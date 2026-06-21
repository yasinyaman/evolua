-- sensors/sys_metrics.lua — perceive system resource state
-- Linux-first (reads /proc); falls back to shelling out on macOS. Emits:
--   metric.cpu  { pct }     CPU utilisation since last sample
--   metric.mem  { pct, used_mb, total_mb }
--   metric.load { one }     1-min load average
-- The sensor adapts: if a metric stays calm, it widens its own interval;
-- if it spikes, it samples faster. Behaviour is not fixed.

local function read_file(p)
  local fh = io.open(p, "r"); if not fh then return nil end
  local s = fh:read("*a"); fh:close(); return s
end

local function cpu_snapshot()
  local s = read_file("/proc/stat")
  if not s then return nil end
  local line = s:match("cpu%s+([%d ]+)")
  if not line then return nil end
  local nums = {}
  for v in line:gmatch("%d+") do nums[#nums + 1] = tonumber(v) end
  if #nums < 4 then return nil end
  local idle = nums[4] + (nums[5] or 0)
  local total = 0
  for _, v in ipairs(nums) do total = total + v end
  return total, idle
end

return {
  name = "sys_metrics",
  desc = "perceives CPU / memory / load and emits metric.* stimuli",
  events = { "metric.cpu", "metric.mem", "metric.load" },

  -- adaptive sampling state
  _prev = nil,
  _interval = 1,   -- ticks between samples
  _wait = 0,

  sense = function(self, ctx)
    self._wait = (self._wait or 0) - 1
    if self._wait > 0 then return end

    local active = false

    -- CPU (delta of /proc/stat)
    local total, idle = cpu_snapshot()
    if total and self._prev then
      local dt = total - self._prev.total
      local di = idle - self._prev.idle
      if dt > 0 then
        local pct = math.floor((1 - di / dt) * 100 + 0.5)
        ctx.bus:emit("metric.cpu", { pct = pct })
        if pct > 60 then active = true end
      end
    end
    if total then self._prev = { total = total, idle = idle } end

    -- Memory (/proc/meminfo)
    local mi = read_file("/proc/meminfo")
    if mi then
      local tot = tonumber(mi:match("MemTotal:%s+(%d+)")) or 0
      local avail = tonumber(mi:match("MemAvailable:%s+(%d+)")) or 0
      if tot > 0 then
        local used = tot - avail
        local pct = math.floor(used / tot * 100 + 0.5)
        ctx.bus:emit("metric.mem", { pct = pct, used_mb = math.floor(used / 1024), total_mb = math.floor(tot / 1024) })
        if pct > 80 then active = true end
      end
    end

    -- Load average
    local la = read_file("/proc/loadavg")
    if la then
      local one = tonumber(la:match("^([%d%.]+)"))
      if one then ctx.bus:emit("metric.load", { one = one }) end
    end

    -- adapt interval: calm -> slower, busy -> faster (self-modifying behaviour)
    if active then
      self._interval = math.max(1, self._interval - 1)
    else
      self._interval = math.min(8, self._interval + 1)
    end
    self._wait = self._interval
  end,
}
