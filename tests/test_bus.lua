local Bus = require("core.bus")

-- a bus with the cost term off (deterministic amounts) that records every reward
local function bus(cfg)
  cfg = cfg or {}
  if cfg.reward_cost_weight == nil then cfg.reward_cost_weight = 0 end
  local b = Bus.new(nil, cfg)
  b.paid = {}
  b:subscribe("self.reward", function(ev)
    local p = b.paid[ev.data.owner] or {}
    p[#p + 1] = ev.data.amount
    b.paid[ev.data.owner] = p
  end, "kernel")
  return b
end

return {
  ["a lone handler of a fresh stimulus earns the base"] = function(t)
    local b = bus()
    b:subscribe("x", function() return true end, "a")
    t.eq(b:emit("x"), 1)
    t.eq(b.paid.a[1], 1)
  end,

  ["filling a starved stimulus earns the gap"] = function(t)
    local b = bus()
    for _ = 1, 3 do b:emit("x") end                     -- nobody handles: streak 3
    t.eq(b.stats.x.unhandled_streak, 3)
    b:subscribe("x", function() return true end, "a")
    b:emit("x")
    t.eq(b.paid.a[1], 4, "base * (1 + streak)")
    t.eq(b.stats.x.unhandled_streak, 0, "handled resets the streak")
  end,

  ["the gap is capped"] = function(t)
    local b = bus({ reward_gap_cap = 8 })
    for _ = 1, 20 do b:emit("x") end
    b:subscribe("x", function() return true end, "a")
    b:emit("x")
    t.eq(b.paid.a[1], 9)
  end,

  ["co-handlers share the credit"] = function(t)
    local b = bus()
    b:subscribe("x", function() return true end, "a")
    b:subscribe("x", function() return { handled = true } end, "b")
    b:emit("x")
    t.eq(b.paid.a[1], 0.5); t.eq(b.paid.b[1], 0.5)
  end,

  ["a declared reward is ignored"] = function(t)
    local b = bus()
    b:subscribe("x", function() return { handled = true, reward = 100 } end, "a")
    b:emit("x")
    t.eq(b.paid.a[1], 1)
  end,

  ["an organ earns nothing for a stimulus it emitted itself"] = function(t)
    local b = bus()
    b:subscribe("tick", function() b:emit("vitals"); return true end, "sup")
    b:subscribe("vitals", function(ev) return true end, "sup")
    b:subscribe("vitals", function(ev) return true end, "other")
    b:emit("tick")
    t.eq(#b.paid.sup, 1, "sup is paid for tick only")
    t.eq(b.paid.other[1], 1, "the other handler is paid in full (the emitter doesn't dilute it)")
  end,

  ["the emitter is recorded on the event"] = function(t)
    local b, seen = bus(), nil
    b:subscribe("tick", function() b:emit("vitals"); return true end, "sup")
    b:subscribe("vitals", function(ev) seen = ev.emitter end, "watcher")
    b:emit("tick")
    t.eq(seen, "sup")
  end,

  ["a throwing reactor raises self.error and earns nothing"] = function(t)
    local b, err = bus(), nil
    b:subscribe("self.error", function(ev) err = ev.data end, "kernel")
    b:subscribe("x", function() error("boom") end, "bad")
    t.eq(b:emit("x"), 0)
    t.eq(err.owner, "bad"); t.ok(err.err:find("boom"), "error text")
    t.eq(b.paid.bad, nil)
  end,

  ["an emit loop is cut at max_emit_depth"] = function(t)
    local b = bus({ max_emit_depth = 5 })
    local depth = 0
    b:subscribe("ping", function() depth = depth + 1; b:emit("pong"); return true end, "a")
    b:subscribe("pong", function() depth = depth + 1; b:emit("ping"); return true end, "b")
    b:emit("ping")
    t.eq(depth, 5, "stopped, no stack overflow")
  end,

  ["reactor time is charged"] = function(t)
    local b = bus({ reward_cost_weight = 10 })
    b:subscribe("x", function()
      local t0 = os.clock()
      while os.clock() - t0 < 0.05 do end      -- burn ~50 ms (plain Lua: CPU time)
      return true
    end, "slow")
    b:emit("x")
    t.ok(b.paid.slow[1] < 0.8, "1 - 10 * ~0.05 should be well under 1, got " .. b.paid.slow[1])
  end,
}
