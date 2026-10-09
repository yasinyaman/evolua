-- core/evolver.lua — the engine of self-improvement
-- Watches the stimulus landscape, detects unmet "needs", and GROWS new organs
-- (plugins) to satisfy them. Then applies selection pressure: rewards fit
-- organs, mutates promising ones, retires the unfit. Genetic, not scripted.

local Templates = require("core.templates")
local EU        = require("core.evo_util")   -- shared ES kernel (gauss, es_step)
local Log       = require("core.log")        -- rotating append for evolution.log

local Evolver = {}
Evolver.__index = Evolver

function Evolver.new(ctx)
  return setmetatable({
    ctx = ctx,
    organs = {},     -- generated name -> { template=, genes=, born_tick= }
    naming = {},     -- template -> count (for unique names)
  }, Evolver)
end

-- recursive copy so a spawned organ never aliases a template's default_genes
-- (nested tables like a rule organ's `rules` list would otherwise be shared)
local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, e in pairs(v) do c[k] = deepcopy(e) end
  return c
end

-- is this organ's lineage PROTECTED seeded infrastructure (colony / supervisor /
-- explorer)? Such lineages are exempt from culling: losing one would silently and
-- permanently remove a capability for the rest of the life (their synthetic
-- triggers mean free-drive can't regrow them). They are also singletons (see
-- spawn). The flag lives on the template so evolvable lineages — e.g. rule
-- organs (also *.tick) — stay cullable.
local function is_protected(template_key)
  local tpl = Templates[template_key]
  return tpl and tpl.protected == true
end

-- names never repeat across lives: the per-template counter is persisted
-- (memory.name_seq), because births — the other record of used names — is pruned
local function unique_name(self, base)
  self.naming[base] = (self.naming[base] or 0) + 1
  local md = self.ctx.memory.data
  md.name_seq = md.name_seq or {}
  md.name_seq[base] = self.naming[base]
  return string.format("gen_%s_%d", base, self.naming[base])
end

-- may this template be grown in this life? Templates switched off by a flag
-- (--no-colony / --no-supervisor / --no-explorer / --no-rule) or listed in
-- cfg.disabled_templates are never grown, whichever drive asks for them.
function Evolver:allowed(template_key)
  local off = self.ctx.cfg.disabled_templates
  return Templates[template_key] ~= nil and not (off and off[template_key])
end

-- write a generated organ to disk and load it -----------------------------
-- This is the ONE gate every drive passes through (seed, directed, free, bandit,
-- MAP-Elites illumination, crossover, HGT, reasoner), so the checks live here.
function Evolver:spawn(template_key, genes, lineage, sigma)
  local tpl = Templates[template_key]
  if not tpl then return nil end
  if not self:allowed(template_key) then
    self.ctx.log:debug("evolver: <%s> is disabled for this life — not growing it", template_key)
    return nil
  end
  -- protected infrastructure (colony / supervisor / explorer) is a SINGLETON. It
  -- is cull-exempt, so extra copies were never selected, only accumulated: three
  -- supervisors, three explorers each running `find`, two colonies handling every ping.
  if tpl.protected and self:population(template_key) >= 1 then return nil end
  genes = genes or {}
  -- fill defaults
  for k, v in pairs(tpl.default_genes or {}) do
    if genes[k] == nil then genes[k] = deepcopy(v) end
  end
  local name = unique_name(self, template_key)
  local src = tpl.build(name, genes)
  local path = self.ctx.cfg.plugins_dir .. "/" .. name .. ".lua"
  local fh = io.open(path, "w")
  if not fh then self.ctx.log:error("evolver: cannot write %s", path); return nil end
  fh:write(src); fh:close()

  local gen = self.ctx.memory:record_birth({
    organ = name, template = template_key, genes = genes, lineage = lineage, sigma = sigma,
  })
  self.organs[name] = { template = template_key, genes = genes, born_tick = self.ctx.kernel.tick, sigma = sigma }
  local md = self.ctx.memory.data                      -- bandit arm-pull count (#13)
  md.template_tries = md.template_tries or {}
  md.template_tries[template_key] = (md.template_tries[template_key] or 0) + 1
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
  local tpl = Templates[rec.template]
  local g, sig
  if tpl and tpl.mutate_genes then          -- template-defined STRUCTURAL mutation (rule organs)
    g = tpl.mutate_genes(rec.genes, self.ctx.cfg)
  else                                       -- generic numeric genes: ES self-adaptation.
    -- Each numeric gene carries a learned step size (sigma). Mutate the step
    -- log-normally, then perturb the gene log-normally by it — so the lineage
    -- LEARNS how far to mutate each gene (good step sizes are inherited).
    local cfg, psig = self.ctx.cfg, rec.sigma or {}
    g, sig = {}, {}
    for k, v in pairs(rec.genes) do
      if type(v) == "number" then
        g[k], sig[k] = EU.es_step(v, psig[k], cfg)   -- self-adaptive log-normal step
      else
        g[k] = v
      end
    end
  end
  return self:spawn(rec.template, g, name, sig)
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

-- does a word of `text` START with kw? Turkish suffixes still match ("izle" in
-- "izlemek") but a keyword buried mid-word doesn't ("load" in "download", "üre"
-- in "süre"). Bytes >= 128 are UTF-8 letters, so they count as word characters.
local function word_prefix(text, kw)
  local init = 1
  while true do
    local s = text:find(kw, init, true)
    if not s then return false end
    local prev = s > 1 and text:byte(s - 1) or nil
    if not prev or not (prev >= 128 or string.char(prev):match("%w")) then return true end
    init = s + 1
  end
