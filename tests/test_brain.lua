-- core/brain.lua selection + the model manager's adopt / judge / rollback,
-- against a fake host (the host_* globals src/brain.rs would provide).
local Brain = require("core.brain")
local ModelMgr = require("core.modelmgr")
local Memory = require("core.memory")

local G = _G
local HOST = { "host_brain_kinds", "host_brain_load", "host_brain_info", "host_brain_complete",
               "host_models", "host_services", "host_apple_status", "llm_complete" }

-- install a fake host. models: what host_models() finds; broken: names whose load fails
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
    host_models = function() return opts.models or {} end,
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

local function dir(t)
  local d = t.tmpdir()
  return d
end

local suite = {}

suite["auto picks the strongest model on the machine that fits"] = function(t)
  fake({ models = MODELS })
  local info = Brain.select({ brain = "auto", model_max_mb = 2000 }, dir(t), nil, 16000)
  unfake()
  t.eq(info.name, "mid", "huge is over model_max_mb")
end

suite["the RAM share caps the pick too"] = function(t)
  fake({ models = MODELS })
  local info = Brain.select({ brain = "auto", model_max_mb = 9000, model_ram_share = 0.25 }, dir(t), nil, 8000)
  unfake()
  t.eq(info.name, "mid", "7.6B (4466 MB) is over a quarter of 8 GB")
end

suite["a model that fails to load falls through to the next"] = function(t)
  fake({ models = MODELS, broken = { mid = true } })
  local info = Brain.select({ brain = "auto" }, dir(t), nil, 16000)
  unfake()
  t.eq(info.name, "tiny")
end

