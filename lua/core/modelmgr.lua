-- core/modelmgr.lua — meta-evolution: the model is a unit under selection (Faz 4)
-- Measures the host (hostcaps), and when the current brain is a BOTTLENECK climbs:
-- first to a stronger brain already on this machine (core/brain.lua candidates —
-- no download), else up the download ladder when the machine is CAPABLE; descends
-- when capacity drops. It only ever PROPOSES a change through the autonomy ladder,
-- gated by the same policy + approval inbox as everything else; every switch is
-- judged on fresh samples and rolled back if the new brain does worse.
-- See docs/ROADMAP.md §Faz 4.

local HostCaps = require("core.hostcaps")
local P        = require("core.platform")
local Brain    = require("core.brain")

local ModelMgr = {}
ModelMgr.__index = ModelMgr

-- Ordered capability ladder. Tier 1 ships embedded (the decision brain); higher
-- tiers are downloaded into <home>/models on capable machines. Tier 2 is wired
-- with a pinned url+sha (real acquisition via model_acquire); tiers 3+ are stubs
-- awaiting their own pinned artifacts.
-- Every downloadable tier is a PINNED, checksummed artifact (Qwen2.5-Coder-Instruct:
-- the smallest family that reliably emits both the reasoner's strict schema AND
-- compilable Lua for the synthesizer organ). The organism may choose WHEN to fetch
-- one, never WHAT — url+sha bound it to a vetted file. All land as decision.gguf so
-- the previous one is kept as decision.prev for `model_rollback`.
-- ram_min_mb ≈ weights + KV cache + runtime; approx_mb = download size.
local HF = "https://huggingface.co/Qwen/"
local LADDER = {
  { name = "smol-135m-q4",   ram_min_mb = 500,  cores_min = 1, approx_mb = 90,   embedded = true, params_b = 0.135 },
  { name = "qwen2.5-coder-0.5b-q4", ram_min_mb = 600,  cores_min = 1, approx_mb = 469,  file = "decision.gguf", params_b = 0.5,
    url = HF .. "Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf?download=true",
    sha = "1d9614638d18024d0fbb36575a15f1302a3adf044df10345688ec4f6e1c4ff32" },
  { name = "qwen2.5-coder-1.5b-q4", ram_min_mb = 1600, cores_min = 2, approx_mb = 1066, file = "decision.gguf", params_b = 1.5,
    url = HF .. "Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true",
    sha = "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046" },
  { name = "qwen2.5-coder-3b-q4",   ram_min_mb = 2800, cores_min = 4, approx_mb = 2008, file = "decision.gguf", params_b = 3,
    url = HF .. "Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf?download=true",
    sha = "724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7" },
  { name = "qwen2.5-coder-7b-q4",   ram_min_mb = 5900, cores_min = 4, approx_mb = 4467, file = "decision.gguf", params_b = 7,
    url = HF .. "Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf?download=true",
    sha = "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c" },
}

function ModelMgr.new(ctx)
  local self = setmetatable({ ctx = ctx }, ModelMgr)
  self.models_dir = (ctx.cfg.reports_dir:gsub("/reports$", "")) .. "/models"
  P.mkdir_p(self.models_dir)
  self.locked = {}   -- tier -> why: acquisition failed in THIS life, don't retry it
  return self
end

-- ── acquisition failures: back off instead of re-downloading every check ───
-- A failed tier is not retried in the same life. Across lives (memory persists)
-- the wait doubles per failure, model_retry_secs · 2^(n-1), and after
-- model_max_attempts the tier is given up until state/memory.lua is reset.
function ModelMgr:blocked(tier)
  if self.locked[tier] then return "failed earlier this life (" .. self.locked[tier] .. ")" end
  local f = (self.ctx.memory.data.model_fail or {})[tier]
  if not f then return nil end
  if f.n >= (self.ctx.cfg.model_max_attempts or 3) then
    return string.format("gave up after %d failed attempts (last: %s)", f.n, tostring(f.last))
  end
  if os.time() < (f.next_at or 0) then
    return string.format("backing off until %s after %d failure(s)", os.date("%Y-%m-%d %H:%M", f.next_at), f.n)
  end
  return nil
