-- core/modelmgr.lua — meta-evolution: the model is a unit under selection (Faz 4)
-- Measures the host (hostcaps), and when the current brain is a BOTTLENECK climbs:
-- first to a stronger brain already on this machine (core/brain.lua candidates —
-- no download), else up the download ladder when the machine is CAPABLE; descends
-- when capacity drops. It only ever PROPOSES a change through the autonomy ladder,
-- gated by the same policy + approval inbox as everything else; every switch is
-- judged on fresh samples and rolled back if the new brain does worse.
-- See docs/ROADMAP.md §Faz 4.

local HostCaps = require("core.hostcaps")
local P        = require("core.platform")
local Brain    = require("core.brain")

local ModelMgr = {}
ModelMgr.__index = ModelMgr

-- Ordered capability ladder. Tier 1 ships embedded (the decision brain); higher
-- tiers are downloaded into <home>/models on capable machines. Tier 2 is wired
-- with a pinned url+sha (real acquisition via model_acquire); tiers 3+ are stubs
-- awaiting their own pinned artifacts.
local LADDER = {
  { name = "smol-135m-q4",   ram_min_mb = 500,  cores_min = 1, approx_mb = 90,   embedded = true, params_b = 0.135 },
  -- first downloadable tier: a PINNED, checksummed artifact. The organism may
  -- choose WHEN to fetch it, but never WHAT — url+sha bound it to a vetted file.
  { name = "qwen0.5b-q5",    ram_min_mb = 600,  cores_min = 1, approx_mb = 500,  file = "decision.gguf", params_b = 0.5,
    url = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q5_k_m.gguf?download=true",
    sha = "041474553fcabfc2a2d67903f9d2c2e50bd92528e670da4f33b5d0ce6e59fd55" },
  { name = "qwen0.5b-q4",    ram_min_mb = 1500, cores_min = 2, approx_mb = 470,  file = "decision.gguf", params_b = 0.5 },
  { name = "qwen3-0.6b-q4",  ram_min_mb = 2000, cores_min = 2, approx_mb = 480,  file = "decision.gguf", params_b = 0.6 },
  { name = "qwen2.5-1.5b-q4",ram_min_mb = 3500, cores_min = 4, approx_mb = 1000, file = "decision.gguf", params_b = 1.5 },
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

-- the brain was switched — a downloaded tier, or a brain adopted from this
-- machine. Forget the new one's failures and remember what it replaced, so the
-- switch can be judged (and rolled back) once the new brain has enough samples.
-- rec = { kind = "download"|"adopt", key, from_spec, to_spec, to_id, from_tier?, to_tier? }
function ModelMgr:record_upgrade(rec)
  local md = self.ctx.memory.data
  if md.model_fail and rec.key then md.model_fail[rec.key] = nil end
  rec.fallback_before = self:fallback_rate()
  md.model_upgrade = rec
  local c = md.counters                    -- the samples so far belong to the old brain
  if c then c.llm_ok, c.llm_fallback = 0, 0 end
  if rec.to_id then md.brain_id = rec.to_id end
  self.ctx.memory:save()
end

-- a ladder tier was downloaded to dest: switch to it now (it also stays the
-- saved choice for later lives)
function ModelMgr:acquired(act, dest)
  local from_tier, from_spec = self:current_index(), Brain.spec
  local spec = { kind = "gguf", path = dest, name = act.tier_name, params_b = LADDER[act.tier] and LADDER[act.tier].params_b }
  local ok, info = Brain.load(spec)
  self:set_index(act.tier)
  if ok then Brain.save(self.models_dir, spec) end
  self:record_upgrade({ kind = "download", key = act.tier, from_tier = from_tier, to_tier = act.tier,
                        from_spec = from_spec, to_spec = spec, to_id = ok and info.id or nil })
  return ok, info
end

-- switch to a brain already on this machine, now
function ModelMgr:adopt(spec)
  local key = "brain:" .. tostring(spec.name or spec.path or spec.kind)
  local from_spec = Brain.spec
  local ok, info = Brain.load(spec)
  if not ok then
    self:record_failure(key, tostring(info))
    return false, info
  end
  Brain.save(self.models_dir, spec)
  self:record_upgrade({ kind = "adopt", key = key, from_spec = from_spec, to_spec = spec, to_id = info.id })
  return true, info
end

-- a new life started with `info` as its brain (core/brain.lua chose it)
function ModelMgr:on_boot(info)
  local md = self.ctx.memory.data
  if md.brain_id ~= info.id then           -- a different brain than last life: fresh samples
    local c = md.counters or {}
    c.llm_ok, c.llm_fallback = 0, 0
    md.counters, md.brain_id = c, info.id
  end
  local up = md.model_upgrade
  if up and up.to_id and not up.judged and info.id ~= up.to_id and (self.ctx.cfg.brain or "auto") == "auto" then
    -- the brain we switched to didn't come back (file gone, failed to load,
    -- service down): back off from it and restore the previous choice
    self.ctx.log:warn("modelmgr: %s did not load this life — dropping it",
      tostring(up.to_spec and up.to_spec.name or up.to_id))
    self:record_failure(up.key, "did not load")
    Brain.save(self.models_dir, up.from_spec)
    md.model_upgrade = nil
  end
end

local function spec_name(spec) return spec and (spec.name or spec.path or spec.kind) or "rules" end

-- reasoner rule-fallback rate since the counters were last reset (nil = too few samples)
function ModelMgr:fallback_rate()
  local c = self.ctx.memory.data.counters or {}
  local ok, fb = c.llm_ok or 0, c.llm_fallback or 0
  if ok + fb < (self.ctx.cfg.model_min_samples or 20) then return nil end
  return fb / (ok + fb)
