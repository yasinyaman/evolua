-- sensors/fswatch.lua — perceive filesystem changes in watched dirs
-- Snapshots (name -> mtime/size) and diffs each pass. Emits:
--   fs.change { kind=created|modified|deleted, path }
-- Pure Lua + `ls`/`stat` via io.popen; no luafilesystem dependency.

local function snapshot(dir)
  local snap = {}
  local p = io.popen and io.popen('find "' .. dir .. '" -maxdepth 2 -type f -printf "%p\\t%T@\\t%s\\n" 2>/dev/null')
  if not p then return snap end
  for line in p:lines() do
    local path, mtime, size = line:match("^(.-)\t([%d%.]+)\t(%d+)$")
    if path then snap[path] = (mtime or "") .. ":" .. (size or "") end
  end
  p:close()
  -- BSD/macOS find lacks -printf; fall back to a plain listing if empty
  if next(snap) == nil then
    local q = io.popen and io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if q then
      for f in q:lines() do snap[dir .. "/" .. f] = "?" end
      q:close()
    end
  end
  return snap
end

return {
  name = "fswatch",
  desc = "watches directories and emits fs.change stimuli",
  events = { "fs.change" },

  _snap = nil,

  sense = function(self, ctx)
    local dirs = ctx.cfg.watch_dirs or {}
    local cur = {}
    for _, d in ipairs(dirs) do
      for k, v in pairs(snapshot(d)) do cur[k] = v end
    end
    if self._snap then
      for path, sig in pairs(cur) do
        if not self._snap[path] then
          ctx.bus:emit("fs.change", { kind = "created", path = path })
        elseif self._snap[path] ~= sig then
          ctx.bus:emit("fs.change", { kind = "modified", path = path })
        end
      end
      for path in pairs(self._snap) do
        if not cur[path] then
          ctx.bus:emit("fs.change", { kind = "deleted", path = path })
        end
      end
    end
    self._snap = cur
  end,
}
