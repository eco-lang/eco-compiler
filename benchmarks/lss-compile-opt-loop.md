# LSS compile-time optimization loop — experiment protocol

This loop implements the steps of `plans/lss-compile-time-optimizations.md` one at a time and
measures each one the only way that matters for compile time: **the compiler containing the
optimization builds itself, and that self-build is what we time.** The details of every step
(mechanism, proposal, risk, evidence) stay in the plan; this file carries the step list, the
method, and the recorded results.

Everything here is native. Never measure on the JS build (13:58 / 10.1 GB native vs 31:13 /
11.8 GB under node on the Sep 3 tree). No census of any kind runs inside a timed leg.

Sibling tracks, same workload: `benchmarks/lss-payoff.md` (whose method this one adapts) and
`benchmarks/lss-opt.md` (Runs A–AV of the substrate/analysis work through 2026-09-10). Their rows
are NOT comparable to rows here: a different binary builds the workload in every row of this loop.

## 0. The steps

Numbering is the plan's implementation order (`plans/lss-compile-time-optimizations.md` §2);
each step is attempted in this order because lower steps are prerequisites of higher ones. Details
live in the plan — this table is number, short name, and the loop entries the plan's §9
specification splits the step into (each sub-entry is its own iteration, §5). "NOT BI" entries
change emission and need Phase 1.5 (the extra bootstrap turn) plus the workload rail.

