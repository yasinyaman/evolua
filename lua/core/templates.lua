-- core/templates.lua — genome blueprints the evolver uses to grow new organs
-- Each template knows: which stimulus it answers, the genes (tunable params)
-- it exposes, and how to render itself into a standalone plugin .lua file.
-- New capabilities are BORN here as source code, not hand-written.

local EU = require("core.evo_util")   -- shared ES kernel (es_step) for rule thresholds

local function literal(genes)
  -- render a flat genes table as a Lua literal
  local parts = {}
  for k, v in pairs(genes) do
    local val = type(v) == "string" and string.format("%q", v) or tostring(v)
    parts[#parts + 1] = string.format("%s = %s", k, val)
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
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
-- triggers="colony.tick" is synthetic (nothing ever emits it), so the evolver's
-- free-drive can never grow a self-replicator by accident; the organ is seeded
-- explicitly by main.lua, or grown in directed mode by a matching goal keyword.
-- It listens on the REAL clock (self.heartbeat) at runtime regardless. The
-- population SAFETY caps live in cfg (NOT in genes) so mutation can tune the
-- comms/clone cadences but can never loosen the bounds.
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

    -- VERTICAL GENE TRANSFER (#11): serialize a flat gene/sigma table to a Lua
    -- literal, and find the parent's FITTEST living organ for the goal's template so
    -- the child inherits TUNED genes (+ learned ES steps), not template defaults.
    -- Best-effort: nil if the parent serves no organ of that template (e.g. an
    -- explore-goal niche it doesn't occupy yet) → child starts fresh, as before.
    local function ser_flat(t)
      if not t then return "nil" end
      local parts = {}
      for k, v in pairs(t) do
        local val = (type(v) == "string") and string.format("%q", v) or tostring(v)
        parts[#parts + 1] = string.format("[%q]=%s", tostring(k), val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
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
            if pf and pf > mybest + (cfg.hgt_margin or 2)
               and ctx.evolver:population(tmpl) < (cfg.max_per_template or 3) then
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
                "return { [%q] = { genes = %s, sigma = %s } }\n", itmpl, ser_flat(igenes), ser_flat(isigma)))
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
-- synthetic (never emitted) so free-drive can't grow it; it is seeded in main.lua.
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
-- synthetic "explore.tick"; seeded in main.lua.
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

    local MOD = { "fs", "log", "net", "cmd", "sys" }
    local modal_i, sys_done, tools_done = 0, false, false

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
  return render(name, "rule organ (evolved reflex on " .. stim .. ")", { stim }, {}, body)
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

return T
