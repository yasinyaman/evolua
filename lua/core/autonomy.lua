-- core/autonomy.lua — the autonomy ladder (Faz 3)
-- Turns a reasoner DECISION into a measured ACTION, gated by confidence, a
-- config ceiling, a safe-action allowlist, and reversibility. Everything is
-- audited; anything destructive or low-confidence is routed to a file-based
-- approval inbox instead of being executed. See docs/ROADMAP.md §"Otonomi".

local P = require("core.platform")

local Autonomy = {}
Autonomy.__index = Autonomy

local LEVELS = { learn = 0, report = 1, notify = 2, suggest = 3, act = 4 }
local NAMES  = { [0] = "learn", [1] = "report", [2] = "notify", [3] = "suggest", [4] = "act" }

function Autonomy.new(ctx)
  local self = setmetatable({ ctx = ctx }, Autonomy)
  self.ceiling = LEVELS[ctx.cfg.autonomy_ceiling or "report"] or LEVELS.report
  self.safe = {}
  for _, v in ipairs(ctx.cfg.safe_actions or { "throttle", "notify" }) do self.safe[v] = true end
  self.audit_path = ctx.cfg.state_dir .. "/audit.log"
  self.last_proposed = {}  -- (entity|verb) -> tick, to suppress duplicate suggestions
  self.inbox = ctx.cfg.state_dir:gsub("/state$", "") .. "/approvals"
  -- approvals/ lives next to state/ under the data home; ensure subdirs exist
  self.inbox = (ctx.cfg.approvals_dir) or (ctx.cfg.reports_dir:gsub("/reports$", "") .. "/approvals")
  os.execute('mkdir -p "' .. self.inbox .. '/approved" "' .. self.inbox .. '/done" 2>/dev/null')
  self.traces = {}   -- outcome-credit eligibility traces (#6): {organ, entity, baseline, born}
  -- evolved rule organs emit action.request; route them through the ladder (above)
  ctx.bus:subscribe("action.request", function(ev) self:request(ev.data); return { handled = true } end, "autonomy")
  return self
end

function Autonomy:audit(line)
  local fh = io.open(self.audit_path, "a")
  if fh then fh:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n"); fh:close() end
end

-- decide the effective level for a decision and carry it out.
-- decision = { entity, hypothesis, confidence, action, proposed = {verb,target_pid,reversible,desc,undo} }
function Autonomy:consider(decision, extra_ceiling)
  local cfg = self.ctx.cfg
  local req  = LEVELS[decision.action or "report"] or LEVELS.report
  local conf = decision.confidence or 0
  local act  = decision.proposed

  -- confidence gates (rules dominate — the blended conf already capped by rules)
  local gated = req
  if gated >= LEVELS.act and conf < (cfg.act_min_conf or 0.85) then gated = LEVELS.suggest end
  if gated >= LEVELS.suggest and conf < (cfg.suggest_min_conf or 0.6) then gated = LEVELS.notify end

  -- safety gate: autonomous action must be safe-listed AND reversible, else suggest
  if gated >= LEVELS.act then
    if not (act and act.verb and self.safe[act.verb] and act.reversible) then
      gated = LEVELS.suggest
    end
  end

  local eff = math.min(gated, self.ceiling, extra_ceiling or 99)
  self:_execute(eff, decision)
  return eff, NAMES[eff]
end

-- an EVOLVED organ (rule-DSL "act") REQUESTS an action. It never executes — the
-- request is routed through the SAME ladder as the reasoner, but capped MORE
-- conservatively: mutation-generated actuators are less trusted, so by default
-- (evolved_action_ceiling="suggest") their actions go to the approval inbox, never
-- autonomous. The safe-list is the second gate (the grammar already excludes kill).
function Autonomy:request(req)
  local cfg = self.ctx.cfg
  if cfg.evolved_actions == false then return end
  if not (req and req.verb and self.safe[req.verb]) then return end   -- never unsafe/kill
  if not req.pid and req.verb ~= "notify" then return end             -- need a target to act on
  local decision = {
    entity = req.entity or "?",
    hypothesis = req.reason or ("evolved organ requests " .. req.verb),
    confidence = req.confidence or 0.7,
    action = "act",                                  -- requested level; gating lowers it
    proposed = { verb = req.verb, target_pid = req.pid, reversible = true,
                 entity = req.entity, requester = req.from, desc = req.reason },
  }
  local cap = LEVELS[cfg.evolved_action_ceiling or "suggest"] or LEVELS.suggest
  self:consider(decision, cap)
end

function Autonomy:_execute(level, d)
  local ctx = self.ctx
  self:audit(string.format("L%d/%s entity=%s conf=%.2f verb=%s :: %s",
    level, NAMES[level], d.entity or "?", d.confidence or 0,
    (d.proposed and d.proposed.verb) or "-", d.hypothesis or ""))

  if level >= LEVELS.report then
    ctx.report("reason", string.format("[L%d %s|conf %.2f] %s — %s",
      level, NAMES[level], d.confidence or 0, d.entity or "?", d.hypothesis or ""))
  end
  if level >= LEVELS.notify then
    P.notify("EvoLua", string.format("%s: %s", d.entity or "?", d.hypothesis or ""))
  end
  if level == LEVELS.suggest then
    self:_propose(d)
  elseif level >= LEVELS.act then
    self:_enact(d.proposed, "autonomous")
  end
end

-- write a pending action to the file-based approval inbox
function Autonomy:_propose(d)
  local act = d.proposed or {}
  -- de-dupe: don't refile the same suggestion while one is still fresh
  local key = (d.entity or "?") .. "|" .. (act.verb or "?")
  local cool = self.ctx.cfg.propose_cooldown or 40
  local prev = self.last_proposed[key]
  if prev and (self.ctx.kernel.tick - prev) < cool then
    self:audit("suppressed duplicate suggestion " .. key)
    return
  end
  self.last_proposed[key] = self.ctx.kernel.tick
  local id = string.format("%d-%s", self.ctx.kernel.tick, (d.entity or "x"):gsub("%W", ""))
  local path = string.format("%s/pending-%s.md", self.inbox, id)
  local fh = io.open(path, "w")
  if not fh then return end
  fh:write("# EvoLua — onay bekleyen aksiyon\n\n")
  fh:write(string.format("ACTION: %s\n", act.verb or "none"))
  fh:write(string.format("TARGET_PID: %s\n", tostring(act.target_pid or "")))
  fh:write(string.format("ENTITY: %s\n", d.entity or "?"))
  fh:write(string.format("CONFIDENCE: %.2f\n", d.confidence or 0))
  fh:write(string.format("REVERSIBLE: %s\n", act.reversible and "yes" or "no"))
  fh:write(string.format("WHY: %s\n", d.hypothesis or ""))
  fh:write(string.format("UNDO: %s\n", act.undo or "-"))
  if act.requester then fh:write(string.format("REQUESTER: %s\n", act.requester)) end
  -- model_upgrade carries acquisition context the approval must preserve so the
  -- download can be enacted on approval (poll_approvals reads these back).
  if act.verb == "model_upgrade" then
    fh:write(string.format("TIER: %s\n", tostring(act.tier or "")))
    fh:write(string.format("TIER_NAME: %s\n", act.tier_name or ""))
    fh:write(string.format("FILE: %s\n", act.file or ""))
    fh:write(string.format("APPROX_MB: %d\n", act.approx_mb or 0))
    fh:write(string.format("URL: %s\n", act.url or ""))
    fh:write(string.format("SHA: %s\n", act.sha or ""))
  end
  fh:write("\n> To APPROVE, move this file into `approved/`. To REJECT, delete it.\n")
  fh:close()
  self:audit("PROPOSED " .. id .. " verb=" .. tostring(act.verb))
end

-- carry out a concrete action (only ever called for safe/approved actions)
function Autonomy:_enact(act, how)
  if not act or not act.verb then return end
  if act.verb == "throttle" then
    P.set_priority(act.target_pid, "low")
  elseif act.verb == "restore" then
    P.set_priority(act.target_pid, "normal")
  elseif act.verb == "kill" then
    P.kill(act.target_pid)
  elseif act.verb == "notify" then
    P.notify("EvoLua", act.desc or "")
  elseif act.verb == "model_downgrade" then
    -- switching to a model we already have is safe & immediate
    if self.ctx.modelmgr then self.ctx.modelmgr:set_index(act.tier) end
  elseif act.verb == "model_upgrade" then
    -- real acquisition via the Rust model_acquire binding; bounded to the
    -- ladder's pinned url+sha. Absent binding/url → no-op + note.
    local acquire = rawget(_G, "model_acquire")
    if acquire and act.url and act.file then
      local dest = (self.ctx.modelmgr and self.ctx.modelmgr.models_dir or ".") .. "/" .. act.file
      self:audit(string.format("model_upgrade: fetching %s (%dMB) → %s",
        act.tier_name or "?", act.approx_mb or 0, dest))
      local pok, got = pcall(acquire, act.url, dest, act.sha)
      if pok and got then
        if self.ctx.modelmgr then self.ctx.modelmgr:set_index(act.tier) end
        -- new brain in place (loads next life); clear the bottleneck samples so
        -- we re-judge it fresh instead of re-downloading on the next check.
        local c = self.ctx.memory.data.counters
        if c then c.llm_ok = 0; c.llm_fallback = 0 end
        self:audit(string.format("model_upgrade: ACQUIRED %s — active next life", act.tier_name or "?"))
      else
        self:audit(string.format("model_upgrade: acquisition FAILED for %s (%s)",
          act.tier_name or "?", tostring(got)))
      end
    else
      self:audit("model_upgrade skipped: no acquire binding/url (build with --features acquire)")
    end
  end
  self:audit(string.format("ENACTED(%s) %s target=%s", how or "?", act.verb,
    tostring(act.target_pid or act.tier_name or "-")))
  -- OUTCOME CREDIT (#6): if an evolved organ requested this action on a world-model
  -- entity, register an eligibility trace; settle_outcomes() rewards the requester
  -- later IF the target's measured load actually dropped — fakeproof, since the
  -- organ cannot fabricate another process's cpu reading.
  if act.requester and act.entity and self.ctx.worldmodel then
    local e = self.ctx.worldmodel.entities[act.entity]
    self.traces[#self.traces + 1] = {
      organ = act.requester, entity = act.entity,
      baseline = (e and e.cpu_avg) or 0, born = self.ctx.kernel.tick,
    }
  end
end

-- poll the approval inbox: enact anything the user moved into approved/, then
-- archive it to done/. Called each tick by the kernel (cheap dir listing).
function Autonomy:poll_approvals()
  local app = self.inbox .. "/approved"
  for _, name in ipairs(P.list_dir(app)) do
    if name:match("%.md$") then
      local path = app .. "/" .. name
      local fh = io.open(path, "r")
      if fh then
        local txt = fh:read("*a"); fh:close()
        local verb = txt:match("ACTION:%s*([%w_]+)")
        local pid = tonumber(txt:match("TARGET_PID:%s*(%d+)"))
        if verb then
          local act = { verb = verb, target_pid = pid }
          act.requester = (txt:match("REQUESTER:%s*([^\n\r]+)") or ""):gsub("%s+$", "")
          act.entity    = (txt:match("ENTITY:%s*([^\n\r]+)") or ""):gsub("%s+$", "")
          if act.requester == "" then act.requester = nil end
          if act.entity == "" then act.entity = nil end
          if verb == "model_upgrade" then
            local function field(k) local v = txt:match(k .. ":%s*([^\n\r]+)"); return v and v:gsub("%s+$", "") end
            act.tier = tonumber(field("TIER"))
            act.tier_name, act.file = field("TIER_NAME"), field("FILE")
            act.approx_mb = tonumber(field("APPROX_MB")) or 0
            act.url, act.sha = field("URL"), field("SHA")
          end
          self:_enact(act, "approved")
        end
        os.rename(path, self.inbox .. "/done/" .. name)
      end
    end
  end
end

-- settle outcome-credit traces: once a trace is older than the outcome window,
-- compare the target entity's current load to the baseline at action time. If it
-- dropped, reward the requesting organ (temporal credit for a world improvement,
-- not for firing). Called each tick by the kernel. Correlation, not proof — but
-- the organ took a real reversible action and cannot fake the worldmodel reading.
function Autonomy:settle_outcomes()
  if not self.traces or #self.traces == 0 then return end
  local cfg, wm = self.ctx.cfg, self.ctx.worldmodel
  local now = self.ctx.kernel.tick
  local ttl = cfg.outcome_window or 15
  local keep = {}
  for _, tr in ipairs(self.traces) do
    if (now - tr.born) >= ttl then
      local e = wm and wm.entities[tr.entity]
      local cur = (e and e.cpu_avg) or 0
      local drop = tr.baseline - cur                 -- positive = the target cooled down
      if drop > (cfg.outcome_min_drop or 5) then
        local reward = math.min(drop / 10, cfg.outcome_max_reward or 5)
        self.ctx.bus:emit_raw("self.reward", { owner = tr.organ, amount = reward })
        self:audit(string.format("OUTCOME +%.2f → %s (entity=%s cpu %.0f→%.0f)",
          reward, tr.organ, tr.entity, tr.baseline, cur))
      end
      -- expired: dropped whether or not it paid off
    else
      keep[#keep + 1] = tr
    end
  end
  self.traces = keep
end

return Autonomy
