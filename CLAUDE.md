# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

EvoLua is a self-evolving Lua "organism": it perceives its host environment (per-process
CPU/RAM, OS error logs, filesystem), builds an entity-based world model, makes sense of the
situation (optional embedded LLM + BM25 RAG, with rule-based fallback), and acts within an
autonomy ladder — growing its own plugins ("organs") under selection pressure and reporting
back. It ships as a single self-contained binary.

**The core insight that shapes everything: the Rust host never changes, and `lua/core/`
is an immutable contract.** New capability is *always* a new `.lua` file — never an edit to
core. The organism writes those files itself at runtime from genome blueprints. When adding
features, prefer a new template/plugin over modifying the kernel.

Docs are in English (`README.md`, `docs/`, `CLAUDE.md`); `README.tr.md` is a Turkish mirror of
the README. Source code is English too, except the `goal_keywords` lists in `templates.lua`,
which are intentionally **bilingual TR/EN** (e.g. "hata"/"error" → `error_reporter`): the English
synonyms feed the reasoner's RAG, the Turkish ones keep Turkish `--goal` directives working —
don't translate the Turkish away. Keep README.md and README.tr.md in sync when you change either.

## This directory IS the standalone crate

`evolua/` is its own detached Cargo workspace (note the empty `[workspace]` table in
`Cargo.toml`) — it does not join or affect any parent workspace. Build it from here directly.

**Source vs. runtime artifacts** — the only source is `src/` (Rust host) and `lua/` (the
organism). These directories are runtime output the organism regenerates and are gitignored;
do **not** treat them as source or hand-edit them:
- `plugins/`, `reports/`, `state/`, `sandbox/` at the repo root
- a stray nested `evolua/` directory (created if launched from inside its own folder)

This working copy is **not currently a git repository** (`git init` if you need one).

## Build & run

```bash
cargo build --release                                   # Phase 1 + rule-based (NO LLM)
cargo build --release --features embed_smol             # + embedded decision brain (Phase 2/3)
cargo build --release --features 'embed_smol acquire'   # + runtime model upgrade (Phase 4)
cargo build --release --features 'embed_smol gpu-metal' # macOS GPU backend

./target/release/evolua --ticks 60 --tick-seconds 0.2   # bounded fast demo
./target/release/evolua --goal "report errors"          # directed mode (also accepts Turkish)
./target/release/evolua                                 # lives indefinitely
./target/release/evolua --help                          # all flags
```

**Build prerequisite for LLM features:** `embed_smol` does `include_bytes!("../models/smol.gguf")`
at compile time. That file is **not in the repo** — `models/smol.gguf` must exist or the build
fails. Plain `cargo build --release` has no such dependency. At runtime the model resolves as:
`$EVOLUA_MODEL` → `<home>/models/decision.gguf` → embedded. If none resolve, the reasoner
gracefully falls back to rules.

**LLM decision quality:** the embedded SmolLM2-135M is marginal — it often can't emit the
reasoner's strict schema and falls back to rules (watch `llm_ok` vs `llm_fallback` in
`state/memory.lua`). A 0.5B-class model (e.g. Qwen2.5-0.5B-Instruct GGUF) produces usable
`source="llm+rule"` decisions; point `$EVOLUA_MODEL` at it to override the embedded brain. The
reasoner prompt (`reasoner.lua` `SCHEMA`) carries a worked example — without it even Qwen echoes
the option menus instead of choosing, so keep the example if you touch the prompt.

Cargo features map directly to the four phases: `default` (none) = perception + world model +
rule reasoning + evolution; `llm` = decision-brain infra; `embed_smol` = bakes in SmolLM2-135M
(implies `llm`); `acquire` = download/checksum a bigger model; `gpu-{metal,cuda,vulkan}` = GPU
backend (build-time, one per binary). Phase 5 (colony / supervisor / explorer / goal acquisition)
is **not** feature-gated — it's pure Lua plus the always-compiled host supervisor.

### Run without building (plain Lua)

A stock `lua` (5.3+) interpreter runs the organism directly — the host is optional:

```bash
lua lua/main.lua --ticks 60 --tick-seconds 0.2
lua lua/main.lua --goal "watch filesystem changes"
```

In plain-Lua mode the data home defaults to next to the script (so artifacts land under
`lua/`); the binary uses an OS-appropriate dir. **Caveat:** `main.lua` reads `EVOLUA_HOME`
as a Lua *global* (`rawget(_G, ...)`), not an env var — so `EVOLUA_HOME=/path lua lua/main.lua`
is silently ignored. To redirect a plain-Lua run, inject it as a global:
`lua -e "EVOLUA_HOME='/path'" lua/main.lua`. The env var works only in binary mode (the host
sets the global) and for `clean.sh`.

