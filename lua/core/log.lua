-- core/log.lua — leveled logger (console + file)
local Log = {}
Log.__index = Log

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local COLOR = { debug = "\27[90m", info = "\27[36m", warn = "\27[33m", error = "\27[31m" }
local RESET = "\27[0m"

function Log.new(opts)
  opts = opts or {}
  local self = setmetatable({
    min = LEVELS[opts.level or "info"] or 2,
    color = opts.color ~= false,
    path = opts.path,
  }, Log)
  if self.path then
    local fh = io.open(self.path, "a")
    if fh then fh:close() end
  end
  return self
end

function Log:_write(level, msg)
  if (LEVELS[level] or 2) < self.min then return end
  local ts = os.date("%H:%M:%S")
  local line = string.format("[%s] %-5s %s", ts, level:upper(), msg)
  if self.color then
    io.write(COLOR[level] or "", line, RESET, "\n")
  else
    io.write(line, "\n")
  end
  if self.path then
    local fh = io.open(self.path, "a")
    if fh then fh:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n"); fh:close() end
  end
end

local function mk(level)
  return function(self, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    self:_write(level, ok and msg or tostring(fmt))
  end
end

Log.debug = mk("debug")
Log.info  = mk("info")
Log.warn  = mk("warn")
Log.error = mk("error")

return Log
