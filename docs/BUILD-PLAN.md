# EvoLua — Build Plan

> **Status: all five phases implemented.** The Lua side was verified over the bridge with real
> perception + timing; the Rust side (`main.rs`, `supervisor.rs`, `llm.rs`, `acquire.rs`) was
> written to the proven mlua pattern and built/tested with a native `cargo build`. Phase 5
> (colony / supervisor / purpose / exploration) was verified with bounded runs (25/25 green —
> `docs/TESTING.md`). Design rationale: `docs/ROADMAP.md` · deep-dive: `docs/COLONY.md`.

## Phase 0 — Setup
- [x] `evolua/` standalone crate (its own `[workspace]`; doesn't touch mini-lua-coder)
- [x] Single-binary host (`src/main.rs`): embeds Lua sources into `package.preload`
- [x] Environment-appropriate data home resolution (mac/linux/win) + `EVOLUA_HOME`

## Phase 1 — Sharp perception + world model
- [x] `lua/core/platform.lua` — OS abstraction (mac/linux/**windows**)
- [x] `lua/sensors/proc_top.lua` — per-process CPU/RAM → `proc.hot` / `proc.sample`
- [x] `lua/sensors/proc_errors.lua` — OS crash/error, attributed to a process → `proc.error`
- [x] `lua/core/worldmodel.lua` — entity dossiers (cpu EMA, errors, temperature, trend, salience)
- [x] Rule-based situational summary (reporter: entity table + narrative)
- [x] Config (proc thresholds, ignore/watch lists)
- [x] Test — correct culprit caught under synthetic load

## Phase 2 — Decision brain + sense-making
- [x] Cargo `llm` feature + `src/llm.rs` (llama-cpp-2 CPU, single-shot)
- [x] Embedded SmolLM2-135M (`embed_smol`) + resolver (`--model` > env > disk > embed)
- [x] `llm_complete(system,user,max)` host binding (main.rs, feature-gated)
- [x] `lua/core/reasoner.lua` — whole-system snapshot → strict decision schema
- [x] Strict parse + rule fallback (garbage/missing/invalid → fall back to rules)
- [x] `lua/core/rag.lua` — fitness-weighted BM25 experience bank
- [x] Test — schema parse, fallback, RAG retrieval, live loop (fake model)

## Phase 3 — Autonomy ladder + curiosity
- [x] `lua/core/autonomy.lua` — L0–L4, rule+LLM combined confidence, ceiling
- [x] File-based approval inbox (`pending`→`approved`→`done`) — round-trip test
- [x] Safe-list + reversibility + audit log (`state/audit.log`)
- [x] Suggestion de-dup (cooldown), platform actions (throttle/kill/notify)
- [x] `lua/sensors/curiosity.lua` — actively profile the least-known process
- [x] Test — gating, approval round-trip, audit

## Phase 4 — Upgrading its own model (meta-evolution)
- [x] `lua/core/hostcaps.lua` — RAM/cores/arch/battery/disk probe (verified for real)
- [x] `lua/core/modelmgr.lua` — model ladder + capacity+bottleneck decision (all scenarios)
- [x] Autonomy integration (upgrade = suggest, downgrade = safe act)
- [x] Rust `src/acquire.rs` — GGUF download + SHA-256 + atomic + rollback
- [x] GPU feature flags — `gpu-metal` / `gpu-cuda` / `gpu-vulkan`
- [x] Test — `decide()` scenarios (upgrade/downgrade/hold, battery & disk gates)

## Phase 5 — Colony, supervisor, purpose, exploration  *(no kernel changes; see `docs/COLONY.md`)*
- [x] `templates.lua` `colony` organ — presence beacon + mailbox + ping (the file dance)
- [x] Self-replication (opt-in `--clone`) — triply bounded (depth/size/cooldown), mortal children
- [x] Intelligent split decision — demand (needs/fallback/heat) + capacity (`hostcaps`: RAM/battery)
- [x] Goal acquisition S1–S3 — `crystallize_goal()`, child `--goal`, `lineage.log`
- [x] Purpose selection S4 — `colony/outcomes/` harvest + bandit over goals (proven payoff)
- [x] `templates.lua` `explorer` organ — fs/log/port/command(`$PATH`)/sys discovery + perception expansion
- [x] `src/supervisor.rs` — host-side autonomic watch (liveness + vitals, never enforces)
- [x] Test — `docs/TESTING.md` 25/25 green (T0–T10)

## Cross-cutting
- [x] README + ROADMAP + COLONY + TESTING + BUILD-PLAN up to date (all in English)
- [x] `.gitignore` — `target/`, `models/`, `approvals/`, `audit.log`; `LICENSE` (MIT)
- [x] First native `cargo build` — compiled and run (supervisor + all organs)
- [ ] Live verification on a Windows VM (after cargo build)

## Known refinement points (next round)
- Retrieval is BM25 today; upgrade to an embedding model as capacity grows (part of the Phase 4 ladder)
- `gpu-dynamic` (`GGML_BACKEND_DL`) — one build, automatic GPU/CPU; llama-cpp-2 DL support to be verified
- Reasoner context budget: snapshot-trimming tuning for very crowded systems
- Colony `outcomes/` consolidation + pruning for long-running colonies
