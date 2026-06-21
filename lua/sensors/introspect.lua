-- sensors/introspect.lua — the organism perceiving ITSELF
-- Emits self.heartbeat with internal vitals so the evolver can react to its
-- own fitness landscape (meta-perception drives evolution of evolution).

return {
  name = "introspect",
  desc = "perceives the organism's own state; emits self.heartbeat",
  events = { "self.heartbeat" },

  sense = function(self, ctx)
    local organs = ctx.registry:list()
    local fitness = ctx.memory.data.fitness
    local best, best_score, worst, worst_score
    for name, score in pairs(fitness) do
      if not best_score or score > best_score then best, best_score = name, score end
      if not worst_score or score < worst_score then worst, worst_score = name, score end
    end
    ctx.bus:emit("self.heartbeat", {
      tick = ctx.kernel.tick,
      organs = #organs,
      generation = ctx.memory.data.generation,
      best = best, best_score = best_score,
      worst = worst, worst_score = worst_score,
    })
  end,
}
