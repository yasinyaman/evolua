-- core/evo_util.lua — shared evolutionary-operator helpers.
-- The ES self-adaptation kernel lives here ONCE, used by both the evolver (generic
-- numeric genes) and templates.lua (rule-organ thresholds) — so the two mutation
-- paths can't drift apart. Pure functions; depends on nothing (no require cycle).

local M = {}

-- Box–Muller standard normal (stock Lua has no gaussian)
function M.gauss()
  local u1 = math.random(); if u1 < 1e-12 then u1 = 1e-12 end
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * math.random())
end

-- one self-adaptive (ES) step on a positive-integer gene. Mutates the per-gene
-- step size (sigma) log-normally, then perturbs the gene log-normally by it,
-- bounding a single step to [0.25x, 4x] so one mutation can't explode a gene.
-- Returns new_value, new_sigma (carry the sigma to the child to inherit the step).
function M.es_step(value, sigma, cfg)
  local tau = (cfg and cfg.es_tau) or 0.3
  local s = (sigma or (cfg and cfg.es_sigma0) or 0.2) * math.exp(tau * M.gauss())
  s = math.max(0.01, math.min(2, s))                       -- clamp the learned step
  local factor = math.max(0.25, math.min(4, math.exp(s * M.gauss())))
  return math.max(1, math.floor(value * factor + 0.5)), s
end

return M
