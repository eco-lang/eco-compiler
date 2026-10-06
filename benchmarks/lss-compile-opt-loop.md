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

**Summary table** (§9, bottom of the file): one row per step, numbers only — the MEDIANS of the
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

(One entry per step, newest last. Each is: the results table, then at most ten lines —
what changed, the verdict, and the reason if it is not obvious. §3 defines the shape.)

### base — series baseline (2026-09-19)

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 398.71 | 1825 | 10 | 20846 | 12,711,036 | 13,304,208 | same |
| r2 | 402.40 | 1825 | 10 | 20846 | 12,707,776 | 13,304,208 | same |
| r3 | 397.19 | 1825 | 10 | 20846 | 12,708,052 | 13,304,208 | same |
| **median** | **398.71** | **1825** | **10** | **20846** | **12,708,052** | 13,304,208 | same |

`bin/eco-opt-prev` = the tree's fixed-point `bin/eco-compiler` (sha256 `7fc3b7e0…`) building the
unchanged tree. Wall spread 5.21 s = 1.31 %. The three GC counters are IDENTICAL across all three
runs — deterministic per (binary x tree), which is why they are judged before wall. All three
outputs are byte-identical to each other and to `bin/eco-compiler.mlir`, so the tree is at its
fixed point. GC/Alloc time 142.10 s = 35.6 % of wall. Reference row until the first win.

### 1 — GC-stats timer overhead in the `build` preset (runtime) — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 366.60 | 1825 | 10 | 20846 | 12,714,744 | 13,304,208 | same |
| r2 | 374.46 | 1825 | 10 | 20846 | 12,705,584 | 13,304,208 | same |
| r3 | 370.18 | 1825 | 10 | 20846 | 12,705,760 | 13,304,208 | same |
| **median** | **370.18** | **1825** | **10** | **20846** | **12,705,760** | 13,304,208 | same |
| D vs base | **-28.53 (-7.16 %)** | 0 | 0 | 0 | -2,292 (-0.02 %) | 0 | — |

`OldGenSpace::allocate` no longer reads the clock when `g_in_minor_gc` is set — two vdso reads
per promoted object, ~1.5e9 per run, measuring a nesting rather than a cost. Four files, 202-line
patch; no compiler source changed, so the candidate is `bin/eco-compiler.mlir` re-lowered against
the rebuilt runtime. WIN on rule 1: wall -28.53 s against a 7.86 s spread, and the GC counters
came back bit-exact (1825/10/20846), which is both the proof that this is pure overhead removal
and what a disturbed machine does not do. `Total GC/Alloc time` rose 142.10 -> 146.53 s: an
accounting change, not a regression — minor-GC time now includes promotion allocation, which the
old code subtracted out. Walls before step 1 are not comparable with later ones for that reason.
Rejected and not to be re-proposed: `rdtsc`, sampling every 2^n-th promotion, keeping the field at
zero. Gates: `check` green 1727/1727 (C++-only). Kept as `keep-1`.

### 2 — hash-cons equality O(arity) instead of a deep structural walk — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 363.97 | 1821 | 10 | 20836 | 12,709,180 | 13,306,221 | same |
| r2 | 359.47 | 1821 | 10 | 20836 | 12,690,620 | 13,306,221 | same |
| r3 | 356.96 | 1821 | 10 | 20836 | 12,690,812 | 13,306,221 | same |
| **median** | **359.47** | **1821** | **10** | **20836** | **12,690,812** | 13,306,221 | same |
| D vs 1 | **-10.71 (-2.89 %)** | **-4** | 0 | **-10** | **-14,948 (-0.12 %)** | +2,013 | — |

The intern key becomes `Canon` — the canonical node plus, for records, fields in ascending name
order — and `eqExact` tests the packed hash, then shallow slots, then children, instead of Elm
`==`. That removes the kernel's `dictEq` from the 99 %-hit path: two vector allocations, an
in-order walk of both red-black trees and a string compare per field, for children already
canonical. Every stat improved on a workload that GREW 2,013 bytes, so real allocation went, not
moved. Byte identity three ways: fixed-point `cmp` over 13.3 MB emitted by two different compilers
from one source; the rail identical on manifest and the 65,508-line census; and a new oracle
checking `eqExact a b == (a == b)` over 8,100 pairs plus opposite-order fields and equal-length
colliding names. Gates: `full` 1727/1727; unit 13,531 + the 12 pre-existing POST_010 failures; new
pins `Data/HashMapTest` and two K6 tests. Kept as `keep-2`.

### 3a — `Eco.CellStore` kernel package, pure twin, native pins — **not measured**

No compiler source changed, so there is nothing to time. Adds the kernel module in three
languages: `eco-kernel-cpp/src/eco-kernel/CellStore.{hpp,cpp}` + `CellStoreExports.cpp` (a C++ vector of
encoded HPointer words plus an undo trail, registered with `RootSet::addExternalRootScanner`),
`src/Eco/Kernel/CellStore.js`, `src/Eco/CellStore.elm`, and `compiler/src-xhr/Eco/CellStore.elm` as
the PURE twin stock Elm compiles for stage 1 and the unit suite. Three costs the spec did not
predict: the kernel JS file's leading `/* … */` block is the IMPORT header, not a comment; a
locally-linked package is COPIED into `~/.eco` and not refreshed when the seed gains a module; and
`ECO_KERNEL_MODS` in `runtime/src/codegen/CMakeLists.txt` decides whether the archive reaches a
lowered program. Gates: `CellStoreTest` (16, the twin) and four native pins — round-trip, rollback
algebra, 40,000 cells surviving forced GC reachable only from the trail, two stores not aliasing.

### 3 — transient union-find store (`Eco.CellStore`) — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 342.48 | 1583 | 10 | 20376 | 12,457,544 | 13,314,359 | same |
| r2 | 338.77 | 1583 | 10 | 20376 | 12,457,292 | 13,314,359 | same |
| r3 | 340.70 | 1583 | 10 | 20376 | 12,457,636 | 13,314,359 | same |
| **median** | **340.70** | **1583** | **10** | **20376** | **12,457,544** | 13,314,359 | same |
| D vs 2 | **-18.77 (-5.22 %)** | **-238 (-13.1 %)** | 0 | **-460 (-2.2 %)** | **-233,268 (-1.84 %)** | +8,138 | — |

`IO.State.ioRefsPoint` is no longer a persistent 32-way trie: a write is one C call and a store, a
fresh Point one vector push. Cells and trail are GC roots through an external root scanner — the
only sound way to hold Elm values in mutable storage here, the collector having no write barrier
(HEAP_047, KERN_007). Linear threading already held except at three best-effort recovery sites,
which now bracket with `markStore`/`rollbackStore`. Every stat improved; the 238-cycle minor drop
is the trie nodes no longer being copied, and -233 MB RSS the same fact from the other end. Rail
census differs on `Hello` by +13 source lambdas and one member id — CellStore's own exports. The
pure twin earned its place by FAILING where the kernel passes (rolling back a pre-mark state is a
no-op on a mutable store). SECOND measurement: the first predated the kernel-license re-audit and
the triples agree. Gates: `full` 1731/1731 (+4 pins); unit 13,547; 1,271 kernel. Kept `keep-3`.

### 4b — per-run classify memo for ground alias instantiations — **WIN (wall), memory regression recorded**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 339.44 | 1600 | 10 | 20863 | 12,711,764 | 13,326,049 | same |
| r2 | 333.06 | 1600 | 10 | 20863 | 12,710,664 | 13,326,049 | same |
| r3 | 334.85 | 1600 | 10 | 20863 | 12,712,684 | 13,326,049 | same |
| **median** | **334.85** | **1600** | **10** | **20863** | **12,711,764** | 13,326,049 | same |
| D vs 3 | **-5.85 (-1.72 %)** | +17 | 0 | **+487 (+2.4 %)** | **+254,220 (+2.0 %)** | +11,690 | — |

An alias instantiation whose arguments and body are ground and arrow-free classifies to the same
canonical `MonoType` everywhere, so the first classify is cached under a structural key
`(home, name, args)`; identity cannot be the key, since `AssignMVarIds` rebuilds every node per
occurrence. WIN on rule 1, wall -5.85 s, with all three candidate runs below the reference MEDIAN
and two below its fastest — though the delta is inside this triple's 6.38 s spread. **Three of the
four other stats moved the wrong way, and that is not noise**: promoted +487 MiB, RSS +254 MB,
minor +17, giving back most of what step 3 won there. The memo buys time with retention, by more
than a key-and-bucket count explains; recorded as measured. Byte identity: fixed point plus the
rail identical on both artefacts. Gates: `full` 1731/1731; unit 13,561; 15 new pins in
`GroundAliasMemoTest`. Kept as `keep-4b`.

### 4a — per-item load memo for ground alias instantiations — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 291.93 | 1312 | 10 | 20354 | 12,026,400 | 13,332,898 | same |
| r2 | 288.67 | 1312 | 10 | 20354 | 12,025,132 | 13,332,898 | same |
| r3 | 295.34 | 1312 | 10 | 20354 | 12,034,740 | 13,332,898 | same |
| **median** | **291.93** | **1312** | **10** | **20354** | **12,026,400** | 13,332,898 | same |
| D vs 4b | **-42.92 (-12.8 %)** | **-288 (-18.0 %)** | 0 | **-509 (-2.4 %)** | **-685,364 (-5.4 %)** | +6,849 | — |

Second and later loads of one ground, arrow-free alias instantiation WITHIN an item reuse the first
load's child Points and mint only a fresh root — for `S`, the compiler's own 31-field state record,
one mint instead of one per field and nested subtree, against a profiled ~5.7 M mints per
self-compile. The root is deliberately NOT shared: that would make a bare reference's family var
and a call's isolated twin union-find equivalent, flipping the MONO_029 stale-read barrier and
livelocking the saturation loop. Every stat improved far outside the noise — wall -42.92 s against
a 6.67 s spread. This settles 4b's memory regression: against step 3, 4b+4a is wall 340.70 ->
291.93, minor 1583 -> 1312, promoted 20376 -> 20354 MiB, RSS 12.46 -> 12.03 GB. Gates: `full`
1731/1731; unit 13,566; five new load-side pins. Kept as `keep-4a`.

### 5a — direct-state entry for `Unify.unify` — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 289.43 | 1287 | 10 | 20341 | 12,048,496 | 13,332,279 | same |
| r2 | 291.57 | 1287 | 10 | 20341 | 12,048,844 | 13,332,279 | same |
| r3 | 287.51 | 1287 | 10 | 20341 | 12,047,792 | 13,332,279 | same |
| **median** | **289.43** | **1287** | **10** | **20341** | **12,048,496** | 13,332,279 | same |
| D vs 4a | **-2.50 (-0.86 %)** | **-25** | 0 | **-13** | +22,096 (+0.18 %) | -619 | — |

`Unify.unify`'s entry becomes a wrapper over a direct-state `unifyS`, `guardedUnify`'s body a
saturated top-level `guardedUnifyS`. Gone per unification: the `liftIO` thunk, the `andThen`
closure and its continuation, `succeed`'s closure, the `IO.pure`, and the `Ok`/`UnifyOk` pairs that
existed only to be destructured. The wall delta is inside this triple's 4.06 s spread, so what
makes it a win is that both deterministic counters moved — 25 fewer minor cycles, 13 MiB less
promoted; RSS +22 MB is inside that column's bimodal band. One adaptation forced by step 3: the
spec had `unifyBoolS` return the PRE-unify state on failure, which means nothing once there is one
in-place store — the real undo is the caller's mark/rollback bracket. Mint order matters beyond the
gate, since `unifyS` is shared with the real typechecker and `Vars.Pt` indices are exposed through
`pointKey`. Gates: `full` 1731/1731; unit 13,566. Kept as `keep-5a`.

### 6 — flag-residue and dead-arm cleanup — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 282.16 | 1281 | 10 | 20201 | 12,051,528 | 13,329,272 | same |
| r2 | 286.85 | 1281 | 10 | 20201 | 12,056,408 | 13,329,272 | same |
| r3 | 286.99 | 1281 | 10 | 20201 | 12,052,184 | 13,329,272 | same |
| **median** | **286.85** | **1281** | **10** | **20201** | **12,052,184** | 13,329,272 | same |
| D vs 5a | **-2.58 (-0.89 %)** | **-6** | 0 | **-140** | +3,688 (+0.03 %) | -3,007 | — |

The residue of the 2026-09-18 flag removal, deleted: the unreachable keyed arm in `enqueueSpec`,
`arrowIdOn`/`arrowMintOn` and their guards, the `needSlow` deferral chain, the
`groundStandalones`/`honestSources` accumulators, two dead `Translate` functions. `foldSetWrites`
becomes `S -> S`, which steps 8 and 10 require. Two deletions needed judgement. `needSlow` deferred
a defensive arm unreachable by the closure of the slot-content channels and measuring zero since
Run C; it now writes ⊤ directly — sound, since ⊤ absorbs. The second was caught by a test:
`honestSourcesOn` also answered False when the accumulator was ABSENT, i.e. lss-off, so hardcoding
True broke `LssDirectedFlowTest` case 5. The rail census differs on 633 lines, every one the same
`set-writes:` line differing ONLY by the deleted ` slow=0` field, empty after normalising. Gates:
`full` 1731/1731; unit 13,565; `ArrowIdentityTest`'s "flag OFF" case deleted. Kept as `keep-6`.

