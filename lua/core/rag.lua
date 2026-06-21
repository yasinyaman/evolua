-- core/rag.lua — fitness-weighted experience bank (BM25 retrieval)
-- Dependency-free BM25 over a growing corpus of: template patterns, the
-- organism's OWN high-fitness organs, and past situation→interpretation pairs.
-- Retrieval is weighted by fitness, so what WORKED before surfaces first — the
-- core of self-improvement without retraining (see docs/ROADMAP.md §1).

local RAG = {}
RAG.__index = RAG

local K1, B = 1.5, 0.75

local STOP = {
  the=true, a=true, an=true, and_=true, ["and"]=true, ["or"]=true, of=true,
  to=true, in_=true, ["in"]=true, is=true, are=true, for_=true, ["for"]=true,
  with=true, on=true, at=true, by=true, it=true, this=true, that=true,
}

local function tokenize(text)
  local toks = {}
  for w in tostring(text):lower():gmatch("[%a_][%a%d_%.%-]+") do
    if #w >= 2 and not STOP[w] then toks[#toks + 1] = w end
  end
  return toks
end

function RAG.new()
  return setmetatable({
    docs = {},        -- { id, tokens, len, weight, meta, text }
    df = {},          -- term -> #docs containing it
    by_id = {},       -- id -> doc index
    total_len = 0,
  }, RAG)
end

-- add or replace a document. weight ≈ fitness (higher → retrieved sooner).
function RAG:add(id, text, weight, meta)
  if self.by_id[id] then self:remove(id) end
  local tokens = tokenize(text)
  local seen = {}
  for _, t in ipairs(tokens) do
    if not seen[t] then seen[t] = true; self.df[t] = (self.df[t] or 0) + 1 end
  end
  local doc = { id = id, tokens = tokens, len = #tokens, weight = weight or 1, meta = meta or {}, text = text }
  self.docs[#self.docs + 1] = doc
  self.by_id[id] = #self.docs
  self.total_len = self.total_len + doc.len
end

function RAG:remove(id)
  local idx = self.by_id[id]
  if not idx then return end
  local doc = self.docs[idx]
  local seen = {}
  for _, t in ipairs(doc.tokens) do
    if not seen[t] then seen[t] = true; self.df[t] = (self.df[t] or 1) - 1 end
  end
  self.total_len = self.total_len - doc.len
  -- swap-remove
  local last = #self.docs
  self.docs[idx] = self.docs[last]
  self.by_id[self.docs[idx].id] = idx
  self.docs[last] = nil
  self.by_id[id] = nil
end

function RAG:bump_weight(id, w)
  local idx = self.by_id[id]
  if idx then self.docs[idx].weight = w end
end

-- BM25 score of one doc for a query token bag (term -> count)
function RAG:_bm25(doc, qbag, N, avgdl)
  local score = 0
  -- term frequencies in doc
  local tf = {}
  for _, t in ipairs(doc.tokens) do tf[t] = (tf[t] or 0) + 1 end
  for term in pairs(qbag) do
    local f = tf[term]
    if f then
      local df = self.df[term] or 1
      local idf = math.log(1 + (N - df + 0.5) / (df + 0.5))
      local denom = f + K1 * (1 - B + B * (doc.len / (avgdl > 0 and avgdl or 1)))
      score = score + idf * (f * (K1 + 1)) / denom
    end
  end
  return score
end

-- retrieve up to k docs most relevant to `query`, fitness-weighted.
function RAG:search(query, k)
  k = k or 3
  local N = #self.docs
  if N == 0 then return {} end
  local avgdl = self.total_len / N
  local qbag = {}
  for _, t in ipairs(tokenize(query)) do qbag[t] = (qbag[t] or 0) + 1 end

  local scored = {}
  for _, doc in ipairs(self.docs) do
    local s = self:_bm25(doc, qbag, N, avgdl)
    if s > 0 then
      -- fold in fitness: a higher-fitness exemplar of equal relevance wins
      local fitw = 1 + math.log(1 + math.max(0, doc.weight))
      scored[#scored + 1] = { doc = doc, score = s * fitw }
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)

  local out = {}
  for i = 1, math.min(k, #scored) do out[i] = scored[i].doc end
  return out
end

function RAG:size() return #self.docs end

return RAG
