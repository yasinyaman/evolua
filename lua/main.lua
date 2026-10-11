#!/usr/bin/env lua
-- main.lua — EvoLua entry point
-- A tiny self-evolving organism: it perceives its environment, reacts, grows
-- new organs (plugins) when it meets a need it can't yet handle, evolves them
-- under selection pressure, and reports back.
--
-- Usage (from the repo root; any working directory works — module paths
-- resolve relative to this file):
--   lua lua/main.lua                         # free mode, lives indefinitely
--   lua lua/main.lua --mode directed --goal "report errors"
--   lua lua/main.lua --ticks 60              # bounded run (good for trying it out)
--   lua lua/main.lua --tick-seconds 0.2 --ticks 100   # fast demo

-- make `require("core.x")` / `require("sensors.x")` work regardless of cwd.
-- (In the single-binary build these modules come from package.preload, injected
--  by the Rust host; this path setup is for running under a plain `lua`.)
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = HERE .. "/?.lua;" .. HERE .. "/?/init.lua;" .. package.path

local cfg = require("config")

-- Where the organism keeps its body parts & memory.
--   * single-binary build: EVOLUA_HOME is injected by the host (an OS-appropriate
--     writable data dir, e.g. ~/Library/Application Support/EvoLua, or $EVOLUA_HOME).
--   * plain `lua` run: a global EVOLUA_HOME (lua -e "EVOLUA_HOME='…'"), else the
--     $EVOLUA_HOME env var — the same one clean.sh reads — else the script directory.
local function nonempty(s) return s ~= nil and s ~= "" and s or nil end
local BASE = nonempty(rawget(_G, "EVOLUA_HOME")) or nonempty(os.getenv("EVOLUA_HOME")) or HERE

-- resolve relative state/perception paths against BASE, so the organism finds
-- its body parts no matter the current working directory or launch method.
local function abs(p)
  if p:match("^/") or p:match("^%a:[/\\]") then return p end -- already absolute
  return BASE .. "/" .. p
end
cfg.plugins_dir = abs(cfg.plugins_dir)
cfg.reports_dir = abs(cfg.reports_dir)
cfg.state_dir   = abs(cfg.state_dir)
for i, d in ipairs(cfg.watch_dirs) do cfg.watch_dirs[i] = abs(d) end
for i, f in ipairs(cfg.watch_logs) do cfg.watch_logs[i] = abs(f) end

