local RAG = require("core.rag")

return {
  ["search ranks the relevant document first"] = function(t)
    local r = RAG.new()
    r:add("a", "cpu_guard metric.cpu cpu resource", 1)
    r:add("b", "fs_journal fs.change file folder journal", 1)
    r:add("c", "error_reporter log.error error report", 1)
    local hits = r:search("node error crash", 3)
    t.eq(hits[1].id, "c")
    t.eq(#hits, 1, "documents with no shared term are not returned")
  end,

  ["fitness breaks a relevance tie"] = function(t)
    local r = RAG.new()
    r:add("weak", "cpu guard", 0)
    r:add("strong", "cpu guard", 50)
    t.eq(r:search("cpu", 1)[1].id, "strong")
  end,

  ["re-adding an id replaces it; remove forgets it"] = function(t)
    local r = RAG.new()
    r:add("x", "alpha beta", 1)
    r:add("x", "gamma delta", 1)
    t.eq(r:size(), 1)
    t.eq(#r:search("alpha", 3), 0); t.eq(r:search("gamma", 3)[1].id, "x")
    r:remove("x")
    t.eq(r:size(), 0); t.eq(#r:search("gamma", 3), 0)
  end,

  ["document frequencies stay consistent after removals"] = function(t)
    local r = RAG.new()
    for i = 1, 20 do r:add("d" .. i, "shared token" .. i, 1) end
    for i = 1, 20, 2 do r:remove("d" .. i) end
    t.eq(r:size(), 10)
    t.eq(r.df["shared"], 10)
  end,
}
