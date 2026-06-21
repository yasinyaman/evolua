-- core/bus.lua — Event bus (pub/sub)
-- The nervous system of the organism. Sensors publish "stimuli", plugins
-- subscribe and react. Subscriptions are fully dynamic: behavior can change
-- at runtime as plugins are born, mutated, or retired.

local Bus = {}
Bus.__index = Bus

function Bus.new(log)
  return setmetatable({
    subs = {},        -- event_type -> { {id=, fn=, owner=} ... }
    log = log,
    -- per-event-type bookkeeping used by the evolver to detect "needs"
    stats = {},       -- type -> { fired=, handled=, unhandled_streak= }
    history = {},     -- recent events (ring buffer)
    hcap = 200,
  }, Bus)
end

local function stat(self, t)
  local s = self.stats[t]
  if not s then s = { fired = 0, handled = 0, unhandled_streak = 0 }; self.stats[t] = s end
  return s
end

-- subscribe(event_type, fn, owner) -> handle to allow later removal
-- fn(event) should return true if it "handled" the stimulus (affects fitness).
function Bus:subscribe(t, fn, owner)
  self.subs[t] = self.subs[t] or {}
  local h = { id = #self.subs[t] + 1, fn = fn, owner = owner or "anon" }
  table.insert(self.subs[t], h)
  return h
end

-- remove every subscription registered by a given owner (used on retire/reload)
function Bus:unsubscribe_owner(owner)
  for _, list in pairs(self.subs) do
    for i = #list, 1, -1 do
      if list[i].owner == owner then table.remove(list, i) end
    end
  end
end

-- publish a stimulus; returns number of reactors that claimed to handle it
function Bus:emit(t, payload)
  local ev = { type = t, data = payload or {}, at = os.time() }
  local s = stat(self, t)
  s.fired = s.fired + 1

  -- ring-buffer history (for the evolver / reporter)
  table.insert(self.history, ev)
  if #self.history > self.hcap then table.remove(self.history, 1) end

  local handled = 0
  local list = self.subs[t]
  if list then
    for _, h in ipairs(list) do
      local ok, res = pcall(h.fn, ev)
      if not ok then
        if self.log then self.log:warn("reactor '%s' errored on '%s': %s", h.owner, t, tostring(res)) end
        -- a throwing reactor emits a self-stimulus the organism can react to
        self:emit_raw("self.error", { owner = h.owner, on = t, err = tostring(res) })
      elseif res == true or (type(res) == "table" and res.handled) then
        handled = handled + 1
        if type(res) == "table" and res.reward and h.owner then
          self:emit_raw("self.reward", { owner = h.owner, amount = res.reward })
        else
          self:emit_raw("self.reward", { owner = h.owner, amount = 1 })
        end
      end
    end
  end

  if handled > 0 then
    s.handled = s.handled + 1
    s.unhandled_streak = 0
  else
    s.unhandled_streak = s.unhandled_streak + 1
  end
  return handled
end

-- emit without recursive bookkeeping (internal reward/error signalling)
function Bus:emit_raw(t, payload)
  local list = self.subs[t]
  if not list then return 0 end
  local n = 0
  for _, h in ipairs(list) do
    local ok = pcall(h.fn, { type = t, data = payload or {}, at = os.time() })
    if ok then n = n + 1 end
  end
  return n
end

function Bus:event_types()
  local out = {}
  for t in pairs(self.stats) do out[#out + 1] = t end
  table.sort(out)
  return out
end

return Bus
