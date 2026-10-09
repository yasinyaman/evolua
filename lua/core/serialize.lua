-- core/serialize.lua — the one serializer for every Lua literal the organism
-- writes: state/memory.lua, the genes rendered into a generated organ, a clone's
-- inherited.lua. Plain data only — nested tables, strings, numbers, booleans;
-- anything else (functions, a table that contains itself) becomes nil. Keys are
-- sorted, so the same value always renders to the same text.

local M = {}

-- numbers that read back exactly: integers as-is, floats in the shortest form
-- that round-trips, and the IEEE specials as expressions (`inf`/`nan` aren't Lua)
local function num(v)
  if v ~= v then return "(0/0)" end
  if v == math.huge then return "1e999" end
  if v == -math.huge then return "-1e999" end
  if math.type and math.type(v) == "integer" then return tostring(v) end
  local s = tostring(v)
  if tonumber(s) ~= v then s = string.format("%.17g", v) end
  return s
end

local function ser(v, indent, open)
  local t = type(v)
  if t == "number" then
    return num(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    if open[v] then return "nil" end          -- a cycle: no literal can express it
    open[v] = true
    local parts, ni = {}, indent .. "  "
    -- array part
    local n = #v
    for i = 1, n do parts[#parts + 1] = ni .. ser(v[i], ni, open) end
    -- hash part
    local keys = {}
    for k in pairs(v) do
      if not (math.type and math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local ks
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        ks = k
      else
        ks = "[" .. ser(k, ni, open) .. "]"
      end
      parts[#parts + 1] = ni .. ks .. " = " .. ser(v[k], ni, open)
    end
    open[v] = nil
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  return "nil"
end

-- serialize v to a Lua literal; `indent` prefixes the closing brace of tables
function M.ser(v, indent)
  return ser(v, indent or "", {})
end

return M
