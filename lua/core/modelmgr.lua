-- core/modelmgr.lua — meta-evolution: the model is a unit under selection (Faz 4)
-- Measures the host (hostcaps), and climbs a model ladder when the machine is
-- CAPABLE and the current model is a BOTTLENECK; descends when capacity drops.
-- It only ever PROPOSES the change through the autonomy ladder — acquisition
-- (download + checksum + hot-swap) is a big, reversible action gated by the
-- same policy + approval inbox as everything else. See docs/ROADMAP.md §Faz 4.

local HostCaps = require("core.hostcaps")
local P        = require("core.platform")

local ModelMgr = {}
ModelMgr.__index = ModelMgr

-- Ordered capability ladder. Tier 1 ships embedded (the decision brain); higher
-- tiers are downloaded into <home>/models on capable machines. Tier 2 is wired
-- with a pinned url+sha (real acquisition via model_acquire); tiers 3+ are stubs
-- awaiting their own pinned artifacts.
local LADDER = {
  { name = "smol-135m-q4",   ram_min_mb = 500,  cores_min = 1, approx_mb = 90,   embedded = true },
  -- first downloadable tier: a PINNED, checksummed artifact. The organism may
  -- choose WHEN to fetch it, but never WHAT — url+sha bound it to a vetted file.
  { name = "qwen0.5b-q5",    ram_min_mb = 600,  cores_min = 1, approx_mb = 500,  file = "decision.gguf",
    url = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q5_k_m.gguf?download=true",
    sha = "041474553fcabfc2a2d67903f9d2c2e50bd92528e670da4f33b5d0ce6e59fd55" },
  { name = "qwen0.5b-q4",    ram_min_mb = 1500, cores_min = 2, approx_mb = 470,  file = "decision.gguf" },
  { name = "qwen3-0.6b-q4",  ram_min_mb = 2000, cores_min = 2, approx_mb = 480,  file = "decision.gguf" },
  { name = "qwen2.5-1.5b-q4",ram_min_mb = 3500, cores_min = 4, approx_mb = 1000, file = "decision.gguf" },
}

function ModelMgr.new(ctx)
  local self = setmetatable({ ctx = ctx }, ModelMgr)
  self.models_dir = (ctx.cfg.reports_dir:gsub("/reports$", "")) .. "/models"
  P.mkdir_p(self.models_dir)
  self.locked = {}   -- tier -> why: acquisition failed in THIS life, don't retry it
  return self
end

-- ── acquisition failures: back off instead of re-downloading every check ───
-- A failed tier is not retried in the same life. Across lives (memory persists)
-- the wait doubles per failure, model_retry_secs · 2^(n-1), and after
-- model_max_attempts the tier is given up until state/memory.lua is reset.
function ModelMgr:blocked(tier)
  if self.locked[tier] then return "failed earlier this life (" .. self.locked[tier] .. ")" end
  local f = (self.ctx.memory.data.model_fail or {})[tier]
  if not f then return nil end
  if f.n >= (self.ctx.cfg.model_max_attempts or 3) then
    return string.format("gave up after %d failed attempts (last: %s)", f.n, tostring(f.last))
  end
  if os.time() < (f.next_at or 0) then
    return string.format("backing off until %s after %d failure(s)", os.date("%Y-%m-%d %H:%M", f.next_at), f.n)
  end
  return nil
end

function ModelMgr:record_failure(tier, why)
  self.locked[tier] = why or "failed"
  local md = self.ctx.memory.data
  md.model_fail = md.model_fail or {}
  local f = md.model_fail[tier] or { n = 0 }
  f.n = f.n + 1
  f.last = why or "failed"
  f.next_at = os.time() + math.floor((self.ctx.cfg.model_retry_secs or 3600) * 2 ^ (f.n - 1))
  md.model_fail[tier] = f
  self.ctx.memory:save()   -- a crash right after a failed download must not forget it
end