| step | short name | loop entries (plan §9 specs; BI unless noted) |
|---|---|---|
| base | *(no change — the tree's fixed-point compiler; measured first and again last)* | — |
| 1 | GC-stats timer overhead (measurement hygiene) | `1` |
| 2 | hash-cons equality O(arity) | `2` (= 2a), then optional `2b` (fused `mRecord` hash fold) |
| 3 | transient union-find store | `3a` kernel package + pure twin + pins (not measured), `3b` the measured change; `3b` NOT split further |
| 4 | ground alias-subtree memo (load/classify) | `4b` classify memo, `4a` load memo, optional `4c` zonk memo |
| 5 | direct-state `Unify.unifyS` | `5a` entry + callers (step-10 prerequisite), `5b` combinator layer |
| 6 | flag-residue/dead-arm cleanup | `6` |
| 7 | census bookkeeping off the default path | `7` (= 7a; 7b skipped — cannot move a timed stat) |
| 8 | no `S` copy on pure reads (`UF.peekS`, one write-back) | `8` or `8a`/`8b` |
| 9 | skip ground arrow-free `enrichFromEnv`/`connectTypes` | `9` or `9a` connectTypes / `9b` enrichFromEnv |
| 10 | retire `Step` (direct state + `$sret`) | `10a` NOT BI (codegen; bootstrap turn + rail), `10b`…`10g` BI |
| 11 | one widen per enqueue + memoised `widenSets` | `11a` one widen, `11b` memo; optional `11c` NOT BI; `11a'` fallback |
| 12 | dense `GlobalId` + Int-keyed per-global memos | `12a` facts/ids/memos, `12b` tallies + registry re-key |
| 13 | member identity as Int keys | `13a` non-lambda kinds, `13b` lambda mints |
| 14 | runtime: inline `resolveFast` in `hpointerToPtr` | `14` |
| 15 | `enqueueSpecKeyed` hit path | `15a` BI, or `15b` (moves the widen; bootstrap turn + rail) — depends on step 11 |
| 16 | inference walk: skip set-inert work | `16a` BI (optionally split `16a`/`16a'`), `16b` NOT BI, optional |
| 17 | `Data.HashMap` buckets → array | `17` |
| 18 | string-pattern `case` arms | `18b` backend first (BI), then `18a` Elm (fixed-point gate) |
| 19 | `revMemoSetIfAbsent` | `19` (needs step 3's `3a`), or `19′` (geometric `Array` growth) if step 3 was slid to the end |
| 20 | `Point` equality via `pointKey` | `20`, optional `20b` (Occurs) |
| 21 | member-table Int dicts → `Array`/`BitSet` | `21` or `21a`/`21b` |
| 22 | `specializeLambda`/overlay rebuild waste | `22a` (a+b), `22c`, `22d` |
| 23 | kernel-boundary translation | `23` or `23a`/`23b` |
| 24 | settle chain + Prune walks | `24a`/`24b` |
| 25 | AbiCloning fingerprints and spec scans | `25a` fingerprint + groups, `25b` registry rows + hostGlobal gate |
| 26 | regroup `S` by co-update | `26a` sched, `26b` runMemo, `26c` letCtx, `26d` drv (optional); skip if census < ~10 M `S` copies |

Steps 1 and 14 change the runtime (C++), not the compiler source; they still go through the same
loop — the candidate is the same compiler MLIR lowered against the changed runtime.

## 1. The loop — one iteration per step

Each iteration has an untimed BUILD phase, a timed MEASURE phase (three cold runs), a VERDICT,
and — only on a win — a GATE phase before the step is kept.

**The reference row is always the last WIN.** Every step is judged on its INCREMENTAL change
against the last kept compiler's medians: on a win the change stays and its medians become the
reference for the next step; on a loss the change is reverted and the reference does NOT move — the
next step is compared with the last win (or the series baseline if nothing has won yet), never with
the reverted run. The reference is never re-measured at the start of an iteration: its numbers are
already on record from the run that produced it, and the tree it was measured on is exactly the
tree the next candidate is built from.

**Snapshots replace git.** This container has no working git, so the loop keeps its own history
with `benchmarks/lss-loop-snap.sh`, which copies the five source trees the loop may touch
(`compiler/src`, `compiler/src-xhr`, `runtime/src`, `elm-kernel-cpp/src`, `eco-kernel-cpp/src`,
~13 MB together) into `snapshots/lss-loop/<name>/`, and can restore the live tree to any snapshot
byte-for-byte (content-aware copy, deletes files the step added, fresh mtimes on rewritten files,
then a full `diff -r` that fails loudly if anything still differs). Snapshots are never
overwritten. Three kinds exist:

| snapshot | taken when | meaning |
|---|---|---|
| `base` | Phase 0, before any change | the series' starting tree = the first reference |
| `try-N` | Phase 1, right after implementing step N, BEFORE any build | the attempted change, kept even if the step loses (for diagnosis and re-tries) |
| `keep-N` | Phase 4, after the gates pass | the tree of a WIN; `keep-N/bin/` also holds `eco-optN` and `ecoN.mlir` |

`lss-loop-snap.sh diff <ref> try-N > snapshots/lss-loop/step-N.patch` is the step's change record
(the substitute for a commit). Reverting a loss is `lss-loop-snap.sh restore <last keep, or base>`
followed by `verify` — there is no hand-editing of a revert, ever. `<ref>` below always means the
last `keep-K`, or `base` before the first win.

Notation: `BK=build/compiler/build-kernel`, `BOOT=build/runtime/src/codegen/eco-boot-native`,
`bin/eco-opt-prev` = the last kept compiler (initially the tree's fixed-point compiler, which is
`bin/eco-compiler` = `bin/eco-lss-post` on 2026-09-18), `N` = the step number.

**Phase 0 — series baseline (ONCE, before step 1; repeated only after the last step).** First
`lss-loop-snap.sh snap base "series start"` and `cp -p bin/eco-compiler bin/eco-opt-prev`. Then measure
`bin/eco-opt-prev` building the unchanged tree, three cold runs (Phase 2's commands with
`ARM=eco-opt-prev`). This is the reference row until the first win replaces it. It is NOT re-run
per step — the reference for step N is the recorded triple of the last win. The one repeat, after
the final step, is a drift check on the series (the last kept compiler measured again; if it
disagrees with its own recorded triple by more than the noise band, the machine drifted and the
deltas of the intervening steps are suspect).

**Phase 1 — implement and build the candidate (untimed).**
0. `lss-loop-snap.sh verify <ref>` — the live tree must be byte-identical to the reference snapshot
   before a single line is changed (catches a botched revert or an edit left over from elsewhere).
1. Implement step N in the source tree (`compiler/src/...`, or `runtime/` for steps 1 and 14).
   Then `lss-loop-snap.sh snap try-N "step N: <short name>"` and
   `lss-loop-snap.sh diff <ref> try-N > snapshots/lss-loop/step-N.patch`; the patch is quoted
   (size and touched files) in the entry.
2. Type-check first — `cmake --build build --target elm-tests` is the full unit suite; the 1-second
   `elm make` type-check of `compiler/src/Terminal/Main.elm` catches compile errors before any
   long build is started.
3. Produce the candidate's MLIR by compiling the CHANGED source with the last kept native compiler
   (cold `eco-stuff`, solver+LSS): `bin/eco-opt-prev make … --output=bin/ecoN.mlir`. This is the
   bootstrap's Stage 7a shape and takes ~7 min; the JS Stage 5 route (`--target eco-compiler`,
   ~14 min plus the JS stages) produces the same artifact and is only needed when no native
   compiler can compile the new source (a language change — not expected in this loop).
4. Lower it: `$BOOT bin/ecoN.mlir -o bin/eco-optN` (~5 min). This binary CONTAINS the
   optimization; its own code was monomorphized by the previous compiler, which is fine — what we
   measure is what the binary does, not how it was produced.
5. For a step the plan marks as NOT byte-identical (an analysis change): the candidate emits
   different MLIR for its own source, so first do one extra bootstrap turn — self-compile with
   `eco-optN` to `bin/ecoN-b.mlir`, lower to `bin/eco-optN-b`, and use THAT as the candidate
   (the fixed-point rule: A≠B is propagation, the gate is B==C). Byte-identical steps skip this;
   the Phase 2 fixed-point check covers them.

**Phase 2 — measure: the candidate builds itself, three cold runs.**

> **From step 12 onward, use the INTERLEAVED form for any step estimated under ~3 %.**
> `benchmarks/lss-loop-ab.sh <last-kept-arm> <candidate-arm>` runs reference and candidate
> alternately in one sitting and reports the PAIRED differences; judge on the median paired
> difference, not on the difference of two medians measured hours apart. §7 records why: the wall
> column drifts about ±5 s between triples on this machine, which is larger than every step still
> on the list, and two re-runs in this series proved it. The GC counters still do not need this —
> they are exact per (binary × tree) — so a step that moves them can be judged from a plain triple.
> The interleaved form costs twice the machine time.

Run the commands in §2 with `ARM=eco-optN` and `R=1,2,3`. Each run deletes `eco-stuff` first,
runs solver+LSS with NO census variables, and writes `eco-optN-rR.time/.stdout/.stderr` plus
`bin/eco-optN-rR-out.mlir`. Between runs nothing else may execute on the machine.

Then two mechanical checks before any number is read:
- **determinism:** `cmp` the three `-out.mlir` files against each other (must be identical);
- **fixed point:** `cmp bin/eco-optN-r1-out.mlir bin/ecoN.mlir` (byte-identical steps) or
  `… bin/ecoN-b.mlir` (analysis steps). A mismatch means the candidate does not reproduce the
  artifact it was built from — the run is INVALID, not a data point.

**Phase 3 — verdict (§4).** Take the median of the three runs for each stat and compare with the
REFERENCE row: the recorded medians of the last win, or of the series baseline if no step has won
yet. Never compare with a reverted step's row. Record the entry (§3) whatever the verdict.

**Phase 4 — on a win only: gates, then keep.** Byte-identity was already checked in Phase 2 for
substrate steps; now run the correctness gates as a SEPARATE pass, never interleaved with a timed
run: the unit suite (`cmake --build build --target elm-tests`), the E2E suite
(`cmake --build build --target full`), and for any front-end change the 633-workload rail
(`benchmarks/mlir-workload-rail.sh`, whose census artefact catches precision drift the bytes do
not). All green ⇒ `lss-loop-snap.sh snap keep-N "step N kept: <short name>"`, copy `bin/eco-optN` and
`bin/ecoN.mlir` into `snapshots/lss-loop/keep-N/bin/`, `cp -p bin/eco-optN bin/eco-opt-prev`; the
tree keeps the change, this step's medians become the reference row, `keep-N` becomes `<ref>`,
and step N+1 starts from it. Any red ⇒ the step is not kept
until fixed; a re-measure after the fix is a new entry (`N'`) judged against the same reference.

**On a loss** (§4 says loss): `lss-loop-snap.sh restore <ref>` then `lss-loop-snap.sh verify <ref>`
(and `cmake --preset build` if the step added or removed source files — CMake globs sources at
configure time), leave `bin/eco-opt-prev` as it was, record the entry, and note in the plan what
was measured so the step is not re-tried blind. `try-N` and `step-N.patch` stay on disk as the
record of the attempt. The reference
row is unchanged: step N+1 is compared with the last win, not with this run. A loss whose
counters improved while wall rose is worth one line of diagnosis (usually: the change moved work
into the front end or into GlobalOpt — check `out.mlir` size and the phase split) before moving on.

## 2. Commands (run from `/work`)

```bash
BK=build/compiler/build-kernel
BOOT=build/runtime/src/codegen/eco-boot-native
ENV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"      # solver+LSS, the shipped configuration; NO census vars

# Phase 1.0/1.1 — snapshot discipline (no git in this container)
benchmarks/lss-loop-snap.sh verify <ref>                       # tree == last keep (or base)
#   ... implement step N ...
benchmarks/lss-loop-snap.sh snap try-N "step N: <short name>"
benchmarks/lss-loop-snap.sh diff <ref> try-N > snapshots/lss-loop/step-N.patch

# Phase 1.3 — candidate MLIR, compiled by the last kept compiler (untimed, cold cache)
rm -rf "$BK/eco-stuff"
( cd "$BK" && ulimit -c 0 && env $ENV ./bin/eco-opt-prev make --optimize \
    --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/ecoN.mlir /work/compiler/src/Terminal/Main.elm )

# Phase 1.4 — lower it to the candidate compiler
$BOOT "$BK/bin/ecoN.mlir" -o "$BK/bin/eco-optN"

# Phase 2 — the candidate builds itself: THREE cold timed runs, strictly serial
ARM=eco-optN                                       # or eco-opt-prev for the baseline row
for R in 1 2 3; do
  rm -rf "$BK/eco-stuff"                           # MANDATORY before every run
  ( cd "$BK" && ulimit -c 0 && env $ENV \
      /usr/bin/time -v -o "$ARM-r$R.time" \
      "./bin/$ARM" make --optimize --kernel-package eco/compiler \
          --local-package eco/kernel=/work/eco-kernel-cpp \
          --output="bin/$ARM-r$R-out.mlir" /work/compiler/src/Terminal/Main.elm \
          > "$ARM-r$R.stdout" 2> "$ARM-r$R.stderr" )
done
cmp "$BK/bin/$ARM-r1-out.mlir" "$BK/bin/$ARM-r2-out.mlir" && \
cmp "$BK/bin/$ARM-r2-out.mlir" "$BK/bin/$ARM-r3-out.mlir" && \
cmp "$BK/bin/$ARM-r1-out.mlir" "$BK/bin/ecoN.mlir" && echo "deterministic + fixed point"

# Phase 4 — WIN (after the gates): keep
benchmarks/lss-loop-snap.sh snap keep-N "step N kept: <short name>"
mkdir -p snapshots/lss-loop/keep-N/bin && cp -p "$BK/bin/eco-optN" "$BK/bin/ecoN.mlir" snapshots/lss-loop/keep-N/bin/
cp -p "$BK/bin/eco-optN" "$BK/bin/eco-opt-prev"
# Phase 4 — LOSS: revert, fool-proof
benchmarks/lss-loop-snap.sh restore <ref> && benchmarks/lss-loop-snap.sh verify <ref>
```

Extraction, per run (all five stats, in the order they are judged):

| stat | file | line |
|---|---|---|
| wall (s) | `$ARM-rR.time` | `Elapsed (wall clock) time` |
| minor GC count | `$ARM-rR.stdout` | `Minor GC cycles:` |
| major GC count | `$ARM-rR.stdout` | `Major GC cycles:` |
| promoted MiB | `$ARM-rR.stdout` | `totals: promoted <objects> (<n> MiB)` under "Retention by Object Kind" |
| max RSS (kB) | `$ARM-rR.time` | `Maximum resident set size` |

Also record `out.mlir` bytes (`stat` on `$ARM-r1-out.mlir`) — the workload-constancy check
(the workload is the compiler's own source, so a step that adds source moves it).

The GC banner is on stdout with the progress bars, so `grep -a`. The `ECO_MONO_ENGINE` /
`ECO_MONO_LSS` values are also the compiled defaults; they are set explicitly so a row can never
silently run another engine. `ECO_BORROW` and `ECO_AGG_PROMOTE` from the payoff track's build line
are NOT set: `aggPromote` is default-on already and `ECO_BORROW=1` is inert (payoff Run A), and
Phase 1.3 and Phase 2 must run under the SAME environment or the fixed-point `cmp` is meaningless.

## 3. Metrics and records

**Per-step entry** (appended under §6 below, newest last), the table FIRST, then at most ten
lines of prose — what changed, the verdict, and the one-line reason if it is not obvious:

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | | | | | | | same / DIFF |
| r2 | | | | | | | |
| r3 | | | | | | | |
| **median** | | | | | | | |
| Δ vs reference (last win / baseline), medians | | | | | | | |

**Summary table** (§7, bottom of the file): one row per step, numbers only — the MEDIANS of the
three runs: `step | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | verdict | ref`.
`ref` names the row the verdict was judged against (`base` or the step number of the last win),
so a reverted row is visibly skipped by the row after it. No commentary in the table; the argument
lives in the entry.

**What the stats mean.** Wall is the thing we are optimizing. Minor GC count is the honest
allocation-pressure proxy (every minor cycle is a real nursery fill; `Objects allocated` undercounts
~6× because of the inline-alloc fast path — never quote it from a timed run). Major GC count and
promoted MiB track retention and old-gen churn. Max RSS is BIMODAL on this box (old-gen mode gap
~2.15 GB at identical allocation) — that is why it is last, and why three runs are the minimum
before reading it at all. The GC counters are deterministic per (binary × tree); wall and RSS are
the only noisy columns, and three runs bound that noise. Record the triple's spread (max − min) for
wall in the entry.

## 4. The win rule

Compare medians of the three runs against the REFERENCE row — the last win's recorded medians, or
the series baseline's if nothing has won yet. A reverted step never becomes the reference, and the
reference is never re-measured; each step is scored on its incremental change over the last win.

- **Wall decreased ⇒ WIN**, even if every other stat degraded.
- **Wall did not increase and at least one of minor GC, major GC, promoted MiB, max RSS improved
  ⇒ WIN.**
- **Wall increased ⇒ LOSS**, whatever the other stats did.
- "Did not increase" is read against the noise band: the candidate's median wall is at most the
  baseline's median wall plus the larger of the two triples' spreads. A wall move inside that band
  is FLAT, and a flat wall with an improved counter is a win under the second rule. (This clause is
  the one interpretation added to the rule as stated; drop it if strict medians are preferred.)
- A step that fails the fixed-point or determinism check has no verdict — fix it first.

**Read GC TIME, not the minor-cycle count, when the two disagree (learned at step 5b).** The rule
above is unchanged and stays wall-first, but the interpretation of the counters is not what it
looked like for the first thirty entries. Minor GC *count* measures allocation VOLUME; minor GC
*cost* is paid for SURVIVORS — an object that dies before the next collection is never traced,
never copied, and costs nothing. Step 5b deleted 10^6-scale short-lived closures, drove the cycle
count down by 26 (the largest counter move in the series) and was **2.1 % SLOWER**, because fewer
collections each spanned more elapsed work and therefore found more of the live set still alive:
GC time rose 5.31 s, which was the entire regression. `lss-loop-extract.sh` prints GC time in
column 7 — quote it in every entry, and treat a cycle-count improvement that comes with a GC-time
or promotion increase as the warning it is.
- Byte-identical emission is a GATE for substrate steps (Phase 2), not a stat; an analysis step
  that legitimately changes `out.mlir` says so in its entry and quotes the size delta, because the
  workload moved.

## 5. Hygiene — non-negotiable

- `rm -rf $BK/eco-stuff` before EVERY run, timed or not. Never delete `~/.eco`.
- **No census variables anywhere in a timed run**: no `ECO_MONO_LSS_REPORT`, `ECO_DISPATCH_STATS`,
  `ECO_MONO_LSS_QCENSUS`, `ECO_MONO_LSS_ARROW_CENSUS`, `ECO_CALL_CENSUS`, `ECO_INLINE_ALLOC`.
  When a step needs a census to explain a result, take it in a separate, labelled, untimed leg.
- **Strictly serial**: 15 GB RAM, ~12.7 GB peak RSS; nothing else heavy on the box; no concurrent
  test runs (they also corrupt `~/.eco`).
- **Do not touch `ECO_HEAP_CONFIG`** — majors are a recorded stat.
- **The instrument changes every step BY DESIGN** (this is the opposite of the flag-off loop, whose
  instrument was fixed): each row is "the candidate builds itself". What must NOT change mid-series
  is anything else — the machine, the runtime build (except when a step IS a runtime change),
  the source outside the step under test.
- **One step per iteration.** Two changes in one candidate cannot be attributed; if a step is
  built in parts (the plan splits several), each part is its own entry (`10a`, `10b`, …).
- **Testing is a separate pass** (Phase 4) — never between the three timed runs.
- Keep every `*.time/.stdout/.stderr` and the `-out.mlir` files of a kept step until the series
  closes; delete a rejected step's outputs after its entry is written.
- **Never edit the tree between `verify <ref>` and `snap try-N` except for step N itself**, and never
  revert by hand: a loss is undone only by `restore <ref>` + `verify <ref>`. Snapshots are never
  deleted or overwritten during a series (`snap` refuses to overwrite). If `verify` fails at the
  start of an iteration, stop and find out why before implementing anything.
- After a `restore` that removed or re-added source files, re-run `cmake --preset build` before any
  ninja-driven gate (the source globs are evaluated at configure time).

## 6. Runs

(Entries in the §3 shape, one per step, newest last.)

### base — series baseline (2026-09-19)

`bin/eco-opt-prev` = the tree's fixed-point `bin/eco-compiler` (sha256 `7fc3b7e0…`) building the
unchanged tree.

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 398.71 | 1825 | 10 | 20846 | 12,711,036 | 13,304,208 | same |
| r2 | 402.40 | 1825 | 10 | 20846 | 12,707,776 | 13,304,208 | same |
| r3 | 397.19 | 1825 | 10 | 20846 | 12,708,052 | 13,304,208 | same |
| **median** | **398.71** | **1825** | **10** | **20846** | **12,708,052** | 13,304,208 | same |

Wall spread 5.21 s = 1.31 %. The three GC counters are IDENTICAL across all three runs — they are
deterministic per (binary x tree), which is why they are judged before wall. All three outputs are
byte-identical to each other and to `bin/eco-compiler.mlir`, so the tree is at its fixed point.
GC/Alloc time 142.10 s = 35.6 % of wall. This row is the reference until the first win.

### 1 — GC-stats timer overhead in the `build` preset (runtime) — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 366.60 | 1825 | 10 | 20846 | 12,714,744 | 13,304,208 | same |
| r2 | 374.46 | 1825 | 10 | 20846 | 12,705,584 | 13,304,208 | same |
| r3 | 370.18 | 1825 | 10 | 20846 | 12,705,760 | 13,304,208 | same |
| **median** | **370.18** | **1825** | **10** | **20846** | **12,705,760** | 13,304,208 | same |
| D vs base | **-28.53 (-7.16 %)** | 0 | 0 | 0 | -2,292 (-0.02 %) | 0 | — |

`OldGenSpace::allocate` no longer reads the clock when `g_in_minor_gc` is set. That call is one
promotion, made once per promoted object by the three nursery evacuation copiers, so the bracket was
costing two vdso clock reads per promoted object — on the order of 1.5e9 reads per run. Promotions
are already inside the minor-GC bracket, so the deleted sub-counter measured a nesting, not a cost.
`NurserySpace::minorGC` therefore records the whole pause with nothing subtracted, and the
`total_oldgen_alloc_in_minor_ns` field is deleted rather than left reading zero. Four files,
202-line patch (`snapshots/lss-loop/step-1.patch`); no compiler source changed, so the candidate is
`bin/eco-compiler.mlir` re-lowered against the rebuilt runtime.

Verdict WIN on rule 1, by a margin no re-run could flip: wall is down 28.53 s against a triple
spread of 7.86 s. That spread is 2.12 % of the median, marginally over the 2 % disturbance
threshold; it was not re-run because the delta is 3.6x the spread and the three GC counters came
back bit-exact, which is what a disturbed machine does not do. The counters landing on 1825 / 10 /
20846 exactly is also the proof that the change is pure overhead removal: the allocator did the same
work, it just stopped timing itself.

One number moved the other way and is not judged: `Total GC/Alloc time` rose from 142.10 s to
146.53 s. That is an accounting change, not a regression. Minor-GC time now includes promotion
allocation, which the old code subtracted out, and the subtracted quantity was itself mostly the
timer overhead this step deleted. Walls recorded before step 1 are not comparable with later ones
for that reason, which is why the reference row moves to this step.

Rejected alternatives, recorded so they are not re-proposed: `rdtsc` (still two instructions plus
serialisation per promotion, and TSC-versus-vdso agreement is unmeasured on this VM); sampling every
2^n-th promotion and scaling (a non-deterministic sub-counter for a figure nobody judges); keeping
the field and writing zero (a zero that reads like data).

Gates: `check` green, 1727/1727 (C++-only change, so `check` is the sanctioned target). Kept as
`keep-1`; `bin/eco-opt-prev` is now `eco-opt1`.

### 2 — hash-cons equality O(arity) instead of a deep structural walk — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 363.97 | 1821 | 10 | 20836 | 12,709,180 | 13,306,221 | same |
| r2 | 359.47 | 1821 | 10 | 20836 | 12,690,620 | 13,306,221 | same |
| r3 | 356.96 | 1821 | 10 | 20836 | 12,690,812 | 13,306,221 | same |
| **median** | **359.47** | **1821** | **10** | **20836** | **12,690,812** | 13,306,221 | same |
| D vs 1 | **-10.71 (-2.89 %)** | **-4** | 0 | **-10** | **-14,948 (-0.12 %)** | +2,013 | — |

The intern table's key type becomes `Canon` — the canonical node plus, for a record only, its
fields in ascending name order — and the probe stays a bare `MonoType` compared against it by
`HashMap.getBy`, added here. `eqExact` is no longer Elm `==`: it tests the packed hash first, then
the shallow slots, then the children with `==`. The record arm walks the fresh `Dict.foldl` in
lockstep against the stored ascending list, so it never builds a list for the probe and never calls
`Dict.get`. The sorted list is built once per canonical node, on the miss path, which is about 1 %
of probes. Two files, 292-line patch (`snapshots/lss-loop/step-2.patch`).

What this removes is the kernel's `dictEq` on the 99 %-hit path: comparing two record shells meant
two vector allocations, an in-order walk of both red-black trees and a string compare per field
name, even though the children on both sides were already canonical and would have answered on
their first word. The children were never the cost; the container shells were.

Every stat improved, so the verdict does not rest on wall alone. Four fewer minor cycles and 10 MiB
less promoted, on a workload that GREW by 2,013 bytes, means the change removed real allocation
rather than merely moving it. Wall spread 7.01 s = 1.95 %, inside the band.

Byte identity, the gate for a substrate step, is met three ways. The fixed-point `cmp` is the
strongest: `eco2.mlir` was emitted by the step-1 compiler (deep `==`) from the changed source and
`eco-opt2-r1-out.mlir` by the step-2 compiler (shallow compare) from that same source, and the two
agree over 13.3 MB. The 633-workload rail agrees as well, on both artefacts — 633/633 manifests
identical and a zero-line diff across the 65,508-line LSS census, which is the analysis gate the
bytes alone would not give. And a new unit oracle checks `eqExact a b == (a == b)` over the 8,100
corpus pairs plus hand-written record cases, including the two a shallow compare is most likely to
get wrong: fields inserted in opposite orders (equal content, different tree shape) and two names
of equal length that also collide on the packed hash.

`out.mlir` grew 2,013 bytes because the workload is the compiler's own source and this step adds
source to it. That is workload movement, not emission drift; the rail is what separates the two.

Gates: `full` green 1727/1727; unit suite 13,531 passed with the 12 pre-existing POST_010
grounding failures unchanged in name and count; rail clean. New pins: `Compiler/Data/HashMapTest`
(6 tests, collision-forcing hash) and two `K6` tests in `ComparableKeyEncodingTest`. Kept as
`keep-2`; `bin/eco-opt-prev` is now `eco-opt2`. The rail artefacts are saved in `keep-2/` as the
reference for step 3.

### 3a — `Eco.CellStore` kernel package, pure twin, native pins — **not measured**

No compiler source changed, so there is nothing to time. Adds the kernel module in three
languages: `eco-kernel-cpp/src/eco/CellStore.{hpp,cpp}` + `CellStoreExports.cpp` (a C++ vector of
encoded HPointer words plus an undo trail, registered with `RootSet::addExternalRootScanner`),
`src/Eco/Kernel/CellStore.js` for the JS bootstrap stages, `src/Eco/CellStore.elm` as the Elm
wrapper, and `compiler/src-xhr/Eco/CellStore.elm` as the PURE twin that stock Elm compiles for
stage 1 and the unit suite. Wired into four build files plus the package manifest and
`ECO_KERNEL_MODS`, which is the list that actually puts the archive in the lowered binary.

Gates: `Compiler/Data/CellStoreTest` (16 tests, the twin) and four native pins under
`test/eco-kernel` — round-trip over 1,000 boxed records, the rollback algebra, 40,000 cells
surviving forced collections with the originals reachable only from the trail, and two stores
built side by side not aliasing. All green.

Three things this cost that the specification did not predict, recorded because the next kernel
module will hit all three. The kernel JS file's leading `/* ... */` block is the IMPORT header, not
a comment, so prose there makes the module unresolvable. A locally-linked package is COPIED into
`~/.eco` on first build and the copy is not refreshed when the seed gains a module, so the copy has
to be moved aside. And `ECO_KERNEL_MODS` in `runtime/src/codegen/CMakeLists.txt`, not the link
lists, is what decides whether the archive reaches a lowered program.

The snapshot tool was extended in this step and is now part of the protocol: it covers
`compiler/tests`, `test/eco-kernel/src` and six individual build/manifest files, skips paths a
snapshot predates rather than deleting them, and excludes `TestServerConfig.elm`, which the E2E
harness rewrites with a fresh port on every run. `keep-2` was backfilled with the pre-step-3
content of the new paths so a step-3 revert would have been complete.

### 3 — transient union-find store (`Eco.CellStore`) — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 342.48 | 1583 | 10 | 20376 | 12,457,544 | 13,314,359 | same |
| r2 | 338.77 | 1583 | 10 | 20376 | 12,457,292 | 13,314,359 | same |
| r3 | 340.70 | 1583 | 10 | 20376 | 12,457,636 | 13,314,359 | same |
| **median** | **340.70** | **1583** | **10** | **20376** | **12,457,544** | 13,314,359 | same |
| D vs 2 | **-18.77 (-5.22 %)** | **-238 (-13.1 %)** | 0 | **-460 (-2.2 %)** | **-233,268 (-1.84 %)** | +8,138 | — |

`IO.State.ioRefsPoint` is no longer a persistent 32-way trie. Every descriptor write and every
union used to copy a path of two or three 32-slot nodes; now a write is one C call and a store, and
a fresh Point is one vector push. The cells and the undo trail are GC roots through an external
root scanner, which is the only sound way to hold Elm values in mutable storage here — the
collector has no write barrier, so an on-heap mutable object could hold an old-to-young pointer no
minor GC would ever see. Recorded as HEAP_047 and KERN_007.

Soundness rests on the store being threaded linearly, which it already was everywhere except three
best-effort recovery sites that used to "undo" a failed unify by keeping the older array value.
Those now bracket their speculation with `markStore`/`rollbackStore`: `Store.unifyBestEffort`,
`Translate.unifyStepBestEffort`, and `Translate.classifyRef`, the last with one scope per fallible
step because each of its three `Err` arms falls back to a different state. The two report-gated
census replays are bracketed too, so a census leaves no path compression behind.

Every stat improved. The minor-GC drop of 238 cycles is the change working as designed: the trie
nodes were the biggest single source of live data being copied at each collection, and 233 MB less
peak RSS is the same fact seen from the other end.

Byte identity: the fixed-point `cmp` holds, and the 633-workload rail's manifest is identical on
all 633. The rail's census differs on exactly one workload, `Hello`, by exactly +13 source lambdas
and one member id — which is `Eco.CellStore`'s twelve exported functions plus the lambda inside
`freeze`, now compiled as part of the kernel package. Adding a module to that package necessarily
mints members for it; no emitted byte moves.

Two process notes. The pure twin earned its place immediately: it FAILED where the kernel would
have passed, because rolling back a pre-mark state is a no-op on a mutable store but "rollback
without a mark" on a value-typed one. The fix — bind the marked state and roll THAT back — is the
portable form, and the twin is what forced it. Separately, one of the native pins failed on first
run for a defect in the pin itself: it read a store through one handle while another binding
mutated it, and Elm does not order independent `let` bindings. That is the hazard KERN_007 (b)
names, caught by the test suite rather than by a miscompile.

This row is the SECOND measurement of step 3. The first (wall median 335.46, GC counters identical
to the digit) was taken before `check-kernel-license-manifest` failed: adding the CellStore
root-registration call to `RuntimeExports.cpp` invalidated the audited hash pinning four licensed
`Runtime.*` kernels. The re-audit is recorded in `KernelSetFacts` — the only change to that file is
one line in the registration hook, touching no licensed body, type or capture behaviour — and the
hash and audit dates were advanced. That edit is part of step 3, so the step was re-measured with
it in rather than reported against a tree that was never built. The two triples agree: identical GC
counters, 5 s of day-to-day wall drift.

Gates: `full` 1731/1731 (up 4: the new native pins); unit suite 13,547 passed with the same 12
pre-existing POST_010 failures; 1,271 kernel tests green; rail as above. Kept as `keep-3`;
`bin/eco-opt-prev` is now `eco-opt3x`.

### 4b — per-run classify memo for ground alias instantiations — **WIN (wall), memory regression recorded**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 339.44 | 1600 | 10 | 20863 | 12,711,764 | 13,326,049 | same |
| r2 | 333.06 | 1600 | 10 | 20863 | 12,710,664 | 13,326,049 | same |
| r3 | 334.85 | 1600 | 10 | 20863 | 12,712,684 | 13,326,049 | same |
| **median** | **334.85** | **1600** | **10** | **20863** | **12,711,764** | 13,326,049 | same |
| D vs 3 | **-5.85 (-1.72 %)** | +17 | 0 | **+487 (+2.4 %)** | **+254,220 (+2.0 %)** | +11,690 | — |

An alias instantiation whose arguments and body are ground and arrow-free classifies to the same
canonical `MonoType` at every occurrence, so the first classify is cached under a structural key
`(home, name, args)` and every later one is a hash lookup instead of a node-by-node walk with an
intern probe per node. The key cannot be object identity: `AssignMVarIds` rebuilds every node of
every type per occurrence, so two occurrences of `S` are two distinct trees before anything runs.
Parameter ids are dropped from the key because they are per-def binder ids, not identity.

Verdict WIN on rule 1: the median wall fell 5.85 s. The evidence is better than that margin alone
suggests, because all three candidate runs came in below the reference MEDIAN and two of the three
below its fastest run — the distributions barely overlap. It is still a narrow result: the delta is
inside this triple's own 6.38 s spread.

**Three of the four other stats moved the wrong way, and that is not noise** — the GC counters are
deterministic per binary and tree. Promoted rose 487 MiB and peak RSS 254 MB, giving back most of
what step 3 won on those columns, and minor cycles rose by 17. The memo buys time with retention:
its map lives for the whole run and holds a key per instantiation, and unlike the classifications
themselves, which were already interned, the keys and buckets are new live data. The size of the
effect is larger than a key-and-bucket count explains, so it is recorded as measured and not
explained away. The plan predicted minor GC would FALL here; it did not, and the prediction was
made for 4a and 4b together.

Consequence for the next entry: 4a (the per-item load memo) is the half the plan expects to cut
mints and therefore allocation. If 4a lands and the pair still shows this retention, the two should
be judged together, and reverting both in favour of 4a alone is the obvious experiment.

Byte identity holds three ways: the fixed-point `cmp`, and the 633-workload rail identical on BOTH
artefacts — manifest and the 65,508-line census, zero diff lines, exactly as the specification
predicted, which is the evidence that the memo changes only how the answer is reached.

Gates: `full` 1731/1731; unit suite 13,561 passed with the same 12 pre-existing POST_010 failures;
15 new pins in `GroundAliasMemoTest` covering the eligibility predicate, key equality under
differing binder ids, and the verdict map overriding the walk. Kept as `keep-4b`.

### 4a — per-item load memo for ground alias instantiations — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 291.93 | 1312 | 10 | 20354 | 12,026,400 | 13,332,898 | same |
| r2 | 288.67 | 1312 | 10 | 20354 | 12,025,132 | 13,332,898 | same |
| r3 | 295.34 | 1312 | 10 | 20354 | 12,034,740 | 13,332,898 | same |
| **median** | **291.93** | **1312** | **10** | **20354** | **12,026,400** | 13,332,898 | same |
| D vs 4b | **-42.92 (-12.8 %)** | **-288 (-18.0 %)** | 0 | **-509 (-2.4 %)** | **-685,364 (-5.4 %)** | +6,849 | — |

The second and later loads of one ground, arrow-free alias instantiation WITHIN an item now reuse
the first load's child Points and mint only a fresh root. For `S`, the compiler's own 31-field
state record, that is one mint instead of one per field and per nested subtree, and the profile put
roughly 5.7 million union-find mints per self-compile largely on this path.

The root is deliberately NOT shared. Sharing it would let a bare reference's family var and a
call's isolated twin become union-find equivalent through it, which flips the MONO_029 stale-read
barrier and livelocks the saturation loop; per-load roots keep them in separate classes, and one
mint is nothing against the hundreds it replaces. Var Points are never shared either, and no arrow
is reachable from an eligible type, so the LSS_006 ordinal contract is not touched — pinned by the
arrow test in `GroundAliasMemoTest` and by the 165 existing arrow pins.

Every stat improved, and by margins far outside the noise: wall is down 42.92 s against a 6.67 s
spread, and the GC counters are exact. This is also the entry that settles 4b's memory regression.
Against step 3, the pair 4b+4a is wall 340.70 to 291.93, minor cycles 1583 to 1312, promoted 20376
to 20354 MiB and RSS 12.46 GB to 12.03 GB — so the retention 4b added is repaid with interest, and
the two do belong together as the plan grouped them.

Byte identity: fixed point holds, and the rail is identical on both artefacts against `keep-4b` —
manifest and the full census, zero diff lines.

Gates: `full` 1731/1731; unit suite 13,566 passed with the same 12 pre-existing POST_010 failures;
five new load-side pins covering one-mint-per-repeat-load, distinct roots over identical children,
no sharing for an arrow-bearing alias, per-instantiation keying, and the var memo and mint counter
left untouched by a hit. Kept as `keep-4a`.

### 5a — direct-state entry for `Unify.unify` — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 289.43 | 1287 | 10 | 20341 | 12,048,496 | 13,332,279 | same |
| r2 | 291.57 | 1287 | 10 | 20341 | 12,048,844 | 13,332,279 | same |
| r3 | 287.51 | 1287 | 10 | 20341 | 12,047,792 | 13,332,279 | same |
| **median** | **289.43** | **1287** | **10** | **20341** | **12,048,496** | 13,332,279 | same |
| D vs 4a | **-2.50 (-0.86 %)** | **-25** | 0 | **-13** | +22,096 (+0.18 %) | -619 | — |

`Unify.unify`'s entry is now a wrapper over `unifyS`, a direct-state function, and `guardedUnify`'s
body is a saturated top-level `guardedUnifyS` the entries call without building the CPS closure
first. `Store.unifyStep` becomes `S -> ( Bool, S )` and renders nothing; callers that propagate a
mismatch use the new `unifyStrict`, which builds the diagnostic only on the failure path. What goes
away per unification is scaffolding: the `liftIO` thunk, the `Engine.andThen` closure and its
continuation, `succeed`'s closure, the `IO.pure` of the success arm, and the `Ok`/`UnifyOk` pairs
that existed only to be destructured immediately.

The wall delta is smaller than this triple's 4.06 s spread, so on wall alone the result would be
"probably faster". What makes it a win rather than a guess is that the two deterministic counters
moved: 25 fewer minor cycles and 13 MiB less promoted, exact per binary and tree. RSS rose 22 MB,
0.18 %, which is inside the bimodal band that column has on this machine.

One adaptation to the specification, forced by step 3. It had `unifyBoolS` return the PRE-unify
state on failure, so a best-effort caller recovered by taking the older value. That stopped working
when the point store became an in-place `Eco.CellStore`: there is one store, so the pre-unify state
names the same mutated cells and returning it only looks like an undo. The real undo is the
caller's `markStore`/`rollbackStore` bracket, which step 3 already installed at all three
best-effort sites, so `unifyBoolS` returns the state the attempt left and the bracket does the
work. Both entries now roll back the state the attempt RETURNED rather than the pre-mark one — the
same portability point the pure twin forced in step 3.

Byte identity: fixed point holds and the rail is identical on both artefacts. Order preservation
matters here beyond the gate, because `unifyS` is shared with the real typechecker and a change in
Point mint order would move `Vars.Pt` indices, which are exposed through `pointKey`.

Gates: `full` 1731/1731; unit suite 13,566 with the same 12 pre-existing failures. Kept as
`keep-5a`. 5b (re-spelling the combinator layer itself, where the per-node closures live) remains
a separate entry.

### 6 — flag-residue and dead-arm cleanup — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 282.16 | 1281 | 10 | 20201 | 12,051,528 | 13,329,272 | same |
| r2 | 286.85 | 1281 | 10 | 20201 | 12,056,408 | 13,329,272 | same |
| r3 | 286.99 | 1281 | 10 | 20201 | 12,052,184 | 13,329,272 | same |
| **median** | **286.85** | **1281** | **10** | **20201** | **12,052,184** | 13,329,272 | same |
| D vs 5a | **-2.58 (-0.89 %)** | **-6** | 0 | **-140** | +3,688 (+0.03 %) | -3,007 | — |

The residue the 2026-09-18 flag removal left behind, deleted: the unreachable keyed arm in
`enqueueSpec`, the `arrowIdOn`/`arrowMintOn` load-context fields and the two guards that read them,
the `needSlow` deferral chain with `foldSlowWrites`, `unifySlotWithSetSlow` and the `setWriteSlow`
counter, the `groundStandalones`/`honestSources` accumulator fields, and two dead `Translate`
functions. `foldSetWrites` becomes `S -> S`, which steps 8 and 10 both require. Five census keys
that were built with string concatenation before any gate are now behind the report flag, the one
per-node case among them being the per-literal key in `walkLiteral`.

Two of the deletions needed judgement rather than mechanical removal. The `needSlow` path existed
to defer a defensive `unifySlotWithSetC` arm to a slow unify at the traversal boundary; that arm is
unreachable by the closure of the slot-content channels and has measured zero on every self-compile
since Run C, so it now writes ⊤ directly. That is sound in the same direction the deferral was: ⊤
absorbs, so the failure mode is lost precision, never a dropped edge.

The second one was caught by a test, and is worth recording because the "obvious" simplification
was wrong. `honestSourcesOn` read a field that production always seeded True, so hardcoding True
looked equivalent — but it also answered False when the zonk accumulator was ABSENT, which is the
lss-off configuration. `LssDirectedFlowTest` case 5 failed immediately. The honesty policy is now
an explicit argument to `resolveSlotMembersWith`, and `resolveSlotMembers` passes "is there an
accumulator", which reproduces the old predicate exactly.

Byte identity: fixed point holds and the rail's manifest is identical on all 633. The census
differs on 633 lines, and every one is the same `set-writes:` line differing ONLY by the deleted
` slow=0` field — checked mechanically by normalising that field away, after which the diff is
empty. That is the counter this step removed, not analysis drift.

Gates: `full` 1731/1731; unit suite 13,565 with the same 12 pre-existing POST_010 failures. One
test was deleted rather than fixed: `ArrowIdentityTest`'s "flag OFF" case pinned the regime this
step removes. Kept as `keep-6`.

### 7 — census bookkeeping off the default path (7a) — **WIN on rule 2, marginal**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 287.08 | 1280 | 10 | 20183 | 12,044,320 | 13,329,112 | same |
| r2 | 293.11 | 1280 | 10 | 20183 | 12,064,424 | 13,329,112 | same |
| r3 | 289.08 | 1280 | 10 | 20183 | 12,044,660 | 13,329,112 | same |
| **median** | **289.08** | **1280** | **10** | **20183** | **12,044,660** | 13,329,112 | same |
| D vs 6 | +2.23 (+0.78 %) | **-1** | 0 | **-18** | **-7,524 (-0.06 %)** | -160 | — |

The zonk accumulator used to carry policy and counters together, so it had to exist whenever LSS
was enabled. It is now counters only, allocated only under the report flag, with `lssOn` and
`maxSetSize` moved onto the context. Every counter bump on the default path is therefore a `case`
on a constant `Nothing` that allocates nothing.

**Verdict WIN under rule 2, and it is the marginal case that rule exists for.** Median wall rose
2.23 s, which is inside this triple's own 6.03 s spread, so wall is FLAT by the noise-band reading;
both deterministic counters improved. But the improvements are tiny — one minor cycle in 1,280 and
18 MiB in 20,183 — so the honest summary is that the accumulator was never a significant allocation
source. Roughly 650,000 records per run is simply not much next to this compiler's nursery traffic.
The step is kept for its substrate value rather than for a measured speedup: steps 8 and 10 both
build on the reshaped zonk context, and `foldSetWrites` and the context split are prerequisites
they assume.

One hazard here was the same shape as step 6's, and this time it was caught by reading rather than
by a test. Three sites used "is there an accumulator" as a proxy for "is LSS enabled" — the two
`LambdaSet1` arms of `zonkSetSlot` and the honesty predicate. Once the accumulator became
report-scoped those two questions came apart, and leaving them would have made the default path
return ⊤ for every set slot: a silent, total precision collapse that no gate here would have
caught, because emission of the self-compile might well not change. They now read `lssOn`.

Byte identity: fixed point holds; the rail is identical on both artefacts, including the census,
which is the check that the report still computes exactly what it did.

Gates: `full` 1731/1731; unit suite 13,565 with the same 12 pre-existing failures. Two test
context literals gained the new fields. 7b (`ItemAux.counters`) stays skipped: under 7a every
counter it would hold is bumped only when the report is on, and the loop never times a report-on
run. Kept as `keep-7`.

### 8a — pure union-find reads (`peekS`/`rootQ`/`equivalentQ`) — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 294.07 | 1291 | 10 | 20233 | 12,118,176 | 13,328,536 | same |
| r2 | 287.90 | 1291 | 10 | 20233 | 12,106,792 | 13,328,536 | same |
| r3 | 288.94 | 1291 | 10 | 20233 | 12,118,144 | 13,328,536 | same |
| **median** | **288.94** | **1291** | **10** | **20233** | **12,118,144** | 13,328,536 | same |
| D vs 7 | -0.14 (-0.05 %) | **+11** | 0 | **+50** | **+73,484 (+0.61 %)** | -576 | — |

A read that only reads does not need to compress the path it walked, so the ~40 read-only sites
were moved to pure `peekS`/`rootQ`/`equivalentQ`, dropping the state copy each one used to write
back.

**Not kept.** Wall moved 0.14 s on a 6.17 s spread, which is flat, and NO other stat improved —
all three moved the wrong way, and the GC counters are exact. A flat wall with nothing improved is
not a win under either rule, and keeping a change that costs 11 minor cycles, 50 MiB and 73 MB of
peak RSS for no measured time would be strictly worse than not making it.

**Why it lost, which is the useful part: step 3 had already removed the cost this step targets.**
The premise was that a read's write-back is expensive — under the old persistent array it copied a
path of trie nodes. Since the store became an in-place `Eco.CellStore`, a compression write is one
C call and a store. So the saving is now near zero, while the cost is real and was always there:
compression is WORK THAT PAYS FORWARD. Skipping it leaves chains long, and every later read walks
them again. The counters going the wrong way is that effect showing up as more live chain traffic.

Two consequences for the plan. Step 8b, the other half, is a different change — it removes zonk
CONTEXT copies rather than compression — but its premise is weakened the same way and it should be
judged on its own before being assumed. And the specification's reasoning was sound when written,
against the tree of 2026-09-19; what invalidated it was a step landing in between. A spec written
before its prerequisites land has to be re-read against what the tree became, not what it was.

The measurement did surface a better target in the same area, recorded here rather than acted on:
`IORef.writePointCellS` allocates a fresh `IO.State` record AND a fresh `Store` wrapper per union-find
write, and under the in-place store both contain exactly what they contained before — the same
handle. That is two allocations per write on a path that runs millions of times per run, and
unlike compression it buys nothing at all.

Reverted with `restore keep-7`, verified byte-identical. The reference row is unchanged: step 9 is
judged against step 7. `try-8a` and `step-8a.patch` remain on disk as the record.

### 8b — drop the threaded state at compressing reads — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 289.23 | 1273 | 10 | 20207 | 12,105,580 | 13,328,331 | same |
| r2 | 287.24 | 1273 | 10 | 20207 | 12,105,460 | 13,328,331 | same |
| r3 | 285.01 | 1273 | 10 | 20207 | 12,103,712 | 13,328,331 | same |
| **median** | **287.24** | **1273** | **10** | **20207** | **12,105,460** | 13,328,331 | same |
| D vs 7 | **-1.84 (-0.64 %)** | **-7** | 0 | +24 | +60,800 (+0.50 %) | -781 | — |

8a's replacement, designed from what 8a's failure showed. The read sites keep calling the
COMPRESSING `UF.get`, and simply do not thread the state it returns. That is sound only because
the store is mutated in place: the compression has already happened by the time the call returns,
and the state handed back differs from the one passed in by nothing but the record wrapper around
the same handle. So the context copy per read goes away while the compression that pays forward
stays.

The comparison with 8a is the whole point, on the same reference row:

| | wall | minor GC | what changed |
|---|---|---|---|
| 8a | -0.14 (flat) | **+11** | dropped the copies AND the compression |
| 8b | **-1.84** | **-7** | dropped the copies, KEPT the compression |

Eighteen exact minor cycles separate the two, which is compression paying for itself. WIN on rule
2: wall is down 1.84 s but that is inside this triple's 4.22 s spread, so it is the deterministic
minor-cycle count that carries the verdict.

The memory columns are mixed and are recorded as measured: promoted is up 24 MiB and peak RSS up
61 MB, both small, both also present in 8a, so they track the context-copy removal rather than the
compression question. They are not explained here.

Byte identity: fixed point holds; rail identical on both artefacts. Gates: `full` 1731/1731; unit
suite 13,565 with the same 12 pre-existing failures. Kept as `keep-8b`.

### 9 — skip `connectTypes` / `enrichFromEnv` for ground, arrow-free types — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 289.18 | 1252 | 10 | 20269 | 12,095,116 | 13,330,827 | same |
| r2 | 288.10 | 1252 | 10 | 20269 | 12,093,628 | 13,330,827 | same |
| r3 | 289.60 | 1252 | 10 | 20269 | 12,095,088 | 13,330,827 | same |
| **median** | **289.18** | **1252** | **10** | **20269** | **12,095,116** | 13,330,827 | same |
| D vs 8b | +1.94 (+0.68 %) | **-21 (-1.6 %)** | 0 | +62 | **-10,344 (-0.09 %)** | +2,496 | — |

A ground, arrow-free type has no type variable to concretise and no set slot to carry members
into, so connecting it to another ground type, or re-encoding a bound type and unifying it into
it, moves nothing. Both are now skipped, using step 4's verdict map so the predicate is a hash
lookup for `S`, `Env` and `ItemAux` rather than a walk.

WIN on rule 2: wall is up 1.94 s, which is flat against the 4.22 s band the reference triple set,
and minor cycles are down 21 — an exact, deterministic figure, and the largest single-step drop in
that column since step 4a.

**This row needed two triples, and the first one is why the GC counters are judged first.** In the
first triple, runs 1 and 2 agreed on 1252 / 20269 while run 3 reported 1273 / 20274 with 120 MB
less peak RSS — counters that are deterministic per binary and tree do not do that. All three
outputs were byte-identical, so the compiler behaved identically; what differed was the allocator,
which this box is on record as switching heap modes. The triple was re-run and came back clean:
identical counters on all three and a 1.50 s spread. The first triple's wall median was 284.73,
about 4.5 s faster than the second's, which sets the honest resolution of the wall column on this
machine at roughly ±5 s between triples. A step worth 2 s cannot be resolved by wall here, and the
exact counters are what carry these verdicts.

Byte identity: fixed point holds; the rail's manifest is identical on all 633. The census differs
on 42 lines and every one is an `enrich|bare` or `enrich|access|ofLocal` COUNT, with no other key
touched. That is the skip being visible in the diagnostic that counts attempted transports: when a
whole tuple is ground the three element recursions are skipped together, so their rows are not
counted. The transports themselves were no-ops — which is why not one emitted byte moves — so the
census is now describing what the analysis actually does. The specification predicted zero census
lines here and was wrong about the tuple arm specifically.

Gates: `full` 1731/1731; unit suite 13,565 with the same 12 pre-existing failures. Kept as
`keep-9`.

### 10 — retire the `Step` encoding — **DEFERRED, not attempted**

Not measured, and the tree is unchanged. Recorded here so the gap is visible rather than silent.

Step 10 is a seven-stage programme (§9 of the plan, entries `10a`–`10g`) and the stages are not
independent. `10a` admits `MonoIf` on the `$sret` result spine, which means teaching
`Generate.MLIR.Expr.generateIf` the spine-yield protocol that `generateCase` already implements —
the aggregate result type, `emitSpineYield` per branch, `finishSpineCase` for the construction.
That cannot be done half-way: admitting `MonoIf` in the selection rule while `generateExpr` still
clears `sretTailLayout` for it would leave a worker whose branches yield scalars into a region
declaring an aggregate. And `10a` on its own is predicted flat to slightly negative by its own
specification — the coverage it unlocks only pays at `10f`, which needs `10b` through `10e` first:
about 263 signatures, 500 combinator uses and 450 `Ok`/`Err` arms across four files.

The ordering cost of deferring is small and was checked: §2's dependency table lists step 10 as a
prerequisite only for step 26, and every step from 11 onward is independent of it. So the series
continues at step 11 and step 26 is the one entry that cannot be reached without coming back here.

What a later attempt should know, from the reading done: the selection side is two small mirror
arms (`sretTailOk` and `sretFreshTailOk` already have the pattern in `sretTailFuncOk`), and the
whole risk sits in `generateIf`. The result-type rule at the top of `generateCase` is the piece to
extract and share first, because both callers need exactly it.

### 11b — memoise `Intern.widenSets` per canonical input — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 280.60 | 1243 | 10 | 20284 | 12,070,640 | 13,336,198 | same |
| r2 | 278.11 | 1243 | 10 | 20284 | 12,058,368 | 13,336,198 | same |
| r3 | 275.15 | 1243 | 10 | 20284 | 12,058,224 | 13,336,198 | same |
| **median** | **278.11** | **1243** | **10** | **20284** | **12,058,368** | 13,336,198 | same |
| D vs 9 | **-11.07 (-3.83 %)** | **-9** | 0 | +15 | **-36,748 (-0.30 %)** | +5,371 | — |

`widenSets` produces the annotation-insensitive spec-registry key, and it ran in full on every
enqueue — a complete rebuild of the demand type with every arrow relabelled, hash-consing each
node on the way. It is a pure function of its input, and the input is canonical because every
producer hash-conses bottom up, so one entry answers every later enqueue of the same demand type.
The intern table gains a second map for it, keyed by the input node.

The largest wall win since 4a, and unambiguous: 11.07 s against a 5.45 s spread.

One thing had to be fixed for the memo to survive at all, and it would have failed silently.
`Engine.withIntern` and `Store.consC` decide whether to write the table back by comparing
`Intern.size` — which counts canonicalised structures and deliberately ignores the new map. A run
that only added memo entries would therefore have written nothing back and discarded them, leaving
the memo permanently cold while still paying to build it. Both guards now use a new `entries`
stamp that counts both tables; `size` keeps its report meaning.

Byte identity: fixed point holds, and the rail is identical on both artefacts — which is the
check that matters here, because a widen that differed from the old one would change specialization
identity with no compile error.

Gates: `full` 1731/1731; unit suite 13,565 with the same 12 pre-existing failures. Kept as
`keep-11b`. 11a (one widen per enqueue, and the lazy render) remains a separate entry.

### 11a — lazy ground-key render in `stampSelfSpine` — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 277.60 | 1238 | 10 | 20301 | 12,073,940 | 13,336,625 | same |
| r2 | 276.33 | 1238 | 10 | 20301 | 12,074,196 | 13,336,625 | same |
| r3 | 277.42 | 1238 | 10 | 20301 | 12,071,668 | 13,336,625 | same |
| **median** | **277.42** | **1238** | **10** | **20301** | **12,073,940** | 13,336,625 | same |
| D vs 11b | -0.69 (-0.25 %) | **-5** | 0 | +17 | +15,572 (+0.13 %) | +427 | — |

`stampSelfSpine` built its ground key eagerly — a full pure rebuild of the demand type followed by
a multi-kilobyte string render — on every global reference and every global call, roughly 141,000
times per run. One arm reads it: a depth-0 Define, TrackedDefine, Link or Cycle head with a
declared arity above zero on an arrow demand. It is now a thunk, forced at that one site.

WIN on rule 2: wall flat, minor cycles down 5. The gain is smaller than the eager work suggests,
which says the consuming arm is hit often enough that the thunk is usually forced — the saving is
the minority of calls that never read it, not the majority.

This row also needed two triples, for the opposite reason to step 9's. The first had identical
counters on all three runs but a 8.94 s wall spread — 3.24 %, over the disturbance threshold — with
one slow run among two fast ones. Re-running gave a 1.27 s spread and a median 1.8 s slower than
the first triple's. Where step 9's first triple was disturbed in its COUNTERS, this one was
disturbed only in wall, and the protocol's spread check is what caught it.

Byte identity: fixed point holds, rail identical on both artefacts. Gates: `full` 1731/1731; unit
suite 13,565 with the same 12 pre-existing failures. Kept as `keep-11a`.

Not done in this entry, and left for a later one: the specification's other half, which routes the
INTERNED widen from `enqueueSpecKeyed` into the stamp so the type handed to the registry is
pointer-identical to the stored one. That needs the widen to be threaded through `stampSelfSpine`,
which is a signature change across the stamp path rather than a local edit.

### 14 — inline the HPointer resolve in the kernel export path (runtime) — **LOSS, reverted**

| triple | r1 | r2 | r3 | median | spread |
|---|---|---|---|---|---|
| first | 280.37 | 282.61 | 278.32 | 280.37 | 4.29 |
| second | 282.65 | 276.40 | 274.53 | 276.40 | 8.12 |
| pooled (6 runs) | | | | **~279.4** | — |

GC counters were IDENTICAL to the reference in all six runs — 1238 / 10 / 20301 — which is
expected and is the whole problem with judging this step.

`Allocator::resolve` was split into an inline fast path in the header and an out-of-line
`resolveSlow`, so that `RuntimeExports.cpp` and the kernel translation units could inline it;
there is no LTO in this build, so previously they could only call it.

**Not kept, and this step cannot be resolved by this instrument.** It allocates nothing, so no GC
counter can move, which means rule 2 can never fire and wall is the only signal. Wall on this box
has a between-triple resolution of about 5 s, as step 9 and step 11a both demonstrated. The effect
here is smaller than that: the two triples straddle the reference, the pooled median is ~2 s
SLOWER, and the second triple's own spread was 8.12 s. There is no honest reading in which this is
a measured improvement, and the measured direction is the wrong one.

Why it plausibly costs rather than saves, which the profile could not show: `resolveFast` was
ALREADY an inline fast path with exactly this body, and the hot kernel dereferences use it. What
this step adds is inlining the same fast path into the roughly 300 `resolve()` call sites, most of
which are cold. That is code growth at cold sites in exchange for a call saved at sites that were
not hot — a classic inlining regression, and it does not show up in a self-time profile of
`Allocator::resolve`, which is what the 7.7 % figure was.

Reverted with `restore keep-11a` and the runtime rebuilt. The reference row is unchanged.

### 19' — geometric `revMemo` growth — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 283.62 | 1239 | 10 | 20316 | 12,134,468 | 13,336,426 | same |
| r2 | 281.54 | 1239 | 10 | 20316 | 12,133,968 | 13,336,426 | same |
| r3 | 277.91 | 1239 | 10 | 20316 | 12,135,168 | 13,336,426 | same |
| **median** | **281.54** | **1239** | **10** | **20316** | **12,134,468** | 13,336,426 | same |
| D vs 11a | +4.12 (+1.49 %) | **+1** | 0 | **+15** | **+60,528 (+0.50 %)** | -199 | — |

The specification's fallback for step 19, chosen over the full version deliberately: the full one
makes `revMemo` a second `Eco.CellStore` with a lifecycle paired to the point store, and a handle
from the wrong lifetime there is a silent wrong id rather than a crash — too much exposure for an
effect the plan sizes at about a second, which is under this box's wall resolution.

**Not kept.** Wall is up 4.12 s, flat against the 5.71 s spread, and nothing improved: one more
minor cycle, 15 MiB more promoted, 60 MB more peak RSS.

The reasoning behind the change was that every var mint pays a `repeat`, a `push` and an `append`
to grow the array by exactly the gap, so growing geometrically would amortise that away. The
measurement says the trade goes the other way, and the RSS column says why: gaps between
consecutive var mints are SMALL — a few structure Points — so the per-mint growth was small, while
doubling an array that reaches roughly 825,000 entries retains up to twice the trie and copies it
in large bursts. Paying O(gap) often beat paying O(n) rarely at this gap distribution.

Reverted with `restore keep-11a`, verified. The reference row is unchanged. The full step 19
remains unbuilt and its premise is now doubtful: if the growth pattern is not the cost, moving the
array into a cell store buys only the `Just` boxes, and it carries the lifecycle risk above.

### 22a — skip the discarded parameter classify in `specializeLambda` — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 280.49 | 1237 | 10 | 20293 | 12,078,924 | 13,336,740 | same |
| r2 | 277.42 | 1237 | 10 | 20293 | 12,074,804 | 13,336,740 | same |
| r3 | 278.01 | 1237 | 10 | 20293 | 12,075,144 | 13,336,740 | same |
| **median** | **278.01** | **1237** | **10** | **20293** | **12,075,144** | 13,336,740 | same |
| D vs 11a | +0.59 (+0.21 %) | **-1** | 0 | **-8** | +1,204 (+0.01 %) | +115 | — |

`specializeLambda` classified every parameter type and then used only the NAMES from that result
whenever the head type peeled to the right arity — which is the normal case, not the fallback. The
classification now runs only when the peel does not line up.

WIN on rule 2: wall flat within a 3.07 s spread, with both exact counters down. Small, as the
sub-item's own estimate implied.

The rail's manifest is identical on all 633, and the census differs on 1,060 lines that are all
zonk counts and their ledger lines — `sets zonked` falls, for instance 756 to 725 on one workload,
because the discarded classifications were being counted. The specification predicted exactly this.
Two checks make it safe to accept: every one of the 1,266 ledgers still reports RECONCILES=yes, so
the counts remain internally consistent, and not one `MSET` line moved, so no member content
changed.

Gates: `full` 1731/1731; unit suite 13,565 with the same 12 pre-existing failures. Kept as
`keep-22a`. Sub-items (b), (c) and (d) of step 22 are not done.

### 16a — inert-callee instantiation skip (D1) + trivial-signature load (D8) — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 276.01 | 1252 | 10 | 20317 | 12,083,308 | 13,337,888 | same |
| r2 | 276.86 | 1252 | 10 | 20317 | 12,088,760 | 13,337,888 | same |
| r3 | 272.80 | 1252 | 10 | 20317 | 12,082,308 | 13,337,888 | same |
| **median** | **276.01** | **1252** | **10** | **20317** | **12,083,308** | 13,337,888 | same |
| D vs 22a | -2.00 (-0.72 %) | **+15** | 0 | **+24** | **+8,164 (+0.07 %)** | +1,148 | — |

A global call whose signature is trivial and whose call type and arguments are all arrow-free
cannot reach a set slot, so the isolated instantiation and its per-argument unifies were skipped;
and a trivial signature now takes the plain isolated load, because the arrow-ordinal array it
would otherwise build exists only to be indexed by facts that never arrive.

**Not kept.** Wall fell 2.00 s but that is inside the 4.06 s spread, and every other stat moved
the wrong way — 15 more minor cycles, 24 MiB more promoted. A change that SKIPS work is not
supposed to allocate more.

The likely mechanism, and the lesson: the inert test runs at EVERY global call, walking the call's
type and every argument type and allocating a closure for the `List.all`, while the skip only pays
off on calls that are actually inert. The specification expected the inert class to be the
majority; the counters say the predicate is being paid far more often than it saves. It sized the
skipped work but not the test, and a guard evaluated on the hot path is itself hot-path work.

Reverted with `restore keep-22a`, verified. The reference row is unchanged. The other parts of
step 16 — D2, D4, D10, D12 — are untouched and are not condemned by this result; D4 in particular
skips a whole store DFS whose only reader is report-gated, and has no per-call predicate.

### 24(i) — `varSuccRounds` pre-scan + pointer-preserving rebuild — **LOSS, reverted**

| run | wall (s) | — | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
| r1 | 281.94 | — | 1250 | 10 | 20239 | 12,028,904 | 13,337,155 | same |
| r2 | 282.38 | — | 1250 | 10 | 20239 | 12,048,384 | 13,337,155 | same |
| r3 | 283.19 | — | 1250 | 10 | 20239 | 12,028,532 | 13,337,155 | same |
| **median** | **282.38** | — | **1250** | **10** | **20239** | **12,028,904** | 13,337,155 | same |
| D vs 22a | +4.37 (+1.57 %) | — | **+13** | 0 | **-54** | **-46,240 (-0.38 %)** | +415 | — |

Interleaved A/B against the reference, which is what settled it:

| pair | ref (22a) | cand (24i) | diff |
| 1 | 278.56 | 279.92 | **+1.36** |
| 2 | 280.50 | 281.77 | **+1.27** |
| 3 | 275.85 | 277.54 | **+1.69** |
| median paired difference |  |  | **+1.36** |

`succType` rebuilds every registry type on every settle round — six full passes per run — and
already computed a "changed" flag it ignored. It now returns unchanged nodes by pointer, and a
`hasVarAnno` pre-scan skips subtrees that cannot contain a successor write at all.

**Not kept: 1.36 s slower, in all three pairs, with a paired spread of 0.42 s.** That is the
tightest measurement in the whole series and leaves no ambiguity. The plain triple had said +4.37 s
against a reference measured two hours earlier; the true figure is +1.36 s, and both agree on the
sign, so the revert is right either way.

It is the same lesson as 16a, which is now a pattern worth naming: **the pre-scan is a full walk
of the subtree, so every subtree that DOES contain a var annotation is walked twice.** Promoted
fell 54 MiB and RSS 46 MB — the pointer preservation is real and does share structure — but minor
cycles rose 13, which is the scan's own `Dict.foldl` closure per record node. Sharing the output
was worth less than walking the input twice cost.

What would be worth trying instead, and is NOT what was built: fuse the test into the walk, so a
single pass both decides and rebuilds, returning the input node by pointer when nothing below it
changed. The pointer preservation half of this change was sound; only the separate pre-scan was
not.

**A compiler bug was found on the way here and is worth recording.** The first form of this change
split the guard into a wrapper plus a worker, making `succType` and `succTypeGo` two MUTUALLY
RECURSIVE let-bound local functions. The compiler accepted the source and emitted MLIR that would
not parse: `invalid value index: 18446744073709551615`, which is -1 as an unsigned 64-bit word.
Merging them into one self-recursive function fixed it. The bug is in the compiler, not in this
step, and it is unrelated to anything the loop has changed — `bin/eco-opt22a` is the compiler that
mis-emitted, and it predates this entry. Reproducer: two mutually recursive functions bound in one
`let` inside a large function.

Reverted with `restore keep-22a`, verified. The reference row is unchanged.

### 12 (surgical form) — key `lssSignatures`/`lssInProgress` by `Global`, not by a built string — **LOSS, reverted**

| run | wall (s) | — | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
| r1 | 278.49 | — | 1256 | 10 | 20292 | 12,044,948 | 13,353,457 | same |
| r2 | 275.58 | — | 1256 | 10 | 20292 | 12,050,456 | 13,353,457 | same |
| r3 | 274.24 | — | 1256 | 10 | 20292 | 12,046,092 | 13,353,457 | same |
| **median** | **275.58** | — | **1256** | **10** | **20292** | **12,046,092** | 13,353,457 | same |
| D vs 22a | -2.43 (-0.87 %) | — | **+19** | 0 | -1 | -29,052 (-0.24 %) | **+16,717** | — |

Interleaved A/B, which did NOT resolve it:

| pair | ref (22a) | cand (12s) | diff |
| 1 | 281.40 | 281.06 | -0.34 |
| 2 | 281.44 | 280.01 | -1.43 |
| 3 | 275.38 | 278.35 | **+2.97** |
| median paired difference |  |  | -0.34 |

Chosen over the specification's full `GlobalId` refactor because the re-profile named the target
precisely: 8.2 % of the run is string comparison, and `signatureFor` probes `lssSignatures` about
twice per translated call — roughly 10^6 times — each probe building a 25-50 character key and
then doing 14-16 compares over a long shared prefix. `TOpt.globalHash` and a `HashMap` keyed by
the `Global` itself remove both.

**Not kept.** The A/B is the first in this series whose pairs disagree in SIGN, so wall is
unresolved; and minor cycles rose 19, which is exact. RSS improved 0.24 %, and the letter of rule
2 would call that a win — one of the listed counters improved — but that reading ignores the rule's
own ORDER. Minor GC is judged before RSS precisely because it is deterministic, while RSS is the
bimodal column this machine is on record for. Taking a win on the least reliable stat while the
most reliable one regresses would be gaming the rule, so the step is reverted.

Why it cost rather than saved is NOT established, and the obvious explanation was checked and
ruled out. The suspicion was that `HashMap.get` takes the hash and the equality as ARGUMENTS, so
every probe would pass two functions where `Dict.get` passed none — a closure per probe on a 10^6
path. The lowered compiler says otherwise: `Data_HashMap_*` appears as neither a defined nor a
called function anywhere in the 13 MB of MLIR, only inside report string literals. Every HashMap
operation is inlined and specialised at its call site, so the function arguments cost nothing.

So the regression is unexplained. What is known: 19 more minor cycles, and the emitted source grew
16.7 kB, the largest growth of any step in this series. The remaining candidates are the insert
path — `HashMap.insert` scans the bucket with `bucketMember` before rebuilding it, and a table of
~43,000 signatures makes that bucket work real — and the fact that a `Dict String` probe allocates
NOTHING once the key exists, so the string build it saves may simply be cheaper than the bucket
machinery it adds.

**This matters beyond this step.** Steps 13, 17 and 21 all assume that replacing a `Dict String`
with a hashed table is close to free. This measurement says that assumption needs evidence per
site, not in general: the win has to come from removing the KEY CONSTRUCTION on a path where the
probe count is high and the insert count is low. `lssSignatures` has 43,000 inserts against a
million probes, which should have been the favourable case, and it still lost.

Reverted with `restore keep-22a`, verified. The reference row is unchanged.

### 27 (new, from the re-profile) — hash the `.ecot` string-intern table — **LOSS, reverted**

| run | wall (s) | — | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
| r1 | **311.63** | — | **1310** | **11** | **20825** | 12,048,200 | 13,342,310 | same |

One run was enough: +33.6 s, +73 minor cycles, an extra MAJOR collection, 532 MiB more promoted.
The remaining runs were abandoned.

This step came from attributing the re-profile's 8.2 % string-comparison block to its callers,
which is worth recording because it is not where this plan has been looking:

| caller of the string compare | share |
| `Compiler.AST.StringTable.string` | 20.6 % |
| `Compiler.Elm.Package.collectStringsFromName` | 13.2 % |
| `Mlir.Bytecode.AttrType.attrIndex` | 10.9 % |
| `Compiler.Elm.ModuleName.collectStringsFromCanonical` | 9.3 % |
| `Compiler.AST.Canonical.collectStringsFromType` | 7.7 % |
| `Engine.internMemberKey` (step 13's target) | 14.3 % |
| `Engine.lambdaMemberLayoutQualified` + `insertMemberKey` | 4.7 % |

About two thirds is artifact and bytecode string INTERNING, and under a fifth is the LSS member
keys step 13 exists to remove. The largest single string cost in this compiler today is in
EMISSION, outside this plan's scope.

`StringTable.strToIdx` is a `Dict String Int` probed once per encoded string field, keyed by
module paths and qualified names that share long prefixes. Hashing it looked like the textbook
case: the keys already exist so nothing is built, the table is written once and read many times,
and a probe costs about sixteen prefix-walking comparisons.

**It lost badly, and the reason is the lesson.** The comparison it replaced runs in C++
(`Elm::StringOps::compare`, essentially a memcmp). The hash replacing it runs in ELM:
`String.foldl` over every character, which in this compiler is a closure invocation per
character. One Elm-level pass over a whole key costs far more than sixteen native partial
compares.

**This condemns the naive form of steps 13, 17 and 21**, and any other `Dict String` to hashed
conversion, unless the hash is computed in the kernel or already carried on the value. Every
hashing step that HAS won here (2, 4, 11b) hashes something with a precomputed integer already on
it, never a string walked per probe. Step 13's real value is that it removes the key
CONSTRUCTION, replacing strings with integers end to end; it must not be built as "the same
strings, hashed".

Reverted with `restore keep-22a`, verified.

### 20 — `Point` equality by index rather than through the generic `==` — **no win, reverted**

GC counters were IDENTICAL to the reference in all runs (1237 / 10 / 20293), which is expected:
the change allocates nothing.

| pair | ref (22a) | cand (20) | diff |
| 1 | 279.48 | 279.03 | -0.45 |
| 2 | 275.62 | 279.04 | +3.42 |
| 3 | 275.74 | 275.86 | +0.12 |
| median paired difference |  |  | **+0.12** |

`Point` is a single-constructor box around an `Int`, so `==` on two of them goes through the
kernel's structural equality to reach the answer an integer compare gives directly. The three
sites in `UnionFind` — the compression test in `reprS`, the already-equal test in `unionS`, and
`equivalentS` — now compare indices.

**Not kept, and this is an instrument limit rather than evidence of harm.** The change strictly
reduces work per operation and is provably equivalent. But it allocates nothing, so no counter can
move, and the paired A/B disagrees in sign with a median of +0.12 s. Under the rule a step that
cannot be shown to help is not kept. This is the same position step 14 ended in, and both should
be revisited with a microbenchmark rather than a whole-compile timing.

### 13 (subset) — memoise the ground-arrow key on `(paramT, resultT)` — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) |
| r1 | 286.22 | 1262 | **11** | 20325 | 11,988,428 |
| r2 | 284.42 | 1262 | **11** | 20325 | 11,996,524 |
| D vs 22a | **+6 to +8** | **+25** | **+1** | +32 | -87,000 |

`groundSetMembers` builds its annotation-widened arrow key with a full pure `widenSets` rebuild
plus a `toComparableMonoType` render, once per SET-SLOT READBACK — on the order of 825,000 times
a run — although it is a pure function of `paramT` and `resultT`, both canonical with precomputed
hashes. Memoising it looked like step 4a's shape, which was the biggest win in the series.

**Not kept, and the reason is a corollary to entry 27: do not memoise a large STRING.** The saving
is real, the widen and the render stop repeating, but each entry retains a multi-kilobyte string
for the life of the run and there are many distinct arrow shapes. That shows up exactly where you
would expect: an extra MAJOR collection, 25 more minor cycles, and RSS moving 87 MB the other way
as the retained table trades against the nursery. Step 4a's memo retained interned `MonoType`s
that were already live; this one manufactures new retention.

Which is the argument for step 13 PROPER rather than any shortcut to it: the win is not caching
the rendered key, it is never rendering one — member identity as an integer end to end. Both
attempts to approximate that, this entry and entry 27, lost for the same underlying reason.

### 23 — lazy kernel-ABI `MVarEnv` + gate `widenedByKernel` — **no win, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) |
| median of 3 | 280.87 | 1237 | 10 | **20255** | 12,109,264 |
| D vs 22a | +2.86 | 0 | 0 | **-38** | +34,120 |

| pair | ref (22a) | cand (23) | diff |
| 1 | 279.70 | 277.59 | -2.11 |
| 2 | 276.41 | 279.19 | +2.78 |
| 3 | 274.28 | 276.30 | +2.02 |
| median paired difference |  |  | **+2.02** |

An `MVarEnv` was built on every kernel call and every bare kernel reference, through its own
`Engine.andThen` layer. `deriveKernelAbiMode` ignores it — its third parameter is literally `_` —
and the only consumer is one branch, so the parameter was dropped from that function (three
callers) and the env is now built inside the branch that reads it. The ungated `widenedByKernel`
counter, which costs an `S` and an `LssStats` copy per rowless or refused boundary and is read
only by a report line, is now behind the report flag.

**Not kept.** Both measurements lean slower: the triple is +2.86 s and the paired A/B is +2.02 s
with two of three pairs positive. The only improvement is 38 MiB of promotion, 0.19 %. Treating
that as a rule-2 win while two independent wall measurements lean the other way would be the same
mistake rejected in entry 12.

The parameter removal is worth keeping in mind independently: `deriveKernelAbiMode` taking an
argument it ignores is a wart, and dropping it is correct regardless of timing. It is reverted
here only because it travelled with the rest of the entry.

### 17 — `Data.HashMap` buckets: `Dict Int` to an array-backed table — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) |
| r1 | 276.68 | 1262 | 10 | 20284 | 12,089,348 | 13,408,214 |
| r2 | 281.28 | 1262 | 10 | 20284 | 12,090,552 | 13,408,214 |
| r3 | 279.02 | 1262 | 10 | 20284 | 12,090,480 | 13,408,214 |
| **median** | **279.02** | **1262** | **10** | **20284** | **12,090,480** | 13,408,214 |
| D vs 22a | +1.01 | **+25** | 0 | -9 | +15,336 | +71,474 |

The bucket map was a red-black `Dict Int`, so every insert copied a path of about seventeen nodes
to store a bucket found by a hash that needs no ordering. Replaced with a power-of-two `Array`
indexed by a mask, doubling at a load factor of two, sequence numbers carried across the rehash so
iteration order is untouched.

**Not kept: 25 more minor cycles.** The reasoning was right about the intern table, which has
around 100,000 inserts, and wrong about everything else. Most `HashMap`s in this compiler are
SMALL and short-lived — per-item tables that hold a handful of entries — and for those the change
replaces a `Dict` that starts genuinely empty with a 64-element `Array.repeat` at construction,
plus a 32-wide trie node copy per `Array.set`. The big table's saving is real but it is outnumbered.

The obvious repair is a smaller initial capacity, or keeping a list until the map outgrows it.
Neither was tried: at a measured +25 minor cycles the headroom is a fraction of a percent, which
this instrument cannot resolve, so it would be tuning against noise.

### 16 (D4) — skip the report-only store DFS in `degradeToSymmetric` — **no win, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) |
| r1 | 280.68 | 1238 | 10 | 20387 | 12,120,732 |
| r2 | 282.58 | 1238 | 10 | 20387 | 12,111,840 |
| delta vs 22a | +3 | +1 | 0 | +94 | +40,000 |

`storeMentionsArrow` is a full store depth-first walk that threads and copies `S` per visited node,
and its only consumer is the arrow-mention test feeding `bumpFlowDegraded`, which is itself already
report-gated. Off report the walk computes a Bool and throws it away, so the candidate skips it --
the same pure-removal shape that won in steps 6 and 7.

**Not kept: nothing improved.** The only reading consistent with a pure removal making every stat
slightly worse is that the site is RARE -- `degradeToSymmetric` fires on container-typed directed
flows only -- so there was almost nothing to remove, and what remains is the noise floor plus the
162 bytes of added source. The step's own estimate was a fraction of a percent, and that is what it
measured. Run 3 was abandoned once the first two runs agreed on both the sign and the counters
(which are deterministic per binary x tree, so r1 == r2 on all four of them is conclusive).

### 15 — `enqueueSpecKeyed` hit path (`15b`: tally probe behind the budget, widen on create only) — **LOSS, reverted**

Measured with the INTERLEAVED form (`lss-loop-ab.sh eco-opt22a eco-opt15 3`), because the step's
own estimate (1-3 % of the mono window) is below the unpaired wall resolution.

| pair | ref `eco-opt22a` | cand `eco-opt15` | diff |
| 1 | 273.35 | 278.54 | **+5.19** |
| 2 | 278.39 | 280.81 | **+2.42** |
| 3 | 279.63 | 284.46 | **+4.83** |

Median paired difference **+4.83 s (+1.7 %)**, same sign in all three pairs, against a paired
resolution of 0.42 s. GC counters IDENTICAL in both arms (1238 / 10 / 20318 MiB), RSS identical to
four digits. `cmp` confirms the two arms emit BYTE-IDENTICAL MLIR (13,337,065 B), the candidate
reproduces `eco15.mlir` exactly (fixed point, so no extra bootstrap turn was owed after all), and
the three candidate runs agree byte-for-byte.

What the candidate did, all three of which the spec expected to pay off on the ~98K keyed HITS:
build `Mono.toComparableGlobal`'s five-part string and probe `specCountByGlobal` only when
`maxSpecsPerGlobal > 0` (it is 0 by default); run `Intern.widenSets` only on the over-budget arm
or on a CREATE (its only two consumers -- the over-budget dedup key and `recordSpecWidenedKey`);
and skip the `{ s | registry, specCountByGlobal, lssStats }` rebuild on the hit path entirely.

**It is slower, reproducibly.** The hit path genuinely does less work, so the cost is elsewhere in
the same function: the rewrite splits one straight-line `let` into a two-armed `if created`, with
bindings live across both arms, and moves the widen from a fixed position before the registry probe
to a position after it inside one arm. Either the function stopped being inlined at its call sites,
or the create arm's now-cold `Intern.widenSets` lost the locality that came from running on every
enqueue. This is the same shape as steps 16a and 24i: **a guard on a hot path is hot-path work**,
and here the guard's structural cost exceeded the ~98K x (one string concat + one red-black
descent + one memoised widen) it was buying back.

**Do not re-try `15b` as written.** If this is revisited, the only piece worth isolating is the
tally probe alone (`15a`), left in the straight-line `let` with no `if created` split -- but note
that the create path needs the key regardless, so the saving is confined to hits and is smaller
than what was measured here as a net loss.

### 18b — per-literal string-intern cache in the codegen — **WIN, kept**

The first entry in this series that changes the CODEGEN (`eco-boot-native`) rather than the
compiler source or the runtime library. The candidate is `eco22a.mlir` -- the reference's own,
unmodified MLIR -- lowered by the rebuilt `eco-boot-native`, so byte-identity is structural:
there is one MLIR file and both arms compile it.

| pair | ref `eco-opt22a` | cand `eco-opt18b` | diff |
| 1 | 279.97 | 275.76 | **-4.21** |
| 2 | 280.63 | 279.22 | **-1.41** |
| 3 | 276.65 | 274.49 | **-2.16** |

Median paired difference **-2.16 s (-0.78 %)**, same sign in all three pairs, against a paired
resolution of 0.42 s. GC counters identical (1237 / 10 / 20293 MiB -- the change removes no
allocation, the interning already deduped). Max RSS **12,126,548 kB vs 12,135,400**, -8.7 MB.
`out.mlir` byte-identical between the arms (13,336,740 B) and identical to `eco22a.mlir`.

**What it does.** Every evaluation of a string literal -- `"Int"` in a `case name of` arm as much
as any literal in ordinary code -- lowered to
`llvm.call @eco_alloc_string_literal_utf8(@__eco_str_N, len)`. That callee is not gc-leaf (its
miss path allocates), so RS4GC statepoints it: every live `ptr addrspace(1)` in the function is
spilled and reloaded around what is, after the first evaluation, an `unordered_map` lookup
returning a pointer that can never change. The pass now gives each `__eco_str_*` bytes global a
zero-initialised `__eco_strlit$<name>` i64 sibling and rewrites each call into the same diamond
the CAF caller-side fast path (Run W) uses:

    %bits  = llvm.load @__eco_strlit$__eco_str_N
    %isset = llvm.icmp ne %bits, 0
    scf.if %isset -> ptr<1> { scf.yield __eco_slot_to_hptr(%bits) }        // no call
    else { scf.yield llvm.call @eco_string_literal_utf8_fill(bytes, len, slot) }

Three files of codegen (`materializeStringLiteralSlots` + `rewriteStringLiteralCallSitesFast` in
`EcoToLLVMGlobals.cpp`, wired into the serial post-Stage-2 phase of `EcoToLLVM.cpp`) and two new
runtime exports (`eco_string_literal_fill` / `eco_string_literal_utf8_fill`) that publish the word
**only** when the interned object landed in the PermanentSpace. That condition is what makes the
slot legal without a GC root: a permanent object is immortal, GC-invisible and never moves
(HEAP_036), so `createGlobalRootInitFunction` skips the `__eco_strlit$` prefix exactly as it
skips `__eco_caf$`. On the old-gen fallback the slot stays 0 and every evaluation keeps calling
through, rooted by `internLiteral` as before. The hit arm's i64 -> ptr<1> crossing is
`globalLoadI64ToValue`, the REP_LLVM_002 barrier form. `ECO_STRLIT_CACHE=0` restores the bare call.

**Gates.** E2E `cmake --build build --target full`: **1731 / 1731 passed**. The lowered compiler
reproduces `eco22a.mlir` byte-for-byte on a self-compile -- a workload that evaluates string
literals by the million, which is the strongest available correctness evidence for this change.
The 633-workload rail does not apply: it gates FRONT-END (Elm source) drift through the JS Stage-1
compiler, and no Elm source changed. `elm-tests` likewise unchanged -- the compiler source is
exactly `keep-22a`'s.

**Where the 2.16 s came from, and the ceiling.** `eco_alloc_string_literal_utf8` was 0.60 % of the
self-compile's samples (1.22 % of the mono window), i.e. ~1.7 s of self time, and the measured win
is larger than that -- the difference is the statepoint traffic the call forced on its callers,
which never appeared under its own symbol. The candidate binary is 1.8 MB LARGER (74,890,920 vs
73,067,112) because every literal site grew a diamond; the win is net of that.

**This also raises the value of step 18a**, which was specified to run second: with the intern
probe gone, what remains at `normalizePrimHome` / `classifyApp` / the `Zonk` `TType` arm is the
`Utils.equal` chain itself, and 18a cuts that from up to 8 compares per node to at most 3 (0 for a
non-primitive name).

### 18a — length-first primitive-name dispatch (`normalizePrimHome`, `classifyApp`, `Zonk`'s `TType` arm) — **LOSS, reverted**

Measured immediately after 18b, against it (`lss-loop-ab.sh eco-opt18b eco-opt18a 3`).

| pair | ref `eco-opt18b` | cand `eco-opt18a` | diff |
| 1 | 279.37 | 281.54 | **+2.17** |
| 2 | 272.86 | 281.66 | **+8.80** |
| 3 | 275.36 | 277.21 | **+1.85** |

Median paired difference **+2.17 s**, same sign in all three pairs. GC counters identical
(1259 / 10 / 20293 -- 1259 rather than 18b's 1237 because BOTH arms compile the 18a source, which
is larger; the comparison is still like-for-like). Both arms emit byte-identical MLIR
(13,341,056 B) and the candidate reproduces `eco18a.mlir` exactly, so the rewrite is BI as
predicted -- it is simply slower.

The candidate replaced `case canonical of ModuleName.Canonical ( "elm", "core" ) _ -> case name of
"Int" | "Float" | "Bool" | "Char" | "String" | "List"` with `case String.length name of` followed
by at most three `name == "..."` compares and, only on a name hit, the module test. The three
sites are `Store.normalizePrimHome` (every `App1` load), `Store.classifyApp` (every `TType` zonk)
and `Zonk.canTypeToMonoWithI`'s `TType` arm.

**18b removed 18a's premise.** The spec priced the old shape at "up to 8 intern probes + 8
statepoint calls + up to 8 `Utils.equal` calls" per node; 18b deleted the probes and the
statepoints, and what is left of a string-pattern arm is a `__eco_value_eq` whose FIRST test is
raw pointer equality against an interned literal -- for a type name that is itself interned, that
hits on the first arm with one compare. Against that, `String.length` plus an Int `case` plus an
explicit `==` chain is more work, not less. This is the third instance in the series of the same
lesson recorded at 16a and 24i: **once the thing being skipped is cheap, the test that skips it
dominates.** It is also the second time in one sitting (with 15) that a plan step aimed at a hot
path lost because the plan priced the work removed and not the code added.

**Do not re-try.** 18a's estimate (2.2 % of the mono window) was for the pre-18b shape and no
longer exists.

### 22b — one member mint per lambda — **WIN on the counters, kept**

`classifyLambdaHead` already mints the lambda's member id (via
`LssInfer.injectLambdaMemberQualified` -> `Engine.lambdaInstanceMemberId`), and then
`specializeLambda` minted it a SECOND time through `Engine.lambdaInstanceMemberMaybe` purely to
fill `ClosureInfo.lssMember`. The second call is state-idempotent but not cheap: every one runs
`instanceQualTagFor`, the `rootLamOf` fold, `layoutQualKey` (a multi-kilobyte string concat) and a
`byKey` probe. `LssInfer.injectLambdaMemberQualifiedId` now returns the id, `classifyLambdaHead`
returns `( MonoType, Maybe Int )`, `specializeLambda` takes the member from there, and
`Engine.lambdaInstanceMemberMaybe` is deleted.

| pair | ref `eco-opt18b` | cand `eco-opt22b` | diff |
| 1 | 283.32 | 278.43 | -4.89 |
| 2 | 276.77 | 274.39 | -2.38 |
| 3 | 275.75 | 280.90 | **+5.15** |

| stat | ref | cand | delta |
| minor GC | 1238 | **1237** | -1 |
| major GC | 10 | 10 | 0 |
| promoted MiB | 20363 | **20335** | -28 |
| max RSS kB | 12,093,664 | **11,916,868** | **-176,796 (-1.5 %)** |

**Judged on the counters, not the wall.** The paired wall differences do not agree on a sign
(-4.89 / -2.38 / +5.15), so wall is FLAT by this instrument -- and the loop's rule is explicit
that flat wall with any other stat improved is a win. Here it is not one other stat but three, and
they are the DETERMINISTIC ones: minor GC, promoted bytes and max RSS are exact per
(binary x tree), so a 176 MB RSS drop is a fact at n=1, not an average. Deleting one of two mints
per lambda removing 176 MB of peak footprint is exactly the shape of the four biggest wins in this
series -- the cost of this compiler is allocation volume.

**Gates, all green.**
- Unit: 13,565 passed, the same 12 pre-existing POST_010 / golden-fingerprint failures.
- E2E `cmake --build build --target full`: **1731 / 1731**.
- 633-workload rail: **MLIR manifest byte-identical for every one of the 633 workloads**.
  The census differs on EXACTLY the three lines the specification predicted and no others --
  `layoutQual: mints=` (halved: e.g. 105 -> 53, 43 -> 23), `ARGF rootFold|folded` (halved), and
  `instanceQual: … rootSkip=`. Every `varsucc|`, `varctor|`, `varlam|`, `grounding:` and
  `members:` line is unchanged, which is the check that a mint-count change did not move
  precision.
- Fixed point: `eco-opt22b` reproduces `eco22b.mlir` exactly; both arms emit identical MLIR
  (13,336,584 B); the three candidate runs agree byte-for-byte.

LSS_017's requirement that a lambda be "stamped IDENTICALLY in its set injection and its
`ClosureInfo.lssMember`" now holds by CONSTRUCTION -- one mint, one id -- rather than by an
idempotence argument about two independent derivations.

### 22d — pointer-preserving `overlayAnnotations` (+ join entry test, `sameFieldKeys`) — **WIN, kept**

The largest single win since step 3, and the clearest confirmation of this series' one finding:
**what costs time in this compiler is allocation.**

| pair | ref `eco-opt22b` | cand `eco-opt22d` | diff |
| 1 | 277.92 | 268.50 | **-9.42** |
| 2 | 275.92 | 272.75 | **-3.17** |
| 3 | 279.27 | 270.19 | **-9.08** |

Median paired difference **-9.08 s (-3.3 %)**, same sign in all three pairs.
Minor GC **1250 vs 1259** (-9 cycles). Promoted **20,004 vs 20,333 MiB (-329 MiB)**. Major GC 10,
unchanged. GC time 126.32 vs 130.37 s.

**What was wrong.** `Mono.overlayAnnotations structural annoSource` rebuilt the ENTIRE type tree on
every call -- `mFunction` / `mList` / `mTuple` / `mRecord` / `mCustom` at every node, `List.map2`
at every argument list, and a whole fresh `Dict` via `Dict.map` at every record -- whether or not
the store zonk had contributed a single annotation. Its callers are the hottest paths in
translation: `classifyLambdaHead` runs it for every lambda head, and there are eight more sites in
`Translate`. The common case is that most of the tree is untouched, and all of that copying was
immediately garbage.

**The fix** is the protocol `joinAnnotationsChanged` next door already used, applied to the
overlay: `overlayAnnotationsChanged : MonoType -> MonoType -> ( Bool, MonoType )` rebuilds only
the spines that actually changed, leaves unchanged siblings pointer-shared, and returns
`structural` ITSELF when nothing changed at all. An O(1) `structural == annoSource` entry test
short-circuits the whole walk (pointer identity, or a packed-hash mismatch in the leading `Int`),
so only hash-equal distinct trees walk -- and that walk is cheaper than the rebuild it replaces.
`overlayAnnotations` stays as a `Tuple.second` wrapper, so **no call site changed**.

Two smaller pieces rode along, both in the same file:
- `joinAnnotationsChanged` gained the same `a == b` entry test (`joinAnnotations a a == a` in
  every arm, so the walk is skippable on equal inputs);
- `Dict.keys fieldsA == Dict.keys fieldsB` at all three record arms became `sameFieldKeys`, which
  decides the same predicate with no allocation (equal size plus every key of `a` in `b` implies
  equal key sets, since keys are unique) instead of building two `List Name` and comparing them.

**Gates, all green.**
- Unit: 13,565 passed, the same 12 pre-existing failures.
- E2E `cmake --build build --target full`: **1731 / 1731**.
- 633-workload rail: MLIR manifest byte-identical for every workload AND **the LSS census is
  byte-identical too -- not one line differs.** That is the strongest gate result in this series:
  22d changes no decision anywhere, only how much garbage is produced reaching them.
- Fixed point OK; both arms emit identical MLIR (13,339,565 B); the three candidate runs agree
  byte-for-byte.

**The part of the specification NOT built.** §9's step 22 also parameterises the walk by a `cons`
function so Engine can hash-cons each rebuilt node (`overlayS`/`enrichS`), and does the same for
the enrich family. That was deliberately left out: it requires threading `S` through twelve call
sites, and today's `overlayAnnotations` does not hash-cons either, so the pure pointer-preserving
form is a strict improvement with ZERO change in canonicality -- which is exactly why the census
came back identical. The `cons` variant remains available if the enrich sites are ever measured.

### 22c — the same pointer-preserving protocol for `enrichAnnotationsWith` — **LOSS, reverted**

The obvious follow-up to 22d: give the enrich family the identical treatment
(`enrichAnnotationsWithChanged` + `enrichListChanged` + `enrichFieldsChanged`, with the
`structural == annoSource` entry test, `enrichAnnotationsWith` kept as a `Tuple.second` wrapper so
no call site changes), plus the same `a == b` entry test on the PURE `joinAnnotations`.

| pair | ref `eco-opt22d` | cand `eco-opt22c` | diff |
| 1 | 273.18 | 276.63 | **+3.45** |
| 2 | 270.95 | 274.37 | **+3.42** |
| 3 | 270.42 | 271.00 | **+0.58** |

Median paired difference **+3.42 s**, same sign in all three pairs. Minor GC identical (1250),
promoted 20,000 vs 20,005 MiB (5 MiB better -- nothing), RSS slightly worse. Wall up ⇒ LOSS by the
rule, and the counters do not rescue it.

**Why the same change wins on overlay and loses on enrich.** `overlayAnnotations` is called to
transplant annotations that MOSTLY are not there -- a storeless classification overlaid with a
zonk that touched a few arrows -- so the no-op case dominates and pointer preservation skips a
whole-tree rebuild. Enrich is called precisely BECAUSE a merge is expected to add something: the
`merged /= annoA` test, the Bool threading and the extra `merge` indirection are paid on every
node, and the no-op case they buy is rare. The population, not the shape of the code, decides.

That makes 22c a fourth instance of the series' recurring lesson in a new form: it is not enough
for a transformation to be sound and to remove work in principle -- **the population it removes
work from has to be the common one**, and here the profitable population was already harvested by
22d next door.

**Do not re-try** without first counting no-op enrich calls; the transformation itself is correct
(it was byte-identical: both arms emitted 13,343,726 B) and is preserved in `try-22c`.

### 24(iii)+(iv) — `varSuccRounds` member decode through `sources`; delete dead `varArgIds` — **LOSS, reverted**

(iii) deleted the two per-ROUND dictionary builds at the head of `varSuccRounds` -- `midKeys`,
which inverts the 62,647-entry `byKey` into a `Dict Int String`, and `compGlobals`, which folds
`toptNodes` into a `Dict String TOpt.Global` building one `toComparableGlobal` string per global
-- and replaced the per-member `String.split "|" mkey` decode with a direct
`Dict.get m sources` read (`SourceGlobal g` -> `( g, 0 )`, `SourcePap g d` -> `( g, d )`),
keeping the `toptNodes` membership test as an O(1) hash probe. The `keysAcc` threading went with
it, since `papMemberIdFor` registers a freshly minted successor's source in the threaded `S`.
(iv) deleted `varArgIds` and `varCellWalk`'s dead `argIds` parameter (threaded through six
recursive calls, never read).