### 7 — census bookkeeping off the default path (7a) — **WIN on rule 2, marginal**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 287.08 | 1280 | 10 | 20183 | 12,044,320 | 13,329,112 | same |
| r2 | 293.11 | 1280 | 10 | 20183 | 12,064,424 | 13,329,112 | same |
| r3 | 289.08 | 1280 | 10 | 20183 | 12,044,660 | 13,329,112 | same |
| **median** | **289.08** | **1280** | **10** | **20183** | **12,044,660** | 13,329,112 | same |
| D vs 6 | +2.23 (+0.78 %) | **-1** | 0 | **-18** | **-7,524 (-0.06 %)** | -160 | — |

The zonk accumulator carried policy and counters together, so it existed whenever LSS was on. It is
now counters only, allocated only under the report flag, with `lssOn` and `maxSetSize` on the
context; every default-path bump is a `case` on a constant `Nothing`. **WIN under rule 2, and the
marginal case that rule exists for**: wall +2.23 s is inside a 6.03 s spread, so flat, and both
deterministic counters improved — by one minor cycle in 1,280 and 18 MiB in 20,183, so the
accumulator was never a significant allocation source. Kept for substrate value; steps 8 and 10
assume the reshaped context. One hazard caught by reading, not by a test: three sites used "is
there an accumulator" as a proxy for "is LSS enabled", and once it became report-scoped those came
apart — leaving them would return ⊤ for every set slot on the default path, a silent total
precision collapse no gate here would catch. Gates: `full` 1731/1731; unit 13,565. Kept `keep-7`.

### 8a — pure union-find reads (`peekS`/`rootQ`/`equivalentQ`) — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 294.07 | 1291 | 10 | 20233 | 12,118,176 | 13,328,536 | same |
| r2 | 287.90 | 1291 | 10 | 20233 | 12,106,792 | 13,328,536 | same |
| r3 | 288.94 | 1291 | 10 | 20233 | 12,118,144 | 13,328,536 | same |
| **median** | **288.94** | **1291** | **10** | **20233** | **12,118,144** | 13,328,536 | same |
| D vs 7 | -0.14 (-0.05 %) | **+11** | 0 | **+50** | **+73,484 (+0.61 %)** | -576 | — |

A read that only reads need not compress the path it walked, so ~40 read-only sites moved to pure
`peekS`/`rootQ`/`equivalentQ`, dropping the write-back. **Not kept.** Wall moved 0.14 s on a 6.17 s
spread — flat — and NO other stat improved; all three moved the wrong way, and the GC counters are
exact. **Why it lost is the useful part: step 3 had already removed the cost this targets.** Under
the old persistent array a write-back copied a path of trie nodes; under `Eco.CellStore` it is one
C call and a store. The saving is near zero while the cost is real and always was — compression is
WORK THAT PAYS FORWARD, and skipping it leaves chains long for every later read. A spec written
before its prerequisites land must be re-read against what the tree became. Surfaced, not acted on:
`IORef.writePointCellS` allocates a fresh `IO.State` AND `Store` wrapper per write, both holding
what they already held. Reverted with `restore keep-7`; the reference row is unchanged.

### 8b — drop the threaded state at compressing reads — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 289.23 | 1273 | 10 | 20207 | 12,105,580 | 13,328,331 | same |
| r2 | 287.24 | 1273 | 10 | 20207 | 12,105,460 | 13,328,331 | same |
| r3 | 285.01 | 1273 | 10 | 20207 | 12,103,712 | 13,328,331 | same |
| **median** | **287.24** | **1273** | **10** | **20207** | **12,105,460** | 13,328,331 | same |
| D vs 7 | **-1.84 (-0.64 %)** | **-7** | 0 | +24 | +60,800 (+0.50 %) | -781 | — |

| | wall | minor GC | what changed |
|---|---|---|---|
| 8a | -0.14 (flat) | **+11** | dropped the copies AND the compression |
| 8b | **-1.84** | **-7** | dropped the copies, KEPT the compression |

8a's replacement, designed from what 8a's failure showed. The read sites keep calling the
COMPRESSING `UF.get` and simply do not thread the state it returns — sound only because the store
is mutated in place, so the compression has already happened by the time the call returns and the
returned state differs from the passed one by nothing but the record wrapper around the same
handle. The context copy per read goes; the compression that pays forward stays. Eighteen exact
minor cycles separate this from 8a, which is compression paying for itself. WIN on rule 2: wall
-1.84 s is inside the 4.22 s spread, so the deterministic minor-cycle count carries the verdict.
Memory is mixed and recorded as measured — promoted +24 MiB, RSS +61 MB, both small and both
present in 8a too, so they track the context-copy removal, not the compression question. Gates:
`full` 1731/1731; unit 13,565. Kept as `keep-8b`.

### 9 — skip `connectTypes` / `enrichFromEnv` for ground, arrow-free types — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 289.18 | 1252 | 10 | 20269 | 12,095,116 | 13,330,827 | same |
| r2 | 288.10 | 1252 | 10 | 20269 | 12,093,628 | 13,330,827 | same |
| r3 | 289.60 | 1252 | 10 | 20269 | 12,095,088 | 13,330,827 | same |
| **median** | **289.18** | **1252** | **10** | **20269** | **12,095,116** | 13,330,827 | same |
| D vs 8b | +1.94 (+0.68 %) | **-21 (-1.6 %)** | 0 | +62 | **-10,344 (-0.09 %)** | +2,496 | — |

A ground, arrow-free type has no variable to concretise and no set slot to carry members into, so
connecting it to another ground type, or re-encoding a bound type into it, moves nothing. Both are
skipped, using step 4's verdict map so the predicate is a hash lookup for `S`, `Env` and `ItemAux`.
WIN on rule 2: wall +1.94 s is flat against the reference's 4.22 s band, minor cycles -21, the
largest drop in that column since 4a. **This row needed two triples, and the first is why the GC
counters are judged first**: runs 1 and 2 agreed on 1252/20269 while run 3 said 1273/20274 with
120 MB less RSS — deterministic counters do not do that. All three outputs were byte-identical, so
the allocator switched heap modes. The re-run was clean, and the two medians differ by ~4.5 s,
which sets the honest wall resolution here at about ±5 s between triples. Rail census differs on 42
lines, all `enrich|bare`/`enrich|access|ofLocal` counts. Gates: `full` 1731/1731; unit 13,565.

### 10 — retire the `Step` encoding — **DEFERRED, not attempted**

Not measured; the tree is unchanged. Recorded so the gap is visible. Step 10 is a seven-stage
programme whose stages are not independent: `10a` admits `MonoIf` on the `$sret` result spine,
which means teaching `generateIf` the spine-yield protocol `generateCase` already implements, and
that cannot be done half-way — admitting `MonoIf` in the selection rule while `generateExpr` still
clears `sretTailLayout` would leave a worker whose branches yield scalars into a region declaring
an aggregate. `10a` alone is predicted flat to slightly negative; the coverage only pays at `10f`,
which needs `10b`-`10e` first: ~263 signatures, 500 combinator uses and 450 `Ok`/`Err` arms across
four files. Deferring costs little — §2 lists step 10 as a prerequisite only for step 26. **It was
attempted in full at the end of the series; see entries `10a` through `10f+10g` below.**

### 11b — memoise `Intern.widenSets` per canonical input — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 280.60 | 1243 | 10 | 20284 | 12,070,640 | 13,336,198 | same |
| r2 | 278.11 | 1243 | 10 | 20284 | 12,058,368 | 13,336,198 | same |
| r3 | 275.15 | 1243 | 10 | 20284 | 12,058,224 | 13,336,198 | same |
| **median** | **278.11** | **1243** | **10** | **20284** | **12,058,368** | 13,336,198 | same |
| D vs 9 | **-11.07 (-3.83 %)** | **-9** | 0 | +15 | **-36,748 (-0.30 %)** | +5,371 | — |

`widenSets` produces the annotation-insensitive spec-registry key and ran in full on every enqueue
— a complete rebuild of the demand type with every arrow relabelled, hash-consing each node. It is
a pure function of a canonical input, so one entry answers every later enqueue of the same demand
type; the intern table gains a second map keyed by the input node. The largest wall win since 4a
and unambiguous: -11.07 s against a 5.45 s spread. One thing had to be fixed or the memo would
have failed SILENTLY: `Engine.withIntern` and `Store.consC` decide whether to write the table back
by comparing `Intern.size`, which counts canonicalised structures and ignores the new map — a run
that only added memo entries would have discarded them while still paying to build them. Both
guards now use an `entries` stamp counting both tables. Byte identity: fixed point and rail
identical on both artefacts. Gates: `full` 1731/1731; unit 13,565. Kept as `keep-11b`.

### 11a — lazy ground-key render in `stampSelfSpine` — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 277.60 | 1238 | 10 | 20301 | 12,073,940 | 13,336,625 | same |
| r2 | 276.33 | 1238 | 10 | 20301 | 12,074,196 | 13,336,625 | same |
| r3 | 277.42 | 1238 | 10 | 20301 | 12,071,668 | 13,336,625 | same |
| **median** | **277.42** | **1238** | **10** | **20301** | **12,073,940** | 13,336,625 | same |
| D vs 11b | -0.69 (-0.25 %) | **-5** | 0 | +17 | +15,572 (+0.13 %) | +427 | — |

`stampSelfSpine` built its ground key eagerly — a full pure rebuild of the demand type plus a
multi-kilobyte string render — on every global reference and call, ~141,000 times per run, for one
arm that reads it. It is now a thunk forced at that site. WIN on rule 2: wall flat, minor cycles
-5. The gain is smaller than the eager work suggests, which says the consuming arm is hit often
enough that the thunk is usually forced — the saving is the minority of calls that never read it.
This row also needed two triples, for the opposite reason to step 9's: the first had identical
counters but an 8.94 s wall spread (3.24 %, over the disturbance threshold), one slow run among
two fast. The re-run spread 1.27 s. Step 9's first triple was disturbed in its COUNTERS; this one
only in wall, and the spread check caught it. Gates: `full` 1731/1731; unit 13,565. Kept as
`keep-11a`. The spec's other half — routing the INTERNED widen into the stamp — is left for later.

### 14 — inline the HPointer resolve in the kernel export path (runtime) — **LOSS, reverted**

| triple | r1 | r2 | r3 | median | spread |
|---|---|---|---|---|---|
| first | 280.37 | 282.61 | 278.32 | 280.37 | 4.29 |
| second | 282.65 | 276.40 | 274.53 | 276.40 | 8.12 |
| pooled (6 runs) | | | | **~279.4** | — |

`Allocator::resolve` was split into an inline fast path in the header and an out-of-line
`resolveSlow`, so `RuntimeExports.cpp` and the kernel translation units could inline it; there is
no LTO in this build. **Not kept, and this step cannot be resolved by this instrument.** It
allocates nothing, so no GC counter can move — the counters were IDENTICAL in all six runs
(1238/10/20301) — which means rule 2 can never fire and wall is the only signal, at ~5 s
resolution. The two triples straddle the reference, the pooled median is ~2 s SLOWER, and the
second triple's spread was 8.12 s. Why it plausibly costs: `resolveFast` was ALREADY an inline
fast path with this body and the hot kernel dereferences use it; what this adds is inlining it
into ~300 mostly-cold `resolve()` sites — code growth at cold sites for a call saved where it was
not hot. That does not show in a self-time profile, which is what the 7.7 % figure was. Reverted.

### 19' — geometric `revMemo` growth — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 283.62 | 1239 | 10 | 20316 | 12,134,468 | 13,336,426 | same |
| r2 | 281.54 | 1239 | 10 | 20316 | 12,133,968 | 13,336,426 | same |
| r3 | 277.91 | 1239 | 10 | 20316 | 12,135,168 | 13,336,426 | same |
| **median** | **281.54** | **1239** | **10** | **20316** | **12,134,468** | 13,336,426 | same |
| D vs 11a | +4.12 (+1.49 %) | **+1** | 0 | **+15** | **+60,528 (+0.50 %)** | -199 | — |

The specification's fallback for step 19, chosen over the full version deliberately: the full one
makes `revMemo` a second `Eco.CellStore` with a lifecycle paired to the point store, where a handle
from the wrong lifetime is a silent wrong id rather than a crash — too much exposure for an effect
the plan sizes at about a second, under this box's wall resolution. **Not kept.** Wall +4.12 s,
flat against the 5.71 s spread, and nothing improved: +1 minor cycle, +15 MiB promoted, +60 MB RSS.
The premise was that every var mint pays a `repeat`, `push` and `append` to grow the array by
exactly the gap. The RSS column says why the trade goes the other way: gaps between consecutive
mints are SMALL, so per-mint growth was small, while doubling an array that reaches ~825,000
entries retains up to twice the trie and copies it in bursts. Paying O(gap) often beat paying O(n)
rarely. The full step 19's premise is now doubtful for the same reason. Reverted.

