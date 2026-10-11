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
cargo build --release                                   # DEFAULT = llm + acquire + remote: ~6 MB, no model bytes
cargo build --release --no-default-features             # rules-only binary
cargo build --release --features embed_smol             # + bake SmolLM2-135M in (offline hosts; needs models/smol.gguf)
cargo build --release --features gpu-metal              # macOS GPU backend for the local brain

./target/release/evolua --ticks 60 --tick-seconds 0.2   # bounded fast demo
./target/release/evolua --goal "report errors"          # directed mode (also accepts Turkish)
./target/release/evolua                                 # lives indefinitely
./target/release/evolua --help                          # all flags
```

**The binary carries no model.** Only opt-in `embed_smol` does `include_bytes!("../models/smol.gguf")`
(file not in the repo — must exist or that build fails). At runtime the brain is **late-bound**
(`llm_load`/`llm_unload`/`llm_model` over a `Rc<RefCell<Option<Brain>>>` slot in `src/main.rs`) and
chosen by `lua/core/modelmgr.lua` in this order, with **failover** for life:
1. **Online service** (`src/remote.rs`, `--llm-api auto` default): first provider with a key in the
   env or in `<home>/keys/<provider>`, free tiers first (ollama server → groq → cerebras → gemini →
   openrouter free → mistral → github → huggingface), then the keyless public endpoint
   (pollinations), then openai/anthropic. Provider table lives in `main.lua` (`PROVIDERS`), keys never
   touch config. Budget per life (`llm_remote_budget`). `EVOLUA_LLM_BASE` overrides the base URL (proxies, tests).
2. **GGUF found on the host** (`lua/core/modelfind.lua`: Ollama manifests/blobs, LM Studio, HF cache,
   llama.cpp caches, `--model-dir`), best coder/instruct that fits `size×1.25+256 ≤ usable RAM`.
   RAM budget = max(available × headroom, total × `model_ram_floor_frac`) — mmap'd weights are evictable
   and macOS "available" undercounts.
3. **Download sized to the host**: pinned ladder (Qwen2.5-Coder-Instruct 0.5B/1.5B/3B/7B q4_k_m, url+sha256)
   through the autonomy ladder, hot-swapped in; `acquire.rs` skips a present, verified file.
4. **Rules.** `$EVOLUA_MODEL` / `--model` still force a specific local file.

**Failover (`ModelMgr:failover`)**: the host marks the online brain *down* after 3 consecutive failures
(`401/402/403` → long backoff at once, `429` → short) and `llm_complete` skips it instantly while down
(a blocked network never stalls the tick loop); `llm_model()` then reports the *effective* brain so the
local ladder runs; `llm_remote_probe()` (a small real-sized call) on the model-check cadence detects
recovery → back online, local model unloaded (`llm_remote_only`). No key anywhere →
`approvals/api-key-wanted.md` once per life + live pickup of `keys/<provider>`. Signing up is human.

**Hot-swap gotcha:** the llama backend is a process singleton — the old `Brain` must be dropped before
loading the next (`BackendAlreadyInitialized` otherwise); `n_batch` must equal `n_ctx` or llama.cpp
*aborts the process* on a long prompt (`GGML_ASSERT n_tokens_all <= n_batch`).

**LLM decision quality:** the embedded SmolLM2-135M is marginal — it often can't emit the
reasoner's strict schema and falls back to rules (watch `llm_ok` vs `llm_fallback` in
`state/memory.lua`). A 0.5B-class model (e.g. Qwen2.5-0.5B-Instruct GGUF) produces usable
`source="llm+rule"` decisions; point `$EVOLUA_MODEL` at it to override the embedded brain. The
reasoner prompt (`reasoner.lua` `SCHEMA`) carries a worked example — without it even Qwen echoes
the option menus instead of choosing, so keep the example if you touch the prompt.

Cargo features: `default = ["llm", "acquire", "remote"]` (the minimum self-sufficient binary — runtime,
downloader, online client, no model bytes); `--no-default-features` = perception + world model + rule
reasoning + evolution only; `llm` = local decision-brain runtime (llama.cpp); `remote` = online brain
(ureq + serde_json; implies `llm`); `embed_smol` = bakes in SmolLM2-135M (implies `llm`); `acquire` =
download/checksum; `gpu-{metal,cuda,vulkan}` = GPU backend (build-time, one per binary). Phase 5 (colony / supervisor / explorer / goal acquisition)
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

### Host-side mesh — organisms on other machines (`src/mesh.rs`, opt-in `--mesh`)

The second deliberate host-side thread, same justification as the brainstem: transport below
evolution. The colony organ's file protocol (`colony/peers/<id>` beacons, `colony/inbox/<id>/`
mail) is bridged across hosts — UDP broadcast beacons on the LAN plus TCP beacons to
`--mesh-seed host:port` (Tailscale/VPN/WAN), remote peers written as beacon files with `addr=`,
mail for an `addr=` peer shipped over TCP and dropped into the remote inbox (`*.net*.msg`). The
organ does not know or care which siblings are remote. `main.lua` writes `state/mesh_id` so the
nerve learns the colony id. Beacons also carry **capabilities** from `state/mesh_caps` (written by
`ModelMgr:mesh_caps`): `brain=`, `online=`, `llm_port/llm_path/llm_model=` for a model served on
that host, `gateway=<port>` when started with `--mesh-gateway` (a CONNECT proxy on port+1). On its
check cadence the model manager may **borrow**: `peer_brain()` attaches a peer's served model when
this node has no brain (`mesh_use_peer_brain`), `gateway()` routes outbound HTTPS through an online
peer's proxy when the local internet probe fails (`mesh_use_gateway`, host global `net_proxy_set`
→ `src/netproxy.rs`, honoured by `remote.rs` and `acquire.rs`). Both are opt-out knobs in
`config.lua`, audited, and emit `mesh.borrow`. Not bridged yet: `genepool/`, `outcomes/`. Verified Mac ↔ GB10 over
Tailscale (`docs/COLONY.md` → *Across hosts*). Env: `EVOLUA_MESH`, `_PORT`, `_SEEDS`, `_TOKEN`.

### The tick loop (`lua/core/kernel.lua`)

`Kernel:run()` drives everything. Each tick, on independent cadences: (1) **perceive** — every
sensor's `sense(ctx)`; (2) **evolve** (`evolve_every`); (3) **persist/housekeep** (`save_every`);
(4) **reason** (`reasoner_every`); (5) poll the approval inbox + meta-evolution
(`model_check_every`); (6) situational report (`situational_every`). All subsystems share one
`ctx` table (`bus`, `memory`, `registry`, `evolver`, `worldmodel`, `reasoner`, `autonomy`,
`modelmgr`, `log`, `report`).

### Event bus = nervous system (`lua/core/bus.lua`)

Sensors `emit` stimuli; plugins `subscribe` and react. A reactor returns `true` or
`{handled=true, reward=N}` to claim a stimulus. The bus does **not** trust that `N` for fitness
— it derives an **honest reward** from observable facts (`base · gap / share − cost`:
need-filling × anti-redundancy sharing − measured reactor CPU time) and emits *that* as
`self.reward`; the declared `N` is kept only as telemetry. This is what breaks reward-hacking
(e.g. the colony minting `reward=4` each heartbeat). A throwing reactor emits `self.error`. The
kernel turns reward/error into fitness deltas (the selective force). The bus tracks per-event-type
`unhandled_streak` (the *unmet-need* signal the evolver reads) and caps emit re-entrancy
(`max_emit_depth`) so chained organ emits can't recurse into a stack overflow.

### Evolution (`lua/core/evolver.lua` + `lua/core/templates.lua` + `lua/core/evo_util.lua`)

`templates.lua` holds **genome blueprints**: each template declares its `triggers` stimulus,
tunable `genes`, `goal_keywords`, an optional `protected` flag (cull-exempt seeded
infrastructure), optional `mutate_genes`/`crossover_genes` operators (structural variation), and
a `build(name, genes)` that *renders the organ's source as a string*. The headline blueprint is
the **rule-DSL/GP** organ (`rule`): a genome of typed rules
(`when <stimulus> if <field> <op> <value> then <report|log|emit|act>`) rendered into **only safe
primitives** — capability-isolated by construction (so structure evolves while staying sandboxed).
The evolver's `step()`:
1. **directed drive** — grow organs whose `goal_keywords` match the goal, using a clone's
   inherited genes (`cfg.inherited_genes` — vertical gene transfer) when present;
2. **free drive** — when an event's `unhandled_streak ≥ need_threshold`, `spawn()` a template
   that triggers on it;
3. **MAP-Elites archive** — `update_archive()` keeps the best living organ per behavior cell
   (primary stimulus × subscription breadth), dumped to `state/repertoire.txt`; cell elites are
   exempt from culling;
4. **selection** — build `ranked`, then: breed via **k-tournament** (not just rank-1) through
   `mutate()` (template-defined structural mutation for rule organs, else **self-adaptive ES**
   numeric perturbation via `evo_util.es_step` — each gene carries an inherited `sigma`);
   **crossover** two tournament parents; a **bandit drive** invests in the highest-UCB template
   (`bandit_pick`, optimistic prior tries each once); **soft probabilistic death** culls organs
   below `2×retire_floor` (cell elites exempt; of each `protected` template only the fittest
   living copy — its *keeper* — is exempt, surplus copies compete normally). Protected templates
   also have their own carrying capacity, `protected_max` (default 1), enforced by
   `Evolver:capacity()` on every breeding path (mutate/crossover/bandit/colony HGT) — cull-exempt
   + breedable would otherwise fill `max_per_template` with immortal duplicates;
5. **entropy** — decay idle fitness; per-generation metrics appended to `state/evolution.log`.

Fitness itself is honest (see the bus); organs can `act` via the safety-gated actuator path (see
Autonomy); the `colony` organ adds vertical + horizontal gene transfer.

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
  can act at L4 above `act_min_conf`. **Evolved organs** (rule-DSL `act`) never execute — they
  *emit* an `action.request` that `Autonomy:request` routes through this same ladder but capped
  by `evolved_action_ceiling` (default `suggest` → approval inbox, never autonomous, whatever the
  global ceiling; kill is not even expressible in the grammar). A successful action earns
  **outcome-credit**: `settle_outcomes()` rewards the requesting organ only if the target's
  world-model load actually drops within `outcome_window` (a fakeproof eligibility trace).
  Approval is a file dance:
  `approvals/pending-<id>.md` → move to `approved/` to apply (archived to `done/`), delete to
  reject. Every decision/action is appended to `state/audit.log`.
- `lua/core/modelmgr.lua` + `lua/core/modelfind.lua` + `lua/core/hostcaps.lua` — brain management
  (see "Build & run" for the online → found → download → rules order and the failover): probe
  RAM/cores/disk/power, attach what fits, and climb the pinned ladder when the brain is a bottleneck
  (high reasoner fallback, or `--model-force-upgrade`) and the host has capacity (Phase 4).
  **Acquisition is fully wired**: every ladder tier carries a *pinned* `url`+`sha256`, and
  `model_acquire` downloads it — verified end-to-end in both **unattended**
  (L4 acts directly) and **approval-gated** (L3 → approval inbox → `poll_approvals` enacts) modes.
  The organism chooses *when* to fetch, never *what* (the pinned url+sha bound it to a vetted file).
  Opt-in `model_force_upgrade` / `model_ignore_battery` override the bottleneck/power guards (off
  by default). Note: macOS available-RAM is `free + inactive + speculative + purgeable` pages
  (`hostcaps.lua`) — "Pages free" alone reads near-zero and would block every upgrade.
- `lua/core/platform.lua` — the OS abstraction (macOS/Linux/Windows) for process listing, error
  logs, and actuator actions. Anything OS-specific belongs here, behind its interface.

### Synthesis — the `synth` organ (the brain writes organs)

Templates are the **floor**, not the ceiling. The seeded `synth` blueprint (`templates.lua`
`T["synth"]`, protected, gated by `cfg.synth`) makes the brain *write whole new organ files* for
needs no blueprint covers: the directed goal (always attempted — `synth_goal_always` — even when a
goal keyword also matched a template) and the most chronically unhandled stimulus. The loop, every
`synth_every` ticks, at most `synth_max` per life, blocking the tick loop for the call:
1. **Brief** — one LLM call turns the (often Turkish) purpose into one English sentence of technical
   requirements naming a read-only command *and an alternative* in backticks.
2. **Perceive before coding** — the allow-listed commands from the brief (`SAMPLE_OK`) are run
   **bounded** (5 s via `timeout`/`perl alarm`; a streaming `top` is reported as such) and a
   representative slice of their REAL output goes into the prompt. This is what let a 3B model pick
   `lsof` over `netstat` when `netstat -an` printed no TCP table inside `io.popen` on this host.
3. **Write** — the SYSTEM prompt carries a complete, pattern-free worked example (small models copy
   whatever example they see — a `df` example became a `df` parser for a load-average goal) and hard
   rules: no `...` placeholders, one handler for a stimulus need, `return { handled = true }` only
   for real work, never echo payloads, never spawn `evolua`/`lua`.
4. **Validate** — compile-only (`cfg.compile`, never executes), denylist (`DENY`, word boundaries
   include `_`), **pre-flight**: every `match("…")` pattern is tried against the organ's *own*
   command's real output (then the brief sample); 0 lines → rejected with the real lines to fit;
   **same-approach guard**: a fingerprint (events, command, pattern, handled, emit) equal to a
   failed attempt is rejected; three identical rejections → the need backs off (`S.cooldown`).
5. **Install** via `ctx.registry:load`, record the birth as template `synth:llm`, keep the source
   (`S.children[n].src`) so a cull by any path still yields a lesson.
6. **Select** — honest fitness + **report value** (`reporter.lua`: a report after ≥ `report_stale_ticks`
   quiet earns `report_reward` and a mark in the per-organ **findings ledger** `memory.valued[organ]`;
   a same-shape repeat within that window costs `report_stale_penalty` and a mark in `memory.stale[organ]`).
   A model-written organ counts as *working* while `stale ≤ report_noise_ratio × valued` — a wave
   detector reports a bounded few times per wave, a garbage reporter forever — and a working organ is
   spared by both the synth's selection and the evolver's cull however low its bus fitness (rare-event
   watchers handle almost nothing on the bus between events; round 1 of `docs/TRIALS.md` lost a correct
   port watcher to exactly that). Otherwise, after `synth_grace` (also honoured by the evolver cull for
   `synth:*` organs) a child below `retire_floor` is retired and its source + a precise *why* (silent
   stimuli / no `handled` / nothing valued / crashed) + the list of tried approaches feed the next
   synthesis. Crashes are recorded as coding slips, not banned approaches. Runtime errors →
   `synth_repairs` repair rounds first, with the failing source line quoted and the Lua slips seen in
   practice listed (gsub's two returns, read-before-close, one variable per capture, no table.find).
Model-written organs are `plugins/syn_*.lua` (gitignored). Real trials of this loop (five goals,
real perturbations, a 7B brain over Ollama on a GB10) are written up in `docs/TRIALS.md`. Observed: a 1.5B brain compiles and runs
but cannot translate "load" into parsing a load-average column; 3B gets the command and column right
but still mis-parses padded tables; a hosted 20B+ model writes a working organ on the first try.

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