| pair | ref `eco-opt22d` | cand `eco-opt24k` | diff |
| 1 | 268.95 | 276.42 | **+7.47** |
| 2 | 269.99 | 275.39 | **+5.40** |
| 3 | 267.35 | 277.37 | **+10.02** |

Median paired difference **+7.47 s (+2.8 %)** -- the largest regression measured in this series.
Counters moved the right way but trivially: minor GC 1248 vs 1249, promoted 19,929 vs 19,935 MiB,
RSS -14 MB. Wall up ⇒ LOSS.

**Why deleting three big dictionary builds made it 7.5 s slower.** The builds are per ROUND --
three of them across the whole run. What replaced the lookup runs per MEMBER per arrow position
across all ~43K registry rows, and it contains
`HashMap.get TOpt.globalHash (==) g s.env.toptNodes`. **`TOpt.globalHash` hashes the global's
module name and name STRINGS in Elm -- a closure call per character** -- whereas
`Dict.get gstr compGlobals` bottoms out in the C++ string compare. This is entry 27's finding
exactly, arriving from the other direction: there, replacing a `Dict String` with a hashed table
cost 33.6 s; here, replacing a prebuilt `Dict String` probe with a hash probe cost 7.5 s. **In
this compiler a hash of a string is more expensive than the ordered comparison it replaces, and
the crossover is nowhere near three dictionary builds.**

