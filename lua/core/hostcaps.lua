-- core/hostcaps.lua — measure the host so the organism can size its own model
-- Reads RAM / cores / arch / power / free disk across macOS, Linux, Windows.
-- Cheap and best-effort: any unknown field degrades gracefully (nil / sane
-- default), never throws. Feeds the model ladder (core/modelmgr.lua, Faz 4).

local P = require("core.platform")

local M = {}

local function readfile(p)
  local fh = io.open(p, "r"); if not fh then return nil end
  local s = fh:read("*a"); fh:close(); return s
end

-- total / available RAM in MB
local function ram_mb()
  if P.os == "linux" then
    local mi = readfile("/proc/meminfo") or ""
    local tot = tonumber(mi:match("MemTotal:%s+(%d+)")) -- KB
    local av  = tonumber(mi:match("MemAvailable:%s+(%d+)"))
    if tot then return math.floor(tot / 1024), av and math.floor(av / 1024) or nil end
  elseif P.os == "macos" then
    local tot = tonumber(P.run("sysctl -n hw.memsize 2>/dev/null"):match("%d+"))
    -- "Pages free" alone is misleading on macOS (the OS keeps free near zero and
    -- uses the rest for cache). Available ≈ free + reclaimable (inactive +
    -- speculative + purgeable) pages.
    local vm = P.run("vm_stat 2>/dev/null")
    local function pages(k) return tonumber(vm:match(k .. ":%s+(%d+)")) or 0 end
    local reclaimable = pages("Pages free") + pages("Pages inactive")
                      + pages("Pages speculative") + pages("Pages purgeable")
    local total = tot and math.floor(tot / 1048576) or nil
    local avail = reclaimable > 0 and math.floor(reclaimable * 4096 / 1048576) or nil
    return total, avail
  elseif P.os == "windows" then
    local out = P.run([[powershell -NoProfile -Command "$o=Get-CimInstance Win32_OperatingSystem; '{0} {1}' -f $o.TotalVisibleMemorySize,$o.FreePhysicalMemory" 2>nul]])
    local tot, free = out:match("(%d+)%s+(%d+)") -- KB
    if tot then return math.floor(tonumber(tot) / 1024), math.floor(tonumber(free) / 1024) end
  end
  return nil, nil
end

local function cores()
  if P.os == "linux" then
    local n = 0
    for _ in (readfile("/proc/cpuinfo") or ""):gmatch("processor%s*:") do n = n + 1 end
    if n > 0 then return n end
    return tonumber(P.run("nproc 2>/dev/null"):match("%d+"))
  elseif P.os == "macos" then
    return tonumber(P.run("sysctl -n hw.ncpu 2>/dev/null"):match("%d+"))
  elseif P.os == "windows" then
    return tonumber((os.getenv("NUMBER_OF_PROCESSORS") or "")) or
           tonumber(P.run([[powershell -NoProfile -Command "[Environment]::ProcessorCount" 2>nul]]):match("%d+"))
  end
end

local function arch()
  if P.os == "windows" then return os.getenv("PROCESSOR_ARCHITECTURE") or "?" end
  return (P.run("uname -m 2>/dev/null"):gsub("%s+$", ""))
end

-- true if running on battery (so we avoid heavy downloads / upgrades)
local function on_battery()
  if P.os == "linux" then
    local s = readfile("/sys/class/power_supply/AC/online")
          or readfile("/sys/class/power_supply/ACAD/online")
    if s then return s:match("0") ~= nil end
  elseif P.os == "macos" then
    return P.run("pmset -g batt 2>/dev/null"):find("Battery Power") ~= nil
  elseif P.os == "windows" then
    -- BatteryStatus 2 = plugged in (AC)
    local st = P.run([[powershell -NoProfile -Command "(Get-CimInstance Win32_Battery).BatteryStatus" 2>nul]]):match("%d+")
    if st then return st ~= "2" end
  end
  return false -- assume AC if unknown
end

-- free disk (MB) for a directory
local function disk_free_mb(path)
  if P.os == "windows" then
    local out = P.run(string.format(
      [[powershell -NoProfile -Command "(Get-Item '%s').PSDrive.Free" 2>nul]], path))
    local b = tonumber(out:match("%d+"))
    return b and math.floor(b / 1048576) or nil
  else
    -- df -Pk: available KB in 4th column of the data row
    local out = P.run(string.format("df -Pk '%s' 2>/dev/null | tail -n 1", path))
    local avail = out:match("%S+%s+%d+%s+%d+%s+(%d+)")
    return avail and math.floor(tonumber(avail) / 1024) or nil
  end
end

-- probe everything; returns a flat capability table
function M.probe(models_dir)
  local total, avail = ram_mb()
  return {
    os = P.os,
    arch = arch(),
    cores = cores() or 1,
    ram_total_mb = total,
    ram_avail_mb = avail or total,            -- fall back to total if avail unknown
    on_battery = on_battery(),
    disk_free_mb = disk_free_mb(models_dir or "."),
  }
end

return M