### 22a — skip the discarded parameter classify in `specializeLambda` — **WIN**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 280.49 | 1237 | 10 | 20293 | 12,078,924 | 13,336,740 | same |
| r2 | 277.42 | 1237 | 10 | 20293 | 12,074,804 | 13,336,740 | same |
| r3 | 278.01 | 1237 | 10 | 20293 | 12,075,144 | 13,336,740 | same |
| **median** | **278.01** | **1237** | **10** | **20293** | **12,075,144** | 13,336,740 | same |
| D vs 11a | +0.59 (+0.21 %) | **-1** | 0 | **-8** | +1,204 (+0.01 %) | +115 | — |

`specializeLambda` classified every parameter type and then used only the NAMES from that result
whenever the head type peeled to the right arity — the normal case, not the fallback. The
classification now runs only when the peel does not line up. WIN on rule 2: wall flat within a
3.07 s spread, both exact counters down. Small, as the sub-item's own estimate implied. The rail's
manifest is identical on all 633; the census differs on 1,060 lines, all zonk counts and their
ledger lines (`sets zonked` 756 -> 725 on one workload) because the discarded classifications were
being counted — exactly as the specification predicted. Two checks make that safe to accept: all
1,266 ledgers still report RECONCILES=yes, and not one `MSET` line moved, so no member content
changed. Gates: `full` 1731/1731; unit 13,565. Kept as `keep-22a`. Sub-items (b), (c), (d) not
done.

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
and a trivial signature now takes the plain isolated load. **Not kept.** Wall -2.00 s is inside the
4.06 s spread, and every other stat moved the wrong way — +15 minor cycles, +24 MiB promoted. A
change that SKIPS work is not supposed to allocate more. The likely mechanism, and the lesson: the
inert test runs at EVERY global call, walking the call's type and every argument type and
allocating a closure for the `List.all`, while the skip only pays on calls that are actually
inert. The spec sized the skipped work but not the test, and **a guard evaluated on the hot path
is itself hot-path work.** Reverted. Step 16's other parts (D2, D4, D10, D12) are not condemned by
this — D4 in particular has no per-call predicate.

### 24(i) — `varSuccRounds` pre-scan + pointer-preserving rebuild — **LOSS, reverted**

| run | wall (s) | — | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
| r1 | 281.94 | — | 1250 | 10 | 20239 | 12,028,904 | 13,337,155 | same |
| r2 | 282.38 | — | 1250 | 10 | 20239 | 12,048,384 | 13,337,155 | same |
| r3 | 283.19 | — | 1250 | 10 | 20239 | 12,028,532 | 13,337,155 | same |
| **median** | **282.38** | — | **1250** | **10** | **20239** | **12,028,904** | 13,337,155 | same |
| D vs 22a | +4.37 (+1.57 %) | — | **+13** | 0 | **-54** | **-46,240 (-0.38 %)** | +415 | — |

| pair | ref (22a) | cand (24i) | diff |
| 1 | 278.56 | 279.92 | **+1.36** |
| 2 | 280.50 | 281.77 | **+1.27** |
| 3 | 275.85 | 277.54 | **+1.69** |
| median paired difference |  |  | **+1.36** |

`succType` rebuilds every registry type on every settle round — six full passes per run — and
already computed a "changed" flag it ignored. It now returns unchanged nodes by pointer, and a
`hasVarAnno` pre-scan skips subtrees that cannot contain a successor write. **Not kept: 1.36 s
slower in all three pairs, paired spread 0.42 s** — the tightest measurement in the series. (The
plain triple had said +4.37 s against a reference two hours old; both agree on sign.) Same lesson
as 16a, now a pattern: **the pre-scan is a full walk, so every subtree that DOES contain a var
annotation is walked twice.** Promoted -54 MiB and RSS -46 MB say the pointer preservation is real;
minor +13 is the scan's own `Dict.foldl` closure per record node. Fusing test into walk is the
thing to try. **A compiler bug surfaced here**: two MUTUALLY RECURSIVE let-bound local functions
emit unparseable MLIR (`invalid value index: -1`); merge them into one. It predates this entry.

### 12 (surgical form) — key `lssSignatures`/`lssInProgress` by `Global`, not by a built string — **LOSS, reverted**

| run | wall (s) | — | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
| r1 | 278.49 | — | 1256 | 10 | 20292 | 12,044,948 | 13,353,457 | same |
| r2 | 275.58 | — | 1256 | 10 | 20292 | 12,050,456 | 13,353,457 | same |
| r3 | 274.24 | — | 1256 | 10 | 20292 | 12,046,092 | 13,353,457 | same |
| **median** | **275.58** | — | **1256** | **10** | **20292** | **12,046,092** | 13,353,457 | same |
| D vs 22a | -2.43 (-0.87 %) | — | **+19** | 0 | -1 | -29,052 (-0.24 %) | **+16,717** | — |

| pair | ref (22a) | cand (12s) | diff |
| 1 | 281.40 | 281.06 | -0.34 |
| 2 | 281.44 | 280.01 | -1.43 |
| 3 | 275.38 | 278.35 | **+2.97** |
| median paired difference |  |  | -0.34 |

Chosen over the spec's full `GlobalId` refactor because the re-profile named the target: 8.2 % of
the run is string comparison, and `signatureFor` probes `lssSignatures` ~2x per translated call —
~10^6 times — each building a 25-50 character key then doing 14-16 compares over a long shared
prefix. **Not kept.** Pairs disagree in SIGN so wall is unresolved, and minor cycles rose 19,
which is exact. **CAUSE ESTABLISHED LATER, by entries 27 and 24(iii)+(iv):** the replacement
probes with `TOpt.globalHash`, whose last line is
`String.foldl (\c h -> globalMixHash h (Char.toCode c)) 23 name` — **an Elm closure call per
character of the name, on every one of ~10^6 probes**, against a `Dict String` descent that
bottoms out in a C++ memcmp. In this compiler hashing a string costs more than the ordered
comparison it replaces. That makes this a RETRYABLE loss, unlike most here: the string build it
removes is real, only the hash is wrong. A retry must carry the hash on the `Global` (computed
once at construction) or go to step 13 proper — integer identity end to end. Do not retry it by
swapping the container alone.

### 27 (new, from the re-profile) — hash the `.ecot` string-intern table — **LOSS, reverted**

| run | wall (s) | — | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
| r1 | **311.63** | — | **1310** | **11** | **20825** | 12,048,200 | 13,342,310 | same |