end

function ModelMgr:record_failure(tier, why)
  self.locked[tier] = why or "failed"
  local md = self.ctx.memory.data
  md.model_fail = md.model_fail or {}
  local f = md.model_fail[tier] or { n = 0 }
  f.n = f.n + 1
  f.last = why or "failed"
  f.next_at = os.time() + math.floor((self.ctx.cfg.model_retry_secs or 3600) * 2 ^ (f.n - 1))
  md.model_fail[tier] = f
  self.ctx.memory:save()   -- a crash right after a failed download must not forget it
end

-- the brain was switched — a downloaded tier, or a brain adopted from this
-- machine. Forget the new one's failures and remember what it replaced, so the
-- switch can be judged (and rolled back) once the new brain has enough samples.
-- rec = { kind = "download"|"adopt", key, from_spec, to_spec, to_id, from_tier?, to_tier? }
function ModelMgr:record_upgrade(rec)
  local md = self.ctx.memory.data
  if md.model_fail and rec.key then md.model_fail[rec.key] = nil end
  rec.fallback_before = self:fallback_rate()
  md.model_upgrade = rec
  local c = md.counters                    -- the samples so far belong to the old brain
  if c then c.llm_ok, c.llm_fallback = 0, 0 end
  if rec.to_id then md.brain_id = rec.to_id end
  self.ctx.memory:save()
end

-- a ladder tier was downloaded to dest: switch to it now (as models/decision.gguf
-- it is also the organism's default brain in later lives)
function ModelMgr:acquired(act, dest)
  local from_tier, from_spec = self:current_index(), Brain.spec
  local spec = { kind = "gguf", path = dest, name = act.tier_name, params_b = LADDER[act.tier] and LADDER[act.tier].params_b }
  local ok, info = Brain.load(spec)
  self:set_index(act.tier)
  self:record_upgrade({ kind = "download", key = act.tier, from_tier = from_tier, to_tier = act.tier,
                        from_spec = from_spec, to_spec = spec, to_id = ok and info.id or nil })
  return ok, info
end

-- switch to a brain already on this machine, now
function ModelMgr:adopt(spec)
  local key = Brain.key(spec)
  local from_spec = Brain.spec
  local ok, info = Brain.load(spec)
  if not ok then
    self:record_failure(key, tostring(info))
    return false, info
  end
  self:record_upgrade({ kind = "adopt", key = key, from_spec = from_spec, to_spec = spec, to_id = info.id })
  return true, info
end

-- a new life started with `info` as its brain. how/default come from
-- Brain.select: "machine" means a brain bigger than the default was found on
-- this machine and is now on probation — judged on fresh samples like any switch.
function ModelMgr:on_boot(info, how, default)
  local md = self.ctx.memory.data
  -- mesh: say what we offer from the first beacon on, and borrow at once if a peer already offers
  self:mesh_step({ "peer_brain", "mesh_caps" })
  info = Brain.info()
  if md.brain_id ~= info.id then           -- a different brain than last life: fresh samples
    local c = md.counters or {}
    c.llm_ok, c.llm_fallback = 0, 0
    md.counters, md.brain_id = c, info.id
  end
  local up = md.model_upgrade
  if up and up.to_id and not up.judged and info.id ~= up.to_id and (self.ctx.cfg.brain or "auto") == "auto" then
    -- the brain we switched to didn't come back (file gone, failed to load,
    -- service down): back off from it
    self.ctx.log:warn("modelmgr: %s did not load this life — dropping it",
      tostring(up.to_spec and up.to_spec.name or up.to_id))
    self:record_failure(up.key, "did not load")
    md.model_upgrade, up = nil, nil
  end
  local key = Brain.key(Brain.spec)
  md.brain_ok = md.brain_ok or {}
  if how == "machine" and not md.brain_ok[key] and not (up and up.to_id == info.id) then
    self:record_upgrade({ kind = "machine", key = key, from_spec = default, to_spec = Brain.spec, to_id = info.id })
  end
end

