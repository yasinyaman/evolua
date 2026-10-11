# EvoLua — a self-evolving Lua organism

🇬🇧 English · [🇹🇷 Türkçe](README.tr.md) · **site:** [yasinyaman.github.io/evolua](https://yasinyaman.github.io/evolua/)

EvoLua is an experimental, self-contained "digital organism." It **perceives** its host
environment (per-process CPU/RAM, OS error logs, the filesystem), builds an entity-based
**world model**, **makes sense** of the situation (optional embedded LLM + BM25 RAG, with a
rule-based fallback), and **acts** within an autonomy ladder — growing its own plugins
("organs") under a genuine **genetic system** (typed-rule genomes, honest fitness,
quality-diversity), **replicating into a colony** of communicating processes, **acquiring
purpose** for its offspring, and reporting back. It ships as a single self-contained binary.

> **The core insight that shapes everything:** the Rust host never changes, and `lua/core/`
> is an immutable contract. New capability is *always* a new `.lua` file — never an edit to
> the kernel. The organism writes those files itself at runtime from genome blueprints.

The only deliberate exception is a thin host-side **supervisor** ("brainstem") that observes
the organism's vitals and feeds them back — it watches, it never steers (see below).

> **Fully standalone.** A repository and crate of its own: `cargo build --release` from the
> repo root. The empty `[workspace]` table in `Cargo.toml` keeps it independent even when
> checked out inside another Cargo workspace.

---

## Quick start

```bash
# Build the single binary (Lua organism is embedded via rust-embed; mlua 5.4 vendored).
cargo build --release                                   # default: online brain + local GGUF runtime + local servers + downloader — NO model bytes (~6 MB)
cargo build --release --no-default-features             # perception + rules only (no brain)
scripts/fetch_model.sh                                  # models/smol.gguf for embed_smol (sha256-checked)
cargo build --release --features embed_smol             # + bake the tiny SmolLM2-135M in (fully offline hosts)
cargo build --release --features apple                  # + macOS's on-device model as a brain (macOS 26+)
cargo build --release --features gpu-metal              # macOS GPU backend for the local brain

./target/release/evolua --ticks 60 --tick-seconds 0.2        # bounded fast demo
./target/release/evolua --goal "watch and report errors"     # directed mode
./target/release/evolua --clone --clone-ignore-battery       # let it grow a colony
./target/release/evolua                                      # lives indefinitely
./target/release/evolua --help                               # all flags
```

Lua is statically linked into the binary; otherwise it links only system libraries (glibc
on Linux, /usr/lib on macOS). For a fully static Linux binary:
`rustup target add x86_64-unknown-linux-musl && cargo build --release --target x86_64-unknown-linux-musl`
(needs `musl-tools`). Tagged releases (`v*`) attach prebuilt default-feature binaries for Linux
x86_64 (static, musl) and macOS (arm64, x86_64) — see `.github/workflows/release.yml`.

**Run without building** — a stock `lua` (5.3+) runs the organism directly; the host is
optional:

```bash
lua lua/main.lua --ticks 60 --tick-seconds 0.2
lua lua/main.lua --goal "log filesystem changes"
```

> In plain-Lua mode the data home defaults next to the script (`lua/`); redirect it the same
> way as the binary: `EVOLUA_HOME=/path lua lua/main.lua`.

---

## What it can do

| Phase | Capability |
|---|---|
| **1 · Sharp perception** | per-process CPU/RAM (`proc_top`), OS crash/error logs (`proc_errors`), an entity-based **world model**, rule-based situational reports |
| **2 · Decision brain** | a model **interprets** a whole-system snapshot — an **online service** when a key is at hand (free tiers first), else one **already on the machine** (Ollama / LM Studio / HF-cache GGUFs, a running local LLM server, macOS's on-device model), else a download sized to the host; **fails over** online ↔ local for life; learns from its own experience via a fitness-weighted **BM25 RAG**; falls back to rules when there is no brain |
| **3 · Autonomy + curiosity** | the **L0–L4 ladder** (learn → report → notify → suggest → act), a file-based **approval inbox**, safe-list + reversibility + audit log, `curiosity`-driven active exploration |
| **4 · Meta-evolution** | probes the host (`hostcaps`) and climbs a **model ladder** when the brain is a bottleneck and there's spare capacity; download + checksum (opt-in `acquire`); a failed fetch backs off instead of retrying every check; **rollback** restores the previous model when the new one falls back to rules more often |
| **5 · Colony, supervisor, purpose, exploration** | **self-replication** into a colony of communicating processes — across **machines** too with `--mesh` (LAN discovery, seeds for Tailscale/WAN; mail, gene pool and purpose ledger all bridged; a node can borrow a peer's **model** or **internet**); an intelligent **when-to-split** decision (load + capacity); a host-side **supervisor** ("brainstem"); **goal acquisition** — offspring born specialized to a crystallized purpose, with the colony learning which purposes pay; and **environment exploration** — the organism scouts the host and grows its own senses |
| **6 · Synthesis — the brain writes organs** | templates are only the *floor*: the `synth` organ turns a goal or an unhandled stimulus into a one-sentence technical brief, **runs the real commands** and shows their output (with the column map of padded tables) to the model, has it write a whole new organ, **dry-runs and pre-flights** the parser against those real lines — column by column — installs it, and lets honest fitness + report value select; failures feed the next attempt ("don't repeat this approach") |

Phases 1–4 are the original organism; **Phase 5 is the colony/supervisor/purpose layer**
documented in depth in [docs/COLONY.md](docs/COLONY.md).

---

## Phase 5 at a glance — colony, supervisor, purpose

### Program flow

```mermaid
flowchart TD
  A[main.lua starts] -->|seeds colony + supervisor organs| B[Kernel tick loop]
  B -->|self.heartbeat each tick| C[colony organ]
  C --> C1[1 · write presence beacon]
  C1 --> C2[2 · drain inbox → colony.message]
  C2 --> C3[3 · broadcast ping to peers]
  C3 --> D{4 · split decision?}
  D -->|gates pass| E[spawn OS-process clone]
  D -->|any gate fails| F[hold off · log reason]
  E --> G[child joins shared colony/ dir]
  G -. peer messages .-> C
  B -->|each tick| H[supervisor organ]
  H -->|beat state/heartbeat| I[(Rust watchdog thread)]
  I -->|writes state/vitals| H
```

### Self-replication (opt-in: `--clone`)

A single seeded `colony` organ gives the organism a sense of **siblings**. Through a shared
filesystem dir `$EVOLUA_HOME/colony/`, each instance writes a presence beacon, drains its
mailbox (emitting a `colony.message` stimulus per message), and pings live peers — the same
"file dance" idiom as the approval inbox. With `--clone` it can spawn **real OS-process
clones** of itself, **triply bounded so it can never fork-bomb**: clone depth
(`clone_max_generation`), colony size (`clone_max_peers`), and a colony-wide cooldown lock.
Children are **mortal** (`clone_child_ticks`) and launched `--no-clone` — only the root
divides (a star colony). The safety caps live in `config.lua`, **not in genes**, so no gene
change can loosen them. The colony itself is a protected singleton: the evolver's single spawn
gate refuses a second copy from any drive, and `--no-colony` switches it off for the whole life.

### When to split is a decision (not just "if there's room")

```mermaid
flowchart TD
  S[clone-cadence tick] --> H{hard caps ok?<br/>enabled · depth · size · cooldown}
  H -->|no| X[wait]
  H -->|yes| D{demand?<br/>unmet needs · brain fallback · host heat}
  D -->|no| X
  D -->|yes| C{capacity?<br/>spare RAM · not on battery}
  C -->|no| X2[hold off · log reason]
  C -->|yes| P[crystallize a goal from the dominant pressure]
  P --> SP[spawn specialized clone with --goal]
```

Mirroring the model ladder's "bottleneck + spare capacity" rule, the colony divides only
under genuine **load** — unmet needs (bus `unhandled_streak`), reasoner brain-bottleneck
(`llm_fallback` rate), or host **heat** (hot/erroring processes) — and only when the host has
**capacity** (spare RAM, not on battery). `--clone-eager` bypasses the gate; `--clone-ignore-battery`
drops just the power guard. (On macOS the system-wide `metric.cpu` sensor is silent —
sys_metrics is `/proc`-based — so "compute pressure" comes from the per-process world model.)

### Goal acquisition — offspring are born with a purpose

A clone is not a generic copy. At split time the colony **crystallizes a goal** from what the
parent is actually living through and passes it as `--goal`, so the child boots **directed**
and grows exactly that niche's organs:

- **explore** — the most chronically unhandled stimulus → fill the gap
- **exploit** — the highest-fitness organ's niche → deepen what pays
- **portfolio** — alternate between the two (default)

Thus an aimless free-mode root **differentiates its offspring into purpose-directed lineages**
over time. Each split is recorded in `colony/lineage.log` (the purpose ledger).
`--clone-generalist` restores plain copies.

And it **learns which purposes pay** (S4, `purpose_learn`): each child harvests how well its
goal paid off into `colony/outcomes/`, and the root then crystallizes via a **bandit over
goals** — favoring goals whose past children earned the most reward, trying each new goal once
(optimistic prior), and periodically probing the current gap. So the colony evolutionarily
keeps valuable purposes. See [docs/COLONY.md](docs/COLONY.md#s4--selecting-valuable-purposes-a-bandit-over-goals).

### Environment exploration — the organism grows its own senses

Beyond the per-process `curiosity` sensor, a seeded `explorer` organ **wanders the host** —
filesystem directories, log files, listening network ports, **installed commands/tools on
`$PATH`** (so it learns what the host can do — `git`, `docker`, `python`, compilers, …), and
system facts — gated by `curiosity`. Its key effect is **perception expansion**: when it discovers an active directory
or log, it appends it to `watch_dirs` / `watch_logs`, so the existing `fswatch` / `logwatch`
sensors start perceiving it on the next tick. New perception → new stimuli → organ growth →
and, through the colony, **new purposes**. So exploration is the front-end that generates the
environmental diversity that goal-acquisition then exploits. It explores outward (its own data
home and huge/VCS dirs like `target/`/`.git` are skipped) within `explore_roots` (default: the
data home + cwd; widen with `--explore-root`). `--no-explorer` / `--no-explore-expand` disable it.

### The host-side supervisor ("brainstem")

The one deliberate exception to "all behavior lives in Lua": a background thread the Rust
host spawns (`src/supervisor.rs`). Because mlua runs the organism in-process on the main
thread, this watch lives on its own thread and talks to the organism only through the
filesystem. It is **supervision, not control**: it observes liveness (the `state/heartbeat`
the Lua `supervisor` organ beats each tick) and writes coarse vitals (`stall`, `self_rss_mb`,
`colony_procs`) to `state/vitals`. The Lua `supervisor` organ reads those back and emits a
`host.vitals` stimulus so the *evolvable* layer decides what to do — the host never caps,
kills, or steers evolution. The single hard reflex (process exit on a prolonged stall) is
**opt-in and off by default** (`EVOLUA_WATCHDOG_KILL=1`).

---

## Evolution engine — how organs actually evolve

Underneath the phases, the evolver is no longer a numeric-parameter tuner over fixed
templates — it is a genuine genetic system. (Design rationale + verification:
[docs/ROADMAP.md](docs/ROADMAP.md#evolution-engine-enrichment).)

| Mechanism | What it does |
|---|---|
| **Honest fitness** | reward is derived from *observable bus facts* — filling a starved stimulus (surprise) ÷ co-handlers (anti-redundancy sharing) − measured cost (parsimony) — **not** the number an organ declares about itself. Breaks reward-hacking (e.g. the colony minting its own reward each heartbeat). |
| **Tournament + soft death** | k-tournament breeding (not just the single fittest) and probabilistic culling preserve diversity; seeded-infrastructure organs (colony/supervisor/explorer) are singletons, exempt from culling and never duplicated. |
| **Rule-DSL / genetic programming** | a `rule` organ's genome is a typed rule list — `when <stimulus> if <field> <op> <value> then <report\|log\|emit\|act>`. Mutation rewrites the stimulus/field/op/value/action and adds/removes rules; crossover recombines two parents. The grammar emits **only safe primitives** (no `os`/`io`) — structurally **capability-isolated**, so structure can evolve while staying safe. |
| **Quality-Diversity (MAP-Elites)** | a behavior archive keeps the best organ per niche (primary stimulus × subscription breadth); cell elites are protected and breeding can *illuminate* empty niches — a **repertoire of competents**, not convergence onto one peak. |
| **Self-adaptive (ES) mutation** | each numeric gene carries its own log-normally-mutated step size (`sigma`), inherited across generations — the lineage learns *how much* to mutate each gene. |
| **Safety-gated actuators + outcome-credit** | a rule organ can `act` — but it only *emits a request*; the core autonomy ladder decides, capped to **approval-gated for evolved organs by default** (never autonomous in this config). When an action is taken, the organ is rewarded only if the target's measured load actually drops — a fakeproof eligibility trace that rewards *the world improving*, not *firing*. |
| **Gene transfer** | **vertical** — a clone inherits its parent's best tuned genes for its goal's template, not just the goal; **horizontal** — colony peers publish/adopt high-fitness genomes through a shared gene pool. |
| **Bandit template selection** | a UCB bandit invests reproduction in templates that pay off, trying each once (optimistic prior) — proactive, payoff-directed exploration beyond the reactive need-drive. |

Two observability files make the dynamics visible: **`state/evolution.log`** (per-generation
TSV — population, mean/max/min/stddev fitness, distinct species, MAP-Elites coverage, reasoner
fallback rate) and **`state/repertoire.txt`** (the current QD map — best organ per behavior cell).

These are the rare justified edits to `lua/core/` (the reward function, selection loop,
variation operators, and QD archive *are* the substrate of selection — they cannot be an
evolvable organ without circularity). The rule grammar itself lives in `templates.lua`, the
blueprint layer.

---

## Architecture

### Host ↔ organism boundary

`src/main.rs` is a thin shell: it embeds the entire `lua/` tree via `rust-embed`, registers
each module into `package.preload` (so `require("core.kernel")` resolves from memory — no
files on disk), resolves a writable data home, spawns the supervisor thread, and injects the
globals `EVOLUA_HOME`, `arg`, the filesystem and model-discovery helpers, the brain loader
(`host_brain_*`), and — when feature-gated — `model_acquire`. Which brain to load is decided in
Lua (`core/brain.lua`); with no brain the reasoner uses rules.

### The tick loop (`lua/core/kernel.lua`)

Each tick, on independent cadences: **perceive** (every sensor's `sense`) → **evolve**
(`evolve_every`) → **persist/housekeep** (`save_every`) → **reason** (`reasoner_every`) →
poll the approval inbox + meta-evolution → situational report. All subsystems share one `ctx`
table (`bus`, `memory`, `registry`, `evolver`, `worldmodel`, `reasoner`, `autonomy`,
`modelmgr`, `log`, `report`).

### Files

| File | Role |
|---|---|
| `src/main.rs` | single-binary host: embeds `lua/`, resolves data home, injects globals, spawns supervisor + mesh |
| `src/supervisor.rs` | host-side autonomic watch (the "brainstem"): liveness + vitals, never enforces |
| `src/mesh.rs` | host-side **mesh** nerve (opt-in): UDP/seed discovery + TCP mail + ledger gossip (gene pool, purpose outcomes) that bridges `colony/` across machines; beacons carry capabilities (brain, served model, internet, gateway) so a node can borrow a peer's **model** or **internet** |
| `src/netproxy.rs` | process-wide outbound proxy the model manager points at a peer's gateway (`net_proxy_set`) |
| `src/remote.rs` | the **online** brain: OpenAI-compatible endpoints + Anthropic, per-life call budget, failure tracking + backoff (the host side of failover) — `remote` feature |
| `src/host.rs` | native filesystem helpers (list / walk / mkdir / cwd) so perception never builds shell commands from paths |
| `src/discover.rs` | finds brains already on the machine: Ollama / LM Studio / Jan / GPT4All / HF / llama.cpp GGUFs, read from their headers |
| `src/brain.rs` | loads and swaps the decision brain on request (`host_brain_*`) |
| `src/service.rs` | a running local LLM server as the brain — `service` feature |
| `src/apple.rs` · `src/apple/bridge.swift` | macOS's on-device model as the brain (Swift bridge built by `build.rs`) — `apple` feature |
| `src/llm.rs` | in-process GGUF brain (llama-cpp-2 CPU, the model's own chat template) — `llm`/`embed_smol` feature |
| `src/acquire.rs` | GGUF download + SHA-256 + atomic swap, keeping the old file as `.prev` for rollback — `acquire` feature |
| `lua/core/kernel.lua` | life cycle / tick loop; reward/error feedback → fitness |
| `lua/core/bus.lua` | event bus (pub/sub) — the nervous system; per-event stats |
| `lua/core/memory.lua` | persistent cross-life memory; fitness, generation, counters |
| `lua/core/serialize.lua` | the one serializer: memory, organ genes, inherited genomes |
| `lua/core/registry.lua` | plugin loader + sandbox + hot-reload + retirement |
| `lua/core/templates.lua` | **genome blueprints** — render organ source; the **rule-DSL/GP** organ + `colony`, `supervisor`, `explorer`, and `synth` (the model-written-organ loop) |
| `lua/core/evolver.lua` | evolution engine: need/goal/**bandit** growth, **tournament** selection + soft death, **MAP-Elites** archive, **ES** mutation, **crossover**, honest-fitness ranking |
| `lua/core/evo_util.lua` | shared evolutionary operators (Box–Muller gauss + self-adaptive ES step) |
| `lua/core/worldmodel.lua` | entity (per-process) dossiers: CPU/errors/temperature/trend/salience |
| `lua/core/reasoner.lua` | sense-making: snapshot → decision schema (LLM+RAG, rule fallback) |
| `lua/core/brain.lua` | which brain to think with: boot selection (online → machine → keyless → default), providers + keys, candidates on this machine, switching |
| `lua/core/rag.lua` | fitness-weighted BM25 experience bank |
| `lua/core/autonomy.lua` | the L0–L4 ladder + approval inbox + safe-list + audit log; **evolved-organ action requests + outcome-credit** |
| `lua/core/hostcaps.lua` | host probe (RAM/cores/power/disk) |
| `lua/core/modelmgr.lua` | meta-evolution: model ladder + capacity/need decision + rollback; online↔local **failover**, key pickup, mesh capabilities + borrowing |
| `lua/core/platform.lua` | OS abstraction (mac/linux/win): process list, error logs, actuators, shell quoting, filesystem walk |
| `lua/core/reporter.lua` | actuator: status summary + observations → Markdown reports; **report value** (a finding after quiet pays, a same-shape repeat costs) |
| `lua/sensors/*.lua` | `sys_metrics`, `logwatch`, `fswatch`, `introspect`, `proc_top`, `proc_errors`, `curiosity` |
| `lua/config.lua` | all "instincts" as plain numbers (thresholds, cadences, caps, colony/purpose) |
| `lua/main.lua` | entry point + CLI flag parser + organ seeding |

---

## Two modes

| Mode | How | Behavior |
|---|---|---|
| **free** | no goal | reacts to whatever the environment offers; grows an organ for any recurring stimulus it can't yet handle |
| **directed** | `--goal "..."` | grows goal-relevant organs first (bilingual TR/EN keyword match; generic words like *monitor*/*izle*/*report* alone don't trigger growth), then free evolution continues |

Directed-mode matching is bilingual: "hata"/"error" → `error_reporter`, "dosya"/"file" →
`fs_journal`, "cpu"/"kaynak"/"resource" → guards, etc.

---

## Decision brain — what it thinks with

The binary carries **no model**. The reasoner needs a model only to fill a short decision schema
(and the synth organ a stronger one to write code), so EvoLua looks for a brain in this order and
keeps **failing over** between them for the rest of its life:

| Kind | Where it comes from | Build feature |
|---|---|---|
| `remote` | an **online service** whose key is in the environment **or in a one-line file `keys/<provider>`** in the data home — free tiers first: `groq` → `cerebras` → `gemini` → `openrouter` (free model) → `mistral` → `github` → `huggingface`, then paid `openai` / `anthropic`; the **keyless** public endpoint (`pollinations`) only when nothing on the machine is worth using. Any OpenAI-compatible URL works too (`--llm-api https://host/v1`, `anthropic+URL` pins the Anthropic wire format) | `remote` |
| `gguf` | a GGUF another tool already downloaded — Ollama's models (plain GGUF blobs), LM Studio, Jan, GPT4All, the Hugging Face and llama.cpp caches, `$EVOLUA_MODEL_DIRS` / `model_dirs` / `--model-dir` | `llm` |
| `service` | a running Ollama, LM Studio, llama-server or other OpenAI-compatible server on localhost (or `$EVOLUA_SERVICE_URLS`) — never started by EvoLua | `service` |
| `apple` | macOS's on-device Foundation model (macOS 26+, Apple Intelligence on; managed by the OS, no RAM in our process) | `apple` |
| download | a pinned ladder sized to the host — Qwen2.5-Coder-Instruct 0.5B → 1.5B → 3B → 7B (url + sha256) — through the autonomy ladder, hot-swapped in when it lands, never re-downloaded | `acquire` |
| `embedded` | SmolLM2-135M baked into the binary (`scripts/fetch_model.sh`) — only for fully offline hosts | `embed_smol` |

**The organism's own default brain never changes**: a `models/decision.gguf` it downloaded, else
the model built into the binary (if any). Everything else is used *instead* when it is better,
and the default stays the fallback. At boot (`--brain auto`, the default) `core/brain.lua` picks:

1. `$EVOLUA_MODEL` / `--model <gguf>`, if set (always wins);
2. else an **online service with a key** (`--llm-api auto`, free tiers first);
3. else the **biggest** brain on the machine, of any kind, that is bigger than the default,
   fits (`model_ram_share` of physical RAM, default 25%; optional `model_max_mb` cap), hasn't
   been backed off, and loads;
4. else the keyless public endpoint; else the default; else rules.

**Failover:** three consecutive online failures (blocked network, quota, outage; `401/402/403`
immediately) put the service in a backoff window during which calls fall straight through to the
local brain; the model manager loads one if none is (machine brain, else the default), probes the
service on the model-check cadence, and switches back when it answers — freeing the local model's
RAM. No key anywhere? It writes `approvals/api-key-wanted.md` (free providers, where a key comes
from, where to drop it) and carries on with the local brain / rules; a key dropped into
`keys/<provider>` goes live without a restart. No provider lets a program sign itself up, so that
step stays human.

"Can use" is then checked in practice. A machine brain starts on probation and goes back to the
default if it falls back to rules more often than `model_fallback_rate`. A brain slower than
`brain_max_seconds` per decision (default 10 s; the warm-up answer isn't counted) steps down to
the next smaller one. Either way it is backed off, so the next life starts at the right brain.
`--brain <kind>` (or `EVOLUA_BRAIN`) restricts the choice, `--brain rules` turns models off.
Discovered models show up in reports as `discovered model: …` even in a build that can't load
them, and every report names the active brain.

Later in a life, when the brain falls back to rules too often, the model manager first proposes
**`model_adopt`** — the next bigger brain on the machine, with no download — and only then the
download ladder (never a tier smaller than the brain in use). Every switch takes effect
immediately, is judged on fresh samples, and is rolled back if the new brain does worse; a
switched-to brain that doesn't load in a later life is dropped.

## Data home layout (`$EVOLUA_HOME`)

```
plugins/    organs the organism wrote (gen_*.lua; model-written syn_*.lua); deletable, it regrows them
reports/    timestamped Markdown status reports (entity table + narrative + fitness)
state/      memory.lua (cross-life memory) · evolua.log · audit.log
            evolution.log (per-generation metrics) · repertoire.txt (MAP-Elites QD map)
            heartbeat · vitals · supervisor.log   (Phase 5: host watch)
            mesh_id · mesh_caps · mesh.log        (--mesh)
approvals/  pending-*.md → (you) approved/ → done/ · api-key-wanted.md (no online key found)
keys/       <provider> — one-line API key files, picked up live
models/     downloaded models + current_tier (Phase 4)
colony/     peers/<id> beacons (addr= for remote hosts via --mesh) · inbox/<id>/ mailboxes · clone.lock
            genepool/<template> (HGT) · outcomes/<id> (S4 purpose payoff) — both gossiped over the mesh
            children/<id>/ (clone sub-homes; inherited.lua = vertical gene transfer)
            lineage.log (purpose ledger)
```

| OS | Default data home (binary mode) |
|---|---|
| macOS | `~/Library/Application Support/EvoLua/` |
| Linux | `$XDG_DATA_HOME/evolua` or `~/.local/share/evolua/` |
| Windows | `%APPDATA%\EvoLua\` |

Override with `EVOLUA_HOME=/path ./evolua` (plain Lua reads the same variable). In plain-Lua
mode the home otherwise defaults next to the script.

---

## CLI flags (selected)

```
--mode <free|directed>     life mode (default: free)
--goal "<text>"            directive for directed mode (implies --mode directed)
--ticks <n>                run for n ticks then rest (default: forever)
--tick-seconds <s>         seconds per tick (0.2 for a fast demo)
--brain <kind>             decision brain: auto|rules|remote|gguf|embedded|service|apple (default: auto)
--autonomy <lvl>           autonomy ceiling: learn|report|notify|suggest|act (default: report)
--unattended               act on its own + download a better model without approval
                           (= EVOLUA_UNATTENDED=1; off by default)

--llm-api <auto|provider|url>  online brain (default auto = free tiers first, see above)
--llm-model <name>         model at that service · --llm-key-env <VAR> · --llm-budget <n>
--no-llm-api / --no-llm-keyless   never go online / never use the keyless public endpoint
--model <path.gguf>        use this local model · --model-dir <path> extra GGUF dir (repeatable)
--model-max-mb <n>         cap model size · --no-model-discover · --model-force-upgrade
--no-synth                 never grow the synthesizer (model-written organs)

--mesh                     join organisms on other hosts (LAN broadcast + TCP mail + ledger gossip; docs/COLONY.md)
--mesh-seed <host:port>    announce to a peer across Tailscale/VPN/WAN (repeatable; implies --mesh)
--mesh-port <n>            mesh UDP/TCP port (default: 7707)
--mesh-gateway             also serve as an internet gateway (CONNECT proxy) for mesh peers

--clone                    allow the colony to spawn real OS-process clones (default: off)
--clone-eager              split whenever there's room (skip the load/capacity gate)
--clone-ignore-battery     allow spawning clones while on battery
--clone-generalist         clones are generic copies (skip goal crystallization)
--purpose-mode <m>         how a clone's goal is chosen: explore|exploit|portfolio
--no-purpose-learn         disable S4 (don't bias goals by harvested child payoff)
--clone-max-peers <n>      hard cap on simultaneous live instances (default: 3)
--clone-generations <n>    hard cap on clone depth, root=0 (default: 1)
--no-colony                do not seed the colony organ
--no-supervisor            do not seed the host-brainstem watch organ
--no-explorer              do not seed the environment-exploration organ
--no-rule                  do not seed the evolvable rule-DSL/GP organ
--no-explore-expand        explore, but don't auto-expand perception
--explore-root <path>      add a directory the explorer may wander (repeatable)
```

Brain env knobs: `EVOLUA_LLM_API`, `EVOLUA_LLM_MODEL`, `EVOLUA_LLM_BASE` (proxy/test base URL),
`EVOLUA_LLM_CTX` (local context, default 4096), `EVOLUA_MODEL` (explicit GGUF), `EVOLUA_BRAIN`.

Host-side supervisor env knobs: `EVOLUA_WATCHDOG` (0=off), `EVOLUA_WATCHDOG_SECS`,
`EVOLUA_WATCHDOG_STALL`, `EVOLUA_WATCHDOG_KILL` (opt-in last-resort exit), `EVOLUA_WATCHDOG_KILL_SECS`.
Mesh env knobs: `EVOLUA_MESH`, `EVOLUA_MESH_PORT`, `EVOLUA_MESH_SEEDS`, `EVOLUA_MESH_TOKEN`.

---

## Autonomy ladder

| Level | Action | Condition |
|---|---|---|
| **L0 learn** | update the world model | always |
| **L1 report** | write to a status report | default ceiling |
| **L2 notify** | OS notification | high salience |
| **L3 suggest** | write `approvals/pending-*`, wait | medium+ confidence |
| **L4 act** | autonomous action (reversible + safe-listed only) | confidence ≥ threshold **and** ceiling ≥ L4 |

`autonomy_ceiling` caps the ladder. Destructive actions (kill) **always** require approval;
reversible safe-listed verbs (throttle, model_downgrade; model_upgrade only with `--unattended`) can act at L4 above
`act_min_conf`. **Evolved organs** (rule-DSL `act`) are capped more conservatively still —
`evolved_action_ceiling` defaults to `suggest`, so their requested actions go to the approval
inbox, never autonomous, whatever the global ceiling. Approval is a file dance:
`approvals/pending-<id>.md` → move to `approved/`
to apply (archived to `done/`), delete to reject. Every decision/action is appended to
`state/audit.log`.

The default ceiling is **`report`**: the organism only writes reports. `--autonomy suggest`
sends proposed actions (and model upgrades) to the approval inbox. Unattended operation is
**opt-in**: `--unattended` (or `EVOLUA_UNATTENDED=1`) sets `autonomy_ceiling = "act"` and
`model_unattended = true` and safe-lists `model_upgrade`, so the organism takes reversible
actions and downloads a better decision model without asking.

---

## Testing & reset

Unit tests cover the pure parts: `lua tests/run.lua` (stock Lua, no build needed) and
`cargo test`. Behavior is verified with bounded runs and inspecting `reports/` and `state/`.
The bounded behavior suite is `scripts/fulltest.sh` (CI runs it on Ubuntu and macOS):
build, unit tests, CLI, base run, colony comms, intelligent split, purpose crystallization,
power-aware hold-off, generalist clones, supervisor roundtrip, cross-life memory and singleton
infrastructure, S4 purpose-learning, environment exploration, and disabled templates. See
[docs/TESTING.md](docs/TESTING.md) for what each check proves and the last result. For a
narrated capture of a real run, see [docs/DEMO.md](docs/DEMO.md).

```bash
lua tests/run.lua      # unit tests (stock Lua)
cargo test             # host unit tests
scripts/fulltest.sh    # bounded behavior suite
./clean.sh             # wipe evolved organs/reports/memory so the next run starts never-lived
```

---

## Safety

Organs run in a deliberately permissive Lua sandbox (`os`/`io` open) — a CI/agent philosophy.
The autonomy default is `report`; unattended operation needs `--unattended` (see above).
Self-replication is **off by default** and triply bounded when enabled; the supervisor
**observes only** unless you opt into its last-resort exit. The colony spawns child *processes*
only with `--clone`. Review `watch_dirs` / `watch_logs` / `autonomy_ceiling` before running on
an unfamiliar host, and inspect the organs in `plugins/` — you can read, review, and delete them.

---

## Disclaimer

EvoLua is **experimental research / educational software**, provided **"as is"** under the
[MIT License](LICENSE) with **no warranty of any kind**. Use it **at your own risk**.

By design it:
- **runs with broad permissions** — organs execute in a deliberately permissive Lua sandbox (`os`/`io` open);
- **observes your host** — per-process stats, OS error logs, and (via the explorer) scans directories, log files, listening ports, and your `$PATH` (read-only);
- **can self-replicate** — with `--clone` it spawns real OS processes (bounded, but real);
- **can act on its own when you opt in** — `--unattended` (or `EVOLUA_UNATTENDED=1`) lets it take reversible actions and even download a model without asking. The default (`autonomy_ceiling = "report"`) only reports.

Review `watch_dirs` / `watch_logs` / `autonomy_ceiling` and inspect the organs it grows under
`plugins/` before running on an important or unfamiliar system, and only run it where you are
authorized to. The authors and contributors accept **no liability** for any damage, data loss,
resource consumption, or other consequences of running this software.

---

## Documentation

- [docs/DEMO.md](docs/DEMO.md) — **annotated capture of a real run** (for reviewers: see what it actually does)
- [docs/COLONY.md](docs/COLONY.md) — Phase 5 deep-dive: colony, intelligent split, supervisor, goal acquisition
- [docs/TESTING.md](docs/TESTING.md) — the bounded verification suite and what each check proves
- [docs/ROADMAP.md](docs/ROADMAP.md) — design rationale across all phases (mostly Turkish)
- [CLAUDE.md](CLAUDE.md) — guidance for AI assistants working in this repo
