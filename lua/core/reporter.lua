-- core/reporter.lua — actuator: turns perception into written reports
-- Exposes ctx.report(category, text) for organ-driven observations, and writes
-- timestamped Markdown into reports/. As of Faz 1 it also renders a rule-based
-- SITUATIONAL summary straight from the world model ("what's going on, by app"),
-- so reports are meaningful even when no organ logged an observation.

local P     = require("core.platform")
local Brain = require("core.brain")

local Reporter = {}
Reporter.__index = Reporter

function Reporter.new(ctx)
  return setmetatable({ ctx = ctx, buf = {}, n = 0 }, Reporter)
end

-- INFORMATION VALUE of a report: honest fitness pays an organ for handling a stimulus,
-- but it cannot tell a real finding from "the same line again with other numbers".
-- Compare each report with the organ's previous one (digits normalised, token Jaccard):
-- a near-identical shape is noise and costs fitness, so "report something every
-- cycle" loses to "report when something actually changed" under selection.
local function shape_tokens(text)
  local set, n = {}, 0
  for tok in tostring(text):gsub("%d+", "#"):gmatch("[%w#%.:/_%-]+") do
    if not set[tok] then set[tok] = true; n = n + 1 end
  end
  return set, n
end

local function similarity(a, b)
  local sa, na = shape_tokens(a)
  local sb, nb = shape_tokens(b)
  if na == 0 or nb == 0 then return 0 end
  local inter = 0
  for tok in pairs(sa) do if sb[tok] then inter = inter + 1 end end
  return inter / (na + nb - inter)
end

function Reporter:report(category, text)
  self.n = self.n + 1
  table.insert(self.buf, {
    at = os.date("%H:%M:%S"), category = category or "note", text = text or "",
  })
  self.ctx.memory:bump("reports")
  local cfg, reg = self.ctx.cfg, self.ctx.registry
  if category and reg and reg.loaded and reg.loaded[category] then     -- only organs are judged
    self.last = self.last or {}
    local tick = (self.ctx.kernel and self.ctx.kernel.tick) or 0
    local prev = self.last[category]
    -- noise = the same SHAPE again within a few ticks ("new process # at #" every sample).
    -- The same shape after a quiet spell ("load 3.1 -> 4.9", later "load 4.9 -> 6.3") is a
    -- real change and is left alone — only the rapid-fire stream is penalised.
    if prev and (tick - prev.tick) < (cfg.report_stale_ticks or 15) then
      local sim = similarity(prev.text, text)
      if sim >= (cfg.report_stale_sim or 0.7) then
        self.ctx.memory:reward(category, -(cfg.report_stale_penalty or 0.5) * sim)
        self.ctx.memory:bump("stale_reports")
        local mem = self.ctx.memory.data
        mem.stale = mem.stale or {}
        mem.stale[category] = (mem.stale[category] or 0) + 1          -- per-organ noise ledger
      end
    elseif prev then
      -- a finding after a quiet spell is what "report anomalies" means: the bus can't see
      -- it (reports aren't stimuli), so the reporter pays the information value itself
      self.ctx.memory:reward(category, cfg.report_reward or 4.0)
      self.ctx.memory:bump("valued_reports")
      local mem = self.ctx.memory.data
      mem.valued = mem.valued or {}
      mem.valued[category] = (mem.valued[category] or 0) + 1       -- per-organ findings ledger
    end
    self.last[category] = { text = text, tick = tick }
  end
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
  local b = Brain.info()
  fh:write(string.format("- tick: %d · generation: %d · organs: %d · brain: %s%s\n\n",
    self.ctx.kernel.tick, self.ctx.memory.data.generation, #self.ctx.registry:list(),
    b.kind == "none" and "rules" or (b.name .. " (" .. b.kind .. ")"),
    b.params_b and string.format(", %.2gB", b.params_b) or ""))

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
  self:rotate(dir)
end

-- keep only the newest report_keep reports (names sort chronologically)
function Reporter:rotate(dir)
  local keep = self.ctx.cfg.report_keep or 100
  if keep <= 0 then return end
  local reports = {}
  for _, name in ipairs(P.list_dir(dir)) do
    if name:match("^report%-.+%.md$") then reports[#reports + 1] = name end
  end
  if #reports <= keep then return end
  table.sort(reports)
  for i = 1, #reports - keep do os.remove(dir .. "/" .. reports[i]) end
end

-- shutdown flush: write out buffered observations only. With an empty buffer
-- there is nothing new to say (the periodic report already covers the world view).
function Reporter:flush(_final)
  if #self.buf == 0 then return end
  self:write_report("flush")
end

return Reporter