-- is the loaded brain too slow to be usable here? Then step down: the next
-- smaller brain on this machine that is still bigger than the default, else the
-- default. The slow one is backed off, so the next life starts lower too.
function ModelMgr:check_speed(caps)
  local cfg = self.ctx.cfg
  local secs = Brain.mean_seconds(3)
  local limit = cfg.brain_max_seconds or 10
  if not secs or secs <= limit or not Brain.spec then return end
  local default = Brain.default(self.models_dir)
  local cur = Brain.info()
  if (cfg.brain or "auto") ~= "auto" or (os.getenv("EVOLUA_MODEL") or "") ~= ""
     or (default and Brain.key(default) == Brain.key(Brain.spec)) then
    return                                  -- explicit, or already the default floor
  end
  local key = Brain.key(Brain.spec)
  self:record_failure(key, string.format("too slow: %.1fs per decision (limit %ss)", secs, limit))
  if self.ctx.memory.data.model_upgrade and self.ctx.memory.data.model_upgrade.key == key then
    self.ctx.memory.data.model_upgrade = nil
  end
  local floor = default and (default.params_b or 0) or 0
  local nxt
  for _, c in ipairs(Brain.bigger(cfg, floor, caps.ram_total_mb, function(k) return self:blocked(k) end)) do
    if c.params_b < (cur.params_b or math.huge) then nxt = c.spec; break end
  end
  local target = nxt or default or { kind = "none" }
  local ok, info = Brain.load(target)
  local msg = string.format("%s is too slow here (%.1fs per decision > %ss) — %s %s", tostring(cur.name), secs, limit,
    ok and "switched to" or "could not switch to", ok and tostring(info.name) or tostring(info))
  self.ctx.log:warn("modelmgr: %s", msg)
  if self.ctx.autonomy then self.ctx.autonomy:audit("brain: " .. msg) end
  if ok then self.ctx.memory.data.brain_id = info.id end
  return true
end

local function spec_name(spec) return spec and (spec.name or spec.path or spec.kind) or "rules" end

-- reasoner rule-fallback rate since the counters were last reset (nil = too few samples)
function ModelMgr:fallback_rate()
  local c = self.ctx.memory.data.counters or {}
  local ok, fb = c.llm_ok or 0, c.llm_fallback or 0
  if ok + fb < (self.ctx.cfg.model_min_samples or 20) then return nil end
  return fb / (ok + fb)
end

-- undo the last switch, now: load the brain it replaced again (rules if there
-- was none) and back off the rolled-back brain, so neither the next check nor
-- the next life's boot picks it straight away. For a download, also put the
-- files back: acquire.rs keeps the replaced model as <name>.prev (decision.gguf
-- → decision.prev); the downloaded file is set aside as <file>.rejected.
function ModelMgr:rollback()
  local md = self.ctx.memory.data
  local up = md.model_upgrade
  if not up then return false, "no recorded upgrade to roll back" end
  local to_name
  if up.kind == "adopt" or up.kind == "machine" then
    to_name = spec_name(up.to_spec)
  else                                     -- a download (records from older versions too)
    local cur = self:current_index()
    local to, from = up.to_tier or up.to, up.from_tier or up.from
    if not (to == cur and from and from < cur) then return false, "no recorded upgrade to roll back" end
    local file = LADDER[cur].file
    if file then
      local live = self.models_dir .. "/" .. file
      local prev = self.models_dir .. "/" .. file:gsub("%.[^.]+$", "") .. ".prev"
      os.remove(live .. ".rejected")
      os.rename(live, live .. ".rejected")
      local fh = io.open(prev, "r")
      if fh then fh:close(); os.rename(prev, live) end
    end
    self:set_index(from)
    to_name = LADDER[cur].name
  end
  Brain.load(up.from_spec or { kind = "none" })
  md.model_upgrade = nil
  md.brain_id = Brain.info().id
  self:record_failure(up.key or up.to, "rolled back")
  return true, string.format("%s → %s", to_name, spec_name(up.from_spec))
end

ModelMgr.ladder = LADDER

