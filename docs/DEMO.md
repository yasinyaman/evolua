# EvoLua — annotated demo run

This is a **real, unedited capture** of a single bounded run of the current binary, so a reviewer
can see what the organism actually does without running it. Reproduce it with:

```bash
cargo build --release
EVOLUA_WATCHDOG_SECS=2 ./target/release/evolua \
  --ticks 300 --tick-seconds 0.2 --clone --clone-ignore-battery --no-synth
# then inspect the data home (macOS: ~/Library/Application Support/EvoLua; or choose one with
# EVOLUA_HOME=/tmp/evolua-demo) — especially state/evolution.log, state/repertoire.txt, colony/lineage.log
```

> `--clone` enables self-replication; `--clone-ignore-battery` lets it spawn on a laptop on
> battery; `--no-synth` keeps the brain from writing organs during the demo (that part is shown
> from a separate run in §8). Everything in §1–7 was produced by one 7-minute run on a MacBook Air
> (arm64, 8 GB) on 2026-10-12 — ticks are slow here because the brain is a 1.5B model running
> in-process on the CPU.

---

## 1. Boot — it finds a brain and wakes up with inherited body parts

```
spawned organ 'gen_colony_1'     from <colony>
spawned organ 'gen_supervisor_1' from <supervisor>
spawned organ 'gen_explorer_1'   from <explorer>
spawned organ 'gen_rule_1'       from <rule>
EvoLua booting — mode=free
brain: qwen2.5-coder:1.5b — bigger than the default, found on this machine: ollama (gguf, 1.5B)
sense organ online: sys_metrics — perceives CPU / memory / load and emits metric.* stimuli
sense organ online: logwatch — tails log files and emits log.error stimuli on matches
sense organ online: fswatch — watches directories and emits fs.change stimuli
sense organ online: introspect — perceives the organism's own state; emits self.heartbeat
sense organ online: proc_top — perceives per-process CPU/RAM; emits proc.hot / proc.sample
sense organ online: proc_errors — perceives OS errors/crashes attributed to a process
sense organ online: curiosity — actively profiles the least-known process
awoke with 4 organ(s), generation 4
```

The binary carries no model. No API key was in the environment, so the organism looked at the
machine, found the GGUF that Ollama had pulled for another tool, checked that it fits a quarter
of physical RAM, loaded it and thought with it for the whole life — every reasoner decision came
from the model, none fell back to rules (`llm_ok = 37 · llm_fallback = 0` in `state/memory.lua`).
With a `GROQ_API_KEY` (or any provider key in `keys/`) the first line would read `… via groq [free
tier]` instead; with nothing on the machine either it would use the keyless public endpoint, then
rules. See README → *Decision brain*.

The foundational organs — colony, supervisor, explorer, an evolvable rule organ (and, without
`--no-synth`, the synthesizer) — are seeded once; they are protected singletons that no drive
can duplicate.

## 2. Perception — an entity-based world model

By tick 300 the organism had reached generation 26 with 15 living organs, and its periodic report
looked like this (the OS error log is the dominant pressure on this host):

```
# EvoLua report — 2026-10-12 00:30:40
- mode: free · trigger: periodic
- tick: 300 · generation: 26 · organs: 15 · brain: qwen2.5-coder:1.5b (gguf), 1.5B

## Situation — what's happening on the system (rule-based)
| entity   | cpu | mem (MB) | errors | hot (ticks) | trend | salience |
|----------|----:|---------:|-------:|------------:|:-----:|---------:|
| system   |   0 |        0 |   2425 |           0 |   →   |    36375 |
| qtn_proc |   0 |        0 |    774 |           0 |   →   |    11610 |
| Sandbox  |   0 |        0 |    134 |           0 |   →   |     2010 |
| error    |   0 |        0 |    100 |           0 |   →   |     1500 |
```

The brain read the same snapshot and routed growth to the right blueprint:

```
reasoner: situation on 'error_reporter' → growing <error_reporter> (conf 0.90)
reasoner: situation on 'load_guard'     → growing <load_guard>     (conf 0.82)
```

## 3. Evolution engine — a real genetic system, not numeric tuning

