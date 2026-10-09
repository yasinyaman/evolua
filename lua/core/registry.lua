-- core/registry.lua — plugin loader + sandbox + lifecycle
-- Plugins are standalone .lua files (the organism's "organs"). They are loaded
-- into a restricted environment, registered on the bus, and can be hot-reloaded
-- or retired at runtime. Core code never changes — new capability = new file.

local Registry = {}
Registry.__index = Registry

-- A plugin file returns a table:
--   { name=..., desc=..., events={...}, attach=function(ctx) ... end }
-- attach(ctx) wires up subscriptions; ctx exposes bus, memory, log, emit, cfg.

function Registry.new(ctx)
  return setmetatable({
    ctx = ctx,            -- shared organism context
    loaded = {},          -- name -> { spec=, path=, alive= }
    dir = ctx.cfg.plugins_dir,
  }, Registry)
end

-- build the sandbox env a plugin executes in. Intentionally permissive
-- (CI/agent scenario) but isolated enough that a plugin can't trivially
-- clobber the registry's own globals.
local function sandbox_env(ctx)
  local env = {
    print = print, pairs = pairs, ipairs = ipairs, type = type,
    tostring = tostring, tonumber = tonumber, pcall = pcall, error = error,
    select = select, next = next, setmetatable = setmetatable,
    string = string, table = table, math = math, os = os, io = io,
    -- organism API surface available to plugins:
    ctx = ctx,
  }
  env._G = env
  return env
end

function Registry:_load_file(path, name)
  local fh = io.open(path, "r")
  if not fh then return nil, "cannot open " .. path end
  local src = fh:read("*a"); fh:close()
  local env = sandbox_env(self.ctx)
  local chunk, err = load(src, "@" .. (name or path), "t", env)
  if not chunk then return nil, err end
  local ok, spec = pcall(chunk)
  if not ok then return nil, spec end
  if type(spec) ~= "table" or not spec.name then
    return nil, "plugin did not return a spec table with a name"
  end
  return spec
end

-- load (or reload) a plugin by file path
function Registry:load(path)
  local name = path:match("([^/\\]+)%.lua$") or path
  -- if already alive, detach first (hot-reload)
  if self.loaded[name] and self.loaded[name].alive then
    self:retire(name, "reload")
  end
  local spec, err = self:_load_file(path, name)
  if not spec then
    self.ctx.log:error("load failed for %s: %s", name, tostring(err))
    self.ctx.bus:emit_raw("self.error", { owner = name, on = "load", err = tostring(err) })
    return false
  end
  spec.name = spec.name or name
  -- wire it up
  local okA, aerr = pcall(spec.attach, self.ctx)
  if not okA then
    self.ctx.log:error("attach failed for %s: %s", spec.name, tostring(aerr))
    return false
  end
  self.loaded[spec.name] = { spec = spec, path = path, alive = true }
  self.ctx.log:info("loaded organ '%s' — %s", spec.name, spec.desc or "")
  self.ctx.bus:emit_raw("self.loaded", { name = spec.name, events = spec.events })
  return true
end

-- an organ grown from a template disabled for this life (gen_<template>_<n>.lua)
-- stays on disk but is not loaded, so --no-colony etc. hold across lives too.
local function disabled(cfg, fname)
  local tpl = fname:match("^gen_(.+)_%d+%.lua$")
  return tpl ~= nil and cfg.disabled_templates ~= nil and cfg.disabled_templates[tpl] == true
end

-- scan the plugins dir and load anything new
function Registry:scan()
  local dir = self.dir
  local p = io.popen and io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
  if not p then return end
  for line in p:lines() do
    local fname = line:match("(.+%.lua)$")
    if fname and not disabled(self.ctx.cfg, fname) then
      local name = fname:gsub("%.lua$", "")
      if not (self.loaded[name] and self.loaded[name].alive) then
        self:load(dir .. "/" .. fname)
      end
    end
  end
  p:close()
end

-- retire a plugin: detach its subscriptions; optionally delete its file
function Registry:retire(name, reason, delete_file)
  local rec = self.loaded[name]
  if not rec then return false end
  self.ctx.bus:unsubscribe_owner(name)
  rec.alive = false
  if rec.spec.detach then pcall(rec.spec.detach, self.ctx) end
  self.ctx.log:warn("retired organ '%s' (%s)", name, reason or "")
  if delete_file and rec.path then os.remove(rec.path) end
  self.ctx.bus:emit_raw("self.retired", { name = name, reason = reason })
  return true
end

function Registry:list()
  local out = {}
  for name, rec in pairs(self.loaded) do
    if rec.alive then out[#out + 1] = { name = name, desc = rec.spec.desc, path = rec.path } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return Registry
