#!/usr/bin/env lua
-- main.lua — EvoLua entry point
-- A tiny self-evolving organism: it perceives its environment, reacts, grows
-- new organs (plugins) when it meets a need it can't yet handle, evolves them
-- under selection pressure, and reports back.
--
-- Usage:
--   lua main.lua                         # free mode, lives indefinitely
--   lua main.lua --mode directed --goal "report errors"
--   lua main.lua --ticks 60              # bounded run (good for trying it out)
--   lua main.lua --tick-seconds 0.2 --ticks 100   # fast demo
--
-- Run from the evolua/ directory (so package paths resolve), or from repo root
-- with:  lua -e 'package.path="evolua/?.lua;"..package.path' evolua/main.lua

-- make `require("core.x")` / `require("sensors.x")` work regardless of cwd.
-- (In the single-binary build these modules come from package.preload, injected
--  by the Rust host; this path setup is for running under a plain `lua`.)
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = HERE .. "/?.lua;" .. HERE .. "/?/init.lua;" .. package.path

local cfg = require("config")

-- Where the organism keeps its body parts & memory.
--   * single-binary build: EVOLUA_HOME is injected by the host (an OS-appropriate
--     writable data dir, e.g. ~/Library/Application Support/EvoLua).
--   * plain `lua` run: fall back to the script directory.
local BASE = (rawget(_G, "EVOLUA_HOME")) or HERE

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

