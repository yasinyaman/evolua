-- core/memory.lua — persistent state (serialized by core/serialize.lua)
-- Stores fitness scores, observation counters, generation log. Survives
-- restarts so the organism "remembers" what it has learned/evolved.

local ser = require("core.serialize").ser

local Memory = {}
Memory.__index = Memory

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

-- keep births bounded: every record of a living organ (rehydrate needs its
-- genes) plus the last `keep` records; older births of dead organs go
function Memory:prune_births(alive, keep)
  local births = self.data.births
  local n = #births
  if n <= keep then return end
  local out = {}
  for i, b in ipairs(births) do
    if i > n - keep or alive[b.organ] then out[#out + 1] = b end
  end
  self.data.births = out
end

function Memory:bump(counter, by)
  self.data.counters[counter] = (self.data.counters[counter] or 0) + (by or 1)
  return self.data.counters[counter]
end

return Memory
