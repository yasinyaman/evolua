-- core/modelmgr.lua — meta-evolution: the model is a unit under selection (Faz 4)
-- The binary ships NO model. This manager gives the organism a brain in two ways,
-- always sized to the host (hostcaps):
--   1. FIND — a GGUF already on the host (Ollama / LM Studio / HF cache / own
--      models dir; core/modelfind.lua) that fits the usable RAM → attach it
--      immediately via the host's llm_load binding. Free, offline, reversible.
--   2. FETCH — when nothing usable is found, or the attached brain is a
--      BOTTLENECK (high rule-fallback in the reasoner) and the host can run a
--      bigger one, climb a PINNED ladder (url + sha256) with the Rust acquire
--      binding — proposed through the autonomy ladder like every other action
--      (unattended config acts directly). The organism chooses WHEN; the ladder
--      bounds WHAT. Then the new brain is hot-swapped (llm_load), not "next life".
-- Capacity drop → unload (free RAM) and re-find something smaller.

local HostCaps = require("core.hostcaps")
local Find     = require("core.modelfind")

local ModelMgr = {}
ModelMgr.__index = ModelMgr

-- Ordered capability ladder — every downloadable tier is a PINNED, checksummed
-- artifact (Qwen2.5-Coder-Instruct: the smallest family that reliably emits both
-- the reasoner's strict schema AND compilable Lua for the synthesizer organ).
-- ram_min_mb ≈ weights + KV cache + runtime; approx_mb = download size.
local HF = "https://huggingface.co/Qwen/"
local LADDER = {
  { name = "rules-only", ram_min_mb = 0, cores_min = 1, approx_mb = 0 },
  { name = "qwen2.5-coder-0.5b-q4", ram_min_mb = 900, cores_min = 1, approx_mb = 469,
    file = "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
    url = HF .. "Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf?download=true",
    sha = "1d9614638d18024d0fbb36575a15f1302a3adf044df10345688ec4f6e1c4ff32" },
  { name = "qwen2.5-coder-1.5b-q4", ram_min_mb = 1600, cores_min = 2, approx_mb = 1066,
    file = "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
    url = HF .. "Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true",
    sha = "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046" },
  { name = "qwen2.5-coder-3b-q4", ram_min_mb = 2800, cores_min = 4, approx_mb = 2008,
    file = "qwen2.5-coder-3b-instruct-q4_k_m.gguf",
    url = HF .. "Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf?download=true",
    sha = "724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7" },
  { name = "qwen2.5-coder-7b-q4", ram_min_mb = 5900, cores_min = 4, approx_mb = 4467,
    file = "qwen2.5-coder-7b-instruct-q4_k_m.gguf",
    url = HF .. "Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf?download=true",
    sha = "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c" },
}

function ModelMgr.new(ctx)
  local self = setmetatable({ ctx = ctx, scans = 0 }, ModelMgr)
  self.models_dir = (ctx.cfg.reports_dir:gsub("/reports$", "")) .. "/models"
  os.execute('mkdir -p "' .. self.models_dir .. '" 2>/dev/null')
  self.binding = rawget(_G, "llm_load") ~= nil        -- host compiled with `llm`
  -- an explicit --model wins over everything (operator intent)
  if ctx.cfg.model_path and ctx.cfg.model_path ~= "" and not self:active() then
    self:activate(ctx.cfg.model_path, nil, "explicit --model")
  end
  -- FIND at birth: a brain already on the host costs nothing — use it from tick 1
  -- (downloads wait for the tick loop + autonomy ladder).
  if self.binding and not self:active() and ctx.cfg.model_discover ~= false then
    self:attach_found(HostCaps.probe(self.models_dir))
  end
  -- mesh: say what we offer from the first beacon on, and borrow at once if a peer already offers
  if ctx.cfg.mesh or os.getenv("EVOLUA_MESH") then
    for _, step in ipairs({ "peer_brain", "mesh_caps" }) do
      local ok, err = pcall(self[step], self)
      if not ok then ctx.log:warn("modelmgr: mesh %s failed at birth: %s", step, tostring(err)) end
    end
  end
  return self
end

ModelMgr.ladder = LADDER

-- which GGUF is live in the host right now (nil = rules only)
function ModelMgr:active()
  local f = rawget(_G, "llm_model")
  return f and f() or nil
end

function ModelMgr:current_index()
  local fh = io.open(self.models_dir .. "/current_tier", "r")
  if fh then local n = tonumber(fh:read("*a")); fh:close(); if n and LADDER[n] then return n end end
  return 1 -- rules-only (or an attached non-ladder model)
end

function ModelMgr:set_index(i)
  local fh = io.open(self.models_dir .. "/current_tier", "w")
  if fh then fh:write(tostring(i)); fh:close() end
end

local function audit(self, line)
  if self.ctx.autonomy then self.ctx.autonomy:audit(line) end
end

-- make `path` the live brain (hot-swap) and remember it for the next life.
-- Returns true if the host actually loaded it now.
function ModelMgr:activate(path, tier, label)
  local fh = io.open(self.models_dir .. "/current_model", "w")
  if fh then fh:write(path); fh:close() end      -- the host's startup resolution reads this
  if tier then self:set_index(tier) end
  local load = rawget(_G, "llm_load")
  if not load then
    self.ctx.log:info("modelmgr: remembered %s (%s) — no llm binding in this host, active next binary life",
      path, label or "?")
    return false
  end
  local ok = load(path)
  if ok then
    local f = io.open(path, "rb")
    if f then local sz = f:seek("end"); f:close(); self.active_mb = sz and sz / 1048576 or nil end
    local c = self.ctx.memory.data.counters
    if c then c.llm_ok = 0; c.llm_fallback = 0 end   -- judge the new brain fresh
    self.ctx.log:info("\27[32m🧠 brain online: %s (%s)\27[0m", label or "?", path)
    audit(self, string.format("model_attach: %s → %s", label or "?", path))
    self.ctx.report("model", string.format("brain online: %s", label or path))
    if self.mesh_caps then pcall(function() self:mesh_caps() end) end   -- advertise the change
  else
    self.ctx.log:warn("modelmgr: llm_load failed for %s", path)
  end
  return ok
end

-- RAM the brain may claim (MB). Instantaneous "available" RAM is a poor gauge
-- for an mmap'd GGUF (its pages are file-backed and evictable; a busy 8GB Mac
-- reports ~300MB "available" yet runs a 1.5B model fine), so the budget is the
-- larger of headroom×available and a floor fraction of TOTAL RAM — sized to the
-- machine, not to the moment.
local function ram_budget(caps, headroom, floor_frac)
  local avail = (caps.ram_avail_mb or caps.ram_total_mb or 0) * (headroom or 0.7)
  local floor = (caps.ram_total_mb or 0) * (floor_frac or 0.25)
  return math.max(avail, floor)
