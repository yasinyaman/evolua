-- core/log.lua — leveled logger (console + file)
local Log = {}
Log.__index = Log

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local COLOR = { debug = "\27[90m", info = "\27[36m", warn = "\27[33m", error = "\27[31m" }
local RESET = "\27[0m"

-- Append text to path. Once the file passes max_bytes it is rotated to
-- path..".1" (one generation kept) so a long-lived organism's logs stay bounded.
-- header (optional) is written first into a fresh file. Shared by every
-- append-only file the organism keeps (evolua.log, evolution.log, audit.log).
function Log.append(path, text, max_bytes, header)
  local fh = io.open(path, "a")
  if not fh then return false end
  local size = fh:seek("end") or 0
  if max_bytes and max_bytes > 0 and size >= max_bytes then
    fh:close()
    os.remove(path .. ".1")
    os.rename(path, path .. ".1")
    fh = io.open(path, "a")
    if not fh then return false end
    size = 0
  end
  if size == 0 and header then fh:write(header) end
  fh:write(text)
  fh:close()
  return true
end

function Log.new(opts)
  opts = opts or {}
  local self = setmetatable({
    min = LEVELS[opts.level or "info"] or 2,
    color = opts.color ~= false,
    path = opts.path,
    max_bytes = opts.max_bytes,
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
    Log.append(self.path, os.date("%Y-%m-%d %H:%M:%S ") .. line .. "\n", self.max_bytes)
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