| caller of the string compare | share |
| `Compiler.AST.StringTable.string` | 20.6 % |
| `Compiler.Elm.Package.collectStringsFromName` | 13.2 % |
| `Mlir.Bytecode.AttrType.attrIndex` | 10.9 % |
| `Compiler.Elm.ModuleName.collectStringsFromCanonical` | 9.3 % |
| `Compiler.AST.Canonical.collectStringsFromType` | 7.7 % |
| `Engine.internMemberKey` (step 13's target) | 14.3 % |
| `Engine.lambdaMemberLayoutQualified` + `insertMemberKey` | 4.7 % |

One run was enough: +33.6 s, +73 minor cycles, an extra MAJOR collection, 532 MiB more promoted;
the remaining runs were abandoned. It came from attributing the re-profile's 8.2 % string block to
its callers — about two thirds is artifact and bytecode INTERNING and under a fifth is the LSS
member keys step 13 targets, so the largest string cost in this compiler is in EMISSION, outside
this plan. `StringTable.strToIdx` looked like the textbook case for hashing: keys already exist,
written once, read many, ~16 prefix-walking compares per probe. **It lost badly, and the reason is
the lesson.** The comparison it replaced runs in C++ (`StringOps::compare`, essentially memcmp);
the hash replacing it runs in ELM — `String.foldl`, a closure invocation per character. **This
condemns the naive form of steps 13, 17 and 21.** Every hashing step that HAS won (2, 4, 11b)
hashes something carrying a precomputed integer, never a string walked per probe.

### 20 — `Point` equality by index rather than through the generic `==` — **no win, reverted**

| pair | ref (22a) | cand (20) | diff |
| 1 | 279.48 | 279.03 | -0.45 |
| 2 | 275.62 | 279.04 | +3.42 |
| 3 | 275.74 | 275.86 | +0.12 |
| median paired difference |  |  | **+0.12** |

`Point` is a single-constructor box around an `Int`, so `==` on two of them goes through the
kernel's structural equality to reach the answer an integer compare gives directly. The three
sites in `UnionFind` — the compression test in `reprS`, the already-equal test in `unionS`, and
`equivalentS` — now compare indices. **Not kept, and this is an instrument limit rather than
evidence of harm.** The change strictly reduces work per operation and is provably equivalent, but
it allocates nothing, so no counter can move — they were IDENTICAL in all runs (1237/10/20293) —
and the paired A/B disagrees in sign with a median of +0.12 s. Under the rule a step that cannot
be shown to help is not kept. This is the same position step 14 ended in, and both should be
revisited with a microbenchmark rather than a whole-compile timing.

### 13 (subset) — memoise the ground-arrow key on `(paramT, resultT)` — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) |
| r1 | 286.22 | 1262 | **11** | 20325 | 11,988,428 |
| r2 | 284.42 | 1262 | **11** | 20325 | 11,996,524 |
| D vs 22a | **+6 to +8** | **+25** | **+1** | +32 | -87,000 |

`groundSetMembers` builds its annotation-widened arrow key with a full pure `widenSets` rebuild
plus a `toComparableMonoType` render, once per SET-SLOT READBACK — ~825,000 times a run — although
it is a pure function of `paramT` and `resultT`, both canonical with precomputed hashes.
Memoising it looked like step 4a's shape, the biggest win in the series. **Not kept, and the
reason is a corollary to entry 27: do not memoise a large STRING.** The saving is real, but each
entry retains a multi-kilobyte string for the life of the run across many distinct arrow shapes —
an extra MAJOR collection, +25 minor cycles, RSS +87 MB as the retained table trades against the
nursery. Step 4a's memo retained interned `MonoType`s that were ALREADY live; this manufactures
new retention. Which is the argument for step 13 PROPER: the win is not caching the rendered key,
it is never rendering one.

### 23 — lazy kernel-ABI `MVarEnv` + gate `widenedByKernel` — **no win, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) |
| median of 3 | 280.87 | 1237 | 10 | **20255** | 12,109,264 |
| D vs 22a | +2.86 | 0 | 0 | **-38** | +34,120 |

| pair | ref (22a) | cand (23) | diff |
| 1 | 279.70 | 277.59 | -2.11 |
| 2 | 276.41 | 279.19 | +2.78 |
| 3 | 274.28 | 276.30 | +2.02 |
| median paired difference |  |  | **+2.02** |

An `MVarEnv` was built on every kernel call and bare kernel reference through its own `andThen`
layer, although `deriveKernelAbiMode` ignores it — its third parameter is literally `_` — and only
one branch consumes it. The parameter was dropped (three callers) and the env is built inside the
branch that reads it; the ungated `widenedByKernel` counter, which costs an `S` and an `LssStats`
copy per rowless or refused boundary for a single report line, moves behind the report flag.
**Not kept.** Both measurements lean slower: the triple +2.86 s, the paired A/B +2.02 s with two
of three pairs positive. The only improvement is 38 MiB of promotion, 0.19 %; treating that as a
rule-2 win while two independent wall measurements lean the other way is the mistake rejected at
entry 12. The parameter removal is correct regardless of timing and is reverted only because it
travelled with the rest.

### 17 — `Data.HashMap` buckets: `Dict Int` to an array-backed table — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) |
| r1 | 276.68 | 1262 | 10 | 20284 | 12,089,348 | 13,408,214 |
| r2 | 281.28 | 1262 | 10 | 20284 | 12,090,552 | 13,408,214 |
| r3 | 279.02 | 1262 | 10 | 20284 | 12,090,480 | 13,408,214 |
| **median** | **279.02** | **1262** | **10** | **20284** | **12,090,480** | 13,408,214 |
| D vs 22a | +1.01 | **+25** | 0 | -9 | +15,336 | +71,474 |

The bucket map was a red-black `Dict Int`, so every insert copied a path of ~17 nodes to store a
bucket found by a hash that needs no ordering. Replaced with a power-of-two `Array` indexed by a
mask, doubling at load factor two, sequence numbers carried across the rehash so iteration order is
untouched. **Not kept: 25 more minor cycles.** The reasoning was right about the intern table
(~100,000 inserts) and wrong about everything else: most `HashMap`s here are SMALL and short-lived
per-item tables holding a handful of entries, and for those the change replaces a `Dict` that
starts genuinely empty with a 64-element `Array.repeat` at construction plus a 32-wide trie node
copy per `Array.set`. The big table's saving is real but outnumbered. The obvious repair — a
smaller initial capacity, or a list until the map outgrows it — was not tried: at +25 minor cycles
the headroom is a fraction of a percent, which this instrument cannot resolve.

### 16 (D4) — skip the report-only store DFS in `degradeToSymmetric` — **no win, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) |
| r1 | 280.68 | 1238 | 10 | 20387 | 12,120,732 |
| r2 | 282.58 | 1238 | 10 | 20387 | 12,111,840 |
| delta vs 22a | +3 | +1 | 0 | +94 | +40,000 |

`storeMentionsArrow` is a full store depth-first walk that threads and copies `S` per visited
node, and its only consumer is the arrow-mention test feeding `bumpFlowDegraded`, which is itself
already report-gated — so off report the walk computes a Bool and throws it away. The candidate
skips it: the same pure-removal shape that won in steps 6 and 7. **Not kept: nothing improved.**
The only reading consistent with a pure removal making every stat slightly worse is that the site
is RARE — `degradeToSymmetric` fires on container-typed directed flows only — so there was almost
nothing to remove, and what remains is the noise floor plus 162 bytes of added source. The step's
own estimate was a fraction of a percent, and that is what it measured. Run 3 was abandoned once
the first two agreed on both sign and counters (deterministic per binary x tree, so r1 == r2 on
all four is conclusive).

### 15 — `enqueueSpecKeyed` hit path (`15b`: tally probe behind the budget, widen on create only) — **LOSS, reverted**

| pair | ref `eco-opt22a` | cand `eco-opt15` | diff |
| 1 | 273.35 | 278.54 | **+5.19** |
| 2 | 278.39 | 280.81 | **+2.42** |
| 3 | 279.63 | 284.46 | **+4.83** |

Measured with the INTERLEAVED form, the step's own estimate (1-3 % of the mono window) being
below unpaired wall resolution. The candidate builds the five-part global string and probes
`specCountByGlobal` only when `maxSpecsPerGlobal > 0` (0 by default), runs `Intern.widenSets` only
on the over-budget arm or a CREATE, and skips the `{ s | registry, … }` rebuild on the hit path.
**It is slower, reproducibly**, same sign in all three pairs against a 0.42 s paired resolution,
with GC counters IDENTICAL in both arms and both emitting byte-identical MLIR. The hit path
genuinely does less work, so the cost is structural: the rewrite splits one straight-line `let`
into a two-armed `if created` with bindings live across both, and moves the widen after the
registry probe. Same shape as 16a and 24i — **a guard on a hot path is hot-path work**. Do not
re-try `15b` as written; only the tally probe alone (`15a`) is worth isolating.

### 18b — per-literal string-intern cache in the codegen — **WIN, kept**

| pair | ref `eco-opt22a` | cand `eco-opt18b` | diff |
| 1 | 279.97 | 275.76 | **-4.21** |
| 2 | 280.63 | 279.22 | **-1.41** |
| 3 | 276.65 | 274.49 | **-2.16** |

The first entry that changes the CODEGEN rather than compiler source or runtime: the candidate is
the reference's own unmodified `eco22a.mlir` lowered by a rebuilt `eco-boot-native`, so
byte-identity is structural. Every string literal lowered to a call to
`eco_alloc_string_literal_utf8`, which is not gc-leaf, so RS4GC statepointed it — every live
`ptr addrspace(1)` spilled and reloaded around what is, after first evaluation, a hash lookup
returning an immutable pointer. Each `__eco_str_*` global now gets a zero-init `__eco_strlit$` i64
sibling and the call becomes a load/test/`scf.if` diamond. The slot needs no GC root because the
runtime publishes the word ONLY when the interned object landed in PermanentSpace (HEAP_036). The
win exceeds the callee's 0.60 % self time — the difference is statepoint traffic that never
appeared under its own symbol. Gates: E2E 1731/1731; self-compile reproduces `eco22a.mlir`.

### 18a — length-first primitive-name dispatch (`normalizePrimHome`, `classifyApp`, `Zonk`'s `TType` arm) — **LOSS, reverted**

| pair | ref `eco-opt18b` | cand `eco-opt18a` | diff |
| 1 | 279.37 | 281.54 | **+2.17** |
| 2 | 272.86 | 281.66 | **+8.80** |
| 3 | 275.36 | 277.21 | **+1.85** |

Measured immediately after 18b, against it. The candidate replaced a `case name of` chain of
string-pattern arms with `case String.length name of` plus at most three `==` compares and, only
on a name hit, the module test, at `Store.normalizePrimHome`, `Store.classifyApp` and
`Zonk.canTypeToMonoWithI`'s `TType` arm. Same sign in all three pairs; both arms emit
byte-identical MLIR, so the rewrite is BI as predicted — simply slower. **18b removed 18a's
premise.** The spec priced the old shape at up to 8 intern probes + 8 statepoint calls + 8
`Utils.equal` per node; 18b deleted the probes and statepoints, and what remains of a
string-pattern arm is a `__eco_value_eq` whose FIRST test is raw pointer equality against an
interned literal — one compare for an interned type name. Third instance of the 16a/24i lesson:
**once the thing being skipped is cheap, the test that skips it dominates.** Do not re-try.

### 22b — one member mint per lambda — **WIN on the counters, kept**

| pair | ref `eco-opt18b` | cand `eco-opt22b` | diff |
| 1 | 283.32 | 278.43 | -4.89 |
| 2 | 276.77 | 274.39 | -2.38 |
| 3 | 275.75 | 280.90 | **+5.15** |

| stat | ref | cand | delta |
| minor GC | 1238 | **1237** | -1 |
| major GC | 10 | 10 | 0 |
| promoted MiB | 20363 | **20335** | -28 |
| max RSS kB | 12,093,664 | **11,916,868** | **-176,796 (-1.5 %)** |

`classifyLambdaHead` already mints the lambda's member id, and `specializeLambda` minted it a
SECOND time purely to fill `ClosureInfo.lssMember` — state-idempotent but not cheap: each ran
`instanceQualTagFor`, the `rootLamOf` fold, `layoutQualKey` (a multi-kilobyte string concat) and a
`byKey` probe. `classifyLambdaHead` now returns `( MonoType, Maybe Int )`;
`lambdaInstanceMemberMaybe` is deleted. **Judged on the counters, not the wall**: the paired
differences disagree on sign (-4.89/-2.38/+5.15), so wall is FLAT, and three DETERMINISTIC stats
improved — exact per (binary x tree), so a 176 MB RSS drop is a fact at n=1. Gates: unit 13,565;
E2E 1731/1731; rail manifest identical on all 633, census differing on EXACTLY the three predicted
lines and no other. LSS_017's identical-stamping requirement now holds by CONSTRUCTION.

### 22d — pointer-preserving `overlayAnnotations` (+ join entry test, `sameFieldKeys`) — **WIN, kept**

| pair | ref `eco-opt22b` | cand `eco-opt22d` | diff |
| 1 | 277.92 | 268.50 | **-9.42** |
| 2 | 275.92 | 272.75 | **-3.17** |
| 3 | 279.27 | 270.19 | **-9.08** |

The largest single win since step 3. `Mono.overlayAnnotations` rebuilt the ENTIRE type tree on
every call — `mFunction`/`mList`/`mTuple`/`mRecord`/`mCustom` at every node, `List.map2` at every
argument list, a fresh `Dict` at every record — whether or not the zonk contributed a single
annotation, on the hottest paths in translation. `overlayAnnotationsChanged` rebuilds only the
spines that changed, leaves siblings pointer-shared, and returns `structural` ITSELF when nothing
changed; an O(1) `structural == annoSource` entry test short-circuits the walk, and the public
name stays a `Tuple.second` wrapper so no call site moved. Riders: the same entry test on
`joinAnnotationsChanged`, and `sameFieldKeys` for `Dict.keys a == Dict.keys b`. Gates: unit
13,565; E2E 1731/1731; **rail manifest AND census byte-identical — not one line differs**, the
strongest gate result in the series.

### 22c — the same pointer-preserving protocol for `enrichAnnotationsWith` — **LOSS, reverted**

| pair | ref `eco-opt22d` | cand `eco-opt22c` | diff |
| 1 | 273.18 | 276.63 | **+3.45** |
| 2 | 270.95 | 274.37 | **+3.42** |
| 3 | 270.42 | 271.00 | **+0.58** |

The obvious follow-up to 22d: identical treatment for the enrich family, same entry test, same
`Tuple.second` wrapper so no call site changes, plus the `a == b` test on pure `joinAnnotations`.
Same sign in all three pairs; minor GC identical, promoted 5 MiB better (nothing), RSS slightly
worse. Wall up ⇒ LOSS, and the counters do not rescue it. **Why the same change wins on overlay
and loses on enrich.** `overlayAnnotations` transplants annotations that MOSTLY are not there, so
the no-op case dominates and pointer preservation skips a whole-tree rebuild. Enrich is called
precisely BECAUSE a merge is expected to add something: the `merged /= annoA` test, the Bool
threading and the extra indirection are paid on every node, and the no-op case is rare. **The
population, not the shape of the code, decides** — the profitable one was harvested by 22d.
Byte-identical; preserved in `try-22c`.

### 24(iii)+(iv) — `varSuccRounds` member decode through `sources`; delete dead `varArgIds` — **LOSS, reverted**

| pair | ref `eco-opt22d` | cand `eco-opt24k` | diff |
| 1 | 268.95 | 276.42 | **+7.47** |
| 2 | 269.99 | 275.39 | **+5.40** |
| 3 | 267.35 | 277.37 | **+10.02** |

(iii) deleted the two per-ROUND dictionary builds at the head of `varSuccRounds` — `midKeys`
(inverting the 62,647-entry `byKey`) and `compGlobals` — and replaced the per-member
`String.split "|"` decode with a direct `Dict.get m sources` read. (iv) deleted `varArgIds` and a
dead `argIds` parameter. **The largest regression in the series.** Counters moved the right way
but trivially. **Why deleting three big dictionary builds made it 7.5 s slower**: the builds are
per ROUND — three across the whole run — while the replacement runs per MEMBER per arrow position
over all ~43K rows and contains `HashMap.get TOpt.globalHash (==) g toptNodes`; **`globalHash`
hashes the module name and name STRINGS in Elm, a closure call per character**, where
`Dict.get gstr compGlobals` bottoms out in a C++ compare. Entry 27's finding from the other
direction. (iv) is genuine dead code and is preserved in `try-24k`.

### 24(i') — pointer-preserving `succType` (no pre-scan) — **WIN, kept**

| pair | ref `eco-opt22d` | cand `eco-opt24i2` | diff |
| 1 | 277.31 | 272.36 | **-4.95** |
| 2 | 274.65 | 270.59 | **-4.06** |
| 3 | 267.12 | 268.45 | +1.33 |

24(i) lost by adding a `hasVarAnno` PRE-SCAN on top of a pointer-preserving rebuild. This is the
same target with the pre-scan removed — the shape that won as 22d: every arm of `succType` returns
its input `t` BY POINTER when nothing under it moved, and the record arm folds changed fields in
rather than rebuilding from `Dict.empty`. `succType` walks every one of ~43K registry rows on
every round, and the vast majority carry no pap-able var arrow, so nearly all of that was
immediate garbage. Minor GC -4, deterministic, corroborating the wall. **The compiler bug got in
the way**: pointer-preserving the argument-list walks too needs a `succList` mutually recursive
with `succType`, which lowers to unparseable MLIR, so the `List.foldr` rebuilds were kept — and
that fold threads state RIGHT TO LEFT, so any replacement must preserve it or mint order moves.
Gates: unit 13,565; E2E 1731/1731; rail manifest AND census byte-identical.

### 21a — `BitSet` membership twin for `provisionalStandalone` — **LOSS, reverted**

| pair | ref `eco-opt24i2` | cand `eco-opt21a` | diff |
| 1 | 273.06 | 275.92 | +2.86 |
| 2 | 271.93 | 275.46 | +3.53 |
| 3 | 274.18 | 268.80 | -5.38 |

The cheapest and hottest slice of step 21, isolated: `groundSetMembers`' fast path asks "is ANY
member of this slot provisional?" once per member per SET ZONK (654,140 zonks), answered by a
red-black descent through 43K Int keys. The candidate added `provisionalBits : BitSet` to
`LssMemberTable` and switched the three membership tests to `BitSet.member`. **LOSS**: minor GC
IDENTICAL, promoted -4 MiB (0.02 %), RSS within noise, wall up. `BitSet.member` is
`Array.get (mid // 32)` on a 32-way persistent trie plus a shift and a mask — two or three
indirections, not obviously fewer than the descent it replaces — and the new field widens
`LssMemberTable`, so every `{ t | … }` copies one more slot. **Same class as entry 27**, now for
Int keys: a "cheaper" container is only cheaper if the operation it replaces was the expensive
part. Step 21's other targets are probed differently and remain undecided by this.

### 24(vii)a — de-PAP `typeHasResidualNumber` — **WIN, kept**

| pair | ref `eco-opt24i2` | cand `eco-opt24v7` | diff |
| 1 | 270.92 | 264.05 | **-6.87** |
| 2 | 271.49 | 266.78 | **-4.71** |
| 3 | 272.16 | 264.73 | **-7.43** |

**Nine lines, -6.87 s** — the best ratio of effect to edit size in the series. Prune's
`typeHasResidualNumber` walks every live node type, and at every `MTuple`, `MCustom` and
`MFunction` called `List.any (typeHasResidualNumber isNumber) xs` — a PARTIAL APPLICATION, so each
node allocated a PAP and dispatched it generically per element. A direct `anyResidualNumber`
recursion allocates nothing and calls directly, with the same left-to-right `||` short-circuit.
**The plan estimated 0.7 % of the mono window; it measured 2.5 % of the whole run** — seven times
over. The plan priced the generic DISPATCH the PAP causes, which the dispatch census could see;
it did not price the PAP ALLOCATION. Generalises immediately: **`List.any`/`map`/`all`/`foldl`
applied to a PARTIALLY APPLIED function on a per-node path is an allocation per node.** Gates:
unit 13,565; E2E 1731/1731; rail manifest and census byte-identical. Part two was not built.

### 24(vii)b — de-PAP three more hot list predicates — **no win, reverted**

| pair | ref `eco-opt24v7` | cand `eco-opt24v7b` | diff |
| 1 | 267.58 | 267.19 | -0.39 |
| 2 | 269.45 | 271.70 | +2.25 |
| 3 | 267.76 | 274.13 | +6.37 |

The direct follow-up to 24(vii)a: the same de-PAP at the other partially-applied list combinators
on the solver path — `resolveNumberType`'s three `List.map`, `groundNoArrowWith`'s two `List.all`,
`hasFunctionCapable`'s two `List.any`. **No win.** Minor GC IDENTICAL, which is the finding:
**the PAPs these sites allocate do not show up in the allocation counter at all**, so there were
few of them. **This bounds 24(vii)a's lesson rather than extending it.** The de-PAP is worth 2.5 %
at `typeHasResidualNumber`, which Prune runs over EVERY live node type, and nothing at three sites
that look identical in source but are not hot: `groundNoArrowWith` sits behind the alias memo,
`hasFunctionCapable` runs on a few hundred kernel signature checks, and `resolveNumberType` only
walks types `typeHasResidualNumber` already flagged. `List.any (f x)` is a reliable *smell*, a
*cost* only where the enclosing walk is hot. Byte-identical; preserved in `try-24v7b`.

### 24(ii) — one `varSucc` pass; the verification pass is report-gated — **WIN, kept**

| pair | ref `eco-opt24v7` | cand `eco-opt24ii` | diff |
| 1 | 268.41 | 264.70 | **-3.71** |
| 2 | 267.93 | 264.89 | **-3.04** |
| 3 | 268.60 | 270.28 | +1.68 |

`settleVarSuccessors` ran `varSuccRounds` to a fixed point (fuel 16), but the census said
`varsucc|rounds = 3` — (write + empty) then (empty), i.e. **exactly one wasted traversal of all
~43K rows**. The pass is idempotent: rows are independent, the within-row walk is TOP-DOWN on the
result spine so a chain of any depth completes in one pass, the member table is monotone, and
`succSetFor`'s verdict is round-invariant. The comment claiming a cross-row dependency described
one this code does not have. `varSuccPass` now runs once; under `report` a second run is a
VERIFICATION RAIL whose registry is discarded. **All three deterministic counters improved.**
**The idempotence was measured, not just argued**: the rail prints `varsucc|verifyClean` and never
`verifyCHANGED` for every one of the 633 workloads. Gates: unit 13,565; E2E 1731/1731; rail
manifest identical; fixed point OK.

### 5b — direct-state `Unify` combinator layer — **LOSS, reverted — and the most informative entry in the series**

| | pair 1 | pair 2 | pair 3 |
|---|---|---|---|
| triple A (diff) | +8.03 | -2.62 | +4.86 |
| triple B (diff) | +9.37 | +5.94 | +1.33 |

| stat | ref `eco-opt24ii` | cand `eco-opt5b` | delta |
|---|---|---|---|
| minor GC cycles | 1240 | **1214** | **-26** |
| promoted MiB | 19,992 | 20,009 | +17 |
| max RSS kB | 11,437,240 | 11,486,464 | +49 MB |
| **GC/Alloc time (s)** | **121.72** | **127.03** | **+5.31** |

5a removed the `IO.andThen`/`Ok`/`UnifyOk` scaffolding from the unify ENTRY and won; 5b removes it
from the RECURSION, where unification runs upwards of 10^6 times per self-compile. **It worked
exactly as designed, and the compiler got slower** — six pairs, five positive, pooled median
+5.40 s. **The allocation reduction is real and the slowdown is its consequence**: minor GC fell
26 cycles, by far the largest counter move in the series, while GC TIME rose 5.31 s, which is the
whole regression. **Minor GC count is a proxy for allocation VOLUME; minor GC cost is paid for
SURVIVORS.** Objects that die before the next collection are free. Deleting them makes the nursery
fill more slowly, so each collection spans MORE elapsed work and finds more of the live set still
alive. **This corrects the series' central heuristic: time is SURVIVOR COPYING, and allocation
volume is only a proxy.** Judge on GC TIME and promoted bytes. Byte-identical; kept in `try-5b`.

### 16 (D10, Let arm) — skip the load and join at ground arrow-free let bindings — **no win, reverted**

| pair | ref `eco-opt24ii` | cand `eco-opt16d10` | diff |
|---|---|---|---|
| 1 | 273.34 | 273.13 | -0.21 |
| 2 | 269.82 | 272.88 | +3.06 |
| 3 | 271.04 | 271.38 | +0.34 |

A GROUND, arrow-free let binding has exactly one instance, so `joinLetUse`'s guard fires on every
read and the `letEnv` entry is provably never consumed. The candidate skipped `loadType defType`
and `sigFlowJoinInto`, and REMOVED the name from `letEnv` so a shadowed outer arrow-typed binding
cannot be found by an inner occurrence. The predicate is `groundNoArrow` — GROUND, not merely
arrow-free, because a GENERALISED let can be USED at an arrow type. **Flat**: one minor cycle
better, promoted, RSS and GC time all worse. Byte-identical and the fixed point holds, so the BI
argument was right; there is simply nothing there. **Most likely already harvested by step 4a** —
D10's whole value is the skipped LOAD, of a GROUND type, which is exactly the population 4a's
load memo already turns into a hit. Third entry (after 8a and 18a) whose premise was deleted by a
step that landed in between. Read a spec against the tree as it IS.

### 24(v) — ctor-row bitmap built once — **no win, reverted**

| pair | ref `eco-opt24ii` | cand `eco-opt24v` | diff |
|---|---|---|---|
| 1 | 267.66 | 272.09 | +4.43 |
| 2 | 274.09 | 268.62 | -5.47 |
| 3 | 271.88 | 274.89 | +3.01 |

Both ctor-row sweeps asked "is this row's key a ctor or box global?" per row per pass — FOUR
`HashMap.get TOpt.globalHash (==) …` probes over ~43K rows, each allocating a `TOpt.Global` and
hashing its strings in Elm. The candidate computes the answer once into a `BitSet` over the row
index, legal because the sweeps write registry TYPES only, never keys. **No win**: minor GC
IDENTICAL, everything else within nothing, byte-identical. **About 129,000 string hashes and
`TOpt.Global` allocations were removed and no counter noticed.** That is the scale lesson: the
settle sweeps run ONCE at the end of monomorphization over 43K rows, so even four passes of a
genuinely wasteful probe is a rounding error beside the per-ITEM work the solver does millions of
times. The same probe removed from a per-item path would be worth measuring; from a
per-registry-pass path it is not. The `gkeyOf`/`moduleOf` caching half was not built.

### 25 — AbiCloning: census-gate `hostGlobal`, one-pass spec scans — **WIN, kept**

| pair | ref `eco-opt24ii` | cand `eco-opt25` | diff |
|---|---|---|---|
| 1 | 271.10 | 265.09 | **-6.01** |
| 2 | 268.51 | 266.27 | **-2.24** |
| 3 | 269.38 | 265.28 | **-4.10** |

The last plan step with no measurement. Three post-mono changes in `AbiCloning.elm`, none of which
changes a decision: `hostGlobal` (a five-part global string built for every one of ~43K specs and
read only behind `if not ctx.census`) is now census-gated; `papResolve` builds its pairs and asks
its `Nothing` question in one `List.foldr` instead of walking a 1,939-element list twice; and
`matchSpec`'s two chained `List.filter`s become one fold, `==` implying `eqLayout`. Same sign in
all three pairs; GC time -2.90 s. **The plan estimated "well under 1 %" and it measured 1.5 %.**
The reason is visible in the GC-time column: what these remove is not CPU but RETAINED
intermediate lists and strings at a point where the graph is large — by step 5b's finding, the
allocation that actually costs. Gates: unit 13,565; E2E 1731/1731; rail manifest AND census
byte-identical, which matters here because the rail diffs `abiCensusLines` too.

### 26a — nest the six scheduling fields of `S` into a `sched` group — **LOSS, reverted**

| pair | ref `eco-opt25` | cand `eco-opt26a` | diff |
|---|---|---|---|
| 1 | 273.07 | 269.36 | -3.71 |
| 2 | 267.55 | 271.61 | +4.06 |
| 3 | 269.21 | 272.90 | +3.69 |

**Step 26 specifies its own decision gate, and the gate was measured first**: lowered with
`ECO_INLINE_ALLOC=0` and a uprobe on `eco_alloc_record`, the self-compile allocated **11,939,218**
31-field `S` records — ~2.96 GB of payload, over the plan's ~10 M threshold, so it was built.
`sched` groups six fields written only on schedule/dirty/port events, taking `S` from 31 to 26
slots: **about 476 MB less allocation.** Every deterministic counter moved the right way and by
almost nothing — **GC time 127.91 vs 128.53 s, just 0.62 s.** Wall up ⇒ LOSS. **476 MB of nursery
traffic bought 0.62 s — about 1.3 µs per megabyte, essentially free.** Step 5b's finding from the
other direction, priced exactly. **This closes step 26 including 26b/26c/26d**: same
transformation, same 11.9 M copies, ~0.12 s per removed slot against an indirection on every read.
No grouping of the remaining fields reaches a win.

### Post-series verification: full bootstrap on the kept tree (2026-09-20)

| gate | result |
|---|---|
| `cmake --build build --target elm-tests` | 13,565 passed, the same 12 pre-existing failures |
| `cmake --build build --target full` | **1731 / 1731** |
| `cmake --build build --target bootstrap` | **exit 0**, whole chain |
| Stage 4b — JS fixed point | `eco-boot-2.js == eco-boot-3.js` |
| Stage 8c — native fixed point | `eco-compiler-boot == eco-compiler-boot-2` |
| Stage 9b — unified binary | `eco` (243,388,712 B) self-compiles to `eco-2` (74,890,568 B) |

Run on `keep-25` after the series closed, to confirm the loop's private `bin/eco-opt-prev` chain
had not drifted from the real bootstrap. **The bootstrapped compiler is byte-identical to the
binary this series measured**: `eco-compiler-boot`, `eco-2` and `keep-25/bin/eco-opt25` are the
same 74,890,568 bytes, and `eco-compiler-boot.mlir` has the same sha256 as `eco25.mlir`. Three
independent routes to one artifact. Method note: the node-hosted stages (2-5) ran under
`ECO_MONO_ENGINE=subst`, which `compiler/CMakeLists.txt:419-423` requires on a 15 GB host. That
does not weaken the result — Stage 8c compares two NATIVE artifacts, both at the defaults
(`EngineSolver`, `lss.enabled = True`) — and it gave incidental subst-path coverage of the
engine-independent work. Stage 7a's 4:52.99 is NOT comparable with this series' 265.28 s: its
compiler was lowered from SUBST-produced MLIR.

### 10a — admit `MonoIf` on the `$sret` result spine — **WIN on the counters, kept**

| pair | ref `eco-opt25` | cand `eco-opt10a-b` | diff |
|---|---|---|---|
| 1 | 272.28 | 271.28 | -1.00 |
| 2 | 266.91 | 269.52 | +2.61 |
| 3 | 271.57 | 271.29 | -0.28 |

Step 10's first stage and its enabler: until now an `if` anywhere on a function's result spine
disqualified the WHOLE function from `$sret` promotion, so its `( a, S )` return stayed a heap
tuple. `Backend.sretTailOk` and `sretFreshTailOk` gain the `MonoIf` arm `sretTailFuncOk` has had
all along, and `Expr.generateIf` learns the spine protocol `generateCase` implements — the result
rule extracted into a shared `spineResultMlirType`, branch yields through `emitSpineYield`, the
join by `finishSpineCase`. Two load-bearing details: the condition is NOT on the spine, so
`generateIf` clears `sretTailLayout` for it and restores it for the branches (a leaked flag there
would make-promote a Bool-typed case — the `eco.papExtend` aggregate-operand incident); and
flag-off emission is unchanged token for token. Wall flat, counters improved. Codegen change, so
the extra bootstrap turn and the rail both apply. Kept as `keep-10a`.

### 10b — the probe: classify family and `connectTypes` to direct state — **WIN, kept**

| pair | ref `eco-opt10a-b` | cand `eco-opt10b` | diff |
|---|---|---|---|
| 1 | 271.18 | 267.79 | **-3.39** |
| 2 | 272.70 | 271.61 | **-1.09** |
| 3 | 273.98 | 272.53 | **-1.45** |

The stage that proves the mechanism before the large rewrite. Seven `Store` classify functions
drop their `Result Failure` and become `S -> ( a, S )`; `loadTypeS` becomes the real function with
`loadType` a one-line adapter; `Translate.classify`/`classifyAs` go direct with `…Step` adapters
for the 27 still-combinator sites; and `connectTypes` becomes `S -> S`, allocating nothing at all.
**Minor GC is IDENTICAL (1234), and that is the point.** This win did not come from allocating
less — it came from not touching the heap at all: `$sret` returns the pair in registers, so the
`( a, S )` that used to be built, boxed and immediately destructured never exists. **That is the
lever step 5b did not have**, 5b having removed short-lived boxes the runtime charges almost
nothing for. Two R4 discoveries here: a bottom (`crashFailure`) is not a tuple literal and must be
wrapped, and mutually recursive call leaves must be re-tupled to bootstrap the least fixpoint.

### 10c — the failure channel — **FLAT, kept as the enabler for 10d/10e**

| pair | ref `eco-opt10b` | cand `eco-opt10c` | diff |
|---|---|---|---|
| 1 | 265.49 | 265.30 | -0.19 |
| 2 | 271.75 | 271.61 | -0.14 |
| 3 | 266.23 | 270.37 | +4.14 |

The stage with the semantic decision in it: `Step` cannot lose its `Result` until every `Failure`
has somewhere else to go. **Policy, per class.** `EngineBug` and `Unsupported` are "never a
fallback" by their own docstring — every site aborts — so the 24 sites raising them call
`Engine.crashFailure`, printing the SAME rendered text via `renderFailure`, moved here from
`Monomorphize`. `UnifyMismatch` is manufactured in one place and recovered in exactly three, which
read a `Bool`; everywhere else it aborts, so `unifyStrictS` crashes with the same message and the
context stays a THUNK so the diagnostic's type walks are built only on the aborting path.
**`LimitExceeded` stays a clean failure** — MONO_030 calls it diagnosable and `SpecWatchdogTest`
pins it — travelling as `ItemAux.pendingFailure`, on `ItemAux` rather than `S`, which is at 31 of
the runtime's 32-slot cap. Flat; kept as the enabler for the rest of step 10.

### 10e-i — the Store zonk and classify families fully direct-state — **WIN, kept**

| pair | ref `eco-opt10c` | cand `eco-opt10ei` | diff |
|---|---|---|---|
| 1 | 273.56 | 265.22 | **-8.34** |
| 2 | 271.15 | 269.86 | **-1.29** |
| 3 | 272.49 | 263.14 | **-9.35** |

The second-largest single win of the series. `Store.zonkToMono` (11.8 % of the mono window),
`zonkToMonoC`, `zonkFlatC`, `residualWithTaintC`, `zonkListC`, `zonkRecordFieldsC`,
`zonkRecordExtC`, `monoTypeToVarS` and the `loadType` family all drop their `Result` and become
`S -> ( a, S )` / `ZonkCtx -> ( a, ZonkCtx )`, with 21 call sites repointed off the adapters.
Same sign in all three pairs; **minor GC IDENTICAL (1232)** — for the third time in this step the
win is not allocation volume. **`$sret` coverage 32 -> 42 MonoSolver workers**, double the series
baseline's 21. Getting the last three took two more applications of R4 — eight mutually recursive
call leaves re-tupled, and two `crashFailure` bottoms wrapped in the tuple, the difference between
40 and 42. **A leaf must be a tuple LITERAL; neither a bare call nor a bottom qualifies.** Gates:
BI both arms, rail manifest and census identical, unit 13,565, E2E 1731/1731.

### 10e-ii — Translate's 30 remaining signatures direct-state — **LOSS, not kept as a step**

| pair | ref `eco-opt10ei` | cand `eco-opt10eii` | diff |
|---|---|---|---|
| 1 | 257.25 | 260.45 | **+3.20** |
| 2 | 255.93 | 260.13 | **+4.20** |
| 3 | 258.27 | 259.15 | **+0.88** |

| | `lift` | `liftU` | `afterU` | total |
|---|---|---|---|---|
| `keep-10ei` | 7 | 3 | 3 | **13** |
| `try-10eii` | 38 | 30 | 9 | **77** |

The last file of stage 10e. `Translate`'s `demandUnify*`, `instantiate*`, `resultVarAfter`,
`unifyResultWithExpected`, `noteAppliedS`, the whole `injectArgLambdaMember` family, `insertVars`,
the `annoPairFold` census family and `enrichFromEnv`'s tuple arm drop their `Result`; two
`Monomorphize` call sites follow. Same sign in all three pairs. Every counter moved the RIGHT way
and by almost nothing, so the +3.20 s is **mutator time, not collection**. `$sret` 42 -> 82 and
the MLIR is 24,782 B SMALLER — the emission side did exactly what step 10 predicted.
**Why it still lost: the transitional adapters.** `lift`/`liftU`/`afterU` each allocate a closure
at their USE site, so converting a callee whose callers are still `Step`-typed MOVES the boxing
rather than removing it — 13 adapters became 77, on per-call paths. **A statement about the
HALF-CONVERTED state, not about step 10**: the conversion is monotone only at its endpoints.

### 10f — `Step` stops being a monad — **WIN on wall, marginal**

| pair | ref `eco-opt10ei` | cand `eco-opt10f` | diff |
|---|---|---|---|
| 1 | 253.88 | 253.93 | +0.05 |
| 2 | 258.06 | 253.53 | **-4.53** |
| 3 | 255.76 | 254.95 | **-0.81** |

The 10e-ii diagnosis pointed at a change 10e-ii itself made available. The `Result` in
`Step a = S -> Result Failure ( a, S )` was dead weight: **no `Err` is ever CONSTRUCTED in
`Translate`** — all 97 occurrences are `Err e -> Err e` pass-throughs — `Engine.fail` has zero
users, and 10c had already moved the one real in-graph failure onto `pendingFailure`. So the alias
changed instead, to `S -> ( a, S )`. Everything followed: the combinator layer lost its `Result`
match and `Ok` box, **`Engine.lift` became the identity**, 45 arm pairs and 106 `Ok` wrappers
collapsed, and `Result Failure` survives at exactly three driver functions. **The number that
matters is not the wall but the allocation: objects fell 0.03 %** (292,652,883 -> 292,557,278).
The inliner and `MonoInlineSimplify` were already folding `case (Ok x) of Ok y -> …` away. Not
kept — see `10f+10g`; its margin is inside its own three-pair spread, and one pair is positive.

### 10f+10g — the whole `Step` monad retired — **LOSS**

| pair | ref `eco-opt10ei` | cand `eco-opt10fg-b` | diff |
|---|---|---|---|
| 1 | 235.64 | 235.07 | -0.57 |
| 2 | 232.29 | 238.89 | **+6.60** |
| 3 | 231.43 | 236.74 | **+5.31** |
| 4 | 237.19 | 236.28 | -0.91 |
| 5 | 232.47 | 238.50 | **+6.03** |
| 6 | 231.65 | 237.60 | **+5.95** |

| | combinator uses in `Translate` | adapters | MonoSolver `$sret` | all `$sret` |
|---|---|---|---|---|
| `keep-10ei` | 320 | 13 | 42 | 528 |
| `try-10eii` | 320 | **77** | 82 | — |
| `try-10f` | 320 | 0 | 115 | 601 |
| `try-10g2` | **0** | **0** | **148** | **635** |

The rest of step 10, taken all the way: all 55 combinator-shaped `Translate` functions rewritten
as explicit `case … of ( a, s1 )` chains, then `andThen`, `map`, `map2`, `succeed`, `getS`,
`modifyS`, `runStep`, `lift`, `liftU`, `afterU`, `scopedStep`, `withScratchStoreStep` and
`thenAlso` deleted from `Engine`. Rewriting the chains is not style: a function whose result-spine
leaves are tuple LITERALS is eligible for `$sret`; one written as a combinator chain never is.
Six pairs in two sittings, reproducing each other pair-for-pair. Counters: minor 1122 -> 1118,
promoted +20 MiB (worse), GC time +1.4 s, MLIR 123,251 B smaller — and **objects allocated
-0.03 %** again. **So the entire `Step` monad is worth 0.03 % of this compiler's allocation and
costs 2.4 % of its wall.** Reverted on the measurement; **restored afterwards by explicit
instruction**, so the tree carries it. Why it lost is in §7.

### 10g (re-measure) — plain triple on the restored tree — **confirms the A/B**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| t1 | 233.60 | 1118 | 10 | 17482 | 10,416,580 | 13,224,281 | same |
| t2 | 235.45 | 1118 | 10 | 17482 | 10,415,772 | 13,224,281 | same |
| t3 | 237.66 | 1118 | 10 | 17482 | 10,415,856 | 13,224,281 | same |
| **median** | **235.45** | **1118** | **10** | **17482** | **10,415,856** | 13,224,281 | same |
| **average** | **235.57** | — | — | — | — | — | — |

Three cold runs of `eco-opt10fg-b` on the restored `try-10g2` tree, taken after the 10f+10g
change was put back. Spread 4.06 s = 1.72 %, inside the band. **Every deterministic counter is
identical to the A/B's candidate arm and identical across all three runs** — 1118 / 10 / 17,482
MiB — which is the check that the restored tree is the measured tree. All three outputs agree
byte-for-byte AND reproduce `eco10fg-b.mlir` exactly, so **the fixed point holds (B == C)**, the
gate a NOT-BI codegen change owes. The absolute wall is NOT comparable with rows above it: the
nearest in-time measurement of the reference `eco-opt10ei` is 232.29 / 232.47 from the same
night, about +3 s below this, which agrees in sign with the six-pair +5.63 s and is the only
comparison this triple licenses. Gates other than the fixed point are still owed.

### 16a (re-measure) — inert-callee instantiation skip (D1) + trivial-signature load (D8) — **WIN, kept**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| t1 | 233.75 | 1112 | 10 | 17404 | 10,384,340 | 13,225,156 | same |
| t2 | 237.27 | 1112 | 10 | 17404 | 10,384,456 | 13,225,156 | same |
| t3 | 238.52 | 1112 | 10 | 17404 | 10,387,632 | 13,225,156 | same |
| **median** | **237.27** | **1112** | **10** | **17404** | **10,384,340** | 13,225,156 | same |
| **average** | **236.51** | — | — | — | — | — | — |
| D vs step 10 | **+1.82** | **-6** | 0 | **-78** | **-31,516** | +875 | — |

Re-applied on the step-10 tree; the original was written against `keep-22a`, which step 10 then
rewrote into direct state-passing, so the logic transferred rather than the patch.
`instantiateWithSig` splits out so a caller holding the signature does not fetch it twice, and a
TRIVIAL signature takes `loadTypeIsolated` — the arrow-ordinal `Array` exists only to be indexed
by facts, and a trivial signature has none. `calleeInert` skips the whole isolated instantiation
when the signature is trivial and the call type and every argument type are arrow-free. Wall rose
1.82 s on a 4.77 s spread, so flat by this instrument, while all three deterministic counters
improved — the reverse of the original run, where they had all moved the wrong way. **Kept by
explicit decision**: wall is within noise and the counters carry it. Fixed point holds, three runs
byte-identical.

### 12s (re-measure, with `Eco.Hash`) — `lssSignatures`/`lssInProgress` keyed by `Global` — **WIN, kept**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| t1 | 234.76 | 1113 | 10 | 17600 | 10,398,400 | 13,241,282 | same |
| t2 | 233.10 | 1113 | 10 | 17600 | 10,398,704 | 13,241,282 | same |
| t3 | 239.60 | 1113 | 10 | 17600 | 10,404,604 | 13,241,282 | same |
| **median** | **234.76** | **1113** | **10** | **17600** | **10,398,400** | 13,241,282 | same |
| **average** | **235.82** | — | — | — | — | — | — |
| D vs 16a | **-2.51** | +1 | 0 | +196 | +14,060 | +16,126 | — |

**This row bundles two changes**, because the second was built to make the first viable. `Eco.Hash`
is a new kernel module: an allocation-free native string hash, gc-leaf, replacing an Elm
`String.foldl` that snapshotted the string into a C++ vector and then performed one GENERIC
CLOSURE DISPATCH per character with the accumulator boxed each time. That is why 12s lost the
first time, and why entries 27 and 24(iii)+(iv) lost the same way. 12s itself then keys
`lssSignatures`/`lssInProgress` on the `Global` instead of a built 25-50 character string.
Wall -2.51 s by median (-0.69 by mean) against a 6.50 s spread; minor GC flat, promoted +196 MiB
and RSS +14 MB — a wider hash makes more distinct `Dict Int` bucket keys, so the bucket tree
retains more. Wall is primary: WIN. Fixed point holds, three runs byte-identical.

### ghash — `aliasKeyOf` and `groundHash` onto the native hash — **WIN, kept**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| t1 | 231.43 | 1113 | 10 | 17633 | 10,526,024 | 13,241,185 | same |
| t2 | 234.40 | 1113 | 10 | 17633 | 10,506,944 | 13,241,185 | same |
| t3 | 235.17 | 1113 | 10 | 17633 | 10,506,704 | 13,241,185 | same |
| **median** | **234.40** | **1113** | **10** | **17633** | **10,506,704** | 13,241,185 | same |
| **average** | **233.67** | — | — | — | — | — | — |
| D vs 12s | **-0.36** (mean **-2.15**) | 0 | 0 | +33 | +108,304 | -97 | — |

The last two string-hash sites. `Store.aliasKeyOf`'s `String.foldl` becomes `Eco.Hash.string` —
VALUE-FOR-VALUE identical, since Store's local `mix` is the kernel's narrow mix at the same seed
23, so only the cost moves. `Store.groundHash` now hashes the CHARACTERS of names at its four
name sites (the `TType` module and type names, record field keys, the `TAlias Holey` pair); it
hashed `String.length` ONLY, so `Dict`/`Set` and `Task`/`Time` collided, as did every same-length
field key. That was a deliberate economy when hashing cost a closure per character, and the
kernel removes the reason for it. **The narrow variant is mandatory here**: `groundHash` returns
`-1` for "free var, arrow or open record" and four sites test `h < 0`, so a `string64` that can
go negative would silently read as ineligible. Wall -0.36 s by median and -2.15 s by mean; RSS
+108 MB is the better-distributed hash making more distinct `Dict Int` bucket keys to retain.

### ghash63 — 63-bit `mix` and name hashes in `groundHash` — **LOSS, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|
| t1 | 238.61 | 1113 | 10 | 17633 | 10,394,976 | 13,241,285 | same |
| t2 | 239.13 | 1113 | 10 | 17633 | 10,394,928 | 13,241,285 | same |
| t3 | 239.69 | 1113 | 10 | 17633 | 10,395,056 | 13,241,285 | same |
| **median** | **239.13** | **1113** | **10** | **17633** | **10,394,976** | 13,241,285 | same |
| **average** | **239.14** | — | — | — | — | — | — |
| D vs ghash | **+4.73** (mean **+5.47**) | 0 | 0 | 0 | -111,728 | +100 | — |

`Store.mix` became `Eco.Hash.mix63` (FNV-1a plus an xor-shift, masked to 63 bits so the `-1`
sentinel survives) and the four name sites took `string63`. The premise was avalanche, not range:
at ~43,000 alias keys the birthday estimate in 2^26 is about fourteen collisions, so width could
never pay, but `h * 33 |> modBy 2^26` barely moves its low bits and `groundHash` nests it once
per node. **Spread 1.08 s, the tightest triple in the series — this is not noise.**
GC time 112.63 -> 116.45 s IS the whole regression; RSS actually improved 112 MB.

**The cause is the call, not the hash.** `mix` runs once per NODE — per list element, per record
field — so a gc-leaf kernel call replaced a single inline `modBy`. One call amortised over a
whole string is a 100x win (`string63`); one call replacing one arithmetic op is a loss. Same
shape as entries 14, 16a and 24(i): **the test, or the call, has to be cheaper than the work it
replaces.** The avalanche question is therefore still OPEN and this entry does not answer it —
a fair test needs `mix` inlined as an MLIR op, not called.

### gc-p1 — TLS shadow root stack: `eco_gc_push/point/restore` inlined at every call site — **NO WIN, reverted**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | GC time (s) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 233.30 | 1113 | 10 | 17633 | 10,523,820 | 112.98 | 13,241,185 | same |
| r2 | 237.62 | 1113 | 10 | 17633 | 10,523,748 | 114.62 | 13,241,185 | same |
| r3 | 235.60 | 1113 | 10 | 17633 | 10,525,404 | 114.17 | 13,241,185 | same |
| **median** | **235.60** | **1113** | **10** | **17633** | **10,523,820** | **114.17** | 13,241,185 | same |
| **average** | **235.51** | — | — | — | — | — | — | — |
| D vs ghash | **+1.20** (mean **+1.84**) | 0 | 0 | 0 | +17,116 | +1.54 | 0 | — |

| symbol (perf, reference binary, cold Stage 7a) | cycles self% | instr self% | plan's figure |
|---|---|---|---|
| `eco_gc_push_stack_range` | 1.32 | 1.83 | 14.53 |
| `eco_gc_restore_stack_range_point` | 0.09 | 0.19 | 1.28 |
| `eco_gc_stack_range_point` | 0.04 | 0.11 | 0.87 |
| **triplet** | **1.45** | **2.13** | **16.68** |

`plans/gc-root-registration-cost.md` Phase 1: `RootSet::stack_root_ranges` (a `std::vector` behind
`tl_heap_ -> nursery_ -> root_set` and an out-of-line call) became three initial-exec TLS cursors,
and `EcoBackend::expandRootRangeOps` rewrites the generated calls into inline `%fs`-relative
traffic. It did exactly what it was built to do — **11,738 push call sites became 3**, point
11,740 -> 2, restore 11,226 -> 4, binary -546 kB, E2E 1731/1731, GC counters identical TO THE
DIGIT and `out.mlir` byte-identical to `ecoghash.mlir` — and wall did not move. **The plan's
premise was already stale when it was written**: its 16.68 % came from `borrow-inf-census.md:157`,
measured before this series, and the same profile on the reference binary now reads **1.45 %** of
cycles, because steps 3/10/24 removed most of the closure-dispatch entries the triplet brackets.
Instructions 2.13 % vs cycles 1.45 % says the body is well-pipelined, not stall-bound, so there
was nothing for inlining to recover. Same shape as step 14 and `inline-bump-state-tls`: **a large
call count is not a large cost.** Reverted at the time — then RESTORED and folded into the `gc-all` row below, which measures
the whole plan as one unit, as the plan intends.

### gc-all — the whole `gc-root-registration-cost` plan, Phases 1-4 as one unit — **FLAT; WIN only on RSS**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | GC time (s) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 235.80 | 1113 | 10 | 17634 | 10,459,624 | 115.76 | 13,241,185 | same |
| r2 | 237.30 | 1113 | 10 | 17634 | 10,451,604 | 117.24 | 13,241,185 | same |
| r3 | 234.14 | 1113 | 10 | 17634 | 10,451,360 | 115.36 | 13,241,185 | same |
| **median** | **235.80** | **1113** | **10** | **17634** | **10,451,604** | **115.76** | 13,241,185 | same |
| **average** | **235.75** | — | — | — | — | — | — | — |
| D vs ghash | **+1.40** (mean **+2.08**) | 0 | 0 | +1 | **-55,100** | +3.13 | 0 | — |

| perf, cycles self% (cold Stage 7a) | before | after | delta |
|---|---|---|---|
| root-range triplet (`push`/`point`/`restore`) | 1.45 | **0.00** | **-1.45** |
| `eco_apply_closure_eval` | 2.12 | 0.86 | -1.26 |
| `invokeSaturatedTyped` | 1.45 | 0.86 | -0.59 |
| `spliceArgsForSaturatedCall` | 0.53 | 0.70 | +0.17 |
| `Elm::Allocator::resolve` | 5.16 | 5.81 | **+0.65** |
| `NurserySpace::evacuate` | 11.34 | 11.60 | +0.26 |

All four phases, measured together: TLS shadow root stack + single-slot stack (P1),
`EvaluatorDesc` indirection (P2), `$sat` entries + fast-path diamond (P3), dead `_dispatch_mode`
path deleted (P4). Gates: E2E **1731/1731**, three runs byte-deterministic, self-compile output
**byte-identical to `ecoghash.mlir`**. **The mechanisms all work**: the root-range triplet is gone
from the profile entirely, 8,001 diamonds compiled in, and the apply/splice family falls 4.10 % ->
2.42 %. **The costs cancel them.** Every slow dispatch now pays the guard, `Allocator::resolve`
rises 0.65 pts because the diamond must resolve the closure on BOTH edges (plan §5.3's "the
resolve is not extra" is false for the generic path, which otherwise hands the HPtr to the runtime
unresolved), and 31,351 `$sat` entries add **+15.5 MB** of text. ~3.1 pts of cycles were removed
from the named symbols and the wall did not move. RSS is the one real improvement: -55 MB, with
the two triples' ranges fully disjoint, so it is separation and not the usual RSS noise.

### gc-all2 — same plan, `$sat` population filtered by reachability + the newarg-count fix — **WIN, -4.85 s**

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | GC time (s) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 229.55 | 1108 | 10 | 17599 | 10,438,980 | 114.82 | 13,241,185 | same |
| r2 | 230.18 | 1108 | 10 | 17599 | 10,437,876 | 115.14 | 13,241,185 | same |
| r3 | 228.01 | 1108 | 10 | 17599 | 10,435,260 | 114.28 | 13,241,185 | same |
| **median** | **229.55** | **1108** | **10** | **17599** | **10,437,876** | **114.82** | 13,241,185 | same |
| **average** | **229.25** | — | — | — | — | — | — | — |
| D vs ghash | **-4.85** (mean **-4.42**) | **-5** | 0 | **-34** | **-68,828** | +2.19 | 0 | — |
| D vs gc-all | **-6.25** | -5 | 0 | -35 | -13,728 | -0.94 | 0 | — |

| | gc-all | gc-all2 |
|---|---|---|
| `$sat` entries | 31,351 | **25,316** |
| diamonds (fast edges compiled in) | 8,001 | **11,501** |
| binary | 90.01 MB | 88.18 MB |

Two changes over `gc-all`. **(1) A reachability filter on `$sat` generation.** The diamond's
`%c1` fixes the applied count at `P - N`, so `%c3`'s kind comparison is the STATICALLY KNOWN
`(D.kinds >> 2*(P-N)) & mask`; an entry is therefore reachable only from a site whose full
`(N, KC, RC)` signature matches exactly, and `n_values` starts at the smallest `num_captured`
the target is created with, bounding `N <= P - minC0`. **(2) The bug that filter exposed**:
`papExtend`'s operands are `[closure, newargs..., roots...]` and `getNewargs()` returns the tail
INCLUDING roots, so every site's N was inflated by its root count — no `n=1` sites at all and a
spurious peak at `n=5`. That is why `gc-all` compiled only 8,001 fast edges; the real
distribution is n=1:8,910, n=2:15,367. Coverage +44 %, entries -19 %. Gates: E2E 1731/1731,
byte-deterministic, output byte-identical. **The two triples' wall ranges are fully disjoint**
([228.01, 230.18] vs [231.43, 235.17]) and minor GC and promoted — exact per (binary x tree) —
both move down, so this is a real win, not spread.

### gcdef — GC defaults retuned from the parameter sweeps — **WIN, -30.09 s (-13.1 %)**

Runtime-only change (like steps 1 and 14): the candidate is `bin/ecoghash.mlir`, the SAME MLIR
`gc-all2` was lowered from, lowered again against the changed runtime. `bin/eco-optgcdef` is
88,176,312 B — byte-size identical to `bin/eco-opt-prev`, as it must be when only compiled-in
constants move. Patch `snapshots/lss-loop/step-gcdef.patch` (15 lines, 3 constants), tree
snapshot `try-gcdef`.

Three constants in `runtime/src/allocator/AllocatorCommon.hpp`:
`PROMOTION_AGE` 2 -> **1**, `NURSERY_MAX_BLOCKS` 1024 -> **512**,
`MAJOR_GC_INITIATING_OCCUPANCY` 0.85 -> **0.95**. Mirrored in
`compiler/cmake/bootstrap/build-kernel/heap-config.json` and `heap-profile.py:BASELINE_HEAP`
(all three kept in sync as a 41-field mirror of the struct).

| run | wall (s) | minor GC | major GC | promoted MiB | max RSS (kB) | GC time (s) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 199.46 | 1924 | 6 | 19861 | 10,816,544 | 86.66 | 13,241,185 | same |
| D vs gc-all2 | **-30.09** (-13.1 %) | +816 | **-4** | +2262 | +378,668 (+3.6 %) | **-28.16** (-24.5 %) | 0 | — |

**ONE run, not the protocol's three** (explicit instruction). The fixed-point check still ran and
passed (`cmp` vs `bin/ecoghash.mlir`); the cross-run determinism `cmp` could not. At -30.09 s the
delta is ~6x the +-5 s between-sitting drift band, and the three counters that carry no noise all
move: majors -4, minors +816, promoted +2262. Deviation from the literal §2 commands: the package
registry cache is `touch`ed first, suppressing the 134 s network call found on 2026-09-22 (see
`plans/gc-param-sweep/sensitivity-2026-09-22-results.md`); `gc-all2` at 229.55 s plainly did not pay it either, so
this keeps the arms comparable rather than introducing a difference.

**GC time accounts for the whole win**: -28.16 s of GC against -30.09 s of wall. Where it comes
from, per the sweeps (`plans/gc-param-sweep/`): `promotion_age=1` halves nursery survivor copying
(1.371 B -> 0.747 B copies) at the cost of +12.9 % promotion; `nursery_max_block_count=512` halves
the nursery ceiling to 256 MiB, which raises the minor count 73.6 % while LOWERING total minor
time — collection COUNT is nearly irrelevant, the same survivors get copied either way;
`major_gc_initiating_occupancy=0.95` takes majors 10 -> 6.

The three were measured individually (-17.7 / -17.6 / -11.8 s) and as pairs and triples; they
compose SUB-additively (singles sum -47.1 s, triple delivers -38.0 s on that binary). **They do
not compose without limit**: swapping in the better single `nursery_max_block_count=128` sends the
old gen to 15,078 MB and the wall to +31 s via swap, because it and `promotion_age` push the same
downstream quantity. Old-gen peak here is 9,928 MB, and RSS +3.6 % is the price of the win.


## 7. Findings

What the series learned, separated from the per-step records above so the entries can stay
to ten lines. Every claim here is traceable to a numbered entry in §6.

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

### Why step 10 lost, and what `$sret` is actually for

`$sret` works and the selection widened exactly as designed — 42 to 148 MonoSolver workers, 528
to 635 overall. What the series had wrong was WHERE it pays.

- **10e-i promoted the hot LEAVES and won 8.34 s.** `Store.zonkToMono` and the classify family are
  11.8 % of the mono window; they are called millions of times, do little work per call, and their
  result tuple was a real per-call allocation.
- **10g promoted the cold SPINES and lost 6 s.** `translateLet`, `specializeDecider`,
  `specializePath` and 52 others are called once per syntax node and each does substantial work;
  the tuple they returned was noise against that. What they gained instead was the promotion's own
  overhead — a worker PLUS a shim per promoted spec, paid at every call site
  `Expr.trySretLetBinding` does not migrate (it migrates LET-BOUND direct calls only).

Same mechanism, opposite sign; the discriminator is the ratio of per-call overhead to per-call
work. **`$sret` is a leaf optimization, and applied as a blanket policy it is negative.**

Two further things are on record for anyone who reopens this.

1. **The half-converted state is the worst state** (entry 10e-ii, +3.20 s). The conversion is
   monotone only at its endpoints — `Step` everywhere (13 adapters) and `Step` nowhere (0) are
   both cheap, and every point between pays `lift`/`liftU`/`afterU` closures at the boundary.
   Convert a whole call graph in one step or not at all.
2. **`Backend.sretFreshGreatest` is written, correct, and inert on this tree.** The promotion
   fixpoint was a LEAST fixpoint over an already-admitted table, so a group of functions whose
   result leaves are calls to EACH OTHER can never bootstrap — the normal shape of a recursive
   descent. The replacement computes the GREATEST fixpoint of the same rule: assume every
   shape-eligible spec promoted, then drop any whose body fails against the current table.
   Removal only shrinks, so it terminates; it returns `Nothing` if the cascade does not settle in
   30 rounds, because a half-settled table is a MISCOMPILE, and the caller falls back to the least
   fixpoint. It moved 600 to 601 workers on its own, and on the converted source the least
   fixpoint finds the same 148 — once the chains are gone the leaves are literals and the
   bootstrap problem it solves no longer exists. Reach for it only if the source returns to
   combinator style.

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


## 8. Provenance

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


## 9. Summary

One row per step, numbers only, in the order the entries were run.

**The method this column records.** Build the candidate compiler with the optimization in it, have
that compiler self-build, and keep the wall time of the OPTIMIZED run only. Three cold runs;
`wall (s)` is their median. `ref` names the row it is judged against — the previous WIN, or `base`
before the first win — and `delta (s)` is this row's `wall` minus that row's `wall`. Negative is
an improvement. A reverted row never becomes the reference, so the next row skips it and is judged
against the same win as this one was.

**Two health warnings on `delta (s)`, both measured on this machine.**

1. **The wall column carries machine drift, and the drift is large.** The unchanged binary
   `eco-opt10ei`, on the unchanged workload, measured 257.25 s at 02:43 on 2026-09-21 and
   232.47 s at 05:22 — **26.84 s, 10.4 %, in one session with nothing changed**. Rows whose
   reference was measured in a different sitting carry that difference inside their delta. The
   step-10 rows at the bottom are the worst affected: they were run in a fast session, so their
   deltas against `10e-i` (measured hours earlier and slower) read as large improvements.
2. **Seven rows have a delta whose SIGN disagrees with their recorded verdict.** Deltas say
   improvement where the verdict says loss at `8a` (-0.14), `16a` (-2.00) and `12s` (-2.43);
   deltas say regression where the verdict says win at `7` (+2.23), `9` (+1.94), `22a` (+0.59),
   `24(i')` (+0.40), `24(ii)` (+0.16) and `25` (+0.39). The four small regressions kept as wins
   were kept because other stats improved — in every case a lower minor-GC count, which is exact
   per (binary x tree) where wall is not. The three small improvements not kept are the ones
   worth a second look; see the note under step 10 below.

**Step 10 is one row.** It was implemented and measured in seven stages (`10a`, `10b`, `10c`,
`10e-i`, `10e-ii`, `10f`, `10g`), but it is a single optimization — retire the `Step` monad and
let `$sret` return `( a, S )` in registers — and only the final state ships. The row is that
final state measured against step 25, the last win before it: 237.17 s vs 265.28 s. The stages
are recorded individually in §6 for anyone repeating the work, and §7 explains which parts of the
mechanism paid and which did not.

`out.mlir` is not a column here: byte-identity is a GATE, checked per entry, not a statistic.

| step | wall (s) | delta (s) | minor GC | major GC | promoted MiB | max RSS (kB) | verdict | ref |
|---|---|---|---|---|---|---|---|---|
| base | 398.71 | — | 1825 | 10 | 20846 | 12708052 | reference | — |
| 1 | 370.18 | -28.53 | 1825 | 10 | 20846 | 12705760 | WIN | base |
| 2 | 359.47 | -10.71 | 1821 | 10 | 20836 | 12690812 | WIN | 1 |
| 3 | 340.70 | -18.77 | 1583 | 10 | 20376 | 12457544 | WIN | 2 |
| 4b | 334.85 | -5.85 | 1600 | 10 | 20863 | 12711764 | WIN | 3 |
| 4a | 291.93 | -42.92 | 1312 | 10 | 20354 | 12026400 | WIN | 4b |
| 5a | 289.43 | -2.50 | 1287 | 10 | 20341 | 12048496 | WIN | 4a |
| 6 | 286.85 | -2.58 | 1281 | 10 | 20201 | 12052184 | WIN | 5a |
| 7 | 289.08 | +2.23 | 1280 | 10 | 20183 | 12044660 | WIN | 6 |
| 8a | 288.94 | -0.14 | 1291 | 10 | 20233 | 12118144 | LOSS (reverted) | 7 |
| 8b | 287.24 | -1.84 | 1273 | 10 | 20207 | 12105460 | WIN | 7 |
| 9 | 289.18 | +1.94 | 1252 | 10 | 20269 | 12095116 | WIN | 8b |
| 11b | 278.11 | -11.07 | 1243 | 10 | 20284 | 12058368 | WIN | 9 |
| 11a | 277.42 | -0.69 | 1238 | 10 | 20301 | 12073940 | WIN | 11b |
| 14 | ~279.4 | ~+1.98 | 1238 | 10 | 20301 | 12073960 | LOSS (reverted) | 11a |
| 19' | 281.54 | +4.12 | 1239 | 10 | 20316 | 12134468 | LOSS (reverted) | 11a |
| 22a | 278.01 | +0.59 | 1237 | 10 | 20293 | 12075144 | WIN | 11a |
| 16a | 276.01 | -2.00 | 1252 | 10 | 20317 | 12083308 | LOSS (reverted) | 22a |
| 24(i) | 282.38 | +4.37 | 1250 | 10 | 20239 | 12028904 | LOSS (reverted) | 22a |
| 12s | 275.58 | -2.43 | 1256 | 10 | 20292 | 12046092 | LOSS (reverted) | 22a |
| 27 | 311.63 | +33.62 | 1310 | 11 | 20825 | 12048200 | LOSS (reverted) | 22a |
| 20 | ~279.0 | ~+0.99 | 1237 | 10 | 20293 | 12107848 | NO WIN (reverted) | 22a |
| 13s | ~285.3 | ~+7.29 | 1262 | 11 | 20325 | 11988428 | LOSS (reverted) | 22a |
| 23 | 280.87 | +2.86 | 1237 | 10 | 20255 | 12109264 | NO WIN (reverted) | 22a |
| 17 | 279.02 | +1.01 | 1262 | 10 | 20284 | 12090480 | LOSS (reverted) | 22a |
| 16-D4 | ~281.6 | ~+3.59 | 1238 | 10 | 20387 | 12120732 | NO WIN (reverted) | 22a |
| 15 | 280.81 | +2.80 | 1238 | 10 | 20318 | 12022700 | LOSS (reverted) | 22a |
| 18b | 275.76 | -2.25 | 1237 | 10 | 20293 | 12126548 | WIN (kept) | 22a |
| 18a | 281.54 | +5.78 | 1259 | 10 | 20293 | 12130068 | LOSS (reverted) | 18b |
| 22b | 278.43 | +2.67 | 1237 | 10 | 20335 | 11916868 | WIN on counters (kept) | 18b |
| 22d | 270.19 | -8.24 | 1250 | 10 | 20004 | 10686984 | WIN (kept) | 22b |
| 22c | 274.37 | +4.18 | 1250 | 10 | 20000 | 11594052 | LOSS (reverted) | 22d |
| 24(iii)+(iv) | 276.42 | +6.23 | 1248 | 10 | 19929 | 11513336 | LOSS (reverted) | 22d |
| 24(i') | 270.59 | +0.40 | 1246 | 10 | 19962 | 11541556 | WIN (kept) | 22d |
| 21a | 275.46 | +4.87 | 1247 | 10 | 19966 | 11583856 | LOSS (reverted) | 24(i') |
| 24(vii)a | 264.73 | -5.86 | 1243 | 10 | 19972 | 11562648 | WIN (kept) | 24(i') |
| 24(vii)b | 271.70 | +6.97 | 1243 | 10 | 19961 | 11563724 | NO WIN (reverted) | 24(vii)a |
| 24(ii) | 264.89 | +0.16 | 1241 | 10 | 19977 | 11529796 | WIN (kept) | 24(vii)a |
| 5b | 266.64 | +1.75 | 1214 | 10 | 20009 | 11486464 | LOSS (reverted) | 24(ii) |
| 16(D10) | 272.88 | +7.99 | 1241 | 10 | 20079 | 11528320 | NO WIN (reverted) | 24(ii) |
| 24(v) | 272.09 | +7.20 | 1242 | 10 | 20061 | 11770580 | NO WIN (reverted) | 24(ii) |
| 25 | 265.28 | +0.39 | 1241 | 10 | 19982 | 11479276 | WIN (kept) | 24(ii) |
| 26a | 271.61 | +6.33 | 1248 | 10 | 19951 | 11529312 | LOSS (reverted) | 25 |
| 10 | 237.17 | -28.11 | 1118 | 10 | 17482 | 10415980 | WIN (kept) | 25 |
| 16a (re-measure) | 237.27 | +1.82 | 1112 | 10 | 17404 | 10384340 | WIN (kept) | 10 |
| 12s (re-measure, + Eco.Hash) | 234.76 | -2.51 | 1113 | 10 | 17600 | 10398400 | WIN (kept) | 16a (re-measure) |
| ghash (aliasKeyOf + groundHash) | 234.40 | -0.36 | 1113 | 10 | 17633 | 10506704 | WIN (kept) | 12s (re-measure) |
| ghash63 (63-bit mix + names) | 239.13 | +4.73 | 1113 | 10 | 17633 | 10394976 | LOSS (reverted) | ghash |
| gc-p1 (TLS shadow root stack) | 235.60 | +1.20 | 1113 | 10 | 17633 | 10523820 | NO WIN (folded into gc-all) | ghash |
| gc-all (Phases 1-4 as one unit) | 235.80 | +1.40 | 1113 | 10 | 17634 | 10451604 | FLAT, RSS-only WIN | ghash |
| gc-all2 (+ $sat reachability filter, newarg fix) | 229.55 | -4.85 | 1108 | 10 | 17599 | 10437876 | WIN | ghash |
| gcdef (GC defaults: age 1, nmbc 512, mio 0.95) | 199.46 | -30.09 | 1924 | 6 | 19861 | 10816544 | WIN | gc-all2 |

**THIS SERIES IS CLOSED AT `gcdef`. It continues in `benchmarks/gc-opt-loop.md`**, which uses
this file's method unchanged and carries this table forward whole, appending its own rows. The
live summary table — and therefore the current reference row for any new step — is that file's
§9, not the one above. Do not append here.

