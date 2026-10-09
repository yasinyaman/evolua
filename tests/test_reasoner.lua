local Reasoner = require("core.reasoner")
local parse, blend = Reasoner._parse_schema, Reasoner._blend_conf

local GOOD = [[
SALIENCE: high
ENTITY: WindowServer
HYPOTHESIS: WindowServer shows sustained high CPU.
ROUTE: template:cpu_guard
ACTION: report
CONFIDENCE: 0.8]]

return {
  ["a well-formed reply parses"] = function(t)
    local d = parse(GOOD)
    t.eq(d.salience, "high"); t.eq(d.entity, "WindowServer"); t.eq(d.route, "template:cpu_guard")
    t.eq(d.action, "report"); t.eq(d.confidence, 0.8); t.eq(d.source, "llm")
  end,

  ["medium/moderate normalize to med"] = function(t)
    t.eq(parse((GOOD:gsub("high", "Medium", 1))).salience, "med")
  end,

  ["confidence is clamped to [0, 1]"] = function(t)
    t.eq(parse((GOOD:gsub("0%.8", "7.5"))).confidence, 1)
  end,

  ["an echoed route menu is rejected"] = function(t)
    t.eq(parse((GOOD:gsub("ROUTE: template:cpu_guard", "ROUTE: <rule>"))), nil)
    t.eq(parse((GOOD:gsub("ROUTE: template:cpu_guard", "ROUTE: rule|escalate"))), nil)
  end,

  ["a missing field or unknown value is rejected"] = function(t)
    t.eq(parse((GOOD:gsub("CONFIDENCE: 0%.8", ""))), nil)
    t.eq(parse((GOOD:gsub("ACTION: report", "ACTION: destroy"))), nil)
    t.eq(parse((GOOD:gsub("SALIENCE: high", "SALIENCE: extreme"))), nil)
    t.eq(parse(""), nil); t.eq(parse(nil), nil)
  end,

  ["rules cap how far the model can raise confidence"] = function(t)
    t.near(blend(0.5, 0.5), 0.5)
    t.near(blend(0.2, 1.0), 0.45, 1e-9, "ceiling = rule + 0.25")
    t.near(blend(0.9, 1.0), 0.94, 1e-9)
    t.eq(blend(0, 0), 0)
  end,
}