Because errors dominated, the evolver grew several `error_reporter` organs (under selection —
weak ones retired; the seeded `rule` organ was itself culled before tick 300). But the engine
does far more than tune one template: **honest fitness** rewards filling a starved stimulus (not
an organ's self-declared number), **MAP-Elites** keeps a diverse repertoire, and a **UCB bandit**
proactively tries templates the reactive need-drive never would.

**Per-generation metrics** (`state/evolution.log`) — population, fitness spread, distinct
species, MAP-Elites coverage, and the reasoner's rule-fallback rate (0.000 all life):

```
tick  gen  pop  mean    max     min    stddev  species  cells  fallback
3     4    4    1.750   3.999   1.000  1.299   4        4      0.000
27    8    8    5.009   21.503  0.784  6.679   7        6      0.000
45    12   11   6.552   35.163  0.760  9.862   8        8      0.000
81    16   13   9.258   57.311  0.653  14.715  9        9      0.000
```

**The MAP-Elites repertoire** (`state/repertoire.txt`) — the best organ kept per behavior niche.
Note the `metric.cpu/load/mem` guards: those sensors are **silent on macOS**, so the reactive
drive never grows them — they exist only because the **bandit** tried each template, and
MAP-Elites **preserves them as low-fitness-but-unique elites** (scalar selection would cull them):

```
# MAP-Elites repertoire @tick 300 — 9 cells filled
colony.message#2     gen_colony_1          8.31
env.discovery#2      gen_explorer_1        5.83
fs.change#1          gen_fs_journal_2      4.70
host.vitals#2        gen_supervisor_1     99.67   ← the host's vitals, handled every beat
log.error#1          gen_error_reporter_2 17.85   ← the dominant niche on this host
metric.cpu#1         gen_cpu_guard_4       0.61    ┐ bandit-explored; never fires on macOS,
metric.load#1        gen_load_guard_5      0.44    │ yet kept as a diverse repertoire entry
metric.mem#1         gen_mem_guard_3       0.19    ┘
self.heartbeat#1     gen_vital_monitor_3  27.86
```

The `rule` template renders a typed rule list into *only* safe primitives (no `os`/`io`;
capability-isolated by construction) — a genome like
`when self.heartbeat if tick >= 10 then report` becomes:

```lua
ctx.bus:subscribe("self.heartbeat", function(ev)
  local d = ev.data or {}
  if (tonumber(d["tick"]) or 0) >= 10 and ready(1) then   -- ready(): at most once per rule_cooldown ticks
    ctx.report(SELF, "rule 1 on self.heartbeat"); return { handled = true, reward = 1 }
  end
  return false
end, SELF)
```

Mutation can flip this rule's stimulus / field / operator / threshold / action (and add or
remove rules); crossover recombines two parents — so one `rule` template differentiates into
many distinct behaviors under selection. (This life's rule organ earned too little against the
error reporters and was retired — selection is honest about that too.)

## 4. Environment exploration — it scouts the host and grows its own senses

The explorer wanders the data home and the working directory and **expands the organism's own
perception** — appending what it finds to the watch lists so the existing sensors start
perceiving them:

```
⌖ [gen_explorer_1] now watching dir /Users/korns/…/evolua/.github
⌖ [gen_explorer_1] now watching dir /Users/korns/…/evolua/docs
```

Other modalities it rotates through: `*.log` files, listening ports (`lsof`), installed
commands on `$PATH`, decision brains already on the host, and `uname`.

## 5. Colony — it replicated and the peers talked

A real peer message (presence ping over the shared `colony/` directory) from the first child,
and the census at the end of the run (children are mortal — only the last one was still alive):

```
[gen_colony_1] <- root-1791753821.15: ping (gen 1, 8 organs) @tick 5
[gen_colony_1] <- root-1791753821.15: ping (gen 1, 8 organs) @tick 10

peers: root-1791753821.300
```

## 6. Intelligent split + goal acquisition + S4 learning

It divided only under load (the clone cooldown is 30 s of wall clock, so six splits in seven
minutes), and each child was **born specialized** to a crystallized goal. Watch the rationale
evolve from optimistic guesses, through an exploration probe, to **proven payoff** — the colony
learning which purposes pay (S4). Each child also inherits the parent's tuned genes for that
goal (`⇓genes`):

```
# colony/lineage.log
15   root-1791753821.15  gen=1 purpose: report errors [untried (optimistic)]  ⇓genes:error_reporter
60   root-1791753821.60  gen=1 purpose: file changes  [untried (optimistic)]  ⇓genes:fs_journal
90   root-1791753821.90  gen=1 purpose: file changes  [untried (optimistic)]  ⇓genes:fs_journal
165  root-1791753821.165 gen=1 purpose: file changes  [explore probe (gap)]   ⇓genes:fs_journal
210  root-1791753821.210 gen=1 purpose: report errors [proven avg=25.7 n=1]   ⇓genes:error_reporter
300  root-1791753821.300 gen=1 purpose: report errors [proven avg=29.1 n=2]   ⇓genes:error_reporter
```

The children harvested how well their purpose paid off into the colony's outcome ledger — and
the numbers explain the choice: "report errors" pays 25–32 on this host, "file changes" pays 4:

```
# colony/outcomes/<id>
purpose=report errors  payoff=25.70
purpose=file changes   payoff=4.06
purpose=file changes   payoff=4.02
purpose=file changes   payoff=3.76
purpose=report errors  payoff=32.47
purpose=report errors  payoff=24.06
```

A specialized child boots **directed**, finds the same brain, and grows exactly its goal's
organ from the inherited genes:

```
EvoLua booting — mode=directed goal="report errors"
brain: qwen2.5-coder:1.5b — bigger than the default, found on this machine: ollama (gguf, 1.5B)
directive 'report errors' → growing <error_reporter> with INHERITED genes
```

