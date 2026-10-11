# Trials — can the brain write a working organ for a goal it has never seen?

This is the evidence behind the claim that templates are only the *floor*. Each trial gives the
organism a **goal in Turkish on a topic no template covers**, lets it run for 360 ticks
(0.5 s/tick), and injects a **real perturbation** on the host mid-run. We then read what the
`synth` organ (see `CLAUDE.md` → *Synthesis*) actually wrote, whether the organ noticed the
perturbation, and whether selection kept it.

All trials were run on **2026-10-11** on `gb10` — an NVIDIA GB10 (aarch64, Ubuntu 24.04,
121 GB) — thinking through the local Ollama server's `qwen2.5:7b-instruct(-q8_0)`. In rounds 1–4 the
organism picked it by itself (the then-current provider list tried a local Ollama server first);
since the merge a local server is a *machine* brain and the biggest served model wins, so round 5
named it explicitly (`--llm-api http://127.0.0.1:11434/v1 --llm-model qwen2.5:7b-instruct`) to keep
the rounds comparable. The Mac runs of the same loop with 1.5B/3B local GGUFs are summarised at the
end for contrast. Scripts: `gb10_trials.sh` (in the session
scratchpad; each trial = goal + perturbation function).

| # | goal (as given) | topic | perturbation on the host |
|---|---|---|---|
| 1 | *disk doluluğunu izle, hızla dolan bölümleri raporla* | disk | `dd` a 3 GB file, then delete it |
| 2 | *açık dinleyen portları izle, yeni açılan portları raporla* | network listeners | `python3 -m http.server 48321`, then kill it |
| 3 | *çalışan docker konteynerlerini izle, başlayan ve duranları raporla* | containers | `docker run --rm -d alpine sleep 100`, then `docker rm -f` |
| 4 | *sistem günlüğündeki hataları izle, yeni hata dalgalarını raporla* | system log | 12× `logger -p user.err …` |
| 5 | *giriş yapmış kullanıcı oturumlarını izle, yeni oturumları raporla* | sessions | an extra `ssh localhost` session |

## Round 1 — before the selection fix

What the model did with each goal (the *brief* is the one-sentence technical translation the
synth organ asks for first; the *organ* is what it then wrote):

**1 · disk.** Brief: *observe `df -h`, anomaly above 90 %*. Organ: parses `df -h` rows and
compares used/size. **Crashed every tick** on a classic Lua slip —
`tonumber(size:gsub("G","000"):gsub("K",""))` passes `gsub`'s second return value (the count) to
`tonumber` as a *base* → `bad argument #2 to 'tonumber' (base out of range)`. Two repair rounds
reproduced the same bug; the organ was retired as unrepairable, and the next attempts were then
**refused by the same-approach guard** because they used `df -h` again — the approach was right,
only the code was wrong.

**2 · ports.** Brief: *baseline the output of `netstat -an -p tcp` / `lsof -nP -iTCP`, report new
ports*. Three parser drafts were rejected by the **pre-flight** (patterns written for a different
`netstat` layout matched 0 of 40 real lines). The fourth draft counted `^tcp.*LISTEN` lines against
a baseline — and it **worked**:

```
14:08:18  [perturb] http.server on :48321 started
14:08:19  syn_acik_dinleyen_2 → "new open ports 20 -> 21"
14:09:48  [perturb] server killed
14:09:57  syn_acik_dinleyen_4 → "new open ports 21 -> 20"
```

Both organs were nevertheless **retired for low fitness** about a minute after their finding.
That is the round-1 lesson: a correct *rare-event* detector reports once a minute, earns one
small reward, and loses it again to idle decay before the next event — the selection pressure that
is right for busy reflexes kills watchers.

**3 · docker.** Brief: *`docker ps -a --format "{{.State}} {{.ID}} {{.Image}}"`, report started /
stopped*. Organ: right command, right idea (diff container IDs against a baseline), but it
appended every sample to one growing list and built an empty message; no report. It was culled
**before the perturbation even started** — the organ was born at 12 s, the container at 120 s,
and 120 ticks of grace at 0.5 s/tick is ~1 minute.

**4 · logs.** Brief: *`grep -i error /var/log/syslog` or `journalctl -b | grep -i error`*. Organ:
a count-based watcher over `journalctl`. `journalctl`/`grep` were not in the tool list the
fingerprint uses, so the attempt was recorded as "ran NO shell command" and every later attempt
was refused as a repeat. Culled before the perturbation (same timing problem).

