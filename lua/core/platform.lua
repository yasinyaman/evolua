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

-- ── shell quoting ────────────────────────────────────────────────────────
-- Quote ONE argument for the shell io.popen / os.execute run. Every command
-- built from a path or other data must pass it through here. POSIX: single
-- quotes, each embedded ' written as '\'' — nothing inside is special any more.
-- Windows cmd has no real escape; double quotes with "" for an embedded quote is
-- the convention most programs parse.
function M.shq(s)
  s = tostring(s)
  if M.os == "windows" then return '"' .. s:gsub('"', '""') .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Is this a path we're willing to perceive (watch, tail, hand to a command)?
-- Rejects control characters and shell metacharacters outright: even quoted,
-- a directory called `x"; rm …` is an accident or an attack, not a target.
function M.safe_path(p)
  if type(p) ~= "string" or p == "" then return false end
  if p:find("[%c`$\"';&|<>*?!]") then return false end
  if M.os ~= "windows" and p:find("\\", 1, true) then return false end
  return true
end

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

-- ── time ─────────────────────────────────────────────────────────────────
-- Seconds for measuring how long something took. In the binary: monotonic
-- wall-clock (host_now_ms), which includes time spent waiting on child
-- processes. Plain Lua has no wall clock finer than os.time(), so it falls back
-- to os.clock() — this process's CPU time only.
function M.clock()
  local host = rawget(_G, "host_now_ms")
  if host then return host() / 1000 end
  return os.clock()
end

-- Pause for sec seconds (fractions allowed). The binary sleeps natively; plain
-- Lua has no sleep, so it shells out — `sleep` on unix, PowerShell on Windows
-- (cmd has no fractional-second sleep).
function M.sleep(sec)
  if not sec or sec <= 0 then return end
  local host = rawget(_G, "host_sleep_ms")
  if host then return host(sec * 1000) end
  if M.os == "windows" then
    os.execute(string.format('powershell -NoProfile -Command "Start-Sleep -Milliseconds %d" 2>nul', math.floor(sec * 1000)))
  else
    os.execute("sleep " .. tostring(sec) .. " 2>/dev/null")
  end
end

-- ── filesystem (host bindings when embedded, quoted shell otherwise) ──────
-- In the binary these go through src/host.rs — no shell at all. Plain-Lua runs
-- fall back to shell commands, with every path quoted by M.shq.

-- list a directory's entries, sorted; {} if unreadable
function M.list_dir(path)
  local host = rawget(_G, "host_list_dir")
  if host then return host(path) or {} end
  local out = {}
  local cmd = (M.os == "windows")
    and ("dir /b " .. M.shq(path) .. " 2>nul")
    or  ("ls -1 " .. M.shq(path) .. " 2>/dev/null")
  for line in M.run(cmd):gmatch("[^\r\n]+") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

-- create a directory and its parents (ok if it exists)
function M.mkdir_p(path)
  local host = rawget(_G, "host_mkdir")
  if host then return host(path) end
  if M.os == "windows" then os.execute("mkdir " .. M.shq(path) .. " 2>nul")
  else os.execute("mkdir -p " .. M.shq(path) .. " 2>/dev/null") end
  return true
end

-- the process's current working directory (nil if unknown)
function M.cwd()
  local host = rawget(_G, "host_cwd")
  if host then return host() end
  local pwd = os.getenv("PWD")
  if pwd and pwd ~= "" then return pwd end
  local out = M.run(M.os == "windows" and "cd" or "pwd 2>/dev/null"):gsub("%s+$", "")
  return out ~= "" and out or nil
end

-- Walk `root` breadth-first down to opts.depth (root's children are depth 1),
-- like `find -mindepth 1 -maxdepth N`. Returns { {path, dir, mtime, size}, … }.
-- opts: depth (1), limit (1000, counted after filtering), kind ("dir"|"file"),
-- suffix (e.g. ".log"), prune (directory names never descended into).
-- Symlinks are not followed.
function M.walk(root, opts)
  opts = opts or {}
  local host = rawget(_G, "host_walk")
  if host then return host(root, opts) end
  local depth, limit = opts.depth or 1, opts.limit or 1000
  local cmd
  if M.os == "linux" then
    cmd = "find " .. M.shq(root) .. " -mindepth 1 -maxdepth " .. math.floor(depth) ..
          " -printf '%y\\t%T@\\t%s\\t%p\\n' 2>/dev/null"
  elseif M.os == "windows" then
    local ps = root:gsub("'", "''")
    cmd = 'powershell -NoProfile -Command "Get-ChildItem -LiteralPath \'' .. ps .. '\' -Recurse -Force -Depth ' ..
          math.max(0, math.floor(depth) - 1) .. ' -EA SilentlyContinue | %{ \'{0}`t{1}`t{2}`t{3}\' -f ' ..
          '$(if($_.PSIsContainer){\'d\'}else{\'f\'}), ' ..
          '[int64](($_.LastWriteTimeUtc - [datetime]\'1970-01-01\').TotalSeconds), ' ..
          '$(if($_.PSIsContainer){0}else{$_.Length}), $_.FullName }" 2>nul'
  else  -- macOS / BSD: find has no -printf; stat prints octal mode (40xxx = dir)
    cmd = "find " .. M.shq(root) .. " -mindepth 1 -maxdepth " .. math.floor(depth) ..
          " -exec stat -f '%p%t%m%t%z%t%N' {} + 2>/dev/null"
  end
  local prune, out = {}, {}
  for _, n in ipairs(opts.prune or {}) do prune[n] = true end
  for line in M.run(cmd):gmatch("[^\r\n]+") do
    local ty, mt, sz, p = line:match("^(%S+)\t([%d%.]+)\t(%d+)\t(.+)$")
    if p then
      local is_dir = (ty == "d") or ty:match("^40") ~= nil
      local is_file = (ty == "f") or ty:match("^10") ~= nil
      local pruned = false
      for seg in p:gmatch("[^/\\]+") do if prune[seg] then pruned = true; break end end
      local base = p:match("([^/\\]+)$") or p
      if not pruned
         and (opts.kind == nil or (opts.kind == "dir" and is_dir) or (opts.kind == "file" and is_file))
         and (opts.suffix == nil or base:sub(-#opts.suffix) == opts.suffix) then
        out[#out + 1] = { path = p, dir = is_dir, mtime = tonumber(mt) or 0, size = tonumber(sz) or 0 }
        if #out >= limit then break end
      end
    end
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
-- title/msg carry process names and (LLM-written) hypotheses, so they are data:
-- quoted for the shell, and escaped for AppleScript on macOS.
function M.notify(title, msg)
  title = tostring(title or "EvoLua"):gsub("%c", " ")
  msg = tostring(msg or ""):gsub("%c", " ")
  if M.os == "macos" then
    local function as(s) return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end
    local script = "display notification " .. as(msg) .. " with title " .. as(title)
    M.run("osascript -e " .. M.shq(script) .. " 2>/dev/null")
  elseif M.os == "linux" then
    M.run("notify-send " .. M.shq(title) .. " " .. M.shq(msg) .. " 2>/dev/null")
  elseif M.os == "windows" then
    -- msg.exe (present on most Windows); harmless no-op if unavailable. cmd can't
    -- escape reliably, so drop the characters it would interpret.
    M.run("msg * /TIME:10 " .. M.shq((title .. ": " .. msg):gsub('[%%^&|<>"]', "")) .. " 2>nul")
  end
end

return M