end

-- pick templates relevant to a directed goal string -----------------------
-- A template's own (distinctive) keywords weigh 2; generic ones
-- (cfg.goal_generic_keywords: izle/monitor/log/report …) and keywords several
-- templates share weigh 1. A template grows at score >= 2, so "report errors"
-- grows the error reporter while "report" alone, or the "izle" in "dosya
-- değişikliklerini izle", no longer grows every template that lists it.
local function goal_templates(goal, cfg)
  local low = goal:lower()
  local generic, owners = {}, {}
  for _, w in ipairs(cfg.goal_generic_keywords or {}) do generic[w] = true end
  for _, tpl in pairs(Templates) do
    for _, kw in ipairs(tpl.goal_keywords or {}) do owners[kw] = (owners[kw] or 0) + 1 end
  end
  local picks = {}
  for key, tpl in pairs(Templates) do
    local score = 0
    for _, kw in ipairs(tpl.goal_keywords or {}) do
      if word_prefix(low, kw) then
        score = score + ((generic[kw] or owners[kw] > 1) and 1 or 2)
      end
    end
    if score >= 2 then picks[key] = true end
  end
  return picks
end
Evolver.goal_templates = goal_templates   -- exposed for tests

-- k-tournament: sample k organs, return the fittest of the sample. Unlike pure
-- elitism (always breed rank-1), this lets mid-fitness organs occasionally breed,
-- preserving diversity and escaping local optima.
local function tournament(ranked, k)
  local best
  for _ = 1, math.max(1, k) do
    local c = ranked[math.random(#ranked)]
    if not best or c.score > best.score then best = c end
  end
  return best
end

-- re-adopt inherited organs across lives ----------------------------------
-- A reincarnated life loads its organs from disk (registry:scan), but the
-- evolver's per-template name counter and organ table start empty — so it would
-- regrow same-named organs (gen_<tpl>_1, ...) and clobber the inherited body on
-- load (hot-reload). Seed both from persisted births: continue the name sequence
-- past the highest used index, and put still-living organs back under selection.
function Evolver:rehydrate()
  for tpl, n in pairs(self.ctx.memory.data.name_seq or {}) do
    if n > (self.naming[tpl] or 0) then self.naming[tpl] = n end
  end
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
          sigma = b.sigma,                       -- re-adopt the lineage's learned ES step sizes
        }
      end
    end
  end
  -- lives from before protected organs became singletons may have left several
  -- copies of one; keep the fittest and retire the rest
  local fit, keep = self.ctx.memory.data.fitness, {}
  for name, rec in pairs(self.organs) do
    if is_protected(rec.template) then
      local cur = keep[rec.template]
      if not cur or (fit[name] or 0) > (fit[cur] or 0) then keep[rec.template] = name end
    end
  end
  for name, rec in pairs(self.organs) do
    if is_protected(rec.template) and keep[rec.template] ~= name then
      self.ctx.registry:retire(name, "surplus copy of a singleton organ", true)
      self.organs[name] = nil
      fit[name] = nil
    end
  end
end

-- MAP-Elites behavior descriptor: derive, from the bus subscriptions (the ground
-- truth of what each organ DOES), an owner -> { n = breadth, primary = stimulus }.
-- The cell is then "primary-stimulus # breadth-bucket": a cpu-watcher, an error-
-- watcher and a multi-stimulus generalist land in distinct cells.
local function organ_behaviors(bus)
  local b = {}
  for stim, list in pairs(bus.subs or {}) do
    if stim ~= "self.reward" and stim ~= "self.error" then   -- skip internal channels
      for _, h in ipairs(list) do
        local o = h.owner
        if o and o ~= "kernel" then
          local e = b[o] or { stims = {}, n = 0 }
          if not e.stims[stim] then e.stims[stim] = true; e.n = e.n + 1 end
          b[o] = e
        end
      end
    end
  end
  for _, e in pairs(b) do
    local pick
    for s in pairs(e.stims) do                  -- prefer a non-heartbeat niche, deterministically
      if s ~= "self.heartbeat" and (not pick or s < pick) then pick = s end
    end
    e.primary = pick or "self.heartbeat"
  end
  return b
end

-- refresh the MAP-Elites archive: the best living organ per behavior cell. Kept
-- to the CURRENT population (no resurrection of dead cells) — combined with cull
-- protection of elites, this maintains a live repertoire across the behavior space.
function Evolver:update_archive()
  local fit = self.ctx.memory.data.fitness
  local beh = organ_behaviors(self.ctx.bus)
  local fresh, elites = {}, {}
  for name in pairs(self.organs) do
    local loaded = self.ctx.registry.loaded[name]
    local e = beh[name]
    if loaded and loaded.alive and e then
      local cell = e.primary .. "#" .. tostring(math.min(e.n, 3))
      local score = fit[name] or 0
      local cur = fresh[cell]
      if not cur or score > cur.score then fresh[cell] = { name = name, score = score } end
    end
  end
  for _, e in pairs(fresh) do elites[e.name] = true end
  self.archive, self.elites = fresh, elites
end

-- BANDIT over templates (#13): arms = templates, reward = current average fitness
-- of an arm's living organs, with a UCB exploration bonus and an optimistic prior
-- for untried arms (→ each template is tried once, then investment flows to what
-- pays off ON THIS HOST). Reuses the colony's S4 bandit idea at the organ level.
function Evolver:bandit_pick()
  local tries = self.ctx.memory.data.template_tries or {}
  local fit = self.ctx.memory.data.fitness or {}
  local sum, cnt, N = {}, {}, 0
  for name, rec in pairs(self.organs) do
    local l = self.ctx.registry.loaded[name]
    if l and l.alive then
      sum[rec.template] = (sum[rec.template] or 0) + (fit[name] or 0)
      cnt[rec.template] = (cnt[rec.template] or 0) + 1
    end
  end
  for _, n in pairs(tries) do N = N + n end
  local c = self.ctx.cfg.bandit_c or 1.5
  local best, bscore = nil, -1e18
  for key, tpl in pairs(Templates) do
    -- never invest in a disabled template, nor in protected singletons (seeded
    -- once; a second copy is refused by spawn anyway)
    if self:allowed(key) and not tpl.protected then
      local n = tries[key] or 0
      local score
      if n == 0 then score = 1e17                   -- optimistic prior: try each arm once
      else
        local avg = cnt[key] and (sum[key] / cnt[key]) or 0
        score = avg + c * math.sqrt(math.log(N + 1) / n)
      end
      if score > bscore then best, bscore = key, score end
    end
  end
  return best
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
    for key in pairs(goal_templates(cfg.goal, cfg)) do
      local tpl = Templates[key]
      if tpl and not self:serves(tpl.triggers) then
        local inh = cfg.inherited_genes and cfg.inherited_genes[key]   -- vertical transfer (#11)
        if inh then
          self.ctx.log:info("directive '%s' → growing <%s> with INHERITED genes", cfg.goal, key)
          self:spawn(key, inh.genes, "inherited", inh.sigma)
        else
          self.ctx.log:info("directive '%s' → growing <%s>", cfg.goal, key)
          self:spawn(key)
        end
      end
    end
  end

  -- 2) FREE drive: detect unmet needs from the stimulus landscape
  for t, s in pairs(ctx.bus.stats) do
    if s.unhandled_streak >= (cfg.need_threshold or 6) then
      -- find a template that answers this stimulus and isn't serving yet
      for key, tpl in pairs(Templates) do
        if tpl.triggers == t and self:allowed(key) and not self:serves(t) then
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

  -- MAP-ELITES: refresh the behavioral archive (best-per-cell) so coverage is
  -- measurable, breeding can illuminate empty niches, and each cell's elite is
  -- protected from culling — a repertoire of competents, not one global peak.
  self:update_archive()

  -- OBSERVABILITY: snapshot the evolutionary state every step so the dynamics are
  -- measurable (you can't tune selection you can't see). One append-only TSV line
  -- per evolve step → state/evolution.log. This lives here, not in a template,
  -- because `ranked` already holds the whole population's scores at zero extra cost.
  if cfg.metrics_log ~= false and #ranked > 0 then
    local n, sum, mx, mn = #ranked, 0, ranked[1].score, ranked[#ranked].score
    for _, r in ipairs(ranked) do sum = sum + r.score end
    local mean = sum / n
    local sm2 = 0
    for _, r in ipairs(ranked) do local d = r.score - mean; sm2 = sm2 + d * d end
    local sd = math.sqrt(sm2 / n)
    local species = {}                       -- distinct templates alive (diversity)
    for _, r in ipairs(ranked) do
      local org = self.organs[r.name]
      if org then species[org.template] = true end
    end
    local nsp = 0; for _ in pairs(species) do nsp = nsp + 1 end
    local ncells = 0; for _ in pairs(self.archive or {}) do ncells = ncells + 1 end
    local c = ctx.memory.data.counters or {}
    local okc, fbc = c.llm_ok or 0, c.llm_fallback or 0
    local fbr = (okc + fbc) > 0 and (fbc / (okc + fbc)) or 0
    Log.append((cfg.state_dir or ".") .. "/evolution.log",
      string.format("%d\t%d\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%.3f\n",
        ctx.kernel.tick, ctx.memory.data.generation, n, mean, mx, mn, sd, nsp, ncells, fbr),
      cfg.log_max_bytes, "tick\tgen\tpop\tmean\tmax\tmin\tstddev\tspecies\tcells\tfallback\n")
    -- dump the current repertoire (cell -> best organ) for a visible QD map
    local rf = io.open((cfg.state_dir or ".") .. "/repertoire.txt", "w")
    if rf then
      rf:write("# MAP-Elites repertoire @tick " .. ctx.kernel.tick .. " — " .. ncells .. " cells filled\n")
      local keys = {}; for cell in pairs(self.archive or {}) do keys[#keys + 1] = cell end
      table.sort(keys)
      for _, cell in ipairs(keys) do
        local e = self.archive[cell]
        rf:write(string.format("%-26s %-22s %.2f\n", cell, e.name, e.score))
      end
      rf:close()
    end
  end

  if #ranked > 0 then
    -- BREED: k-tournament instead of always cloning rank-1 — keeps the gene pool
    -- diverse and avoids elitist convergence onto a single lineage.
    if math.random() < (cfg.mutate_chance or 0.25) then
      local parent = tournament(ranked, cfg.tournament_k or 3)
      if parent then self:mutate(parent.name) end
    end
    -- MAP-ELITES illumination: sometimes breed from a RANDOM cell's elite (uniform
    -- over the behavior space) instead of the fittest — this expands the repertoire
    -- into empty niches rather than climbing one fitness peak.
    if math.random() < (cfg.mapelites_chance or 0.3) then
      local cells = {}
      for _, e in pairs(self.archive or {}) do cells[#cells + 1] = e end
      if #cells > 0 then self:mutate(cells[math.random(#cells)].name) end
    end
    -- CULL: soft, probabilistic death instead of euthanizing only the single
    -- worst. Past grace, an organ's death chance rises as its fitness sinks below
    -- the floor (0 at/above 2×floor, 0.5 at the floor, →1 toward zero), scaled by
    -- cull_rate so selection stays gentle. Protected seeded-infrastructure
    -- lineages (tpl.protected) are exempt — free-drive can't regrow them.
    local floor2 = 2 * (cfg.retire_floor or 0.5)
    local cull_rate = cfg.cull_rate or 0.5
    for _, r in ipairs(ranked) do
      local org = self.organs[r.name]
      if floor2 > 0                                      -- guard retire_floor=0 → division by zero
         and org and not is_protected(org.template)
         and not (self.elites and self.elites[r.name])   -- keep each cell's elite (QD diversity)
         and r.age > (cfg.grace_ticks or 25) then
        local p_die = math.max(0, 1 - r.score / floor2)
        if p_die > 0 and math.random() < p_die * cull_rate then
          ctx.registry:retire(r.name, "low fitness", true) -- delete file too
          self.organs[r.name] = nil
          ctx.memory.data.fitness[r.name] = nil
        end
      end
    end

    -- CROSSOVER: recombine two tournament-selected parents of the SAME template
    -- (when that template supports it — e.g. rule organs). Asexual mutation alone
    -- misses recombination, the main source of novelty in genetic algorithms.
    if math.random() < (cfg.crossover_chance or 0.15) and #ranked >= 2 then
      local a, b = tournament(ranked, cfg.tournament_k or 3), tournament(ranked, cfg.tournament_k or 3)
      if a and b and a.name ~= b.name then
        local ra, rb = self.organs[a.name], self.organs[b.name]
        local tpl = ra and rb and ra.template == rb.template and Templates[ra.template]
        if tpl and tpl.crossover_genes
           and self:population(ra.template) < (cfg.max_per_template or 3) then
          self:spawn(ra.template, tpl.crossover_genes(ra.genes, rb.genes, cfg), a.name .. "×" .. b.name)
        end
      end
    end
  end

  -- BANDIT drive (#13): occasionally invest a reproduction in the highest-UCB
  -- template — mutate its fittest organ if it has one, else grow it fresh (so the
  -- optimistic prior proactively tries untried templates, beyond need/goal drives).
  if math.random() < (cfg.bandit_chance or 0.15) then
    local key = self:bandit_pick()
    if key then
      local bestnm, bestsc = nil, -1e18
      for nm, rec in pairs(self.organs) do
        local l = ctx.registry.loaded[nm]
        if rec.template == key and l and l.alive and (fitness[nm] or 0) > bestsc then
          bestnm, bestsc = nm, (fitness[nm] or 0)
        end
      end
      if bestnm then self:mutate(bestnm)
      elseif self:population(key) < (cfg.max_per_template or 3) then self:spawn(key) end
    end
  end

  -- 4) ENTROPY: idle capabilities slowly decay (keeps selection honest)
  ctx.memory:decay(cfg.decay_rate or 0.03)

  -- 5) bound the birth record: living organs + the most recent births_keep
  local alive = {}
  for nm in pairs(self.organs) do
    local l = ctx.registry.loaded[nm]
    if l and l.alive then alive[nm] = true end
  end
  ctx.memory:prune_births(alive, cfg.births_keep or 200)
end

return Evolver
