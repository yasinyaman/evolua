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
the README. The project site (https://yaman.dev/evolua/) is `site/index.html` (hand-written
landing page) plus the READMEs and `docs/*.md` rendered by pandoc — `scripts/build_site.sh` builds it
into `_site/`, `.github/workflows/pages.yml` publishes it on every push to `main` that touches docs;
`site/links.lua` rewrites the Markdown cross-links, so keep linking `.md` files as usual. Source code is English too, except the `goal_keywords` lists in `templates.lua`,
which are intentionally **bilingual TR/EN** (e.g. "hata"/"error" → `error_reporter`): the English
synonyms feed the reasoner's RAG, the Turkish ones keep Turkish `--goal` directives working —
don't translate the Turkish away. Keep README.md and README.tr.md in sync when you change either.

## Repository layout

EvoLua is a standalone repository (github.com/yasinyaman/evolua) and a single crate; build it
from the repo root. The empty `[workspace]` table in `Cargo.toml` keeps it its own workspace
root even if it is checked out inside another Cargo workspace.

**Source vs. runtime artifacts** — the only source is `src/` (Rust host) and `lua/` (the
organism). These directories are runtime output the organism regenerates and are gitignored
(`plugins/` only its `gen_*.lua` / `syn_*.lua` — a hand-authored plugin there is committable);
do **not** treat them as source or hand-edit them:
- `plugins/`, `reports/`, `state/`, `sandbox/`, `colony/`, `models/`, `approvals/`, `keys/` at the
  repo root, and the same dirs under `lua/` (a plain-Lua run's default data home)
- a stray nested `evolua/` directory (created if launched from inside its own folder)

## Build & run

```bash
cargo build --release                                   # DEFAULT = llm + acquire + remote + service: ~6 MB, NO model bytes
cargo build --release --no-default-features             # rules-only binary (no brain at all)
cargo build --release --features embed_smol             # + bake SmolLM2-135M in (offline hosts; needs models/smol.gguf)
cargo build --release --features apple                  # + macOS's on-device model as a brain (macOS 26+)
cargo build --release --features gpu-metal              # macOS GPU backend for the local brain

./target/release/evolua --ticks 60 --tick-seconds 0.2   # bounded fast demo
./target/release/evolua --goal "report errors"          # directed mode (also accepts Turkish)
./target/release/evolua                                 # lives indefinitely
./target/release/evolua --help                          # all flags
```

**Build prerequisite for LLM features:** `embed_smol` does `include_bytes!("../models/smol.gguf")`
at compile time. That file is **not in the repo** — run `scripts/fetch_model.sh` first (downloads
the pinned SmolLM2-135M-Instruct Q8_0 and checks its sha256), or the build fails. Plain
`cargo build --release` has no such dependency. `scripts/verify_model_pin.sh` checks every
pinned model (this one and the ladder's) against Hugging Face without downloading.

**The binary carries no model. Which brain runs** is Lua policy (`core/brain.lua`, at boot),
and the host (`src/brain.rs`) only loads what it is told to. Order for a life (`--brain auto`):
1. **explicit** — `$EVOLUA_MODEL` / `--model <gguf>`;
2. **online service with a key** (`src/remote.rs`, feature `remote`, `--llm-api auto`): the first
   provider in `cfg.llm_providers` whose key is in the env or in `<home>/keys/<provider>`, free
   tiers first (groq → cerebras → gemini → openrouter → mistral → github → huggingface, then paid
   openai / anthropic). Keys never touch config. Budget per life `llm_remote_budget`;
   `EVOLUA_LLM_BASE` overrides the base URL (proxies, tests). While it is up no local model is
   loaded (`llm_remote_only`);
3. **the biggest usable brain on this machine** that is bigger than the default: GGUFs of Ollama /
   LM Studio / Jan / GPT4All / the HF and llama.cpp caches (`src/discover.rs`, read from their
   headers), a running local LLM server (`src/service.rs`, feature `service`), the macOS on-device
   model (`src/apple.rs`, feature `apple`) — "fits" = `model_ram_share` of physical RAM (optional
   `model_max_mb`), not backed off, loads. At equal size a model a **running server already
   holds** (its GPU, its RAM) or the OS model beats the same GGUF loaded in-process on the CPU
   (on the GB10 that was 8 ticks in 10 s vs 40 s). Reasoning models' `<think>…</think>` is
   stripped for every backend (`brain.rs` `strip_thinking`), and Ollama is told `think: false`
   for the families that have it (`service.rs` `thinks`), or Qwen3 spends the whole token budget
   deliberating;
4. **the default** (`<home>/models/decision.gguf` if downloaded, else the embedded model on an
   `embed_smol` build);
5. **the keyless public endpoint** (pollinations; `llm_keyless`) — only when there is no default, or
   it fails to load, because it answers 402 to big prompts → rules.
`--brain <kind>` / `EVOLUA_BRAIN` restrict the choice (`remote` = online only); `--no-llm-api`
keeps the organism offline; `--no-model-discover` ignores machine brains.

A machine brain is on probation (`ModelMgr:on_boot`, judged against `model_fallback_rate`) and
steps down if slower than `brain_max_seconds` (`ModelMgr:check_speed`); both verdicts back it off
across lives. The download ladder (`modelmgr.lua` `LADDER`: pinned Qwen2.5-Coder-Instruct
0.5B/1.5B/3B/7B q4_k_m, url + sha256, all landing as `decision.gguf`) climbs one tier when the
brain is a bottleneck and the host has capacity, after first proposing `model_adopt` (a stronger
brain already on the machine). **Failover** (`ModelMgr:failover`): the host marks the online brain
*down* after 3 consecutive failures (`401/402/403` → long backoff at once, `429` → short) and
`host_brain_complete` skips it instantly while down (a blocked network never stalls the tick loop),
falling through to the local backend; the model manager then loads a local brain if none is
(machine → default), probes the service on the model-check cadence (`host_remote_probe`, a
real-sized call) and unloads the local model again when the service is back. No key anywhere →
`approvals/api-key-wanted.md` once per life + live pickup of `keys/<provider>` (`want_key`).
Signing up is human. Keep the split: policy in Lua, mechanisms in Rust.

**Hot-swap gotchas:** the llama backend is a process singleton (`llm.rs` `BACKEND`); `n_batch`
must equal `n_ctx` or llama.cpp *aborts the process* on a long prompt (`GGML_ASSERT n_tokens_all
<= n_batch`); the context is 4096 by default (`EVOLUA_LLM_CTX`) because synthesis prompts carry
real command output.

**LLM decision quality:** the embedded SmolLM2-135M is marginal — it often can't emit the
reasoner's strict schema and falls back to rules (watch `llm_ok` vs `llm_fallback` in
`state/memory.lua`). A 0.5B-class model (e.g. Qwen2.5-0.5B-Instruct GGUF) produces usable
`source="llm+rule"` decisions, and a bigger brain already on the machine (Ollama's
qwen2.5-coder:1.5b, the Apple on-device model) is used instead of the embedded one automatically. The
reasoner prompt (`reasoner.lua` `SCHEMA`) carries a worked example — without it even Qwen echoes
the option menus instead of choosing, so keep the example if you touch the prompt.

Cargo features: `default = ["llm", "acquire", "remote", "service"]` — the minimum
self-sufficient binary (runtime, downloader, online client, local-server client, no model bytes);
`--no-default-features` = perception + world model + rule reasoning + evolution only; `llm` =
in-process GGUF brain (incl. models found on disk); `remote` = online LLM services; `service` = a
running local LLM server as the brain; `embed_smol` = bakes in SmolLM2-135M (implies `llm`);
`apple` = macOS's on-device model (Swift bridge built by `build.rs`, weak-linked); `acquire` =
download/checksum a bigger model; `gpu-{metal,cuda,vulkan}` = GPU backend (build-time, one per
binary). Phase 5 (colony / supervisor / explorer / goal acquisition / synth / mesh) is **not**
feature-gated — it's pure Lua plus the always-compiled host threads.

### Run without building (plain Lua)

A stock `lua` (5.3+) interpreter runs the organism directly — the host is optional:

```bash
lua lua/main.lua --ticks 60 --tick-seconds 0.2
lua lua/main.lua --goal "watch filesystem changes"
```

In plain-Lua mode the data home defaults to next to the script (so artifacts land under
`lua/`); the binary uses an OS-appropriate dir. Both honor `EVOLUA_HOME=/path` (as does
`clean.sh`); a Lua global (`lua -e "EVOLUA_HOME='/path'" …`) also works and wins over the env var.

### Tests & reset

Two layers:
- **Unit tests** for the pure parts — `lua tests/run.lua` (stock Lua, no host; serializer,
  memory, bus reward math, rule DSL, model ladder, reasoner parsing, RAG, goal matching,
  platform helpers, log rotation, brain selection incl. online providers + failover against a
  fake host) and `cargo test` (service / acquire / remote add their own). Add a `tests/test_*.lua`
  file to `FILES` in `tests/run.lua` for a new area.
- **Online failover, for real** — a mock OpenAI endpoint (`python3 -I scripts/mock_llm.py`, on
  `127.0.0.1:48200`), `GROQ_API_KEY=x EVOLUA_LLM_BASE=http://127.0.0.1:48200/v1 evolua --llm-api
  groq --ticks 170 --tick-seconds 0.5`, kill the mock mid-run and restart it: `state/audit.log`
  must show `brain_failover: online → local` then `local → online`. Check `lsof -i :48200` first —
  a stale mock from an earlier session makes the test pass vacuously.
- **Behavior** — bounded runs (`--ticks N --tick-seconds 0.2`) and inspecting `reports/` and
  `state/evolua.log`; the scripted suite is `scripts/fulltest.sh` (what each check proves:
  docs/TESTING.md). CI (`.github/workflows/ci.yml`) runs clippy, both unit suites and it.

`./clean.sh` wipes all evolved organs/reports/memory so the next run starts from a
never-lived state (use `EVOLUA_HOME=/path ./clean.sh` for a custom home).

## Architecture

### Host ↔ organism boundary

`src/main.rs` is a thin shell: it embeds the entire `lua/` tree via `rust-embed`, registers
each module into `package.preload` (so the organism's `require("core.kernel")` resolves from
memory — no files on disk), resolves a writable data home, and injects globals
`EVOLUA_HOME`, `arg`, the always-on filesystem helpers `host_list_dir` / `host_walk` /
`host_mkdir` / `host_cwd` / `host_models` (`src/host.rs`), the brain loader `host_brain_kinds` /
`_load` / `_complete` / `_info` (`src/brain.rs`; `host_services`, `host_apple_status`,
`host_remote_set` / `_clear` / `_status` / `_probe` with their features), the outbound proxy
`net_proxy_set` / `_clear` / `net_proxy` (`src/netproxy.rs`, for the mesh gateway), and
`model_acquire(url,dest,sha)` (`src/acquire.rs`, feature-gated). The reasoner's `llm_complete`
is set by `core/brain.lua` once a brain loads or an online service attaches; with none, it stays
absent and the reasoner uses rules. `main.lua` bridges `cfg.llm` / `cfg.llm_active` /
`cfg.compile` / `cfg.dryrun` onto `cfg` for the sandboxed synth organ. Only `lua/core/`,
`lua/sensors/`, `config.lua` and `main.lua` are embedded — never the runtime dirs a plain-Lua
run leaves under `lua/`.

**Never splice a path or other data into a shell command.** Go through `core/platform.lua`:
`list_dir` / `walk` / `mkdir_p` / `cwd` use the host helpers when present and quoted shell
commands otherwise; `shq` quotes one argument (POSIX `'…'`, Windows `"…"`); `safe_path` vets a
path before it joins perception. Sandboxed organs can't `require` core, so the kernel hands them
the same module as `ctx.platform`.

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
colony's two shared **ledgers** are gossiped the same way on every beacon round (`SYNC`):
`colony/genepool/<template>` (horizontal gene transfer — a received genome replaces the local
entry only if fitter, the organ's own rule, so equal entries never ping-pong) and
`colony/outcomes/<member>` (the S4 purpose ledger — a node never lets a copy replace its own
file). The organ does not know or care which siblings are remote. `main.lua` writes
`state/mesh_id` so the nerve learns the colony id. Beacons also carry **capabilities** from
`state/mesh_caps` (written by `ModelMgr:mesh_caps`): `brain=`, `online=`,
`llm_port/llm_path/llm_model=` for a model served on that host (an online brain on `localhost`,
or a `service` brain), `gateway=<port>` when started with `--mesh-gateway` (a CONNECT proxy on
port+1). On its check cadence the model manager may **borrow**: `peer_brain()` attaches a peer's
served model when this node has no brain (`mesh_use_peer_brain`), `gateway()` routes outbound
HTTPS through an online peer's proxy when the local internet probe fails (`mesh_use_gateway`,
host global `net_proxy_set`, honoured by `remote.rs` and `acquire.rs`). Both are opt-out knobs in
`config.lua`, audited, and emit `mesh.borrow`. Verified Mac ↔ GB10 over Tailscale
(`docs/COLONY.md` → *Across hosts*). Env: `EVOLUA_MESH`, `_PORT`, `_SEEDS`, `_TOKEN`.

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
   inherited genes (`cfg.inherited_genes` — vertical gene transfer) when present. A keyword
   matches at the start of a goal word; distinctive keywords weigh 2, generic ones
   (`cfg.goal_generic_keywords`) and keywords shared by several templates weigh 1, and a template
   grows at score ≥ 2 — so give a new template at least one keyword no other template uses;
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
   below `2×retire_floor` (protected and cell-elite lineages exempt; model-written `synth:*` organs
   get `synth_grace` and are spared while their findings outweigh their noise — see Synthesis);
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
  `autonomy_ceiling` hard-caps it. The committed default is **safe**: `autonomy_ceiling =
  "report"`, `model_unattended = false`, `model_upgrade` not safe-listed. `--autonomy suggest`
  routes proposals to the approval inbox; `--unattended` (or `EVOLUA_UNATTENDED=1`) flips all
  three at once so the organism *acts* on its own, including **downloading a better decision
  model without approval** — keep that opt-in, never the default. Destructive actions (kill) *always*
  require approval; reversible safe-listed verbs (throttle, notify, model_downgrade,
  model_rollback, model_adopt; model_upgrade only with `--unattended`) can act at L4 above
  `act_min_conf`. **Evolved organs** (rule-DSL `act`) never execute — they
  *emit* an `action.request` that `Autonomy:request` routes through this same ladder but capped
  by `evolved_action_ceiling` (default `suggest` → approval inbox, never autonomous, whatever the
  global ceiling; kill is not even expressible in the grammar). A successful action earns
  **outcome-credit**: `settle_outcomes()` rewards the requesting organ only if the target's
  world-model load actually drops within `outcome_window` (a fakeproof eligibility trace).
  Approval is a file dance:
  `approvals/pending-<id>.md` → move to `approved/` to apply (archived to `done/`), delete to
  reject. Every decision/action is appended to `state/audit.log`.
- `lua/core/modelmgr.lua` + `lua/core/hostcaps.lua` — meta-evolution: probe RAM/cores/disk/power,
  and climb a model ladder when the brain is a bottleneck (high reasoner fallback) and the host
  has capacity (Phase 4). **Acquisition is fully wired**: every download tier carries a *pinned*
  `url`+`sha256`, and `model_acquire` downloads it — verified end-to-end in both **unattended**
  (L4 acts directly) and **approval-gated** (L3 → approval inbox → `poll_approvals` enacts) modes.
  The organism chooses *when* to fetch, never *what* (the pinned url+sha bound it to a vetted file).
  A failed fetch locks that tier for the life and backs off exponentially across lives
  (`model_retry_secs`, `model_max_attempts`). An upgrade is recorded with the fallback rate it
  replaced; if the new brain falls back more, `model_rollback` restores `<name>.prev`. Before any
  download, a bottlenecked brain first proposes `model_adopt`: the next stronger brain already
  on the machine. Downloads and adoptions switch immediately and are judged and rolled back the
  same way; `ModelMgr:on_boot` drops a switched-to brain that doesn't load in a later life.
  Opt-in `model_force_upgrade` / `model_ignore_battery` override the bottleneck/power guards (off
  by default). Note: macOS available-RAM is `free + inactive + speculative + purgeable` pages
  (`hostcaps.lua`) — "Pages free" alone reads near-zero and would block every upgrade.
- `lua/core/platform.lua` — the OS abstraction (macOS/Linux/Windows) for process listing, error
  logs, and actuator actions. Anything OS-specific belongs here, behind its interface.

### Synthesis — the `synth` organ (the brain writes organs)

Templates are the **floor**, not the ceiling. The seeded `synth` blueprint (`templates.lua`
`T["synth"]`, protected singleton, gated by `cfg.synth` / `--no-synth`) makes the brain *write
whole new organ files* for needs no blueprint covers: the directed goal (always attempted —
`synth_goal_always` — even when a goal keyword also matched a template) and the most chronically
unhandled stimulus (`Evolver:template_for` says no blueprint answers it). The loop, every
`synth_every` ticks, at most `synth_max` per life, blocking the tick loop for the call:
1. **Brief** — one LLM call turns the (often Turkish) purpose into one English sentence of technical
   requirements naming a read-only command *and an alternative* in backticks.
2. **Perceive before coding** — the allow-listed commands from the brief (`SAMPLE_OK`) are run
   **bounded** (5 s via `timeout`/`perl alarm`; a streaming `top` is reported as such) and a
   representative slice of their REAL output goes into the prompt. When that output is a padded
   table (`table_shape`: most lines share one field count), the prompt also carries the **column
   map** (`1=Filesystem 2=Size …`) and the split recipe (`gmatch("%S+")`, index by field).
3. **Write** — the SYSTEM prompt carries a complete, pattern-free worked example (small models copy
   whatever example they see) and hard rules: no `...` placeholders, one handler for a stimulus
   need, `return { handled = true }` only for real work, never echo payloads, never spawn
   `evolua`/`lua`.
4. **Validate** — compile-only (`cfg.compile`, never executes), denylist (`DENY`), **dry run**
   (`cfg.dryrun`: attach to a fake ctx, fire its events twice, surface the runtime slips with the
   failing line), **pre-flight**: every `match("…")` pattern is tried against the organ's *own*
   command's real output (then the brief sample); 0 lines → rejected with the real lines to fit;
   **column check** on a table: every capture must be one whole field and the same field on every
   line (a capture that is a piece of a field — `3` out of `3.0Gi` — or drifts between columns is
   rejected with the column map); **same-approach guard**: a fingerprint (events, command, pattern,
   handled, emit) equal to a failed attempt is rejected; three identical rejections → the need
   backs off (`S.cooldown`).
5. **Install** via `ctx.registry:load`, record the birth as template `synth:llm`, keep the source
   so a cull by any path still yields a lesson.
6. **Select** — honest fitness + **report value** (`reporter.lua`: a report after ≥ `report_stale_ticks`
   quiet earns `report_reward` and a mark in the per-organ **findings ledger** `memory.valued[organ]`;
   a same-shape repeat within that window costs `report_stale_penalty` and a mark in `memory.stale[organ]`).
   A model-written organ counts as *working* while `stale ≤ report_noise_ratio × valued`, and a
   working organ is spared by the evolver's cull however low its bus fitness. Otherwise, after
   `synth_grace` a child below `retire_floor` is retired and its source + a precise *why* + the list
   of tried approaches feed the next synthesis. Runtime errors → `synth_repairs` repair rounds first.
Model-written organs are `plugins/syn_*.lua` (gitignored). Real trials (five Turkish goals, real
perturbations, a 7B brain over Ollama on a GB10) are written up in `docs/TRIALS.md`. Observed: a
1.5B brain compiles and runs but cannot translate "load" into parsing a load-average column; 3B
gets the command right but mis-parsed padded tables before the column check; a hosted 20B+ model
writes a working organ on the first try.

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
/ `--explore-root` tune it. Like colony/supervisor, it's a protected singleton: cull-exempt, never
copied, and re-rendered from its blueprint when that changes (`Evolver:rehydrate`).

### The colony — self-replication + peer communication

A single seeded organ (`templates.lua` `"colony"`) gives the organism a sense of *siblings*.
It needs no core changes — it's grown like any other organ and seeded once by `main.lua`
(idempotent across lives; its goal keywords "çoğal"/"koloni" only matter when the seed was skipped,
since `Evolver:spawn` refuses a second living protected organ).
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
  (NOT in genes) so no gene change can loosen the *bounds*. `triggers = "colony.tick"` is synthetic
  (never emitted) so the free drive never picks it, but the actual guarantee is `Evolver:spawn()`,
  the one gate every drive (seed, directed, free, bandit, illumination, crossover, HGT, reasoner)
  goes through: it refuses a second living protected organ and any template in
  `cfg.disabled_templates` (`--no-colony` etc.), and the bandit skips protected templates.
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
Default is off. The colony organ is in `evolver.organs`, so it earns fitness from handling
heartbeats and cloning (not from the `colony.message` stimuli it emits itself — the bus gives no
credit for an organ's own emits), but as a protected singleton it is never mutated or duplicated.

### Tuning

All "instincts" — thresholds, cadences, evolutionary pressure, autonomy caps, model params —
live as plain numbers in `lua/config.lua`, overridable by CLI flags (parsed in `lua/main.lua`).
Change behavior there before touching logic.

## Data home layout (`$EVOLUA_HOME`)

```
plugins/    organs the organism wrote (gen_*.lua, model-written syn_*.lua); deletable, it regrows them
reports/    timestamped Markdown status reports (entity table + narrative + fitness)
state/      memory.lua (persistent cross-life memory) · evolua.log · audit.log · mesh_id · mesh_caps · mesh.log
approvals/  pending-*.md → (you) approved/ → done/ · api-key-wanted.md (no online key found)
keys/       <provider> one-line API key files, picked up live (gitignored)
models/     downloaded models + current_tier (Phase 4)
colony/     peers/<id> beacons (addr= for mesh peers) · inbox/<id>/ mailboxes · clone.lock
            genepool/<template> (HGT) · outcomes/<id> (S4) — both gossiped over the mesh · children/<id>/
```