### Tests & reset

There is **no automated test suite** — verification is done with bounded runs
(`--ticks N --tick-seconds 0.2`) and inspecting `reports/` and `state/evolua.log`.
`./clean.sh` wipes all evolved organs/reports/memory so the next run starts from a
never-lived state (use `EVOLUA_HOME=/path ./clean.sh` for a custom home).

## Architecture

### Host ↔ organism boundary

`src/main.rs` is a thin shell: it embeds the entire `lua/` tree via `rust-embed`, registers
each module into `package.preload` (so the organism's `require("core.kernel")` resolves from
memory — no files on disk), resolves a writable data home, and injects globals
`EVOLUA_HOME`, `arg`, and — when feature-gated — `llm_complete(system,user,max)` (`src/llm.rs`)
and `model_acquire(url,dest,sha)` (`src/acquire.rs`). If the LLM feature is off or no model
resolves, those globals are simply absent and the Lua side detects that and uses rules.

### Host-side autonomic watch — the "brainstem" (`src/supervisor.rs`)

The one deliberate exception to "all behavior lives in Lua": a background thread the
host spawns before running the organism (`supervisor::spawn`). Because mlua runs the
organism in-process on the main thread (and blocks there), this watch lives on its own
thread and talks to the organism the only way it can across that boundary — through the
filesystem. It is **supervision, not control**: it observes liveness (the `state/heartbeat`
the Lua `supervisor` organ beats each tick; falls back to the log's mtime) and writes
coarse vitals (`stall`, `self_rss_mb`, `colony_procs`) to `state/vitals`. The Lua
`supervisor` organ reads those back and emits a `host.vitals` stimulus so the *evolvable*
layer decides what to do — the host never caps, kills, or steers evolution. The single
hard reflex (process exit on a prolonged stall) is **opt-in and off by default**
(`EVOLUA_WATCHDOG_KILL=1`). Tunable via env: `EVOLUA_WATCHDOG` (0=off), `_SECS` (interval),
`_STALL`, `_KILL`, `_KILL_SECS`. In plain-Lua mode there's no host thread, so `state/vitals`
never appears and the organ just beats the heartbeat harmlessly. This is the rare place a
change touches `src/` — justified because it sits *below* evolution as a safety/observation
floor, not within it.

### The tick loop (`lua/core/kernel.lua`)

`Kernel:run()` drives everything. Each tick, on independent cadences: (1) **perceive** — every
sensor's `sense(ctx)`; (2) **evolve** (`evolve_every`); (3) **persist/housekeep** (`save_every`);
(4) **reason** (`reasoner_every`); (5) poll the approval inbox + meta-evolution
(`model_check_every`); (6) situational report (`situational_every`). All subsystems share one
`ctx` table (`bus`, `memory`, `registry`, `evolver`, `worldmodel`, `reasoner`, `autonomy`,
`modelmgr`, `log`, `report`).

### Event bus = nervous system (`lua/core/bus.lua`)

Sensors `emit` stimuli; plugins `subscribe` and react. A reactor returns `true` or
`{handled=true, reward=N}` to claim a stimulus — that emits `self.reward`; a throwing reactor
emits `self.error`. The kernel turns reward/error into fitness deltas (the selective force).
The bus tracks per-event-type `unhandled_streak`, which is exactly the signal the evolver reads
to detect an *unmet need*.

### Evolution (`lua/core/evolver.lua` + `lua/core/templates.lua`)

`templates.lua` holds **genome blueprints**: each template declares which stimulus it
`triggers` on, its tunable `genes`, `goal_keywords` for directed mode, and a `build(name,genes)`
that *renders the organ's source code as a string*. The evolver's `step()`:
1. **directed drive** — grow organs whose `goal_keywords` match the goal;
2. **free drive** — when an event's `unhandled_streak ≥ need_threshold`, `spawn()` a template
   that triggers on it (writes a `gen_*.lua` file and loads it);
3. **selection** — rank living organs by fitness; `mutate()` the fittest (clone with perturbed
   numeric genes, bounded by `max_per_template` carrying capacity); retire the worst once past
   `grace_ticks` if below `retire_floor`;
4. **entropy** — decay idle fitness so selection stays honest.

### Plugins / organs (`lua/core/registry.lua`)

A plugin is a standalone `.lua` file returning `{name, desc, events, attach(ctx), detach?}`.
The registry loads it into a deliberately **permissive sandbox** (`os`/`io` open — CI/agent
philosophy) that's isolated enough not to clobber core globals, wires its subscriptions via
`attach`, and supports hot-reload and retirement. `scan()` also picks up organs dropped into
`plugins/` by hand. Two ways to add capability, neither touches core: drop a `.lua` in
`plugins/`, or add a blueprint to `templates.lua` and let the organism grow it.

### Cognition & action layers

- `lua/core/worldmodel.lua` — entity (per-process) dossiers: CPU EMA, errors, "temperature",
  trend, salience; decays entities after `worldmodel_decay` ticks of no contact.
- `lua/core/reasoner.lua` — whole-system snapshot → strict decision schema via `llm_complete`,
  with strict parsing and rule fallback on any garbage/missing field. `lua/core/rag.lua` is a
  fitness-weighted BM25 experience bank feeding exemplars into the prompt.
- `lua/core/autonomy.lua` — the **L0–L4 ladder**: learn → report → notify → suggest → act.
  `autonomy_ceiling` hard-caps it. ⚠️ **This working copy is configured UNATTENDED**
  (`autonomy_ceiling = "act"`, `model_unattended = true`, `model_upgrade` safe-listed in
  `config.lua`) — diverging from the README's safe `report` default — so the organism *acts*
  on its own, including **downloading a better decision model without approval**. Set
  `autonomy_ceiling = "report"` for the safe default. Destructive actions (kill) *always*
  require approval; reversible safe-listed verbs (throttle, model_downgrade, model_upgrade)
  can act at L4 above `act_min_conf`. Approval is a file dance:
  `approvals/pending-<id>.md` → move to `approved/` to apply (archived to `done/`), delete to
  reject. Every decision/action is appended to `state/audit.log`.
- `lua/core/modelmgr.lua` + `lua/core/hostcaps.lua` — meta-evolution: probe RAM/cores/disk/power,
  and climb a model ladder when the brain is a bottleneck (high reasoner fallback) and the host
  has capacity (Phase 4). **Acquisition is fully wired**: ladder tier 2 carries a *pinned*
  `url`+`sha256`, and `model_acquire` downloads it — verified end-to-end in both **unattended**
  (L4 acts directly) and **approval-gated** (L3 → approval inbox → `poll_approvals` enacts) modes.
  The organism chooses *when* to fetch, never *what* (the pinned url+sha bound it to a vetted file).
  Opt-in `model_force_upgrade` / `model_ignore_battery` override the bottleneck/power guards (off
  by default). Note: macOS available-RAM is `free + inactive + speculative + purgeable` pages
  (`hostcaps.lua`) — "Pages free" alone reads near-zero and would block every upgrade.
- `lua/core/platform.lua` — the OS abstraction (macOS/Linux/Windows) for process listing, error
  logs, and actuator actions. Anything OS-specific belongs here, behind its interface.

### Environment exploration — the `explorer` organ

A seeded organ (`templates.lua` `"explorer"`) is the macro complement to the per-process
`curiosity` sensor: gated by `cfg.curiosity`, it wanders the host (filesystem dirs, `*.log`
files, listening ports via `lsof`/`netstat`, installed commands/tools via a `$PATH` scan, and
`uname`) and emits `env.discovery`. Its real effect
is **perception expansion** — discovered dirs/logs are appended to `cfg.watch_dirs` /
`cfg.watch_logs`, and because `fswatch`/`logwatch` re-read those lists every tick, the organism
starts perceiving the new target immediately. New perception → new stimuli → organ growth → and,
via the colony, new purposes (exploration feeds goal-acquisition). It explores *outward* (its own
data home and huge/VCS dirs — `target/`, `.git`, `node_modules`, … — are skipped) within
`cfg.explore_roots` (default: data home + cwd), capped by `explore_max_watch`. `triggers` is the
synthetic `"explore.tick"`; seeded in `main.lua`. Read-only; `--no-explorer` / `--no-explore-expand`
/ `--explore-root` tune it. Like colony/supervisor, it's a normal organ subject to mutation/selection.

### The colony — self-replication + peer communication

A single seeded organ (`templates.lua` `"colony"`) gives the organism a sense of *siblings*.
It needs no core changes — it's grown like any other organ and seeded once by `main.lua`
(idempotent across lives; also growable in directed mode by goal keyword e.g. "çoğal"/"koloni").
Two behaviors, both via a shared filesystem dir `$EVOLUA_HOME/colony/`:
- **Communication (on by default):** each `self.heartbeat`, the organ writes a presence beacon
  (`colony/peers/<id>`), drains its mailbox (`colony/inbox/<id>/`) emitting a `colony.message`
  stimulus per message, and broadcasts a ping to every live peer. Same "file dance" spirit as the
  approval inbox. Sender id is embedded in the message body (ids contain dots, so filenames can't
  carry it). Stale peers are pruned by beacon age (`peer_ttl`).
- **Self-replication (OPT-IN, `--clone`):** spawns a real OS-process clone of itself, relaunching
  `cfg.prog` with `EVOLUA_HOME` pointed at its own sub-home under `colony/children/<id>/` and a
  shared `--colony-root`. **Triply bounded so it can never fork-bomb:** clone depth
  (`clone_max_generation`), colony size (`clone_max_peers`), and a colony-wide cooldown lock
  (`colony/clone.lock`). Children are **mortal** (`clone_child_ticks` then they rest) and launched
  with `--no-clone` — only the root replicates (a star colony). The SAFETY caps live in `config.lua`
  (NOT in genes) so mutation can tune the comms/clone *cadences* but never loosen the *bounds*.
  `triggers = "colony.tick"` is synthetic (never emitted) precisely so the evolver's free-drive can
  never grow a self-replicator by accident.
  - **When to split is itself a decision** (mirrors the model ladder's "bottleneck + spare capacity"):
    by default (`clone_require_pressure`) the organism divides only under genuine **load** — unmet
    needs (bus `unhandled_streak`), reasoner brain-bottleneck (`llm_fallback` rate), or host **heat**
    (hot/erroring processes in the world model) — AND only when the host has **capacity** to feed
    another worker (spare RAM + not on battery, probed via `hostcaps`, bridged onto `cfg` by
    `main.lua` since the sandbox can't `require`). On macOS the system-wide `metric.cpu` sensor is
    silent (sys_metrics is `/proc`-based), so "compute pressure" comes from the per-process world
    model. `--clone-eager` bypasses the load/capacity gate (fills to `clone_max_peers` whenever
    there's room); `--clone-ignore-battery` drops just the power guard.
  - **What to become is acquired, not given** (`purpose_enabled`, on by default): a clone is
    not a generic copy — at split time the colony *crystallizes a goal* from what the parent is
    living through and passes it as `--goal`, so the child boots **directed** and grows exactly
    that niche's organs. The split's dominant pressure becomes the child's purpose: `purpose_mode`
    = `explore` (the most chronically unhandled stimulus → fill the gap), `exploit` (the
    highest-fitness organ's niche → deepen what pays), or `portfolio` (alternate). The maps live in
    `config.lua` (`purpose_map` stimulus→goal, `template_goal` template→goal); goals are English
    and kept *distinctive* (no shared words like "monitor") so the directed drive grows only the intended organ.
    Thus an aimless free-mode root differentiates its offspring into purpose-directed lineages over
    time; each split is appended to `colony/lineage.log` (the purpose ledger). Children are still
    `--no-clone` (only the root divides) and still adaptive (free-drive can add organs beyond the
    goal). `--clone-generalist` restores plain copies.
  - **Selecting which purposes pay** (S4, `purpose_learn`, on by default): each purpose-directed
    member harvests how well its goal pays off (summed fitness of the goal's organs) into
    `colony/outcomes/<id>`; at the next split the root aggregates that ledger and crystallizes via
    a **bandit over goals** — highest average payoff wins, untried goals get an optimistic prior
    (`purpose_prior`, so each is tried once), and an epsilon probe (`purpose_explore_every`) keeps
    adapting. The rationale is recorded in `lineage.log` ("untried (optimistic)" → "proven avg=6.9
    n=2"). So the colony evolutionarily keeps valuable purposes. `--no-purpose-learn` reverts to S1–S3.

⚠️ With `--clone` (or `clone_enabled = true`), a normal run spawns child *processes* on the host.
Default is off. The colony organ is in `evolver.organs`, so it earns fitness from messaging/cloning
and is itself subject to mutation — the capability self-improves.

### Tuning

All "instincts" — thresholds, cadences, evolutionary pressure, autonomy caps, model params —
live as plain numbers in `lua/config.lua`, overridable by CLI flags (parsed in `lua/main.lua`).
Change behavior there before touching logic.

## Data home layout (`$EVOLUA_HOME`)

```
plugins/    organs the organism wrote (gen_*.lua); deletable, it regrows them
reports/    timestamped Markdown status reports (entity table + narrative + fitness)
state/      memory.lua (persistent cross-life memory) · evolua.log · audit.log
approvals/  pending-*.md → (you) approved/ → done/
models/     downloaded models + current_tier (Phase 4)
colony/     peers/<id> beacons · inbox/<id>/ mailboxes · clone.lock · children/<id>/ (clone sub-homes)
```
