# EvoLua — annotated demo run

🇬🇧 English · [🇹🇷 Türkçe](DEMO.tr.md)

This is a **real, unedited capture** of a single bounded run, so a reviewer can see what the
organism actually does without running it. Reproduce it with:

```bash
cargo build --release
EVOLUA_WATCHDOG_SECS=2 ./target/release/evolua \
  --ticks 160 --tick-seconds 0.2 --clone --clone-ignore-battery
# then inspect the data home it printed — especially state/evolution.log + state/repertoire.txt
# (or set EVOLUA_HOME=/tmp/evolua-demo)
```

> `--clone` enables self-replication; `--clone-ignore-battery` lets it spawn on a laptop on
> battery. Everything below was produced by one ~32-second run on macOS (arm64).

---

## 1. Boot — it wakes up with inherited body parts

```
EvoLua booting — mode=free
sense organ online: sys_metrics — perceives CPU / memory / load and emits metric.* stimuli
sense organ online: logwatch — tails log files and emits log.error stimuli on matches
sense organ online: fswatch — watches directories and emits fs.change stimuli
sense organ online: introspect — perceives the organism's own state; emits self.heartbeat
sense organ online: proc_top — perceives per-process CPU/RAM; emits proc.hot / proc.sample
sense organ online: proc_errors — perceives OS errors/crashes attributed to a process
sense organ online: curiosity — actively profiles the least-known process
awoke with 3 organ(s), generation 3
```