**5 · users.** Brief: *`who` and `w`*. Organ: `who` line count against a baseline — the simplest
correct answer. The perturbation itself failed (the nested `ssh localhost` exited at once inside
the detached suite), so there was nothing to detect; culled on timing.

Across all five: the **reasoner** (decision brain) ran at 43–45 valid LLM decisions per trial with
0–2 rule fallbacks — the 7B model over the OpenAI-compatible endpoint is a usable brain for the
organism's own decisions, which no local model on the 8 GB Mac had achieved.

### What round 1 changed in the code

- A finding is worth more: `report_reward` 1 → 4, and the reporter keeps a **per-organ findings
  ledger** (`memory.valued[organ]`). Both the synth's own selection and the evolver's cull **spare a
  model-written organ that has produced a finding** — it is doing its job between events.
- The **same-approach guard** no longer bans an approach whose organ *crashed* (that is a coding
  slip to repair, not a wrong approach); it bans only approaches that ran and earned nothing.
- The tool list used to recognise "the sensing command" (and to pre-flight it) grew: `docker`,
  `journalctl`, `grep`, `tail`, `dmesg`, `nvidia-smi`, …
- Repair hints name the two Lua slips seen most: `gsub` returns two values; `pcall(io.popen, …)`
  returns `ok, handle`.
- Trial timing: the perturbation now comes in **two pulses** (60 s and 110 s after launch) so an
  organ born at ~15 s sees one inside its grace, and a second-attempt organ sees the other.

## Round 2 — after the selection fix

Same five goals, same brain, perturbation in two pulses.

**2 · ports — the goal is met.** Second draft (the first was cut off before the spec table):
count `LISTEN` lines of `netstat -an -p tcp` against a baseline, report the change, emit
`ports.change`. It caught **both pulses** and **survived the whole run**:

```
16:21:37  [perturb] http.server on :48321 started      16:22:27  [perturb] killed
16:22:27  syn_acik_dinleyen_1 → "new open ports 100 -> 99"
16:24:17  [perturb] started again                       16:25:07  [perturb] killed
16:25:07  syn_acik_dinleyen_1 → "new open ports 100 -> 99"
```

Its fitness stayed low (3.0 — a watcher that reports twice in five minutes handles almost nothing
on the bus) but the findings ledger now exempts it from both culls. This is the behaviour the whole
loop exists for: a Turkish one-liner → a working, surviving sensor nobody wrote a template for.

**1 · disk — still a coding slip.** The organ now closed the `df -h` handle and *then* read it
(`attempt to use a closed file`), and assigned a six-capture `line:match` to one variable. Two
repairs reproduced it; unrepairable. The hints now spell out both slips (read fully, then close;
one variable per capture) — they were missing from the prompt in this round.

**3 · docker — hallucinated API.** `docker ps -q` / `docker ps -a -q` diffed against a baseline,
which is a good design, but implemented with `table.findsub(...)`, which does not exist in Lua.
Unrepairable twice. Hint added: there is no `table.find/contains/indexOf` or `string.split`.

**4 · logs — the detector was right, the test was wrong.** The organ piped `grep -i error
/var/log/syslog; journalctl -b | grep -i error` and counted error-looking lines. It saw nothing,
for two reasons that are not its fault: `/var/log/syslog` is unreadable to this user (no `adm`
group), and the injected lines said *"simulated failure"* — no "error" in them. Round 3 injects
`ERROR` lines. (Culled for no fitness: correct behaviour given no findings.)

**5 · users — the test was wrong again.** `who`-count against a baseline (second attempt `w`),
exactly right; but the extra session never opened — `ssh localhost` inside the detached suite had
no key to offer (exit 255 both pulses). Round 3 uses a dedicated trial key.

Every trial again produced 43–45 valid reasoner decisions with ≤2 fallbacks.

## Round 3 — fixed tests, extended hints

Same goals; the logs and sessions perturbations now actually happen; the prompt carries the Lua
slips seen in rounds 1–2. gb10 was under memory pressure during this round (108 of 121 GB in
use by other workloads), so Ollama answered in 20–37 s instead of 8–12 s and the reasoner's
fallback rate rose (27 ok / 9 fallback in the logs trial vs 43 / 2 before).

