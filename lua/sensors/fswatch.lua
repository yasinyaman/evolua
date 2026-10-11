-- sensors/fswatch.lua — perceive filesystem changes in watched dirs
-- Snapshots (path -> mtime:size) and diffs each pass. Emits:
--   fs.change { kind=created|modified|deleted, path }
-- Listing goes through core/platform (host binding in the binary, quoted
-- `find` in plain Lua), so a watched path is never spliced into a command.

local P = require("core.platform")

local function snapshot(dir)
  local snap = {}
  for _, e in ipairs(P.walk(dir, { depth = 2, kind = "file", limit = 5000 })) do
    snap[e.path] = tostring(e.mtime) .. ":" .. tostring(e.size)
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
