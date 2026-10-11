local Evolver = require("core.evolver")
local cfg = require("config")

local function grows(goal)
  local got = {}
  for k in pairs(Evolver.goal_templates(goal, cfg)) do got[#got + 1] = k end
  table.sort(got)
  return table.concat(got, " ")
end

local CASES = {
  -- the canonical purpose goals each grow exactly their own organ
  { "report errors", "error_reporter" },
  { "file changes", "fs_journal" },
  { "cpu resource", "cpu_guard" },
  { "memory resource", "mem_guard" },
  { "system load", "load_guard" },
  -- generic words don't spill over into other templates
  { "dosya değişikliklerini izle", "fs_journal" },
  { "log filesystem changes", "fs_journal" },
  { "yüksek cpu kullanımını izle", "cpu_guard" },
  { "sistem yükünü izle", "load_guard" },
  { "hataları raporla", "error_reporter" },
  -- a generic word alone grows nothing; mid-word hits don't count
  { "report", "" },
  { "izle", "" },
  { "download speed", "" },
  { "bu taraftan bak", "" },
  -- two generic words together are still a request
  { "monitor resources", "cpu_guard load_guard mem_guard" },
  { "koloni kur ve çoğal", "colony" },
  { "ortamı keşfet", "explorer" },
}

local suite = {}
for _, c in ipairs(CASES) do
  suite[string.format("%q grows {%s}", c[1], c[2])] = function(t) t.eq(grows(c[1]), c[2]) end
end

suite["every canonical purpose names a template that it grows"] = function(t)
  for tmpl, goal in pairs(cfg.template_goal) do
    t.ok(Evolver.goal_templates(goal, cfg)[tmpl], goal .. " should grow " .. tmpl)
  end
end

return suite