**5 · sessions — the goal is met.** `who` line count against a baseline (the second attempt;
the first was retired before the first pulse). It caught the extra ssh session opening and
closing in both pulses — and then caught the operator's own cleanup session a minute later:

```
17:21:18  [perturb] ssh session opened         17:21:20  "giriş yapmış kullanıcı sayısı 5 -> 6"
17:22:19  [perturb] session closed             17:22:20  "giriş yapmış kullanıcı sayısı 6 -> 5"
17:24:02  (operator logs in to clean up)       17:24:02  "… 5 -> 6"   17:24:07  "… 6 -> 5"
```

**4 · logs — detected, then penalised.** Both organs counted error lines from `journalctl -b`
(the unreadable `/var/log/syslog` simply contributed nothing) and tracked the injected wave as it
grew, in near real time: `hata sayısı 839 → 848 → 850 → 851` during pulse 1 and
`107 → 109 → … → 114` during pulse 2. Both were then retired for low fitness: a wave produces
several same-shape reports a few seconds apart, which the stale-report rule scored as noise, and
the findings exemption required "more findings than noise". That is a scoring bug, not a sensing
one — fixed after this round: an organ is *working* while `stale ≤ 4 × valued`, since a wave
detector reports a bounded few times per wave and a garbage reporter reports forever.

**2 · ports — alive, but noisier.** This round's draft counted all `^tcp` lines (every
connection) instead of `LISTEN` lines, so it reported the connection count flickering every few
seconds. The findings exemption kept it alive anyway — the same bounded-ratio rule now stops
that: a chatterbox with a few lucky hits is no longer spared.

**1 · disk — still a slip.** `pcall(io.popen, …)` handled correctly this time, but `close` was
called on the wrong value; the evolver culled it mid-repair, and the cull was recorded as "earned
nothing", which banned the (correct) `df -h` approach for the rest of the run. Fixed: a culled organ
that had been throwing is recorded as a crash, and crashes never ban an approach.

**3 · docker — hallucinated API, again.** `table.find` this time, despite the hint that no such
function exists; both attempts unrepairable, and with 35 s per call the run hit its 480 s wall
before a third. This is the one goal where the 7B model's Lua, not the loop, is the limit — a
larger coder model is the fix, not more prompt.

## Round 4 — dry run + goal-first (logs and ports only)

Two more changes went in before this short round: every model-written organ is now **run once
before installation** (two synthetic heartbeats against real payloads, in a sandbox — `cfg.dryrun`),
and while a goal's organ has no finding yet, no synthesis budget goes to side needs.

- The dry run **caught runtime slips before installation** in both trials (`handler for
  'proc.sample' threw on tick 20`, `… 'anomaly.report' threw on tick 10`) and the retry fixed one of
  them on the next attempt — seconds instead of the minute-plus repair cycle of rounds 1–3.
- **ports**: the organ survived the whole run, but as a *delta-of-connection-count* reporter
  ("new open ports: 4", "-2", "-30") every ~8 s — noise that the scoring counted as findings
  because 8 s is longer than the 15-tick stale window at 0.5 s/tick. The noise/finding split by
  timing alone has reached its limit; the honest next step is a *semantic* check (does the report
  correlate with a host event the organism can see?), not another threshold.
- **logs**: this round's draft produced nothing and was retired; the round-3 draft had worked. Same
  model, same prompt — a 7B model's output varies run to run, which is exactly why selection, not
  the first draft, has to carry the result.

## What four rounds showed

| goal | round 1 | round 2 | round 3 |
|---|---|---|---|
| disk | crash (`gsub` two returns) | crash (read after close) | crash (`close` on wrong value) |
| ports | **detected**, then culled | **detected both pulses, survived** | alive, too noisy |
| docker | culled before perturbation | hallucinated `table.findsub` | hallucinated `table.find` |
| logs | culled before perturbation | detected nothing (test bug) | **detected both waves**, then culled (scoring bug, fixed) |
| sessions | test bug (no session) | test bug (no key) | **detected both sessions, survived** |

- Every goal was translated into the right **observation strategy** on the first brief: `df`,
  `netstat`/`lsof`, `docker ps`, `journalctl`, `who`. Comprehension of a Turkish one-liner is not the
  bottleneck with a 7B instruct model.
- Three of five goals produced an organ that **detected the real perturbation** with the right
  numbers at the right second. Two of those survived selection in the round where the scoring was
  right.
