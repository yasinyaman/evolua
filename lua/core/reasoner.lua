-- core/reasoner.lua — sense-making (Faz 2)
-- Builds a whole-system snapshot from the world model, retrieves relevant
-- experience (RAG), asks the embedded decision brain (llm_complete) for a
-- STRICT decision schema, and blends its confidence with deterministic rules.
-- If no model is present or the output won't parse, it falls back to rules —
-- the binary always reasons, just less richly.

local RAG       = require("core.rag")
local Templates = require("core.templates")

local Reasoner = {}
Reasoner.__index = Reasoner

-- map a hot/error situation to the template that addresses it
local REASON_TEMPLATE = { cpu = "cpu_guard", mem = "mem_guard", error = "error_reporter" }

local SCHEMA = [[
Decide from the snapshot. Reply with EXACTLY 6 lines, ONE chosen value each.
Pick a single option per line. Do NOT copy the option lists, and never use '|', '<' or '>'.

SALIENCE: low or med or high
ENTITY: the single most important process name from the snapshot
HYPOTHESIS: one short sentence on what is going on
ROUTE: rule  (or)  escalate  (or)  template:NAME with NAME one of cpu_guard mem_guard load_guard error_reporter fs_journal
ACTION: learn or report or notify or suggest or act
CONFIDENCE: one number between 0.0 and 1.0

Example of a correct reply (copy this FORMAT, not these values):
SALIENCE: high
ENTITY: WindowServer
HYPOTHESIS: WindowServer shows sustained high CPU.
ROUTE: template:cpu_guard
ACTION: report
CONFIDENCE: 0.8]]

function Reasoner.new(ctx)
  local self = setmetatable({ ctx = ctx, rag = RAG.new(), last_tick = -1 }, Reasoner)
  self:seed()
  return self
end

-- seed the experience bank with the template patterns (always-available priors)
function Reasoner:seed()
  for key, tpl in pairs(Templates) do
    local kws = table.concat(tpl.goal_keywords or {}, " ")
    self.rag:add("tpl:" .. key, string.format("%s %s %s", key, tpl.triggers or "", kws), 1,
      { kind = "template", key = key })
  end
end

-- fold the organism's own high-fitness organs into the bank (learn from self)
function Reasoner:harvest()
  for _, b in ipairs(self.ctx.memory.data.births or {}) do
    local fit = self.ctx.memory:fitness(b.organ)
    if fit and fit > 1 then
      self.rag:add("organ:" .. b.organ,
        string.format("%s %s", b.template, b.organ), fit,
        { kind = "organ", key = b.template, organ = b.organ })
    end
  end
end