## 7. The host-side supervisor (the "brainstem")

The Rust watch thread observed liveness + vitals and wrote them for the Lua side to react to:

```
# state/vitals
at=1791754240  stall=0  heartbeat_age=0  self_rss_mb=955  colony_procs=1

# state/supervisor.log
supervisor online (interval=2s stall=30s kill=false)
```

`self_rss_mb=955` is the 1.5B model resident in the process; `colony_procs=1` is the real
number of live colony processes the host saw at that moment — something the Lua side can't
cheaply measure about itself. Health of the run: `load/attach failures: 0 · fatal errors: 0`.

---

## 8. Synthesis — the brain writes an organ (a different run, same day)

Templates are the floor. For a goal no blueprint covers, the `synth` organ asks the brain to
write a whole organ against the real output of the commands it names, dry-runs it, pre-flights
its parser column by column, and repairs the slips a small model repeats. This excerpt is from
the GB10 trials (`docs/TRIALS.md`, round 5c): a Turkish goal, a 7B model served by Ollama:

```
brain: qwen2.5:7b-instruct via http://127.0.0.1:11434/v1 — online service, budget 300 calls
✎ [gen_synth_1] need (goal): disk doluluğunu izle, hızla dolan bölümleri raporla
✎ [gen_synth_1] brief: Observe disk usage; report an anomaly if the `df -h` command shows more than 90% disk usage …
✎ [gen_synth_1] auto-fixed 4 known slip(s) (tonumber(gsub) / table.find) before the dry run
✎ [gen_synth_1] goal 'syn_disk_dolulugunu_1' try 1: compiles (50s)
✦ [gen_synth_1] synthesized organ 'syn_disk_dolulugunu_1' ← "disk doluluğunu izle, hızla dolan bölümleri raporla"
```

What it wrote (head of `plugins/syn_disk_dolulugunu_1.lua`) — the column recipe from the
prompt, the unit stripped before `tonumber`, the inner parentheses added by the organism:

```lua
local function parse_df(line)
  local f = {}
  for w in line:gmatch("%S+") do f[#f+1] = w end
  local size        = tonumber((f[2]:gsub("[^%d%.]", "")))
  local used        = tonumber((f[3]:gsub("[^%d%.]", "")))
  local avail       = tonumber((f[4]:gsub("[^%d%.]", "")))
  local use_percent = tonumber((f[5]:gsub("[^%d%.]", "")))
  return { size = size, used = used, avail = avail, use_percent = use_percent }
end
```

And what selection did with it: the organ reported "93% used" every eight seconds (the brief had
turned "filling fast" into a threshold, and that disk sits at 93%), the report-value rule counted
it as noise, and it was retired after its grace — with that verdict fed into the next attempt.
The loop's safeguards remove the mechanical failures; what remains is the model's logic, and the
organism reaches a stronger model as soon as a key or a bigger served model is available.

## 9. Mesh — a colony across two machines (a different run, same day)

With `--mesh` the colony's file protocol crosses hosts. A MacBook and the GB10 found each other
over Tailscale with one seed each; the Mac's gene-pool entry and purpose outcome were on the GB10
four seconds later, and the GB10's came back in the same round:

```
# gb10: state/mesh.log
mesh up: id=gb10-node port=7707 seeds=["100.75.73.106:7707"] token=false gateway=false
peer discovered: mac-node at 100.75.73.106:7707 (Yasins-MacBook-Air.local)
sync: genepool/cpu_guard received
sync: genepool/error_reporter received
sync: outcomes/mac-node received

# gb10: colony/genepool/cpu_guard   (planted on the Mac, adopted because fitter)
fitness 77
genes every 9
sigma every 0.25

# mac: state/mesh.log
peer discovered: gb10-node at 100.111.119.48:7707 (gx10-0587)
sync: genepool/supervisor received
sync: outcomes/gb10-node received
```

The organ on either side did not change: it reads `colony/peers`, `colony/genepool` and
`colony/outcomes` exactly as before — horizontal gene transfer and purpose learning now span
the mesh. Details: [COLONY.md → Across hosts](COLONY.md#across-hosts--the-mesh-opt-in---mesh).

---

## Reproducibility & tests

This walkthrough is one run; behavior varies with the host environment (it reacts to whatever
the machine offers, and to whichever brain it can reach). The repeatable verification is the
bounded suite in [TESTING.md](TESTING.md) — **27 checks, all green** — covering build, unit
tests, CLI, base run, colony comms, intelligent split, purpose crystallization, power-aware
hold-off, generalist clones, the supervisor roundtrip, cross-life memory, S4 purpose-learning,
environment exploration and disabled templates.

Deep-dive on the colony / supervisor / purpose / exploration layer: [COLONY.md](COLONY.md).
The synthesis trials: [TRIALS.md](TRIALS.md).