-- a tier was acquired: forget its failures and remember what it replaced, so the
-- upgrade can be judged (and rolled back) once the new brain has enough samples
function ModelMgr:record_upgrade(from, to, fallback_before)
  local md = self.ctx.memory.data
  if md.model_fail then md.model_fail[to] = nil end
  md.model_upgrade = { from = from, to = to, fallback_before = fallback_before }
  self.ctx.memory:save()
end

-- reasoner rule-fallback rate since the counters were last reset (nil = too few samples)
function ModelMgr:fallback_rate()
  local c = self.ctx.memory.data.counters or {}
  local ok, fb = c.llm_ok or 0, c.llm_fallback or 0
  if ok + fb < (self.ctx.cfg.model_min_samples or 20) then return nil end
  return fb / (ok + fb)
end

-- undo the last upgrade: acquire.rs keeps the replaced model as <name>.prev
-- (decision.gguf → decision.prev). Put it back, set the downloaded file aside as
-- <file>.rejected (out of the loader's path — with no .prev that means the
-- embedded brain loads again), restore the tier index, and back off the
-- rolled-back tier so the next check doesn't fetch it straight away.
-- Like an upgrade, it takes effect next life.
function ModelMgr:rollback()
  local md = self.ctx.memory.data
  local up = md.model_upgrade
  local cur = self:current_index()
  if not (up and up.to == cur and up.from and up.from < cur) then
    return false, "no recorded upgrade to roll back"
  end
  local file = LADDER[cur].file
  if file then
    local live = self.models_dir .. "/" .. file
    local prev = self.models_dir .. "/" .. file:gsub("%.[^.]+$", "") .. ".prev"
    os.remove(live .. ".rejected")
    os.rename(live, live .. ".rejected")
    local fh = io.open(prev, "r")
    if fh then fh:close(); os.rename(prev, live) end
  end
  self:set_index(up.from)
  md.model_upgrade = nil
  self:record_failure(cur, "rolled back")
  return true, string.format("%s → %s", LADDER[cur].name, LADDER[up.from].name)
end

ModelMgr.ladder = LADDER

function ModelMgr:current_index()
  local fh = io.open(self.models_dir .. "/current_tier", "r")
  if fh then local n = tonumber(fh:read("*a")); fh:close(); if n and LADDER[n] then return n end end
  return 1 -- embedded decision brain
end

function ModelMgr:set_index(i)
  local fh = io.open(self.models_dir .. "/current_tier", "w")
  if fh then fh:write(tostring(i)); fh:close() end
end

-- is the current model a bottleneck? proxy = high rule-fallback rate in the
-- reasoner (the embedded brain failing to produce usable decisions).
function ModelMgr:bottleneck()
  if self.ctx.cfg.model_force_upgrade then return true end  -- operator/demo override: always seek to climb
  local rate = self:fallback_rate()
  return rate ~= nil and rate > (self.ctx.cfg.model_fallback_rate or 0.4)
end

-- PURE decision: given caps + bottleneck + current tier, what should change?
-- Returns { action = "upgrade"|"downgrade"|"hold", from, to, reason }.
function ModelMgr.decide(caps, bottleneck, cur, opts)
  opts = opts or {}
  local headroom = opts.headroom or 0.7
  local usable = (caps.ram_avail_mb or caps.ram_total_mb or 0) * headroom

  -- highest tier the machine can comfortably run
  local feasible = 1
  for i, t in ipairs(LADDER) do
    if t.ram_min_mb <= usable and t.cores_min <= (caps.cores or 1) then feasible = i end
  end

  if feasible < cur then
    return { action = "downgrade", from = cur, to = feasible, reason = "capacity dropped (RAM/cores)" }
  end
  if bottleneck and feasible > cur and (opts.ignore_battery or not caps.on_battery) then
    local target = cur + 1
    local need_mb = LADDER[target].approx_mb
    if (caps.disk_free_mb or math.huge) < need_mb then
      return { action = "hold", from = cur, to = cur, reason = "insufficient disk for upgrade" }
    end
    return { action = "upgrade", from = cur, to = target, reason = "bottleneck + spare capacity" }
  end
  return { action = "hold", from = cur, to = cur, reason = bottleneck and "no spare capacity" or "model adequate" }