-- ---- minimal flag parser -------------------------------------------------
local function parse(args)
  local i = 1
  while i <= #args do
    local a = args[i]
    local function val() i = i + 1; return args[i] end
    if a == "--mode" then cfg.mode = val()
    elseif a == "--goal" then cfg.mode = "directed"; cfg.goal = val()
    elseif a == "--ticks" then cfg.max_ticks = tonumber(val())
    elseif a == "--tick-seconds" then cfg.tick_seconds = tonumber(val())
    elseif a == "--evolve-every" then cfg.evolve_every = tonumber(val())
    elseif a == "--watch-dir" then table.insert(cfg.watch_dirs, val())
    elseif a == "--watch-log" then table.insert(cfg.watch_logs, val())
    elseif a == "--log-level" then cfg.log_level = val()
    -- colony / self-replication
    elseif a == "--clone" then cfg.clone_enabled = true
    elseif a == "--no-clone" then cfg.clone_enabled = false
    elseif a == "--clone-eager" then cfg.clone_require_pressure = false
    elseif a == "--clone-ignore-battery" then cfg.clone_ignore_battery = true
    elseif a == "--clone-generalist" then cfg.purpose_enabled = false
    elseif a == "--purpose-mode" then cfg.purpose_mode = val()
    elseif a == "--no-purpose-learn" then cfg.purpose_learn = false
    elseif a == "--no-colony" then cfg.colony = false
    elseif a == "--no-supervisor" then cfg.supervisor = false
    elseif a == "--no-explorer" then cfg.explorer = false
    elseif a == "--no-synth" then cfg.synth = false
    elseif a == "--llm-api" then
      local v = val()
      -- "off" / "none" / "0" / "false" read as --no-llm-api (otherwise they'd be taken for a URL)
      if v and ({ off = 1, none = 1, no = 1, ["0"] = 1, ["false"] = 1 })[v:lower()] then cfg.llm_api = false else cfg.llm_api = v end
    elseif a == "--no-llm-api" then cfg.llm_api = false
    elseif a == "--no-llm-keyless" then cfg.llm_keyless = false
    elseif a == "--llm-model" then cfg.llm_api_model = val()
    elseif a == "--llm-key-env" then cfg.llm_key_env = val()
    elseif a == "--llm-budget" then cfg.llm_remote_budget = tonumber(val())
    elseif a == "--model" then cfg.model_path = val()
    elseif a == "--model-dir" then table.insert(cfg.model_dirs, val())
    elseif a == "--model-max-mb" then cfg.model_max_mb = tonumber(val())
    elseif a == "--no-model-discover" then cfg.model_discover = false
    elseif a == "--model-ignore-battery" then cfg.model_ignore_battery = true
    elseif a == "--model-force-upgrade" then cfg.model_force_upgrade = true
    elseif a == "--no-rule" then cfg.rule_seed = false
    elseif a == "--no-explore-expand" then cfg.explore_expand = false
    elseif a == "--explore-root" then cfg.explore_roots = cfg.explore_roots or {}; table.insert(cfg.explore_roots, val())
    elseif a == "--mesh" then cfg.mesh = true
    elseif a == "--no-mesh" then cfg.mesh = false
    elseif a == "--mesh-port" then cfg.mesh = true; cfg.mesh_port = tonumber(val())
    elseif a == "--mesh-gateway" then cfg.mesh = true; cfg.mesh_gateway = true
    elseif a == "--mesh-seed" then cfg.mesh = true; cfg.mesh_seeds = cfg.mesh_seeds or {}; table.insert(cfg.mesh_seeds, val())
    elseif a == "--colony-id" then cfg.colony_id = val()
    elseif a == "--generation" then cfg.generation = tonumber(val())
    elseif a == "--colony-root" then cfg.colony_root = val()
    elseif a == "--clone-max-peers" then cfg.clone_max_peers = tonumber(val())
    elseif a == "--clone-generations" then cfg.clone_max_generation = tonumber(val())
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

  --clone                    allow the colony to spawn real OS-process clones (default: off)
  --no-clone                 forbid replication (used internally for child instances)
  --clone-eager              split whenever there's room (skip the load/capacity gate)
  --clone-ignore-battery     allow spawning clones while on battery
  --clone-generalist         clones are generic copies (skip goal crystallization)
  --purpose-mode <m>         how a clone's goal is chosen: explore|exploit|portfolio
  --no-purpose-learn         disable S4 (don't bias goals by harvested child payoff)
  --no-colony                do not seed the colony organ at all
  --no-supervisor            do not seed the host-brainstem watch organ
  --no-explorer              do not seed the environment-exploration organ
  --no-synth                 do not seed the synthesizer organ (model-written organs)
  --no-rule                  do not seed the evolvable rule-DSL organ

  --llm-api <auto|provider|url>  online brain. auto (default) = first provider with a key in
                             the env, free tiers first: ollama groq cerebras gemini openrouter
                             mistral github huggingface, then openai anthropic. Or a provider
                             id, or an OpenAI-compatible base URL ("anthropic+URL" for proxies)
  --no-llm-api               never use an online brain (local model / rules only)
  --no-llm-keyless           in auto mode, skip the keyless public endpoint (keys/local only)
  --llm-model <name>         model name at that service (default: provider's cheap default)
  --llm-key-env <VAR>        env var holding the API key (default: provider's usual var)
  --llm-budget <n>           max online calls per life (default: 300)
  --model <path.gguf>        use this model as the brain (wins over discovery/download)
  --model-dir <path>         extra directory to scan for *.gguf (repeatable)
  --model-max-mb <n>         cap model size for discovery + download (default: sized by RAM)
  --no-model-discover        never attach a model found on the host (download ladder only)
  --model-ignore-battery     allow downloading a model while on battery
  --model-force-upgrade      treat the brain as a bottleneck (climb the ladder even if it works)
  --no-explore-expand        explore, but don't auto-expand perception (watch dirs/logs)
  --explore-root <path>      add a directory the explorer may wander (repeatable)
  --clone-max-peers <n>      hard cap on simultaneous live instances (default: 3)
  --clone-generations <n>    hard cap on clone depth: root=0 (default: 1)
  --mesh                     join organisms on OTHER hosts: LAN broadcast discovery + TCP mail
                             (host-side nerve; remote peers appear in colony/peers like local ones)
  --mesh-port <n>            mesh UDP/TCP port (default: 7707)
  --mesh-gateway             also serve as an internet gateway (CONNECT proxy on port+1) for peers
  --mesh-seed <host:port>    a peer to announce to across networks broadcast can't cross
                             (Tailscale/VPN/WAN); repeatable; implies --mesh
  --colony-id <id>           this instance's colony id (set automatically for clones)
  --generation <n>           this instance's clone depth (set automatically for clones)
  --colony-root <path>       shared colony directory root (set automatically for clones)

Examples:
  lua main.lua --ticks 60 --tick-seconds 0.2
  lua main.lua --goal "watch filesystem changes" --ticks 80
  lua main.lua --ticks 120 --tick-seconds 0.2 --clone   # let it replicate (bounded)
]])
      os.exit(0)
    else
      io.stderr:write("unknown flag: " .. tostring(a) .. " (try --help)\n")
    end
    i = i + 1
  end
end

parse(arg or {})

-- colony wiring: bridge launch context from globals into cfg so the sandboxed
-- colony organ (which only sees ctx.cfg) can find its identity, the shared
-- colony dir, and how to relaunch the program when it replicates.
cfg.colony_root = cfg.colony_root or BASE
cfg.colony_id   = cfg.colony_id or ("root-" .. tostring(os.time()))
cfg.generation  = cfg.generation or 0
if os.getenv("EVOLUA_MESH_FORCE_GATEWAY") == "1" then cfg.mesh_force_gateway = true end
-- tell the host-side mesh nerve (src/mesh.rs) who we are; it waits for this file
do
  os.execute('mkdir -p "' .. cfg.state_dir .. '" 2>/dev/null')
  local fh = io.open(cfg.state_dir .. "/mesh_id", "w")
  if fh then fh:write(string.format("id=%s\ngen=%d\n", cfg.colony_id, cfg.generation)); fh:close() end
end
cfg.prog        = (arg and arg[0]) or "evolua"
cfg.embedded    = rawget(_G, "EVOLUA_EMBEDDED") and true or false
cfg.is_windows  = (package.config:sub(1, 1) == "\\")
-- bridge the host-capability probe so the sandboxed colony organ can ask "is
-- there room for another worker?" before it splits (it can't require() core).
cfg.hostcaps    = require("core.hostcaps")
-- bridge the brain to the sandbox (organs can't see host globals). LATE-BOUND:
-- the model manager may attach/swap a model at any tick, so look the binding up
-- on every call rather than capturing it once.
cfg.llm = function(system, user, max_tokens)
  local f = rawget(_G, "llm_complete"); if not f then return nil end
  return f(system, user, max_tokens)
end
cfg.llm_active = function()
  local f = rawget(_G, "llm_model"); return f and f() or nil
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
if not cfg.explore_roots then
  cfg.explore_roots = { BASE }
  local ph = io.popen and io.popen("pwd 2>/dev/null")
  local cwd = ph and ph:read("*l"); if ph then ph:close() end
  if cwd and cwd ~= "" and cwd ~= BASE then table.insert(cfg.explore_roots, cwd) end
end

-- ONLINE brain: attach a hosted LLM before the kernel is born, so the model manager
-- sees an active brain and (llm_remote_only) skips local discovery/download entirely.
-- FREE tiers come first in auto mode; model names are defaults the operator can override
-- (--llm-model), since providers rename their free models now and then.
local PROVIDERS = {
  { id = "ollama",      kind = "openai",    base = "http://localhost:11434/v1",                      model = "qwen2.5-coder:1.5b",                      key = nil,                 free = true,  probe = true },
  { id = "groq",        kind = "openai",    base = "https://api.groq.com/openai/v1",                 model = "llama-3.3-70b-versatile",                 key = "GROQ_API_KEY",      free = true },
  { id = "cerebras",    kind = "openai",    base = "https://api.cerebras.ai/v1",                     model = "llama3.1-8b",                             key = "CEREBRAS_API_KEY",  free = true },
  { id = "gemini",      kind = "openai",    base = "https://generativelanguage.googleapis.com/v1beta/openai", model = "gemini-2.0-flash",            key = "GEMINI_API_KEY",    free = true },
  { id = "openrouter",  kind = "openai",    base = "https://openrouter.ai/api/v1",                   model = "meta-llama/llama-3.3-70b-instruct:free", key = "OPENROUTER_API_KEY", free = true },
  { id = "mistral",     kind = "openai",    base = "https://api.mistral.ai/v1",                      model = "mistral-small-latest",                    key = "MISTRAL_API_KEY",   free = true },
  { id = "github",      kind = "openai",    base = "https://models.github.ai/inference",             model = "openai/gpt-4o-mini",                      key = "GITHUB_TOKEN",      free = true },
  { id = "huggingface", kind = "openai",    base = "https://router.huggingface.co/v1",               model = "Qwen/Qwen2.5-Coder-32B-Instruct",         key = "HF_TOKEN",          free = true },
  -- keyless public endpoint (rate-limited, best effort) — the fallback when no key exists
  { id = "pollinations", kind = "openai",   base = "https://text.pollinations.ai/openai",            model = "openai",                                  key = nil,                 free = true,  keyless = true },
  { id = "openai",      kind = "openai",    base = "https://api.openai.com/v1",                      model = "gpt-4o-mini",                             key = "OPENAI_API_KEY" },
  { id = "anthropic",   kind = "anthropic", base = "https://api.anthropic.com/v1",                   model = "claude-haiku-5-5",                        key = "ANTHROPIC_API_KEY" },
}
cfg.llm_providers = PROVIDERS
local remote_label
-- a key may also be dropped as a FILE: <home>/keys/<provider> (one line). That is how a
-- key obtained later reaches a running organism without a restart (see modelmgr).
local function key_for(p)
  if not p.key then return nil end
  local k = os.getenv(p.key)
  if k and k ~= "" then return k end
  local fh = io.open(BASE .. "/keys/" .. p.id, "r")
  if fh then k = (fh:read("*l") or ""):gsub("%s+$", ""); fh:close(); if k ~= "" then return k end end
  return nil
end
-- attach an online provider now; returns label or nil, reason
cfg.llm_attach = function(p, model_override)
  local set = rawget(_G, "llm_remote_set")
  if not set then return nil, "no online-brain binding (build with --features remote)" end
  local base = os.getenv("EVOLUA_LLM_BASE") or p.base               -- proxy / test override
  local model = model_override or cfg.llm_api_model or os.getenv("EVOLUA_LLM_MODEL") or p.model
  local key = key_for(p)
  if p.key and not key and not p.key_optional then return nil, "no key in $" .. p.key .. " or keys/" .. p.id end
  if not set(p.kind, base, model, key, cfg.llm_remote_budget) then return nil, "host refused provider kind " .. tostring(p.kind) end
  cfg.llm_remote = { api = p.id, model = model, base = base, free = p.free or false, keyless = p.keyless or false }
  return string.format("%s via %s%s (%s)", model, p.id, p.free and (p.keyless and " [free, keyless]" or " [free tier]") or "", base)
end
do
  local api = cfg.llm_api
  local env_api = os.getenv("EVOLUA_LLM_API")
  if env_api and env_api ~= "" then api = env_api end
  local function by_id(id) for _, p in ipairs(PROVIDERS) do if p.id == id then return p end end end
  local function reachable(url)                         -- ollama: is a server listening?
    local ph = io.popen and io.popen(string.format('curl -s -m 1 -o /dev/null -w "%%{http_code}" %q/models 2>/dev/null', url))
    local code = ph and ph:read("*a"); if ph then ph:close() end
    return code and code:match("^[23]") ~= nil
  end
  if api and api ~= "" and api ~= false then
    if not rawget(_G, "llm_remote_set") then
      if api ~= "auto" then io.stderr:write("evolua: --llm-api given but this host has no online-brain binding (build with --features remote)\n") end
    elseif api == "auto" then
      -- list order = free first; keyed providers before the keyless public one (quality),
      -- the keyless one before paid ones (cost)
      -- a local model server: ask it what it serves and take the best coder/instruct model
      -- (a hard-coded name would 404 on any host that pulled different models)
      local function served_model(base)
        local ph = io.popen and io.popen(string.format("curl -s -m 2 %q/models 2>/dev/null", base))
        local body = ph and ph:read("*a") or ""; if ph then ph:close() end
        local best, best_score
        for id in body:gmatch('"id"%s*:%s*"([^"]+)"') do
          local l = id:lower()
          if not (l:find("embed") or l:find("rerank") or l:find("bge") or l:find("whisper")) then
            local score = 0
            if l:find("coder") then score = score + 30 end
            if l:find("instruct") or l:find("chat") then score = score + 10 end
            local b = tonumber(l:match("(%d+%.?%d*)b")) or 0
            score = score + math.min(b, 70)                  -- bigger is better, up to a point
            if l:find("q8") then score = score + 1 end
            if not best_score or score > best_score then best, best_score = id, score end
          end
        end
        return best
      end
      for _, p in ipairs(PROVIDERS) do
        if p.probe then
          if reachable(p.base) then
            local pick = (not cfg.llm_api_model) and (not os.getenv("EVOLUA_LLM_MODEL")) and served_model(os.getenv("EVOLUA_LLM_BASE") or p.base) or nil
            remote_label = cfg.llm_attach(p, pick); if remote_label then break end
          end
        elseif p.key then
          if key_for(p) then remote_label = cfg.llm_attach(p); if remote_label then break end end
        elseif p.keyless and cfg.llm_keyless ~= false then
          remote_label = cfg.llm_attach(p); if remote_label then break end
        end
      end
    else
      local kind_prefix, url = api:match("^(%a+)%+(https?://.+)$")   -- "anthropic+https://proxy/v1"
      -- a raw URL is usually a self-hosted server (vLLM, llama-server, Ollama): the key is optional
      local p = by_id(api)
        or (kind_prefix and { id = api, kind = kind_prefix, base = url, model = "default", key = "EVOLUA_LLM_KEY", key_optional = true })
        or { id = api, kind = "openai", base = api, model = "default", key = "EVOLUA_LLM_KEY", key_optional = true }
      local why
      remote_label, why = cfg.llm_attach(p)
      if not remote_label then io.stderr:write("evolua: --llm-api " .. api .. ": " .. tostring(why) .. " — continuing without the online brain\n") end
    end
  end
end

local Kernel = require("core.kernel")
local organism = Kernel.new(cfg)
if remote_label then
  organism.ctx.log:info("\27[32m🧠 brain online: %s [online service, budget %s calls]\27[0m", remote_label, tostring(cfg.llm_remote_budget or "∞"))
end

-- Seed foundational always-on organs exactly once. Idempotent across lives: if a
-- previous life already wrote one to the plugins dir, boot()'s scan + evolver:
-- rehydrate re-adopt it, so we skip re-seeding to avoid duplicates.
local function seed_once(template)
  local present = false
  local p = io.popen and io.popen('ls -1 "' .. cfg.plugins_dir .. '" 2>/dev/null')
  if p then
    for l in p:lines() do
      if l:match("^gen_" .. template .. "_%d+%.lua$") then present = true; break end
    end
    p:close()
  end
  if not present then organism.ctx.evolver:spawn(template) end
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
