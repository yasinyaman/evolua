#!/usr/bin/env bash
# Bounded behavior suite: runs the organism in several configurations under
# throwaway data homes and asserts on the artifacts it leaves. docs/TESTING.md
# says what each check proves.
#
#   scripts/fulltest.sh               # exit 0 = all green
#   LUA=lua5.4 scripts/fulltest.sh    # choose the interpreter (default: lua)
#
# Most checks use plain Lua (fast, no rebuild); T7 needs the compiled binary
# because the host-side watch thread only exists there. T5 only means
# something on battery power and is skipped otherwise.
set -u
cd "$(dirname "$0")/.."
LUA=${LUA:-lua}
NOANSI='s/\x1b\[[0-9;]*m//g'
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS — $1"; PASS=$((PASS+1)); }
no()   { echo "  FAIL — $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP — $1"; SKIP=$((SKIP+1)); }

H=$(mktemp -d "${TMPDIR:-/tmp}/evolua_ft.XXXXXX")
# clones are separate processes whose command line carries --colony-root "$H/…";
# let them finish (they are mortal) before the homes are deleted
reap() {
  for _ in $(seq 60); do pgrep -f "$H" >/dev/null 2>&1 || break; sleep 1; done
  rm -rf "$H"
}
trap reap EXIT

# run the organism in plain Lua with its own home: life <home> <flags…>
life() { local home=$1; shift; EVOLUA_HOME="$H/$home" "$LUA" lua/main.lua "$@" >/dev/null 2>&1; }
log()  { sed "$NOANSI" "$H/$1/state/evolua.log" 2>/dev/null; }
count_files() { ls "$1" 2>/dev/null | grep -cE "$2"; }

on_battery() {   # 0 = on battery; 1 = on AC power or unknown
  if command -v pmset >/dev/null 2>&1; then pmset -g batt 2>/dev/null | grep -q "Battery Power"; return; fi
  for f in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
    [ -r "$f" ] && { [ "$(cat "$f")" = 0 ]; return; }
  done
  return 1
}

echo "== T0 cargo build =="
cargo build 2>&1 | tail -n1
[ -x target/debug/evolua ] && ok "binary built" || no "binary missing"

echo "== T0b unit tests =="
"$LUA" tests/run.lua | tail -n1 | grep -q " 0 failed" && ok "lua tests/run.lua" || no "lua unit tests"
cargo test --quiet >/dev/null 2>&1 && ok "cargo test" || no "cargo test"

echo "== T1 CLI =="
"$LUA" lua/main.lua --help 2>&1 | grep -qE -- "--clone" && ok "help lists colony flags" || no "missing flags"
"$LUA" lua/main.lua --ticks abc >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad value exits 2" || no "bad value accepted"

echo "== T2 base free-mode run =="
life t2 --ticks 40 --tick-seconds 0.05 --no-clone
ORG=$(count_files "$H/t2/plugins" '\.lua$')
ERR=$(log t2 | grep -ciE "fatal|attach failed|load failed")
[ "$ORG" -gt 0 ] && ok "grew $ORG organs" || no "no organs"
[ "$ERR" -eq 0 ] && ok "no load/attach failures" || no "$ERR load/attach failures"

echo "== T3 colony beacon =="
[ "$(count_files "$H/t2/colony/peers" .)" -gt 0 ] && ok "beacon written" || no "no beacon"

