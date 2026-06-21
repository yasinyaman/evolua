-- sensors/proc_top.lua — per-process resource perception
-- Answers "WHICH app is eating resources" (vs sys_metrics' aggregate view).
-- Emits:
--   proc.hot { name, pid, cpu, mem_mb, reason }   when a process crosses a threshold
--   proc.sample { top = {...} }                    a light snapshot of top consumers
-- Adaptive: samples less often when the machine is calm, faster when something is hot.

local P = require("core.platform")

return {
  name = "proc_top",
  desc = "perceives per-process CPU/RAM; emits proc.hot / proc.sample",
  events = { "proc.hot", "proc.sample" },

  _interval = 3,
  _wait = 0,

  sense = function(self, ctx)
    self._wait = (self._wait or 0) - 1
    if self._wait > 0 then return end

    local cpu_thr = ctx.cfg.proc_cpu_threshold or 50      -- %CPU (per ps, may exceed 100 over cores)
    local mem_thr = ctx.cfg.proc_mem_threshold_mb or 1500 -- MB RSS
    local ignore  = ctx.cfg.ignore_procs or {}
    local watch   = ctx.cfg.watch_procs                    -- nil = watch all
    local selfpid = P.self_pid()

    local function ignored(name)
      for _, n in ipairs(ignore) do if name == n then return true end end
      if watch then
        for _, n in ipairs(watch) do if name == n then return false end end
        return true -- watch list set and name not on it
      end
      return false
    end

    local procs = P.proc_list()
    -- aggregate by process name (apps spawn many helpers → sum them)
    local agg = {}
    for _, pr in ipairs(procs) do
      if pr.pid ~= selfpid and not ignored(pr.name) then
        local a = agg[pr.name]
        if not a then a = { name = pr.name, pid = pr.pid, cpu = 0, mem_mb = 0, procs = 0 }; agg[pr.name] = a end
        a.cpu = a.cpu + pr.cpu
        a.mem_mb = a.mem_mb + pr.mem_mb
        a.procs = a.procs + 1
      end
    end

    -- rank and emit
    local ranked = {}
    for _, a in pairs(agg) do ranked[#ranked + 1] = a end
    table.sort(ranked, function(x, y) return (x.cpu + x.mem_mb / 50) > (y.cpu + y.mem_mb / 50) end)

    local any_hot = false
    for _, a in ipairs(ranked) do
      local reason
      if a.cpu >= cpu_thr then reason = "cpu"
      elseif a.mem_mb >= mem_thr then reason = "mem" end
      if reason then
        any_hot = true
        ctx.bus:emit("proc.hot", {
          name = a.name, pid = a.pid, cpu = a.cpu, mem_mb = a.mem_mb,
          procs = a.procs, reason = reason,
        })
      end
    end

    -- light snapshot of the top consumers for the world model (even sub-threshold)
    local top = {}
    for i = 1, math.min(5, #ranked) do
      local a = ranked[i]
      top[i] = { name = a.name, cpu = a.cpu, mem_mb = a.mem_mb }
    end
    ctx.bus:emit("proc.sample", { top = top })

    -- adapt cadence
    if any_hot then self._interval = math.max(1, self._interval - 1)
    else self._interval = math.min(8, self._interval + 1) end
    self._wait = self._interval
  end,
}