end

function ModelMgr:usable_mb(caps)
  local cfg = self.ctx.cfg
  local u = ram_budget(caps, cfg.model_headroom, cfg.model_ram_floor_frac)
  local cap = cfg.model_max_mb
  if cap then u = math.min(u, cap * 1.25 + 256) end   -- inverse of modelfind's fit test
  return u
end

-- FIND: scan the host for a usable GGUF that fits; attach the best one.
function ModelMgr:attach_found(caps)
  local cfg = self.ctx.cfg
  local dirs = { self.models_dir }
  for _, d in ipairs(cfg.model_dirs or {}) do dirs[#dirs + 1] = d end
  local ph = io.popen and io.popen("pwd 2>/dev/null")
  local cwd = ph and ph:read("*l"); if ph then ph:close() end
  if cwd and cwd ~= "" then dirs[#dirs + 1] = cwd .. "/models" end
  local cands = Find.discover({ dirs = dirs })
  self.scans = self.scans + 1
  local best, score = Find.best(cands, self:usable_mb(caps))
  self.ctx.log:info("modelmgr: host scan found %d GGUF(s); usable RAM %dMB → %s",
    #cands, math.floor(self:usable_mb(caps)), best and string.format("%s (%.0fMB, %s)", best.name, best.size_mb or 0, best.source) or "none fit")
  if best then
    -- rank the found brain on the ladder by size, so decide() compares like with like
    local tier = 1
    for i, t in ipairs(LADDER) do
      if t.approx_mb > 0 and (best.size_mb or 0) >= t.approx_mb * 0.8 then tier = i end
    end
    return self:activate(best.path, tier, best.name .. " [found on host]")
  end
  return false
end

-- is the current brain a bottleneck? no brain at all = yes; otherwise a high
-- rule-fallback rate in the reasoner (the model failing to produce usable output).
function ModelMgr:bottleneck()
  if self.ctx.cfg.model_force_upgrade then return true end
  if self.binding and not self:active() then return true end
  local c = self.ctx.memory.data.counters or {}
  local ok, fb = c.llm_ok or 0, c.llm_fallback or 0
  local total = ok + fb
  if total < (self.ctx.cfg.model_min_samples or 20) then return false end
  return (fb / total) > (self.ctx.cfg.model_fallback_rate or 0.4)
end

-- PURE decision: given caps + bottleneck + current tier, what should change?
-- Returns { action = "upgrade"|"downgrade"|"hold", from, to, reason }.
-- "upgrade" jumps straight to the HIGHEST tier the host can run (sized to the
-- system), not one rung at a time.
function ModelMgr.decide(caps, bottleneck, cur, opts)
  opts = opts or {}
  local usable = ram_budget(caps, opts.headroom, opts.floor_frac)
  local max_mb = opts.max_mb or math.huge

  local feasible = 1
  for i, t in ipairs(LADDER) do
    if t.ram_min_mb <= usable and t.cores_min <= (caps.cores or 1) and t.approx_mb <= max_mb then feasible = i end
  end

  if feasible < cur then
    return { action = "downgrade", from = cur, to = feasible, reason = "capacity dropped (RAM/cores)" }
  end
  if bottleneck and feasible > cur and (opts.ignore_battery or not caps.on_battery) then
    -- pick the biggest feasible tier the disk can also hold
    local target = feasible
    while target > cur and (caps.disk_free_mb or math.huge) < LADDER[target].approx_mb * 1.1 do
      target = target - 1
    end
    if target <= cur then
      return { action = "hold", from = cur, to = cur, reason = "insufficient disk for upgrade" }
    end
    return { action = "upgrade", from = cur, to = target, reason = "bottleneck + spare capacity" }
  end
  return { action = "hold", from = cur, to = cur,
           reason = bottleneck and (caps.on_battery and "on battery" or "no spare capacity") or "model adequate" }
end

-- periodic check: FIND first, then FETCH via the autonomy ladder if warranted
-- is the active brain an online service? (then the local ladder is irrelevant)
function ModelMgr:remote()
  local a = self:active()
  return a and a:sub(1, 7) == "remote:" or false
end

-- FAILOVER between the online brain and the local one. The host marks the online
-- service "down" after consecutive failures (blocked network, quota, outage) and backs
-- off; here we notice that, let the local ladder run (find / download a GGUF) so the
-- organism keeps thinking, probe the service periodically, and when it answers again
-- go back online — freeing the local model's RAM if the operator wants online-only.
function ModelMgr:failover()
  local status = rawget(_G, "llm_remote_status")
  local st = status and status()
  if not st then return false end                      -- no online brain configured
  local cfg = self.ctx.cfg
  if st.down and not self.remote_down then
    self.remote_down = true
    self.ctx.log:warn("[33m⇄ online brain unreachable (%s) — failover to local brain%s[0m",
      st.last_error ~= "" and st.last_error or "no detail", self:active() and "" or " (none yet: discovering)")
    audit(self, "brain_failover: online → local (" .. tostring(st.last_error) .. ")")
    self.ctx.report("model", "online brain unreachable — running on the local brain / rules until it answers again")
    self.ctx.bus:emit("brain.failover", { to = "local", reason = st.last_error })
  elseif self.remote_down and not st.down then
    self.remote_down = false
    self.ctx.log:info("[32m⇄ online brain is back (%s) — using it again[0m", st.label)
    audit(self, "brain_failover: local → online")
    self.ctx.report("model", "online brain is back")
    self.ctx.bus:emit("brain.failover", { to = "online" })
    if cfg.llm_remote_only ~= false then                -- free the local model's RAM
      local unload = rawget(_G, "llm_unload")
      if unload and self.active_mb then unload(); self.active_mb = nil end
    end
  elseif self.remote_down then
    local probe = rawget(_G, "llm_remote_probe")       -- cheap forced ping on the check cadence
    if probe and probe() then
      self.ctx.log:debug("modelmgr: online probe succeeded")
    end
  end
  return not self.remote_down                          -- true = online brain is serving
end

-- KEYS: the organism cannot sign up for an API account (every free tier wants a human:
-- e-mail/OAuth, CAPTCHA, terms). What it CAN do: say precisely what it needs — one file in
-- the approval inbox listing the free providers, where a key comes from, and where to drop
-- it — and then pick the key up the moment it appears (keys/<provider>), no restart.
function ModelMgr:want_key()
  local cfg = self.ctx.cfg
  if cfg.llm_key_request == false or cfg.llm_api ~= "auto" or not cfg.llm_providers then return end
  if rawget(_G, "llm_remote_status") and rawget(_G, "llm_remote_status")() then return end   -- online already
  if not rawget(_G, "llm_remote_set") then return end
  local home = (cfg.reports_dir:gsub("/reports$", ""))
  -- 1) hot pickup: a key file for a keyed provider → attach now
  for _, p in ipairs(cfg.llm_providers) do
    if p.key then
      local fh = io.open(home .. "/keys/" .. p.id, "r")
      if fh then
        fh:close()
        local label = cfg.llm_attach and cfg.llm_attach(p)
        if label then
          self.ctx.log:info("\27[32m🧠 brain online: %s [key file keys/%s]\27[0m", label, p.id)
          audit(self, "model_attach: online " .. label)
          self.ctx.report("model", "online brain attached from keys/" .. p.id .. ": " .. label)
          return
        end
      end
    end
  end
  -- 2) ask once per life
  if self.key_requested then return end
  self.key_requested = true
  os.execute('mkdir -p "' .. home .. '/approvals" "' .. home .. '/keys" 2>/dev/null')
  local path = home .. "/approvals/api-key-wanted.md"
  local fh = io.open(path, "w"); if not fh then return end
  fh:write("# EvoLua wants an online brain — an API key is needed\n\n")
  fh:write("No LLM key was found in the environment and the local model is small or absent. ")
  fh:write("Free tiers exist, but every provider requires a human to sign up (e-mail/OAuth, terms of use), ")
  fh:write("so the organism cannot obtain one by itself.\n\n")
  fh:write("Drop the key as ONE LINE into the matching file — it is picked up within a minute, no restart:\n\n")
  fh:write("| provider | free tier | get a key at | drop it into |\n|---|---|---|---|\n")
  local where = {
    groq = "https://console.groq.com/keys", cerebras = "https://cloud.cerebras.ai", gemini = "https://aistudio.google.com/apikey",
    openrouter = "https://openrouter.ai/keys", mistral = "https://console.mistral.ai/api-keys", github = "https://github.com/settings/tokens",
    huggingface = "https://huggingface.co/settings/tokens", openai = "https://platform.openai.com/api-keys", anthropic = "https://console.anthropic.com/settings/keys",
  }
  for _, p in ipairs(cfg.llm_providers) do
    if p.key then
      fh:write(string.format("| %s | %s | %s | `keys/%s` (or env `%s`) |\n", p.id, p.free and "yes" or "no (paid)", where[p.id] or "-", p.id, p.key))
    end
  end
  fh:write("\nOr run a local Ollama server (`ollama serve`) — it is picked up automatically, no key.\n")
  fh:write("Delete this file to dismiss. The organism keeps working on rules / the local model meanwhile.\n")
  fh:close()
  self.ctx.log:info("modelmgr: no API key found — wrote %s (free providers + where to drop a key)", path)
  audit(self, "key_request: " .. path)
end

-- ===== MESH: what this node offers, and what it may borrow from peers =====================
-- Peers' beacons (colony/peers/<id>) carry capability fields the host-side nerve copies from
-- state/mesh_caps: brain=, llm_port=/llm_path=/llm_model= (a model endpoint peers may call),
-- online=0/1 (internet), gateway=<port> (a CONNECT proxy peers may tunnel through).

local function shellq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- is the internet reachable from this node? (cached; curl does not use the mesh proxy, so
-- while tunnelling through a gateway this keeps saying "offline" — which is the truth)
function ModelMgr:online()
  local now = os.time()
  if self._online_at and now - self._online_at < 60 then return self._online end
  local ph = io.popen and io.popen("curl -s -m 3 -o /dev/null -w '%{http_code}' https://huggingface.co 2>/dev/null")
  local code = ph and ph:read("*a") or ""; if ph then ph:close() end
  self._online = code:match("^[23]") ~= nil
  self._online_at = now
  return self._online
end

function ModelMgr:peers_dir()
  return (self.ctx.cfg.colony_root or (self.ctx.cfg.reports_dir:gsub("/reports$", ""))) .. "/colony/peers"
end

-- read every peer beacon into { id, fields{} , ip }
function ModelMgr:peers()
  local out = {}
  local ph = io.popen and io.popen('ls -1 "' .. self:peers_dir() .. '" 2>/dev/null')
  if not ph then return out end
  for id in ph:lines() do
    local fh = io.open(self:peers_dir() .. "/" .. id, "r")
    if fh then
      local body = fh:read("*a"); fh:close()
      local f = {}
      for k, v in body:gmatch("([%w_]+)=(%S+)") do f[k] = v end
      if f.addr then                                  -- remote (mesh) peers only
        f.ip = f.addr:match("^(.-):%d+$") or f.addr
        out[#out + 1] = { id = id, f = f }
      end
    end
  end
  ph:close()
  return out
end

-- advertise: write state/mesh_caps for the nerve to put in our beacon
function ModelMgr:mesh_caps()
  local cfg = self.ctx.cfg
  if not cfg.mesh and not os.getenv("EVOLUA_MESH") then return end
  local lines = {}
  local active = self:active()
  if active then lines[#lines + 1] = "brain=" .. tostring(active):gsub("%s+", "_"):gsub("[^%w%._:/@%-]", "_"):sub(1, 80) end
  lines[#lines + 1] = "online=" .. (self:online() and "1" or "0")
  -- a model served on THIS host (localhost base) can serve peers too: tell them port + path + model
  if cfg.mesh_share_brain ~= false and cfg.llm_remote and cfg.llm_remote.base then
    local host, port, path = cfg.llm_remote.base:match("^https?://([^/:]+):?(%d*)(/?.*)$")
    if host and (host == "localhost" or host == "127.0.0.1" or host == "0.0.0.0") and not self.remote_down then
      lines[#lines + 1] = "llm_port=" .. (port ~= "" and port or "80")
      lines[#lines + 1] = "llm_path=" .. (path ~= "" and path or "/")
      lines[#lines + 1] = "llm_model=" .. tostring(cfg.llm_remote.model):gsub("%s+", "_")
    end
  end
  local fh = io.open(cfg.state_dir .. "/mesh_caps", "w")
  if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
end

-- borrow a brain: no brain here, a peer advertises a model endpoint → think through it
function ModelMgr:peer_brain()
  local cfg = self.ctx.cfg
  if cfg.mesh_use_peer_brain == false or not cfg.llm_attach then return false end
  if self:active() then return false end
  for _, p in ipairs(self:peers()) do
    if p.f.llm_port and p.f.ip then
      local base = string.format("http://%s:%s%s", p.f.ip, p.f.llm_port, p.f.llm_path or "/v1")
      local label = cfg.llm_attach({ id = "peer:" .. p.id, kind = "openai", base = base, model = p.f.llm_model or "default",
                                     key = nil, free = true }, p.f.llm_model)
      if label then
        self.peer_brain_id = p.id
        self.ctx.log:info("\27[32m🧠 brain online: %s [borrowed from mesh peer %s]\27[0m", label, p.id)
        audit(self, "mesh: borrowing brain from peer " .. p.id .. " at " .. base)
        self.ctx.report("model", "thinking through mesh peer " .. p.id .. " (" .. base .. ")")
        self.ctx.bus:emit("mesh.borrow", { what = "brain", peer = p.id, base = base })
        return true
      end
    end
  end
  return false
end

-- borrow a gateway: no internet here, a peer with internet serves a CONNECT proxy → tunnel
function ModelMgr:gateway()
  local cfg = self.ctx.cfg
  if cfg.mesh_use_gateway == false then return end
  local set, clear = rawget(_G, "net_proxy_set"), rawget(_G, "net_proxy_clear")
  if not set then return end
  local need = cfg.mesh_force_gateway or not self:online()
  if need and not self.gateway_peer then
    for _, p in ipairs(self:peers()) do
      if p.f.gateway and p.f.ip and (p.f.online == "1" or cfg.mesh_force_gateway) then
        local url = string.format("http://%s:%s", p.f.ip, p.f.gateway)
        set(url)
        self.gateway_peer = p.id
        self.ctx.log:info("\27[33m⇄ no internet here — tunnelling online calls through mesh peer %s (%s)\27[0m", p.id, url)
        audit(self, "mesh: gateway via peer " .. p.id .. " " .. url)
        self.ctx.report("model", "internet via mesh peer " .. p.id)
        self.ctx.bus:emit("mesh.borrow", { what = "gateway", peer = p.id, url = url })
        return
      end
    end
  elseif self.gateway_peer and not need then
    if clear then clear() end
    self.ctx.log:info("⇄ internet is back — dropping the mesh gateway (%s)", self.gateway_peer)
    audit(self, "mesh: gateway released")
    self.gateway_peer = nil
  end
end

function ModelMgr:step()
  local cfg = self.ctx.cfg
  self:want_key()
  if cfg.mesh or os.getenv("EVOLUA_MESH") then
    for _, step in ipairs({ "gateway", "peer_brain", "mesh_caps" }) do
      local ok, err = pcall(self[step], self)
      if not ok then self.ctx.log:warn("modelmgr: mesh %s failed: %s", step, tostring(err)) end
    end
  end
  local online = self:failover()
  if online and cfg.llm_remote_only ~= false then return nil end   -- online: no local ladder needed
  local caps = HostCaps.probe(self.models_dir)

  -- 0) capacity drop: an attached brain that no longer fits → free it, re-find smaller
  if self.binding and self:active() and self.active_mb
     and (self.active_mb * 1.25 + 256) > self:usable_mb(caps) * 1.3 then
    local unload = rawget(_G, "llm_unload")
    if unload then
      unload(); self.active_mb = nil
      self.ctx.log:warn("modelmgr: brain no longer fits usable RAM (%dMB) — unloaded", math.floor(self:usable_mb(caps)))
      audit(self, "model_unload: capacity dropped")
    end
  end

  -- 1) FIND: no brain → look on the host (rescan occasionally; hosts gain models)
  if self.binding and not self:active() and cfg.model_discover ~= false
     and (self.scans == 0 or self.scans % 5 == 0 or math.random() < 0.2) then
    if self:attach_found(caps) then return { action = "attach" } end
  elseif self.binding and not self:active() then
    self.scans = self.scans + 1
  end

  -- 2) FETCH: still a bottleneck and the host can carry a ladder tier?
  local cur = self:current_index()
  if self:active() and cur == 1 then
    -- an attached non-ladder model: treat it as "tier 1 + a brain"; only climb if it is weak
  end
  local bn = self:bottleneck()
  local d = ModelMgr.decide(caps, bn, cur,
    { headroom = cfg.model_headroom, floor_frac = cfg.model_ram_floor_frac,
      ignore_battery = cfg.model_ignore_battery, max_mb = cfg.model_max_mb })
  self.ctx.log:debug("modelmgr: decide=%s %d→%d (%s) | bottleneck=%s ram_avail=%s cores=%s disk=%s batt=%s",
    d.action, d.from, d.to, d.reason, tostring(bn),
    tostring(caps.ram_avail_mb), tostring(caps.cores), tostring(caps.disk_free_mb), tostring(caps.on_battery))
  if d.action == "hold" then return d end

  local from_t, to_t = LADDER[d.from], LADDER[d.to]
  if d.action == "downgrade" then
    -- a smaller ladder file we already downloaded? attach it; else just unload above handles it
    local p = to_t.file and (self.models_dir .. "/" .. to_t.file)
    local f = p and io.open(p, "rb")
    if f then f:close()
      if self.ctx.autonomy then
        self.ctx.autonomy:consider({
          entity = "self.model", confidence = 0.9, action = "act",
          hypothesis = string.format("downgrade model %s → %s (%s)", from_t.name, to_t.name, d.reason),
          proposed = { verb = "model_downgrade", reversible = true, tier = d.to, tier_name = to_t.name, path = p,
                       desc = "switch to a smaller model already on disk", undo = "re-attach " .. from_t.name },
        })
      end
    else
      self:set_index(d.to)
    end
    return d
  end

  if not rawget(_G, "model_acquire") then
    if not self._warned_acquire then
      self._warned_acquire = true
      self.ctx.log:warn("modelmgr: would fetch %s but this host has no acquire binding (build with --features acquire)", to_t.name)
    end
    return d
  end
  -- an upgrade downloads data → SUGGESTION (approval inbox) unless the operator
  -- opted into unattended acquisition — still bounded to the pinned url+sha.
  local autonomous = cfg.model_unattended and true or false
  local decision = {
    entity = "self.model",
    hypothesis = string.format("fetch model %s → %s (%s; ~%dMB)", from_t.name, to_t.name, d.reason, to_t.approx_mb),
    confidence = autonomous and 0.9 or 0.7,
    action = autonomous and "act" or "suggest",
    proposed = {
      verb = "model_upgrade", reversible = true, tier = d.to, tier_name = to_t.name,
      file = to_t.file, approx_mb = to_t.approx_mb, url = to_t.url, sha = to_t.sha,
      desc = string.format("download %s sized to this host", to_t.name),
      undo = string.format("revert to %s", from_t.name),
    },
  }
  if self.ctx.autonomy then self.ctx.autonomy:consider(decision) end
  return d
end

return ModelMgr
