-- core/templates.lua — genome blueprints the evolver uses to grow new organs
-- Each template knows: which stimulus it answers, the genes (tunable params)
-- it exposes, and how to render itself into a standalone plugin .lua file.
-- New capabilities are BORN here as source code, not hand-written.

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
local function guard(metric_event, field, label)
  return {
    triggers = metric_event,
    goal_keywords = { "kaynak", "resource", "cpu", "memory", "bellek", "yük", "load", "izle", "monitor", "guard" },
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

T["cpu_guard"]  = guard("metric.cpu",  "pct", "CPU")
T["mem_guard"]  = guard("metric.mem",  "pct", "MEM")
T["load_guard"] = guard("metric.load", "one", "LOAD")

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
  goal_keywords = {
    "çoğal", "klon", "clone", "replicate", "replikasyon", "kopya", "üre",
    "koloni", "colony", "iletişim", "haberleş", "communicate", "mesaj", "message",
  },
  default_genes = { link_every = 5, clone_every = 15, clone_cooldown = 30, peer_ttl = 30 },
  build = function(name, genes)
    local body = "local SELF = " .. string.format("%q", name) .. "\n" .. [==[
    local cfg = ctx.cfg
    local function win() return cfg.is_windows end
    local function shq(s) s = tostring(s); return '"' .. s:gsub('"', '\\"') .. '"' end
    local function ensure_dir(p)
      if win() then os.execute('mkdir ' .. shq(p) .. ' 2>nul')
      else os.execute('mkdir -p ' .. shq(p) .. ' 2>/dev/null') end
    end
    local function list_dir(p)
      local cmd = win() and ('dir /b ' .. shq(p) .. ' 2>nul')
                          or  ('ls -1 ' .. shq(p) .. ' 2>/dev/null')
      local out = {}
      local fh = io.popen and io.popen(cmd)
      if not fh then return out end
      for line in fh:lines() do if line ~= "" then out[#out + 1] = line end end
      fh:close()
      return out
    end
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

    -- aggregate the colony's harvested outcomes: goal -> {sum, n} (the S4 ledger)
    local function read_outcomes()
      local dir, agg = root() .. "/colony/outcomes", {}
      for _, fn in ipairs(list_dir(dir)) do
        local txt = read_file(dir .. "/" .. fn)
        local g = txt and txt:match("purpose=([^\n]+)")
        local p = txt and tonumber(txt:match("payoff=([%d%.%-]+)"))
        if g and p then
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
      if cfg.goal and cfg.goal ~= "" and cfg.purpose_learn ~= false then
        local odir = cdir .. "/outcomes"
        ensure_dir(odir)
        write_file(odir .. "/" .. mid,
          string.format("purpose=%s\npayoff=%.2f\ngen=%d\nat=%d\n", cfg.goal, purpose_payoff(), gen(), now))
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
            local flags = " --colony-id " .. cid
              .. " --generation " .. tostring(gen() + 1)
              .. " --colony-root " .. shq(root())
              .. " --ticks " .. tostring(cfg.clone_child_ticks or 40)
              .. " --tick-seconds " .. tostring(cfg.tick_seconds or 1)
              .. " --no-clone"                           -- children don't replicate (star colony)
              .. (goal and (" --goal " .. shq(goal)) or "")  -- born specialized, or generalist
            local cmd
            if win() then
              cmd = 'cmd /c start "" /B cmd /c "set EVOLUA_HOME=' .. chome .. '&& ' .. prog .. flags .. '"'
            elseif cfg.embedded then
              cmd = 'EVOLUA_HOME=' .. shq(chome) .. ' ' .. shq(prog) .. flags .. ' >/dev/null 2>&1 &'
            else
              cmd = 'lua -e ' .. shq("EVOLUA_HOME='" .. chome .. "'") .. ' ' .. shq(prog) .. flags .. ' >/dev/null 2>&1 &'
            end
            local reasons = {}
            if why.eager then reasons[#reasons + 1] = "eager" end
            if why.needs then reasons[#reasons + 1] = "needs=" .. why.needs end
            if why.brain then reasons[#reasons + 1] = string.format("fallback=%.0f%%", why.brain * 100) end
            if why.hot   then reasons[#reasons + 1] = "hot=" .. why.hot end
            local rtext = table.concat(reasons, " ")
            local ptext = goal and ("purpose: " .. goal .. (last_why ~= "" and (" [" .. last_why .. "]") or "")) or "generalist"
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
  goal_keywords = {
    "keşif", "keşfet", "explore", "discover", "ortam", "environment", "tara", "scan", "merak",
  },
  default_genes = { explore_every = 7, depth = 2, breadth = 6 },
  build = function(name, genes)
    local body = "local SELF = " .. string.format("%q", name) .. "\n" .. [==[
    local cfg = ctx.cfg
    local function shq(s) s = tostring(s); return '"' .. s:gsub('"', '\\"') .. '"' end
    local function run(cmd)
      local p = io.popen and io.popen(cmd); if not p then return "" end
      local o = p:read("*a") or ""; p:close(); return o
    end
    local function lines_of(cmd)
      local out = {}; for l in run(cmd):gmatch("[^\n]+") do out[#out + 1] = l end; return out
    end
    local function contains(t, v) for _, x in ipairs(t or {}) do if x == v then return true end end return false end
    -- skip the organism's OWN output dirs (no self-referential perception loops)
    -- and known-huge build/vcs dirs (don't drown fswatch).
    local SKIP = { target = true, [".git"] = true, node_modules = true, build = true,
                   [".cargo"] = true, dist = true, [".svn"] = true, [".hg"] = true, ["__pycache__"] = true }
    local function skip_dir(path)
      for seg in path:gmatch("[^/]+") do if SKIP[seg] then return true end end  -- any huge/vcs segment
      -- skip the organism's OWN data home (explore OUTWARD, not self-referentially)
      for _, d in ipairs({ cfg.colony_root, cfg.plugins_dir, cfg.reports_dir, cfg.state_dir }) do
        if d and d ~= "" and path:sub(1, #d) == d then return true end
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
          for _, d in ipairs(lines_of("find " .. shq(root) .. " -mindepth 1 -maxdepth " ..
              tostring(genes.depth or 2) .. " -type d 2>/dev/null | head -n 100")) do
            if not skip_dir(d) and not contains(cfg.watch_dirs, d) then
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
          for _, f in ipairs(lines_of("find " .. shq(root) .. " -maxdepth 3 -type f -name '*.log' 2>/dev/null | head -n 50")) do
            if not skip_dir(f) and not contains(cfg.watch_logs, f) then
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
        local raw = run("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null")
        if raw == "" then raw = run("netstat -an 2>/dev/null | grep -i listen") end
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
            local lister = cfg.is_windows and ("dir /b " .. shq(dir) .. " 2>nul")
                                            or  ("ls -1 " .. shq(dir) .. " 2>/dev/null")
            for f in run(lister):gmatch("[^\n]+") do
              if f ~= "" and not seen[f] then seen[f] = true; n = n + 1 end
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
          local u = run("uname -srm 2>/dev/null"):gsub("%s+$", "")
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

return T
