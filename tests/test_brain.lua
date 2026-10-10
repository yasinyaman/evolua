-- core/brain.lua selection + the model manager's probation / speed / adopt /
-- rollback, against a fake host (the host_* globals src/brain.rs would provide).
local Brain = require("core.brain")
local ModelMgr = require("core.modelmgr")
local Memory = require("core.memory")
local HostCaps = require("core.hostcaps")

local G = _G
local HOST = { "host_brain_kinds", "host_brain_load", "host_brain_info", "host_brain_complete",
               "host_models", "host_services", "host_apple_status", "llm_complete" }

-- install a fake host. models: what host_models() finds on the machine; dir_models:
-- what it finds in extra dirs (the data home's models/); broken: names whose load fails
local function fake(opts)
  local loaded
  local h = {
    host_brain_kinds = function() return opts.kinds or { "gguf", "embedded" } end,
    host_brain_info = function()
      if not loaded then return { kind = "none", id = "none", name = "rules" } end
      return { kind = loaded.kind, id = loaded.kind .. ":" .. tostring(loaded.name or loaded.path),
               name = loaded.name or loaded.path or loaded.kind, params_b = loaded.params_b }
    end,
    host_brain_load = function(spec)
      if spec.kind == "none" then loaded = nil; return G.host_brain_info() end
      if (opts.broken or {})[spec.name or spec.path or spec.kind] then return nil, "corrupt" end
      loaded = spec
      return G.host_brain_info()
    end,
    host_brain_complete = function() return "SALIENCE: low" end,
    host_models = function(extra) return extra and (opts.dir_models or {}) or (opts.models or {}) end,
    host_apple_status = opts.apple and function() return opts.apple end or nil,
  }
  for _, k in ipairs(HOST) do rawset(G, k, h[k]) end
  Brain.spec = nil
end

local function unfake()
  for _, k in ipairs(HOST) do rawset(G, k, nil) end
  Brain.spec = nil
end

local function gguf(name, params, mb)
  return { path = "/m/" .. name .. ".gguf", source = "ollama", name = name, params_b = params, size_mb = mb }
end

local MODELS = { gguf("tiny", 0.5, 400), gguf("mid", 1.5, 940), gguf("huge", 7.6, 4466) }
local APPLE = { kinds = { "gguf", "embedded", "apple" }, apple = "available" }

local function with(base, extra)
  local o = {}
  for k, v in pairs(base) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local suite = {}

-- ── selection ──────────────────────────────────────────────────────────────

suite["a bigger brain on the machine replaces the built-in default"] = function(t)
  fake({ models = MODELS })
  local info, how, default = Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 16000 })
  unfake()
  t.eq(info.name, "mid", "huge (4466 MB) is over a quarter of 16 GB")
  t.eq(how, "machine")
  t.eq(default.kind, "embedded", "the built-in model stays the default")
end

suite["the biggest usable brain wins, whatever its kind"] = function(t)
  fake(with(APPLE, { models = MODELS }))
  t.eq(Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 16000 }).kind, "apple", "3B > 1.5B")
  t.eq(Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 32000 }).name, "huge", "7.6B fits 32 GB")
  unfake()
end

suite["a machine brain no bigger than the default doesn't replace it"] = function(t)
  fake({ models = { gguf("small", 0.1, 90) } })
  local info, how = Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 16000 })
  unfake()
  t.eq(info.kind, "embedded")
  t.eq(how, "default")
end

suite["a downloaded default sets the bar instead"] = function(t)
  local d = t.tmpdir()
  local fh = io.open(d .. "/decision.gguf", "w"); fh:write("x"); fh:close()
  fake({ models = MODELS, dir_models = { { path = d .. "/decision.gguf", name = "decision", params_b = 2.0, size_mb = 1200 } } })
  local info, how, default = Brain.select({ brain = "auto" }, d, nil, { ram_total_mb = 16000 })
  unfake()
  t.eq(info.name, "decision.gguf", "1.5B on the machine isn't bigger than the downloaded 2B")
  t.eq(how, "default")
  t.eq(default.params_b, 2.0, "size read from its header")
end

suite["model_max_mb is an optional cap"] = function(t)
  fake({ models = MODELS })
  t.eq(Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 32000 }).name, "huge")
  t.eq(Brain.select({ brain = "auto", model_max_mb = 2000 }, t.tmpdir(), nil, { ram_total_mb = 32000 }).name, "mid")
  unfake()
end

suite["a brain that fails to load or is backed off is passed over"] = function(t)
  fake({ models = MODELS, broken = { mid = true } })
  t.eq(Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 16000 }).name, "tiny")
  unfake()
  fake({ models = MODELS })
  local skip = function(key) return key == "brain:mid" end
  t.eq(Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 16000, skip = skip }).name, "tiny")
  unfake()
end