Note what this does NOT say: the `sources` decode itself is sound and cheap (`Dict.get` on an Int
key). It is the `toptNodes` membership test that had to be re-derived per member, because
`compGlobals` was doing double duty as decode AND as the "is this global resolvable" filter. A
version that keeps `compGlobals` and only deletes `midKeys` was not measured; on this evidence
the remaining prize (one `Dict Int String` build of 62,647 entries, three times) is too small to
be worth another run.

(iv) is a genuine dead-code deletion and is preserved in `try-24k` for whenever this area is
touched again; it was measured only as part of this bundle and cannot have caused the loss.

### 24(i') — pointer-preserving `succType` (no pre-scan) — **WIN, kept**

Entry 24(i) earlier in this series lost: it added a `Mono.hasVarAnno` PRE-SCAN per registry row on
top of a pointer-preserving rebuild, and allocation went UP by 13 minor cycles. This is the same
target with the pre-scan removed -- exactly the shape that won as 22d: every arm of `succType`
returns its input `t` BY POINTER when nothing under it moved, and the record arm folds changed
fields into `fields` instead of building a new `Dict` from `Dict.empty`.

| pair | ref `eco-opt22d` | cand `eco-opt24i2` | diff |
| 1 | 277.31 | 272.36 | **-4.95** |
| 2 | 274.65 | 270.59 | **-4.06** |
| 3 | 267.12 | 268.45 | +1.33 |

