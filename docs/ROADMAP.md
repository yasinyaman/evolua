# EvoLua — Situational Awareness & Sense-making Roadmap

> Goal: let the organism see **which application** is eating resources / producing errors,
> **wander the system and make sense** of what's happening (LLM), and act on a
> **learn → report → suggest → intervene** ladder bounded by confidence + policy.
> Platform-agnostic (macOS + Linux), without touching `mini-lua-coder`.

## ⬛ Status: all five phases implemented

This document explains the **design rationale**; the implementation is complete. For granular
progress and the file list, see `docs/BUILD-PLAN.md`. Summary:

- **Phases 1–4 coded**, the Lua side verified over the bridge with real perception + timing.
- **Phase 5 (colony / supervisor / goal acquisition / exploration)** added and verified with
  bounded runs (25/25 green — `docs/TESTING.md`). Deep-dive: **`docs/COLONY.md`**.
- **Evolution engine enrichment** — honest fitness, MAP-Elites quality-diversity, rule-DSL/GP,
  self-adaptive ES, vertical + horizontal gene transfer, bandit template selection, and
  safety-gated actuators with outcome-credit (the section below).
- **Rust side** (`main.rs`, `supervisor.rs`, `llm.rs`, `acquire.rs`) written to the proven mlua
  pattern and built/tested with a native `cargo build`.
- Open items: live verification on a Windows VM, `gpu-dynamic` (`GGML_BACKEND_DL`).

## Phase 5 — Colony, supervisor, goal acquisition, exploration *(implemented)*

> Let a single organism **replicate** into a colony of communicating processes, decide
> intelligently **when to divide** (load + capacity), be watched by a soft host-side
> **supervisor** ("brainstem"), **acquire purpose** — birthing specialized offspring from the
> pressures it actually experiences — and **explore its environment**, growing its own senses.
> No kernel changes; the colony, supervisor, and explorer are ordinary organs grown from
> `templates.lua`, plus one host-side watch thread.

- **Self-replication** — `colony` organ; opt-in `--clone`; triply bounded (depth, size,
  cooldown lock); mortal children; star topology. Safety caps in `config.lua`, not genes.
- **When-to-split decision** — divide only under demand (unmet needs / brain bottleneck /
  host heat) AND with capacity (spare RAM, not on battery); mirrors the model ladder.
- **Goal acquisition** — `crystallize_goal()` maps the dominant pressure to a goal passed to
  the child (`--goal`), which boots directed and specializes. Modes: explore / exploit /
  portfolio. Ledger: `colony/lineage.log`.
- **Selecting valuable purposes (S4)** — children harvest their goal's payoff into
  `colony/outcomes/`; the root crystallizes via a bandit over goals, favoring proven-valuable
  purposes (optimistic prior for untried, epsilon probe for gaps). `--no-purpose-learn` disables.
- **Environment exploration** — `explorer` organ scouts the host (filesystem / logs / network
  ports / installed commands on `$PATH` / system facts) and expands perception by appending
  discovered dirs/logs to `watch_dirs`/`watch_logs`. New perception feeds goal acquisition.
- **Host-side supervisor** — `src/supervisor.rs` background thread: observes liveness + vitals
  via the filesystem, surfaces them as `host.vitals`; never enforces (opt-in last-resort exit).

Full design and diagrams: **`docs/COLONY.md`**. Verification: **`docs/TESTING.md`**.

## Evolution engine enrichment

> *Implemented.* The phases above grow capability; this layer enriches **how organs evolve** underneath them.
> The evolver began as numeric-parameter tuning over fixed templates with a self-declared
> reward — two poverties: a thin **search space** and a dishonest **fitness signal**. Both are
> now addressed (branch `evolution-enrichment`, 5 commits; verified by bounded plain-Lua runs +
> a focused harness for the safety-gated paths). All edits are to the selection *substrate*
> (`bus` / `evolver` / `autonomy` / `evo_util` — the reward function and operators can't be an
> evolvable organ without circularity); the rule grammar itself is a `templates.lua` blueprint.

