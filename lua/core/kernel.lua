-- core/kernel.lua — the life cycle / tick loop
-- Boots the organism, drives perception → cognition (evolution) → action each
-- tick, wires reward/error feedback into fitness, and shuts down gracefully.

local Bus        = require("core.bus")
local Log        = require("core.log")
local Memory     = require("core.memory")
local Registry   = require("core.registry")
local Evolver    = require("core.evolver")
local Reporter   = require("core.reporter")
local WorldModel = require("core.worldmodel")
local Reasoner   = require("core.reasoner")
local Autonomy   = require("core.autonomy")
local ModelMgr   = require("core.modelmgr")

local Kernel = {}
Kernel.__index = Kernel

local BUILTIN_SENSORS = {
  "sys_metrics", "logwatch", "fswatch", "introspect",
  "proc_top", "proc_errors",   -- Faz 1: per-process perception
  "curiosity",                 -- Faz 3: active exploration
}

local function ensure_dir(p) os.execute('mkdir -p "' .. p .. '" 2>/dev/null') end

function Kernel.new(cfg)
  ensure_dir(cfg.plugins_dir)
  ensure_dir(cfg.reports_dir)
  ensure_dir(cfg.state_dir)

  local log = Log.new({ level = cfg.log_level, path = cfg.state_dir .. "/evolua.log" })
  local self = setmetatable({ cfg = cfg, tick = 0, running = false, sensors = {} }, Kernel)

  -- shared organism context handed to every subsystem & plugin
  local ctx = { cfg = cfg, log = log, kernel = self }
  ctx.bus      = Bus.new(log, cfg)   -- cfg carries the honest-reward tunables
  ctx.memory   = Memory.new(cfg.state_dir .. "/memory.lua")
  ctx.registry = Registry.new(ctx)
  ctx.reporter = Reporter.new(ctx)
  ctx.report   = function(category, text) ctx.reporter:report(category, text) end
  ctx.evolver  = Evolver.new(ctx)
  ctx.worldmodel = WorldModel.new(ctx)   -- situational memory (entity dossiers)
  ctx.worldmodel:attach()                -- wire it to proc.* stimuli
  ctx.reasoner = Reasoner.new(ctx)       -- sense-making (LLM + RAG, rule fallback)
  ctx.autonomy = Autonomy.new(ctx)       -- autonomy ladder (learn→report→…→act)
  ctx.modelmgr = ModelMgr.new(ctx)       -- meta-evolution: size the model to the host
  self.ctx = ctx

  -- feedback loop: reward/error stimuli adjust fitness (the selective force)
  ctx.bus:subscribe("self.reward", function(ev)
    ctx.memory:reward(ev.data.owner, ev.data.amount or 1)
  end, "kernel")
  ctx.bus:subscribe("self.error", function(ev)
    ctx.memory:reward(ev.data.owner, -(cfg.error_penalty or 1))
  end, "kernel")

  return self
end

function Kernel:boot()
  local ctx = self.ctx
  ctx.log:info("\27[1mEvoLua\27[0m booting — mode=%s%s", self.cfg.mode,
    (self.cfg.goal and self.cfg.goal ~= "") and (" goal=\"" .. self.cfg.goal .. "\"") or "")

  -- load built-in sensors
  for _, name in ipairs(BUILTIN_SENSORS) do
    if self.cfg.sensors[name] ~= false then
      local ok, mod = pcall(require, "sensors." .. name)
      if ok and mod then
        self.sensors[#self.sensors + 1] = mod
        ctx.log:info("sense organ online: %s — %s", mod.name, mod.desc)
      else
        ctx.log:warn("sensor '%s' failed to load: %s", name, tostring(mod))
      end
    end
  end

  -- load any organs already on disk from previous lives
  ctx.registry:scan()
  ctx.log:info("awoke with %d organ(s), generation %d",
    #ctx.registry:list(), ctx.memory.data.generation)
end

-- portable sleep without external deps
local function sleep(sec)
  if sec <= 0 then return end
  os.execute("sleep " .. tostring(sec) .. " 2>/dev/null")
end

function Kernel:run()
  self:boot()
  self.running = true
  local ctx = self.ctx
  local max = self.cfg.max_ticks  -- nil = run forever

  while self.running do
    self.tick = self.tick + 1

    -- 1) PERCEIVE
    for _, s in ipairs(self.sensors) do
      local ok, err = pcall(s.sense, s, ctx)
      if not ok then ctx.log:warn("sensor %s error: %s", s.name, tostring(err)) end
    end

    -- 2) EVOLVE (cognition) — on its own cadence
    if self.tick % (self.cfg.evolve_every or 3) == 0 then
      local ok, err = pcall(function() ctx.evolver:step() end)
      if not ok then ctx.log:error("evolver error: %s", tostring(err)) end
    end

    -- 3) PERSIST + housekeeping
    if self.tick % (self.cfg.save_every or 10) == 0 then
      ctx.memory:save()
      ctx.registry:scan() -- pick up externally-dropped organs too
      ctx.worldmodel:decay(self.cfg.worldmodel_decay or 60) -- forget stale entities
    end

    -- 4) sense-making (Faz 2) — reasoner on its own cadence (LLM+RAG / rules)
    if self.tick % (self.cfg.reasoner_every or 8) == 0 then
      local ok, err = pcall(function() ctx.reasoner:step() end)
      if not ok then ctx.log:warn("reasoner error: %s", tostring(err)) end
    end

    -- 5) check the approval inbox (user-approved actions) — cheap dir scan
    pcall(function() ctx.autonomy:poll_approvals() end)
    -- 5a) settle outcome-credit traces (reward organs whose actions cooled a target)
    pcall(function() ctx.autonomy:settle_outcomes() end)

    -- 5b) meta-evolution: occasionally reconsider which model fits the host
    if self.tick % (self.cfg.model_check_every or 200) == 0 then
      pcall(function() ctx.modelmgr:step() end)
    end

    -- 6) situational report on its own cadence (rule-based, from the world model)
    if self.tick % (self.cfg.situational_every or 20) == 0 then
      pcall(function() ctx.reporter:write_report("periodic") end)
    end

    if max and self.tick >= max then self.running = false end
    if self.running then sleep(self.cfg.tick_seconds or 1) end
  end

  self:shutdown()
end

function Kernel:shutdown()
  local ctx = self.ctx
  ctx.reporter:flush(true)
  ctx.memory:save()
  ctx.log:info("\27[1mEvoLua\27[0m resting after %d ticks · gen %d · %d organs",
    self.tick, ctx.memory.data.generation, #ctx.registry:list())
end

function Kernel:stop() self.running = false end

return Kernel
