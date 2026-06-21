-- core/memory.lua — persistent state + tiny dependency-free serializer
-- Stores fitness scores, observation counters, generation log. Survives
-- restarts so the organism "remembers" what it has learned/evolved.

local Memory = {}
Memory.__index = Memory

-- serialize a plain Lua value (tables/strings/numbers/booleans) to a literal
local function ser(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local parts, ni = {}, indent .. "  "
    -- array part
    local n = #v
    local seen = {}
    for i = 1, n do
      seen[i] = true
      parts[#parts + 1] = ni .. ser(v[i], ni)
    end
    -- hash part
    local keys = {}
    for k in pairs(v) do
      if not (type(k) == "number" and seen[k]) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local ks
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        ks = k
      else
        ks = "[" .. ser(k, ni) .. "]"
      end
      parts[#parts + 1] = ni .. ks .. " = " .. ser(v[k], ni)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  return "nil"
end

function Memory.new(path)
  local self = setmetatable({ path = path, data = {} }, Memory)
  self:load()
  -- structural defaults
  self.data.fitness = self.data.fitness or {}     -- plugin name -> score
  self.data.births  = self.data.births  or {}     -- generation log
  self.data.counters = self.data.counters or {}   -- arbitrary counters
  self.data.generation = self.data.generation or 0
  return self
end

function Memory:load()
  local fh = io.open(self.path, "r")
  if not fh then return end
  local src = fh:read("*a"); fh:close()
  if not src or src == "" then return end
  local chunk = load("return " .. src, "memory", "t", {})
  if chunk then
    local ok, val = pcall(chunk)
    if ok and type(val) == "table" then self.data = val end
  end
end

function Memory:save()
  local fh = io.open(self.path, "w")
  if not fh then return false end
  fh:write(ser(self.data, ""))
  fh:close()
  return true
end

-- fitness helpers ---------------------------------------------------------
function Memory:fitness(name) return self.data.fitness[name] or 0 end

function Memory:reward(name, amount)
  self.data.fitness[name] = (self.data.fitness[name] or 0) + (amount or 1)
  return self.data.fitness[name]
end

function Memory:decay(rate)
  -- entropy: unused capabilities slowly lose fitness, pressuring selection
  for k, v in pairs(self.data.fitness) do
    self.data.fitness[k] = v * (1 - (rate or 0.02))
  end
end

function Memory:record_birth(entry)
  self.data.generation = self.data.generation + 1
  entry.generation = self.data.generation
  entry.at = os.date("%Y-%m-%d %H:%M:%S")
  table.insert(self.data.births, entry)
  return self.data.generation
end

function Memory:bump(counter, by)
  self.data.counters[counter] = (self.data.counters[counter] or 0) + (by or 1)
  return self.data.counters[counter]
end

return Memory