Median paired difference **-4.06 s (-1.5 %)**. Minor GC **1246 vs 1250 (-4)** -- deterministic,
and it corroborates the wall: less was allocated. Promoted 19,962 vs 19,951 MiB (+11) and RSS
+8 MB, both trivial and both after the wall and the minor count in the judging order.

`succType` walks every one of the ~43K registry rows on every round of `varSuccRounds`, and used
to rebuild every node of every row whether or not a successor was written. The vast majority of
rows carry no pap-able var arrow at all, so essentially all of that was immediate garbage.

**A compiler bug got in the way, and the workaround is the interesting part.** The first version
also made the argument-list walks pointer-preserving, via a `succList` helper mutually recursive
with `succType`. That lowered to MLIR the backend could not parse --
`error: invalid value index: 18446744073709551615` -- which is the known miscompile of two
mutually recursive `let`-bound local functions (recorded as `elm-mutual-recursion-let-miscompile`;
the standing workaround is to merge them into one self-recursive function). Here merging is not
possible without changing the walk, so the `List.foldr` list rebuilds were kept and only the NODE
allocations are avoided. The list rebuild also has a correctness constraint worth recording: the
fold is a `List.foldr`, so state threads RIGHT TO LEFT, and any replacement must visit element i
after every element to its right or `papMemberIdFor`'s mint order -- and therefore every successor
member id -- changes.