The foundational organs — colony, supervisor, explorer, an evolvable rule organ and the synthesizer —
are seeded automatically (no kernel changes — they're genome blueprints in `templates.lua`):

```
spawned organ 'gen_colony_1'     from <colony>
spawned organ 'gen_explorer_1'   from <explorer>
spawned organ 'gen_supervisor_1' from <supervisor>
spawned organ 'gen_supervisor_2' from <supervisor>   ← duplicates: the bug, see the note below
spawned organ 'gen_supervisor_3' from <supervisor>
```

> This capture predates protected organs becoming singletons. The two extra supervisors were
> mutation copies of an organ that topped the leaderboard by handling the `host.vitals`
> stimulus it emitted itself. A current run seeds exactly one colony, explorer, supervisor and synth,
> and the bus gives an organ no credit for its own emits.

## 2. Perception — an entity-based world model

By tick 160 it had grown to generation 9 / 9 organs and wrote situational reports like this
(the OS error log is the dominant pressure on this host):

```
# EvoLua report — 2026-06-21 12:40:13
- mode: free · tick: 160 · generation: 9 · organs: 9

## Situation — what's happening on the system (rule-based)
| entity   | cpu | mem (MB) | errors | hot (ticks) | trend | salience |
|----------|----:|---------:|-------:|------------:|:-----:|---------:|
| system   |   0 |        0 |    779 |           0 |   →   |    11685 |
| qtn_proc |   0 |        0 |    404 |           0 |   →   |     6060 |
| error    |   0 |        0 |     36 |           0 |   →   |      540 |
| Sandbox  |   0 |        0 |     29 |           0 |   →   |      435 |
```

## 3. Evolution engine — a real genetic system, not numeric tuning

Because errors dominated, the evolver grew several `error_reporter` organs (under selection —
weak ones retired). But the engine does far more than tune one template: **honest fitness**
rewards filling a starved stimulus (not an organ's self-declared number), **MAP-Elites** keeps a
diverse repertoire, and a **UCB bandit** proactively tries templates the reactive need-drive
never would.

**Per-generation metrics** (`state/evolution.log`) — population, fitness spread, distinct
species, MAP-Elites coverage — the repertoire filling over time:

```
tick  gen  pop  mean     max      min    stddev  species  cells
3     4    4    1.750    4.000    1.000  1.299   4        4
39    12   12   21.895   217.063  0.737  58.931  6        6
93    18   17   15.166   142.496  0.833  32.251  9        8
```

**The MAP-Elites repertoire** (`state/repertoire.txt`) — the best organ kept per behavior niche.
Note the `metric.cpu/load/mem` guards: those sensors are **silent on macOS**, so the reactive
drive never grows them — they exist only because the **bandit** tried each template once, and
MAP-Elites **preserves them as low-fitness-but-unique elites** (scalar selection would cull them):

```
# MAP-Elites repertoire — 9 cells filled
colony.message#2     gen_colony_1          2.43
env.discovery#2      gen_explorer_1        4.97
fs.change#1          gen_fs_journal_2      5.79
host.vitals#2        gen_supervisor_1     14.55
log.error#1          gen_error_reporter_1 134.77   ← the dominant niche on this host
metric.cpu#1         gen_cpu_guard_1       0.53    ┐ bandit-explored; never fires on macOS,
metric.load#1        gen_load_guard_1      0.89    │ yet kept as a diverse repertoire entry
metric.mem#1         gen_mem_guard_1       0.60    ┘
self.heartbeat#1     gen_rule_2           12.48
```

**An evolved rule-DSL organ** — its genome is a typed rule list rendered into *only* safe
primitives (no `os`/`io`; capability-isolated by construction):

```lua
ctx.bus:subscribe("self.heartbeat", function(ev)
  local d = ev.data or {}
  if (tonumber(d["tick"]) or 0) >= 10 then
    ctx.report(SELF, "rule 1 on self.heartbeat"); return { handled = true, reward = 1 }
  end
  return false
end, SELF)
```

Mutation can flip this rule's stimulus / field / operator / threshold / action (and add or
remove rules); crossover recombines two parents — so one `rule` template differentiates into
many distinct behaviors under selection.

## 4. Environment exploration — it scouts the host and grows its own senses

```
discovered dir:  /Users/korns/Documents/GitHub/evolua/models
discovered port: 6 listeners (ControlCe,Code H,zed)
discovered sys:  Darwin 25.5.0 arm64
discovered tool: 2089 commands on PATH; notable: git,docker,kubectl,python3,node,
                 lua,cargo,rustc,gcc,clang,go,ruby,java,make,cmake,curl,wget,ssh,jq,sqlite3
```

It then **expanded its own perception** — appending what it found to the watch lists so the
existing sensors start perceiving them:

```
now watching dir /Users/korns/Documents/GitHub/evolua/plugins
now tailing log /Users/korns/Documents/GitHub/evolua/state/evolua.log
```

## 5. Colony — it replicated and the peers talked

Live members and a real peer message (presence ping over the shared `colony/` directory):

```
peers: root-1782034428  root-1782034428.135  root-1782034428.75
MSG from root-1782034366.90: ping (gen 1, 5 organs) @tick 5
```

## 6. Intelligent split + goal acquisition + S4 learning

It divided only under load, and each child was **born specialized** to a crystallized goal.
Watch the rationale evolve from a guess to **proven payoff** — the colony learning which
purposes pay (S4):

```
splitting under load [needs=1 hot=4] -> ...135 (gen 1) · purpose: report errors [untried (optimistic)]
splitting under load [needs=1 hot=8] -> ...75  (gen 1) · purpose: report errors [proven avg=617.9 n=1]
splitting under load [needs=1 hot=8] -> ...135 (gen 1) · purpose: report errors [proven avg=312.4 n=2]
```

The children harvested how well their purpose paid off into the colony's outcome ledger:

```
purpose=report errors payoff=617.93 gen=1
purpose=report errors payoff=73.47  gen=1
purpose=report errors payoff=6.92   gen=1
```

A specialized child boots **directed** and grows exactly its goal's organ:

```
EvoLua booting — mode=directed goal="report errors"
directive 'report errors' → growing <error_reporter>
```

## 7. The host-side supervisor (the "brainstem")

The Rust watch thread observed liveness + vitals and wrote them for the Lua side to react to:

```
# state/vitals
stall=0   heartbeat_age=0   self_rss_mb=4   colony_procs=7

# state/supervisor.log
supervisor online (interval=2s stall=30s kill=false)
```

`colony_procs=7` is the real number of live colony processes the host saw at that moment —
something the Lua side can't cheaply measure about itself.

## 8. Health

```
load/attach failures: 0   ·   fatal errors: 0
```

---

## Reproducibility & tests

This walkthrough is one run; behavior varies with the host environment (it reacts to whatever
the machine offers). The repeatable verification is the bounded suite in
[TESTING.md](TESTING.md) — **27 checks, all green** — covering build, base run, colony comms,
intelligent split, purpose crystallization, power-aware hold-off, generalist clones, the
supervisor roundtrip, cross-life memory, S4 purpose-learning, and environment exploration.

Deep-dive on the colony / supervisor / purpose / exploration layer: [COLONY.md](COLONY.md).
