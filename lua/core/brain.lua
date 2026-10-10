-- core/brain.lua — which decision brain the reasoner thinks with, and switching it.
-- The host (src/brain.rs) loads whatever it is told to; this module decides WHAT:
-- an explicit model, the model manager's saved choice, a downloaded model, a
-- brain already on this machine (a GGUF another tool fetched, a running local
-- LLM service, the OS's own on-device model), or the embedded one. Loading points
-- the global llm_complete — what the reasoner calls — at the new brain.

local P   = require("core.platform")
local Ser = require("core.serialize")

local Brain = {}
Brain.spec = nil   -- spec of the loaded brain (nil = rules only)

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

-- Load a brain ({ kind = "none" } unloads). On success the reasoner's
-- llm_complete points at it; on failure the current brain stays.
function Brain.load(spec)
  local f = host("host_brain_load")
  if not f then return false, "this build has no brain backends (--features llm / service / apple)" end
  local ok, info, err = pcall(f, spec)
  if not ok then return false, tostring(info) end
  if not info then return false, err or "load failed" end
  Brain.spec = (spec.kind ~= "none") and spec or nil
  rawset(_G, "llm_complete", Brain.spec and host("host_brain_complete") or nil)
  return true, info
end

-- ── the model manager's saved choice (<models>/brain.lua) ──────────────────
function Brain.saved(models_dir)
  local fh = io.open(models_dir .. "/brain.lua", "r")
  if not fh then return nil end
  local src = fh:read("*a"); fh:close()
  local chunk = load("return " .. src, "brain", "t", {})
  local ok, spec = pcall(chunk or error)
  return (ok and type(spec) == "table" and spec.kind) and spec or nil
end

function Brain.save(models_dir, spec)
  local path = models_dir .. "/brain.lua"
  if not spec then os.remove(path); return end
  local fh = io.open(path, "w")
  if fh then fh:write(Ser.ser(spec)); fh:close() end
end

-- ── what could we switch to? ───────────────────────────────────────────────
-- Every brain this binary could load right now, weakest first:
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
  if kinds.embedded then
    add({ kind = "embedded", name = "embedded smollm2-135m", source = "binary", params_b = 0.135, size_mb = 140,
          spec = { kind = "embedded", params_b = 0.135 } })
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
  table.sort(out, function(a, b) return a.params_b < b.params_b end)
  return out
end

-- may this candidate run here? within model_max_mb, and no more than
-- model_ram_share of physical RAM (models are mmapped, so total RAM — not the
-- momentary "available" figure — is the fair yardstick)
function Brain.fits(c, cfg, ram_total_mb)
  local size = c.size_mb or 0
  if size > (cfg.model_max_mb or 2000) then return false end
  if ram_total_mb and size > ram_total_mb * (cfg.model_ram_share or 0.25) then return false end
  return true
end

-- ── this life's brain ──────────────────────────────────────────────────────
-- Precedence with cfg.brain = "auto":
--   $EVOLUA_MODEL → the model manager's saved choice → models/decision.gguf
--   (downloaded) → the strongest brain already on this machine that fits,
--   trying kinds in cfg.brain_order → the embedded model → rules.
-- cfg.brain = <kind> keeps only steps of that kind; "rules" loads nothing.
function Brain.select(cfg, models_dir, log, ram_total_mb)
  local want = cfg.brain or "auto"
  local function note(fmt, ...) if log then log:info("brain: " .. fmt, ...) end end
  if want == "rules" then note("rules only (--brain rules)"); return Brain.info() end
  local kinds = Brain.kinds()
  if not next(kinds) then note("this build has no brain backends — reasoning with rules"); return Brain.info() end

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
  if env and env ~= "" and try({ kind = "gguf", path = env }, "$EVOLUA_MODEL") then return Brain.info() end
  local saved = Brain.saved(models_dir)
  if saved and try(saved, "chosen by the model manager") then return Brain.info() end
  local dl = models_dir .. "/decision.gguf"
  local fh = io.open(dl, "r")
  if fh then
    fh:close()
    if try({ kind = "gguf", path = dl, name = "decision.gguf" }, "downloaded") then return Brain.info() end
  end
  local cands = Brain.candidates(cfg)
  for _, kind in ipairs(cfg.brain_order or { "apple", "service", "gguf" }) do
    for i = #cands, 1, -1 do                       -- strongest first, then weaker ones
      local c = cands[i]
      if c.kind == kind and Brain.fits(c, cfg, ram_total_mb)
         and try(c.spec, "found on this machine: " .. c.source) then
        return Brain.info()
      end
    end
  end
  if try({ kind = "embedded", params_b = 0.135 }, "embedded in the binary") then return Brain.info() end
  note("no brain available — reasoning with rules")
  return Brain.info()
end

return Brain
