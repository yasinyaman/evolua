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
    elseif a == "--no-explore-expand" then cfg.explore_expand = false
    elseif a == "--explore-root" then cfg.explore_roots = cfg.explore_roots or {}; table.insert(cfg.explore_roots, val())
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
  --no-explore-expand        explore, but don't auto-expand perception (watch dirs/logs)
  --explore-root <path>      add a directory the explorer may wander (repeatable)
  --clone-max-peers <n>      hard cap on simultaneous live instances (default: 3)
  --clone-generations <n>    hard cap on clone depth: root=0 (default: 1)
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
cfg.prog        = (arg and arg[0]) or "evolua"
cfg.embedded    = rawget(_G, "EVOLUA_EMBEDDED") and true or false
cfg.is_windows  = (package.config:sub(1, 1) == "\\")
-- bridge the host-capability probe so the sandboxed colony organ can ask "is
-- there room for another worker?" before it splits (it can't require() core).
cfg.hostcaps    = require("core.hostcaps")
-- default exploration scope: the data home + the current working directory (the
-- explorer can be pointed elsewhere with --explore-root). Sane default, not a
-- security boundary — widen it freely (openness is intentional here).
if not cfg.explore_roots then
  cfg.explore_roots = { BASE }
  local ph = io.popen and io.popen("pwd 2>/dev/null")
  local cwd = ph and ph:read("*l"); if ph then ph:close() end
  if cwd and cwd ~= "" and cwd ~= BASE then table.insert(cfg.explore_roots, cwd) end
end

local Kernel = require("core.kernel")
local organism = Kernel.new(cfg)

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

-- graceful Ctrl-C if the host Lua exposes signals (optional; safe if absent)
local ok_sig = pcall(function()
  local posix = require("posix.signal")
  posix.signal(posix.SIGINT, function() organism:stop() end)
end)

organism:run()
