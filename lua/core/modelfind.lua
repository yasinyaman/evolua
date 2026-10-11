-- core/modelfind.lua — find GGUF models that are ALREADY on the host
-- The binary ships no model. Before downloading anything, the organism looks
-- where models usually live: Ollama's blob store (parsing its manifests), LM
-- Studio, the Hugging Face hub cache, llama.cpp's cache, its own models dir,
-- and any extra dirs from config. Candidates are ranked by how capable they
-- look (size, "coder"/"instruct" in the name) among those that FIT the host's
-- usable RAM. Pure Lua + shell; best-effort everywhere, never throws.

local P = require("core.platform")

local M = {}

local function home_dir() return os.getenv("HOME") or os.getenv("USERPROFILE") or "." end
local function env(k) local v = os.getenv(k); if v and v ~= "" then return v end end

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end
  return false
end

local function read_all(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function size_mb(p)
  local out
  if P.os == "windows" then
    out = P.run(string.format('for %%I in ("%s") do @echo %%~zI', p))
  else
    out = P.run(string.format("wc -c < '%s' 2>/dev/null", p))
  end
  local b = tonumber((out or ""):match("%d+"))
  return b and b / 1048576 or nil
end

-- recursive *.gguf listing under a dir (bounded depth, >50MB so mmproj/vocab files drop)
local function find_gguf(dir, depth)
  local out = {}
  if not dir or dir == "" then return out end
  local raw
  if P.os == "windows" then
    raw = P.run(string.format('dir /s /b "%s\\*.gguf" 2>nul', dir))
  else
    raw = P.run(string.format("find '%s' -maxdepth %d -type f -name '*.gguf' -size +50M 2>/dev/null",
      dir, depth or 6))
  end
  for l in (raw or ""):gmatch("[^\r\n]+") do out[#out + 1] = l end
  return out
end

-- Ollama keeps models as content-addressed blobs; the manifest JSON names the
-- layer whose mediaType is application/vnd.ollama.image.model — that blob IS a
-- plain GGUF file llama.cpp can load directly.
local function ollama_models(root)
  local out = {}
  local mroot = root .. "/manifests"
  local files
  if P.os == "windows" then
    files = P.run(string.format('dir /s /b /a-d "%s" 2>nul', mroot))
  else
    files = P.run(string.format("find '%s' -maxdepth 6 -type f 2>/dev/null", mroot))
  end
  for mf in (files or ""):gmatch("[^\r\n]+") do
    local txt = read_all(mf)
    if txt then
      for obj in txt:gmatch("{[^{}]*}") do
        if obj:find("vnd%.ollama%.image%.model") then
          local hex = obj:match('"digest"%s*:%s*"sha256:(%x+)"')
          local bytes = tonumber(obj:match('"size"%s*:%s*(%d+)'))
          if hex then
            local blob = root .. "/blobs/sha256-" .. hex
            if exists(blob) then
              -- name = "<model>:<tag>" from the manifest path tail
              local model, tag = mf:match("([^/\\]+)[/\\]([^/\\]+)$")
              out[#out + 1] = {
                path = blob, size_mb = bytes and bytes / 1048576 or nil,
                name = (model or "ollama") .. ":" .. (tag or "latest"), source = "ollama",
              }
            end
          end
        end
      end
    end
  end
  return out
end

-- every place worth looking, per OS
local function roots(opts)
  local h = home_dir()
  local r = {}
  local function add(kind, dir) if dir and dir ~= "" then r[#r + 1] = { kind = kind, dir = dir } end end
  add("ollama", env("OLLAMA_MODELS") or (h .. "/.ollama/models"))
  add("gguf", h .. "/.cache/lm-studio/models")
  add("gguf", h .. "/.lmstudio/models")
  add("gguf", (env("HF_HOME") or (h .. "/.cache/huggingface")) .. "/hub")
  add("gguf", h .. "/.cache/llama.cpp")
  if P.os == "macos" then add("gguf", h .. "/Library/Caches/llama.cpp") end
  if P.os == "windows" then
    local la = env("LOCALAPPDATA")
    if la then add("gguf", la .. "\\llama.cpp") end
  end
  for _, d in ipairs(opts.dirs or {}) do add("gguf", d) end   -- own models dir, cwd/models, cfg.model_dirs
  return r
end

-- scan everything; returns a list of { path, size_mb, name, source }
function M.discover(opts)
  opts = opts or {}
  local seen, out = {}, {}
  local function push(c)
    if c.path and not seen[c.path] then
      seen[c.path] = true
      c.size_mb = c.size_mb or size_mb(c.path)
      c.name = c.name or c.path:match("([^/\\]+)%.gguf$") or c.path
      out[#out + 1] = c
    end
  end
  local explicit = env("EVOLUA_MODEL")
  if explicit and exists(explicit) then push({ path = explicit, source = "env" }) end
  for _, r in ipairs(roots(opts)) do
    if r.kind == "ollama" then
      for _, c in ipairs(ollama_models(r.dir)) do push(c) end
    else
      for _, p in ipairs(find_gguf(r.dir, 6)) do push({ path = p, source = r.dir }) end
    end
  end
  return out
end

-- does this candidate look usable as a decision/code brain on this host?
-- returns a score (higher = better) or nil (unusable / doesn't fit)
function M.score(c, usable_mb)
  local n = (c.name or ""):lower() .. " " .. (c.path or ""):lower()
  if n:find("mmproj") or n:find("embed") or n:find("whisper") or n:find("vision")
     or n:find("clip") or n:find("%-%d%d%d%d%d%-of%-%d%d%d%d%d") then return nil end
  local mb = c.size_mb or 0
  if mb < 50 then return nil end
  -- weights + KV cache + runtime overhead must fit the usable RAM budget
  if usable_mb and (mb * 1.25 + 256) > usable_mb then return nil end
  local s = math.log(mb)                                   -- bigger = more capable
  if n:find("coder") or n:find("code") then s = s + 1.5 end  -- we want it to WRITE organs
  if n:find("instruct") or n:find("chat") then s = s + 0.5 end
  if n:find("smol") or mb < 200 then s = s - 2 end           -- tiny models rarely emit valid code
  return s
end

-- pick the best-fitting candidate for the given RAM budget (nil if none fits)
function M.best(cands, usable_mb)
  local best, bs
  for _, c in ipairs(cands or {}) do
    local s = M.score(c, usable_mb)
    if s and (not bs or s > bs) then best, bs = c, s end
  end
  return best, bs
end

return M
