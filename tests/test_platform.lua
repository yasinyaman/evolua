local P = require("core.platform")

local function with_os(name, out, f)
  local os0, run0 = P.os, P.run
  P.os, P.run = name, function() return out end
  local ok, err = pcall(f)
  P.os, P.run = os0, run0
  if not ok then error(err, 0) end
end

local function names(list)
  local n = {}
  for _, p in ipairs(list) do n[#n + 1] = p.name end
  return table.concat(n, "|")
end

local suite = {
  ["safe_path accepts ordinary paths, refuses metacharacters"] = function(t)
    t.ok(P.safe_path("/var/log/app.log"))
    t.ok(P.safe_path("/Users/me/My Documents/proje (eski)"), "spaces, parens, UTF-8")
    for _, bad in ipairs({ "", 'a"b', "it's", "$(id)", "x`id`", "a;b", "a|b", "a&b", "a\nb", "*.log" }) do
      t.ok(not P.safe_path(bad), "should refuse " .. bad)
    end
  end,

  ["proc_list keeps Linux kernel-thread names whole"] = function(t)
    with_os("linux", "    1  0.0  1234 systemd\n   12  0.0     0 ksoftirqd/1\n  900 12,5  5120 firefox\n  901  0.0     0 1\n",
      function()
        local list = P.proc_list()
        t.eq(names(list), "systemd|ksoftirqd/1|firefox", "no entity called 1")
        t.eq(list[3].cpu, 12.5, "decimal comma")
      end)
  end,

  ["proc_list strips the path on macOS"] = function(t)
    with_os("macos", "  300  3.1  9000 /Applications/Foo Bar.app/Contents/MacOS/Foo Helper (GPU)\n", function()
      t.eq(names(P.proc_list()), "Foo Helper (GPU)")
    end)
  end,

  ["proc_errors attributes lines to processes"] = function(t)
    local attribute = require("sensors.proc_errors")._attribute
    t.eq(attribute("Out of memory: Killed process 9001 (node) total-vm:1kB"), "node")
    t.eq(attribute("2026-10-09 12:00:00 host Chrome[1234]: crashed"), "Chrome")
    t.eq(attribute("Oct  9 12:00:00 host kernel: oops"), "kernel")
    t.eq(attribute("something unparseable"), "system")
  end,

  ["walk honors depth, kind, suffix and prune"] = function(t)
    local root = t.tmpdir()
    for _, d in ipairs({ "a", "a/b", "a/b/c", "target", "target/deep" }) do P.mkdir_p(root .. "/" .. d) end
    for _, f in ipairs({ "top.log", "a/x.log", "a/b/y.txt", "target/z.log" }) do
      local fh = io.open(root .. "/" .. f, "w"); fh:write("x"); fh:close()
    end
    local function rel(list)
      local out = {}
      for _, e in ipairs(list) do out[#out + 1] = e.path:sub(#root + 2) end
      table.sort(out); return table.concat(out, " ")
    end
    t.eq(rel(P.walk(root, { depth = 2, kind = "dir", prune = { "target" } })), "a a/b")
    t.eq(rel(P.walk(root, { depth = 3, kind = "file", suffix = ".log", prune = { "target" } })), "a/x.log top.log")
    t.eq(rel(P.walk(root, { depth = 1, kind = "file" })), "top.log")
    t.eq(#P.walk(root, { depth = 3, limit = 2 }), 2, "limit")
    local e = P.walk(root, { depth = 1, kind = "file" })[1]
    t.eq(e.size, 1); t.ok(e.mtime > 0, "mtime")
  end,

  ["list_dir and mkdir_p handle awkward names"] = function(t)
    local root = t.tmpdir()
    local odd = root .. "/it's \"odd\" $(x)"
    P.mkdir_p(odd .. "/sub")
    local fh = io.open(odd .. "/sub/f.txt", "w"); fh:write("x"); fh:close()
    t.eq(table.concat(P.list_dir(odd), ","), "sub")
    t.eq(table.concat(P.list_dir(odd .. "/sub"), ","), "f.txt")
  end,
}

-- shq must make any string ONE inert shell word: hand it to sh and read it back
if P.os ~= "windows" then
  suite["shq round-trips through the shell"] = function(t)
    for _, s in ipairs({ "plain", "sp ace", "it's", 'a"b', "$(id)", "`id`", "a\\b", "x'; echo pwned; '", "" }) do
      local p = io.popen("printf '%s' " .. P.shq(s))
      local out = p:read("*a"); p:close()
      t.eq(out, s)
    end
  end
end

return suite
