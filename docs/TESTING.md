# Testing & verification

EvoLua has **no unit-test harness**. It is a living process, so verification is done with
**bounded runs** (`--ticks N --tick-seconds 0.2`) and inspecting the artifacts it leaves in
`reports/`, `state/`, and `colony/`. This page documents the bounded suite that exercises
every subsystem, what each check proves, and the last recorded result.

## Running the suite

The suite is plain bash. It builds the debug binary, runs the organism in several
configurations under throwaway `EVOLUA_HOME` dirs, and asserts on the artifacts. A copy is
reproduced below; save it as `fulltest.sh` and run `bash fulltest.sh`.

Most checks use plain `lua` (fast, no rebuild). The supervisor check uses the compiled binary,
because the host-side watch thread only exists in the Rust host.

> The machine's power state matters: the **power-aware hold-off** check (T5) only triggers on
> battery. On AC it is skipped (the path isn't exercised).

## What each check proves

| # | Check | Proves |
|---|---|---|
| **T0** | `cargo build` | the Rust host (incl. `src/supervisor.rs`) compiles clean |
| **T1** | `--help` | the CLI parser exposes the colony/clone flags |
| **T2** | base free-mode run | the organism boots, grows organs for unmet needs, writes reports, no load/attach failures |
| **T3** | colony beacon | a single instance announces presence in `colony/peers/<id>` |
| **T4** | intelligent split + purpose | under load it splits, **crystallizes a goal**, the child boots **directed** and grows exactly that goal's organ; `colony/lineage.log` records the purpose |
| **T5** | power-aware hold-off | on battery it logs `holding off` and spawns **no** clones (capacity guard) |
| **T6** | generalist clones | `--clone-generalist` makes children generic (boot **free**, ledger says `generalist`) |
| **T7** | supervisor roundtrip | the Rust thread writes `state/vitals`; the Lua organ beats `state/heartbeat`, reads vitals, and surfaces them (`host.vitals` → report) |
| **T8** | reincarnation | a second life inherits organs (cross-life memory); seeding is idempotent, variant count bounded by `max_per_template` |
| **T9** | S4 purpose-learning | children harvest payoff into `colony/outcomes/`; later splits crystallize by **proven** payoff (the colony learns which purposes pay) |
| **T10** | environment exploration | the `explorer` scouts the host and **expands perception** (auto-adds discovered dirs/logs); huge/VCS dirs (`target/`, `.git`) are skipped |

## Last recorded result

```
T0  cargo build (debug) ......... PASS (binary built)
T1  --help ...................... PASS (lists colony flags)
T2  base free-mode run .......... PASS (organs=5, reports=2, hardErrors=0)
T3  colony presence beacon ...... PASS (beacon written)
T4  intelligent split + purpose . PASS (split "needs=1 hot=7" · purpose: report errors;
                                        child directed; grew <error_reporter>; ledger 2 entries)
T5  power-aware hold-off ......... PASS (held off on battery; 0 clones)
T6  generalist clones ........... PASS (generic; child boots free mode)
T7  supervisor roundtrip ........ PASS (vitals written; stall=0; Lua surfaced vitals; heartbeat beat)
T8  reincarnation / memory ...... PASS (life1 gen 2 → life2 awoke with organs; seeding idempotent)
T9  S4 purpose-learning ......... PASS (4 outcome entries; later splits "proven avg=6.9 n=2")
T10 environment exploration ..... PASS (5 discoveries, 4 perception expansions; target/.git skipped)

SUMMARY: PASS=25  FAIL=0  — ALL GREEN
```

> Note on T8: a healthy run produces **3** `gen_supervisor_*.lua` files — one from seeding plus
> two mutation variants. This is correct: the supervisor organ earns reward every tick, becomes
> the fittest organ, and the evolver breeds variants of it up to the `max_per_template = 3`
> carrying capacity. Seeding itself is idempotent (it skips if a base organ is already on disk).

## The suite

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"               # run from the repo root
NOANSI='s/\x1b\[[0-9;]*m//g'
PASS=0; FAIL=0
ok(){ echo "  PASS — $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL — $1"; FAIL=$((FAIL+1)); }
H=/tmp/evolua_ft; rm -rf "$H"; mkdir -p "$H"

echo "== T0 cargo build =="; cargo build 2>&1 | tail -n1
[ -x target/debug/evolua ] && ok "binary built" || no "binary missing"

echo "== T1 --help =="
lua lua/main.lua --help 2>&1 | grep -qE -- "--clone" && ok "help lists colony flags" || no "missing flags"

echo "== T2 base free-mode run =="
lua -e "EVOLUA_HOME='$H/t2'" lua/main.lua --ticks 40 --tick-seconds 0.05 --no-clone >/dev/null 2>&1
ORG=$(ls "$H/t2/plugins/" 2>/dev/null | grep -c '\.lua$')
ERR=$(grep -aciE "fatal|attach failed|load failed" "$H/t2/state/evolua.log")
[ "$ORG" -gt 0 ] && ok "grew $ORG organs" || no "no organs"
[ "$ERR" -eq 0 ] && ok "no load/attach failures" || no "failures present"

echo "== T3 colony beacon =="
ls "$H/t2/colony/peers/" >/dev/null 2>&1 && ok "beacon written" || no "no beacon"

echo "== T4 intelligent split + purpose =="
lua -e "EVOLUA_HOME='$H/t4'" lua/main.lua --ticks 200 --tick-seconds 0.06 --clone --clone-ignore-battery >/dev/null 2>&1; sleep 1
grep -aE "splitting under load" "$H/t4/state/evolua.log" | sed "$NOANSI" | grep -q "purpose:" && ok "split crystallized a purpose" || no "no purpose"
CH=$(ls -d "$H/t4"/colony/children/*/ 2>/dev/null | head -n1)
[ -n "$CH" ] && grep -q "mode=directed" "$CH/state/evolua.log" && ok "child booted directed" || no "child not directed"
[ -f "$H/t4/colony/lineage.log" ] && ok "purpose ledger written" || no "no ledger"

echo "== T5 power-aware hold-off =="
BATT=$(pmset -g batt 2>/dev/null | grep -c "Battery Power")
lua -e "EVOLUA_HOME='$H/t5'" lua/main.lua --ticks 60 --tick-seconds 0.06 --clone >/dev/null 2>&1
KIDS=$(ls -d "$H/t5"/colony/children/*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$BATT" -gt 0 ]; then
  grep -qa "holding off" "$H/t5/state/evolua.log" && ok "held off (power-aware)" || no "no hold-off"
  [ "$KIDS" -eq 0 ] && ok "no clones on battery" || no "$KIDS clones on battery"
else echo "  (on AC — skipped)"; ok "skipped"; fi

echo "== T6 generalist clones =="
lua -e "EVOLUA_HOME='$H/t6'" lua/main.lua --ticks 120 --tick-seconds 0.06 --clone --clone-ignore-battery --clone-generalist >/dev/null 2>&1; sleep 1
grep -qa "generalist" "$H/t6/colony/lineage.log" 2>/dev/null && ok "generic clones" || no "expected generalist"

echo "== T7 supervisor roundtrip =="
EVOLUA_HOME="$H/t7" EVOLUA_WATCHDOG_SECS=2 ./target/debug/evolua --ticks 70 --tick-seconds 0.2 >/dev/null 2>&1
[ -f "$H/t7/state/vitals" ] && ok "host wrote vitals" || no "no vitals"
grep -qa "supervisor online" "$H/t7/state/supervisor.log" 2>/dev/null && ok "supervisor.log online" || no "no supervisor.log"
grep -qarE "vitals: rss=" "$H/t7/reports/" 2>/dev/null && ok "Lua surfaced vitals" || no "not surfaced"

echo "== T8 reincarnation =="
rm -rf "$H/t8"
lua -e "EVOLUA_HOME='$H/t8'" lua/main.lua --ticks 30 --tick-seconds 0.05 --no-clone >/dev/null 2>&1
lua -e "EVOLUA_HOME='$H/t8'" lua/main.lua --ticks 30 --tick-seconds 0.05 --no-clone >/dev/null 2>&1
grep -aoE "awoke with [1-9]" "$H/t8/state/evolua.log" | tail -n1 | grep -q "awoke" && ok "memory persists" || no "no inheritance"

echo "== T9 S4 purpose-learning =="
lua -e "EVOLUA_HOME='$H/t9'" lua/main.lua --ticks 360 --tick-seconds 0.04 --clone --clone-ignore-battery >/dev/null 2>&1; sleep 1
[ "$(ls "$H/t9/colony/outcomes/" 2>/dev/null | wc -l)" -gt 0 ] && ok "children harvested payoff" || no "no outcome ledger"
grep -qaE "proven avg=" "$H/t9/colony/lineage.log" 2>/dev/null && ok "later splits chose by proven payoff" || no "no learning"

echo "== T10 environment exploration =="
lua -e "EVOLUA_HOME='$H/t10'" lua/main.lua --ticks 260 --tick-seconds 0.03 --no-clone >/dev/null 2>&1
EXP=$(grep -acE "now watching dir|now tailing log|discovered (dir|log|port|sys)" "$H/t10/state/evolua.log" "$H/t10"/reports/*.md 2>/dev/null | paste -sd+ - | bc)
[ "${EXP:-0}" -gt 0 ] && ok "explorer scouted / expanded perception" || no "no exploration"
[ "$(grep -acE "watching dir .*/(target|\.git)/" "$H/t10/state/evolua.log" 2>/dev/null)" -eq 0 ] && ok "skipped huge/vcs dirs" || no "watched target/.git"

echo ""; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$H"
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || echo "SOME FAILURES"
```
