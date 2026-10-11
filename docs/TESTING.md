# Testing & verification

The pure parts have unit tests — `lua tests/run.lua` (stock Lua, no host) and `cargo test`.
The organism as a whole is a living process, so its behavior is verified with **bounded runs**
(`--ticks N --tick-seconds 0.2`) and by inspecting the artifacts it leaves in `reports/`,
`state/`, and `colony/`. This page documents the bounded suite that exercises
every subsystem, what each check proves, and the last recorded result.

## Running the suite

```bash
scripts/fulltest.sh              # exit 0 = all green
LUA=lua5.4 scripts/fulltest.sh   # choose the interpreter (default: lua)
```

The script builds the debug binary, runs the unit tests, then runs the organism in several
configurations under throwaway `EVOLUA_HOME` dirs and asserts on the artifacts. CI
(`.github/workflows/ci.yml`) runs it on Ubuntu and macOS after clippy and the unit tests.

Most checks use plain `lua` (fast, no rebuild). The supervisor check uses the compiled binary,
because the host-side watch thread only exists in the Rust host.

> The machine's power state matters: the **power-aware hold-off** check (T5) only triggers on
> battery. On AC power, or where the power state can't be read (CI), it is skipped.

## What each check proves

| # | Check | Proves |
|---|---|---|
| **T0** | `cargo build` | the Rust host (incl. `src/supervisor.rs`) compiles clean |
| **T0b** | unit tests | `lua tests/run.lua` and `cargo test` pass |
| **T1** | CLI | `--help` lists the colony/clone flags; a bad value (`--ticks abc`) exits 2 |
| **T2** | base free-mode run | the organism boots and grows organs for unmet needs (`plugins/*.lua` appear); no `fatal` / load / attach failures in the log |
| **T3** | colony beacon | a single instance announces presence in `colony/peers/<id>` |
| **T4** | intelligent split + purpose | under load it splits, **crystallizes a goal**, the child boots **directed** (`mode=directed` in its log); `colony/lineage.log` records the purpose |
| **T5** | power-aware hold-off | on battery it logs `holding off` and spawns **no** clones (capacity guard) |
| **T6** | generalist clones | `--clone-generalist` makes children generic (boot **free**, ledger says `generalist`) |
| **T7** | supervisor roundtrip | the Rust thread writes `state/vitals` and `state/supervisor.log`; the Lua organ reads vitals and surfaces them (`vitals: rss=` in a report); one instance counts as `colony_procs=1` |
| **T8** | reincarnation | a second life inherits organs (cross-life memory); colony / supervisor / explorer stay **one each** (protected organs — those three and synth — are singletons; the suite checks the three) |
| **T9** | S4 purpose-learning | children harvest payoff into `colony/outcomes/`; later splits crystallize by **proven** payoff (the colony learns which purposes pay) |
| **T10** | environment exploration | the `explorer` scouts the host and **expands perception** (auto-adds discovered dirs/logs); huge/VCS dirs (`target/`, `.git`) are skipped |
| **T11** | disabled templates | with `--no-colony --no-supervisor --no-explorer --no-rule`, no drive grows any of them |

## Last recorded result

macOS (Apple Silicon), Lua 5.5, on battery — 2026-10-11, after merging the brain-sourcing /
synthesis / mesh line onto the local-brains base (T5 ran for real this time, so 27 checks):

```
T0  cargo build ................. PASS
T0b unit tests .................. PASS (lua tests/run.lua: 97 · cargo test: 24)
T1  CLI ......................... PASS
T2  base free-mode run .......... PASS (grew 11 organs · no load/attach failures)
T3  colony presence beacon ...... PASS
T4  intelligent split + purpose . PASS
T5  power-aware hold-off ........ PASS (held off · no clones on battery)
T6  generalist clones ........... PASS
T7  supervisor roundtrip ........ PASS
T8  reincarnation / memory ...... PASS
T9  S4 purpose-learning ......... PASS
T10 environment exploration ..... PASS (7 discoveries/expansions)
T11 disabled templates .......... PASS

PASS=27 FAIL=0 SKIP=0 — ALL GREEN
```

Outside the suite, the same day: online→local→online **failover** against a mock OpenAI endpoint
(kill + restart; `state/audit.log`: `brain_failover: online → local` … `local → online`), and the
**mesh ledger gossip** between two nodes on one host (a planted `genepool/fs_journal` with
`fitness 42` and a member's `outcomes/<id>` arrived at the peer within one beacon round; identical
copies are not rewritten, so nothing echoes).

Previous run — macOS (Apple Silicon), Lua 5.5, on AC power — 2026-10-09:

```
T0  cargo build ................. PASS
T0b unit tests .................. PASS (lua tests/run.lua · cargo test)
T1  CLI ......................... PASS (help lists colony flags · bad value exits 2)
T2  base free-mode run .......... PASS (grew 10 organs · no load/attach failures)
T3  colony presence beacon ...... PASS
T4  intelligent split + purpose . PASS (purpose crystallized · child directed · ledger written)
T5  power-aware hold-off ........ SKIP (on AC power)
T6  generalist clones ........... PASS
T7  supervisor roundtrip ........ PASS (vitals · supervisor.log · surfaced in reports · colony_procs=1)
T8  reincarnation / memory ...... PASS (memory persists · one colony, supervisor, explorer)
T9  S4 purpose-learning ......... PASS (outcomes harvested · "proven avg=" in lineage.log)
T10 environment exploration ..... PASS (27 discoveries/expansions · target/.git skipped)
T11 disabled templates .......... PASS

PASS=25 FAIL=0 SKIP=1 — ALL GREEN
```

> Note on T8: protected infrastructure organs (colony, supervisor, explorer, synth) are singletons —
> seeded once, never duplicated by mutation, illumination or the bandit, and exempt from culling.
> Earlier versions let the evolver copy them up to `max_per_template = 3`; the supervisor then
> topped the leaderboard by handling the `host.vitals` stimulus it emitted itself. Both are fixed:
> spawn refuses a second copy, and the bus gives an organ no credit for its own emits.