**Fitness signal** *(was: an organ's self-declared `reward=N`)*
- **Honest fitness** — reward derived from observable bus facts: `base · gap / share − cost`,
  where *gap* = how starved the stimulus was (need-filling), *share* = co-handlers (anti-
  redundancy), *cost* = measured reactor CPU. Breaks reward-hacking (the colony minting reward
  each heartbeat); the organ's declared number is demoted to telemetry.
- **Outcome-credit (eligibility trace)** — when an action is taken on a world-model entity, the
  requester is rewarded *only if the target's measured load later drops* — fakeproof; rewards
  the world improving, not firing. (Strict corroboration / temporal credit.)
- **Quality-Diversity (MAP-Elites)** — a behavior archive (cell = primary stimulus × subscription
  breadth) keeps the best organ per niche; cell elites are cull-exempt and breeding *illuminates*
  empty niches — a repertoire of competents, not one peak. Coverage logged to `evolution.log`.

**Search space** *(was: fixed templates, numeric genes only)*
- **Rule-DSL / genetic programming** — a `rule` organ's genome is a typed rule list
  (`when <stimulus> if <field> <op> <value> then <report|log|emit|act>`); mutation rewrites
  structure, crossover recombines. The grammar emits only safe primitives → capability-isolated
  by construction (also resolves the sandbox concern — evolved structure can't reach `os`/`io`).
- **Self-adaptive ES mutation** — per-gene log-normal step size (`sigma`), inherited; the kernel
  lives once in `core/evo_util.lua`, shared by numeric genes and rule thresholds.

**Selection & investment**
- **Tournament selection + soft probabilistic death** — replaces elitist rank-1 breeding and
  single-worst culling; seeded-infrastructure lineages (colony/supervisor/explorer) are protected.
- **Bandit template selection** — a UCB bandit over templates (reward = average fitness,
  optimistic prior) invests reproduction where it pays and tries each template once.

**Two-timescale coupling** *(organ ↔ colony)*
- **Vertical gene transfer** — a clone inherits its parent's best genes for its goal's template,
  not just the goal, so colony adaptation compounds instead of restarting each generation.
- **Horizontal gene transfer** — colony peers publish/adopt high-fitness flat genomes through a
  shared `colony/genepool/`.

**Safety.** Evolved organs can `act`, but only by *emitting a request* routed through the same
autonomy ladder — capped to approval-gated by default (`evolved_action_ceiling`), with the
grammar excluding destructive verbs (kill is not expressible).

## Fixed decisions

| Topic | Decision |
|---|---|
| Sense-making | **LLM-based** (local service: Ollama / llama-server, OpenAI-compatible HTTP, or embedded) |
| Proactivity | **Tunable curiosity** — `curiosity` 0 (passive) → 1 (constant exploration) |
| Action | **Autonomy ladder** — learn / report / suggest / autonomous intervention, with confidence + ceiling |
| Platform | **Both** — OS abstraction via `core/platform.lua` |

---

## New architecture pieces

```
  PERCEPTION (sharp)      SITUATION MODEL           SENSE-MAKING (LLM)
  ─────────────────       ───────────────           ──────────────────
  proc_top   ─┐                                  ┌─► reasoner.lua
  proc_errors ┼─► bus ─► worldmodel.lua (dossiers)┤    (situation → hypothesis/narrative)
  net / disk ─┘            per-entity: process     └─► organ growth (LLM code)
                           temperature, errors, trend     │
                                   │                       ▼
                                   └──────────►  AUTONOMY POLICY
                                                 (learn → report → suggest → intervene)
```

- **`core/platform.lua`** — detects the OS, picks the right command (macOS `ps`/`log show`,
  Linux `/proc`/`journalctl`). All sensors use it.
- **`sensors/proc_top.lua`** — per-process CPU/RAM; for those over threshold, `proc.hot {name,pid,cpu,mem}`.
- **`sensors/proc_errors.lua`** — crash/diagnostic logs + exit codes; `proc.error {name,code,msg}`.
- **`core/worldmodel.lua`** — aggregates raw events into **entity (process) dossiers**:
  `{entity, hot_ticks, errors, fs_writes, first_seen, trend, profile}`. The memory of the situation.
- **`core/reasoner.lua`** — sends dossiers over a salience threshold to the LLM, gets a
  natural-language interpretation + (optionally) organ code. Expensive → not every tick, triggered by *interest*.
- **`core/autonomy.lua`** — places the conclusion on the ladder (below).
- **`llm.rs` binding** — `llm_complete(prompt)` host function. The binary stays standalone.

## Curiosity — "wandering the system"

`curiosity ∈ [0,1]` sets the probability/frequency of exploration each tick. When actively
exploring, the organism samples the entity it knows **least** (information gain first): process
name, files/ports it opens, how long it has lived. At 0 it is purely reactive; at 1 it constantly
profiles and proactively enriches the world model. (Phase 5's `explorer` organ extends this from
the per-process scale to the whole host environment.)

## Autonomy ladder (4 actions in one policy)

Every conclusion carries a **confidence score**; the action is chosen by `min(confidence-threshold, config ceiling)`:

| Level | Action | Condition |
|---|---|---|
| **L0 learn** | update the world model + memory | always |
| **L1 report** | write a situational report (narrative) | salience > threshold |
| **L2 notify** | OS notification / highlighted log | high salience |
| **L3 suggest** | "should I stop this process?" → approval inbox (file/interaction) | medium+ confidence |
| **L4 intervene** | autonomous action (throttle/restart) | confidence ≥ threshold **and** ceiling ≥ L4 **and** action safe-listed |

**Safety rules (L4):**
- `autonomy_ceiling` (config) caps the ladder — default **L1 (report)**.
- Only **reversible** actions are autonomous (renice/throttle, restart a user process); destructive
  ones (kill, file deletion) **always** require L3 approval.
- Actions are limited to a **safe-list** (allowlist); every action is written to an **audit log**.
- LLM-generated organ code is **dry-run** first; if it makes system-changing calls it auto-drops to L3.

---

## Phases (risk-reducing order)

### Phase 1 — Sharp perception + world model  *(no LLM, no autonomy — safe, immediately useful)*
`platform.lua`, `proc_top`, `proc_errors`, `worldmodel.lua`, rule-based situational summary.
Output: entity-based reports like "Chrome Helper hot for 40 ticks (cpu ~85%), 2 errors".
→ Test: generate synthetic load/errors, verify the right process is caught.

### Phase 2 — Decision brain + sense-making  *(opt-in `llm` feature)*
Embedded **SmolLM2-135M** decision cortex (`llama-cpp-2`, `embed_smol`) + `reasoner.lua`. The tiny
model decides triage/routing/escalation; good organ code + rich narrative come from templates/RAG or
(when present) a **downloaded larger model**. Output in a strict schema, strict parse + rule fallback.
→ Test: does the tiny model fall back to rules when unsure; schema-parse robustness; narrative quality with a larger model.

### Phase 3 — Autonomy ladder + curiosity
`autonomy.lua`, `curiosity` exploration, approval inbox, safe-list, reversibility, audit log.
Opened gradually via `autonomy_ceiling`.
→ Test: raise the ceiling to L4, verify only reversible + safe-listed actions pass and those needing approval wait.

---

## Embedded model: a tiny "decision brain" + a cortex that grows by evolution

**Design decision:** the binary embeds only a model **small enough to decide**; the heavy
generation/interpretation work is left to **evolution** (RAG + a downloaded larger model).
Biological analogy: a fixed **brainstem** (decisions/routing) + a growing **cortex** (generation).

### Two-speed cognition
| Layer | Where | Job | Cost |
|---|---|---|---|
| **Decision cortex** | embedded, **SmolLM2-135M (~90 MB)** | triage, salience, which-organ, autonomy level, escalation decision | always on, cheap, offline |
| **Thinking layer** | acquired by evolution | good Lua organ code + rich situation narrative | on demand, if capacity allows |

The embedded tiny model **doesn't write code** — it just **decides**: is this situation important,
which template to grow an organ from, are rules enough or should it defer to a larger model, which
autonomy level, should it upgrade its model? Organ *bodies* come from templates (Phase 1) or — when
escalation is needed — a **downloaded larger model** (Phase 2/4). RAG feeds exemplars to whichever generator runs.

### Why tiny is enough
- The binary stays small (~90 MB), runs offline everywhere, decisions always available.
- Generation **quality** scales with evolution + hardware; decision **availability** is constant.
- 135M decisions are noisy → wrapped by a **rule-based guardrail** + confidence threshold: if the tiny
  model is unsure, fall back to the deterministic rule (safe default). The model *enriches* the decision; it doesn't own safety.
- Output is requested in a **strict schema** (keywords), strictly parsed; parse failure → rule fallback.

A build-time feature picks the embedded base (`embed_smol` default). Higher tiers are acquired at runtime (Phase 4).

## Self-improvement — RAG + alternatives

Two timescales: a **fast loop** (online, no weight updates) + a **slow loop** (offline consolidation).
The organism learns from its experience.

### 1) Experience-bank RAG  *(core method — fitness-weighted, self-referential)*
The corpus comes from three sources: (a) seed organ patterns (templates), (b) the organism's own
**high-fitness organs** (harvested while running), (c) past situation→interpretation pairs. When
generating a new organ/interpretation, the **most relevant + highest-fitness** exemplars are retrieved
and injected into the prompt (BM25). As the fitness landscape shifts, the retrieved exemplars shift →
**behavior improves with experience**. Real self-improvement without retraining.

### 2) Experience replay (case-based reasoning)
`(situation_signature, organ, outcome_fitness)` triples are stored. For a new situation, the nearest
past situations are retrieved; low-fitness approaches are avoided, high-fitness ones preferred.

### 3) Prompt / strategy evolution
The generation prompt itself is under selection: prompt variants that birth higher-fitness organs survive.

### 4) Offline LoRA consolidation  *(slow loop — "sleep/consolidation", optional)*
Accumulated high-fitness organs + interpretations are harvested into a fine-tune dataset; the model is
retrained and the embedded model is hot-swapped. Learned behavior is baked into the weights.

> The fast loop (RAG + replay) is always on; the slow loop (LoRA) is periodic/manual.

---

## Phase 4 — Upgrading its own model (meta-evolution)

> The organism measures host capacity; **if the system is capable** it climbs to a stronger model,
> if weak/under load it descends. The model becomes **a unit under selection**, like organs.

### Technical constraint
An embedded model baked in via rust-embed is **compile-time** fixed; it can't change at runtime. Solution:
a **resolver** with priority **disk (data home) > embedded base**.
- The embedded model is a **base/fallback** (always works, offline).
- "Upgrade" = **download** a larger GGUF into the data home (`EVOLUA_HOME/models/`) and switch to it
  (hot-swap on next load). The existing `--model`/env override is preserved.

### Host capacity probe  (`core/hostcaps.lua`)
Measures at boot + periodically: total/free RAM, CPU cores + arch, free disk, battery/thermal, and
**measured real tokens/sec**. These map to the model ladder.

### Model ladder (by capacity)
| Tier | Model | ~RAM | Condition |
|---|---|---|---|
| 0 (base) | SmolLM2-135M Q4 | ~0.5 GB | every machine — embedded fallback |
| 1 | Qwen2.5-0.5B Q5 | ~0.6 GB | pinned url+sha (real acquisition) |
| 2 | Qwen2.5-0.5B Q4 | ~1.5 GB | 2+ cores |
| 3 | Qwen3-0.6B Q4 | ~2 GB | better reasoning |
| 4 | Qwen2.5-1.5B Q4 | ~3–4 GB | 4+ cores, ample RAM |

*(Thresholds calibrated by measured tokens/sec; always leave RAM headroom.)*

### Upgrade decision (meta-selection)
Climbs when **both** hold:
1. **Capacity** — the host runs the next tier with headroom (RAM/disk/cores, not on battery).
2. **Need** — the current model is a **bottleneck**: its organs are low-fitness / interpretations rejected.

Descends on: OOM risk, high latency, battery/thermal, or if the larger model's fitness doesn't beat the smaller.

### Upgrade = a large (but reversible) action on the autonomy ladder
- Downloading a model is significant → default **L3 (suggest/approve)**; autonomous if `autonomy_ceiling ≥ L4`
  and checksum + disk + power checks pass.
- **Safety:** disk/RAM check before download; GGUF **checksum/signature verification**; no download on
  battery; bandwidth awareness.
- **Rollback:** `acquire` keeps the previous model as `<name>.prev`. Once the upgraded brain has
  `model_min_samples` decisions, a higher rule-fallback rate than before the upgrade proposes
  `model_rollback` (safe-listed; also accepted from the approval inbox), which restores `.prev`
  and backs off the rolled-back tier. A failed download is locked for the life and retried with
  exponential back-off across lives. Not yet handled: a downloaded model that fails to *load* —
  the reasoner then runs on rules alone and nothing proposes the rollback.
- **Audit log:** every model change (tier, reason, confidence) is logged.

### GPU: "GPU if present, else CPU" — three scenarios by backend
- **Metal (macOS):** every Mac has Metal → a Metal binary runs on **all Macs**; falls back to CPU with
  `n_gpu_layers=0`. Safe to default on for Mac in a single file.
- **CUDA / Vulkan (Linux/Win):** the binary dynamically links that GPU runtime → won't even start if the
  stack is absent. So a single file can't be "portable + auto CPU fallback"; a target-specific build is needed.
- **`GGML_BACKEND_DL=ON` (dynamic backend loading) — the real solution:** backends are separate shared
  libraries; at runtime a registry loads whichever GPU is present, gracefully falling back to CPU. Cost: the "single file" property is gone.

**Decision (EvoLua):** the embedded 135M decision brain is fast on CPU; GPU is meaningful only for the
larger **downloaded models (Tier 3+)** in Phase 4. So: **default CPU-only** (single file, everywhere,
always works); **opt-in** `gpu-metal` (safe default on Mac), `gpu-cuda` / `gpu-vulkan` (separate builds);
**future** `gpu-dynamic` (`GGML_BACKEND_DL`) — one build, automatic GPU-or-CPU.

---

## Resolved decisions (Phase 2-3)

### LLM context = **the whole-system snapshot**
`reasoner` gives the larger model not a single entity but a **compact summary of the whole world model**
(hot processes, errors, fs/net activity, the organism's own state) → it interprets the situation
*holistically* and correlates entities ("X hot + Y writing to disk → in sync"). The snapshot budget is
trimmed to the **highest-salience** entities (the tiny decision brain triages what goes in).

### Approval mechanism = **file-based inbox**
An `EVOLUA_HOME/approvals/` directory. A proposed action is written as a **pending** file
(`pending-<id>.md`: what, why, confidence, undo plan). The user approves by moving it to `approved/`,
rejects by deleting it. The organism polls `approvals/` each round; it applies approved ones and writes
to the audit log. Independent of interactive prompts → runs headless.

### Confidence score = **rule + LLM combined**
A single score blended from two sources: (a) **deterministic rule signals** — threshold-exceedance
severity, repetition/persistence, past fitness, schema-parse success; (b) the **LLM's self-report**.
Combined confidence = weighted blend; **rules set the ceiling/floor** (the LLM can't claim high confidence
and skip up the ladder on bravado). This score directly drives the ladder level (L0–L4).

### Retrieval = **part of the model ladder** (tiered)
Retrieval evolves with capacity too: at base tiers, **BM25** (dependency-free). As the ladder climbs
(if the system is capable), a small **embedding model** is acquired for semantic retrieval — a downloaded,
fitness-justified tier like the generation model. So the "BM25 → embedding" transition is a step of Phase 4 meta-evolution.