- The failures are **Lua slips** (two-value returns, handle lifetime, invented library functions)
  and **selection scoring** for rare-event watchers. The loop's safeguards caught every slip
  (pre-flight, repair with the failing line, bounded sampling), and each round's scoring bug became
  a rule — the next model-written watcher inherits them.
- The 8 GB laptop with 1.5B/3B local models never got this far; a served 7B does; the docker trial
  says a larger coder model would close the remaining gap. The organism does not care which: it
  picks the best brain it can reach and fails over when it can't.

## Round 5 — the merged binary: column check, unit map, mechanical repairs (disk and docker)

Run 2026-10-11 evening on the GB10 after the brain-sourcing line was merged onto `feat/local-brains`,
same two goals that had never produced a working organ, brain `qwen2.5:7b-instruct` over Ollama
(`--llm-api http://127.0.0.1:11434/v1`). Three passes, each one teaching the loop something; the
synth organ changed between passes, the model did not.

| pass | disk | docker |
|---|---|---|
| 5a (column check + column map) | organ installed on attempt 5 — split the line with `gmatch("%S+")`, took `f[5]`… and `tonumber("94%")` is nil: silent for its whole grace, retired; the same-approach guard then blocked the right fix 3× ("df -h + %S+" fingerprinted the same) | 12 rejections in a row, all `table.find` (told "no table.find" each time); organ on attempt 13, correct (`docker ps -q` counts, baseline, diff) but born after both pulses |
| 5b (units in the column map, conversion in the fingerprint, a lesson per slip) | 15 rejections, all `tonumber(f[5]:gsub(...))` — the model took the unit lesson and dropped the inner parentheses every single time | organ on attempt 6; reported once at the first run (the baseline echo: "16 stopped: …"), missed the start/stop, retired as noise |
| 5c (mechanical repairs: `tonumber((…))`, `__array_find`) | **organ on attempt 1** (`auto-fixed 4 known slips`), parses every `df` field correctly — and reports "93% used" every 8 s: the brief said *anomaly = above 90 %* and this disk sits at 93 %; the noise rule retired it (38 stale reports); a 3 GB write can't move the percent of a 916 GB disk anyway | organ on attempt 2 (`auto-fixed 2`), `docker ps -q` + `__array_find` + diff — called `__array_find(running_ids, id, last_running_ids)`: searched the wrong list, found every id, reported nothing |

What this pass settled:

- **Mechanical repairs beat lessons.** Thirty-plus rejections across 5a/5b were two slips with one
  fix each; a 7B model does not apply the fix when told, but the organism can apply it itself.
  After 5c the model's attempts are judged on the organ's *logic*, where the real 7B limit is: the
  wrong list in a diff, a threshold where a change was asked for.
- **The pre-flight now catches what it was built for**: `([%d%.]+)` was rejected as "pieces of
  fields, not whole fields" with the column map; `^(%d+)` as fitting 0 of 9 real lines.
- **The brief can be the trap.** "Report an anomaly if above 90 %" on a host already at 93 % is a
  constant alarm; the report-value rule correctly culled it, but the goal (*hızla dolan* — filling
  fast) asks for a *rate*, and the brief lost that. The disk test itself is also too small for its
  instrument: 3 GB is 0.3 % of this disk.
- **The dry run and the tick loop**: three model calls of ~30 s each block the organism for 90 s;
  the host watchdog flagged it STALLED (`hb_age=88s`) once per pass. Known, documented, still true.
- Rounds 1–4 and this one agree on the shape of the gap: the loop's safeguards remove the
  mechanical failures one class at a time; what remains needs a stronger coder model than 7B, and
  the organism reaches one as soon as a key or a bigger served model is available.

## For contrast: the same loop on an 8 GB laptop

The Mac runs (`qwen2.5-coder` 1.5B and 3B GGUFs found in Ollama's store, CPU/Metal) showed where
the floor is: 1.5B copies whatever example it is shown (a `df` example became a `df` parser for a
load-average goal) and cannot turn "load" into parsing a load-average column even with the real
`iostat` output in front of it; 3B picks the right command (`lsof` over a `netstat` that printed no
TCP table inside `io.popen` on that host) but mis-parses padded tables. Every mechanical safeguard
in the loop — bounded sampling, pre-flight, same-approach guard, repair with the failing line —
came out of those runs. With a hosted/served 7B the loop produces working organs; the remaining
failures are Lua slips and timing, not comprehension.