suite["an OS model that isn't available is skipped"] = function(t)
  fake(with(APPLE, { models = MODELS, apple = "appleIntelligenceNotEnabled" }))
  t.eq(Brain.select({ brain = "auto" }, t.tmpdir(), nil, { ram_total_mb = 16000 }).name, "mid")
  unfake()
end

suite["--brain rules loads nothing; --brain <kind> restricts"] = function(t)
  fake({ models = MODELS })
  t.eq(Brain.select({ brain = "rules" }, t.tmpdir(), nil, {}).kind, "none")
  t.eq(rawget(G, "llm_complete"), nil, "reasoner has no llm_complete")
  t.eq(Brain.select({ brain = "embedded" }, t.tmpdir(), nil, { ram_total_mb = 16000 }).kind, "embedded")
  unfake()
end

suite["llm_complete is timed, without the warm-up answer"] = function(t)
  fake({ models = MODELS })
  Brain.load({ kind = "gguf", path = "/m/mid.gguf", name = "mid" })
  local complete = rawget(G, "llm_complete")
  t.ok(complete ~= nil, "set")
  for _ = 1, 3 do complete("s", "u", 8) end
  t.eq(Brain.stats.calls, 3); t.eq(Brain.stats.timed, 2)
  t.eq(Brain.mean_seconds(3), nil, "not enough timed answers yet")
  complete("s", "u", 8)
  t.ok(Brain.mean_seconds(3) ~= nil, "mean after 3 timed answers")
  Brain.load({ kind = "none" })
  t.eq(rawget(G, "llm_complete"), nil, "cleared on unload")
  unfake()
end

-- ── the model manager ──────────────────────────────────────────────────────

local ROOMY = function() return { ram_total_mb = 16000, ram_avail_mb = 12000, cores = 8, disk_free_mb = 1e6, on_battery = false } end

