local T = require("core.templates")
local Bus = require("core.bus")

-- load a generated organ's source the way the registry does, against a small ctx
local function attach(src, tick)
  local ctx = { cfg = { rule_cooldown = 10 }, kernel = { tick = tick or 0 }, reports = {},
                log = { info = function() end }, bus = Bus.new(nil, { reward_cost_weight = 0 }) }
  ctx.report = function(cat, text) ctx.reports[#ctx.reports + 1] = text end
  local env = { pairs = pairs, ipairs = ipairs, tonumber = tonumber, tostring = tostring,
                string = string, table = table, math = math, ctx = ctx }
  local spec = assert(load(src, "organ", "t", env))()
  spec.attach(ctx)
  return spec, ctx
end

-- every genome the operators can produce must still render to loadable code
local function valid(t, genes, cfg)
  t.ok(#genes.rules >= 1 and #genes.rules <= (cfg.rule_max_rules or 4), "genome size bound: " .. #genes.rules)
  local src = T.rule.build("gen_rule_1", genes)
  t.ok(load(src, "organ", "t", {}), "renders to valid Lua")
end

return {
  ["the seed rule reports, then cools down"] = function(t)
    local spec, ctx = attach(T.rule.build("gen_rule_1", T.rule.default_genes))
    t.eq(spec.genes.stimulus, "self.heartbeat", "organ carries its genome")
    for tick = 1, 40 do
      ctx.kernel.tick = tick
      ctx.bus:emit("self.heartbeat", { tick = tick })
    end
    -- fires at tick 10, 20, 30, 40 (tick >= 10, once per 10 ticks)
    t.eq(#ctx.reports, 4)
  end,

  ["a condition gates the action"] = function(t)
    local genes = { stimulus = "proc.hot",
      rules = { { field = "cpu_avg", op = ">", value = 50, action = "emit", emit = "alert.cpu" } } }
    local _, ctx = attach(T.rule.build("gen_rule_2", genes))
    local alerts = {}
    ctx.bus:subscribe("alert.cpu", function(ev) alerts[#alerts + 1] = ev.data.value end, "watch")
    ctx.bus:emit("proc.hot", { cpu_avg = 30 })
    ctx.bus:emit("proc.hot", { cpu_avg = 80 })
    t.eq(#alerts, 1); t.eq(alerts[1], 80)
  end,

  ["act only requests, never executes"] = function(t)
    local genes = { stimulus = "proc.hot", rules = { { action = "act", verb = "kill" } } }
    local _, ctx = attach(T.rule.build("gen_rule_3", genes))
    local req
    ctx.bus:subscribe("action.request", function(ev) req = ev.data end, "autonomy")
    ctx.bus:emit("proc.hot", { name = "x", pid = 42 })
    t.eq(req.verb, "notify", "a verb outside the safe list falls back to notify")
    t.eq(req.pid, 42)
  end,

  ["injected field names, operators and values stay inert"] = function(t)
    local exited = false
    local trap = { exit = function() exited = true end }
    local evil = {
      { field = 'x"]) os.exit(1) --', op = ">", value = 1, action = "report" },
      { field = "cpu_avg", op = "> 0 or os.exit(1) or", value = 1, action = "report" },
      { field = "cpu_avg", op = ">", value = "1 or os.exit(1)", action = "emit", emit = "x) os.exit(1" },
    }
    for i, r in ipairs(evil) do
      local src = T.rule.build("gen_rule_" .. i, { stimulus = "proc.hot", rules = { r } })
      local ctx = { cfg = {}, kernel = { tick = 100 }, report = function() end, log = { info = function() end },
                    bus = Bus.new(nil, {}) }
      local env = { tonumber = tonumber, tostring = tostring, ctx = ctx, os = trap }
      local spec = assert(load(src, "organ", "t", env), "renders to valid Lua")()
      spec.attach(ctx)
      ctx.bus:emit("proc.hot", { cpu_avg = 99 })
    end
    t.ok(not exited, "no genome reached os.exit")
  end,

  ["mutation keeps every genome valid"] = function(t)
    local cfg = { rule_max_rules = 4 }
    local g = T.rule.default_genes
    for _ = 1, 500 do
      g = T.rule.mutate_genes(g, cfg)
      valid(t, g, cfg)
    end
  end,

  ["crossover respects the size bound"] = function(t)
    local cfg = { rule_max_rules = 3 }
    local a, b = T.rule.default_genes, T.rule.default_genes
    for _ = 1, 50 do a = T.rule.mutate_genes(a, { rule_max_rules = 4 }) end
    for _ = 1, 50 do b = T.rule.mutate_genes(b, { rule_max_rules = 4 }) end
    for _ = 1, 200 do valid(t, T.rule.crossover_genes(a, b, cfg), cfg) end
  end,

  ["mutation never aliases the parent"] = function(t)
    local parent = { stimulus = "proc.hot", rules = { { field = "cpu_avg", op = ">", value = 50, action = "report" } } }
    for _ = 1, 50 do T.rule.mutate_genes(parent, {}) end
    t.eq(parent.rules[1].value, 50); t.eq(#parent.rules, 1)
  end,
}