end

-- undo the last switch, now: load the brain it replaced again (rules if there
-- was none) and make that the saved choice; back off the rolled-back brain so
-- the next check doesn't pick it straight away. For a download, also put the
-- files back: acquire.rs keeps the replaced model as <name>.prev (decision.gguf
-- → decision.prev); the downloaded file is set aside as <file>.rejected.
function ModelMgr:rollback()
  local md = self.ctx.memory.data
  local up = md.model_upgrade
  if not up then return false, "no recorded upgrade to roll back" end
  local to_name
  if up.kind == "adopt" then
    to_name = spec_name(up.to_spec)
  else                                     -- a download (records from older versions too)
    local cur = self:current_index()
    local to, from = up.to_tier or up.to, up.from_tier or up.from
    if not (to == cur and from and from < cur) then return false, "no recorded upgrade to roll back" end
    local file = LADDER[cur].file
    if file then
      local live = self.models_dir .. "/" .. file
      local prev = self.models_dir .. "/" .. file:gsub("%.[^.]+$", "") .. ".prev"
      os.remove(live .. ".rejected")
      os.rename(live, live .. ".rejected")
      local fh = io.open(prev, "r")
      if fh then fh:close(); os.rename(prev, live) end
    end
    self:set_index(from)
    to_name = LADDER[cur].name
  end
  Brain.load(up.from_spec or { kind = "none" })
  Brain.save(self.models_dir, up.from_spec)
  md.model_upgrade = nil
  md.brain_id = Brain.info().id
  self:record_failure(up.key or up.to, "rolled back")
  return true, string.format("%s → %s", to_name, spec_name(up.from_spec))
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

-- judge the last switch once the new brain has enough samples: if it falls back
-- to rules MORE often than the brain it replaced, propose rolling it back
-- (safe & reversible — it restores a brain that was already trusted).
function ModelMgr:judge_upgrade(info)
  local md = self.ctx.memory.data
  local up = md.model_upgrade
  if not up or up.judged then return end
  if up.to_id then
    if info.id ~= up.to_id then return end   -- not running the brain we switched to
  elseif (up.to_tier or up.to) ~= self:current_index() then
    return
  end
  local rate = self:fallback_rate()
  if not rate then return end
  up.judged = true                           -- one verdict per switch, not one per check
  if rate <= (up.fallback_before or 1) then return end   -- the new brain earns its keep
  local to_name = up.to_spec and spec_name(up.to_spec) or (LADDER[up.to_tier or up.to] or {}).name
  local from_name = up.from_spec and spec_name(up.from_spec) or (LADDER[up.from_tier or up.from] or {}).name or "rules"
  if self.ctx.autonomy then
    self.ctx.autonomy:consider({
      entity = "self.model",
      hypothesis = string.format("rollback %s → %s: rule fallback %.0f%% vs %.0f%% before the switch",
        tostring(to_name), tostring(from_name), rate * 100, (up.fallback_before or 0) * 100),
      confidence = 0.9, action = "act",
      proposed = { verb = "model_rollback", reversible = true, tier_name = from_name,
                   desc = string.format("restore decision brain %s", tostring(from_name)),
                   undo = string.format("switch to %s again", tostring(to_name)) },
    })
  end
  return true
end

-- a brain on this machine meaningfully stronger than the current one, that fits
-- and hasn't failed recently: the weakest such (climb one step at a time).
-- Never overrides an explicit choice ($EVOLUA_MODEL, --brain <kind>).
function ModelMgr:adoptable(caps)
  local cfg = self.ctx.cfg
  if (cfg.brain or "auto") ~= "auto" or (os.getenv("EVOLUA_MODEL") or "") ~= "" then return nil end
  local cur = Brain.info()
  local cur_p = cur.params_b
  if cur.kind == "none" then cur_p = 0 end
  if not cur_p and cur.kind == "gguf" then cur_p = (LADDER[self:current_index()] or {}).params_b end
  if not cur_p then return nil end         -- can't tell what "stronger" means
  for _, c in ipairs(Brain.candidates(cfg)) do  -- weakest first
    local key = "brain:" .. tostring(c.spec.name or c.spec.path or c.kind)
    if c.params_b > cur_p * 1.25 and Brain.fits(c, cfg, caps.ram_total_mb) and not self:blocked(key) then
      return c, key
    end
  end
  return nil
end

-- run a check and, if a change is warranted, PROPOSE it via the autonomy ladder
function ModelMgr:step()
  local caps = HostCaps.probe(self.models_dir)
  local cur = self:current_index()
  local info = Brain.info()
  if self:judge_upgrade(info) then return { action = "rollback", from = cur, to = cur } end
  local bn = self:bottleneck()

  -- 1) a stronger brain already on this machine? Switching to it costs no
  -- download; it is reversible like a downgrade, so it is proposed as an action
  -- (still capped by the autonomy ceiling — at the default `report` it's only reported).
  if bn then
    local c = self:adoptable(caps)
    if c then
      if self.ctx.autonomy then
        self.ctx.autonomy:consider({
          entity = "self.model",
          hypothesis = string.format("adopt %s (%s, %.2gB) — %s falls back to rules %.0f%% of the time",
            c.name, c.source, c.params_b, tostring(info.name), (self:fallback_rate() or 1) * 100),
          confidence = 0.9, action = "act",
          proposed = { verb = "model_adopt", reversible = true, spec = c.spec, tier_name = c.name,
                       desc = "switch the decision brain to " .. c.name,
                       undo = "switch back to " .. tostring(info.name) },
        })
      end
      return { action = "adopt", from = cur, to = cur, reason = c.name }
    end
  end

  -- 2) the download ladder
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
