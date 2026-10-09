-- tests/run.lua — unit tests for the organism's pure parts, no host needed.
--
--   lua tests/run.lua            # from the repo root; exit 0 = all passed
--   lua tests/run.lua bus rule   # only test files whose name contains a word
--
-- Each tests/test_*.lua returns { ["what it checks"] = function(t) … end }.
-- `t` carries the assertions below. A failing assertion aborts that test only.

local ROOT = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$")) or "."
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/tests/?.lua;" .. package.path

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

local t = {}
function t.ok(cond, msg) if not cond then error(msg or "expected a true value", 2) end end
function t.eq(got, want, msg)
  if got ~= want then error(string.format("%s: got %s, want %s", msg or "eq", fmt(got), fmt(want)), 2) end
end
function t.near(got, want, tol, msg)
  if type(got) ~= "number" or math.abs(got - want) > (tol or 1e-9) then
    error(string.format("%s: got %s, want %s ± %s", msg or "near", fmt(got), fmt(want), fmt(tol or 1e-9)), 2)
  end
end
-- a fresh scratch directory for tests that touch the filesystem
function t.tmpdir()
  local p = os.tmpname()
  os.remove(p)
  require("core.platform").mkdir_p(p)
  return p
end

-- test files, in a stable order (no directory listing needed)
local FILES = {
  "test_serialize", "test_memory", "test_bus", "test_rule_dsl", "test_modelmgr",
  "test_reasoner", "test_rag", "test_goals", "test_platform", "test_log",
}

local only = {}
for i = 1, #(arg or {}) do only[#only + 1] = arg[i] end
local function wanted(file)
  if #only == 0 then return true end
  for _, w in ipairs(only) do if file:find(w, 1, true) then return true end end
  return false
end

math.randomseed(12345)   -- property tests use math.random; keep runs reproducible
local pass, fail = 0, 0
for _, file in ipairs(FILES) do
  if wanted(file) then
    local suite = require(file)
    local names = {}
    for name in pairs(suite) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local ok, err = pcall(suite[name], t)
      if ok then
        pass = pass + 1
      else
        fail = fail + 1
        print(string.format("FAIL %s: %s\n     %s", file, name, tostring(err)))
      end
    end
  end
end
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