-- VERTICAL GENE TRANSFER (#11): a clone's parent colony writes <home>/inherited.lua
-- with its best genes for the child's goal template. Load it onto cfg so the directed
-- drive grows that organ PRE-TUNED instead of from template defaults.
do
  local fh = io.open(BASE .. "/inherited.lua", "r")
  if fh then
    local src = fh:read("*a"); fh:close()
    local chunk = load(src, "inherited", "t", {})
    if chunk then
      local ok, t = pcall(chunk)
      if ok and type(t) == "table" then cfg.inherited_genes = t end
    end
  end
end

-- Unattended operation is OPT-IN (--unattended or EVOLUA_UNATTENDED=1): act on its
-- own (reversible, safe-listed verbs only) and acquire a better decision model
-- without approval. One switch, so the three settings can't drift apart.
local function unattended()
  cfg.autonomy_ceiling = "act"
  cfg.model_unattended = true
  for _, v in ipairs(cfg.safe_actions) do
    if v == "model_upgrade" then return end
  end
  table.insert(cfg.safe_actions, "model_upgrade")
end
if os.getenv("EVOLUA_UNATTENDED") == "1" then unattended() end
if (os.getenv("EVOLUA_BRAIN") or "") ~= "" then cfg.brain = os.getenv("EVOLUA_BRAIN") end

-- ---- minimal flag parser -------------------------------------------------
-- A bad command line stops the organism before it lives (exit 2): `--ticks abc`
-- used to become nil and silently mean "live forever".
local function die(msg)
  io.stderr:write("evolua: " .. msg .. " (try --help)\n")
  os.exit(2)
end

local function is_int(n) return n % 1 == 0 end
local POSITIVE_INT = { "a positive integer", function(n) return n >= 1 and is_int(n) end }
local NONNEG_INT   = { "a non-negative integer", function(n) return n >= 0 and is_int(n) end }
local NONNEG_NUM   = { "a non-negative number", function(n) return n >= 0 end }

local function parse(args)
  local i = 1
  while i <= #args do
    local a = args[i]
    -- the flag's value: the next argument, which must exist and not be a flag
    local function val()
      i = i + 1
      local v = args[i]
      if v == nil or v:sub(1, 2) == "--" then die(a .. " needs a value") end
      return v
    end
    local function num(kind)
      local v = val()
      local n = tonumber(v)
      if not n or n ~= n or n == math.huge or n == -math.huge or not kind[2](n) then
        die(string.format("%s expects %s, got '%s'", a, kind[1], v))
      end
      return n
    end
    local function word(...)
      local v = val()
      for _, w in ipairs({ ... }) do if v == w then return v end end
      die(string.format("%s expects one of %s, got '%s'", a, table.concat({ ... }, "|"), v))
    end
    if a == "--mode" then cfg.mode = word("free", "directed")
    elseif a == "--goal" then cfg.mode = "directed"; cfg.goal = val()
    elseif a == "--ticks" then cfg.max_ticks = num(POSITIVE_INT)
    elseif a == "--tick-seconds" then cfg.tick_seconds = num(NONNEG_NUM)
    elseif a == "--evolve-every" then cfg.evolve_every = num(POSITIVE_INT)
    elseif a == "--watch-dir" then table.insert(cfg.watch_dirs, val())
    elseif a == "--watch-log" then table.insert(cfg.watch_logs, val())
    elseif a == "--log-level" then cfg.log_level = word("debug", "info", "warn", "error")
    elseif a == "--autonomy" then cfg.autonomy_ceiling = word("learn", "report", "notify", "suggest", "act")
    elseif a == "--unattended" then unattended()
    elseif a == "--brain" then cfg.brain = word("auto", "rules", "remote", "gguf", "embedded", "service", "apple")
    -- online brain
    elseif a == "--llm-api" then
      local v = val()
      -- "off" / "none" / "0" / "false" read as --no-llm-api (otherwise they'd be taken for a URL)
      if ({ off = 1, none = 1, no = 1, ["0"] = 1, ["false"] = 1 })[v:lower()] then cfg.llm_api = false else cfg.llm_api = v end
    elseif a == "--no-llm-api" then cfg.llm_api = false
    elseif a == "--no-llm-keyless" then cfg.llm_keyless = false
    elseif a == "--llm-model" then cfg.llm_api_model = val()
    elseif a == "--llm-key-env" then cfg.llm_key_env = val()
    elseif a == "--llm-budget" then cfg.llm_remote_budget = num(POSITIVE_INT)
    -- local brain
    elseif a == "--model" then cfg.model_path = val()
    elseif a == "--model-dir" then table.insert(cfg.model_dirs, val())
    elseif a == "--model-max-mb" then cfg.model_max_mb = num(POSITIVE_INT)
    elseif a == "--no-model-discover" then cfg.model_discover = false
    elseif a == "--model-ignore-battery" then cfg.model_ignore_battery = true
    elseif a == "--model-force-upgrade" then cfg.model_force_upgrade = true
    elseif a == "--no-synth" then cfg.synth = false
    -- mesh (the host-side nerve parses these too; here they only need to be known)
    elseif a == "--mesh" then cfg.mesh = true
    elseif a == "--no-mesh" then cfg.mesh = false
    elseif a == "--mesh-port" then cfg.mesh = true; cfg.mesh_port = num(POSITIVE_INT)
    elseif a == "--mesh-gateway" then cfg.mesh = true; cfg.mesh_gateway = true
    elseif a == "--mesh-seed" then cfg.mesh = true; cfg.mesh_seeds = cfg.mesh_seeds or {}; table.insert(cfg.mesh_seeds, val())
    -- colony / self-replication
    elseif a == "--clone" then cfg.clone_enabled = true
    elseif a == "--no-clone" then cfg.clone_enabled = false
    elseif a == "--clone-eager" then cfg.clone_require_pressure = false
    elseif a == "--clone-ignore-battery" then cfg.clone_ignore_battery = true
    elseif a == "--clone-generalist" then cfg.purpose_enabled = false
    elseif a == "--purpose-mode" then cfg.purpose_mode = word("explore", "exploit", "portfolio")
    elseif a == "--no-purpose-learn" then cfg.purpose_learn = false
    elseif a == "--no-colony" then cfg.colony = false
    elseif a == "--no-supervisor" then cfg.supervisor = false
    elseif a == "--no-explorer" then cfg.explorer = false
    elseif a == "--no-rule" then cfg.rule_seed = false
    elseif a == "--no-explore-expand" then cfg.explore_expand = false
    elseif a == "--explore-root" then cfg.explore_roots = cfg.explore_roots or {}; table.insert(cfg.explore_roots, val())
    elseif a == "--colony-id" then cfg.colony_id = val()
    elseif a == "--generation" then cfg.generation = num(NONNEG_INT)
    elseif a == "--colony-root" then cfg.colony_root = val()
    elseif a == "--clone-max-peers" then cfg.clone_max_peers = num(POSITIVE_INT)
    elseif a == "--clone-generations" then cfg.clone_max_generation = num(NONNEG_INT)
    elseif a == "--help" or a == "-h" then
      print([[
EvoLua — a self-evolving Lua organism

  --mode <free|directed>     life mode (default: free)
  --goal "<text>"            directive for directed mode (implies --mode directed)
  --ticks <n>                run for n ticks then rest (default: forever)
  --tick-seconds <s>         seconds per tick (default: 1; use 0.2 for a fast demo)
  --evolve-every <n>         run the evolver every n ticks (default: 3)
  --watch-dir <path>         add a directory to filesystem perception
  --watch-log <path>         add a log file to log perception
  --log-level <lvl>          debug|info|warn|error
  --autonomy <lvl>           autonomy ceiling: learn|report|notify|suggest|act (default: report;
                             suggest = proposed actions + model upgrades go to approvals/)
  --brain <kind>             decision brain: auto|rules|gguf|embedded|service|apple (default: auto
                             = an explicit/saved/downloaded model, else the strongest one already
                             on this machine, else the embedded one; = EVOLUA_BRAIN)
  --unattended               act on its own (reversible, safe-listed verbs only) and download a
                             better decision model WITHOUT approval (= EVOLUA_UNATTENDED=1)

  --llm-api <auto|provider|url>  online brain. auto (default) = first provider with a key in the
                             env or keys/<provider>, free tiers first: groq cerebras gemini
                             openrouter mistral github huggingface, then openai anthropic; the
                             keyless public endpoint only when nothing is on the machine. Or a
                             provider id, or an OpenAI-compatible base URL ("anthropic+URL")
  --no-llm-api               never use an online brain (local model / rules only)
  --no-llm-keyless           never fall back to the keyless public endpoint
  --llm-model <name>         model name at that service (default: provider's free/cheap default)
  --llm-key-env <VAR>        env var holding the API key (default: provider's usual var)
  --llm-budget <n>           max online calls per life (default: 300)
  --model <path.gguf>        use this GGUF as the brain (= $EVOLUA_MODEL; wins over everything)
  --model-dir <path>         extra directory to scan for *.gguf (repeatable)
  --model-max-mb <n>         cap model size for machine brains + downloads (default: by RAM)
  --no-model-discover        never use a brain found on this machine (online / download / rules)
  --model-ignore-battery     allow downloading a model while on battery
  --model-force-upgrade      treat the brain as a bottleneck (climb the ladder even if it works)
  --no-synth                 never grow the synthesizer organ (the brain writes no new organs)

  --mesh                     join organisms on OTHER hosts: LAN broadcast discovery + TCP mail,
                             gene pool and purpose ledger (host-side nerve; remote peers appear in
                             colony/peers like local ones)
  --mesh-port <n>            mesh UDP/TCP port (default: 7707)
  --mesh-seed <host:port>    a peer to beacon to directly — Tailscale/VPN/WAN (repeatable)
  --mesh-gateway             also serve as an internet gateway (CONNECT proxy on port+1) for peers

  --clone                    allow the colony to spawn real OS-process clones (default: off)
  --no-clone                 forbid replication (used internally for child instances)
  --clone-eager              split whenever there's room (skip the load/capacity gate)
  --clone-ignore-battery     allow spawning clones while on battery
  --clone-generalist         clones are generic copies (skip goal crystallization)
  --purpose-mode <m>         how a clone's goal is chosen: explore|exploit|portfolio
  --no-purpose-learn         disable S4 (don't bias goals by harvested child payoff)
  --no-colony                never grow the colony organ (no seed, no evolutionary regrowth)
  --no-supervisor            never grow the host-brainstem watch organ
  --no-explorer              never grow the environment-exploration organ
  --no-rule                  never grow evolvable rule-DSL organs
  --no-explore-expand        explore, but don't auto-expand perception (watch dirs/logs)
  --explore-root <path>      add a directory the explorer may wander (repeatable)
  --clone-max-peers <n>      hard cap on simultaneous live instances (default: 3)
  --clone-generations <n>    hard cap on clone depth: root=0 (default: 1)
  --colony-id <id>           this instance's colony id (set automatically for clones)
  --generation <n>           this instance's clone depth (set automatically for clones)
  --colony-root <path>       shared colony directory root (set automatically for clones)

Examples:
  evolua --ticks 60 --tick-seconds 0.2
  evolua --goal "watch filesystem changes" --ticks 80
  evolua --ticks 120 --tick-seconds 0.2 --clone     # let it replicate (bounded)
  (plain Lua: lua lua/main.lua …, same flags)
]])
      os.exit(0)
    else
      die("unknown flag: " .. tostring(a))
    end
    i = i + 1
  end
end

parse(arg or {})

-- --no-colony / --no-supervisor / --no-explorer / --no-rule switch the template
-- off for the WHOLE life, not just the seed: the evolver's spawn gate consults this
-- set, so no drive (bandit, illumination, directed, …) can grow it back. Accepts a
-- list ({ "load_guard" }) or a set ({ load_guard = true }) from config.lua.
do
  local off = {}
  for k, v in pairs(cfg.disabled_templates or {}) do
    if type(k) == "number" then off[v] = true elseif v then off[k] = true end
  end
  if cfg.colony == false then off.colony = true end
  if cfg.supervisor == false then off.supervisor = true end
  if cfg.explorer == false then off.explorer = true end
  if cfg.rule_seed == false then off.rule = true end
  if cfg.synth == false then off.synth = true end
  cfg.disabled_templates = off
end

-- colony wiring: bridge launch context from globals into cfg so the sandboxed
-- colony organ (which only sees ctx.cfg) can find its identity, the shared
-- colony dir, and how to relaunch the program when it replicates.
cfg.colony_root = cfg.colony_root or BASE
cfg.colony_id   = cfg.colony_id or ("root-" .. tostring(os.time()))
cfg.generation  = cfg.generation or 0
cfg.prog        = (arg and arg[0]) or "evolua"
cfg.embedded    = rawget(_G, "EVOLUA_EMBEDDED") and true or false
cfg.is_windows  = (package.config:sub(1, 1) == "\\")
-- bridge the host-capability probe so the sandboxed colony organ can ask "is
-- there room for another worker?" before it splits (it can't require() core).
cfg.hostcaps    = require("core.hostcaps")
if os.getenv("EVOLUA_MESH_FORCE_GATEWAY") == "1" then cfg.mesh_force_gateway = true end
-- tell the host-side mesh nerve (src/mesh.rs) who we are; it waits for this file
do
  local Platform0 = require("core.platform")
  Platform0.mkdir_p(cfg.state_dir)
  local fh = io.open(cfg.state_dir .. "/mesh_id", "w")
  if fh then fh:write(string.format("id=%s\ngen=%d\n", cfg.colony_id, cfg.generation)); fh:close() end
end
-- bridge the brain to the sandbox (organs can't see host globals). LATE-BOUND: the
-- model manager may attach/swap a brain at any tick, so look it up on every call.
local Brain = require("core.brain")
cfg.llm = function(system, user, max_tokens)
  local f = rawget(_G, "llm_complete"); if not f then return nil end
  return f(system, user, max_tokens)
end
cfg.llm_active = function()
  local b = Brain.info()
  if b.kind == "none" then return nil end
  return b.name .. " (" .. b.kind .. ")"
end
-- compile-only check for model-written source (never executes it): the synth
-- organ uses it to validate syntax before a file ever reaches the registry.
cfg.compile = function(src, chunkname)
  return load(src, chunkname or "=synth", "t", {})
end
-- DRY RUN for model-written source: compile it in an environment like the plugin sandbox,
-- attach it to a fake ctx, and fire its events twice (ticks 10 and 20 — baseline, then compare)
-- so the runtime slips a small model makes (closed handle, two-value returns, invented library
-- functions, table-vs-string) surface in seconds, with the failing line, instead of after the
-- organ is installed and has thrown for a minute. Returns ok, err, reports(n), emits(n).
cfg.dryrun = function(src, chunkname, payloads)
  local env = {
    string = string, table = table, math = math, os = os, io = io, utf8 = utf8,
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type, tostring = tostring,
    tonumber = tonumber, pcall = pcall, error = error, assert = assert, unpack = table.unpack,
    print = function() end,
  }
  env._G = env
  local fn, cerr = load(src, chunkname or "=dryrun", "t", env)
  if not fn then return false, "syntax error: " .. tostring(cerr) end
  local ok, spec = pcall(fn)
  if not ok then return false, "error while loading: " .. tostring(spec) end
  if type(spec) ~= "table" or type(spec.attach) ~= "function" then return false, "no spec table with attach()" end
  local handlers, reports, emits = {}, 0, 0
  local fake = {
    cfg = cfg, kernel = { tick = 10 },
    bus = {
      subscribe = function(_, t, f) handlers[#handlers + 1] = { t = t, f = f } end,
      emit = function() emits = emits + 1 end,
      stats = {}, history = {},
    },
    report = function() reports = reports + 1 end,
    log = { info = function() end, debug = function() end, warn = function() end, error = function() end },
    memory = { data = { fitness = {}, counters = {} }, bump = function() end, reward = function() end },
    registry = { loaded = {} }, evolver = { organs = {} },
  }
  local aok, aerr = pcall(spec.attach, fake)
  if not aok then return false, "attach() threw: " .. tostring(aerr) end
  if #handlers == 0 then return false, "attach() subscribed to nothing" end
  for _, tick in ipairs({ 10, 20 }) do
    fake.kernel.tick = tick
    for _, h in ipairs(handlers) do
      local data = (payloads and payloads[h.t]) or {}
      if h.t == "self.heartbeat" then data = { tick = tick } end
      local hok, herr = pcall(h.f, { type = h.t, data = data, at = os.time() })
      if not hok then return false, string.format("handler for '%s' threw on tick %d: %s", h.t, tick, tostring(herr)) end
    end
  end
  return true, nil, reports, emits
end
-- default exploration scope: the data home + the current working directory (the
-- explorer can be pointed elsewhere with --explore-root). Sane default, not a
-- security boundary — widen it freely (openness is intentional here).
local Platform = require("core.platform")
if not cfg.explore_roots then
  cfg.explore_roots = { BASE }
  local cwd = Platform.cwd()
  if cwd and cwd ~= BASE then table.insert(cfg.explore_roots, cwd) end
end

local Kernel = require("core.kernel")
local organism = Kernel.new(cfg)

-- Seed foundational always-on organs exactly once. Idempotent across lives: if a
-- previous life already wrote one to the plugins dir, boot()'s scan + evolver:
-- rehydrate re-adopt it, so we skip re-seeding to avoid duplicates.
local function seed_once(template)
  for _, l in ipairs(Platform.list_dir(cfg.plugins_dir)) do
    if l:match("^gen_" .. template .. "_%d+%.lua$") then return end
  end
  organism.ctx.evolver:spawn(template)
end

if cfg.colony then seed_once("colony") end
if cfg.supervisor then seed_once("supervisor") end
if cfg.explorer then seed_once("explorer") end
if cfg.rule_seed then seed_once("rule") end
if cfg.synth then seed_once("synth") end

-- graceful Ctrl-C if the host Lua exposes signals (optional; safe if absent)
local ok_sig = pcall(function()
  local posix = require("posix.signal")
  posix.signal(posix.SIGINT, function() organism:stop() end)
end)

organism:run()
