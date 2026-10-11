local Ser = require("core.serialize")

local function back(s) return assert(load("return " .. s, "ser", "t", {}))() end

return {
  ["nested tables round-trip"] = function(t)
    local v = { stimulus = "proc.hot", rules = { { field = "cpu_avg", op = ">=", value = 42 } } }
    local r = back(Ser.ser(v))
    t.eq(r.stimulus, "proc.hot")
    t.eq(r.rules[1].field, "cpu_avg")
    t.eq(r.rules[1].value, 42)
  end,

  ["floats round-trip exactly, integers stay integers"] = function(t)
    local r = back(Ser.ser({ a = 0.1 + 0.2, b = 1 / 3, n = 3, z = -0.0 }))
    t.eq(r.a, 0.1 + 0.2); t.eq(r.b, 1 / 3)
    t.eq(math.type(r.n), "integer", "3 stays an integer")
  end,

  ["inf and nan render as expressions"] = function(t)
    local r = back(Ser.ser({ hi = math.huge, lo = -math.huge, nan = 0 / 0 }))
    t.eq(r.hi, math.huge); t.eq(r.lo, -math.huge)
    t.ok(r.nan ~= r.nan, "nan stays nan")
  end,

  ["odd keys are bracketed"] = function(t)
    local r = back(Ser.ser({ [7] = "seven", ["a key"] = true, [true] = 1 }))
    t.eq(r[7], "seven"); t.eq(r["a key"], true); t.eq(r[true], 1)
  end,

  ["strings with quotes and newlines survive"] = function(t)
    local s = 'say "hi"\nand \\ bye\0end'
    t.eq(back(Ser.ser({ s = s })).s, s)
  end,

  ["output is deterministic"] = function(t)
    local v = { b = 1, a = 2, c = { z = 1, y = 2 } }
    t.eq(Ser.ser(v), Ser.ser(back(Ser.ser(v))))
  end,

  ["a cycle renders as nil instead of recursing"] = function(t)
    local c = { a = 1 }; c.self = c
    local r = back(Ser.ser(c))
    t.eq(r.a, 1); t.eq(r.self, nil)
  end,

  ["functions render as nil"] = function(t)
    t.eq(back(Ser.ser({ f = print })).f, nil)
  end,
}
