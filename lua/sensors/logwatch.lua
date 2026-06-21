-- sensors/logwatch.lua — tail watched log files, surface errors
-- Emits log.error { file, line, pattern } when a new line matches a known
-- error signature. The set of signatures is adaptive: repeated novel tokens
-- near errors are promoted into new watch patterns over time.

return {
  name = "logwatch",
  desc = "tails log files and emits log.error stimuli on matches",
  events = { "log.error", "log.warn" },

  _pos = {},   -- file -> byte offset already consumed
  _patterns = { "error", "exception", "fatal", "panic", "traceback", "fail" },
  _seen_tokens = {},

  sense = function(self, ctx)
    local files = ctx.cfg.watch_logs or {}
    for _, path in ipairs(files) do
      local fh = io.open(path, "r")
      if fh then
        local start = self._pos[path] or 0
        fh:seek("set", start)
        local chunk = fh:read("*a") or ""
        self._pos[path] = fh:seek()
        fh:close()
        for line in chunk:gmatch("[^\n]+") do
          local low = line:lower()
          local hitp
          for _, p in ipairs(self._patterns) do
            if low:find(p, 1, true) then hitp = p; break end
          end
          if hitp then
            ctx.bus:emit("log.error", { file = path, line = line:sub(1, 240), pattern = hitp })
            -- adaptive: learn co-occurring tokens as future signatures
            for tok in low:gmatch("[%a_][%a%d_]+") do
              if #tok > 4 then
                self._seen_tokens[tok] = (self._seen_tokens[tok] or 0) + 1
                if self._seen_tokens[tok] == 5 then
                  local known = false
                  for _, p in ipairs(self._patterns) do if p == tok then known = true end end
                  if not known then
                    table.insert(self._patterns, tok)
                    ctx.log:debug("logwatch learned new signature: %s", tok)
                  end
                end
              end
            end
          end
        end
      end
    end
  end,
}