echo "== T4 intelligent split + purpose =="
life t4 --ticks 200 --tick-seconds 0.06 --clone --clone-ignore-battery; sleep 1
log t4 | grep -E "splitting under load" | grep -q "purpose:" && ok "split crystallized a purpose" || no "no purpose"
CH=$(ls -d "$H/t4"/colony/children/*/ 2>/dev/null | head -n1)
[ -n "$CH" ] && grep -q "mode=directed" "$CH/state/evolua.log" && ok "child booted directed" || no "child not directed"
[ -f "$H/t4/colony/lineage.log" ] && ok "purpose ledger written" || no "no ledger"

echo "== T5 power-aware hold-off =="
if on_battery; then
  life t5 --ticks 60 --tick-seconds 0.06 --clone
  log t5 | grep -q "holding off" && ok "held off (power-aware)" || no "no hold-off"
  KIDS=$(ls -d "$H/t5"/colony/children/*/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$KIDS" -eq 0 ] && ok "no clones on battery" || no "$KIDS clones on battery"
else
  skip "on AC power (or unknown) — the battery guard isn't exercised"
fi

echo "== T6 generalist clones =="
life t6 --ticks 120 --tick-seconds 0.06 --clone --clone-ignore-battery --clone-generalist; sleep 1
grep -q "generalist" "$H/t6/colony/lineage.log" 2>/dev/null && ok "generic clones" || no "expected generalist"

echo "== T7 supervisor roundtrip =="
EVOLUA_HOME="$H/t7" EVOLUA_WATCHDOG_SECS=2 ./target/debug/evolua --ticks 70 --tick-seconds 0.2 >/dev/null 2>&1
[ -f "$H/t7/state/vitals" ] && ok "host wrote vitals" || no "no vitals"
grep -q "supervisor online" "$H/t7/state/supervisor.log" 2>/dev/null && ok "supervisor.log online" || no "no supervisor.log"
grep -qrE "vitals: rss=" "$H/t7/reports/" 2>/dev/null && ok "Lua surfaced vitals" || no "not surfaced"
grep -q "colony_procs=1" "$H/t7/state/vitals" 2>/dev/null && ok "one instance counted once" || no "colony_procs != 1"

echo "== T8 reincarnation =="
life t8 --ticks 60 --tick-seconds 0.02 --no-clone
life t8 --ticks 60 --tick-seconds 0.02 --no-clone
log t8 | grep -oE "awoke with [1-9]" | tail -n1 | grep -q "awoke" && ok "memory persists" || no "no inheritance"
for t in colony supervisor explorer; do
  N=$(count_files "$H/t8/plugins" "^gen_${t}_[0-9]+\.lua$")
  [ "$N" -eq 1 ] && ok "one $t after two lives" || no "$N $t organs (protected organs are singletons)"
done

echo "== T9 S4 purpose-learning =="
# "proven" needs the third split at the earliest (the first two try the untried goals on the
# optimistic prior); with child boot + the clone cooldown, 360 ticks gave only two splits on a
# slow CI runner, so this life is longer
life t9 --ticks 600 --tick-seconds 0.04 --clone --clone-ignore-battery; sleep 1
[ "$(count_files "$H/t9/colony/outcomes" .)" -gt 0 ] && ok "children harvested payoff" || no "no outcome ledger"
grep -qE "proven avg=" "$H/t9/colony/lineage.log" 2>/dev/null && ok "later splits chose by proven payoff" || no "no learning"

echo "== T10 environment exploration =="
life t10 --ticks 260 --tick-seconds 0.03 --no-clone
EXP=$(cat "$H/t10/state/evolua.log" "$H/t10"/reports/*.md 2>/dev/null | sed "$NOANSI" \
      | grep -cE "now watching dir|now tailing log|discovered (dir|log|port|sys)")
[ "${EXP:-0}" -gt 0 ] && ok "explorer scouted / expanded perception ($EXP)" || no "no exploration"
[ "$(log t10 | grep -cE "watching dir .*/(target|\.git)(/|$)")" -eq 0 ] && ok "skipped huge/vcs dirs" || no "watched target/.git"

echo "== T11 disabled templates =="
life t11 --ticks 120 --tick-seconds 0.02 --no-clone --no-colony --no-supervisor --no-explorer --no-rule
N=$(count_files "$H/t11/plugins" "^gen_(colony|supervisor|explorer|rule)_")
[ "$N" -eq 0 ] && ok "no disabled template grew" || no "$N organs of disabled templates"

echo ""
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || echo "SOME FAILURES"
[ "$FAIL" -eq 0 ]
