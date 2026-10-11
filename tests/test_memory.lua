local Memory = require("core.memory")

return {
  ["save then load restores the data"] = function(t)
    local dir = t.tmpdir()
    local m = Memory.new(dir .. "/memory.lua")
    m:reward("gen_x_1", 2.5)
    m:bump("llm_ok", 3)
    m:record_birth({ organ = "gen_x_1", template = "x", genes = { rules = { { value = 7 } } } })
    t.ok(m:save(), "save")
    local m2 = Memory.new(dir .. "/memory.lua")
    t.eq(m2:fitness("gen_x_1"), 2.5)
    t.eq(m2.data.counters.llm_ok, 3)
    t.eq(m2.data.generation, 1)
    t.eq(m2.data.births[1].genes.rules[1].value, 7, "nested genes persist")
  end,

  ["a missing or corrupt file starts fresh"] = function(t)
    local dir = t.tmpdir()
    local fh = io.open(dir .. "/memory.lua", "w"); fh:write("{ this is not lua"); fh:close()
    local m = Memory.new(dir .. "/memory.lua")
    t.eq(m.data.generation, 0)
    t.ok(m.data.fitness and m.data.births and m.data.counters, "structural defaults")
  end,

  ["decay shrinks every fitness"] = function(t)
    local m = Memory.new(t.tmpdir() .. "/memory.lua")
    m:reward("a", 10)
    m:decay(0.1)
    t.near(m:fitness("a"), 9)
  end,

  ["prune_births keeps living organs and the newest records"] = function(t)
    local m = Memory.new(t.tmpdir() .. "/memory.lua")
    for i = 1, 10 do m:record_birth({ organ = "o" .. i, template = "x" }) end
    m:prune_births({ o2 = true }, 3)
    local names = {}
    for _, b in ipairs(m.data.births) do names[#names + 1] = b.organ end
    t.eq(table.concat(names, ","), "o2,o8,o9,o10")
  end,
}
