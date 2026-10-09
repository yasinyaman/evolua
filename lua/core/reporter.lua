-- core/reporter.lua — actuator: turns perception into written reports
-- Exposes ctx.report(category, text) for organ-driven observations, and writes
-- timestamped Markdown into reports/. As of Faz 1 it also renders a rule-based
-- SITUATIONAL summary straight from the world model ("what's going on, by app"),
-- so reports are meaningful even when no organ logged an observation.

local Reporter = {}
Reporter.__index = Reporter

function Reporter.new(ctx)
  return setmetatable({ ctx = ctx, buf = {}, n = 0 }, Reporter)
end

function Reporter:report(category, text)
  self.n = self.n + 1
  table.insert(self.buf, {
    at = os.date("%H:%M:%S"), category = category or "note", text = text or "",
  })
  self.ctx.memory:bump("reports")
  if #self.buf >= (self.ctx.cfg.report_flush or 12) then self:write_report("buffer-full") end
end

-- rule-based situational summary from the world model (Faz 1 cognition)
function Reporter:_situational(fh)
  local wm = self.ctx.worldmodel
  if not wm then return end
  local snap = wm:snapshot(8)
  if #snap == 0 then return end
  fh:write("## Situation — what's happening on the system (rule-based)\n\n")
  fh:write("| entity | cpu | mem (MB) | errors | hot (ticks) | trend | salience |\n")
  fh:write("|---|---:|---:|---:|---:|:--:|---:|\n")
  for _, e in ipairs(snap) do
    fh:write(string.format("| %s | %.0f | %.0f | %d | %d | %s | %.0f |\n",
      e.name, e.cpu_avg or 0, e.mem_mb or 0, e.errors or 0,
      e.hot_ticks or 0, e.trend or "→", wm:salience(e)))
  end
  -- a one-line natural narrative for the most salient entity
  local top = snap[1]
  if top then
    local why = {}
    if (top.cpu_avg or 0) >= (self.ctx.cfg.proc_cpu_threshold or 50) then why[#why+1] = string.format("CPU ~%.0f%%", top.cpu_avg) end
    if (top.errors or 0) > 0 then why[#why+1] = string.format("%d errors", top.errors) end
    if (top.hot_ticks or 0) > 5 then why[#why+1] = string.format("hot for %d ticks", top.hot_ticks) end
    if top.last_error then why[#why+1] = "last error: " .. top.last_error:sub(1, 80) end
    if #why > 0 then
      fh:write(string.format("\n> **%s** stands out — %s. (trend %s)\n\n",
        top.name, table.concat(why, ", "), top.trend or "→"))
    else
      fh:write("\n")
    end
  end
end

-- write a full report. Always renders the situational view; includes buffered
-- observations if any. Skipped only when there is genuinely nothing to say.
function Reporter:write_report(reason)
  local wm = self.ctx.worldmodel
  local have_world = wm and #wm:snapshot(1) > 0
  if #self.buf == 0 and not have_world then return end

  local dir = self.ctx.cfg.reports_dir
  local stamp = os.date("%Y%m%d-%H%M%S")
  local base = string.format("%s/report-%s-t%d", dir, stamp, self.ctx.kernel.tick)
  -- two reports can land in the same second AND tick (e.g. buffer-full then the
  -- shutdown flush) — never overwrite: suffix -2, -3, … until the name is free
  local path, n = base .. ".md", 1
  while true do
    local probe = io.open(path, "r")
    if not probe then break end
    probe:close()
    n = n + 1
    path = string.format("%s-%d.md", base, n)
  end
  local fh = io.open(path, "w")
  if not fh then return end

  fh:write("# EvoLua report — ", os.date("%Y-%m-%d %H:%M:%S"), "\n\n")
  fh:write(string.format("- mode: **%s**%s · trigger: %s\n", self.ctx.cfg.mode,
    self.ctx.cfg.goal and self.ctx.cfg.goal ~= "" and (" · goal: _" .. self.ctx.cfg.goal .. "_") or "",
    reason or "?"))
  fh:write(string.format("- tick: %d · generation: %d · organs: %d\n\n",
    self.ctx.kernel.tick, self.ctx.memory.data.generation, #self.ctx.registry:list()))

  self:_situational(fh)

  -- organ-driven observations grouped by category
  if #self.buf > 0 then
    local groups = {}
    for _, e in ipairs(self.buf) do
      groups[e.category] = groups[e.category] or {}
      table.insert(groups[e.category], string.format("  - `%s` %s", e.at, e.text))
    end
    local cats = {}
    for c in pairs(groups) do cats[#cats + 1] = c end
    table.sort(cats)
    fh:write("## Observations\n\n")
    for _, c in ipairs(cats) do
      fh:write("### ", c, "\n", table.concat(groups[c], "\n"), "\n\n")
    end
  end

  -- fitness leaderboard
  fh:write("## Fitness leaderboard\n\n")
  local rank = {}
  for name, score in pairs(self.ctx.memory.data.fitness) do rank[#rank + 1] = { name, score } end
  table.sort(rank, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(10, #rank) do
    fh:write(string.format("%d. **%s** — %.1f\n", i, rank[i][1], rank[i][2]))
  end

  -- lineage of generated organs
  fh:write("\n## Evolution log\n\n")
  local births = self.ctx.memory.data.births
  for i = math.max(1, #births - 10), #births do
    local b = births[i]
    if b then
      fh:write(string.format("- gen %d: `%s` from <%s>%s\n", b.generation, b.organ,
        b.template, b.lineage and (" (mutation of " .. b.lineage .. ")") or ""))
    end
  end

  fh:close()
  self.ctx.log:info("\27[32m▣ report written: %s (%d obs)\27[0m", path, #self.buf)
  self.buf = {}
end

-- shutdown flush: write out buffered observations only. With an empty buffer
-- there is nothing new to say (the periodic report already covers the world view).
function Reporter:flush(_final)
  if #self.buf == 0 then return end
  self:write_report("flush")
end

return Reporter
