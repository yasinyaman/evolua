-- sensors/proc_errors.lua — perceive errors & crashes, attributed to a process
-- Reads OS-level error/crash logs (macOS unified log, Linux journald/dmesg) via
-- the platform layer, attributes each line to a process name when possible, and
-- emits:  proc.error { name, msg, source }
-- De-dupes: only newly-seen lines are emitted each pass.

local P = require("core.platform")

-- pull a process name out of a log line, best-effort across formats:
--   syslog/journald:  "kernel: ..."  /  "Chrome[1234]: ..."  /  "comm[pid]:"
--   macOS compact:    "... processName[pid] ..."
local function attribute(line)
  -- Linux OOM killer: "Killed process 9001 (node)" → node
  local n = line:match("[Kk]illed process %d+ %(([%w%._%-]+)%)")
  if n then return n end
  -- name[pid]  (syslog / unified log, most reliable)
  n = line:match("([%w%._%-]+)%[%d+%]")
  if n then return n end
  -- "<timestamp> host <ident>: rest"  → the syslog identifier before the colon
  n = line:match("[%a%d_%-%.]+%s+([%w%._%-]+):%s")
  if n and #n > 1 and not n:match("^%d+$") then return n end
  return "system"
end

return {
  name = "proc_errors",
  desc = "perceives OS errors/crashes attributed to a process; emits proc.error",
  events = { "proc.error" },
  _attribute = attribute,   -- for tests

  _seen = {},        -- hash set of recently emitted lines (bounded)
  _seen_order = {},  -- FIFO of hashes to bound memory
  _interval = 5,
  _wait = 0,

  _mark = function(self, key)
    if self._seen[key] then return false end
    self._seen[key] = true
    self._seen_order[#self._seen_order + 1] = key
    if #self._seen_order > 400 then
      local old = table.remove(self._seen_order, 1)
      self._seen[old] = nil
    end
    return true
  end,

  sense = function(self, ctx)
    self._wait = (self._wait or 0) - 1
    if self._wait > 0 then return end
    self._wait = self._interval

    local window = ctx.cfg.error_window_secs or 120
    local lines = P.recent_errors(window)
    for _, line in ipairs(lines) do
      -- key on a trimmed line so identical repeats don't re-fire
      local key = line:gsub("%s+", " "):sub(1, 160)
      if self:_mark(key) then
        ctx.bus:emit("proc.error", {
          name = attribute(line),
          msg = line,
          source = P.os,
        })
      end
    end
  end,
}