local function manager(t)
  local home = t.tmpdir()
  local proposals = {}
  local ctx = {
    cfg = { reports_dir = home .. "/reports", state_dir = home .. "/state", brain = "auto",
            model_min_samples = 4, model_fallback_rate = 0.4, brain_max_seconds = 10 },
    memory = Memory.new(home .. "/memory.lua"),
    log = { info = function() end, warn = function() end, debug = function() end },
  }
  ctx.autonomy = { consider = function(_, d) proposals[#proposals + 1] = d end, audit = function() end }
  local mm = ModelMgr.new(ctx)
  ctx.modelmgr = mm
  return mm, ctx, proposals
end

-- boot like the kernel does
local function boot(mm, ctx)
  local info, how, default = Brain.select(ctx.cfg, mm.models_dir, nil,
    { ram_total_mb = 16000, skip = function(k) return mm:blocked(k) end })
  mm:on_boot(info, how, default)
  return info
end

local function with_caps(f)
  local probe = HostCaps.probe
  HostCaps.probe = ROOMY
  local ok, err = pcall(f)
  HostCaps.probe = probe
  if not ok then error(err, 0) end
end

suite["a machine brain that falls back too often goes back to the default"] = function(t)
  with_caps(function()
    fake({ models = MODELS })
    local mm, ctx, proposals = manager(t)
    t.eq(boot(mm, ctx).name, "mid")
    t.eq(ctx.memory.data.model_upgrade.kind, "machine", "on probation")
    ctx.memory.data.counters = { llm_ok = 1, llm_fallback = 9 }
    t.eq(mm:step().action, "rollback")
    t.eq(proposals[#proposals].proposed.verb, "model_rollback")
    t.ok(mm:rollback(), "rolled back")
    t.eq(Brain.info().kind, "embedded", "the built-in default again")
    t.ok(mm:blocked("brain:mid"), "backed off")
    t.eq(boot(mm, ctx).name, "tiny", "next life tries the next smaller one")
    unfake()
  end)
end

suite["a machine brain that does well is kept and not re-tried"] = function(t)
  with_caps(function()
    fake({ models = MODELS })
    local mm, ctx = manager(t)
    boot(mm, ctx)
    ctx.memory.data.counters = { llm_ok = 9, llm_fallback = 1 }
    mm:step()
    t.ok(ctx.memory.data.brain_ok["brain:mid"], "verdict remembered")
    boot(mm, ctx)
    t.ok(ctx.memory.data.model_upgrade.judged, "no new probation for a proven brain")
    unfake()
  end)
end

suite["a brain too slow for this host steps down and is backed off"] = function(t)
  with_caps(function()
    fake(with(APPLE, { models = MODELS }))
    local mm, ctx = manager(t)
    t.eq(boot(mm, ctx).kind, "apple")
    Brain.stats = { calls = 5, timed = 4, secs = 60 }       -- 15 s per decision
    t.eq(mm:step().action, "step down")
    t.eq(Brain.info().name, "mid", "next smaller")
    t.ok(mm:blocked("brain:Apple on-device model"), "the slow one backs off")
    t.eq(boot(mm, ctx).name, "mid", "and the next life starts there")
    unfake()
  end)
end

suite["the default is never stepped down from"] = function(t)
  with_caps(function()
    fake({ models = {} })
    local mm, ctx = manager(t)
    t.eq(boot(mm, ctx).kind, "embedded")
    Brain.stats = { calls = 5, timed = 4, secs = 60 }
    t.ok(not mm:check_speed(ROOMY()), "nothing below the default")
    t.eq(Brain.info().kind, "embedded")
    unfake()
  end)
end

suite["the download ladder doesn't fetch a tier smaller than the brain in use"] = function(t)
  with_caps(function()
    fake({ models = { gguf("mid", 1.5, 940) } })
    local mm, ctx = manager(t)
    ctx.cfg.model_force_upgrade = true                      -- always "bottlenecked"
    boot(mm, ctx)
    ctx.memory.data.model_upgrade = nil                     -- no probation in the way
    local d = mm:step()
    t.eq(d.action, "hold")
    t.eq(d.reason, "current brain is bigger than the next tier")
    unfake()
  end)
end

suite["adopt switches now; a worse brain is judged and rolled back"] = function(t)
  with_caps(function()
    fake({ models = MODELS })
    local mm, ctx, proposals = manager(t)
    Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
    ctx.memory.data.counters = { llm_ok = 6, llm_fallback = 4 }        -- 40% before
    t.ok(mm:adopt({ kind = "gguf", path = "/m/mid.gguf", name = "mid", params_b = 1.5 }), "adopted")
    t.eq(Brain.info().name, "mid", "active right away")
    t.eq(ctx.memory.data.counters.llm_ok, 0, "fresh samples for the new brain")
    ctx.memory.data.counters = { llm_ok = 1, llm_fallback = 9 }        -- 90% after: worse
    t.eq(mm:step().action, "rollback")
    t.eq(proposals[#proposals].proposed.verb, "model_rollback")
    t.ok(mm:rollback(), "rolled back")
    t.eq(Brain.info().name, "tiny", "previous brain back")
    t.ok(mm:blocked("brain:mid"), "the rolled-back brain backs off")
    unfake()
  end)
end

suite["a failed adopt keeps the current brain and backs off"] = function(t)
  fake({ models = MODELS, broken = { mid = true } })
  local mm = manager(t)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  t.ok(not mm:adopt({ kind = "gguf", path = "/m/mid.gguf", name = "mid", params_b = 1.5 }), "refused")
  t.eq(Brain.info().name, "tiny")
  t.ok(mm:blocked("brain:mid"), "backs off")
  unfake()
end

suite["a switched-to brain that doesn't come back next life is dropped"] = function(t)
  fake({ models = MODELS })
  local mm, ctx = manager(t)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  mm:adopt({ kind = "gguf", path = "/m/mid.gguf", name = "mid", params_b = 1.5 })
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })   -- next life: mid failed
  mm:on_boot(Brain.info(), "machine")
  t.eq(ctx.memory.data.model_upgrade.to_id, Brain.info().id, "only the new probation remains")
  t.ok(mm:blocked("brain:mid"), "backs off")
  unfake()
end

suite["an explicit brain choice is never adopted away"] = function(t)
  fake({ models = MODELS })
  local mm, ctx = manager(t)
  ctx.cfg.brain = "gguf"
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  t.eq(mm:adoptable({ ram_total_mb = 16000 }), nil)
  unfake()
end

suite["model_adopt survives the approval inbox round trip"] = function(t)
  with_caps(function()
    fake({ models = MODELS })
    local Autonomy = require("core.autonomy")
    local mm, ctx = manager(t)
    ctx.cfg.autonomy_ceiling, ctx.cfg.safe_actions = "suggest", { "model_adopt" }
    ctx.kernel = { tick = 50 }
    ctx.report = function() end
    ctx.bus = { subscribe = function() end, emit_raw = function() end }
    ctx.autonomy = Autonomy.new(ctx)
    Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
    ctx.memory.data.counters = { llm_ok = 1, llm_fallback = 9 }
    t.eq(mm:step().action, "adopt")
    t.eq(Brain.info().name, "tiny", "suggest ceiling: nothing switched yet")
    local inbox, pending = ctx.autonomy.inbox, nil
    for _, f in ipairs(require("core.platform").list_dir(inbox)) do
      if f:match("^pending%-") then pending = f end
    end
    t.ok(pending, "a pending approval was filed")
    os.rename(inbox .. "/" .. pending, inbox .. "/approved/" .. pending)   -- the user approves
    ctx.autonomy:poll_approvals()
    t.eq(Brain.info().name, "mid", "switched on approval")
    t.eq(Brain.info().params_b, 1.5, "params survived the file")
    unfake()
  end)
end

return suite