-- compact whole-system snapshot (token-budgeted: most salient entities first)
function Reasoner:snapshot_text(limit)
  local wm = self.ctx.worldmodel
  local snap = wm:snapshot(limit or 6)
  local lines = { string.format("tick=%d organs=%d", self.ctx.kernel.tick, #self.ctx.registry:list()) }
  for _, e in ipairs(snap) do
    lines[#lines + 1] = string.format(
      "%s: cpu=%.0f mem=%.0fMB errors=%d hot=%d trend=%s%s",
      e.name, e.cpu_avg or 0, e.mem_mb or 0, e.errors or 0, e.hot_ticks or 0, e.trend or "-",
      e.last_error and (" lastErr='" .. e.last_error:sub(1, 60) .. "'") or "")
  end
  return table.concat(lines, "\n"), snap
end

-- deterministic decision purely from the world model (fallback + rule signals)
function Reasoner:rule_decision(top)
  local wm = self.ctx.worldmodel
  local sal = top and wm:salience(top) or 0
  local bucket = sal >= 80 and "high" or (sal >= 35 and "med" or "low")
  local reason = top and (top.errors > 0 and "error" or top.last_reason) or nil
  local route = reason and REASON_TEMPLATE[reason] and ("template:" .. REASON_TEMPLATE[reason]) or "rule"
  -- rule confidence: scaled salience, capped
  local conf = math.min(0.9, sal / 100)
  local hyp
  if top then
    local bits = {}
    if (top.cpu_avg or 0) >= (self.ctx.cfg.proc_cpu_threshold or 50) then bits[#bits+1] = string.format("high CPU (~%.0f%%)", top.cpu_avg) end
    if (top.errors or 0) > 0 then bits[#bits+1] = string.format("%d error(s)", top.errors) end
    if (top.hot_ticks or 0) > 5 then bits[#bits+1] = string.format("sustained %d ticks", top.hot_ticks) end
    hyp = string.format("%s shows %s", top.name, #bits > 0 and table.concat(bits, ", ") or "elevated activity")
  else
    hyp = "system nominal"
  end
  return { salience = bucket, entity = top and top.name or "system", hypothesis = hyp,
           route = route, action = "report", confidence = conf, source = "rule" }
end

-- strict parse of the model's schema reply; returns nil on any deviation
local function parse_schema(text)
  if not text or text == "" then return nil end
  local function grab(key)
    return text:match(key .. "%s*:%s*([^\n\r]+)")
  end
  local sal = (grab("SALIENCE") or ""):lower():match("%a+")
  sal = ({ medium = "med", moderate = "med", mid = "med" })[sal] or sal
  local ent = grab("ENTITY")
  local hyp = grab("HYPOTHESIS")
  local route = (grab("ROUTE") or ""):lower():gsub("%s", "")
  local action = (grab("ACTION") or ""):lower():match("%a+")
  local conf = tonumber((grab("CONFIDENCE") or ""):match("[%d%.]+"))
  if not (sal and ent and route ~= "" and action and conf) then return nil end
  if not ({ low = 1, med = 1, high = 1 })[sal] then return nil end
  if not ({ learn = 1, report = 1, notify = 1, suggest = 1, act = 1 })[action] then return nil end
  -- validate route shape
  local ok_route = route == "rule" or route == "escalate" or route:match("^template:[%a_]+$")
  if not ok_route then return nil end
  return { salience = sal, entity = ent:gsub("%s+$", ""), hypothesis = hyp or "",
           route = route, action = action, confidence = math.max(0, math.min(1, conf)), source = "llm" }
end

-- blend rule + LLM confidence; rules set the ceiling so the LLM can't leap the
-- autonomy ladder on bravado (full enforcement lands in Faz 3).
local function blend_conf(rule_c, llm_c)
  local combined = 0.6 * rule_c + 0.4 * llm_c
  local ceiling = math.min(1, rule_c + 0.25)
  return math.max(0, math.min(combined, ceiling))
end

function Reasoner:step()
  local ctx = self.ctx
  if self.ctx.kernel.tick == self.last_tick then return end
  self.last_tick = self.ctx.kernel.tick

  local snap_text, snap = self:snapshot_text(6)
  local top = snap[1]
  local floor = ctx.cfg.reasoner_salience_floor or 30
  if not top or ctx.worldmodel:salience(top) < floor then return end -- nothing worth reasoning about

  -- rule baseline (also the fallback)
  local rule = self:rule_decision(top)

  -- RAG: retrieve relevant experience for the prompt
  self:harvest()
  local query = string.format("%s %s %s", top.name, top.last_reason or "",
    top.errors > 0 and "error crash" or "cpu memory")
  local hits = self.rag:search(query, ctx.cfg.rag_k or 3)
  local ctx_lines = {}
  for _, d in ipairs(hits) do ctx_lines[#ctx_lines + 1] = "- " .. d.text end
  local rag_ctx = #ctx_lines > 0 and ("Relevant past patterns:\n" .. table.concat(ctx_lines, "\n")) or ""

  -- ask the decision brain, if present
  local decision = rule
  local llm = rawget(_G, "llm_complete")
  if llm then
    local system = "You are EvoLua's decision module. Be terse and follow the schema exactly."
    local user = string.format("%s\n\nSystem snapshot:\n%s\n\n%s", SCHEMA, snap_text, rag_ctx)
    local ok, reply = pcall(llm, system, user, 160)
    if ok and reply then
      local parsed = parse_schema(reply)
      if parsed then
        parsed.confidence = blend_conf(rule.confidence, parsed.confidence)
        -- keep rule's route if the model picked something nonsensical for the entity
        decision = parsed
        decision.source = "llm+rule"
        ctx.memory:bump("llm_ok")            -- decision brain produced usable output
      else
        ctx.memory:bump("llm_fallback")      -- bottleneck signal for the model ladder
        ctx.log:debug("reasoner: schema parse failed, using rules")
      end
    else
      ctx.memory:bump("llm_fallback")
    end
  end

  -- attach a concrete proposed action for the autonomy layer (Faz 3).
  -- Resource pressure → throttle (reversible, safe). Errors → notify only.
  -- Anything heavier (kill) is never proposed here; the user can do it from a suggestion.
  local reason = top.errors > 0 and "error" or top.last_reason
  if (reason == "cpu" or reason == "mem") and top.pid then
    decision.proposed = {
      verb = "throttle", target_pid = top.pid, reversible = true,
      desc = string.format("lower %s priority", top.name),
      undo = "restore priority to normal",
    }
  elseif reason == "error" then
    decision.proposed = { verb = "notify", reversible = true, desc = decision.hypothesis }
  end

  -- ACT via the autonomy ladder (gated by confidence + ceiling + safety).
  -- In Faz 2 the ladder defaults to L1 (report); Faz 3 lets the user raise it.
  if ctx.autonomy then
    ctx.autonomy:consider(decision)
  else
    ctx.report("reason", string.format("[%s|conf %.2f] %s → %s (route %s)",
      decision.salience, decision.confidence, decision.entity, decision.hypothesis, decision.route))
  end

  -- store this situation→interpretation as future experience (weighted by salience);
  -- only the newest rag_max_situations are kept, so a long life can't grow the bank forever
  local sid = "sit:" .. self.ctx.kernel.tick
  self.rag:add(sid, string.format("%s %s %s", decision.entity, top.last_reason or "", decision.hypothesis),
    ctx.worldmodel:salience(top) / 20, { kind = "situation" })
  self.situations = self.situations or {}
  table.insert(self.situations, sid)
  while #self.situations > (ctx.cfg.rag_max_situations or 500) do
    self.rag:remove(table.remove(self.situations, 1))
  end

  -- inform evolution: grow the routed organ if it's warranted and not already serving
  local tkey = decision.route:match("^template:([%a_]+)$")
  if tkey and Templates[tkey] and not ctx.evolver:serves(Templates[tkey].triggers) then
    if decision.confidence >= (ctx.cfg.reasoner_grow_conf or 0.5) then
      ctx.log:info("reasoner: situation on '%s' → growing <%s> (conf %.2f)",
        decision.entity, tkey, decision.confidence)
      ctx.evolver:spawn(tkey)
    end
  end

  return decision
end

return Reasoner
