local Log = require("core.log")

local function size(path)
  local fh = io.open(path, "r"); if not fh then return nil end
  local n = fh:seek("end"); fh:close(); return n
end

return {
  ["append rotates past max_bytes and keeps one generation"] = function(t)
    local path = t.tmpdir() .. "/x.log"
    for i = 1, 100 do Log.append(path, string.format("line %03d\n", i), 200) end
    t.ok(size(path) <= 200, "current file bounded: " .. tostring(size(path)))
    t.ok(size(path .. ".1") ~= nil, "rotated generation exists")
    t.eq(size(path .. ".2"), nil, "only one generation")
    local fh = io.open(path); local last = fh:read("a"); fh:close()
    t.ok(last:find("line 100", 1, true), "newest line in the current file")
  end,

  ["a header starts every fresh file"] = function(t)
    local path = t.tmpdir() .. "/m.tsv"
    for i = 1, 30 do Log.append(path, i .. "\n", 40, "tick\n") end
    local fh = io.open(path); local first = fh:read("l"); fh:close()
    t.eq(first, "tick")
  end,
}
