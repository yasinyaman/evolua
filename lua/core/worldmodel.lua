-- core/worldmodel.lua — the organism's situational memory
-- Folds raw stimuli (proc.hot / proc.sample / proc.error) into per-ENTITY
-- dossiers (keyed by process name). This is "what is going on", not "what just
-- happened" — the substrate the rule summary (Faz 1) and the LLM reasoner
-- (Faz 2) interpret. Unseen entities fade, so the model reflects the present.

local WorldModel = {}
WorldModel.__index = WorldModel

function WorldModel.new(ctx)
  return setmetatable({ ctx = ctx, entities = {} }, WorldModel)
end

local function ema(prev, x, a)
  if prev == nil then return x end
  return prev * (1 - a) + x * a
end

function WorldModel:_entity(name)
  local e = self.entities[name]
  if not e then
    e = {
      name = name, first_seen = self.ctx.kernel.tick, last_seen = self.ctx.kernel.tick,
      hot_ticks = 0, cpu_avg = nil, prev_cpu = nil, mem_mb = 0,
      errors = 0, last_error = nil, trend = "→",
    }
    self.entities[name] = e
  end
  return e
end

-- wire dossiers to the stimulus stream
function WorldModel:attach()
  local bus = self.ctx.bus

  bus:subscribe("proc.hot", function(ev)
    local d = ev.data
    local e = self:_entity(d.name)
    e.last_seen = self.ctx.kernel.tick
    e.pid = d.pid or e.pid
    e.hot_ticks = e.hot_ticks + 1
    e.prev_cpu = e.cpu_avg
    e.cpu_avg = ema(e.cpu_avg, d.cpu or 0, 0.4)
    e.mem_mb = math.max(e.mem_mb, d.mem_mb or 0)
    e.last_reason = d.reason
    self:_update_trend(e)
    return { handled = true, reward = 1 }  -- perceiving counts as handling the stimulus
  end, "worldmodel")

  bus:subscribe("proc.sample", function(ev)
    for _, t in ipairs(ev.data.top or {}) do
      local e = self:_entity(t.name)
      e.last_seen = self.ctx.kernel.tick
      e.prev_cpu = e.cpu_avg
      e.cpu_avg = ema(e.cpu_avg, t.cpu or 0, 0.25)
      e.mem_mb = math.max(e.mem_mb, t.mem_mb or 0)
      self:_update_trend(e)
    end
    -- a sample is ambient context, not a "need" → don't mark handled
  end, "worldmodel")

  bus:subscribe("proc.detail", function(ev)
    local e = self:_entity(ev.data.name)
    e.profile = ev.data.detail
    e.last_seen = self.ctx.kernel.tick
    -- knowing more about an entity is mild progress, not a "need" being met
  end, "worldmodel")

  bus:subscribe("proc.error", function(ev)
    local e = self:_entity(ev.data.name or "system")
    e.last_seen = self.ctx.kernel.tick
    e.errors = e.errors + 1
    e.last_error = (ev.data.msg or ""):sub(1, 160)
    return { handled = true, reward = 2 }
  end, "worldmodel")
end

function WorldModel:_update_trend(e)
  if e.prev_cpu and e.cpu_avg then
    if e.cpu_avg > e.prev_cpu * 1.15 then e.trend = "↑"
    elseif e.cpu_avg < e.prev_cpu * 0.85 then e.trend = "↓"
    else e.trend = "→" end
  end
end

-- salience: how much this entity "matters" right now
function WorldModel:salience(e)
  local persist = math.min(e.hot_ticks, 30) * 0.5
  return (e.cpu_avg or 0) + e.errors * 15 + persist + (e.last_reason == "mem" and 10 or 0)
end

-- forget entities not seen for a while (keeps the model in the present)
function WorldModel:decay(max_age)
  max_age = max_age or 60
  local now = self.ctx.kernel.tick
  for name, e in pairs(self.entities) do
    if now - e.last_seen > max_age then self.entities[name] = nil end
  end
end

-- ranked, compact view for the reporter (Faz 1) and the reasoner snapshot (Faz 2)
function WorldModel:snapshot(limit)
  local list = {}
  for _, e in pairs(self.entities) do list[#list + 1] = e end
  table.sort(list, function(a, b) return self:salience(a) > self:salience(b) end)
  if limit then
    local trimmed = {}
    for i = 1, math.min(limit, #list) do trimmed[i] = list[i] end
    list = trimmed
  end
  return list
end

return WorldModel