local function audit(self, line)
  if self.ctx.autonomy then self.ctx.autonomy:audit(line) end
end

function ModelMgr:home()
  return (self.ctx.cfg.reports_dir:gsub("[/\\]reports$", ""))
end

local function mesh_on(cfg) return cfg.mesh or os.getenv("EVOLUA_MESH") == "1" end

-- ── FAILOVER between the online brain and a local one ──────────────────────
-- The host marks the online service "down" after consecutive failures (blocked
-- network, quota, outage) and backs off. Here we notice that, make sure a LOCAL
-- brain is loaded so the organism keeps thinking (machine brain / default), probe
-- the service on the check cadence, and when it answers again go back online —
-- unloading the local model if the operator wants online-only (llm_remote_only).
-- Returns true while the online brain is serving.
function ModelMgr:failover(caps)
  local st = Brain.remote_status()
  if not st then return false end                       -- no online brain attached
  local cfg, ctx = self.ctx.cfg, self.ctx
  if st.down and not self.remote_down then
    self.remote_down = true
    ctx.log:warn("\27[33m⇄ online brain unreachable (%s) — failover to a local brain\27[0m",
      st.last_error ~= "" and st.last_error or "no detail")
    audit(self, "brain_failover: online → local (" .. tostring(st.last_error) .. ")")
    if ctx.report then ctx.report("model", "online brain unreachable — running on a local brain / rules until it answers again") end
    if ctx.bus then ctx.bus:emit("brain.failover", { to = "local", reason = st.last_error }) end
    if not Brain.spec then                                -- nothing local loaded: pick one now
      local info, how = Brain.select(cfg, self.models_dir, ctx.log,
        { ram_total_mb = caps and caps.ram_total_mb, skip = function(k) return self:blocked(k) end, no_online = true })
      ctx.log:info("brain: failover brain is %s (%s)", tostring(info.name), tostring(how))
      self.ctx.memory.data.brain_id = info.id
    end
  elseif self.remote_down and not st.down then
    self.remote_down = false
    ctx.log:info("\27[32m⇄ online brain is back (%s) — using it again\27[0m", st.label)
    audit(self, "brain_failover: local → online")
    if ctx.report then ctx.report("model", "online brain is back") end
    if ctx.bus then ctx.bus:emit("brain.failover", { to = "online" }) end
    if cfg.llm_remote_only ~= false and Brain.spec then  -- free the local model's RAM
      Brain.load({ kind = "none" })
    end
    self.ctx.memory.data.brain_id = Brain.info().id
  elseif self.remote_down then
    local probe = rawget(_G, "host_remote_probe")        -- a small real call past the backoff window
    if probe and probe() then ctx.log:debug("modelmgr: online probe succeeded") end
  end
  return not self.remote_down
end

-- ── KEYS: ask for one, pick one up ─────────────────────────────────────────
-- The organism cannot sign up for an API account (every free tier wants a human:
-- e-mail/OAuth, CAPTCHA, terms). What it CAN do: say precisely what it needs — one
-- file in the approval inbox listing the free providers, where a key comes from and
-- where to drop it — and pick the key up the moment it appears (keys/<provider>).
function ModelMgr:want_key()
  local cfg, ctx = self.ctx.cfg, self.ctx
  if cfg.llm_key_request == false or cfg.llm_api ~= "auto" or not cfg.llm_providers then return end
  if (cfg.brain or "auto") ~= "auto" and cfg.brain ~= "remote" then return end
  if not rawget(_G, "host_remote_set") then return end
  if Brain.remote and not Brain.remote.keyless then return end   -- keyed and online already
  local home = self:home()
  -- 1) hot pickup: a key file for a keyed provider → attach now (replaces the keyless one)
  for _, p in ipairs(cfg.llm_providers) do
    if p.key and not os.getenv(p.key) then
      local fh = io.open(home .. "/keys/" .. p.id, "r")
      if fh then
        fh:close()
        local label = Brain.remote_attach(p, cfg, home)
        if label then
          ctx.log:info("\27[32m🧠 brain online: %s [key file keys/%s]\27[0m", label, p.id)
          audit(self, "model_attach: online " .. label)
          if ctx.report then ctx.report("model", "online brain attached from keys/" .. p.id .. ": " .. label) end
          if cfg.llm_remote_only ~= false and Brain.spec then Brain.load({ kind = "none" }) end
          self.ctx.memory.data.brain_id = Brain.info().id
          return
        end
      end
    end
  end
  -- 2) ask once per life — only when the organism has no proper brain
  if self.key_requested or Brain.remote then return end
  local b = Brain.info()
  if b.kind ~= "none" and (b.params_b or 0) >= 3 then return end
  self.key_requested = true
  P.mkdir_p(home .. "/approvals"); P.mkdir_p(home .. "/keys")
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
  ctx.log:info("modelmgr: no API key found — wrote %s (free providers + where to drop a key)", path)
  audit(self, "key_request: " .. path)