suite["the saved choice comes before discovery"] = function(t)
  local d = dir(t)
  fake({ models = MODELS })
  Brain.save(d, { kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  local info = Brain.select({ brain = "auto" }, d, nil, 16000)
  unfake()
  t.eq(info.name, "tiny")
end

suite["brain_order prefers the OS model when it is available"] = function(t)
  fake({ models = MODELS, kinds = { "gguf", "apple" }, apple = "available" })
  local info = Brain.select({ brain = "auto", brain_order = { "apple", "gguf" } }, dir(t), nil, 16000)
  unfake()
  t.eq(info.kind, "apple")
end

suite["an unavailable OS model is skipped"] = function(t)
  fake({ models = MODELS, kinds = { "gguf", "apple" }, apple = "appleIntelligenceNotEnabled" })
  local info = Brain.select({ brain = "auto", brain_order = { "apple", "gguf" } }, dir(t), nil, 16000)
  unfake()
  t.eq(info.name, "mid")
end

suite["embedded is the fallback when nothing else fits"] = function(t)
  fake({ models = { gguf("huge", 7.6, 4466) } })
  local info = Brain.select({ brain = "auto" }, dir(t), nil, 16000)
  unfake()
  t.eq(info.kind, "embedded")
end

suite["--brain rules loads nothing; --brain <kind> restricts"] = function(t)
  fake({ models = MODELS })
  t.eq(Brain.select({ brain = "rules" }, dir(t), nil, 16000).kind, "none")
  t.eq(rawget(G, "llm_complete"), nil, "reasoner has no llm_complete")
  t.eq(Brain.select({ brain = "embedded" }, dir(t), nil, 16000).kind, "embedded")
  unfake()
end

suite["loading points llm_complete at the brain; unloading removes it"] = function(t)
  fake({ models = MODELS })
  Brain.load({ kind = "gguf", path = "/m/mid.gguf", name = "mid" })
  t.ok(rawget(G, "llm_complete") ~= nil, "set")
  Brain.load({ kind = "none" })
  t.eq(rawget(G, "llm_complete"), nil, "cleared")
  unfake()
end

-- ── model manager: adopt → judge → rollback, and "didn't come back" ────────

local function manager(t, models)
  local home = dir(t)
  local audits = {}
  local ctx = {
    cfg = { reports_dir = home .. "/reports", state_dir = home .. "/state", brain = "auto",
            model_min_samples = 4, model_fallback_rate = 0.4, model_max_mb = 2000 },
    memory = Memory.new(home .. "/memory.lua"),
    log = { info = function() end, warn = function() end, debug = function() end },
  }
  ctx.autonomy = { consider = function(_, d) audits[#audits + 1] = d end }
  local mm = ModelMgr.new(ctx)
  ctx.modelmgr = mm
  return mm, ctx, audits
end

suite["a bottlenecked brain proposes the next stronger one on the machine"] = function(t)
  fake({ models = MODELS })
  local mm, ctx, proposals = manager(t)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  ctx.memory.data.counters = { llm_ok = 1, llm_fallback = 9 }
  local d = mm:step()
  unfake()
  t.eq(d.action, "adopt")
  t.eq(proposals[1].proposed.verb, "model_adopt")
  t.eq(proposals[1].proposed.spec.name, "mid", "one step up, not straight to the biggest")
end

suite["adopt switches now, then a worse brain is judged and rolled back"] = function(t)
  fake({ models = MODELS })
  local mm, ctx, proposals = manager(t)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  ctx.memory.data.counters = { llm_ok = 6, llm_fallback = 4 }        -- 40% before
  local ok = mm:adopt({ kind = "gguf", path = "/m/mid.gguf", name = "mid", params_b = 1.5 })
  t.ok(ok, "adopted")
  t.eq(Brain.info().name, "mid", "active right away")
  t.eq(Brain.saved(mm.models_dir).name, "mid", "saved for later lives")
  t.eq(ctx.memory.data.counters.llm_ok, 0, "fresh samples for the new brain")
  ctx.memory.data.counters = { llm_ok = 1, llm_fallback = 9 }        -- 90% after: worse
  local d = mm:step()
  t.eq(d.action, "rollback")
  t.eq(proposals[#proposals].proposed.verb, "model_rollback")
  local rolled = mm:rollback()
  t.ok(rolled, "rolled back")
  t.eq(Brain.info().name, "tiny", "previous brain back")
  t.eq(Brain.saved(mm.models_dir).name, "tiny")
  t.ok(mm:blocked("brain:mid"), "the rolled-back brain backs off")
  unfake()
end

suite["a failed adopt keeps the current brain and backs off"] = function(t)
  fake({ models = MODELS, broken = { mid = true } })
  local mm = manager(t)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  local ok = mm:adopt({ kind = "gguf", path = "/m/mid.gguf", name = "mid", params_b = 1.5 })
  t.ok(not ok, "refused")
  t.eq(Brain.info().name, "tiny")
  t.ok(mm:blocked("brain:mid"), "backs off")
  unfake()
end

suite["a switched-to brain that doesn't come back next life is dropped"] = function(t)
  fake({ models = MODELS })
  local mm, ctx = manager(t)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  mm:adopt({ kind = "gguf", path = "/m/mid.gguf", name = "mid", params_b = 1.5 })
  -- next life: the boot selection ended up on something else (mid failed to load)
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  mm:on_boot(Brain.info())
  t.eq(ctx.memory.data.model_upgrade, nil, "switch forgotten")
  t.eq(Brain.saved(mm.models_dir).name, "tiny", "previous choice restored")
  t.ok(mm:blocked("brain:mid"), "backs off")
  unfake()
end

suite["an explicit brain choice is never adopted away"] = function(t)
  fake({ models = MODELS })
  local mm, ctx = manager(t)
  ctx.cfg.brain = "gguf"
  Brain.load({ kind = "gguf", path = "/m/tiny.gguf", name = "tiny", params_b = 0.5 })
  ctx.memory.data.counters = { llm_ok = 1, llm_fallback = 9 }
  t.eq(mm:adoptable({ ram_total_mb = 16000 }), nil)
  unfake()
end

suite["model_adopt survives the approval inbox round trip"] = function(t)
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
  local inbox = ctx.autonomy.inbox
  local pending
  for _, f in ipairs(require("core.platform").list_dir(inbox)) do
    if f:match("^pending%-") then pending = f end
  end
  t.ok(pending, "a pending approval was filed")
  os.rename(inbox .. "/" .. pending, inbox .. "/approved/" .. pending)   -- the user approves
  ctx.autonomy:poll_approvals()
  t.eq(Brain.info().name, "mid", "switched on approval")
  t.eq(Brain.info().params_b, 1.5, "params survived the file")
  unfake()
end

return suite
