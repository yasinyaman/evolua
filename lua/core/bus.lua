-- core/bus.lua — Event bus (pub/sub)
-- The nervous system of the organism. Sensors publish "stimuli", plugins
-- subscribe and react. Subscriptions are fully dynamic: behavior can change
-- at runtime as plugins are born, mutated, or retired.

local clock = require("core.platform").clock   -- wall-clock in the binary, CPU time in plain Lua

local Bus = {}
Bus.__index = Bus

function Bus.new(log, cfg)
  return setmetatable({
    subs = {},        -- event_type -> { {id=, fn=, owner=} ... }
    log = log,
    cfg = cfg or {},  -- honest-reward tunables (reward_base/gap_cap/cost_weight/share)
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
  -- re-entrancy guard: reactors may emit derived stimuli (legit pipelines), but a
  -- cycle (e.g. two rule organs pinging each other via alert.*) would recurse to a
  -- C-stack overflow. Cap the depth and bail instead of running the loop to death.
  self._depth = (self._depth or 0) + 1
  if self._depth > ((self.cfg and self.cfg.max_emit_depth) or 8) then
    self._depth = self._depth - 1
    if self.log then self.log:warn("bus: emit-depth cap on '%s' — breaking a possible emit loop", t) end
    return 0
  end
  -- the organ whose reactor is running right now emitted this (nil = a sensor or
  -- core). Tracked by the bus itself, so an organ can't claim to be someone else.
  local emitter = self._reactor
  local ev = { type = t, data = payload or {}, at = os.time(), emitter = emitter }
  local s = stat(self, t)
  s.fired = s.fired + 1

  -- ring-buffer history (for the evolver / reporter)
  table.insert(self.history, ev)
  if #self.history > self.hcap then table.remove(self.history, 1) end

  -- HONEST REWARD: fitness is derived from observable bus facts, NOT from the
  -- reward number the organ declares about itself (the old `res.reward`, which
  -- let an organ — e.g. the colony every heartbeat — mint its own fitness).
  --   gap   = surprise: filling a starved stimulus (high unhandled_streak) is
  --           worth more than re-handling a metronome (heartbeat → streak 0).
  --   share = a stimulus's credit is split across its co-handlers (#10): a lone
  --           handler of a real need outranks one of N riders on the same event.
  --   cost  = measured reactor time is subtracted (#5 parsimony): a pricey
  --           reactor can't out-earn a lean one doing the same job. Wall-clock
  --           in the binary, so shelling out to find/ps/lsof is charged too.
  --   self  = an organ earns nothing for handling a stimulus it emitted itself
  --           (the supervisor emitting host.vitals every tick and then handling
  --           it would otherwise mint its own fitness, like the old res.reward).
  -- The organ's res.reward is carried only as telemetry (`hint`), never fitness.
  local cfg    = self.cfg or {}
  local base   = cfg.reward_base or 1
  local gapcap = cfg.reward_gap_cap or 8
  local costw  = cfg.reward_cost_weight or 0.5
  local share_on = cfg.fitness_share ~= false
  local gap    = 1 + math.min(s.unhandled_streak, gapcap)  -- streak BEFORE this emit

  local handled = 0
  local claimed = {}     -- handlers that earned credit, paid after the loop
  local list = self.subs[t]
  if list then
    for _, h in ipairs(list) do
      local outer = self._reactor
      self._reactor = h.owner
      local t0 = clock()
      local ok, res = pcall(h.fn, ev)
      local cost = clock() - t0
      self._reactor = outer
      if not ok then
        if self.log then self.log:warn("reactor '%s' errored on '%s': %s", h.owner, t, tostring(res)) end
        -- a throwing reactor emits a self-stimulus the organism can react to
        self:emit_raw("self.error", { owner = h.owner, on = t, err = tostring(res) })
      elseif res == true or (type(res) == "table" and res.handled) then
        handled = handled + 1
        if h.owner and h.owner ~= emitter then
          claimed[#claimed + 1] = { owner = h.owner, cost = cost,
            hint = (type(res) == "table" and res.reward) or nil }
        end
      end
    end
  end

  -- distribute the stimulus's credit across THIS emit's handlers
  local share = share_on and math.max(1, #claimed) or 1
  for _, c in ipairs(claimed) do
    local amount = (base * gap) / share - costw * c.cost
    if amount < 0 then amount = 0 end
    self:emit_raw("self.reward",
      { owner = c.owner, amount = amount, gap = gap, share = share, hint = c.hint })
  end

  if handled > 0 then
    s.handled = s.handled + 1
    s.unhandled_streak = 0
  else
    s.unhandled_streak = s.unhandled_streak + 1
  end
  self._depth = self._depth - 1
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
