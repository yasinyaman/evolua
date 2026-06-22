-- config.lua — EvoLua defaults. Override via CLI flags (see main.lua) or by
-- editing here. The organism's "instincts" live in these numbers.
return {
  -- mode of life: "free" (react to whatever the environment offers) or
  -- "directed" (bias evolution toward a stated goal)
  mode = "free",
  goal = "",                 -- only used in directed mode, e.g. "report errors"

  -- where the organism keeps its body parts and memories.
  -- Relative paths are resolved against the directory of main.lua (see main.lua),
  -- so EvoLua works no matter which directory you launch it from.
  plugins_dir = "plugins",
  reports_dir = "reports",
  state_dir   = "state",

  -- perception targets (adapt to your machine)
  watch_dirs = { "sandbox" },          -- filesystem perception
  watch_logs = { "state/evolua.log" }, -- log perception (self-referential by default)
  sensors = {
    sys_metrics = true, logwatch = true, fswatch = true, introspect = true,
    proc_top = true, proc_errors = true,   -- Faz 1: per-process perception
    curiosity = true,                      -- Faz 3: active exploration
  },

  -- per-process perception (Faz 1)
  proc_cpu_threshold    = 50,    -- %CPU (per ps; can exceed 100 across cores) → proc.hot
  proc_mem_threshold_mb = 1500,  -- MB RSS → proc.hot
  -- never flag these (includes our own helpers across OSes)
  ignore_procs = {
    "evolua", "lua", "ps", "bash", "sh", "uname",
    "powershell", "conhost", "cmd", "WmiPrvSE", "msg",  -- Windows helpers
  },
  watch_procs  = nil,            -- nil = watch all; or a list to watch only those
  error_window_secs = 120,       -- how far back proc_errors scans OS logs
  worldmodel_decay  = 60,        -- ticks of no-contact before an entity is forgotten
  situational_every = 20,        -- write a rule-based situational report every N ticks

  -- sense-making (Faz 2) — decision brain + RAG
  reasoner_every          = 8,   -- run the reasoner every N ticks
  reasoner_salience_floor = 30,  -- ignore situations below this salience
  reasoner_grow_conf      = 0.5, -- min confidence to grow a routed organ
  rag_k                   = 3,   -- experience-bank exemplars injected into the prompt

  -- autonomy ladder (Faz 3) — how far the organism may act on its own
  -- NOTE: set to UNATTENDED ("act" + model_upgrade safe-listed) so the organism
  -- acquires its own decision model without approval. Revert ceiling to "report"
  -- and drop model_upgrade / model_unattended for the safe, approval-gated default.
  autonomy_ceiling = "act",      -- learn | report | notify | suggest | act
  safe_actions     = { "throttle", "notify", "model_downgrade", "model_upgrade" }, -- reversible verbs allowed at L4
  suggest_min_conf = 0.6,        -- min confidence to file an approval suggestion
  act_min_conf     = 0.85,       -- min confidence for autonomous (L4) action
  -- evolved-organ actions (rule-DSL "act"): routed through the SAME ladder as the
  -- reasoner but capped MORE conservatively — mutation-generated actuators are less
  -- trusted, so by default their actions go to the APPROVAL inbox, never autonomous.
  evolved_actions        = true,       -- allow rule organs to REQUEST actions at all
  evolved_action_ceiling = "suggest",  -- cap: "suggest"=approval-gated (safe) · "act"=autonomous (still safe-listed+reversible only)
  outcome_window         = 15,         -- ticks before judging an action's outcome (eligibility trace)
  outcome_min_drop       = 5,          -- min cpu_avg drop vs baseline that counts as a success
  outcome_max_reward     = 5,          -- cap on outcome credit per settled action
  curiosity        = 0.3,        -- 0 = passive · 1 = constantly explore the system

  -- model meta-evolution (Faz 4) — size the decision model to the host
  model_unattended    = true,    -- download a better brain WITHOUT approval (bounded to ladder url+sha)
  model_force_upgrade = false,   -- opt-in: always treat the brain as upgradeable (skip bottleneck test)
  model_ignore_battery= false,   -- opt-in: allow acquisition while on battery
  model_check_every   = 50,      -- reconsider the model every N ticks
  model_headroom      = 0.7,     -- only claim this fraction of available RAM
  model_min_samples   = 10,      -- reasoner samples before judging a bottleneck
  model_fallback_rate = 0.4,     -- rule-fallback rate above which the model is "too weak"

  -- colony: primitive self-replication + peer communication
  -- One seeded organ (templates.lua "colony") gives the organism a sense of
  -- siblings: it announces presence and trades messages with other instances
  -- through a shared filesystem dir, and — only when clone_enabled — spawns
  -- bounded, mortal OS-process clones of itself.
  colony               = true,   -- seed the colony organ (presence + messaging machinery)
  -- host-side autonomic watch ("brainstem"): the Rust supervisor thread observes
  -- liveness + vitals and writes them to state/vitals; the seeded Lua "supervisor"
  -- organ beats state/heartbeat and surfaces those vitals as a host.vitals stimulus
  -- so the evolvable layer can react. Advisory, never enforcing. (Watchdog knobs
  -- are host-side env vars: EVOLUA_WATCHDOG, *_SECS, *_STALL, *_KILL.)
  supervisor           = true,   -- seed the supervisor organ (no-op in plain-Lua mode: no host thread)
  -- environment exploration ("wandering the host"): the seeded "explorer" organ
  -- scouts the filesystem / logs / network / system (curiosity-gated) and EXPANDS
  -- the organism's own perception — it appends discovered dirs/logs to watch_dirs/
  -- watch_logs so fswatch/logwatch start perceiving them. New perception → new
  -- stimuli → organ growth → and (via S1–S4) new purposes. Macro complement to the
  -- per-process `curiosity` sensor. Gated by `curiosity` (0 = off).
  explorer          = true,   -- seed the explorer organ
  explore_expand    = true,   -- auto-add discovered dirs/logs to perception
  explore_max_watch = 12,     -- cap on auto-added watch targets (bound perception growth)
  explore_net       = true,   -- include network (listening ports) discovery
  explore_tools     = true,   -- include installed-command / tool discovery ($PATH scan)
  -- "what capabilities does this host offer?" — flagged when present during a PATH scan
  notable_tools = {
    "git", "docker", "podman", "kubectl", "python3", "python", "node", "deno", "lua",
    "cargo", "rustc", "gcc", "clang", "go", "ruby", "java", "make", "cmake",
    "curl", "wget", "ssh", "jq", "rg", "psql", "sqlite3", "redis-cli", "ffmpeg",
  },
  explore_roots     = nil,    -- where it may wander (set by main.lua: {EVOLUA_HOME, cwd})
  clone_enabled        = false,  -- OPT-IN: let the colony spawn REAL OS-process clones (--clone)
  clone_max_peers      = 3,      -- HARD cap on simultaneous live instances (NOT a gene)
  clone_max_generation = 1,      -- HARD cap on clone depth: root=0 may spawn, gen-1 may not
  clone_child_ticks    = 40,     -- children are mortal: each clone lives this many ticks then rests
  -- intelligent split: divide only under genuine load (like a cell dividing when
  -- nutrients are abundant) AND only if the host can host another worker. Mirrors
  -- the model ladder's "bottleneck + spare capacity" rule. --clone-eager bypasses.
  clone_require_pressure = true, -- false (or --clone-eager) = split whenever there's room
  clone_ignore_battery   = false,-- if true, may spawn clones while on battery
  clone_min_ram_mb       = 200,  -- need at least this much AVAILABLE RAM to host a child (a Lua
                                 -- child is tiny; keep low — macOS reports "available" RAM very
                                 -- conservatively, see hostcaps.lua, so a high bar blocks everything)
  clone_need_events      = 1,    -- >= this many starved event types (unhandled_streak >= need_threshold) = demand
  clone_hot_entities     = 1,    -- >= this many hot/erroring processes in the world model = demand
  clone_fallback_rate    = nil,  -- reasoner rule-fallback rate that counts as a brain bottleneck (nil → model_fallback_rate)
  -- goal acquisition: a clone is NOT a generic copy — it is born specialized to a
  -- goal CRYSTALLIZED from what the parent is actually experiencing. The split's
  -- dominant pressure becomes the child's purpose, so an aimless free-mode node
  -- differentiates its offspring into purpose-directed lineages over time.
  purpose_enabled = true,        -- false (or --clone-generalist) = old generic clones
  purpose_mode    = "portfolio", -- explore (fill gaps) | exploit (deepen niches) | portfolio (alternate)
  -- explore: the most chronically UNHANDLED stimulus → this goal (fills gaps).
  -- Goals are DISTINCTIVE on purpose: they avoid words shared across templates
  -- (e.g. "monitor"/"watch") so the directed drive grows ONLY the intended organ.
  purpose_map = {
    ["log.error"]  = "report errors",
    ["self.error"] = "report errors",
    ["fs.change"]  = "file changes",
    ["metric.cpu"] = "cpu resource",
    ["metric.mem"] = "memory resource",
    ["metric.load"]= "system load",
    ["proc.hot"]   = "cpu resource",
  },
  -- exploit: the highest-FITNESS organ's template → this goal (deepens what pays)
  template_goal = {
    error_reporter = "report errors",
    fs_journal     = "file changes",
    cpu_guard      = "cpu resource",
    mem_guard      = "memory resource",
    load_guard     = "system load",
  },
  -- S4 — selection AMONG purposes: each purpose-directed child harvests how well
  -- its goal paid off (fitness of its goal's organs) into colony/outcomes/; the
  -- root then biases crystallization toward goals that historically earned the most
  -- (a bandit). Untried goals get an optimistic prior (tried at least once); an
  -- epsilon probe keeps adapting. So the colony evolutionarily keeps valuable purposes.
  purpose_learn         = true,  -- false (or --no-purpose-learn) = S1–S3 portfolio only
  purpose_prior         = 1e6,   -- optimistic payoff for untried goals (→ try each once)
  purpose_explore_every = 4,     -- every Nth split, probe the current gap regardless of payoff
  -- horizontal gene transfer (#12): peers swap high-fitness genomes via colony/genepool/
  hgt              = true,   -- publish my best genome + adopt clearly-better peer genomes
  hgt_min_fitness  = 3,      -- don't publish a genome below this fitness
  hgt_margin       = 2,      -- only adopt a peer genome this much fitter than my local best
  hgt_every        = 6,      -- adopt at most once every N link cycles
  -- the next three are set at runtime by main.lua (bridged from globals → cfg so
  -- the sandboxed organ can read them); listed here for documentation only.
  colony_id            = nil,    -- this instance's colony id (root auto-generates; children get --colony-id)
  generation           = 0,      -- this instance's clone depth
  colony_root          = nil,    -- shared colony dir root (defaults to EVOLUA_HOME)

  -- life rhythm
  tick_seconds = 1,          -- wall-clock seconds per tick
  evolve_every = 3,          -- run the evolver every N ticks
  save_every   = 10,
  max_ticks    = nil,        -- nil = live indefinitely; set a number for a bounded run

  -- evolutionary pressure
  need_threshold = 6,        -- unhandled stimulus streak that signals an unmet need
  mutate_chance  = 0.25,     -- chance per step to breed a variant of the fittest organ
  es_sigma0      = 0.2,      -- ES: initial per-gene mutation step size (self-adapted thereafter)
  es_tau         = 0.3,      -- ES: learning rate of the step size (log-normal sigma mutation)
  max_per_template = 3,      -- carrying capacity: max living variants of one species
  grace_ticks    = 25,       -- newborn protection before it can be culled
  tournament_k   = 3,        -- breeding: k-tournament parent-selection sample size (1 = pure elitism)
  cull_rate      = 0.5,      -- death: scales the probabilistic cull (0 = never die, 1 = aggressive)
  crossover_chance = 0.15,   -- breeding: chance per step to recombine two parents (templates that support it)
  mapelites_chance = 0.3,    -- breeding: chance per step to illuminate a random behavior cell (QD)
  bandit_chance    = 0.15,   -- breeding: chance per step to invest in the highest-UCB template (#13)
  bandit_c         = 1.5,    -- bandit exploration constant (higher = try under-sampled templates more)
  rule_seed        = true,   -- seed one evolvable rule-DSL organ (open-ended GP population)
  rule_max_rules   = 4,      -- bound a rule organ's genome size
  retire_floor   = 0.5,      -- fitness floor: below 2× this, death probability rises toward 1
  decay_rate     = 0.03,     -- per-step fitness entropy
  error_penalty  = 1,

  -- honest fitness — reward is DERIVED from observable bus facts, not from the
  -- number an organ declares about itself (see core/bus.lua). Breaks reward-
  -- hacking (e.g. the colony minting reward=4 each heartbeat) and the frequency
  -- bias of constant per-fire reward.
  reward_base        = 1,    -- base credit for handling a stimulus
  reward_gap_cap     = 8,    -- max surprise multiplier (how starved the stimulus was)
  reward_cost_weight = 0.5,  -- penalty per CPU-second the reactor burns (parsimony; 0 = off)
  fitness_share      = true, -- split a stimulus's credit across its co-handlers (anti-redundancy)
  metrics_log        = true, -- append per-generation evolution metrics to state/evolution.log
  max_emit_depth     = 8,    -- bus re-entrancy cap: breaks runaway emit loops (e.g. chained rule organs)

  -- reporting
  report_flush = 12,         -- observations buffered before a report is written

  -- logging
  log_level = "info",        -- debug | info | warn | error
}
