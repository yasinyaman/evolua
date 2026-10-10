-- core/brain.lua — which decision brain the reasoner thinks with, and switching it.
-- The host (src/brain.rs) loads whatever it is told to; this module decides WHAT.
--
-- The organism's own DEFAULT brain never changes: a model it downloaded
-- (models/decision.gguf) if any, else the one embedded in the binary. But if this
-- machine already has a BIGGER brain the organism can use — a GGUF another tool
-- fetched, a running local LLM server, the OS's on-device model — that one is used
-- instead, and the default stays the fallback. "Can use" = fits in RAM, loads,
-- answers fast enough (brain_max_seconds) and doesn't fall back to rules too often;
-- a brain that fails any of these is backed off and the next smaller one is tried.

local P = require("core.platform")

local Brain = {}
Brain.spec = nil                          -- spec of the loaded brain (nil = rules only)
Brain.stats = { calls = 0, timed = 0, secs = 0 }   -- answer times since the last load

local EMBEDDED_PARAMS = 0.135             -- SmolLM2-135M (embed_smol)

local function host(name) return rawget(_G, name) end

-- the brain kinds this binary can load: set of "gguf" | "embedded" | "service" | "apple"
function Brain.kinds()
  local set, f = {}, host("host_brain_kinds")
  if f then for _, k in ipairs(f()) do set[k] = true end end
  return set
end

-- the loaded brain: { kind, id, name, params_b } (kind = "none" when reasoning with rules)
function Brain.info()
  local f = host("host_brain_info")
  return f and f() or { kind = "none", id = "none", name = "rules" }
end

-- the back-off key a brain's failures are recorded under (core/modelmgr.lua)
function Brain.key(spec)
  return "brain:" .. tostring(spec and (spec.name or spec.path or spec.kind) or "rules")
end

-- llm_complete as the reasoner sees it: the host call, timed. The first answer
-- after a load includes warm-up, so it isn't counted.
local function timed(complete)
  return function(system, user, max_tokens)
    local t0 = P.clock()
    local out = complete(system, user, max_tokens)
    local s = Brain.stats
    s.calls = s.calls + 1
    if s.calls > 1 then s.timed, s.secs = s.timed + 1, s.secs + (P.clock() - t0) end
    return out
  end
end

-- mean seconds per answer of the loaded brain (nil until min_calls timed answers)
function Brain.mean_seconds(min_calls)
  local s = Brain.stats
  if s.timed < (min_calls or 3) then return nil end
  return s.secs / s.timed
end

-- Load a brain ({ kind = "none" } unloads). On success the reasoner's
-- llm_complete points at it; on failure the current brain stays.
function Brain.load(spec)
  local f = host("host_brain_load")
  if not f then return false, "this build has no brain backends (--features llm / service / apple)" end
  local ok, info, err = pcall(f, spec)
  if not ok then return false, tostring(info) end
  if not info then return false, err or "load failed" end
  Brain.spec = (spec.kind ~= "none") and spec or nil
  Brain.stats = { calls = 0, timed = 0, secs = 0 }
  local complete = host("host_brain_complete")
  rawset(_G, "llm_complete", (Brain.spec and complete) and timed(complete) or nil)
  return true, info
end

