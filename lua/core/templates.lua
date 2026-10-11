-- core/templates.lua — genome blueprints the evolver uses to grow new organs
-- Each template knows: which stimulus it answers, the genes (tunable params)
-- it exposes, and how to render itself into a standalone plugin .lua file.
-- New capabilities are BORN here as source code, not hand-written.

local EU  = require("core.evo_util")   -- shared ES kernel (es_step) for rule thresholds
local Ser = require("core.serialize")  -- genes → Lua literal (nested tables included)

local function literal(genes)
  return Ser.ser(genes)
end

-- header shared by every generated organ
local function render(name, desc, events, genes, body)
  return string.format([[
-- GENERATED ORGAN: %s
-- desc: %s
-- This file was written by the evolver. Genes are tunable across generations.
local genes = %s
return {
  name = %q,
  desc = %q,
  generated = true,
  genes = genes,
  events = { %s },
  attach = function(ctx)
%s
  end,
}
]], name, desc, literal(genes), name, desc,
    ("%q, "):rep(#events):format(table.unpack(events)):gsub(", $", ""),
    body)
end

local T = {}

-- threshold guard for a numeric metric (cpu / mem / load) -----------------
-- Each guard has its OWN keywords plus the shared generic ones, so "cpu
-- resource" grows the cpu guard only (it used to grow all three).
local function guard(metric_event, field, label, keywords)
  local kws = { "kaynak", "resource", "izle", "monitor", "guard" }
  for _, k in ipairs(keywords) do kws[#kws + 1] = k end
  return {
    triggers = metric_event,
    goal_keywords = kws,
    default_genes = { threshold = (field == "one") and 4 or 75, cooldown = 5 },
    build = function(name, genes)
      local body = string.format([[
    local last = -1e9
    ctx.bus:subscribe(%q, function(ev)
      local v = ev.data.%s or 0
      if v >= genes.threshold and (ctx.kernel.tick - last) >= genes.cooldown then
        last = ctx.kernel.tick
        ctx.log:warn("[%s] %s %%s over threshold %%s", tostring(v), tostring(genes.threshold))
        ctx.report(%q, string.format("%s=%%s (>= %%s) at tick %%d", v, genes.threshold, ctx.kernel.tick))
        return { handled = true, reward = 2 }
      end
      return false
    end, %q)]],
        metric_event, field, name, label, label, label, name)
      return render(name, label .. " threshold guard", { metric_event }, genes, body)
    end,
  }
end

T["cpu_guard"]  = guard("metric.cpu",  "pct", "CPU",  { "cpu", "işlemci", "processor" })
T["mem_guard"]  = guard("metric.mem",  "pct", "MEM",  { "memory", "bellek", "ram" })
-- "yükü"/"yüke", not a bare "yük": that would also match "yüksek" (= high)
T["load_guard"] = guard("metric.load", "one", "LOAD", { "load", "yükü", "yüke" })

-- error reporter: collects log.error / self.error and writes reports -------
T["error_reporter"] = {
  triggers = "log.error",
  goal_keywords = { "hata", "error", "report", "rapor", "log", "takip", "track" },
  default_genes = { flush_every = 5 },
  build = function(name, genes)
    local body = string.format([[
    local buf, n = {}, 0
    local function collect(ev)
      n = n + 1
      buf[#buf + 1] = string.format("- [%%s] %%s: %%s", ev.type,
        tostring(ev.data.pattern or ev.data.on or "?"),
        tostring(ev.data.line or ev.data.err or ""))
      if n %% genes.flush_every == 0 then
        ctx.report(%q, "ERRORS\n" .. table.concat(buf, "\n"))
        buf = {}
      end
      return { handled = true, reward = 3 }
    end
    ctx.bus:subscribe("log.error", collect, %q)
    ctx.bus:subscribe("self.error", collect, %q)]], name, name, name)
    return render(name, "aggregates errors and reports them",
      { "log.error", "self.error" }, genes, body)
  end,
}

-- fs journal: records filesystem changes to a journal report --------------
T["fs_journal"] = {
  triggers = "fs.change",
  goal_keywords = { "dosya", "file", "klasör", "folder", "journal", "değişiklik", "change", "izle", "watch" },
  default_genes = { verbose = 1 },
  build = function(name, genes)
    local body = string.format([[
    ctx.bus:subscribe("fs.change", function(ev)
      ctx.report(%q, string.format("%%s  %%s", ev.data.kind, tostring(ev.data.path)))
      if genes.verbose == 1 then
        ctx.log:info("[%s] %%s %%s", ev.data.kind, tostring(ev.data.path))
      end
      return { handled = true, reward = 1 }
    end, %q)]], name, name, name)
    return render(name, "journals filesystem changes", { "fs.change" }, genes, body)
  end,
}

-- vital monitor: reacts to self.heartbeat and notes drift ------------------
T["vital_monitor"] = {
  triggers = "self.heartbeat",
  goal_keywords = { "kendi", "self", "vital", "health", "sağlık", "meta" },
  default_genes = { report_every = 20 },
  build = function(name, genes)
    local body = string.format([[
    ctx.bus:subscribe("self.heartbeat", function(ev)
      if ev.data.tick %% genes.report_every == 0 then
        ctx.report(%q, string.format("tick=%%d organs=%%d gen=%%d best=%%s(%%.1f)",
          ev.data.tick, ev.data.organs or 0, ev.data.generation or 0,
          tostring(ev.data.best), ev.data.best_score or 0))
        return { handled = true, reward = 1 }
      end
      return false
    end, %q)]], name, name)
    return render(name, "monitors the organism's own vitals", { "self.heartbeat" }, genes, body)
  end,
}

-- colony: primitive self-replication + peer communication --------------------
-- One organ that (a) announces its presence and trades messages with sibling
-- instances through a shared filesystem "colony" dir, and (b) — ONLY when
-- cfg.clone_enabled — spawns bounded, mortal OS-process clones of the organism.
--
-- triggers="colony.tick" is synthetic (nothing ever emits it), so the free drive
-- never picks it. What keeps every OTHER drive from growing a self-replicator is
-- the evolver's spawn gate: colony is `protected`, so a second living copy is
-- refused (and the bandit skips it), and --no-colony disables the template for
-- the whole life. It is seeded by main.lua, or its first copy grown in directed
-- mode by a matching goal keyword. It listens on the REAL clock (self.heartbeat)
-- at runtime regardless. The population SAFETY caps live in cfg (NOT in genes),
-- so no gene change can loosen the bounds.
T["colony"] = {
  triggers = "colony.tick",
  protected = true,   -- seeded infrastructure: exempt from culling (can't be regrown)
  goal_keywords = {
    "çoğal", "klon", "clone", "replicate", "replikasyon", "kopya", "üre",
    "koloni", "colony", "iletişim", "haberleş", "communicate", "mesaj", "message",
  },
  default_genes = { link_every = 5, clone_every = 15, clone_cooldown = 30, peer_ttl = 30 },
  build = function(name, genes)
    local body = "local SELF = " .. string.format("%q", name) .. "\n" .. [==[
    local cfg = ctx.cfg
    local P = ctx.platform              -- OS layer: quoting, mkdir_p, list_dir (no raw shell)
    local function win() return cfg.is_windows end
    local shq, ensure_dir, list_dir = P.shq, P.mkdir_p, P.list_dir
    local function read_file(p)
      local fh = io.open(p, "r"); if not fh then return nil end
      local s = fh:read("*a"); fh:close(); return s
    end
    local function write_file(p, s)
      local fh = io.open(p, "w"); if not fh then return false end
      fh:write(s); fh:close(); return true
    end
    local function root() return cfg.colony_root or "." end
    local function me()   return cfg.colony_id or "root" end
    local function gen()  return cfg.generation or 0 end

    -- "should I split?" — DEMAND: is work going uncovered right now? Returns a
    -- reasons table (empty = no demand). Platform-robust: the bus's native unmet-
    -- need streaks, the reasoner's brain-bottleneck counters, and the world model's
    -- per-process heat (the latter works on macOS, where the system-wide
    -- metric.cpu sensor stays silent because sys_metrics is /proc-based).
    local function demand()
      local r = {}
      -- (a) unmet needs: stimuli that keep going unhandled
      local need_t, starved = (cfg.need_threshold or 6), 0
      for _, s in pairs(ctx.bus.stats or {}) do
        if (s.unhandled_streak or 0) >= need_t then starved = starved + 1 end
      end
      if starved >= (cfg.clone_need_events or 1) then r.needs = starved end
      -- (b) brain bottleneck: reasoner falling back to rules too often
      local c = (ctx.memory.data and ctx.memory.data.counters) or {}
      local okc, fbc = c.llm_ok or 0, c.llm_fallback or 0
      local tot = okc + fbc
      if tot >= (cfg.model_min_samples or 20)
         and (fbc / tot) > (cfg.clone_fallback_rate or cfg.model_fallback_rate or 0.4) then
        r.brain = fbc / tot
      end
      -- (c) host heat: salient / hot / erroring processes in the world model
      local hot = 0
      local ok, snap = pcall(function() return ctx.worldmodel:snapshot(8) end)
      if ok and type(snap) == "table" then
        for _, e in ipairs(snap) do
          if (e.errors or 0) > 0 or (e.hot_ticks or 0) > 5
             or (e.cpu_avg or 0) >= (cfg.proc_cpu_threshold or 50) then hot = hot + 1 end
        end
      end
      if hot >= (cfg.clone_hot_entities or 1) then r.hot = hot end
      return r
    end

    -- CAPACITY: can the host feed another worker? Mirrors the model ladder's
    -- guard (spare RAM, and not on battery unless told to ignore it).
    local function capacity_ok()
      if not cfg.hostcaps then return true end          -- no probe wired → rely on hard caps
      local ok, caps = pcall(function() return cfg.hostcaps.probe(cfg.colony_root) end)
      if not ok or type(caps) ~= "table" then return true end
      local avail = caps.ram_avail_mb or caps.ram_total_mb or 0
      if avail < (cfg.clone_min_ram_mb or 500) then return false, "low RAM" end
      if caps.on_battery and not cfg.clone_ignore_battery then return false, "on battery" end
      return true
    end
    local last_block = nil   -- remember the last "can't split" reason (log it only on change)
    local last_why  = ""     -- why the last clone got the goal it did (for the split log)
    local split_n   = 0      -- counts splits, for portfolio alternation / epsilon-probe

    -- how well is THIS instance's purpose paying off? sum of fitness across the
    -- organs that serve its goal (S4 harvest). 0 if not a purpose-directed member.
    local function purpose_payoff()
      local goal = cfg.goal
      if not goal or goal == "" then return 0 end
      local tg, mine = cfg.template_goal or {}, {}
      for tmpl, g in pairs(tg) do if g == goal then mine[tmpl] = true end end
      local fit, sum = (ctx.memory.data and ctx.memory.data.fitness) or {}, 0
      for nm, rec in pairs(ctx.evolver.organs or {}) do
        if mine[rec.template] then sum = sum + (fit[nm] or 0) end
      end
      return sum
    end

    -- the colony's purposes are the canonical goals in cfg.template_goal. Only
    -- those enter the S4 ledger: a user's free-text --goal (say, a Turkish
    -- sentence) maps to no template, always pays 0, and would only become a
    -- bandit arm that wastes splits.
    local function canonical(goal)
      for _, g in pairs(cfg.template_goal or {}) do if g == goal then return true end end
      return false
    end

    -- aggregate the colony's harvested outcomes: goal -> {sum, n} (the S4 ledger)
    local function read_outcomes()
      local dir, agg = root() .. "/colony/outcomes", {}
      for _, fn in ipairs(list_dir(dir)) do
        local txt = read_file(dir .. "/" .. fn)
        local g = txt and txt:match("purpose=([^\n]+)")
        local p = txt and tonumber(txt:match("payoff=([%d%.%-]+)"))
        if g and p and canonical(g) then      -- ignores entries older versions wrote
          local a = agg[g] or { sum = 0, n = 0 }
          a.sum, a.n = a.sum + p, a.n + 1; agg[g] = a
        end
      end
      return agg
    end

    -- CRYSTALLIZE the next clone's goal from what the parent is living through.
    -- explore = most chronically unhandled stimulus (fill a gap); exploit = the
    -- highest-fitness organ's niche (deepen what pays). With purpose_learn (S4) the
    -- colony also SELECTS among purposes: it favors goals whose past children earned
    -- the most reward (a bandit; untried goals get an optimistic prior so each is
    -- tried once; an epsilon probe keeps adapting to a shifting environment).
    local function crystallize_goal()
      if cfg.purpose_enabled == false then return nil end
      local pm, tg = cfg.purpose_map or {}, cfg.template_goal or {}
      local exp, top = nil, 0
      for t, s in pairs(ctx.bus.stats or {}) do
        if pm[t] and (s.unhandled_streak or 0) > top then exp, top = pm[t], s.unhandled_streak end
      end
      local exl, best = nil, -1e9
      local fit = (ctx.memory.data and ctx.memory.data.fitness) or {}
      for nm, rec in pairs(ctx.evolver.organs or {}) do
        local g = tg[rec.template]
        if g and (fit[nm] or 0) > best then exl, best = g, (fit[nm] or 0) end
      end
      split_n = split_n + 1
      if cfg.purpose_learn ~= false then            -- S4: select valuable purposes
        local agg = read_outcomes()
        -- epsilon: periodically probe the current gap regardless of proven payoff
        if exp and (split_n % (cfg.purpose_explore_every or 4) == 0) then
          last_why = "explore probe (gap)"; return exp
        end
        local cand = {}
        if exp then cand[exp] = true end
        if exl then cand[exl] = true end
        for g in pairs(agg) do cand[g] = true end
        local prior = cfg.purpose_prior or 1e6      -- optimistic: try each purpose once
        local pick, pscore = nil, -1e18
        for g in pairs(cand) do
          local a = agg[g]
          local score = a and (a.sum / a.n) or prior
          if score > pscore then pick, pscore = g, score end
        end
        if pick then
          local a = agg[pick]
          last_why = a and string.format("proven avg=%.1f n=%d", a.sum / a.n, a.n) or "untried (optimistic)"
          return pick
        end
        return exp or exl
      end
      local mode = cfg.purpose_mode or "portfolio"  -- S1–S3 (purpose_learn off)
      if mode == "explore" then last_why = "explore"; return exp or exl end
      if mode == "exploit" then last_why = "exploit"; return exl or exp end
      last_why = "portfolio"
      if split_n % 2 == 1 then return exp or exl else return exl or exp end
    end

    -- VERTICAL GENE TRANSFER (#11): find the parent's FITTEST living organ for the
    -- goal's template so the child inherits TUNED genes (+ learned ES steps), not
    -- template defaults; they are written with the core serializer (ctx.serialize),
    -- which handles nested genomes too. Best-effort: nil if the parent serves no
    -- organ of that template (e.g. an explore-goal niche it doesn't occupy yet) →
    -- child starts fresh, as before.
    local ser = ctx.serialize.ser
    local function inherit_for(goal)
      if not goal or goal == "" then return nil end
      local tg  = cfg.template_goal or {}
      local fit = (ctx.memory.data and ctx.memory.data.fitness) or {}
      local bn, bs, bt = nil, -1e9, nil
      for nm, rec in pairs(ctx.evolver.organs or {}) do
        if tg[rec.template] == goal and (fit[nm] or 0) > bs then bn, bs, bt = nm, (fit[nm] or 0), rec.template end
      end
      if not bn then return nil end
      local rec = ctx.evolver.organs[bn]
      return bt, rec.genes, rec.sigma
    end

    -- incoming messages from peers: log, report, reward. This reward is what
    -- keeps the comms organ "fit" so selection never retires it.
    ctx.bus:subscribe("colony.message", function(ev)
      ctx.log:info("[%s] <- %s: %s", SELF, tostring(ev.data.from), tostring(ev.data.body))
      ctx.report(SELF, string.format("MSG from %s: %s",
        tostring(ev.data.from), tostring(ev.data.body)))
      return { handled = true, reward = 2 }
    end, SELF)

    -- the clock: presence beacon + inbox drain + broadcast + gated replication
    ctx.bus:subscribe("self.heartbeat", function(ev)
      local tick = ev.data.tick or ctx.kernel.tick
      if tick % (genes.link_every or 5) ~= 0 then return false end

      local cdir   = root() .. "/colony"
      local peersd = cdir .. "/peers"
      local inboxd = cdir .. "/inbox"
      local mid    = me()
      ensure_dir(peersd)
      ensure_dir(inboxd .. "/" .. mid)
      local now = os.time()

      -- 1) announce presence
      write_file(peersd .. "/" .. mid, string.format(
        "id=%s gen=%d tick=%d organs=%d time=%d",
        mid, gen(), tick, #ctx.registry:list(), now))

      -- 2) drain my inbox -> a stimulus per message, then consume the file
      local got = 0
      for _, fn in ipairs(list_dir(inboxd .. "/" .. mid)) do
        local path = inboxd .. "/" .. mid .. "/" .. fn
        local txt = read_file(path)
        if txt then
          -- sender is embedded in the body (ids contain dots, so a filename
          -- split would mis-parse a child's id like "root-123.15")
          local from = txt:match("from=([^\n]+)") or "?"
          local body = txt:gsub("^from=[^\n]*\n?", "")
          ctx.bus:emit("colony.message",
            { from = from, body = body, to = mid, tick = tick })
          got = got + 1
        end
        os.remove(path)
      end

      -- 3) census of live peers; prune beacons older than peer_ttl
      local live = {}
      for _, pf in ipairs(list_dir(peersd)) do
        local bt = read_file(peersd .. "/" .. pf)
        local t = bt and tonumber(bt:match("time=(%d+)"))
        if t and (now - t) <= (genes.peer_ttl or 30) then
          if pf ~= mid then live[#live + 1] = pf end
        elseif pf ~= mid then
          os.remove(peersd .. "/" .. pf)
        end
      end

      -- 4) broadcast a ping to every live peer
      for _, peer in ipairs(live) do
        ensure_dir(inboxd .. "/" .. peer)
        write_file(inboxd .. "/" .. peer .. "/" .. mid .. "." .. tostring(tick) .. ".msg",
          string.format("from=%s\nping (gen %d, %d organs) @tick %d",
            mid, gen(), #ctx.registry:list(), tick))
      end

      -- 4b) S4 harvest: a purpose-directed member reports how well its purpose is
      --     paying off, so the root can learn which purposes are worth spawning.
      if cfg.goal and canonical(cfg.goal) and cfg.purpose_learn ~= false then
        local odir = cdir .. "/outcomes"
        ensure_dir(odir)
        write_file(odir .. "/" .. mid,
          string.format("purpose=%s\npayoff=%.2f\ngen=%d\nat=%d\n", cfg.goal, purpose_payoff(), gen(), now))
      end

      -- 4c) HORIZONTAL GENE TRANSFER (#12): publish my fittest organ's genome to a
      --     shared gene pool, and periodically ADOPT a peer-evolved genome that
      --     clearly beats my local best for that template — good alleles spread
      --     across the colony (same file-dance as peers/outcomes). Runs in any
      --     instance; with peers it cross-pollinates, solo it's effectively a no-op.
      if cfg.hgt ~= false then
        local gpdir = cdir .. "/genepool"; ensure_dir(gpdir)
        local fit = (ctx.memory.data and ctx.memory.data.fitness) or {}
        local bn, bs, bt
        for nm, rec in pairs(ctx.evolver.organs or {}) do
          if (fit[nm] or 0) > (bs or -1) then bn, bs, bt = nm, (fit[nm] or 0), rec.template end
        end
        if bn and bs > (cfg.hgt_min_fitness or 3) then          -- publish, if I beat the pool
          local rec = ctx.evolver.organs[bn]
          local glines = {}                                   -- only FLAT-NUMERIC genomes transfer;
          for k, v in pairs(rec.genes or {}) do               -- a rule organ's structural genome
            if type(v) == "number" then glines[#glines + 1] = string.format("genes %s %g", k, v) end
          end                                                 -- (stimulus/rules) has no numeric top-
          if #glines > 0 then                                 -- level genes → skipped, no crash.
            local cur = read_file(gpdir .. "/" .. bt)
            local curf = cur and tonumber(cur:match("fitness ([%d%.%-eE]+)")) or -1
            if bs > curf then                                 -- line format (sandbox has no `load`)
              local lines = { string.format("fitness %g", bs) }
              for _, l in ipairs(glines) do lines[#lines + 1] = l end
              for k, v in pairs(rec.sigma or {}) do
                if type(v) == "number" then lines[#lines + 1] = string.format("sigma %s %g", k, v) end
              end
              write_file(gpdir .. "/" .. bt, table.concat(lines, "\n") .. "\n")
            end
          end
        end
        if tick % ((genes.link_every or 5) * (cfg.hgt_every or 6)) == 0 then  -- adopt one clear winner
          for _, tmpl in ipairs(list_dir(gpdir)) do
            local txt = read_file(gpdir .. "/" .. tmpl) or ""
            local pf = tonumber(txt:match("fitness ([%d%.%-eE]+)"))
            local mybest = -1
            for nm, rec in pairs(ctx.evolver.organs or {}) do
              if rec.template == tmpl and (fit[nm] or 0) > mybest then mybest = (fit[nm] or 0) end
            end
            local cap = ctx.evolver.capacity and ctx.evolver:capacity(tmpl) or (cfg.max_per_template or 3)
            if pf and pf > mybest + (cfg.hgt_margin or 2)
               and ctx.evolver:population(tmpl) < cap then
              local g, sg = {}, {}                            -- parse line format (no `load` in sandbox)
              for sec, k, v in txt:gmatch("(%a+) ([%w_]+) ([%d%.%-eE]+)") do
                if sec == "genes" then g[k] = tonumber(v) elseif sec == "sigma" then sg[k] = tonumber(v) end
              end
              if next(g) and ctx.evolver:spawn(tmpl, g, "hgt", next(sg) and sg or nil) then
                ctx.log:info("\27[36m\u{21c4} [%s] HGT: adopted %s genome (fitness %.1f > local %.1f)\27[0m",
                  SELF, tmpl, pf, mybest)
                break
              end
            end
          end
        end
      end

      -- 5) replication — OPT-IN, INTELLIGENTLY GATED, and hard-bounded.
      --    Hard caps (depth, population) are the ceiling; the split only fires
      --    under genuine load AND when the host can host another worker; a
      --    colony-wide lock rate-limits it. Cheap checks first, host probe last.
      local size = #live + 1
      if cfg.clone_enabled
         and (tick % (genes.clone_every or 15) == 0)
         and gen() < (cfg.clone_max_generation or 1)     -- hard cap: clone depth
         and size < (cfg.clone_max_peers or 3) then        -- hard cap: colony population
        local lock = cdir .. "/clone.lock"
        local lt = read_file(lock); lt = lt and tonumber(lt:match("(%d+)"))
        if not (lt and (now - lt) < (genes.clone_cooldown or 30)) then   -- cooldown gate (cheap)
          -- demand gate: split under load (or eager); then the capacity probe.
          local why = (cfg.clone_require_pressure ~= false) and demand() or { eager = true }
          local cap_ok, cap_why = capacity_ok()
          if next(why) and cap_ok then
            write_file(lock, tostring(now))            -- acquire colony-wide rate limit
            local cid   = mid .. "." .. tostring(tick)
            local chome = cdir .. "/children/" .. cid
            local prog  = cfg.prog or "evolua"
            local goal  = crystallize_goal()             -- the child's acquired purpose (or nil)
            local itmpl, igenes, isigma = inherit_for(goal)   -- parent's best genes for that goal (#11)
            if itmpl then
              ensure_dir(chome)
              write_file(chome .. "/inherited.lua", string.format(
                "return { [%q] = { genes = %s, sigma = %s } }\n", itmpl, ser(igenes), ser(isigma)))
            end
            local flags = " --colony-id " .. cid
              .. " --generation " .. tostring(gen() + 1)
              .. " --colony-root " .. shq(root())
              .. " --ticks " .. tostring(cfg.clone_child_ticks or 40)
              .. " --tick-seconds " .. tostring(cfg.tick_seconds or 1)
              .. " --no-clone"                           -- children don't replicate (star colony)
              .. (goal and (" --goal " .. shq(goal)) or "")  -- born specialized, or generalist
            local cmd
            if win() then
              -- cmd strips the outermost quote pair, leaving: set "VAR=x"&& "prog" …
              cmd = 'cmd /c start "" /B cmd /c "set "EVOLUA_HOME=' .. chome .. '"&& ' .. shq(prog) .. flags .. '"'
            else   -- binary and plain Lua both read $EVOLUA_HOME
              cmd = 'EVOLUA_HOME=' .. shq(chome) .. ' ' .. (cfg.embedded and "" or "lua ") ..
                    shq(prog) .. flags .. ' >/dev/null 2>&1 &'
            end
            local reasons = {}
            if why.eager then reasons[#reasons + 1] = "eager" end
            if why.needs then reasons[#reasons + 1] = "needs=" .. why.needs end
            if why.brain then reasons[#reasons + 1] = string.format("fallback=%.0f%%", why.brain * 100) end
            if why.hot   then reasons[#reasons + 1] = "hot=" .. why.hot end
            local rtext = table.concat(reasons, " ")
            local ptext = goal and ("purpose: " .. goal .. (last_why ~= "" and (" [" .. last_why .. "]") or "")) or "generalist"
            if itmpl then ptext = ptext .. " \u{21d3}genes:" .. itmpl end   -- inherited a tuned organ
            ctx.log:info("\27[35m⎘ [%s] splitting under load [%s] -> %s (gen %d) · %s\27[0m",
              SELF, rtext, cid, gen() + 1, ptext)
            ctx.report(SELF, string.format("CLONE %s — split [%s]; %s; colony was %d",
              cid, rtext, ptext, size))
            local lf = io.open(cdir .. "/lineage.log", "a")  -- colony's purpose ledger (observability)
            if lf then lf:write(string.format("%d %s gen=%d %s\n", tick, cid, gen() + 1, ptext)); lf:close() end
            os.execute(cmd)
            return { handled = true, reward = 4 }
          elseif next(why) and not cap_ok then
            if cap_why ~= last_block then     -- transparency without per-tick spam
              last_block = cap_why
              ctx.log:info("[%s] under load but holding off — host can't host another worker (%s)",
                SELF, tostring(cap_why))
            end
          end
        end
      end

      return { handled = true, reward = (got > 0) and (1 + got) or 1 }
    end, SELF)
  ]==]
    return render(name, "colony: presence + messaging + gated self-replication",
      { "self.heartbeat", "colony.message" }, genes, body)
  end,
}

-- supervisor: the cortex-side of the host "brainstem" watch -------------------
-- Works WITH the Rust supervisor thread (src/supervisor.rs). Each beat it proves
-- the tick loop is alive (touches state/heartbeat) and reads the vitals the host
-- watchdog wrote (state/vitals), surfacing them as a `host.vitals` stimulus so the
-- EVOLVABLE layer can react. It is advisory — it logs/reports, never enforces.
-- In plain-Lua mode there is no host thread, so state/vitals never appears and the
-- organ simply beats the heartbeat (harmless). triggers="supervisor.tick" is
-- synthetic (never emitted) so free-drive can't grow it; it is seeded in main.lua and,
-- being protected, never duplicated (see the spawn gate in evolver.lua).
T["supervisor"] = {
  triggers = "supervisor.tick",
  protected = true,   -- seeded infrastructure: exempt from culling (can't be regrown)
  goal_keywords = {
    "süpervizör", "supervisor", "vital", "watchdog", "canlılık", "gözet", "sağlık", "health",
  },
  default_genes = { beat_every = 1, report_every = 20 },
  build = function(name, genes)
    local body = "local SELF = " .. string.format("%q", name) .. "\n" .. [==[
    local cfg = ctx.cfg
    local function read_file(p)
      local fh = io.open(p, "r"); if not fh then return nil end
      local s = fh:read("*a"); fh:close(); return s
    end
    local function write_file(p, s)
      local fh = io.open(p, "w"); if not fh then return false end
      fh:write(s); fh:close(); return true
    end
    local sd = cfg.state_dir or "."
    local hb, vf = sd .. "/heartbeat", sd .. "/vitals"

    local function vitals()
      local t = read_file(vf); if not t then return nil end
      local v = {}
      for k, val in t:gmatch("([%w_]+)=(-?%d+)") do v[k] = tonumber(val) end
      return v
    end

    -- advisory reaction to vitals (evolvable: other organs may also subscribe to
    -- host.vitals and react — e.g. the colony could weigh real process count).
    ctx.bus:subscribe("host.vitals", function(ev)
      local v = ev.data or {}
      if (v.stall or 0) == 1 then
        ctx.log:warn("[%s] host watchdog flags the organism STALLED (hb_age=%ss)",
          SELF, tostring(v.heartbeat_age))
        ctx.report(SELF, "host watchdog: organism flagged stalled")
      end
      return { handled = true, reward = 1 }
    end, SELF)

    -- the beat: prove liveness to the host, then surface host vitals to evolution
    ctx.bus:subscribe("self.heartbeat", function(ev)
      local tick = ev.data.tick or ctx.kernel.tick
      if tick % (genes.beat_every or 1) ~= 0 then return false end
      write_file(hb, string.format("tick=%d time=%d", tick, os.time()))
      local v = vitals()
      if v then
        ctx.bus:emit("host.vitals", v)
        if tick % (genes.report_every or 20) == 0 then
          ctx.report(SELF, string.format("vitals: rss=%dMB procs=%d stall=%d hb_age=%s",
            v.self_rss_mb or 0, v.colony_procs or 0, v.stall or 0, tostring(v.heartbeat_age)))
        end
      end
      return { handled = true, reward = 1 }
    end, SELF)
  ]==]
    return render(name, "host-brainstem watch: liveness beat + vitals surfacing",
      { "self.heartbeat", "host.vitals" }, genes, body)
  end,
}

-- explorer: active environment discovery + perception expansion ----------------
-- Curiosity-gated, it wanders the host (filesystem / logs / network / system) and
-- EXPANDS the organism's own senses: discovered dirs/logs are appended to
-- cfg.watch_dirs / cfg.watch_logs so fswatch/logwatch start perceiving them. New
-- perception → new stimuli → organ growth → and (via the colony) new purposes.
-- The macro complement to the per-process `curiosity` sensor. triggers is the
-- synthetic "explore.tick"; seeded in main.lua; protected, so never duplicated.
T["explorer"] = {
  triggers = "explore.tick",
  protected = true,   -- seeded infrastructure: exempt from culling (can't be regrown)
  goal_keywords = {
    -- "tarama", not "tara": that would also match "taraf"/"tarafından" (= side / by)
    "keşif", "keşfet", "explore", "discover", "ortam", "environment", "tarama", "scan", "merak",
  },
  default_genes = { explore_every = 7, depth = 2, breadth = 6 },
  build = function(name, genes)
    local body = "local SELF = " .. string.format("%q", name) .. "\n" .. [==[
    local cfg = ctx.cfg
    local P = ctx.platform              -- OS layer: walk / list_dir without a shell, path checks
    local function run(cmd)
      local p = io.popen and io.popen(cmd); if not p then return "" end
      local o = p:read("*a") or ""; p:close(); return o
    end
    local function contains(t, v) for _, x in ipairs(t or {}) do if x == v then return true end end return false end
    -- skip the organism's OWN output dirs (no self-referential perception loops)
    -- and known-huge build/vcs dirs (don't drown fswatch) — never even descended into.
    local PRUNE = { "target", ".git", "node_modules", "build", ".cargo", "dist", ".svn", ".hg", "__pycache__" }
    local SKIP = {}; for _, n in ipairs(PRUNE) do SKIP[n] = true end
    local function skip_dir(path)
      for seg in path:gmatch("[^/\\]+") do if SKIP[seg] then return true end end  -- any huge/vcs segment
      -- skip the organism's OWN data home (explore OUTWARD, not self-referentially)
      for _, d in ipairs({ cfg.colony_root, cfg.plugins_dir, cfg.reports_dir, cfg.state_dir }) do
        -- inside d, on a path boundary (home "/x/evo" must not swallow "/x/evolution")
        local n = #(d or "")
        if n > 0 and path:sub(1, n) == d and (#path == n or path:sub(n + 1, n + 1):match("[/\\]")) then
          return true
        end
      end
      return false
    end
    -- a discovered path joins perception only if it is safe to hand to a command
    -- later (no quotes / metacharacters / control chars); others are logged once
    local refused = {}
    local function acceptable(path)
      if P.safe_path(path) then return true end
      if not refused[path] then
        refused[path] = true
        ctx.log:warn("[%s] not watching %q — unsafe characters in the path", SELF, path)
      end
      return false
    end

    local MOD = { "fs", "log", "net", "cmd", "model", "sys" }
    local modal_i, sys_done, tools_done, models_done = 0, false, false, false

    -- discoveries: report + reward (observability; the real effect is perception growth)
    ctx.bus:subscribe("env.discovery", function(ev)
      local d = ev.data or {}
      ctx.report(SELF, string.format("discovered %s: %s", tostring(d.kind), tostring(d.detail or d.path or "?")))
      return { handled = true, reward = 1 }
    end, SELF)

    ctx.bus:subscribe("self.heartbeat", function(ev)
      local tick = ev.data.tick or ctx.kernel.tick
      if tick % (genes.explore_every or 7) ~= 0 then return false end
      local c = cfg.curiosity or 0
      if c <= 0 then return false end
      if math.random() > c then return false end      -- curiosity-gated intensity

      local roots = cfg.explore_roots or {}
      modal_i = (modal_i % #MOD) + 1
      local m = MOD[modal_i]
      if m == "net" and cfg.explore_net == false then m = "sys" end
      if m == "model" and cfg.explore_models == false then m = "sys" end
      if m == "cmd" and cfg.explore_tools == false then m = "sys" end

      if m == "fs" then
        for _, root in ipairs(roots) do
          for _, e in ipairs(P.walk(root, { depth = genes.depth or 2, kind = "dir", limit = 100, prune = PRUNE })) do
            local d = e.path
            if not skip_dir(d) and not contains(cfg.watch_dirs, d) and acceptable(d) then
              ctx.bus:emit("env.discovery", { kind = "dir", path = d })
              if cfg.explore_expand ~= false and #(cfg.watch_dirs or {}) < (cfg.explore_max_watch or 12) then
                table.insert(cfg.watch_dirs, d)       -- expand perception (fswatch picks it up)
                ctx.log:info("\27[36m⌖ [%s] now watching dir %s\27[0m", SELF, d)
              end
              return { handled = true, reward = 2 }
            end
          end
        end
        return { handled = true, reward = 1 }

      elseif m == "log" then
        for _, root in ipairs(roots) do
          for _, e in ipairs(P.walk(root, { depth = 3, kind = "file", suffix = ".log", limit = 50, prune = PRUNE })) do
            local f = e.path
            if not skip_dir(f) and not contains(cfg.watch_logs, f) and acceptable(f) then
              ctx.bus:emit("env.discovery", { kind = "log", path = f })
              if cfg.explore_expand ~= false and #(cfg.watch_logs or {}) < (cfg.explore_max_watch or 12) then
                table.insert(cfg.watch_logs, f)       -- expand perception (logwatch tails it)
                ctx.log:info("\27[36m⌖ [%s] now tailing log %s\27[0m", SELF, f)
              end
              return { handled = true, reward = 2 }
            end
          end
        end
        return { handled = true, reward = 1 }

      elseif m == "net" then
        local raw
        if cfg.is_windows then
          raw = run("netstat -an 2>nul | findstr /i listening")
        else
          raw = run("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null")
          if raw == "" then raw = run("netstat -an 2>/dev/null | grep -i listen") end
        end
        local n, names = 0, {}
        for line in raw:gmatch("[^\n]+") do
          if not line:find("^COMMAND") then
            n = n + 1
            local cmd = line:match("^(%S+)")
            if cmd and #names < (genes.breadth or 6) and not contains(names, cmd) then names[#names + 1] = cmd end
          end
        end
        if n > 0 then
          ctx.bus:emit("env.discovery", { kind = "port", detail = n .. " listeners (" .. table.concat(names, ",") .. ")" })
          return { handled = true, reward = 2 }
        end
        return { handled = true, reward = 1 }

      elseif m == "cmd" then     -- installed commands / tools on $PATH (scanned once)
        if not tools_done then
          tools_done = true
          local sep = cfg.is_windows and ";" or ":"
          local path = (os.getenv and os.getenv("PATH")) or ""
          local seen, n = {}, 0
          for dir in path:gmatch("[^" .. sep .. "]+") do
            for _, f in ipairs(P.list_dir(dir)) do
              if not seen[f] then seen[f] = true; n = n + 1 end
            end
          end
          local have = {}
          for _, t in ipairs(cfg.notable_tools or {}) do if seen[t] then have[#have + 1] = t end end
          ctx.bus:emit("env.discovery", { kind = "tool", detail = string.format(
            "%d commands on PATH; notable: %s", n, #have > 0 and table.concat(have, ",") or "none") })
        end
        return { handled = true, reward = 1 }

      elseif m == "model" then   -- decision brains already on this host (scanned once)
        if not models_done then
          models_done = true
          local found = P.models(cfg.model_dirs)
          for i, md in ipairs(found) do
            if i > (genes.breadth or 6) then break end
            ctx.bus:emit("env.discovery", { kind = "model", detail = string.format("%s (%s, %.2gB %s, %d MB)",
              md.name, md.source, md.params_b or 0, md.quant or "?", md.size_mb or 0) })
          end
          if #found > 0 then return { handled = true, reward = 2 } end
        end
        return { handled = true, reward = 1 }

      else -- sys (once)
        if not sys_done then
          sys_done = true
          local u = run(cfg.is_windows and "ver" or "uname -srm 2>/dev/null"):gsub("^%s+", ""):gsub("%s+$", "")
          ctx.bus:emit("env.discovery", { kind = "sys", detail = (u ~= "" and u or "unknown host") })
        end
        return { handled = true, reward = 1 }
      end
    end, SELF)
  ]==]
    return render(name, "environment exploration: scout the host + expand perception",
      { "self.heartbeat", "env.discovery" }, genes, body)
  end,
}

-- ===========================================================================
-- RULE DSL — a typed, capability-isolated grammar the evolver can grow, mutate,
-- and recombine. Unlike the fixed templates above (structure frozen, only numeric
-- genes vary), a rule organ's GENOME is a list of rules:
--     when <stimulus>, if <field> <op> <value> then <report|log|emit>
-- Mutation rewrites the subscribed stimulus, the compared field/op/value, the
-- action, and adds/removes rules; crossover recombines two parents' rule lists.
-- The grammar renders ONLY safe primitives (subscribe / read ev.data / compare /
-- report / log / emit) — it cannot express os/io, so an evolved rule organ is
-- capability-isolated BY CONSTRUCTION (the structural-novelty + sandbox-safety
-- win in one): values are numbers, operators come from a whitelist, fields are
-- bracket-quoted lookups, so a mutated genome can never inject code.
-- ===========================================================================
local RULE = {}
-- real stimuli the organism emits, with the NUMERIC ev.data fields each carries.
-- alert.* are the organ's OWN emit targets, also subscribable — so rule organs can
-- chain into pipelines (one organ's emit feeds another's stimulus).
RULE.stimulus_fields = {
  ["metric.cpu"]     = { "pct" },
  ["metric.mem"]     = { "pct", "mb" },
  ["metric.load"]    = { "one" },
  ["proc.hot"]       = { "cpu_avg", "rss_mb" },
  ["proc.sample"]    = { "cpu_avg", "rss_mb" },
  ["self.heartbeat"] = { "tick", "organs", "generation" },
  ["log.error"]      = {},
  ["fs.change"]      = {},
  ["env.discovery"]  = {},
  ["alert.cpu"]      = { "value" },
  ["alert.mem"]      = { "value" },
  ["alert.load"]     = { "value" },
  ["alert.proc"]     = { "value" },
  ["alert.fs"]       = { "value" },
  ["alert.generic"]  = { "value" },
}
RULE.stimuli = {}
for s in pairs(RULE.stimulus_fields) do RULE.stimuli[#RULE.stimuli + 1] = s end
RULE.ops     = { ">=", "<=", ">", "<", "==", "~=" }
RULE.actions = { "report", "log", "emit", "act" }   -- every action has an OBSERVABLE effect.
                                             -- "act" REQUESTS a host action via the autonomy
                                             -- ladder — it NEVER executes directly (see below).
RULE.emits   = { "alert.cpu", "alert.mem", "alert.load", "alert.proc", "alert.fs", "alert.generic" }
RULE.act_verbs = { "throttle", "restore", "notify" }   -- SAFE, reversible verbs ONLY — never "kill"

local OPSET, EMITSET, ACTSET = {}, {}, {}
for _, o in ipairs(RULE.ops)       do OPSET[o]  = true end
for _, e in ipairs(RULE.emits)     do EMITSET[e] = true end
for _, v in ipairs(RULE.act_verbs) do ACTSET[v] = true end
local function rand_pick(t) return t[math.random(#t)] end

local function random_rule(stimulus)
  local fields = RULE.stimulus_fields[stimulus] or {}
  local r = { action = rand_pick(RULE.actions) }
  if #fields > 0 and math.random() < 0.8 then       -- usually a real condition
    r.field, r.op, r.value = rand_pick(fields), rand_pick(RULE.ops), math.random(1, 100)
  end                                               -- else: fires whenever stimulus does
  if r.action == "emit" then r.emit = rand_pick(RULE.emits) end
  if r.action == "act"  then r.verb = rand_pick(RULE.act_verbs) end
  r.reward = math.random(1, 3)                       -- telemetry hint (honest fitness ignores it)
  return r
end

local function clone_genes(g)
  local out = { stimulus = g.stimulus, rules = {} }
  for i, rule in ipairs(g.rules or {}) do
    local nr = {}; for k, v in pairs(rule) do nr[k] = v end
    out.rules[i] = nr
  end
  return out
end

-- render a rule genome into safe organ source (injection-proof) -----------------
local function render_rules(name, genes)
  local q = function(s) return string.format("%q", tostring(s)) end
  local stim = RULE.stimulus_fields[genes.stimulus] and genes.stimulus or "self.heartbeat"
  local lines = {}
  for i, r in ipairs(genes.rules or {}) do
    local cond = "true"
    if r.field and r.op and OPSET[r.op] then
      cond = "(tonumber(d[" .. q(r.field) .. "]) or 0) " .. r.op .. " " .. tostring(tonumber(r.value) or 0)
    end
    -- report/log rules fire at most once per cfg.rule_cooldown ticks: the seed
    -- rule (`tick >= 10 → report`) would otherwise report on every heartbeat
    if r.action ~= "emit" and r.action ~= "act" then
      cond = cond .. " and ready(" .. i .. ")"
    end
    local act
    if r.action == "emit" then
      local em = EMITSET[r.emit] and r.emit or "alert.generic"
      if em == stim then                              -- never re-emit our own trigger
        act = "ctx.report(SELF, " .. q("rule " .. i) .. ")"
      else
        act = "ctx.bus:emit(" .. q(em) .. ", { from = SELF, value = (tonumber(d[" .. q(r.field or "") .. "]) or 0) })"
      end
    elseif r.action == "log" then
      act = 'ctx.log:info("[%s] rule fired", SELF)'
    elseif r.action == "act" then
      -- REQUEST a host action (never execute): emit action.request; core autonomy
      -- ladder decides act/approve/refuse. Verb whitelisted to safe reversible ones.
      local verb = ACTSET[r.verb] and r.verb or "notify"
      act = 'ctx.bus:emit("action.request", { from = SELF, verb = ' .. q(verb) ..
        ', entity = tostring(d["name"] or "?"), pid = tonumber(d["pid"]), confidence = 0.75, reason = ' ..
        q("rule " .. i .. " " .. verb .. " on " .. stim) .. ' })'
    else -- report
      act = "ctx.report(SELF, " .. q("rule " .. i .. " on " .. stim) .. ")"
    end
    lines[#lines + 1] = "      if " .. cond .. " then " .. act ..
      "; return { handled = true, reward = " .. tostring(tonumber(r.reward) or 1) .. " } end"
  end
  if #lines == 0 then lines[1] = "      -- (no rules)" end
  local body = "local SELF = " .. q(name) .. "\n" ..
    "    local last = {}\n" ..
    "    local function ready(i)\n" ..
    "      local t = ctx.kernel.tick\n" ..
    "      if t - (last[i] or -1e9) < (ctx.cfg.rule_cooldown or 10) then return false end\n" ..
    "      last[i] = t; return true\n" ..
    "    end\n" ..
    "    ctx.bus:subscribe(" .. q(stim) .. ", function(ev)\n" ..
    "      local d = ev.data or {}\n" ..
    table.concat(lines, "\n") .. "\n" ..
    "      return false\n" ..
    "    end, SELF)"
  return render(name, "rule organ (evolved reflex on " .. stim .. ")", { stim }, genes, body)
end

-- structural mutation: rewrite ONE aspect of the genome --------------------------
local function mutate_rule_genes(g, cfg)
  g = clone_genes(g)
  local maxr = (cfg and cfg.rule_max_rules) or 4
  local rules = g.rules
  local kind = math.random(7)
  if kind == 1 and #rules > 0 then                 -- perturb a threshold (self-adaptive ES)
    local r = rules[math.random(#rules)]
    if r.value then r.value, r.vsigma = EU.es_step(r.value, r.vsigma, cfg) end
  elseif kind == 2 and #rules > 0 then             -- flip the operator
    rules[math.random(#rules)].op = rand_pick(RULE.ops)
  elseif kind == 3 and #rules > 0 then             -- watch a different field
    local fields = RULE.stimulus_fields[g.stimulus] or {}
    if #fields > 0 then rules[math.random(#rules)].field = rand_pick(fields) end
  elseif kind == 4 and #rules < maxr then          -- grow a rule
    rules[#rules + 1] = random_rule(g.stimulus)
  elseif kind == 5 and #rules > 1 then             -- prune a rule
    table.remove(rules, math.random(#rules))
  elseif kind == 6 and #rules > 0 then             -- change the action
    local r = rules[math.random(#rules)]
    r.action = rand_pick(RULE.actions)
    if r.action == "emit" and not r.emit then r.emit = rand_pick(RULE.emits) end
    if r.action == "act"  and not r.verb then r.verb = rand_pick(RULE.act_verbs) end
  else                                             -- DIFFERENTIATE: jump to a new niche
    g.stimulus = rand_pick(RULE.stimuli)
    local fields = RULE.stimulus_fields[g.stimulus] or {}
    for _, r in ipairs(rules) do                   -- keep each rule's field valid
      if #fields > 0 then
        if r.field then r.field = rand_pick(fields) end
      else
        r.field, r.op, r.value = nil, nil, nil
      end
    end
  end
  return g
end

-- crossover: uniform recombination of two parents' rule lists --------------------
local function crossover_rule_genes(g1, g2, cfg)
  local child = { stimulus = (math.random() < 0.5) and g1.stimulus or g2.stimulus, rules = {} }
  local fields = RULE.stimulus_fields[child.stimulus] or {}
  local fok = {}; for _, f in ipairs(fields) do fok[f] = true end
  local pool = {}
  for _, r in ipairs(g1.rules or {}) do pool[#pool + 1] = r end
  for _, r in ipairs(g2.rules or {}) do pool[#pool + 1] = r end
  for _, r in ipairs(pool) do
    if math.random() < 0.5 then
      local nr = {}; for k, v in pairs(r) do nr[k] = v end
      if nr.field and not fok[nr.field] then         -- repair fields invalid for the niche
        if #fields > 0 then nr.field = fields[math.random(#fields)]
        else nr.field, nr.op, nr.value = nil, nil, nil end
      end
      child.rules[#child.rules + 1] = nr
    end
  end
  local maxr = (cfg and cfg.rule_max_rules) or 4
  while #child.rules > maxr do table.remove(child.rules) end   -- respect the genome-size bound (mutation does)
  if #child.rules == 0 then child.rules[1] = random_rule(child.stimulus) end
  return child
end

T["rule"] = {
  triggers = "rule.tick",      -- synthetic: free-drive can't auto-grow it; it is
                               -- seeded once, then proliferates by mutation/crossover
                               -- (and the bandit); --no-rule disables it at the spawn gate
  goal_keywords = { "kural", "rule", "refleks", "reflex" },   -- distinctive (no generic "behavior"/"evolve" that a user --goal would collide with)
  -- seed in the self.heartbeat "incubator" niche — alive on every platform (unlike
  -- macOS's /proc-based metric.cpu) so the organ survives long enough to DIFFERENTIATE
  -- (mutation kind 7 jumps it to a live event niche: log.error / fs.change / proc.hot).
  default_genes = { stimulus = "self.heartbeat",
    rules = { { field = "tick", op = ">=", value = 10, action = "report", reward = 1 } } },
  build           = render_rules,
  mutate_genes    = mutate_rule_genes,     -- evolver delegates structural mutation here
  crossover_genes = crossover_rule_genes,  -- evolver delegates recombination here
}

-- ===========================================================================
-- SYNTHESIZER — "think and produce". Templates are the organism's FLOOR: the
-- minimum competence it has with no model at all. This seeded organ is the
-- CEILING: when a directed goal has no blueprint (or only generic verbs like
-- "report"/"watch" matched one), or a stimulus starves with no blueprint that
-- answers it, it asks the brain (cfg.llm → llm_complete) to WRITE a whole new
-- organ file. The result is compiled (cfg.compile, never executed), linted,
-- written to plugins/syn_*.lua and loaded through the normal registry. From
-- then on it is an ordinary organ under HONEST FITNESS: one that earns nothing
-- past its grace is retired and the goal re-synthesized with that failure as
-- feedback; one that throws is repaired (the error goes back to the model).
-- Evolution by LLM-mutation, selected by the same reward as everything else.
-- Budgeted (cfg.synth_max calls per life); idles when no brain is attached.
-- `triggers` is synthetic (never emitted): free-drive can't grow a second one.
T["synth"] = {
  triggers = "synth.tick",
  protected = true,
  goal_keywords = { "sentez", "synth", "icat", "invent", "üret", "generate", "tasarla", "design" },
  default_genes = { every = 40, tokens = 1800 },
  build = function(name, genes)
    local body = "local SELF = " .. string.format("%q", name) .. "\n" .. [==[
    local cfg = ctx.cfg
    local mem = ctx.memory.data
    mem.synth = mem.synth or { n = 0, children = {}, failures = {} }
    -- read-only tools an organ may sample/run; also how we recognise "the sensing command" in source
    local SAMPLE_OK = { netstat = true, lsof = true, ps = true, df = true, who = true, uptime = true, top = true,
                        uname = true, ifconfig = true, ip = true, ss = true, vm_stat = true, iostat = true,
                        ls = true, last = true, launchctl = true, systemctl = true, free = true, w = true,
                        docker = true, journalctl = true, dmesg = true, grep = true, tail = true, head = true,
                        cat = true, wc = true, du = true, stat = true, mount = true, hostname = true, date = true,
                        sysctl = true, sensors = true, ["nvidia-smi"] = true, nproc = true, env = true, id = true,
                        ["log"] = true, podman = true, kubectl = true, systemd = true, lsblk = true, ["ss"] = true }
    -- the shell command an organ runs, whether io.popen("cmd") or helper("cmd"): the first
    -- string literal whose first word is a known tool
    local function find_cmd(src)
      local direct = src:match('io%.popen%s*%(%s*"([^"]+)"')
      if direct then return direct end
      for lit in src:gmatch('"([^"\n]+)"') do
        local head = lit:match("^%s*(%S+)")
        if head and SAMPLE_OK[head] then return lit end
      end
      return nil
    end

    local S = mem.synth
    local attempts, last_try = 0, -1e9
    local errs = {}        -- owner -> last error text (from self.error)

    -- verbs shared across many blueprints: matching ONLY these means the goal's
    -- real topic (e.g. "network") has no blueprint → synthesize
    local GENERIC = { "rapor", "report", "izle", "watch", "takip", "track", "log", "monitor",
                      "gözle", "kontrol", "check", "journal" }
    local function generic(kw) for _, g in ipairs(GENERIC) do if kw == g then return true end end return false end
    local function alive(nm) local r = ctx.registry.loaded[nm]; return r and r.alive end
    local function child_for(key)
      if S.cooldown and S.cooldown[key] and ctx.kernel.tick < S.cooldown[key] then return true end
      for nm, c in pairs(S.children) do if c.key == key and not c.dead and alive(nm) then return nm end end
    end
    local function ascii(s)
      s = s:lower()
      for from, to in pairs({ ["ç"]="c", ["ğ"]="g", ["ı"]="i", ["ö"]="o", ["ş"]="s", ["ü"]="u", ["â"]="a", ["î"]="i" }) do
        s = s:gsub(from, to)
      end
      return s
    end
    local function slug(text)
      local w = {}
      for t in ascii(text):gmatch("%a+") do
        if #t > 2 and not generic(t) then w[#w + 1] = t end
        if #w == 2 then break end
      end
      return #w > 0 and table.concat(w, "_") or "organ"
    end
    local host_os = (function()
      if cfg.is_windows then return "Windows" end
      local p = io.popen and io.popen("uname -s 2>/dev/null"); local s = p and p:read("*l") or ""; if p then p:close() end
      return s:find("Darwin") and "macOS" or (s ~= "" and s or "Linux")
    end)()

    -- what the organism is actually seeing right now (real payload shapes)
    local function stimuli_summary()
      local seen, order = {}, {}
      for i = #ctx.bus.history, 1, -1 do
        local ev = ctx.bus.history[i]
        if not seen[ev.type] and ev.type ~= "self.reward" and ev.type ~= "self.error" then
          seen[ev.type] = ev; order[#order + 1] = ev.type
          if #order >= 14 then break end
        end
      end
      table.sort(order)
      local lines = {}
      for _, t in ipairs(order) do
        local d, fs = seen[t].data or {}, {}
        local function show(v, depth)
          if type(v) ~= "table" then
            local sv = tostring(v); if #sv > 32 then sv = sv:sub(1, 32) .. "…" end
            return sv
          end
          if depth > 1 then return "{…}" end
          local parts, n = {}, 0
          if #v > 0 then                                   -- array: show the first element's shape
            return "{ " .. #v .. " items like " .. show(v[1], depth + 1) .. " }"
          end
          for kk, vv in pairs(v) do
            parts[#parts + 1] = tostring(kk) .. "=" .. show(vv, depth + 1); n = n + 1
            if n >= 6 then parts[#parts + 1] = "…"; break end
          end
          table.sort(parts)
          return "{" .. table.concat(parts, ", ") .. "}"
        end
        for k, v in pairs(d) do
          fs[#fs + 1] = tostring(k) .. "=" .. show(v, 0)
          if #fs >= 6 then break end
        end
        table.sort(fs)
        lines[#lines + 1] = "- " .. t .. " {" .. table.concat(fs, ", ") .. "}"
      end
      return table.concat(lines, "\n")
    end

    -- which need should the model work on? repairs first, then the goal, then
    -- the most-starved stimulus no blueprint answers
    local function find_need()
      for nm, c in pairs(S.children) do
        if not c.dead and alive(nm) and errs[nm] and (c.repairs or 0) < (cfg.synth_repairs or 2) then
          return { kind = "repair", key = c.key, text = c.goal, child = nm, err = errs[nm] }
        end
      end
      if cfg.mode == "directed" and cfg.goal and cfg.goal ~= "" then
        -- the evolver already weighs generic words (izle/monitor/report…) too low to pick a
        -- template on their own, so any pick here is a specific one
        local specific = next(ctx.evolver:goal_picks(cfg.goal)) ~= nil
        local key = "goal:" .. cfg.goal
        -- templates are the FLOOR: by default the model also attempts the goal itself, so
        -- a keyword hit on cpu_guard doesn't stop a purpose-built organ from being written
        -- (synth_goal_always=false restores "only when no specific template matched")
        if (cfg.synth_goal_always ~= false or not specific) and not child_for(key) then
          return { kind = "goal", key = key, text = cfg.goal }
        end
      end
      -- GOAL FIRST: while the goal's organ exists but has not produced a finding yet, spend no
      -- synthesis budget on side needs — in the trials two of six attempts per life went to a
      -- proc.sample organ nobody asked for while the goal organ waited for its third attempt
      if cfg.mode == "directed" and cfg.goal and cfg.goal ~= "" then
        local gc = child_for("goal:" .. cfg.goal)
        if gc and gc ~= true and (((mem.valued or {})[gc]) or 0) == 0 then return nil end
      end
      local worst, wn
      for t, s in pairs(ctx.bus.stats) do
        if s.unhandled_streak >= (cfg.need_threshold or 6) and not ctx.evolver:template_for(t)
           and not t:match("^self%.") and not t:match("^action%.") and not child_for("stim:" .. t) then
          if not worst or s.unhandled_streak > wn then worst, wn = t, s.unhandled_streak end
        end
      end
      if worst then
        return { kind = "stimulus", key = "stim:" .. worst, stim = worst,
                 text = "react to the '" .. worst .. "' event: read its fields from ev.data, track them across events, and report notable changes or outliers (no organ handles this event yet)" }
      end
    end

    local SYSTEM = [=[
You write Lua 5.4 plugin files ("organs") for EvoLua, an event-driven organism. Reply with ONE complete Lua file inside a ```lua fence and nothing else. Write REAL code: no placeholders, no "..." ellipses, no "TODO".

COMPLETE WORKED EXAMPLE (purpose: "watch how many users are logged in, report changes"):
```lua
local NAME = "syn_example_1"
local last_count, last_msg = nil, nil
local function count_lines(cmd)
  local n = 0
  local ok = pcall(function()
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return end
    for _ in p:lines() do n = n + 1 end
    p:close()
  end)
  return ok and n or nil
end
return {
  name = NAME, desc = "login watch: reports when the number of logged-in users changes", events = { "self.heartbeat" },
  attach = function(ctx)
    ctx.bus:subscribe("self.heartbeat", function(ev)
      local d = ev.data or {}
      if (d.tick or 0) % 10 ~= 0 then return false end
      local n = count_lines("who"); if not n then return false end
      if last_count == nil then last_count = n; return false end   -- first sample = baseline, nothing to report yet
      if n == last_count then return false end
      local msg = string.format("logged-in users %d -> %d", last_count, n)
      last_count = n
      if msg == last_msg then return false end
      last_msg = msg
      ctx.bus:emit("users.change", { from = last_count, to = n })
      ctx.report(NAME, msg)
      return { handled = true }
    end, NAME)
  end,
}
```

The example above shows only the SHAPE (baseline → compare → report only changes → handled). Its command (who) and its wording belong to the login purpose — never reuse them for a different PURPOSE. To read a number out of a line use string.match with a pattern written against the SAMPLE OUTPUT (e.g. "^(%S+)%s+(%d+)" takes the first word and the number after it), then tonumber().

API inside attach: ctx.bus:subscribe(type, fn, NAME) · ctx.bus:emit(type, table) creates a NEW stimulus type other organs can react to · ctx.report(NAME, text) writes a line into the Markdown report (THIS is how you report) · ctx.log:info(fmt, args) · ctx.kernel.tick · ctx.cfg.
Globals: string, table, math, os, io, pairs, ipairs, tostring, tonumber, pcall, type, next. io.popen(cmd) runs a shell command. There is NO require, NO load, NO dofile.
RULES:
- The PURPOSE is human language (often Turkish). Interpret its MEANING; never use its words as grep patterns, identifiers or commands. A TECHNICAL BRIEF (English) is given when available — follow it.
- A stimulus name like "proc.sample" is an event on ctx.bus, NOT a shell command: read its fields from ev.data.
- Parsing command output: anchor patterns with ^, separate fields with %s+ (columns are padded with several spaces), capture with %S+; convert with tonumber() and guard nil. Count or sum what matters (e.g. number of rows) rather than echoing rows. Lua slips that have broken organs before: `line:match(pat)` returns one value PER capture (`local a, b = line:match(pat)`); `s:gsub()` returns two values (wrap in parentheses); read the handle fully BEFORE `p:close()`; `pcall(io.popen, cmd)` returns `ok, handle`; there is NO table.find/contains/indexOf or string.split in Lua — loop instead.
- SAMPLE OUTPUT shows what each candidate command REALLY prints on this host. Pick the command whose sample actually contains the data the PURPOSE needs (e.g. TCP lines with ports); a command whose sample lacks them is useless here even if it works elsewhere. Write your patterns against the sample's exact format.
- If the PURPOSE needs information that no existing stimulus carries (network connections, listening ports, sockets, disk, users, services, processes), you MUST sense it yourself: run a read-only shell command via io.popen from "self.heartbeat" every N ticks (N>=5), parse its output, and emit your own stimulus type for what you find. Useful read-only commands: macOS/Linux "lsof -nP -i" or "netstat -an" (connections + listening ports), "ps aux", "df -k", "who", "uptime"; Windows "netstat -ano", "tasklist".
- Keep a BASELINE in local upvalues and report only CHANGES / anomalies with concrete details (addresses, ports, process names, counts, deltas). Never report the same line twice in a row. Never merely echo a stimulus payload back into the report — that is worthless and earns nothing.
- Return { handled = true } ONLY when you actually did useful work on that stimulus; otherwise return false. Fitness is earned from honest handling, not from claiming.
- "self.heartbeat" fires every tick (d.tick). Keep each handler fast (<100 ms); wrap io.popen in pcall and close the handle.
- Pass NAME as the last argument of every subscribe call.
- Never: os.exit, kill, rm, delete/rename files, sleep, infinite loops, network writes.]=]

    -- translate a (possibly Turkish, possibly vague) purpose into one English sentence of
    -- concrete technical requirements, once per need; a small model writes far better code
    -- from "count listening TCP ports via lsof -nP -iTCP -sTCP:LISTEN" than from "garip bağlantı".
    S.briefs = S.briefs or {}
    local BRIEF_SYS = "You turn a monitoring goal (any language) into ONE English sentence of concrete technical requirements for a " .. host_os ..
      " host: what to observe, which read-only shell command gives it plus ONE alternative command (both in backticks, e.g. `lsof -nP -iTCP` and `netstat -an -p tcp`), " ..
      "and what counts as an anomaly worth reporting. No code, no markdown, one sentence only."
    local function brief_for(need)
      if S.briefs[need.key] then return S.briefs[need.key] end
      local hint = need.stim and ("Goal: " .. need.text .. "\nThe event '" .. need.stim .. "' carries fields: " .. stimuli_summary():match("%- " .. need.stim:gsub("%p", "%%%0") .. " ({[^}]*})") or "") or ("Goal: " .. need.text)
      local ok, reply = pcall(cfg.llm, BRIEF_SYS, hint, 160)
      if ok and type(reply) == "string" then
        reply = reply:gsub("```.-```", ""):gsub("^%s+", ""):gsub("%s+$", "")
        reply = reply:match("^[^\n]+") or reply
        if #reply > 20 and #reply < 600 then
          S.briefs[need.key] = reply
          ctx.log:info("\27[35m✎ [%s] brief: %s\27[0m", SELF, reply)
          return reply
        end
      end
      return nil
    end

    -- PERCEIVE BEFORE CODING: a model that has never seen this host's `netstat -an`
    -- invents a parse pattern for some other OS. Run the read-only commands the brief
    -- names (allow-listed) and show the real first lines, so the parser is written
    -- against actual output.
    S.samples = S.samples or {}
    -- every sampled command runs under a wall-clock bound: a bare `top` or `iostat 1`
    -- streams forever and would hang the whole organism inside io.popen
    local BOUND_SECS = 5
    local function bounded(cmd)
      local function has(x)
        local p = io.popen("command -v " .. x .. " 2>/dev/null"); local r = p and p:read("*l"); if p then p:close() end
        return r and r ~= ""
      end
      S.bound_tool = S.bound_tool or (has("timeout") and "timeout" or (has("perl") and "perl" or "none"))
      if S.bound_tool == "timeout" then return string.format("timeout %d sh -c %q < /dev/null", BOUND_SECS, cmd) end
      if S.bound_tool == "perl" then return string.format("perl -e 'alarm shift; exec \"/bin/sh\",\"-c\",shift' %d %q < /dev/null", BOUND_SECS, cmd) end
      return cmd .. " < /dev/null"
    end
    -- run cmd bounded; returns lines (capped), timed_out
    local function run_sample(cmd, cap)
      local lines, timed_out = {}, false
      pcall(function()
        local p = io.popen(bounded(cmd .. " 2>&1")); if not p then return end
        for l in p:lines() do
          if #lines < cap and l:match("%S") then lines[#lines + 1] = (#l > 110) and (l:sub(1, 110) .. "…") or l end
        end
        local _, how, code = p:close()
        if (how == "exit" and (code == 124 or code == 142)) or (how == "signal" and code == 14) then timed_out = true end
      end)
      return lines, timed_out
    end
    -- COLUMN AWARENESS. Most sensing commands print padded tables (df, ps, netstat, who):
    -- the columns line up visually but are separated by a VARYING number of spaces, and a
    -- small model writing "^(%S+) (%d+)" against them captures the wrong field or nothing.
    -- fields(l) splits a line the way a parser should; table_shape() says whether a sample
    -- is such a table (most lines share one field count) and reads its header.
    local function fields(l)
      local f = {}
      for w in l:gmatch("%S+") do f[#f + 1] = w end
      return f
    end
    local function table_shape(lines)
      local counts, total = {}, 0
      for _, l in ipairs(lines) do
        local n = #fields(l)
        if n >= 2 then counts[n] = (counts[n] or 0) + 1; total = total + 1 end
      end
      local ncol, best = nil, 0
      for n, c in pairs(counts) do if c > best or (c == best and n > (ncol or 0)) then ncol, best = n, c end end
      if not ncol or ncol < 3 or total < 3 or best < total * 0.6 then return nil end
      -- a header = a first line whose fields are words, not numbers (±1 field: "Mounted on")
      local h = fields(lines[1])
      local header
      if math.abs(#h - ncol) <= 1 then
        local words = 0
        for _, w in ipairs(h) do if not tonumber((w:gsub("[%%,]", ""))) then words = words + 1 end end
        if words >= #h - 1 then header = h end
      end
      return { ncol = ncol, header = header }
    end
    local function column_map(shape)
      if not shape or not shape.header then return nil end
      local parts = {}
      for i, h in ipairs(shape.header) do parts[#parts + 1] = string.format("%d=%s", i, h) end
      return table.concat(parts, " ")
    end

    local function sample_commands(brief, key)
      if not brief then return nil end
      if S.samples[key] ~= nil then return S.samples[key] or nil end
      local out, seen, n = {}, {}, 0
      for cmd in brief:gmatch("`([^`\n]+)`") do
        local head = cmd:match("^%s*(%S+)")
        if head and SAMPLE_OK[head] and not seen[cmd] and n < 3 and not cmd:find("[|;&><]") then
          seen[cmd] = true; n = n + 1
          -- representative slice, not just the head: the first lines are often a header
          -- or an irrelevant section (netstat prints multipath/unix sockets too)
          local all, timed_out = run_sample(cmd, 3000)
          local lines = {}
          if timed_out then
            out[#out + 1] = string.format("$ %s   → did NOT finish within %ds: it streams forever (interactive). Use a one-shot form instead (e.g. `top -l 1 -n 10`, `iostat -c 1`, `vm_stat`).", cmd, BOUND_SECS)
          elseif #all > 0 then
            local head = math.min(6, #all)
            for i = 1, head do lines[#lines + 1] = all[i] end
            local rest = #all - head
            if rest > 0 then
              local want = math.min(14, rest)
              for k = 1, want do lines[#lines + 1] = all[head + math.floor(k * rest / want)] end
            end
            local shape = table_shape(all)
            local cols = column_map(shape)
            out[#out + 1] = string.format("$ %s   (%d lines total; REAL output on this host — header + evenly sampled lines)\n%s%s",
              cmd, #all, table.concat(lines, "\n"),
              shape and string.format("\n  ↳ this is a %d-column table padded with a VARYING number of spaces%s. Split each line with `for w in line:gmatch(\"%%S+\") do f[#f+1] = w end` and read f[k] — never count spaces, never use a single space in a pattern.",
                shape.ncol, cols and ("; columns: " .. cols) or "") or "")
          end
        end
      end
      S.samples[key] = (#out > 0) and table.concat(out, "\n\n") or false
      return S.samples[key] or nil
    end

    -- PRE-FLIGHT: before an organ is installed, try every `match("…")` pattern in its
    -- source against the REAL sample lines. A parser that matches none of them would run
    -- for 40 ticks, report nothing, be culled, and only then teach the model — this
    -- tells it in the same breath, with the real lines to fit.
    local function own_sample(code)
      local cmd = find_cmd(code)
      if not cmd then return nil end
      cmd = cmd:gsub("%s*2>%s*/dev/null%s*$", ""):gsub("%s*2>&1%s*$", "")
      local head = cmd:match("^%s*(%S+)")
      if not (head and SAMPLE_OK[head]) or cmd:find("[;&><]") then return nil end
      if S.samples["cmd:" .. cmd] ~= nil then
        local v = S.samples["cmd:" .. cmd]
        if v == "TIMEOUT" then return nil, cmd end
        return v or nil
      end
      local lines, timed_out = run_sample(cmd, 40)
      if timed_out then S.samples["cmd:" .. cmd] = "TIMEOUT"; return nil, cmd end
      S.samples["cmd:" .. cmd] = (#lines > 0) and ("$ " .. cmd .. "\n" .. table.concat(lines, "\n")) or false
      return S.samples["cmd:" .. cmd] or nil
    end

    local function preflight(code, sample)
      -- judge the parser against the output of the command the organ ACTUALLY runs;
      -- the brief's multi-command sample is only a fallback
      local own, streaming = own_sample(code)
      if streaming then
        return false, string.format("`%s` did not finish within %ds — it streams forever and would freeze the organism. Use a one-shot command (e.g. `top -l 1 -n 10`, `iostat -c 1`, `uptime`, `vm_stat`).", streaming, BOUND_SECS)
      end
      sample = own or sample
      if not sample then return true end
      local lines = {}
      for l in sample:gmatch("[^\n]+") do
        if not l:match("^%$ ") then lines[#lines + 1] = l end
      end
      if #lines < 2 then return true end
      -- COLUMN CHECK: on a padded table every capture of a pattern must be one whole
      -- field, and the SAME field on every line it matches. A capture that is a piece
      -- of a field ("3" out of "3.0Gi") or that drifts between columns (a single-space
      -- separator eats a column where the padding is one space wide) parses garbage
      -- that only shows up as nonsense reports many ticks later.
      local shape = table_shape(lines)
      if shape then
        local data = {}
        for _, l in ipairs(lines) do if #fields(l) == shape.ncol then data[#data + 1] = l end end
        for q in code:gmatch("match%s*%(%s*(%b\"\")") do
          local fn = cfg.compile("return " .. q, "=pat")
          local okp, pat = pcall(fn or function() end)
          if okp and type(pat) == "string" and pat:find("%(") then
            local cols, partial, matched = {}, 0, 0
            for _, l in ipairs(data) do
              local okm, caps = pcall(function() return { l:match(pat) } end)
              if okm and caps[1] ~= nil then
                matched = matched + 1
                local f = fields(l)
                for i, cap in ipairs(caps) do
                  local col
                  for j, w in ipairs(f) do if w == cap then col = j; break end end
                  if col then cols[i] = cols[i] or {}; cols[i][col] = true else partial = partial + 1 end
                end
              end
            end
            if matched >= 2 then
              local drift
              for i, set in pairs(cols) do
                local n = 0; for _ in pairs(set) do n = n + 1 end
                if n > 1 then drift = i end
              end
              if drift or partial > matched * 0.3 then
                local map = column_map(shape)
                return false, string.format(
                  "pattern %s does not read the table correctly: %s. The output is a %d-column table padded with a varying number of spaces%s. Split each line into fields with `local f = {} for w in line:gmatch(\"%%S+\") do f[#f+1] = w end`, pick the field by index (f[k]) and tonumber() it (strip units with gsub first) — do not count spaces or use a single space in a pattern. Real lines:\n%s",
                  q, drift and ("capture " .. drift .. " lands on different columns on different lines") or "its captures are pieces of fields, not whole fields",
                  shape.ncol, map and ("; columns: " .. map) or "", table.concat({ data[1], data[2] or "", data[3] or "" }, "\n"))
              end
            end
          end
        end
      end
      local pats = {}
      local quoted = {}
      for q in code:gmatch("match%s*%(%s*(%b\"\")") do quoted[#quoted + 1] = q end
      for q in code:gmatch("match%s*%([^,\n]-,%s*(%b\"\")") do quoted[#quoted + 1] = q end
      for _, q in ipairs(quoted) do
        local fn = cfg.compile("return " .. q, "=pat")
        local okp, pat = pcall(fn or function() end)
        if okp and type(pat) == "string" and #pat > 3 and not pats[pat] then pats[pat] = 0; pats[#pats + 1] = pat end
      end
      if #pats == 0 then return true end
      local data = #lines
      local best, best_pat = 0, pats[1]
      for _, pat in ipairs(pats) do
        for i = 1, #lines do
          local okm, m = pcall(string.match, lines[i], pat)
          if okm and m ~= nil then pats[pat] = pats[pat] + 1 end
        end
        if pats[pat] > best then best, best_pat = pats[pat], pat end
      end
      local ratio = best / math.max(1, data)
      -- a tabular parser should fit most data lines; an anchored pattern may legitimately
      -- select a subset (e.g. only LISTEN rows), an unanchored one matching a few lines is
      -- almost always a substring hit on the wrong columns
      if best >= 1 and (ratio >= 0.3 or best_pat:sub(1, 1) == "^" or #lines <= 6) then return true end
      local shown = {}
      for i = 2, math.min(#lines, 4) do shown[#shown + 1] = lines[i] end
      local plist = {}
      for _, pat in ipairs(pats) do plist[#plist + 1] = string.format("%q", pat) end
      return false, string.format("your pattern(s) %s fit only %d of %d REAL output lines (accidental mid-line matches are not a parser). Anchor with ^, separate fields with %%s+ not a single space, prefer %%S+ over %%d+, and fit these lines exactly:\n%s",
        table.concat(plist, ", "), best, data, table.concat(shown, "\n"))
    end

    local function user_prompt(need, name, feedback)
      local parts = {}
      parts[#parts + 1] = "Host OS: " .. host_os .. ". Organ NAME to use: " .. name .. "."
      parts[#parts + 1] = "PURPOSE: " .. need.text
      local brief = brief_for(need)
      if brief then parts[#parts + 1] = "TECHNICAL BRIEF: " .. brief end
      local sample = sample_commands(brief, need.key)
      if sample then parts[#parts + 1] = "SAMPLE OUTPUT — write your parsing patterns against exactly this format:\n" .. sample end
      if need.stim then parts[#parts + 1] = "Subscribe to '" .. need.stim .. "' ONLY — one handler, it already fires regularly. Keep the file short." end
      parts[#parts + 1] = "Live stimuli and real payload fields seen so far:\n" .. stimuli_summary()
      if feedback then parts[#parts + 1] = feedback end
      parts[#parts + 1] = "Write the complete file now."
      return table.concat(parts, "\n\n")
    end

    -- word boundaries include `_` so sense_load( / proc_kill_count don't trip the denylist
    local DENY = { "os%.exit", "os%.remove", "os%.rename", "%f[%w_]kill%f[^%w_]", "rm %-rf", "%f[%w_]rm %-", "shutdown",
                   "reboot", "mkfs", "dd if=", "while%s+true%s+do", "%f[%w_]sleep%f[^%w_]", "require%s*%(",
                   "%f[%w_]load%s*%(", "dofile", "loadstring", "curl .*%-X", "wget ",
                   "popen%s*%([^)]*evolua", "popen%s*%([^)]*lua " }   -- never spawn another organism / interpreter

    local function extract(reply)
      local code = reply:match("```[Ll]ua%s*\n(.-)```") or reply:match("```%s*\n(.-)```")
        or reply:match("```[Ll]ua%s*\n(.*)$") or reply:match("```%s*\n(.*)$") or reply
      return (code:gsub("^%s+", ""))
    end

    local function validate(code, name)
      if not code:find("return%s*{") then return nil, "no `return { ... }` spec table" end
      if not code:find("attach%s*=") then return nil, "spec has no attach function" end
      if code:find("%.%.%.") then return nil, "contains `...` — that is a placeholder, not Lua; write the real code" end
      if code:find("TODO") then return nil, "contains TODO — write the real code" end
      for _, pat in ipairs(DENY) do
        if code:find(pat) then return nil, "forbidden construct matched: " .. pat end
      end
      code = code:gsub('NAME%s*=%s*"[^"]*"', 'NAME = "' .. name .. '"', 1)
      code = code:gsub('name%s*=%s*"[^"]*"', 'name = "' .. name .. '"', 1)
      local fn, err = cfg.compile(code, name)
      if not fn then return nil, "syntax error: " .. tostring(err) end
      return code
    end

    local function install(code, name, need)
      local path = cfg.plugins_dir .. "/" .. name .. ".lua"
      local fh = io.open(path, "w"); if not fh then return false, "cannot write " .. path end
      fh:write(string.format("-- SYNTHESIZED ORGAN: %s\n-- purpose: %s\n-- written by model: %s at %s\n",
        name, need.text, tostring(cfg.llm_active() or "?"), os.date("%Y-%m-%d %H:%M:%S")))
      fh:write(code); fh:close()
      local before = {}; for k in pairs(ctx.registry.loaded) do before[k] = true end
      errs[name] = nil
      local ok = ctx.registry:load(path)
      if not ok or not alive(name) then
        for k, r in pairs(ctx.registry.loaded) do           -- a stray spec under another name
          if not before[k] and r.alive then ctx.registry:retire(k, "synth: name mismatch", false) end
        end
        os.remove(path)
        return false, errs[name] or "load/attach failed"
      end
      local subs = 0
      for _, list in pairs(ctx.bus.subs) do
        for _, h in ipairs(list) do if h.owner == name then subs = subs + 1 end end
      end
      if subs == 0 then
        ctx.registry:retire(name, "synth: no subscriptions", true)
        return false, "the organ subscribed to nothing under its own NAME"
      end
      return true, path
    end

    local function read_src(path)
      local fh = io.open(path, "r"); if not fh then return "" end
      local s = fh:read("*a"); fh:close()
      return #s > 2500 and (s:sub(1, 2500) .. "\n-- [truncated]") or s
    end

    -- one-line fingerprint of what an attempt did, so the next attempt can be told
    -- NOT to do the same thing again (otherwise a small model rewrites the same organ)
    local function describe_approach(src)
      local evs = src:match("events%s*=%s*{([^}]*)}") or ""
      local list = {}
      for e in evs:gmatch('"([^"]+)"') do list[#list + 1] = e end
      local parts = { "subscribed to " .. (#list > 0 and table.concat(list, ", ") or "nothing") }
      local cmd = find_cmd(src)
      parts[#parts + 1] = cmd and ("sensed via shell `" .. cmd .. "`") or "ran NO shell command (sensed nothing new)"
      local pat = src:match('match%s*%(%s*(%b"")') or src:match('match%s*%([^,\n]-,%s*(%b"")')
      if pat then parts[#parts + 1] = "parsed with " .. pat end
      -- event-driven organs run no command: what distinguishes them is WHICH payload fields they use
      local fields, seen = {}, {}
      for f in src:gmatch("%f[%w_]d%.([%a_][%w_]*)") do
        if not seen[f] and f ~= "tick" then seen[f] = true; fields[#fields + 1] = f end
      end
      table.sort(fields)
      if #fields > 0 then parts[#parts + 1] = "used fields " .. table.concat(fields, ",") end
      parts[#parts + 1] = src:find("handled%s*=%s*true") and "returned handled=true" or "never returned handled=true"
      parts[#parts + 1] = src:find("bus:emit") and "emitted its own stimulus" or "emitted nothing"
      return table.concat(parts, "; ")
    end

    local function remember_failure(key, why, src)
      local f = S.failures[key] or { tried = {} }
      f.tried = f.tried or {}
      -- a crash is a coding slip, not a wrong approach: the next attempt may keep the approach
      -- and fix the code. Only approaches that RAN and earned nothing are banned from repeating.
      local crashed = why:find("throwing") or why:find("crashed")
      if not crashed then f.tried[#f.tried + 1] = describe_approach(src) end
      while #f.tried > 4 do table.remove(f.tried, 1) end
      f.why, f.src = why, src
      S.failures[key] = f
    end

    local function failure_feedback(f)
      local lines = { "ALL previous attempts at this purpose were retired. Last one: " .. tostring(f.why) }
      if f.tried and #f.tried > 0 then
        lines[#lines + 1] = "Approaches already tried and FAILED — do NOT repeat any of them:"
        for i, t in ipairs(f.tried) do lines[#lines + 1] = string.format("  %d) %s", i, t) end
      end
      lines[#lines + 1] = "Take a genuinely different route: sense the real thing the PURPOSE names (run a shell command if no stimulus carries it), keep a baseline, report only anomalies, return { handled = true } when you did."
      if f.src and f.src ~= "" then lines[#lines + 1] = "Last failed source, for reference only:\n" .. f.src end
      return table.concat(lines, "\n")
    end

    -- one synthesis cycle: ask → validate → (one retry with the error) → install
    local function synthesize(need, tick)
      local name
      if need.kind == "repair" then name = need.child
      else S.n = S.n + 1; name = string.format("syn_%s_%d", slug(need.text), S.n) end
      local feedback
      if need.kind == "repair" then
        local c = S.children[name]
        local src = read_src(c.path)
        local ln = tonumber(tostring(need.err):match(":(%d+):"))
        local culprit = ""
        if ln then
          local i = 0
          for line in (src .. "\n"):gmatch("([^\n]*)\n") do
            i = i + 1
            if i == ln then culprit = line; break end
          end
        end
        feedback = "Your previous version of this organ (below) threw at runtime:\n" .. tostring(need.err) ..
          (culprit ~= "" and ("\nThe failing line " .. ln .. " is:\n    " .. culprit) or "") ..
          "\nCommon causes: a `local` declared inside a function/pcall body is nil outside it (return it instead);" ..
          " a field that is a table was used as a string; a pattern matched nothing so a capture is nil (guard with `if x then`);" ..
          " `s:gsub(...)` returns TWO values — write `(s:gsub(...))` in parentheses before tonumber()/format(); " ..
          "read ALL output first (`local out = p:read(\"*a\")` or a `for line in p:lines()` loop) and only THEN `p:close()` — a closed handle cannot be read; " ..
          "`line:match(pat)` with N captures returns N separate values — assign `local a, b, c = line:match(pat)`, never one variable indexed like a table; " ..
          "the Lua standard library has NO table.find / table.findsub / table.contains / table.indexOf / string.split — write a small loop instead." ..
          "\nFix it and return the whole corrected file.\n\n" .. src
      elseif S.failures[need.key] then
        feedback = failure_feedback(S.failures[need.key])
      end
      local code, why
      local tried = S.failures[need.key] and S.failures[need.key].tried or {}
      for try = 1, (need.kind == "repair" and 2 or 3) do
        local t0 = os.time()
        local reply = cfg.llm(SYSTEM, user_prompt(need, name, feedback), genes.tokens or cfg.synth_tokens or 900)
        local secs = os.time() - t0
        if not reply then why = "brain returned nothing"; break end
        code, why = validate(extract(reply), name)
        if not code then
          local tail = reply:gsub("%s+", " "):sub(-160)
          ctx.log:debug("✎ [%s] rejected reply tail: …%s", SELF, tail)
          if why:find("no `return") and not reply:find("```%s*$") then
            why = why .. " (your reply was cut off before the spec table — write a SHORTER file: one small helper at most, then the return table)"
          end
        end
        if code then
          local okf, whyf = preflight(code, S.samples[need.key] or nil)
          if not okf then code, why = nil, whyf end
        end
        if code and cfg.dryrun then
          -- RUN it once before trusting it: real payloads for its events, two heartbeats
          local payloads = {}
          for i = #ctx.bus.history, 1, -1 do
            local ev = ctx.bus.history[i]
            if not payloads[ev.type] then payloads[ev.type] = ev.data end
          end
          local t1 = os.time()
          local okr, whyr = cfg.dryrun(code:gsub('NAME%s*=%s*"[^"]*"', 'NAME = "' .. name .. '"', 1), name, payloads)
          if not okr then
            local ln = tonumber(tostring(whyr):match(":(%d+):"))
            local culprit = ""
            if ln then
              local i = 0
              for line in (code .. "\n"):gmatch("([^\n]*)\n") do i = i + 1; if i == ln then culprit = line; break end end
            end
            code, why = nil, "it ran but threw: " .. tostring(whyr) ..
              (culprit ~= "" and ("\n    failing line " .. ln .. ": " .. culprit) or "") ..
              "\nRemember: gsub returns two values; read a handle fully before close(); one variable per capture; no table.find/contains; a field that prints as table: is a TABLE."
            ctx.log:debug("✎ [%s] dry run failed (%ds): %s", SELF, os.time() - t1, tostring(whyr))
          end
        end
        if code and need.kind ~= "repair" then
          -- the model must not hand back a clone of something selection already killed
          local fp = describe_approach(code)
          for i, t in ipairs(tried) do
            if t == fp then
              code, why = nil, string.format("this is the SAME approach as failed attempt %d (%s); change the command, the parsing or the strategy", i, t)
              break
            end
          end
        end
        ctx.log:info("\27[35m✎ [%s] %s '%s' try %d: %s (%ds)\27[0m", SELF, need.kind, name, try,
          code and "compiles" or ("rejected — " .. tostring(why)), secs)
        if code then break end
        feedback = (feedback and (feedback .. "\n\n") or "") .. "Your previous reply was rejected: " .. why ..
          "\nReturn the whole file again, fixed."
      end
      if not code then
        ctx.report(SELF, string.format("synthesis failed for '%s': %s", need.text, tostring(why)))
        if why and why:find("SAME approach") then           -- the model cannot vary: back off on this need
          S.cooldown = S.cooldown or {}
          S.cooldown[need.key] = tick + 3 * (genes.every or 40)
          ctx.log:info("\27[35m✎ [%s] backing off '%s' until tick %d (model keeps repeating a failed approach)\27[0m", SELF, need.text, S.cooldown[need.key])
        end
        return false
      end
      if need.kind == "repair" then ctx.registry:retire(name, "synth: repairing", false) end
      local ok, info = install(code, name, need)
      if ok then
        -- the evolver may also have adopted this child (rehydrate); its cull must see a newborn
        local er = ctx.evolver and ctx.evolver.organs and ctx.evolver.organs[name]
        if er then er.born_tick = tick end
        if need.kind == "repair" then
          local c = S.children[name]; c.repairs = (c.repairs or 0) + 1; c.born = tick; c.src = read_src(c.path)
          ctx.report(SELF, string.format("repaired organ %s (attempt %d) for '%s'", name, c.repairs, need.text))
        else
          S.children[name] = { key = need.key, goal = need.text, path = info, born = tick, repairs = 0, src = read_src(info) }
          ctx.memory:record_birth({ organ = name, template = "synth:llm", genes = { goal = need.text }, lineage = SELF })
          ctx.memory:reward(name, 1)
          ctx.report(SELF, string.format("synthesized organ %s for '%s' (model: %s)", name, need.text,
            tostring(cfg.llm_active() or "?")))
          ctx.log:info("\27[35m✦ [%s] synthesized organ '%s' ← \"%s\"\27[0m", SELF, name, need.text)
        end
        return true
      end
      ctx.report(SELF, string.format("synthesized organ %s failed to load: %s", name, tostring(info)))
      if need.kind == "repair" then
        local c = S.children[name]; c.dead = true
        remember_failure(c.key, "crashed on load after repair: " .. tostring(info), read_src(c.path))
      end
      return false
    end

    -- SELECTION over the children: honest fitness decides who stays
    local function select_children(tick)
      for nm, c in pairs(S.children) do
        if not c.dead then
          if not alive(nm) then
            c.dead = true                                   -- retired elsewhere (evolver cull, user)
            if c.src and c.src ~= "" and not (S.failures[c.key] and S.failures[c.key].src == c.src) then
              local why = errs[nm]
                and ("crashed (" .. tostring(errs[nm]) .. ") and was culled after " .. (tick - (c.born or tick)) .. " ticks")  -- a slip, not a wrong approach
                or string.format("culled by selection after %d ticks: it earned no fitness (its handlers fired but did nothing the organism values)", tick - (c.born or tick))
              remember_failure(c.key, why, c.src)
            end
          else
            local age = tick - (c.born or tick)
            local fit = mem.fitness[nm] or 0
            local exhausted = errs[nm] and (c.repairs or 0) >= (cfg.synth_repairs or 2)
            -- "doing its job" = more findings than noise; a chatterbox with a few lucky hits is not spared
            local valued, stale = ((mem.valued and mem.valued[nm]) or 0), ((mem.stale and mem.stale[nm]) or 0)
            local working = valued > 0 and stale <= (cfg.report_noise_ratio or 4) * valued
            if exhausted or (not working and age > (cfg.synth_grace or 40) and fit < (cfg.retire_floor or 0.5)) then
              local src = read_src(c.path); if src == "" then src = c.src or "" end
              local why
              if exhausted then
                why = "kept throwing after repairs: " .. tostring(errs[nm])
              else
                -- say precisely what went wrong, so the next attempt can fix THAT
                local silent = {}
                for e in (src:match("events%s*=%s*{([^}]*)}") or ""):gmatch('"([^"]+)"') do
                  local st = ctx.bus.stats[e]
                  if not st or st.fired == 0 then silent[#silent + 1] = e end
                end
                if #silent > 0 then
                  why = string.format("earned no fitness in %d ticks: it watched stimuli that never fire (%s)", age, table.concat(silent, ", "))
                elseif not src:find("handled%s*=%s*true") then
                  why = string.format("earned no fitness in %d ticks: its handlers never return { handled = true }", age)
                else
                  why = string.format("earned no fitness in %d ticks: its handlers fired but did nothing the organism values (echoing payloads is worthless; sense and report real anomalies)", age)
                end
              end
              remember_failure(c.key, why, src)
              ctx.registry:retire(nm, "synth: " .. (exhausted and "unrepairable" or "low fitness"), true)
              c.dead = true
              ctx.report(SELF, string.format("retired synthesized organ %s — %s", nm, why))
            end
          end
        end
      end
    end

    ctx.bus:subscribe("self.error", function(ev)
      local d = ev.data or {}
      if type(d.owner) == "string" and d.owner:match("^syn_") then errs[d.owner] = tostring(d.err) end
      return false
    end, SELF)

    ctx.bus:subscribe("self.heartbeat", function(ev)
      local tick = ev.data.tick or ctx.kernel.tick
      if tick % 5 == 0 then select_children(tick) end
      if tick - last_try < (genes.every or 40) then return false end
      if attempts >= (cfg.synth_max or 6) then return false end
      if not cfg.llm or not cfg.llm_active or not cfg.llm_active() then return false end
      local need = find_need()
      if not need then return false end
      last_try = tick; attempts = attempts + 1
      ctx.log:info("\27[35m✎ [%s] need (%s): %s\27[0m", SELF, need.kind, need.text)
      synthesize(need, tick)
      return { handled = true, reward = 2 }
    end, SELF)
  ]==]
    return render(name, "synthesizer: the brain writes new organs for needs no blueprint covers",
      { "self.heartbeat", "self.error" }, genes, body)
  end,
}

return T
