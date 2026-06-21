-- core/modelmgr.lua — meta-evolution: the model is a unit under selection (Faz 4)
-- Measures the host (hostcaps), and climbs a model ladder when the machine is
-- CAPABLE and the current model is a BOTTLENECK; descends when capacity drops.
-- It only ever PROPOSES the change through the autonomy ladder — acquisition
-- (download + checksum + hot-swap) is a big, reversible action gated by the
-- same policy + approval inbox as everything else. See docs/ROADMAP.md §Faz 4.

local HostCaps = require("core.hostcaps")

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
  os.execute('mkdir -p "' .. self.models_dir .. '" 2>/dev/null')
  return self
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
  local c = self.ctx.memory.data.counters or {}
  local ok, fb = c.llm_ok or 0, c.llm_fallback or 0
  local total = ok + fb
  if total < (self.ctx.cfg.model_min_samples or 20) then return false end
  return (fb / total) > (self.ctx.cfg.model_fallback_rate or 0.4)
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

-- run a check and, if a change is warranted, PROPOSE it via the autonomy ladder
function ModelMgr:step()
  local caps = HostCaps.probe(self.models_dir)
  local cur = self:current_index()
  local bn = self:bottleneck()
  local d = ModelMgr.decide(caps, bn, cur,
    { headroom = self.ctx.cfg.model_headroom, ignore_battery = self.ctx.cfg.model_ignore_battery })
  self.ctx.log:debug("modelmgr: decide=%s %d→%d (%s) | bottleneck=%s ram_avail=%s cores=%s disk=%s batt=%s",
    d.action, d.from, d.to, d.reason, tostring(bn),
    tostring(caps.ram_avail_mb), tostring(caps.cores), tostring(caps.disk_free_mb), tostring(caps.on_battery))
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