end

-- judge the last upgrade once the new brain has enough samples: if it falls back
-- to rules MORE often than the brain it replaced, propose rolling it back
-- (safe & reversible — it restores a model that was already trusted).
function ModelMgr:judge_upgrade(cur)
  local md = self.ctx.memory.data
  local up = md.model_upgrade
  if not (up and up.to == cur and not up.judged) then return end
  local rate = self:fallback_rate()
  if not rate then return end
  up.judged = true                           -- one verdict per upgrade, not one per check
  if rate <= (up.fallback_before or 1) then return end   -- the upgrade earns its keep
  local from_t, to_t = LADDER[up.from], LADDER[cur]
  if self.ctx.autonomy then
    self.ctx.autonomy:consider({
      entity = "self.model",
      hypothesis = string.format("rollback %s → %s: rule fallback %.0f%% vs %.0f%% before the upgrade",
        to_t.name, from_t.name, rate * 100, (up.fallback_before or 0) * 100),
      confidence = 0.9, action = "act",
      proposed = { verb = "model_rollback", reversible = true, tier = up.from, tier_name = from_t.name,
                   desc = string.format("restore decision model %s", from_t.name),
                   undo = string.format("upgrade to %s again", to_t.name) },
    })
  end
  return true
end

-- run a check and, if a change is warranted, PROPOSE it via the autonomy ladder
function ModelMgr:step()
  local caps = HostCaps.probe(self.models_dir)
  local cur = self:current_index()
  if self:judge_upgrade(cur) then return { action = "rollback", from = cur, to = cur } end
  local bn = self:bottleneck()
  local d = ModelMgr.decide(caps, bn, cur,
    { headroom = self.ctx.cfg.model_headroom, ignore_battery = self.ctx.cfg.model_ignore_battery })
  self.ctx.log:debug("modelmgr: decide=%s %d→%d (%s) | bottleneck=%s ram_avail=%s cores=%s disk=%s batt=%s",
    d.action, d.from, d.to, d.reason, tostring(bn),
    tostring(caps.ram_avail_mb), tostring(caps.cores), tostring(caps.disk_free_mb), tostring(caps.on_battery))
  if d.action == "upgrade" then
    local why = self:blocked(d.to)
    if why then
      self.ctx.log:debug("modelmgr: not retrying %s — %s", LADDER[d.to].name, why)
      return { action = "hold", from = cur, to = cur, reason = why }
    end
  end
  if d.action == "hold" then return d end

  local from_t, to_t = LADDER[d.from], LADDER[d.to]
  local verb = d.action == "upgrade" and "model_upgrade" or "model_downgrade"
  -- a downgrade is safe & reversible (use a model we already trust) → acts;
  -- an upgrade downloads data → routed as a SUGGESTION (approval inbox), unless
  -- the operator opted into unattended acquisition (cfg.model_unattended), in
  -- which case it acts directly — still bounded to the ladder's pinned url+sha.
  local autonomous = d.action == "downgrade" or self.ctx.cfg.model_unattended
  local decision = {
    entity = "self.model",
    hypothesis = string.format("%s model %s → %s (%s)", d.action, from_t.name, to_t.name, d.reason),
    confidence = autonomous and 0.9 or 0.7,
    action = autonomous and "act" or "suggest",
    proposed = {
      verb = verb, reversible = true, tier = d.to, tier_name = to_t.name,
      file = to_t.file, approx_mb = to_t.approx_mb, url = to_t.url, sha = to_t.sha,
      desc = string.format("switch decision model to %s", to_t.name),
      undo = string.format("revert to %s", from_t.name),
    },
  }
  if self.ctx.autonomy then self.ctx.autonomy:consider(decision) end
  return d
end

return ModelMgr
