-- core/platform.lua — OS abstraction for perception & action
-- One place that knows the per-OS commands, so sensors stay platform-agnostic.
-- Pure Lua + io.popen; no luaposix / luafilesystem dependency.

local M = {}

-- ── OS detection ──────────────────────────────────────────────────────────
local function detect_os()
  if package.config:sub(1, 1) == "\\" then return "windows" end
  -- unix: distinguish macOS vs Linux via uname
  local p = io.popen and io.popen("uname -s 2>/dev/null")
  if p then
    local s = (p:read("*l") or ""):lower()
    p:close()
    if s:find("darwin") then return "macos" end
    if s:find("linux") then return "linux" end
    if s ~= "" then return s end
  end
  return "unknown"
end

M.os = detect_os()
M.sep = package.config:sub(1, 1)

-- ── shell capture helper ─────────────────────────────────────────────────
-- Run a command, return its stdout as a string (or "" on failure). Safe: any
-- error is swallowed so a missing tool never crashes a sensor.
function M.run(cmd)
  if not io.popen then return "" end
  local ok, p = pcall(io.popen, cmd)
  if not ok or not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return out
end

-- ── own PID (to exclude self from process perception) ────────────────────
function M.self_pid()
  -- Linux: /proc/self/stat first field is our pid. macOS: no /proc → nil.
  local fh = io.open("/proc/self/stat", "r")
  if fh then
    local s = fh:read("*l") or ""
    fh:close()
    return tonumber(s:match("^(%d+)"))
  end
  return nil
end

-- ── process list: {pid, name, cpu, mem_mb} for every process ─────────────
-- cpu = %CPU as reported by ps (can exceed 100 across cores). mem from RSS(KB).
function M.proc_list()
  local cmd
  if M.os == "macos" then
    cmd = "ps -axo pid=,pcpu=,rss=,comm= 2>/dev/null"
  elseif M.os == "windows" then
    -- PowerShell two-sample delta → instantaneous %CPU per process, plus RSS.
    -- Emits the SAME columns as ps: "pid pcpu rss(KB) name", so one parser fits all.
    cmd = [[powershell -NoProfile -Command "$a=Get-Process|Select Id,@{N='c';E={$_.CPU}};Start-Sleep -Milliseconds 300;$b=Get-Process|Select Id,ProcessName,@{N='m';E={[math]::Round($_.WorkingSet64/1MB)}},@{N='c';E={$_.CPU}};$h=@{};$a|%{$h[$_.Id]=$_.c};$b|%{$d=($_.c-$h[$_.Id]);if($d -lt 0){$d=0};$p=[math]::Round($d/0.3/[Environment]::ProcessorCount*100);('{0} {1} {2} {3}' -f $_.Id,$p,($_.m*1024),$_.ProcessName)}" 2>nul]]
  else
    cmd = "ps -eo pid=,pcpu=,rss=,comm= 2>/dev/null"
  end
  local out = {}
  if not cmd then return out end
  for line in M.run(cmd):gmatch("[^\n]+") do
    -- pid  pcpu  rss(KB)  comm(rest of line, may contain spaces/path)
    local pid, cpu, rss, name = line:match("^%s*(%d+)%s+([%d%.]+)%s+(%d+)%s+(.+)$")
    if pid then
      -- keep just the basename of comm (strip path)
      local base = name:match("([^/\\]+)%s*$") or name
      out[#out + 1] = {
        pid = tonumber(pid),
        cpu = tonumber(cpu) or 0,
        mem_mb = (tonumber(rss) or 0) / 1024,
        name = base:gsub("%s+$", ""),
      }
    end
  end
  return out
end

-- ── recent OS-level error/crash lines (best-effort, per OS) ───────────────
-- Returns an array of short strings. Sensors decide how to interpret them.
function M.recent_errors(window_secs)
  window_secs = window_secs or 120
  local lines = {}
  local raw = ""
  if M.os == "macos" then
    -- error-and-above messages from the unified log over the window
    local mins = math.max(1, math.floor(window_secs / 60))
    raw = M.run(string.format(
      "log show --last %dm --style compact --predicate 'messageType >= 16' 2>/dev/null | tail -n 200",
      mins))
  elseif M.os == "linux" then
    -- prefer journald; fall back to dmesg
    raw = M.run(string.format(
      "journalctl --since '-%d seconds' -p err -q --no-pager 2>/dev/null | tail -n 200",
      window_secs))
    if raw == "" then
      raw = M.run("dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -n 50")
    end
  elseif M.os == "windows" then
    -- Application + System logs, Critical(1)+Error(2) over the window.
    -- "ProviderName: message" → the attributor picks the provider as the entity.
    raw = M.run(string.format(
      [[powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application','System';Level=1,2;StartTime=(Get-Date).AddSeconds(-%d)} -MaxEvents 50 -EA SilentlyContinue | %%{('{0}: {1}' -f $_.ProviderName,($_.Message -replace '\r?\n',' '))}" 2>nul]],
      window_secs))
  end
  for line in raw:gmatch("[^\n]+") do lines[#lines + 1] = line:sub(1, 240) end
  return lines
end

-- ── action helpers (used by the autonomy layer, Faz 3) ───────────────────
-- Lower a process's scheduling priority. Reversible (restore to normal), so it
-- is eligible for autonomous use; it never kills work, only de-prioritises it.
function M.set_priority(pid, level)
  if not pid then return false end
  if M.os == "windows" then
    local cls = (level == "low") and "BelowNormal" or "Normal"
    M.run(string.format([[powershell -NoProfile -Command "(Get-Process -Id %d).PriorityClass='%s'" 2>nul]], pid, cls))
  else
    local nice = (level == "low") and "10" or "0"
    M.run(string.format("renice %s -p %d 2>/dev/null", nice, pid))
  end
  return true
end

-- Terminate a process. DESTRUCTIVE → never autonomous; only via explicit approval.
function M.kill(pid)
  if not pid then return false end
  if M.os == "windows" then
    M.run(string.format("taskkill /PID %d /F 2>nul", pid))
  else
    M.run(string.format("kill %d 2>/dev/null", pid))
  end
  return true
end

-- list a directory's entries (cross-OS), returns an array of names
function M.list_dir(path)
  local out = {}
  local cmd = (M.os == "windows")
    and ('dir /b "' .. path .. '" 2>nul')
    or  ('ls -1 "' .. path .. '" 2>/dev/null')
  for line in M.run(cmd):gmatch("[^\r\n]+") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

-- deep-probe a process (curiosity layer): its command line / image path
function M.proc_detail(pid)
  if not pid then return "" end
  local out
  if M.os == "windows" then
    out = M.run(string.format([[powershell -NoProfile -Command "(Get-Process -Id %d).Path" 2>nul]], pid))
  else
    out = M.run(string.format("ps -o args= -p %d 2>/dev/null", pid))
  end
  return (out or ""):gsub("%s+$", ""):sub(1, 200)
end

-- ── user-facing notification (action layer) ──────────────────────────────
function M.notify(title, msg)
  title = (title or "EvoLua"):gsub('"', "'")
  msg = (msg or ""):gsub('"', "'")
  if M.os == "macos" then
    M.run(string.format('osascript -e \'display notification "%s" with title "%s"\' 2>/dev/null', msg, title))
  elseif M.os == "linux" then
    M.run(string.format('notify-send "%s" "%s" 2>/dev/null', title, msg))
  elseif M.os == "windows" then
    -- msg.exe (present on most Windows); harmless no-op if unavailable
    M.run(string.format('msg * /TIME:10 "%s: %s" 2>nul', title, msg))
  end
end

return M
