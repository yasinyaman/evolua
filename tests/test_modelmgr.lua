local MM = require("core.modelmgr")

local function caps(ram, cores, extra)
  local c = { ram_avail_mb = ram, cores = cores, disk_free_mb = 1e6, on_battery = false }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

return {
  ["a bottleneck on a roomy host climbs one tier"] = function(t)
    local d = MM.decide(caps(8000, 8), true, 1, { headroom = 0.7 })
    t.eq(d.action, "upgrade"); t.eq(d.from, 1); t.eq(d.to, 2)
  end,

  ["no bottleneck holds"] = function(t)
    t.eq(MM.decide(caps(8000, 8), false, 1).action, "hold")
  end,

  ["a bottleneck without spare capacity holds"] = function(t)
    local d = MM.decide(caps(500, 1), true, 1, { headroom = 0.7 })   -- 350 MB usable
    t.eq(d.action, "hold"); t.eq(d.reason, "no spare capacity")
  end,

  ["shrinking capacity downgrades to the feasible tier"] = function(t)
    local d = MM.decide(caps(1000, 1), false, 4, { headroom = 0.7 })  -- 700 MB usable → tier 2
    t.eq(d.action, "downgrade"); t.eq(d.to, 2)
  end,

  ["on battery it waits, unless told to ignore it"] = function(t)
    t.eq(MM.decide(caps(8000, 8, { on_battery = true }), true, 1).action, "hold")
    t.eq(MM.decide(caps(8000, 8, { on_battery = true }), true, 1, { ignore_battery = true }).action, "upgrade")
  end,

  ["not enough disk for the next model holds"] = function(t)
    local d = MM.decide(caps(8000, 8, { disk_free_mb = 100 }), true, 1)
    t.eq(d.action, "hold"); t.eq(d.reason, "insufficient disk for upgrade")
  end,

  ["the first downloadable tier is pinned"] = function(t)
    local tier = MM.ladder[2]
    t.ok(tier.url and tier.url:match("^https://"), "https url")
    t.ok(tier.sha and #tier.sha == 64 and not tier.sha:find("[^%x]"), "sha256 hex")
  end,
}
