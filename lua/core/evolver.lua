-- core/evolver.lua — the engine of self-improvement
-- Watches the stimulus landscape, detects unmet "needs", and GROWS new organs
-- (plugins) to satisfy them. Then applies selection pressure: rewards fit
-- organs, mutates promising ones, retires the unfit. Genetic, not scripted.

local Templates = require("core.templates")

local Evolver = {}
Evolver.__index = Evolver

function Evolver.new(ctx)
  return setmetatable({
    ctx = ctx,
    organs = {},     -- generated name -> { template=, genes=, born_tick= }
    naming = {},     -- template -> count (for unique names)
  }, Evolver)
end

local function unique_name(self, base)
  self.naming[base] = (self.naming[base] or 0) + 1
  return string.format("gen_%s_%d", base, self.naming[base])
end

-- write a generated organ to disk and load it -----------------------------
function Evolver:spawn(template_key, genes, lineage)
  local tpl = Templates[template_key]
  if not tpl then return nil end
  genes = genes or {}
  -- fill defaults
  for k, v in pairs(tpl.default_genes or {}) do
    if genes[k] == nil then genes[k] = v end
  end
  local name = unique_name(self, template_key)
  local src = tpl.build(name, genes)
  local path = self.ctx.cfg.plugins_dir .. "/" .. name .. ".lua"
  local fh = io.open(path, "w")
  if not fh then self.ctx.log:error("evolver: cannot write %s", path); return nil end
  fh:write(src); fh:close()

  local gen = self.ctx.memory:record_birth({
    organ = name, template = template_key, genes = genes, lineage = lineage,
  })
  self.organs[name] = { template = template_key, genes = genes, born_tick = self.ctx.kernel.tick }
  self.ctx.log:info("\27[35m✦ gen %d: spawned organ '%s' from <%s>\27[0m", gen, name, template_key)
  self.ctx.registry:load(path)
  self.ctx.memory:reward(name, 1) -- seed fitness so newborns get a grace window
  return name
end

-- count living organs grown from a given template (population of a species)
function Evolver:population(template_key)
  local n = 0
  for nm, rec in pairs(self.organs) do
    if rec.template == template_key
      and self.ctx.registry.loaded[nm] and self.ctx.registry.loaded[nm].alive then
      n = n + 1
    end
  end
  return n
end

-- mutate: clone an organ with perturbed numeric genes ---------------------
function Evolver:mutate(name)
  local rec = self.organs[name]
  if not rec then return nil end
  -- carrying capacity: don't let one species overrun the population
  if self:population(rec.template) >= (self.ctx.cfg.max_per_template or 3) then
    return nil
  end
  local g = {}
  for k, v in pairs(rec.genes) do
    if type(v) == "number" then
      local jitter = (math.random() * 0.5 + 0.05) * (math.random() < 0.5 and -1 or 1)
      g[k] = math.max(1, math.floor(v * (1 + jitter) + 0.5))
    else
      g[k] = v
    end
  end
  return self:spawn(rec.template, g, name)
end

-- does any matching organ already serve this trigger? ---------------------
function Evolver:serves(trigger)
  for _, rec in pairs(self.organs) do
    if Templates[rec.template] and Templates[rec.template].triggers == trigger then
      return true
    end
  end
  return false
end

-- pick templates relevant to a directed goal string -----------------------
local function goal_templates(goal)
  local picks, low = {}, goal:lower()
  for key, tpl in pairs(Templates) do
    for _, kw in ipairs(tpl.goal_keywords or {}) do
      if low:find(kw, 1, true) then picks[key] = true; break end
    end
  end
  return picks
end

-- re-adopt inherited organs across lives ----------------------------------
-- A reincarnated life loads its organs from disk (registry:scan), but the
-- evolver's per-template name counter and organ table start empty — so it would
-- regrow same-named organs (gen_<tpl>_1, ...) and clobber the inherited body on
-- load (hot-reload). Seed both from persisted births: continue the name sequence
-- past the highest used index, and put still-living organs back under selection.
function Evolver:rehydrate()
  local births = self.ctx.memory.data.births or {}
  for _, b in ipairs(births) do
    if b.organ and b.template then
      local idx = tonumber(tostring(b.organ):match("_(%d+)$"))
      if idx and idx > (self.naming[b.template] or 0) then
        self.naming[b.template] = idx
      end
      local rec = self.ctx.registry.loaded[b.organ]
      if rec and rec.alive and not self.organs[b.organ] then
        self.organs[b.organ] = {
          template = b.template, genes = b.genes or {}, born_tick = self.ctx.kernel.tick,
        }
      end
    end
  end
end

-- one evolutionary step ----------------------------------------------------
function Evolver:step()
  local ctx = self.ctx
  local cfg = ctx.cfg

  -- on the first step of a life, re-adopt organs inherited from prior lives so
  -- names continue instead of colliding and the inherited body stays selectable
  if not self._rehydrated then self._rehydrated = true; self:rehydrate() end

  -- 1) DIRECTED drive: make sure goal-relevant organs exist
  if cfg.mode == "directed" and cfg.goal and cfg.goal ~= "" then
    for key in pairs(goal_templates(cfg.goal)) do
      local tpl = Templates[key]
      if tpl and not self:serves(tpl.triggers) then
        self.ctx.log:info("directive '%s' → growing <%s>", cfg.goal, key)
        self:spawn(key)
      end
    end
  end

  -- 2) FREE drive: detect unmet needs from the stimulus landscape
  for t, s in pairs(ctx.bus.stats) do
    if s.unhandled_streak >= (cfg.need_threshold or 6) then
      -- find a template that answers this stimulus and isn't serving yet
      for key, tpl in pairs(Templates) do
        if tpl.triggers == t and not self:serves(t) then
          ctx.log:info("unmet need: '%s' ignored %d× → growing <%s>", t, s.unhandled_streak, key)
          self:spawn(key)
          s.unhandled_streak = 0
          break
        end
      end
    end
  end

  -- 3) SELECTION: reward landscape -> mutate the strong, cull the weak
  local fitness = ctx.memory.data.fitness
  local ranked = {}
  for name, rec in pairs(self.organs) do
    if ctx.registry.loaded[name] and ctx.registry.loaded[name].alive then
      ranked[#ranked + 1] = { name = name, score = fitness[name] or 0, age = ctx.kernel.tick - rec.born_tick }
    end
  end
  table.sort(ranked, function(a, b) return a.score > b.score end)

  if #ranked > 0 then
    -- occasionally breed a variant of the fittest organ (exploration)
    if math.random() < (cfg.mutate_chance or 0.25) then
      self:mutate(ranked[1].name)
    end
    -- cull: an organ past its grace period with near-zero fitness is retired
    local worst = ranked[#ranked]
    if worst.age > (cfg.grace_ticks or 25) and worst.score < (cfg.retire_floor or 0.5) then
      ctx.registry:retire(worst.name, "low fitness", true) -- delete file too
      self.organs[worst.name] = nil
      ctx.memory.data.fitness[worst.name] = nil
    end
  end

  -- 4) ENTROPY: idle capabilities slowly decay (keeps selection honest)
  ctx.memory:decay(cfg.decay_rate or 0.03)
end

return Evolver
