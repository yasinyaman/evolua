-- sensors/curiosity.lua — active exploration ("wandering to make sense")
-- Instead of only reacting to thresholds, with probability = cfg.curiosity the
-- organism PROBES the entity it knows least about (information gain first):
-- it fetches that process's command line / image path and enriches its dossier.
-- curiosity = 0 → purely reactive; curiosity = 1 → constantly exploring.

local P = require("core.platform")

return {
  name = "curiosity",
  desc = "actively profiles the least-known process (curiosity-driven)",
  events = { "proc.detail" },

  sense = function(self, ctx)
    local c = ctx.cfg.curiosity or 0
    if c <= 0 then return end
    if math.random() > c then return end

    -- pick the most salient entity we haven't profiled yet
    local target
    for _, e in ipairs(ctx.worldmodel:snapshot(10)) do
      if e.pid and not e.profile then target = e; break end
    end
    if not target then return end

    local detail = P.proc_detail(target.pid)
    if detail and detail ~= "" then
      ctx.bus:emit("proc.detail", { name = target.name, pid = target.pid, detail = detail })
      ctx.log:debug("curiosity profiled %s: %s", target.name, detail:sub(1, 60))
    end
  end,
}