**Gates, all green.** Unit 13,565 + the same 12 pre-existing failures; E2E **1731 / 1731**;
633-workload rail **MLIR manifest identical and the census byte-identical** (not one line
differs); fixed point OK; both arms emit identical MLIR (13,339,902 B).

### 21a — `BitSet` membership twin for `provisionalStandalone` — **LOSS, reverted**

The cheapest and hottest slice of step 21, isolated: `groundSetMembers`' fast path asks "is ANY
member of this slot provisional?" once per member per SET ZONK (654,140 zonks), and answered it
with `CoreDict.member mid provisionalStandalone` -- a red-black descent through 43K Int keys,
~13 Int compares and a pointer chase, per member. The candidate added
`provisionalBits : BitSet` to `LssMemberTable`, wrote it alongside the payload in
`insertMemberProvisional`, and switched the three membership tests (the fast-path `List.any`, the
deferral count, and the test fixture's hand-built table) to `BitSet.member`. The payload `Dict`
stays for the slow path.

| pair | ref `eco-opt24i2` | cand `eco-opt21a` | diff |
| 1 | 273.06 | 275.92 | +2.86 |
| 2 | 271.93 | 275.46 | +3.53 |
| 3 | 274.18 | 268.80 | -5.38 |

Median paired difference **+2.86 s**. Minor GC IDENTICAL (1247), promoted 19,966 vs 19,970 MiB
(-4 MiB, 0.02 %), RSS within noise. Wall up on the median with nothing deterministic improving
⇒ LOSS.

**What this measures, and what it does not.** `BitSet.member` is `Array.get (mid // 32)` on a
32-way persistent trie plus a shift and a mask — two or three indirections, not obviously fewer
than the red-black descent it replaces — and the new field widens `LssMemberTable`, so every
`{ t | … }` update on it copies one more slot. On this evidence the `Dict Int` -> bitmap swap is
not the free win step 21 assumes; **it is the same class of finding as entry 27** (a "cheaper"
container is only cheaper if the operation it replaces was actually the expensive part), arriving
now for Int keys rather than String keys.

This measures ONE of step 21's targets. `specWidenedKeys` / `rootLamOf` / `lambdaQualified` as
`Array` (indexed by a dense id rather than probed) and `flexCtorSpecs` as a `BitSet` are
**still unmeasured** and are not decided by this entry: an `Array.get` at a known dense index is a
different operation from a `BitSet.member`, and those tables are probed 3-4 times per mint over
43K/12K/30K entries rather than once per member per zonk. What this entry does establish is that
step 21's estimate ("~1 % of the mono window") cannot be assumed for any of them without its own
run.

### 24(vii)a — de-PAP `typeHasResidualNumber` — **WIN, kept**

**Nine lines, -6.87 s.** The best ratio of effect to edit size in the entire series.

Prune's `Mono.typeHasResidualNumber isNumber monoType` walks every live node type. At every
`MTuple`, `MCustom` and `MFunction` node it called `List.any (typeHasResidualNumber isNumber) xs`
-- and `typeHasResidualNumber isNumber` is a PARTIAL APPLICATION, so each of those nodes
allocated a PAP and then dispatched it generically once per element. Replacing it with a direct
`anyResidualNumber isNumber xs` recursion allocates nothing and calls directly. Identical
semantics: the same left-to-right `||` short-circuit, the same number of `isNumber` calls.

| pair | ref `eco-opt24i2` | cand `eco-opt24v7` | diff |
| 1 | 270.92 | 264.05 | **-6.87** |
| 2 | 271.49 | 266.78 | **-4.71** |
| 3 | 272.16 | 264.73 | **-7.43** |

Median paired difference **-6.87 s (-2.5 %)**, same sign in all three pairs. Minor GC
**1243 vs 1246 (-3)**. Promoted +10 MiB and RSS +18 MB, both trivial and both below wall and the
minor count in the judging order.

**The plan estimated this at 0.7 % of the mono window. It measured at 2.5 % of the whole run** --
roughly seven times the estimate. The plan priced the generic DISPATCH the PAP causes (which is
what the dispatch census could see); it did not price the PAP ALLOCATION, and in this compiler
allocation is what costs. That is the same correction the four biggest wins in this series all
made, and it generalises immediately: **`List.any`/`List.map`/`List.all`/`List.foldl` applied to
a PARTIALLY APPLIED function on a per-node path is an allocation per node**, and there is no
reason to think this was the only one.

**Gates, all green.** Unit 13,565 + the same 12 pre-existing failures; E2E **1731 / 1731**;
633-workload rail MLIR manifest identical AND census byte-identical; fixed point OK; both arms
emit identical MLIR (13,339,964 B).

Part two of the specification's (vii) -- threading a `seen : HashMap MonoType ()` through
`collectAllCustomTypes` so a node type costs one probe instead of one per `MCustom` inside it --
was NOT built: it touches ~30 call sites and, after 21a and 24(iii), a hash probe replacing a
cheaper operation is exactly the shape that has been losing. It remains unmeasured.

### 24(vii)b — de-PAP three more hot list predicates — **no win, reverted**

The direct follow-up to 24(vii)a: apply the same de-PAP to the other partially-applied list
combinators the grep turned up on the solver path --
`Mono.resolveNumberType`'s three `List.map (resolveNumberType isNumber)`,
`Store.groundNoArrowWith`'s two `List.all (groundNoArrowWith aliasMemo)`, and
`KernelSetFacts.hasFunctionCapable`'s two `List.any (hasFunctionCapable isScalarVar)`. Each
became a direct top-level recursion over the (arity-bounded) list.

| pair | ref `eco-opt24v7` | cand `eco-opt24v7b` | diff |
| 1 | 267.58 | 267.19 | -0.39 |
| 2 | 269.45 | 271.70 | +2.25 |
| 3 | 267.76 | 274.13 | +6.37 |

Median paired difference **+2.25 s**. Minor GC IDENTICAL (1243) -- which is the finding:
**the PAPs these sites allocate do not show up in the allocation counter at all**, so there were
few of them. Promoted 19,961 vs 19,972 MiB (-11) and RSS mixed. Wall up ⇒ no win.

**This bounds 24(vii)a's lesson rather than extending it.** The de-PAP is worth 2.5 % at
`typeHasResidualNumber`, which Prune runs over EVERY live node type, and worth nothing at three
sites that look identical in the source but are not hot: `groundNoArrowWith` is behind the alias
memo (step 4a/6), `hasFunctionCapable` runs on kernel signature checks (a few hundred), and
`resolveNumberType` only walks types that `typeHasResidualNumber` already said carry a residual.
The pattern `List.any (f x)` is a reliable *smell*; it is only a *cost* where the enclosing walk
is hot, and the minor-GC counter is the cheap way to tell the difference after the fact.

The three rewrites are correct and byte-identical (13,338,740 B both arms) and are preserved in
`try-24v7b`.

### 24(ii) — one `varSucc` pass; the verification pass is report-gated — **WIN, kept**

`settleVarSuccessors` ran `varSuccRounds` to a fixed point (fuel 16). The census said
`varsucc|rounds = 3`, which decomposes as (write + empty) for the first invocation plus (empty)
for the second -- **exactly one wasted traversal of all ~43K registry rows.** The pass is
idempotent, so that round could never do anything.

Why it is idempotent: rows are independent (`succType` reads only its own row's type and the
member table); within a row the walk is TOP-DOWN on the result spine, writing `LSet succ` at an
arrow and immediately descending into the rewritten result, so a chain of any depth completes in
one pass; the member table is monotone and `succSetFor`'s verdict for a member is a pure function
of its source, the arg count and `declaredArityOf`, all round-invariant, with freshly minted
successors visible immediately; and after the pass every writable position IS `LSet` while every
skipped position is skipped again for the same reason. The comment claiming "a row rewritten late
can expose a head an earlier row's walk passed over" described a cross-row dependency this code
does not have.

`varSuccRounds` became `varSuccPass : S -> ( S, Bool )`; `settleVarSuccessors` runs it once, and
under `report` runs it a second time as a VERIFICATION RAIL whose registry is discarded (so
report-on and report-off emit the same bytes) and only its counters kept.

| pair | ref `eco-opt24v7` | cand `eco-opt24ii` | diff |
| 1 | 268.41 | 264.70 | **-3.71** |
| 2 | 267.93 | 264.89 | **-3.04** |
| 3 | 268.60 | 270.28 | +1.68 |

Median paired difference **-3.04 s**, and **all three deterministic counters improved**:
minor GC **1241 vs 1243**, promoted **19,977 vs 20,002 MiB (-25)**, max RSS
**11,529,796 vs 11,551,176 kB (-21 MB)**.

**The idempotence argument was not just argued, it was measured.** The verification rail prints
`varsucc|verifyClean` -- never `varsucc|verifyCHANGED` -- for **every one of the 633 rail
workloads** (zero `verifyCHANGED` lines in the census), and the rail's MLIR manifest is identical
for all 633. The self-compile agrees: both arms emit byte-identical MLIR (13,340,422 B) and the
fixed point holds. The census differs only on `varsucc|rounds`-family lines
(`skipNoSucc`, `skipBeyond`, the new `verifyClean`), all report-only.

**Gates, all green.** Unit 13,565 + the same 12 pre-existing failures; E2E **1731 / 1731**;
rail manifest identical; fixed point OK.


### 5b — direct-state `Unify` combinator layer — **LOSS, reverted — and the most informative entry in the series**

`Unify` wrapped `List Vars.Variable -> IO (Result UnifyErr (UnifyOk a))`, so every structural node
of every unification paid one `IO.andThen` continuation closure plus an `Ok`, a `UnifyOk` and a
tuple, all built to be destructured immediately. Step 5a removed exactly that scaffolding from the
ENTRY and won; 5b removes it from the RECURSION: the payload takes `IO.State` explicitly so the
combinators call the next step directly, and `Result UnifyErr (UnifyOk a)` collapses into a single
`UResult = UOk vars a | UErr vars`. Unification runs upwards of 10^6 times per self-compile.

**It worked, exactly as designed, and the compiler got slower.**

| | pair 1 | pair 2 | pair 3 |
|---|---|---|---|
| triple A (diff) | +8.03 | -2.62 | +4.86 |
| triple B (diff) | +9.37 | +5.94 | +1.33 |

Six pairs, five positive; pooled median **+5.40 s (+2.1 %)**. A second triple was run precisely
because the first disagreed in sign and the counter it moved was the largest in the series.

| stat | ref `eco-opt24ii` | cand `eco-opt5b` | delta |
|---|---|---|---|
| minor GC cycles | 1240 | **1214** | **-26** |
| promoted MiB | 19,992 | 20,009 | +17 |
| max RSS kB | 11,437,240 | 11,486,464 | +49 MB |
| **GC/Alloc time (s)** | **121.72** | **127.03** | **+5.31** |

**The allocation reduction is real and the slowdown is its consequence.** Minor GC count fell by
26 cycles -- by far the largest counter move of the whole series -- while GC TIME rose by 5.31 s,
which is the whole of the 5.40 s wall regression. Promotion rose with it.

The mechanism follows from what a generational nursery actually charges for. **Minor GC count is a
proxy for allocation VOLUME; minor GC cost is paid for SURVIVORS.** A short-lived object that dies
before the next collection is free — it is never traced, never copied, and its space is reclaimed
by moving a pointer. What 5b deleted was precisely that kind of object: continuation closures and
`Ok`/`UnifyOk` wrappers that die within the same unification. Deleting them makes the nursery fill
more slowly, so collections happen less often — but each collection now spans MORE elapsed work,
so a larger fraction of the live set is still alive when it runs. `evacuate` is 10.8 % of this
compiler's samples; more survivors per cycle at a lower cycle count came out net negative, and the
extra 17 MiB of promotion is the same effect spilling into the old generation.

**This corrects the series' central heuristic and is the single most useful thing it learned.**
Fourteen entries supported "time is allocation"; this one shows the rule is really **time is
SURVIVOR COPYING**, and allocation volume is only a proxy for it — a good proxy when the objects
removed were being copied (the union-find store in step 3, the overlay rebuilds in 22d, the
per-node PAPs in 24(vii)a all removed objects that lived long enough to be traced), and a
MISLEADING one when they were dying young anyway. **A step should from now on be judged on GC
TIME and promoted bytes, not on the minor-cycle count**, and `lss-loop-extract.sh` already prints
GC time in column 7.

The rewrite itself is correct: both arms emit byte-identical MLIR (13,328,697 B), the fixed point
holds, and Point mint order is preserved (which matters beyond the gate — `Vars.Pt` indices reach
`dedupeSources` and the lambda-set `seen` sets through `IO.pointKey`). It is kept in `try-5b`.


### 16 (D10, Let arm) — skip the load and join at ground arrow-free let bindings — **no win, reverted**

A GROUND, arrow-free let binding has exactly one instance, so every occurrence of the name is
arrow-free and `joinLetUse`'s guard fires on every read: the `letEnv` entry is provably never
consumed. The candidate therefore skipped `Store.loadType defType` (which mints Points for the
whole structure) and `sigFlowJoinInto` (ground x anything recurses to leaves over slot-free
structure and can only bump a census counter), and REMOVED the name from `letEnv` rather than
leaving it, so a shadowed outer arrow-typed binding cannot be found by an inner occurrence. The
predicate is `Store.groundNoArrow`, which step 4/6 already added and exported -- GROUND and not
merely arrow-free, because a GENERALISED let (`let xs = [] in …` : `List a`) can be USED at
`List (Int -> Int)`, and skipping its entry would delete a real top write (more precise, still
sound by LSS_005, but not byte-identical).

| pair | ref `eco-opt24ii` | cand `eco-opt16d10` | diff |
|---|---|---|---|
| 1 | 273.34 | 273.13 | -0.21 |
| 2 | 269.82 | 272.88 | +3.06 |
| 3 | 271.04 | 271.38 | +0.34 |

Median paired difference **+0.34 s** -- flat. Minor GC 1241 vs 1242 (-1); promoted 20,079 vs
20,067 MiB (+12, worse); RSS +27 MB (worse); GC time 129.97 vs 128.54 s (+1.43, worse). Nothing
improved except a single minor cycle, so no win under the rule. Byte-identical (13,340,632 B both
arms) and the fixed point holds, so the BI argument was right; there is simply nothing there.

**Most likely already harvested by step 4a.** D10's whole value is the skipped LOAD, and the load
it skips is of a GROUND type — which is exactly the population step 4a's per-item ground-alias
load memo already turns into a memo hit. This is the third entry in the series (after 8a and 18a)
whose premise was true when the specification was written and was deleted by a step that landed
in between. Read a spec against the tree as it IS, not as it was.

The literal half of D10 (`walkLiteral`'s arrow-free short-circuit) was not built and remains
unmeasured; on this evidence it is unlikely to differ, since it skips the same kind of load.


### 24(v) — ctor-row bitmap built once — **no win, reverted**

Both ctor-row sweeps asked "is this row's key a ctor or box global?" per row per pass — FOUR
`HashMap.get TOpt.globalHash (==) (TOpt.Global home name) toptNodes` probes over ~43K rows, each
allocating a `TOpt.Global` and hashing its module name and its name (an Elm closure call per
character, entry 27's cost). The candidate computes the answer once into a `BitSet` over the row
index — legal because the sweeps write registry TYPES only, never keys — and both sweeps test
`BitSet.member idx ctorRows`.

| pair | ref `eco-opt24ii` | cand `eco-opt24v` | diff |
|---|---|---|---|
| 1 | 267.66 | 272.09 | +4.43 |
| 2 | 274.09 | 268.62 | -5.47 |
| 3 | 271.88 | 274.89 | +3.01 |

Median paired difference **+3.01 s**. Minor GC IDENTICAL (1242); promoted +5 MiB, RSS +5 MB,
GC time +0.13 s — all within nothing. Byte-identical (13,340,956 B both arms), fixed point holds.

**About 129,000 string hashes and `TOpt.Global` allocations were removed and no counter noticed.**
That is the scale lesson this entry contributes: the settle sweeps run ONCE at the end of
monomorphization over 43K rows, so even four passes of a genuinely wasteful probe is a rounding
error beside the per-ITEM work the solver does millions of times. The same probe removed from a
per-item path would be worth measuring; removed from a per-registry-pass path it is not.

The remaining half of the specification's (v) — caching the `gkeyOf` /`moduleOf` strings in the
index so `Mono.toComparableGlobal` is built once per ctor row rather than once per row per pass —
was not built, and on this evidence would not register either.


### 25 — AbiCloning: census-gate `hostGlobal`, one-pass spec scans — **WIN, kept**

The last plan step with no measurement of any kind. Three changes in
`Compiler/GlobalOpt/AbiCloning.elm`, all post-mono, none of which changes a decision:

1. **`hostGlobal` only under census.** The stamp fold set
   `hostGlobal = hostGlobalAt record.registry.reverseMapping specId` for EVERY one of the ~43K
   specs — a five-part `Mono.toComparableGlobal` string each time — and every reader of
   `ctx.hostGlobal` sits behind an `if not ctx.census` early return (1852, 1899, 1999, 2106,
   2126). Off census the string was built and never read.
2. **`papResolve`: one pass.** It built a `( specId, specFunctionRow specId ctx )` pair for every
   spec of the callee global — 1,939 of them for `List.foldl` — then walked that list twice, once
   to filter matches and once to ask whether any row was `Nothing`. Now one `List.foldr` produces
   both, in the same order.
3. **`matchSpec`: one pass.** `List.filter eqLayout` followed by `List.filter (==)` over its
   result became a single `List.foldr` building both lists; `==` implies `eqLayout`, so the exact
   list is a sub-fold of the layout list.

| pair | ref `eco-opt24ii` | cand `eco-opt25` | diff |
|---|---|---|---|
| 1 | 271.10 | 265.09 | **-6.01** |
| 2 | 268.51 | 266.27 | **-2.24** |
| 3 | 269.38 | 265.28 | **-4.10** |

Median paired difference **-4.10 s (-1.5 %)**, same sign in all three pairs. GC time
**124.11 vs 127.01 s (-2.90)**. Minor GC identical (1241), promoted +3 MiB, RSS flat.

**The plan estimated "wall down by well under 1 %" and it measured 1.5 %** — the estimate was
made on the grounds that AbiCloning lives inside a ~28 s slice of the run, which is true and
still leaves this as one of the larger wins in the second half of the series. The reason is
visible in the GC-time column: what these three changes remove is not CPU but RETAINED
intermediate lists and strings at a point where the graph is large, and by the finding at step 5b
that is the allocation that actually costs.

**Gates, all green.** Unit 13,565 + the same 12 pre-existing failures; E2E **1731 / 1731**;
633-workload rail MLIR manifest identical AND census byte-identical — which matters more here
than usual, because the rail diffs everything from `=== LSS census ===` onward and that includes
`abiCensusLines` and the `lss globalopt:` line, so `memberReps` ORDER is load-bearing for this
gate even though it is print-only. Fixed point OK; both arms emit identical MLIR (13,337,011 B).

The remaining pieces of the specification — `siteFingerprint`'s `String.join` of depth-4
`shallowLayoutKey` strings and its `Dict String` probe, and `resolvePapSuffix`'s
`List.concat (Dict.values memberInfo.buckets)` — were NOT built and remain unmeasured.


### 26a — nest the six scheduling fields of `S` into a `sched` group — **LOSS, reverted**

**Step 26 specifies its own decision gate, and the gate was measured first.** Lower the kept
compiler with `ECO_INLINE_ALLOC=0` so every record allocation goes through
`eco_alloc_record(field_count, …)`, then count allocations by width with a uprobe:

    sudo -n bpftrace -e 'uprobe:<BIN>:eco_alloc_record { @w[arg0] = count(); } END { print(@w); }'

`S` is the only 31-field record in the solver, and the self-compile allocated
**@w[31] = 11,939,218** of them (next widest populations: @w[4] = 103.4 M, @w[11] = 8.6 M,
@w[2] = 4.2 M, @w[28] = 3.0 M). 31 slots x 8 B x 11.9 M is about 2.96 GB of record payload, and
the plan's build threshold is >= ~10 M copies. **The gate said build**, so it was built.

`sched = { worklist, inProgress, scheduled, dirtySpecs, dirtyList, ports }` — six fields written
only when a spec is scheduled, marked dirty, or a port is registered (thousands of times), read
through one extra indirection. `S` goes 31 -> 26 slots, i.e. 40 B and five GC-scanned slots off
every one of the 11.9 M copies: **about 476 MB less allocation.**

| pair | ref `eco-opt25` | cand `eco-opt26a` | diff |
|---|---|---|---|
| 1 | 273.07 | 269.36 | -3.71 |
| 2 | 267.55 | 271.61 | +4.06 |
| 3 | 269.21 | 272.90 | +3.69 |

Median paired difference **+3.69 s**. Every deterministic counter moved the right way and by
almost nothing: minor GC 1248 vs 1250 (-2), promoted 19,951 vs 19,965 MiB (-14), RSS -14 MB, and
**GC time 127.91 vs 128.53 s — just 0.62 s**. Wall up ⇒ LOSS. Byte-identical (13,329,454 B both
arms), fixed point holds.

**476 MB of nursery traffic bought 0.62 s.** That is about 1.3 microseconds per megabyte, which
is to say: essentially free. It is step 5b's finding measured from the other direction and it
prices the effect exactly — **allocation that dies young is nearly costless in this runtime**, and
`S` copies die immediately (each is consumed by the next step of the same fold). The extra
indirection on every `s.sched.*` read, plus a 6-slot group record at each write, cost more than
0.62 s.

**This closes step 26, including its unbuilt parts.** The specification's remaining groups
(`runMemo` 26b, `letCtx` 26c, `drv` 26d) are the same transformation on the same 11.9 M copies,
differing only in how many slots they remove; the measured price of a removed slot is now known
(~0.12 s per slot across the whole run, against an indirection cost paid on every read), and no
grouping of the remaining fields reaches a win. The formula in the plan's §1 —
`ΔBytes = 8 · Σ N_w · (31 − T) − 8 · Σ N_g · |g|` — was right about the bytes and wrong about what
a byte is worth.


## 7. Provenance

- Step list and order: `plans/lss-compile-time-optimizations.md` §2 (implementation order,
  2026-09-19); measurement anatomy behind the order: same file §1 and the memory note
  `lss-compile-time-profile-sep18`.
- Method adapted from `benchmarks/lss-payoff.md` (workload, cache reset, no-census rule, entry
  shape) with three changes: the tested binary is the CANDIDATE built by the previous kept
  compiler and then measured building ITSELF; three cold runs per row instead of one, judged on
  medians; the five-stat order and win rule of §4.
- Self-compile command: bootstrap Stage 7a, `compiler/CMakeLists.txt:494`; lowering command:
  Stage 6, `compiler/CMakeLists.txt:457-468`.
- Noise band for THIS series, measured by the base triple (2026-09-19, §6): wall spread 5.21 s
  = 1.31 % of median; RSS spread 0.03 %; minor/major GC and promoted MiB exactly deterministic.
  The older indicative bands (wall ±2 % run-to-run; RSS bimodal with a ~2.15 GB gap, 2026-08-28
  series and the retracted `injTotal` claim) still bound what a BAD triple can look like — a
  triple whose wall spread exceeds ~2 % means the machine was disturbed, so re-run it.
- Stat extraction: `benchmarks/lss-loop-extract.sh <prefix>` prints the five judged stats (plus GC
  time and `out.mlir` bytes) as one TSV line from `<prefix>.time` + `<prefix>.stdout`; validated
  2026-09-19 against the Sep-18 profile run's artefacts (reproduced all five figures exactly).
- Fixed-point discipline for analysis-changing steps: one extra bootstrap turn, gate B==C
  (`premono-inliner-shipped-default-on`, 2026-09-11).
- Snapshot tool: `benchmarks/lss-loop-snap.sh` (snap / restore / verify / diff / list), self-tested
  2026-09-19: an added file is deleted and a modified file restored byte-identically by `restore`;
  `verify` exits non-zero on any drift. No git in this container (`build-traps` memory, Trap 3).

## 8. Summary

One row per step, numbers only, in the order the entries were run.

**`wall (s)` is the candidate's OWN median** — of the plain triple for steps 1-11a, and of the
candidate arm of the interleaved A/B from step 12 onward. It is an absolute number and is
directly comparable down the column, but it carries machine drift: two sittings hours apart
differ by about +/-5 s, which is larger than most single steps here.

**`paired D (s)` is the judging statistic** for every A/B-measured entry: the MEDIAN of the three
paired differences (candidate minus reference, measured minutes apart in one sitting). Drift
cancels in it, and it resolves to roughly 2-3 s (0.4 s on a quiet machine — see "The instrument,
calibrated" below). Where the two columns disagree, the paired difference is the one the verdict
follows. `—` means the entry predates the interleaved form.

The GC counters need neither correction: they are exact per (binary x tree).

| step | wall (s) | paired D (s) | minor GC | major GC | promoted MiB | max RSS (kB) | verdict | ref |
|---|---|---|---|---|---|---|---|---|
| base | 398.71 | — | 1825 | 10 | 20846 | 12708052 | reference | — |
| 1 | 370.18 | — | 1825 | 10 | 20846 | 12705760 | WIN | base |
| 2 | 359.47 | — | 1821 | 10 | 20836 | 12690812 | WIN | 1 |
| 3 | 340.70 | — | 1583 | 10 | 20376 | 12457544 | WIN | 2 |
| 4b | 334.85 | — | 1600 | 10 | 20863 | 12711764 | WIN | 3 |
| 4a | 291.93 | — | 1312 | 10 | 20354 | 12026400 | WIN | 4b |
| 5a | 289.43 | — | 1287 | 10 | 20341 | 12048496 | WIN | 4a |
| 6 | 286.85 | — | 1281 | 10 | 20201 | 12052184 | WIN | 5a |
| 7 | 289.08 | — | 1280 | 10 | 20183 | 12044660 | WIN | 6 |
| 8a | 288.94 | — | 1291 | 10 | 20233 | 12118144 | LOSS (reverted) | 7 |
| 8b | 287.24 | — | 1273 | 10 | 20207 | 12105460 | WIN | 7 |
| 9 | 289.18 | — | 1252 | 10 | 20269 | 12095116 | WIN | 8b |
| 10 | — | — | — | — | — | — | DEFERRED (not attempted) | — |
| 11b | 278.11 | — | 1243 | 10 | 20284 | 12058368 | WIN | 9 |
| 11a | 277.42 | — | 1238 | 10 | 20301 | 12073940 | WIN | 11b |
| 14 | ~279.4 | — | 1238 | 10 | 20301 | 12073960 | LOSS (reverted) | 11a |
| 19' | 281.54 | — | 1239 | 10 | 20316 | 12134468 | LOSS (reverted) | 11a |
| 22a | 278.01 | — | 1237 | 10 | 20293 | 12075144 | WIN | 11a |
| 16a | 276.01 | — | 1252 | 10 | 20317 | 12083308 | LOSS (reverted) | 22a |
| 24(i) | 282.38 | — | 1250 | 10 | 20239 | 12028904 | LOSS (reverted) | 22a |
| 12s | 275.58 | — | 1256 | 10 | 20292 | 12046092 | LOSS (reverted) | 22a |
| 27 | 311.63 | — | 1310 | 11 | 20825 | 12048200 | LOSS (reverted) | 22a |
| 20 | ~279.0 | — | 1237 | 10 | 20293 | 12107848 | NO WIN (reverted) | 22a |
| 13s | ~285.3 | — | 1262 | 11 | 20325 | 11988428 | LOSS (reverted) | 22a |
| 23 | 280.87 | — | 1237 | 10 | 20255 | 12109264 | NO WIN (reverted) | 22a |
| 17 | 279.02 | — | 1262 | 10 | 20284 | 12090480 | LOSS (reverted) | 22a |
| 16-D4 | ~281.6 | — | 1238 | 10 | 20387 | 12120732 | NO WIN (reverted) | 22a |
| 15 | 280.81 | +4.83 | 1238 | 10 | 20318 | 12022700 | LOSS (reverted) | 22a |
| **18b** | **275.76** | **-2.16** | 1237 | 10 | 20293 | **12126548** | **WIN (kept)** | **18b** |
| 18a | 281.54 | +2.17 | 1259 | 10 | 20293 | 12130068 | LOSS (reverted) | 18b |
| **22b** | **278.43** | flat (-2.38 median, mixed sign) | **1237** | 10 | **20335** | **11916868** | **WIN on counters (kept)** | **22b** |
| **22d** | **270.19** | **-9.08** | **1250** | 10 | **20004** | 10686984 | **WIN (kept)** | **22d** |
| 22c | 274.37 | +3.42 | 1250 | 10 | 20000 | 11594052 | LOSS (reverted) | 22d |
| 24(iii)+(iv) | 276.42 | +7.47 | 1248 | 10 | 19929 | 11513336 | LOSS (reverted) | 22d |
| **24(i')** | **270.59** | **-4.06** | **1246** | 10 | 19962 | 11541556 | **WIN (kept)** | **24i2** |
| 21a | 275.46 | +2.86 | 1247 | 10 | 19966 | 11583856 | LOSS (reverted) | 24i2 |
| **24(vii)a** | **264.73** | **-6.87** | **1243** | 10 | 19972 | 11562648 | **WIN (kept)** | **24v7** |
| 24(vii)b | 271.70 | +2.25 | 1243 | 10 | 19961 | 11563724 | NO WIN (reverted) | 24v7 |
| **24(ii)** | **264.89** | **-3.04** | **1241** | 10 | **19977** | **11529796** | **WIN (kept)** | **24ii** |
| 5b | 266.64 | +5.40 (6 pairs) | **1214** | 10 | 20009 | 11486464 | LOSS (reverted) | 24ii |
| 16(D10) | 272.88 | +0.34 | 1241 | 10 | 20079 | 11528320 | NO WIN (reverted) | 24ii |
| 24(v) | 272.09 | +3.01 | 1242 | 10 | 20061 | 11770580 | NO WIN (reverted) | 24ii |
| **25** | **265.28** | **-4.10** | 1241 | 10 | 19982 | 11479276 | **WIN (kept)** | **25** |
| 26a | 271.61 | +3.69 | 1248 | 10 | 19951 | 11529312 | LOSS (reverted) | 25 |

**SERIES COMPLETE: 398.71 s to 265.28 s, -33.5 %.** Minor GC 1825 to 1241 (-32 %), promoted
20,846 to 19,982 MiB, peak RSS 12.71 to 11.48 GB (-9.7 %), GC time 142.10 to 124.11 s.
**Forty-three entries run.**

- **Kept (20):** 1, 2, 3, 4b, 4a, 5a, 6, 7, 8b, 9, 11b, 11a, 22a, 18b, 22b, 22d, 24(i'),
  24(vii)a, 24(ii), 25.
- **Reverted after their own measurement (22):** 5b, 8a, 12s, 13s, 14, 15, 16a, 16-D4, 16-D10,
  17, 18a, 19', 20, 21a, 22c, 23, 24(i), 24(iii)+(iv), 24(v), 24(vii)b, 26a, 27.
- **Deferred (1):** 10 — see its entry. It is the ONE step of the twenty-six with no measurement
  of its own, and the entry says exactly why: it is a seven-stage programme whose first stage
  cannot be built half-way and is predicted flat-to-negative alone.

**Every other step of the plan now has at least one measurement of its own**, including the two
that previously had none: step 25 (measured, kept) and step 26 (its own census gate measured at
11.9 M `S` copies, over the plan's build threshold, so it was built — and it lost).

**Drift check on the series** (protocol §1, Phase 0's "repeated only after the last step"): the
last kept compiler `eco-opt25` was re-measured in the 26a sitting at 273.07 / 267.55 / 269.21,
median **269.21 s** against its own recorded **265.28 s** — a 3.93 s disagreement, inside the
+/-5 s drift band this machine was calibrated at. The series deltas stand.

### What the series actually found

**Time is SURVIVOR COPYING, not allocation volume.** For the first thirty entries the working
rule was "time is allocation", and it fitted: every large win removed objects — the off-heap
union-find store (3), the ground-alias load memo (4a), the `widenSets` memo (11b), the
per-promotion GC timer (1), the pointer-preserving overlay (22d), the de-PAP'd predicate
(24(vii)a), the deleted redundant pass (24(ii)). Not one win came from making an operation
cheaper while allocating the same amount.

Then two entries priced the rule and corrected it:

- **5b** deleted ~10^6-scale short-lived closures from the `Unify` combinators, drove the minor
  GC cycle count down by **26** — the largest counter move in the series — and was **2.1 %
  SLOWER**, because GC TIME rose 5.31 s. Fewer collections each spanned more elapsed work, so a
  larger fraction of the live set was still alive when they ran.
- **26a** took 40 B off each of 11.9 M `S` record copies — **476 MB less allocation, measured** —
  and bought **0.62 s of GC time**. About 1.3 microseconds per megabyte.

So: an object that dies before the next minor collection is very nearly free — it is never
traced, never copied, and its space is reclaimed by moving a pointer. The wins above did not work
because they allocated less; they worked because what they stopped allocating was being COPIED —
retained trees (22d, 24(i')), retained store structure (3, 4a, 11b), per-node PAPs on a walk
whose results outlive the walk (24(vii)a), whole extra passes over the registry (24(ii)). Judge a
candidate on **GC time and promoted bytes**, not on the minor-cycle count.

The mirror-image lessons, each paid for with a measured run:

- **A guard on a hot path is hot-path work** (16a, 15, 22c, 24(i)): four steps added a test to
  skip work and measured slower, because the test ran on every item while the skip paid off on
  few. Size the test, not just the work it avoids.
- **A "cheaper" container is only cheaper if the operation it replaced was the expensive one**
  (27, 21a, 24(iii)): hashing a string in Elm is a closure call per character and loses to the
  C++ ordered compare it replaces; `BitSet.member` does not beat a red-black descent on Int keys.
- **The same transformation wins in one place and loses in another** (22d vs 22c, 24(vii)a vs
  24(vii)b) — what decides it is whether the population it optimises is the common one. This is
  the reason every step had to be measured rather than inferred from a sibling.
- **A specification can be invalidated by its own prerequisites landing** (8a, 18a, 16-D10): each
  had a premise that was true when written and deleted by a step that landed in between.
- **Scale beats waste** (24(v)): 129,000 redundant string hashes removed from a pass that runs
  once over the registry did not register at all. The same probe removed from a per-item path
  would have.

### The instrument, calibrated

Wall on this machine resolves to roughly +/-5 s (1.8 %) BETWEEN sittings, measured twice before
the interleaved form existed: step 9's first triple disagreed with its re-run by 4.5 s on the
median, and step 11a's by 1.8 s with an 8.94 s internal spread. Every remaining step in the plan
was estimated at 1-3 % of the run, i.e. at or below that.

`benchmarks/lss-loop-ab.sh` was written in response and has been the measurement form since step
12. It runs reference and candidate ALTERNATELY in one sitting — A B A B A B — and reports the
paired differences, so drift cancels instead of averaging. Its calibration is in the subsection
below: on step 16a it resolved a 0.42 s paired spread against the ~5 s unpaired drift, and it
CORRECTED THE SIGN of that verdict. It costs twice the machine time per step, and for steps worth
1-3 % it is the only form that produces a verdict worth having.

**The paired form is still not unlimited.** Several later entries show paired differences that
disagree in sign across the three pairs (22b, 24(i'), 24(ii), 21a, 5b): the median is reliable at
about the 2-3 s level, not at 0.4 s, and the 0.42 s figure was a best case on a quiet machine.
Where the paired median is small, the verdict rests on the GC counters, which is fine — they are
exact per (binary x tree).

**Only allocation-reducing steps are judgeable at the margin.** A step that removes CPU without
removing objects (14 is the clean example, 20 another) cannot move any counter, so wall is its
only signal and wall cannot see it. Both were reverted not because they were shown harmful but
because they could not be shown to help. That is the correct call under the rule and also an
honest admission of where the instrument stops.

Two further findings worth carrying forward, both of which cost a measured run to learn:

- **A guard on the hot path is hot-path work.** Step 16a skipped an isolated instantiation behind
  a predicate evaluated at every global call; the predicate cost more than the skip saved and
  allocation went UP. Size the test, not just the work it avoids. Steps 15, 22c and 24(iii)
  repeated the lesson in three other shapes.
- **A specification written before its prerequisites land can be invalidated by them.** Step 8a's
  premise — that a read's write-back is expensive — was true of the persistent array and false
  once step 3 made the store mutable. Re-read a spec against the tree as it IS.

### What is still unmeasured, precisely

Forty-three entries in, **every step of the plan except one has been measured on its own.** This
section says exactly what has not been, so nothing reads as untested opinion.

**Step 10 — retire the `Step` encoding — is the single unmeasured step.** Its entry above says
why: it is a seven-stage programme (`10a`-`10g`), the stages are not separable (admitting
`MonoIf` on the `$sret` result spine without the rest leaves a worker whose branches yield
scalars into a region declaring an aggregate), its own specification predicts `10a` alone as flat
to slightly negative, and the payoff only arrives at `10f` after ~263 signatures, ~500 combinator
uses and ~450 `Ok`/`Err` arms across four files have moved. It is a project, not a loop
iteration.

Two later entries bear on it and are worth reading before anyone starts, though NEITHER is a
measurement of step 10 and neither should be treated as one:
- **5b** performed the same shape of change — removing the `Ok`/wrapper boxing from a state monad
  in this codebase — on `Unify`'s combinator layer. It removed the objects as designed and was
  2.1 % slower, because the boxes died young.
- **26a** priced short-lived allocation directly: 476 MB removed bought 0.62 s.

Step 10's `Ok ( a, S )` boxes are the same kind of short-lived object. That is a reason to
re-price the step before building it, not a verdict on it.

**Sub-parts specified but never built.** Each is named in its step's entry with what is known:

| unbuilt | where it is discussed | what is known |
|---|---|---|
| 4c (zonk-side ground memo) | step 4 spec §4.11 | adds a probe to every zonked node; 16-D10 suggests 4a already harvested this population |
| 11c (non-BI widen variant) | step 11 entries | 11a and 11b both kept; 11c was the optional non-BI fallback |
| 16 D2 (callee child re-walk), D12 (`joinLetUse` test order), D10's literal half | step 16 spec | D1/D8 (16a), D4 and D10's Let arm all measured; all three lost or were flat |
| 21b / 21c (`specWidenedKeys`, `rootLamOf`, `lambdaQualified` as `Array`; `flexCtorSpecs` as `BitSet`) | entry 21a | 21a measured the hottest of step 21's targets and lost; an `Array.get` at a dense index is a different operation and is NOT decided by it |
| 22d's `cons`-parameterised (hash-consing) variant | entry 22d | deliberately omitted; the pure form already gave -9.08 s with a byte-identical census |
| 24(vi) (fuse the lambda-home and edge/effect node walks) | step 24 spec | never built; 24(v) showed once-per-graph work does not register, and this is once-per-graph work |
| 24(vii) part 2 (`seen` map in `collectAllCustomTypes`) | entry 24(vii)a | a hash probe replacing a cheaper operation is the shape that lost at 21a and 24(iii) |
| 25's `siteFingerprint` and `resolvePapSuffix` | entry 25 | the other three pieces of step 25 were built and won -4.10 s |
| 26b / 26c / 26d (`runMemo`, `letCtx`, `drv` groups) | entry 26a | 26a priced a removed `S` slot at ~0.12 s across the whole run against an indirection on every read; no remaining grouping reaches a win |
| 12 and 13 in full (dense `GlobalId`, integer member identity end to end) | entries 12s, 13s | both surgical forms measured and lost; the full forms are large and remain the strongest unbuilt idea in the plan |

### Where the time is now, and what to do next

`perf record -F 299`, 83K samples, `eco-opt24i2` self-compiling (the profile was taken mid-series;
the three steps kept after it change the ranking little):

| cluster | share |
|---|---|
| GC (`evacuate` 10.8, `evacuateListSpine` 3.2, `markOneObject` 2.8, `scanObject` 2.7, `blockIndexFor` 1.6, `pushMarkRoot` 1.1, `lazySweep` 1.1, and the rest) | **~30 %** |
| libc (memcpy/memmove, overwhelmingly inside `evacuate`) | **~11 %** |
| `Elm::Allocator::resolve` | 6.1 % |
| string comparison (`StringOps::compare` 3.2, `eco_string_cmp3` 2.6, `forEachSegmentEx` 1.8) | 7.6 % |
| `Dict` operations (`balance` 2.9, `insertHelp` 2.7, `get` 1.3) | 6.9 % |
| generic dispatch (`eco_apply_closure_eval` 2.3, `invokeSaturatedTyped` 1.5, `spliceArgsForSaturatedCall` 0.5) | 4.3 % |
| `Utils::eqHelp` | 0.5 % |

**GC plus the memcpy it drives is over 40 % of the run, and no step in this plan points at it.**
Plan §4 N22 ruled GC tuning out of scope when GC was a smaller share of a slower compile; that
decision is stale. The two clusters this plan WAS written to attack are gone: hash-cons equality
fell from ~20 % to 0.5 % (step 2), and the union-find store cluster (~12 %) is out of the top
thirty entirely (step 3).

**Recommended order for the next session:**

1. **Attack survivor copying.** `evacuate` + its memcpy is the single largest block. The lever is
   not "allocate less" — 5b and 26a proved that at 10^6 and 11.9 M objects respectively — it is
   "promote less and copy less": nursery sizing against the actual survivor curve, and finding
   the structures that survive a minor collection and should not.
2. **Attack emission-side string interning.** About two thirds of the 7.6 % string cost is the
   `.ecot` string table and the MLIR attribute tables, entirely outside this plan. Entry 27 shows
   the fix is NOT an Elm-level hash; it is a kernel-side hash primitive, or interning at
   construction so the encoder carries an index rather than a string.
3. **Then step 13**, rebuilt as integer identity end to end with keys never constructed — with
   step 12 first, and re-priced against entry 13s.
4. Use `benchmarks/lss-loop-ab.sh` for anything under 3 %, quote GC time in every entry, and
   re-profile after any two kept steps. This series showed three times (8a, 18a, 16-D10) that a
   specification goes stale the moment its prerequisites land.

### Interleaved A/B: calibration, and a verdict it corrected

`benchmarks/lss-loop-ab.sh` was written after the run above and validated on step 16a, whose plain
triple was the most ambiguous row in the series — wall 2.00 s FASTER than the reference, which
under rule 1 would have made it a win, against three counters that all moved the wrong way.

| pair | ref (22a) | cand (16a) | diff |
| 1 | 275.65 | 276.94 | **+1.29** |
| 2 | 273.64 | 273.91 | **+0.27** |
| 3 | 278.70 | 281.85 | **+3.15** |
| median paired difference |  |  | **+1.29** |

16a is SLOWER, in every pair. The plain triple had said 2.00 s faster; the true figure is about
1.3 s slower, so the revert was right and the unpaired comparison had the SIGN wrong.

The three reference runs in that table are the calibration: 275.65, 273.64, 278.70 — the same
binary on the same tree, spread 5.06 s across half an hour. That is the drift, measured directly,
and it is why comparing two medians taken hours apart cannot resolve a 1-3 % step. The paired
differences spread 2.88 s, so magnitudes remain soft, but all three agree in sign — and the sign
is what a verdict needs.
