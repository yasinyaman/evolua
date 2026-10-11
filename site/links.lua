-- pandoc Lua filter: point the repo's Markdown cross-links at the rendered pages.
--   README.md → readme.html · README.tr.md → readme.tr.html · docs/X.md → docs/X.html
-- The page's own location is passed as metadata `root` ("." for top-level pages,
-- ".." for pages under docs/) so links resolve from either place.
local root = "."

function Meta(m)
  if m.root then root = pandoc.utils.stringify(m.root) end
  return m
end

local function rewrite(target)
  if target:match("^%a+://") or target:match("^#") or target:match("^mailto:") then return target end
  local path, frag = target:match("^([^#]*)(#?.*)$")
  if not path:match("%.md$") then return target end
  -- normalise: strip a leading ./ and any ../ (docs pages link to ../README.md)
  path = path:gsub("^%./", ""):gsub("^%.%./", "")
  local out
  if path == "CLAUDE.md" then return "https://github.com/yasinyaman/evolua/blob/main/CLAUDE.md" .. frag end
  if path == "README.md" then out = root .. "/readme.html"
  elseif path == "README.tr.md" then out = root .. "/readme.tr.html"
  elseif path:match("^docs/") then out = root .. "/" .. path:gsub("%.md$", ".html")
  else out = path:gsub("%.md$", ".html") end           -- a sibling doc, same directory
  return out .. frag
end

function Link(el)
  el.target = rewrite(el.target)
  return el
end

-- images referenced from the repo root (docs/assets/x.png) live at assets/x.png on the site
function Image(el)
  local src = el.src
  if not src:match("^%a+://") then
    src = src:gsub("^%./", ""):gsub("^%.%./", "")
    src = src:gsub("^docs/assets/", root .. "/assets/"):gsub("^assets/", root .. "/assets/")
    el.src = src
  end
  return el
end