end

-- ── MESH: what this node offers, and what it may borrow from peers ──────────
-- Peers' beacons (colony/peers/<id>) carry capability fields the host-side nerve
-- copies from state/mesh_caps: brain=, llm_port=/llm_path=/llm_model= (a model
-- endpoint peers may call), online=0/1 (internet), gateway=<port> (a CONNECT proxy
-- peers may tunnel through).

-- is the internet reachable from this node? (cached; curl does not use the mesh proxy,
-- so while tunnelling through a gateway this keeps saying "offline" — which is the truth)
function ModelMgr:online()
  local now = os.time()
  if self._online_at and now - self._online_at < 60 then return self._online end
  local code = P.run("curl -s -m 3 -o /dev/null -w '%{http_code}' https://huggingface.co")
  self._online = code:match("^[23]") ~= nil
  self._online_at = now
  return self._online
end

function ModelMgr:peers_dir()
  return (self.ctx.cfg.colony_root or self:home()) .. "/colony/peers"
end

-- every REMOTE peer beacon (carries addr=) as { id, f = fields, f.ip }
function ModelMgr:peers()
  local out, dir = {}, self:peers_dir()
  for _, id in ipairs(P.list_dir(dir)) do
    local fh = io.open(dir .. "/" .. id, "r")
    if fh then
      local body = fh:read("*a"); fh:close()
      local f = {}
      for k, v in body:gmatch("([%w_]+)=(%S+)") do f[k] = v end
      if f.addr then
        f.ip = f.addr:match("^(.-):%d+$") or f.addr
        out[#out + 1] = { id = id, f = f }
      end
    end
  end
  return out
end

-- a model served on THIS host that peers could call: port + path + model, or nil
function ModelMgr:served_model()
  local function local_host(h) return h == "localhost" or h == "127.0.0.1" or h == "0.0.0.0" end
  if Brain.remote and Brain.remote.base and not self.remote_down then
    local host, port, path = Brain.remote.base:match("^https?://([^/:]+):?(%d*)(/?.*)$")
    if host and local_host(host) then return port ~= "" and port or "80", path ~= "" and path or "/", Brain.remote.model end
  end
  local s = Brain.spec
  if s and s.kind == "service" and s.url then         -- Ollama / LM Studio / llama-server: all speak /v1
    local host, port = s.url:match("^https?://([^/:]+):?(%d*)")
    if host and local_host(host) then return port ~= "" and port or "80", "/v1", s.model end
  end
  return nil
end

-- advertise: write state/mesh_caps for the nerve to put in our beacon
function ModelMgr:mesh_caps()
  local cfg = self.ctx.cfg
  if not mesh_on(cfg) then return end
  local lines = {}
  local b = Brain.info()
  if b.kind ~= "none" then
    lines[#lines + 1] = "brain=" .. tostring(b.id):gsub("%s+", "_"):gsub("[^%w%._:/@%-]", "_"):sub(1, 80)
  end
  lines[#lines + 1] = "online=" .. (self:online() and "1" or "0")
  if cfg.mesh_share_brain ~= false then
    local port, path, model = self:served_model()
    if port then
      lines[#lines + 1] = "llm_port=" .. port
      lines[#lines + 1] = "llm_path=" .. path
      lines[#lines + 1] = "llm_model=" .. tostring(model):gsub("%s+", "_")
    end
  end
  local fh = io.open(cfg.state_dir .. "/mesh_caps", "w")
  if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
end

-- borrow a brain: no brain here, a peer advertises a model endpoint → think through it
function ModelMgr:peer_brain()
  local cfg, ctx = self.ctx.cfg, self.ctx
  if cfg.mesh_use_peer_brain == false then return false end
  if Brain.info().kind ~= "none" then return false end
  for _, p in ipairs(self:peers()) do
    if p.f.llm_port and p.f.ip then
      local base = string.format("http://%s:%s%s", p.f.ip, p.f.llm_port, p.f.llm_path or "/v1")
      local label = Brain.remote_attach({ id = "peer:" .. p.id, kind = "openai", base = base,
                                          model = p.f.llm_model or "default", key = nil, free = true }, cfg, self:home(), p.f.llm_model)
      if label then
        self.peer_brain_id = p.id
        ctx.log:info("\27[32m🧠 brain online: %s [borrowed from mesh peer %s]\27[0m", label, p.id)
        audit(self, "mesh: borrowing brain from peer " .. p.id .. " at " .. base)
        if ctx.report then ctx.report("model", "thinking through mesh peer " .. p.id .. " (" .. base .. ")") end
        if ctx.bus then ctx.bus:emit("mesh.borrow", { what = "brain", peer = p.id, base = base }) end
        self.ctx.memory.data.brain_id = Brain.info().id
        return true
      end
    end
  end
  return false
end

-- borrow a gateway: no internet here, a peer with internet serves a CONNECT proxy → tunnel
function ModelMgr:gateway()
  local cfg, ctx = self.ctx.cfg, self.ctx
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
        ctx.log:info("\27[33m⇄ no internet here — tunnelling online calls through mesh peer %s (%s)\27[0m", p.id, url)
        audit(self, "mesh: gateway via peer " .. p.id .. " " .. url)
        if ctx.report then ctx.report("model", "internet via mesh peer " .. p.id) end
        if ctx.bus then ctx.bus:emit("mesh.borrow", { what = "gateway", peer = p.id, url = url }) end
        return
      end
    end
  elseif self.gateway_peer and not need then
    if clear then clear() end
    ctx.log:info("⇄ internet is back — dropping the mesh gateway (%s)", self.gateway_peer)
    audit(self, "mesh: gateway released")
    self.gateway_peer = nil
  end
end

function ModelMgr:mesh_step(steps)
  if not mesh_on(self.ctx.cfg) then return end
  for _, step in ipairs(steps) do
    local ok, err = pcall(self[step], self)
    if not ok then self.ctx.log:warn("modelmgr: mesh %s failed: %s", step, tostring(err)) end
  end
end

function ModelMgr:current_index()
  local fh = io.open(self.models_dir .. "/current_tier", "r")
  if fh then local n = tonumber(fh:read("*a")); fh:close(); if n and LADDER[n] then return n end end
  return 1 -- embedded decision brain
end

function ModelMgr:set_index(i)
  local fh = io.open(self.models_dir .. "/current_tier", "w")
  if fh then fh:write(tostring(i)); fh:close() end
end

-- is the current model a bottleneck? proxy = high rule-fallback rate in the
-- reasoner (the embedded brain failing to produce usable decisions).
function ModelMgr:bottleneck()
  if self.ctx.cfg.model_force_upgrade then return true end  -- operator/demo override: always seek to climb
  local rate = self:fallback_rate()
  return rate ~= nil and rate > (self.ctx.cfg.model_fallback_rate or 0.4)
end

-- PURE decision: given caps + bottleneck + current tier, what should change?
-- Returns { action = "upgrade"|"downgrade"|"hold", from, to, reason }.
function ModelMgr.decide(caps, bottleneck, cur, opts)
  opts = opts or {}
  local headroom = opts.headroom or 0.7
  local usable = (caps.ram_avail_mb or caps.ram_total_mb or 0) * headroom

  -- highest tier the machine can comfortably run
  local feasible = 1
  for i, t in ipairs(LADDER) do
    if t.ram_min_mb <= usable and t.cores_min <= (caps.cores or 1) then feasible = i end
  end

  if feasible < cur then
    return { action = "downgrade", from = cur, to = feasible, reason = "capacity dropped (RAM/cores)" }
  end
  if bottleneck and feasible > cur and (opts.ignore_battery or not caps.on_battery) then
    local target = cur + 1
    local need_mb = LADDER[target].approx_mb
    if (caps.disk_free_mb or math.huge) < need_mb then
      return { action = "hold", from = cur, to = cur, reason = "insufficient disk for upgrade" }
    end
    return { action = "upgrade", from = cur, to = target, reason = "bottleneck + spare capacity" }
  end
  return { action = "hold", from = cur, to = cur, reason = bottleneck and "no spare capacity" or "model adequate" }
end

-- judge the last switch once the new brain has enough samples: if it falls back
-- to rules MORE often than the brain it replaced, propose rolling it back
-- (safe & reversible — it restores a brain that was already trusted).
function ModelMgr:judge_upgrade(info)
  local md = self.ctx.memory.data
  local up = md.model_upgrade
  if not up or up.judged then return end
  if up.to_id then
    if info.id ~= up.to_id then return end   -- not running the brain we switched to
  elseif (up.to_tier or up.to) ~= self:current_index() then
    return
  end
  local rate = self:fallback_rate()
  if not rate then return end
  up.judged = true                           -- one verdict per switch, not one per check
  -- vs the brain it replaced; a brain picked at boot has no "before" here, so it
  -- must simply stay under the bottleneck threshold
  local limit = up.fallback_before or (up.kind == "machine" and (self.ctx.cfg.model_fallback_rate or 0.4)) or 1
  if rate <= limit then                      -- the new brain earns its keep
    local md2 = self.ctx.memory.data
    md2.brain_ok = md2.brain_ok or {}
    if up.key then md2.brain_ok[up.key] = true end
    return
  end
  local to_name = up.to_spec and spec_name(up.to_spec) or (LADDER[up.to_tier or up.to] or {}).name
  local from_name = up.from_spec and spec_name(up.from_spec) or (LADDER[up.from_tier or up.from] or {}).name or "rules"
  if self.ctx.autonomy then
    self.ctx.autonomy:consider({
      entity = "self.model",
      hypothesis = string.format("rollback %s → %s: rule fallback %.0f%% vs %.0f%% before the switch",
        tostring(to_name), tostring(from_name), rate * 100, (up.fallback_before or 0) * 100),
      confidence = 0.9, action = "act",
      proposed = { verb = "model_rollback", reversible = true, tier_name = from_name,
                   desc = string.format("restore decision brain %s", tostring(from_name)),
                   undo = string.format("switch to %s again", tostring(to_name)) },
    })
  end
  return true
end

-- a brain on this machine meaningfully stronger than the current one, that fits
-- and hasn't failed recently: the weakest such (climb one step at a time).
-- Never overrides an explicit choice ($EVOLUA_MODEL, --brain <kind>).
function ModelMgr:adoptable(caps)
  local cfg = self.ctx.cfg
  if (cfg.brain or "auto") ~= "auto" or (os.getenv("EVOLUA_MODEL") or "") ~= "" then return nil end
  local cur = Brain.info()
  local cur_p = cur.params_b
  if cur.kind == "none" then cur_p = 0 end
  if not cur_p and cur.kind == "gguf" then cur_p = (LADDER[self:current_index()] or {}).params_b end
  if not cur_p then return nil end         -- can't tell what "stronger" means
  for _, c in ipairs(Brain.candidates(cfg)) do  -- weakest first
    local key = Brain.key(c.spec)
    if c.params_b > cur_p * 1.25 and Brain.fits(c, cfg, caps.ram_total_mb) and not self:blocked(key) then
      return c, key
    end
  end
  return nil
end

-- run a check and, if a change is warranted, PROPOSE it via the autonomy ladder
function ModelMgr:step()
  local caps = HostCaps.probe(self.models_dir)
  local cur = self:current_index()
  self:want_key()
  self:mesh_step({ "gateway", "peer_brain", "mesh_caps" })
  -- an online brain that is up makes the local ladder moot (llm_remote_only); while
  -- it is down, failover() has loaded a local brain and the ladder runs over that
  if self:failover(caps) and self.ctx.cfg.llm_remote_only ~= false then
    return { action = "hold", from = cur, to = cur, reason = "online brain is serving" }
  end
  if self:check_speed(caps) then return { action = "step down", from = cur, to = cur } end
  local info = Brain.info()
  if self:judge_upgrade(info) then return { action = "rollback", from = cur, to = cur } end
  local bn = self:bottleneck()

  -- 1) a stronger brain already on this machine? Switching to it costs no
  -- download; it is reversible like a downgrade, so it is proposed as an action
  -- (still capped by the autonomy ceiling — at the default `report` it's only reported).
  if bn then
    local c = self:adoptable(caps)
    if c then
      if self.ctx.autonomy then
        self.ctx.autonomy:consider({
          entity = "self.model",
          hypothesis = string.format("adopt %s (%s, %.2gB) — %s falls back to rules %.0f%% of the time",
            c.name, c.source, c.params_b, tostring(info.name), (self:fallback_rate() or 1) * 100),
          confidence = 0.9, action = "act",
          proposed = { verb = "model_adopt", reversible = true, spec = c.spec, tier_name = c.name,
                       desc = "switch the decision brain to " .. c.name,
                       undo = "switch back to " .. tostring(info.name) },
        })
      end
      return { action = "adopt", from = cur, to = cur, reason = c.name }
    end
  end

  -- 2) the download ladder
  local d = ModelMgr.decide(caps, bn, cur,
    { headroom = self.ctx.cfg.model_headroom, ignore_battery = self.ctx.cfg.model_ignore_battery })
  self.ctx.log:debug("modelmgr: decide=%s %d→%d (%s) | bottleneck=%s ram_avail=%s cores=%s disk=%s batt=%s",
    d.action, d.from, d.to, d.reason, tostring(bn),
    tostring(caps.ram_avail_mb), tostring(caps.cores), tostring(caps.disk_free_mb), tostring(caps.on_battery))
  if d.action == "upgrade" and (LADDER[d.to].params_b or 0) <= (info.params_b or 0) then
    -- the brain in use (likely one found on this machine) is already bigger
    return { action = "hold", from = cur, to = cur, reason = "current brain is bigger than the next tier" }
  end
  if d.action == "upgrade" then
    local why = self:blocked(d.to)
    if why then
      self.ctx.log:debug("modelmgr: not retrying %s — %s", LADDER[d.to].name, why)
      return { action = "hold", from = cur, to = cur, reason = why }
    end
  end
  if d.action == "hold" then return d end

  local from_t, to_t = LADDER[d.from], LADDER[d.to]
  local verb = d.action == "upgrade" and "model_upgrade" or "model_downgrade"
  -- a downgrade is safe & reversible (use a model we already trust) → acts;
  -- an upgrade downloads data → routed as a SUGGESTION (approval inbox), unless
  -- the operator opted into unattended acquisition (cfg.model_unattended), in
  -- which case it acts directly — still bounded to the ladder's pinned url+sha.
  local autonomous = d.action == "downgrade" or self.ctx.cfg.model_unattended
  local decision = {
    entity = "self.model",
    hypothesis = string.format("%s model %s → %s (%s)", d.action, from_t.name, to_t.name, d.reason),
    confidence = autonomous and 0.9 or 0.7,
    action = autonomous and "act" or "suggest",
    proposed = {
      verb = verb, reversible = true, tier = d.to, tier_name = to_t.name,
      file = to_t.file, approx_mb = to_t.approx_mb, url = to_t.url, sha = to_t.sha,
      desc = string.format("switch decision model to %s", to_t.name),
      undo = string.format("revert to %s", from_t.name),
    },
  }
  if self.ctx.autonomy then self.ctx.autonomy:consider(decision) end
  return d
end

return ModelMgr