-- ── what's on this machine ─────────────────────────────────────────────────
-- Every brain this binary could load from the machine, smallest first:
-- { { kind, name, source, params_b, size_mb, spec }, … }. size_mb is what it
-- costs the host's RAM (0 for the OS model, which the system manages).
function Brain.candidates(cfg)
  local kinds, out = Brain.kinds(), {}
  local function add(c) out[#out + 1] = c end
  if kinds.gguf then
    for _, m in ipairs(P.models(cfg.model_dirs)) do
      add({ kind = "gguf", name = m.name, source = m.source, params_b = m.params_b or 0, size_mb = m.size_mb or 0,
            spec = { kind = "gguf", path = m.path, name = m.name, params_b = m.params_b } })
    end
  end
  local services = host("host_services")
  if kinds.service and services then
    local ok, list = pcall(services, cfg.service_urls)
    for _, s in ipairs(ok and list or {}) do
      for _, m in ipairs(s.models or {}) do
        add({ kind = "service", name = m.name, source = s.api .. " " .. s.url, params_b = m.params_b or 0,
              size_mb = m.size_mb or 0,
              spec = { kind = "service", url = s.url, api = s.api, model = m.name, name = m.name, params_b = m.params_b } })
      end
    end
  end
  local apple = host("host_apple_status")
  if kinds.apple and apple and apple() == "available" then
    add({ kind = "apple", name = "Apple on-device model", source = "macOS", params_b = 3, size_mb = 0,
          spec = { kind = "apple", name = "Apple on-device model", params_b = 3 } })
  end
  -- smallest first; at equal size the one costing less of our RAM comes last (= preferred)
  table.sort(out, function(a, b)
    if a.params_b ~= b.params_b then return a.params_b < b.params_b end
    return (a.size_mb or 0) > (b.size_mb or 0)
  end)
  return out
end

-- does it fit? no more than model_ram_share of physical RAM (models are
-- mmapped, so total RAM — not the momentary "available" figure — is the fair
-- yardstick), and within model_max_mb if one is set
function Brain.fits(c, cfg, ram_total_mb)
  local size = c.size_mb or 0
  if cfg.model_max_mb and size > cfg.model_max_mb then return false end
  if ram_total_mb and size > ram_total_mb * (cfg.model_ram_share or 0.25) then return false end
  return true
end

-- the organism's own default brain: what it downloaded, else what it was built with
function Brain.default(models_dir)
  local dl = models_dir .. "/decision.gguf"
  local fh = io.open(dl, "r")
  if fh and Brain.kinds().gguf then
    fh:close()
    local params                           -- its size, from its own GGUF header
    for _, m in ipairs(P.models({ models_dir })) do
      if m.path == dl then params = m.params_b end
    end
    return { kind = "gguf", path = dl, name = "decision.gguf", params_b = params }
  end
  if fh then fh:close() end
  if Brain.kinds().embedded then return { kind = "embedded", params_b = EMBEDDED_PARAMS } end
  return nil
end

-- System brains bigger than `floor` that fit and aren't backed off, biggest first.
function Brain.bigger(cfg, floor, ram_total_mb, skip)
  local out, cands = {}, Brain.candidates(cfg)
  for i = #cands, 1, -1 do
    local c = cands[i]
    if c.params_b > floor and Brain.fits(c, cfg, ram_total_mb) and not (skip and skip(Brain.key(c.spec))) then
      out[#out + 1] = c
    end
  end
  return out
end

-- ── this life's brain ──────────────────────────────────────────────────────
-- With cfg.brain = "auto": $EVOLUA_MODEL (explicit) → the biggest usable brain
-- on this machine that is bigger than the default → the default (downloaded,
-- else embedded) → rules. cfg.brain = <kind> keeps only that kind; "rules" loads
-- nothing. opts = { ram_total_mb, skip = function(key) → backed off? }.
-- Returns info, how = "explicit" | "machine" | "default" | "rules", default_spec.
function Brain.select(cfg, models_dir, log, opts)
  opts = opts or {}
  local want = cfg.brain or "auto"
  local function note(fmt, ...) if log then log:info("brain: " .. fmt, ...) end end
  if want == "rules" then note("rules only (--brain rules)"); return Brain.info(), "rules" end
  local kinds = Brain.kinds()
  if not next(kinds) then note("this build has no brain backends — reasoning with rules"); return Brain.info(), "rules" end

  local function try(spec, why)
    if want ~= "auto" and spec.kind ~= want then return false end
    if not kinds[spec.kind] then return false end
    local ok, res = Brain.load(spec)
    if ok then
      note("%s — %s (%s%s)", res.name, why, res.kind, res.params_b and string.format(", %.2gB", res.params_b) or "")
    else
      note("skipping %s (%s): %s", spec.name or spec.path or spec.kind, why, tostring(res))
    end
    return ok
  end

  local env = os.getenv("EVOLUA_MODEL")
  if env and env ~= "" and try({ kind = "gguf", path = env }, "$EVOLUA_MODEL") then return Brain.info(), "explicit" end

  local default = Brain.default(models_dir)
  local floor = default and (default.params_b or 0) or 0
  for _, c in ipairs(Brain.bigger(cfg, floor, opts.ram_total_mb, opts.skip)) do
    if try(c.spec, "bigger than the default, found on this machine: " .. c.source) then
      return Brain.info(), "machine", default
    end
  end
  if default and try(default, default.kind == "embedded" and "the built-in default" or "the downloaded default") then
    return Brain.info(), "default", default
  end
  note("no brain available — reasoning with rules")
  return Brain.info(), "rules", default
end

return Brain
