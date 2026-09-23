# GC optimization loop — experiment protocol

This loop implements garbage-collector and heap-layout changes one at a time and measures each one
the only way that matters for compile time: **the compiler containing the change builds itself, and
that self-build is what we time.**

The step list is `plans/gc-tier1-constant-factors.md` (§0 below). This file is the direct
continuation of `benchmarks/lss-compile-opt-loop.md`, which closed at row `gcdef` (199.46 s).
**The method below is that loop's, unchanged except where noted; §9's summary table is its table,
carried over whole, and new GC rows are appended to it.** The parent file keeps the
per-step entries and findings of the LSS series — they are not repeated here.

Everything here is native. Never measure on the JS build. No census of any kind runs inside a timed
leg.

## 0. The steps

The step list is `plans/gc-tier1-constant-factors.md` — its "Work packages, in landing order"
table, in that order. **One package per iteration**, named by its `W` number; a package the plan
itself sub-numbers (`W1.1`, `W1.2`, `W1.3`, `W4(29,31)` vs `W4(32)`, `W5(53)`) splits into one
entry per sub-number, because §5's one-step-per-iteration rule applies to items, not to the
plan's grouping.

| step | package | items | basis | risk |
|---|---|---|---|---|
| base | *(no change — the `gcdef` tree; INHERITED, not re-measured)* | — | — | — |
| W0 | Free deletions | 11,12,13,27,39,48,49,50 | bound | trivial |
| W1 | Nursery zeroing | 6,7,8,9 | **5.6 % CPU, measured** | medium |
| W2 | `evacuate` inner loop | 16–23 | bound | low |
| W3 | Per-object dispatch | 24–28 | bound | low |
| W4 | Slot scanning | 29–31 (**32 gated**) | bound | medium |
| W5 | Minor-GC structure | 33,34,35,37,53,55 (**36 closed**) | bound | low |
| W6 | Old-gen virgin-page bump | 10, 15 (counter first) | bound | medium |
| W7 | Promotion-path sweep coupling | 14 | measured outlier | medium |
| W8 | Mark-side data structures | 38,40,51,52,54 | bound | medium |
| W9 | Old-gen bookkeeping | 41–47 | bound | low |
| W10 | Stackmap lookup | 56 | bound | low |

W0 first because it is free; W1 next because it is the only package with a measured cost. W8 is
also the prerequisite for parallel marking (working-list #57–#63), so it has value beyond its own
delta. **Only W1 is backed by a measurement — every other package is a bound**, so expect flat
results and read the disposition rule in §4 before calling one a loss.

**Order is constrained, not free** (the plan's Sequencing section):

```
W0 ───────────────────────────────────────────────►  (free, land immediately)
W1.3 (investigate) ─► W1.1 ─► W1.2                   (W1.3 may make W1.2 unnecessary — run it first)
W2 ─► W3 ─► W4(29,31) ─┬─► W4(32)
                       └─► W5(53)                    (53 needs 29's boxed mask)
W5(33,34,35,37,55)                                   (independent)
W6(10) ─► W6(15 counter) ─► W7                       (old-gen allocation policy)
W8(40) ─► W8(38,51,52) ─► W8(54)                     (40 gates the rest)
W9, W10                                              (independent)
```

Four cross-package dependencies must hold: **53 → 29** (prefetching walks the mask 29 builds),
**54 → 40** (prefetching a `vector<vector<uint8_t>>` chases a pointer per probe), **32 ↔ 46**
(both want bits out of `Header.refcount` — one `constexpr` field split, agreed once), and
**15 → 10**.

**Most steps in this series change the runtime (C++), not the compiler source.** Those still go
through the same loop — **the candidate is the same compiler MLIR lowered against the changed
runtime** — so Phase 1.3 is skipped and Phase 1.4 lowers the reference MLIR again. A candidate
differing from its reference only in compiled-in constants should come out BYTE-SIZE IDENTICAL; if
it does not, something other than the step moved.

Exploration of heap PARAMETERS (as opposed to collector code) belongs in `heap-profile.py`
(`plans/gc-param-sweep/`), not here: that harness sweeps `ECO_HEAP_CONFIG` variants cheaply and
without the bootstrap. This loop scores a change once it is committed to the compiled-in defaults.

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
`bin/eco-opt-prev` = the last kept compiler (for this series it starts at `bin/eco-optgcdef`,
the `gcdef` row), `N` = the step number.

**Phase 0 — series baseline. DONE 2026-09-22.** This series INHERITS its baseline: the `gcdef` row
of §9 is the reference for step 1, so no new baseline triple was measured. Its Phase 4 gates ran on
promotion — E2E `--target check` **1731/1731 PASSED**; the unit suite is 13,565 pass / 12 fail, all
pre-existing (`elm-test-rs` runs the front end compiled by stock Elm to JS, which never links the
runtime, so a heap-constant change cannot reach it). Reference snapshot is **`keep-gcdef`** and
`bin/eco-opt-prev` = `bin/eco-optgcdef`. (For an independent series you would measure
`bin/eco-opt-prev` building the unchanged tree, three cold runs (Phase 2's commands with
`ARM=eco-opt-prev`). This is the reference row until the first win replaces it. It is NOT re-run
per step — the reference for step N is the recorded triple of the last win. The one repeat, after
the final step, is a drift check on the series (the last kept compiler measured again; if it
disagrees with its own recorded triple by more than the noise band, the machine drifted and the
deltas of the intervening steps are suspect).

**Phase 1 — implement and build the candidate (untimed).**
0. `lss-loop-snap.sh verify <ref>` — the live tree must be byte-identical to the reference snapshot
   before a single line is changed (catches a botched revert or an edit left over from elsewhere).
1. Implement step N in the source tree (usually `runtime/src/allocator/...` in this series;
   `compiler/src/...` when a step changes what is emitted).
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
> difference, not on the difference of two medians measured hours apart. The parent loop's §7
records why: the wall
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
not). For THIS series the plan sets the gate list per package: `--target check` suffices for the
C++-only packages (W0–W10 are all C++-only, and none changes `.mlir`), so `--target full` is not
required — the CLAUDE.md carve-out `inline-bump-state-tls.md:120` relied on. E2E must be green
flag-on and flag-off, and a **heap-validate build is mandatory for W1, W4 item 32, W6 and W8**.

All green ⇒ `lss-loop-snap.sh snap keep-N "step N kept: <short name>"`, copy `bin/eco-optN` and
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
REG=~/.eco/0.1.1/packages/registry.dat           # see the touch below

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
  touch "$REG"                                     # MANDATORY: see the note below
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

**`touch $REG` before every run.** Deleting `eco-stuff` forces dependency re-verification, which
calls `Registry.update`; under the `Normal` policy that hits the network unless `registry.dat` was
modified in the last 30 minutes (`compiler/src/Builder/Deps/Registry.elm:208`). Measured
2026-09-22, that POST took **134 s and then FAILED** — and a failed update neither writes nor
touches the file, so the TTL never resets by itself and every later run re-pays it. It lands inside
the measured wall and is charged to mutator time. The touch suppresses only the registry REFRESH;
the cached registry and the packages are untouched. `heap-profile.py` does the same in
`_freeze_registry_ttl()`.

The GC banner is on stdout with the progress bars, so `grep -a`. The `ECO_MONO_ENGINE` /
`ECO_MONO_LSS` values are also the compiled defaults; they are set explicitly so a row can never
silently run another engine. `ECO_BORROW` and `ECO_AGG_PROMOTE` from the payoff track's build line
are NOT set: `aggPromote` is default-on already and `ECO_BORROW=1` is inert (payoff Run A), and
Phase 1.3 and Phase 2 must run under the SAME environment or the fixed-point `cmp` is meaningless.

## 3. Metrics and records

**Per-step entry** (appended under §6 below, newest last), the table FIRST, then at most ten
lines of prose — what changed, the verdict, and the one-line reason if it is not obvious:

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | | | | | | | | same / DIFF |
| r2 | | | | | | | | |
| r3 | | | | | | | | |
| **median** | | | | | | | | |
| Δ vs reference (last win / baseline), medians | | | | | | | | |

**Summary table** (§9, bottom of the file): one row per step, numbers only — the MEDIANS of the
three runs: `step | wall (s) | delta (s) | minor GC | major GC | promoted MiB | max RSS (kB) | verdict | ref`
— the shape already in use, continued from the inherited rows.
`ref` names the row the verdict was judged against (`base` or the step number of the last win),
so a reverted row is visibly skipped by the row after it. No commentary in the table; the argument
lives in the entry.

**GC time is the primary stat in THIS series** — it was a footnote in the parent loop. It is what
every step here tries to move, and unlike wall it is not drift-dominated; quote it in the table and
lead the entry with it. Old-gen in-use peak belongs in the prose of any step touching nursery
sizing or promotion: a config can buy wall with memory it does not have (2026-09-22,
`nursery_max_block_count=128` under `promotion_age=1` took the old gen to 15,078 MB on a 15 GB box
and paid 40 s in a single major GC to swap).

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

**Amendment for this series, from `plans/gc-tier1-constant-factors.md` (Disposition rule).** Only
W1 has a measured basis; the rest are bounds, so several packages will be flat. **A flat-but-correct
package that deletes work still SHIPS** — the precedent is `inline-bump-state-tls`, `stringLengthOp`
(−0.12 %) and `appendSplit` (+0.80 %), all default-on. It is recorded as **flat**, not as a win, and
its wall number still goes in the entry. This overrides the plain reading of the third rule above:
a flat wall is not a loss here. A wall REGRESSION outside the noise band is still a loss.

**Counter identity is a GATE in this series, not a stat.** The plan requires the self-compile output
byte-identical AND the GC counters (minor count, major count, objects promoted, promoted MB)
IDENTICAL to the reference — they are deterministic per binary × tree (n=6, `benchmarks/lss-opt.md`
Run R), so any movement is a behaviour change and must be explained before the package lands.
**W1, W6 and W7 are the exceptions**: they deliberately change allocation or sweep timing, so record
their new counters and justify them in the entry.

**Read GC TIME, not the minor-cycle count, when the two disagree** (inherited; learned at step
`5b` of `benchmarks/lss-compile-opt-loop.md`). The rule
above is unchanged and stays wall-first, but the interpretation of the counters is not what it
looked like for the first thirty entries. Minor GC *count* measures allocation VOLUME; minor GC
*cost* is paid for SURVIVORS — an object that dies before the next collection is never traced,
never copied, and costs nothing. That step deleted 10^6-scale short-lived closures, drove the cycle
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
- **Never set `ECO_HEAP_CONFIG` in a timed run.** Here a heap parameter IS often the step — so
  change the COMPILED-IN default in `runtime/src/allocator/AllocatorCommon.hpp` and rebuild, as the
  shipped config does, mirroring it into `compiler/cmake/bootstrap/build-kernel/heap-config.json`
  and `heap-profile.py:BASELINE_HEAP`. An env override measures a different binary from the one
  being scored. Use `heap-profile.py` with `ECO_HEAP_CONFIG` to EXPLORE, and this loop to score.
- **`rc == 0` is not proof a run completed.** The runtime's fatal-signal handler prints the whole
  GC-statistics banner and the process still exits 0, so wall, counters and the parsed banner all
  look healthy on a crashed run. Check that the output artifact exists and matches, and grep stderr
  for `[gc-stats] SIG`. A crashed run is FAST, so this failure mode flatters exactly the rows most
  likely to be believed (2026-09-22, `alloc_buffer_size=128K` read as a 26 % win).
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

(One entry per step, newest last. Each is: the results table, then at most ten lines — what changed,
the verdict, and the one-line reason if it is not obvious. Entries from the LSS series live in
`benchmarks/lss-compile-opt-loop.md` §6 and are not duplicated here.)

### W0 — free deletions (items 13, 27, 39, 48, 49, 50) — **FLAT, kept**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 199.32 | 84.99 | 1924 | 6 | 19861 | 10,816,924 | 13,241,185 | same |
| r2 | 198.43 | 85.01 | 1924 | 6 | 19861 | 10,818,328 | 13,241,185 | same |
| r3 | 198.30 | 84.10 | 1924 | 6 | 19861 | 10,817,408 | 13,241,185 | same |
| **median** | **198.43** | **84.99** | **1924** | **6** | **19861** | **10,817,408** | 13,241,185 | same |
| Δ vs `gcdef` | **-1.03** | -1.67 | **0** | **0** | **0** | +864 | 0 | — |

Dead `Marking` branch in `OldGenSpace::allocate` deleted (13); `hdr->size` reused in
`getObjectSize`'s `Tag_Array` case (27); `collectRoots()` returns `const&` instead of copying the
root set per major GC (39); two `getenv` magic statics folded into one namespace-scope
`g_oldgen_debug` (48); Floyd cycle detection moved behind `ECO_HEAP_VALIDATE` (49); early return
when `nursery_owned_bodies_` is empty (50). Patch `snapshots/lss-loop/step-W0.patch`, 69 lines.
Binary 88,176,312 -> **88,153,008 B** (-23,304). Gates: E2E `--target check` **1731/1731**;
determinism and fixed point both `cmp`-clean; no `[gc-stats] SIG` in any leg.

**FLAT, not a win: -1.03 s is inside the 5.3 s band.** Kept under §4's disposition rule (correct,
deletes work). The -1.67 s GC time is NOT claimed — the reference is a single run, so it cannot be
separated from drift. **The result that matters is gate 4: minor, major and promoted are
BIT-IDENTICAL to the reference across all three legs**, which is what six behaviour-preserving
deletions have to prove. Triple spread 1.02 s (0.51 %).

**Items 11/12 were NOT implemented — already done.** The timer bracket already reads
`const bool timed = !g_in_minor_gc;`, excluding the promotion path the plan costs at 357M-475M
calls; its own comment records that removal. What is left is mutator-context old-gen allocation,
which `gcdef` measured at **213.80 ms total**, so the plan's `ENABLE_GC_ALLOC_TIMING` macro would
chase ~0.1 % of wall while blinding `heap-profile.py`'s `helper_*` columns and the accounting
identity. Declined with that measurement; the plan's §W0 text for 11/12 is stale.

**One deviation:** item 13's `case GCPhase::Marking:` in `freeLargeBodyCell`'s switch is KEPT. It is
a jump-table entry costing nothing per call, while deleting it would forfeit the compiler's
exhaustiveness check and silently flip `need_sentinel` from true to false if that state ever arose.
The hot half of item 13 — the per-allocation branch — is gone.

**Cross-check worth recording:** item 13's premise is that the branch never runs. The 2026-09-22
sensitivity sweep independently sat `mark_work_ratio` at 1 / 2 / 4 and got bit-identical GC counters
every time, which is only possible if it never executes. `mark_work_ratio` now has no reader at all
and is documented as inert in `AllocatorCommon.hpp`.

### W1.1 — item 6, high-water nursery clear — **LOSS (reverted), gate failure**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 198.65 | 85.37 | 1924 | 6 | 19861 | 10,810,052 | 13,241,185 | same |
| r2 | 194.94 | 84.45 | 1924 | 6 | 19861 | 10,810,956 | 13,241,185 | same |
| r3 | 199.23 | 86.61 | 1924 | 6 | 19861 | 10,811,008 | 13,241,185 | same |
| **median** | **198.65** | **85.37** | 1924 | 6 | 19861 | **10,810,956** | 13,241,185 | same |
| Δ vs `W0` | +0.22 | +0.38 | 0 | 0 | 0 | **-6,452** | 0 | — |

Per-extent high-water WATERMARKS — plain pointers recording the highest address ever WRITTEN in an
extent; nothing to do with mark bits, `markOneObject` or `gc_phase_ == Marking`, which are old-gen
tracing and are untouched here. Keyed on the physical low/high extent so the semi-space flip needs
no swap), so `clearToSpaceFreeRegion` stops at the watermark instead of the capacity end, with the full
clear kept under `ECO_HEAP_VALIDATE` as a differential check. Timed result was FLAT on wall with a
small but REAL RSS win — all three legs below all three `W0` legs, disjoint ranges, the mechanism
item 6 predicts (pages above the mark never fault in). Triple spread 4.29 s (2.2 %), a noisier
sitting than W0's 1.02 s.

**It fails the heap-validate gate, which is MANDATORY for W1, so it cannot be kept.** The
differential check fired twice:
`[heap-validate] high-water skip is NOT zero at 0x10580000011 (offset 1 past watermark
0x10580000010, extent [0x10580000000,0x10580020000))`, and 2 of 1731 E2E tests failed with it.

**Two placements were tried and both failed.** First the watermark was assigned in
`clearToSpaceFreeRegion`; that is wrong because it runs BEFORE evacuation copies survivors
(`:536`, "after checkAndGrow so newly added blocks are also zeroed"), so `copy_ptr_` there is
to-space's START and evacuation writes straight over the range just declared clean — a byte at
`hw+1` with `hw+0` zero is an object header starting exactly at the watermark, which is what the
dump shows.
Moving the assignment to the final `copy_ptr_` just before the flip — i.e. after evacuation has
finished writing survivors — fixed that ordering and **the check
still fired twice, identically**.

**Conclusion: the premise is not safe as the plan states it.** "The region beyond the previous
high-water mark is already zero" requires a complete model of every writer into to-space, and the
plan enumerates only the mutator bump pointer. There is at least one other writer (the evacuation
copiers — plain, JIT-root and list-spine — and the nursery-owned split-header bodies are the
candidates, unverified). Reverted to `keep-W0`. Anyone retrying this must first enumerate the
to-space writers; the differential check is the right tool and is cheap, so reinstate it first.

### W1.3 — item 9, root-cause investigation — **PARTIAL: static half done, dynamic half inconclusive**

**The static narrowing paid for itself and corrected the plan three times.** Verified against
`scanObject`:

| plan says | actually |
|---|---|
| `FieldGroup` scans `hdr->size`, **exposed** | **NOT exposed** — `NurserySpace.cpp:1630`, "no pointers to scan (field IDs only)" |
| *(absent from the table)* | **`Task` IS exposed** — four fixed slots, no fill counter |
| *(absent from the table)* | **`Process` IS exposed** — three fixed slots |

The load-bearing exclusion holds: `Array` iterates `arr->length`, never capacity, in both the
boxed walk and the validate tripwire, so its uninitialised tail is genuinely unreachable.

**The dynamic half is INCONCLUSIVE and must not be read as a green light.** Poison fill
(`ECO_NURSERY_POISON=1` under `ECO_HEAP_VALIDATE`) plus tripwires in `evacuate` and on the offset-8
kind bitmap reported **zero hits** over the E2E suite — but **no positive control was established**
that the poison was actually reaching allocated payloads, so "nothing traces an unwritten slot" and
"the instrumentation did not take effect" cannot be distinguished from this run. The plan also asks
for a self-compile, which was not run: under `ECO_HEAP_VALIDATE` the O(bytes-allocated)-per-minor
`preEvacuationFromSpaceWalk` over 1,924 minors and ~20 GB makes it hours, not minutes.
**W1.2 therefore remains unresolved** — it is neither justified nor excluded by this.

### W2 — `evacuate` inner loop (items 16-22; 23 declined) — **FLAT, kept**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 194.25 | 83.21 | 1924 | 6 | 19861 | 10,817,016 | 13,241,185 | same |
| r2 | 201.39 | 86.40 | 1924 | 6 | 19861 | 10,816,820 | 13,241,185 | same |
| r3 | 197.87 | 84.58 | 1924 | 6 | 19861 | 10,816,648 | 13,241,185 | same |
| **median** | **197.87** | **84.58** | 1924 | 6 | 19861 | 10,816,820 | 13,241,185 | same |
| Δ vs `W0` | **-0.56** | -0.41 | **0** | **0** | **0** | -588 | 0 | — |

Item 17 moves the from-space test ahead of the child header load, so an edge pointing at to-space,
old gen or permanent space no longer pays a cache-line touch on a different object; items 18/19/22
cache `promotion_age` (three sites) and `use_hybrid_dfs` (per Cons cell) as members refreshed in
`refreshCapacityCaches`, folding the three copies of the promote predicate into `shouldPromote()`;
item 21 inlines `evacuateUnboxable` so an unboxed slot costs no call; item 16 caches the heap
bounds; item 20 adds three argued `__builtin_expect` hints. Patch `step-W2b.patch`, 90 lines.

**FLAT (-0.56 s, inside the 5.3 s band), kept under §4's disposition rule.** Counter identity —
the gate for this package — holds exactly: 1924 / 6 / 19861 on every leg. E2E `--target check`
1731/1731. Triple spread 7.14 s (3.6 %), above §8's ~2 % disturbed-machine line; not re-run
because the effect is ~0.5 s and the counters carry the verdict.

**Item 23 DECLINED, not deferred.** The three bitfield writes deliberately leave `color`
UNTOUCHED, while the plan's composed word `(uint64_t)Tag_Forward | (fwd << 7)` zeroes it — a real
behaviour change for a speculative micro-gain on a word `memcpy` has just left in L1. Reinstating
it needs a justification for dropping `color`, which the plan does not give.

**TRAP that cost a full cycle (`W2` before `W2'`).** Hoisting `allocator_->getHeapBase()` into a
member by a blanket string replace also rewrote the cache's OWN initialiser inside
`refreshCapacityCaches` into `heap_base_ = heap_base_;`. The cache stayed null, every pointer
tested as out-of-heap, and all three legs took SIGSEGV at the first minor GC in 0.14 s. A global
replace of an expression is unsafe exactly where that expression initialises the thing replacing
it. `try-W2` keeps the broken state; `try-W2b` is the fix.


### W3 — per-object dispatch (items 24, 28; 25 refuted, 26 no-op) — **item 24 LOSS, item 28 FLAT and kept**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| **W3** = 24+28, r1 | 201.55 | 87.74 | 1924 | 6 | 19861 | 10,817,360 | 13,241,185 | same |
| r2 | 201.34 | 87.48 | 1924 | 6 | 19861 | 10,817,036 | 13,241,185 | same |
| r3 | 201.76 | 88.59 | 1924 | 6 | 19861 | 10,817,640 | 13,241,185 | same |
| **median** | **201.55** | **87.74** | 1924 | 6 | 19861 | 10,817,360 | — | same |
| Δ vs `W2` | +3.68 | **+3.16** | 0 | 0 | 0 | +540 | 0 | — |
| **W3'** = 28 alone, median of 197.91 / 195.73 / 193.34 | **195.73** | **83.49** | 1924 | 6 | 19861 | 10,816,696 | 13,241,185 | same |
| Δ vs `W2` | -2.14 | **-1.09** | 0 | 0 | 0 | -124 | 0 | — |

**Item 24 (table-driven `getObjectSize`) is a REGRESSION and is reverted.** Its triple was
exceptionally tight (spread 0.42 s) and GC-time ranges are near-disjoint against W2 — 87.48-88.59
vs 83.21-86.40. Re-measuring item 28 ALONE then swung it back (-1.09 s GC), which attributes the
whole +3.16 s to item 24: roughly 5 s of GC time for the table.

**Why the premise fails.** The plan argues `getObjectSize` is "an indirect branch on a
data-dependent tag sequence, so it mispredicts". On this workload the sequence is NOT adversarial —
`Cons`, `Custom` and `Tuple2` dominate the survivor population — so the branch predictor handles
the jump table well, while the replacement adds a table load plus a multiply on the Cheney stride's
critical path. **Branchless is not free when the branch was already predicted.** Treat the same
style of argument in W4 item 29/30 with that in mind.

**Item 28 kept (FLAT, -2.14 s wall / -1.09 s GC, inside the band).** `walkStepFor` discards its
second argument on every uniform size-class page, so the eager `getObjectSize(obj)` was a full size
dispatch per marked object for a value immediately thrown away; it is now computed only on the
mixed path. Counters identical, E2E 1731/1731. Patch `step-W3b.patch`, 9 lines.

**Item 25 REFUTED by the code, not measured.** The plan says the Cheney loop "recomputes" a size
`scanObject` already has — but `scanObject` calls `getObjectSize` **zero** times; the loop's call at
`:503`/`:530` is the only computation, so returning the stride would merely relocate it. Evacuate's
size cannot be threaded either: it and the scan loop are separated by the work queue. **Item 26** is
"leave the switch", i.e. a no-op by design.


### W4 — slot scanning (items 29/30/31; 32 closed by its own gate) — **LOSS, reverted**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 199.13 | 85.45 | 1924 | 6 | 19861 | 10,817,208 | same |
| r2 | 202.18 | 86.53 | 1924 | 6 | 19861 | 10,816,088 | same |
| r3 | 198.23 | 84.77 | 1924 | 6 | 19861 | 10,816,228 | same |
| **median** | **199.13** | **85.45** | 1924 | 6 | 19861 | 10,816,228 | same |
| Δ vs `W3'` | +3.40 | **+1.96** | 0 | 0 | 0 | -468 | — |

Hand-hoisted the kind bitmap out of the `Custom` / `Record` / `Closure` slot loops (the compiler
cannot: `evacuate` writes through `Unboxable&`) with an all-boxed fast path that drops the per-slot
shift/mask/compare entirely, plus item 31's uniform-kind hoist for `ElmArray`. **GC-time ranges are
DISJOINT against the reference** (84.77-86.53 vs 82.73-84.07), so this is a real regression, not
spread. Reverted to `keep-W3`.

**NOT the plan's `_pext_u64` form, deliberately.** BMI2 is in the `release` preset
(`-march=x86-64-v3`) but NOT in `build`, which is what these candidates link, and the plan's own
non-BMI2 fallback is "the existing loop" — so that version would have compiled out to exactly the
code it was meant to replace and measured as a guaranteed no-op.

**Item 32 CLOSED on its own gate, at zero build cost.** The gate is "pointer-free objects >= 15 % of
SCANNED objects". `GCStats` already prints per-tag survived counts as the `copied N` field of the
retention block, so the number was available from an existing run: pointer-free tags are
**2,686,761 of 744,330,443 copied = 0.36 %**, against a 15 % threshold. `Custom` + `Cons` are
**96.9 %** of scanned objects and both are structurally excluded from the bit (Cons's bitmap covers
the head only; Custom qualifies on the inline path alone). Int / Float / Char never appear as
survivors at all. So the riskiest item in the plan — a header-bit steal touching ~60 writers and 13
`composeHeader` call sites — is retired by arithmetic. Items 29/31 having also failed removes the
second half of its justification.


### W5 — minor-GC structure (items 33, 35, 55; 34/36/37/53 resolved without a build) — **WIN on RSS, kept**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 192.87 | 82.05 | 1924 | 6 | 19861 | 10,805,484 | same |
| r2 | 199.85 | 84.78 | 1924 | 6 | 19861 | 10,806,452 | same |
| r3 | 196.17 | 83.39 | 1924 | 6 | 19861 | 10,805,896 | same |
| **median** | **196.17** | **83.39** | 1924 | 6 | 19861 | **10,805,896** | same |
| Δ vs `W3'` | +0.44 | -0.10 | 0 | 0 | 0 | **-10,800** | — |

**WIN under §4 rule 2**: wall did not increase and max RSS improved by **10.8 MB with DISJOINT
ranges** (10,805,484-10,806,452 vs 10,816,156-10,817,404). Counters identical, E2E 1731/1731.
Patch `step-W5.patch`, 84 lines.

Item 33 deletes a Cheney drain that phase 3 re-ran unconditionally straight after. **Item 35 is
where the RSS came from**: `promoted_objects` was a local, so it malloc'd and doubled from zero
inside every pause — ~350K promoted per minor GC is ~19 reallocs each copying up to 2.8 MB of
pointers, 1,924 times per run — and is now a retained member cleared per cycle. Item 55 inlines
`recordPromotion` / `recordSurvival`, **~1.42 billion calls per self-compile** (744M survivors +
676M promotions); it moved GC time by -0.10 s, i.e. nothing, which is the `inline-bump-state-tls`
lesson again at the largest call count in the plan.

**Four items resolved with no build cycle:**
- **34 (hybrid-DFS A/B)** — specified as a config-only experiment, and the 2026-09-22 sensitivity
  sweep already ran it: `use_hybrid_dfs=false` measured **+8.1 s** with counters identical. Its own
  decision rule ("turn it off if flag-off improves wall >=1 %") says **keep it on**. Closed.
- **36 (root iteration order)** — closed by the plan itself: roots are `longLived=4 jit=0`.
- **37 (`std::function` scanners)** — closed on arithmetic: ~6 scanners x 1,924 minors is ~11.5K
  heap allocations per run, under a millisecond. Not worth 7 registration sites across 6 files.
- **53 (child prefetch)** — skipped: its stated prerequisite is item 29, which W4 measured as a
  LOSS, and it is an add-work-to-save-misses change of exactly the class that has now failed twice.


### W10 — stackmap lookup (item 56) — **FLAT, kept**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 197.02 | 83.68 | 1924 | 6 | 19861 | 10,805,776 | same |
| r2 | 197.27 | 83.84 | 1924 | 6 | 19861 | 10,805,624 | same |
| r3 | 193.67 | 82.33 | 1924 | 6 | 19861 | 10,805,692 | same |
| **median** | **197.02** | **83.68** | 1924 | 6 | 19861 | 10,805,692 | same |
| Δ vs `W5` | +0.85 | +0.29 | 0 | 0 | 0 | -204 | — |

`StackMap::findRecord` runs per stack frame at every minor AND major GC, and most frames — GC
entry, allocator internals, libc — can never match. Records the `[lo, hi)` span of statepoint
return addresses at parse time and rejects out-of-span frames with two compares before touching
the hash table (the plan's tier 2, the only one that can eliminate a lookup rather than speed it
up). The map is never mutated after startup, so the span is fixed once parsed; the empty-map case
degrades correctly (`addr_hi_ = 0` rejects everything). Patch `step-W10.patch`, 12 lines.

**Flat and kept under the disposition rule** — it deletes work, and nothing regressed. Tiers 1
(sort + binary search) and 3 (direct-mapped cache) NOT attempted: the span check removes the
lookups rather than accelerating them, so the remaining surface is the frames that DO match, which
must be looked up regardless. Counters identical, E2E 1731/1731.


### W9 — old-gen bookkeeping (item 41; 42-47 not attempted) — **FLAT, kept**

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 197.13 | 83.49 | 1924 | 6 | 19861 | 10,805,240 | same |
| r2 | 198.62 | 84.19 | 1924 | 6 | 19861 | 10,805,824 | same |
| r3 | 197.18 | 83.55 | 1924 | 6 | 19861 | 10,803,792 | same |
| **median** | **197.18** | **83.55** | 1924 | 6 | 19861 | 10,805,240 | same |
| Δ vs `W10` | +0.16 | -0.13 | 0 | 0 | 0 | -452 | — |

Deleted `BufferMetadata::block_index` and the O(#blocks) walk that rewrote it in
`fixupIndicesAfterBlockMove`. Verified first that the field is written in three places and **read
nowhere** but that loop's own self-comparison; every real consumer subscripts `buffer_meta_[i]`
from `blocks_`. The parallel-vector invariant that makes the deletion safe is now written down in
`OldGenSpace.hpp` and asserted in the two reset paths, rather than left as convention. Patch
`step-W9.patch`, 41 lines. Counters identical, E2E 1731/1731.

**The size estimate was right and the cost was still nil.** The per-major table shows reclaim
releasing 761 / 518 / 5007 / 3536 MB in single pauses — ~10,000 block releases against a
~20,000-block heap, i.e. **~1e8 iterations inside one GC pause** — and removing them moved GC time
by -0.13 s. At ~1 ns per trivial compare that is ~0.1 s across the whole run, under the noise
floor. **Fourth confirmation of the `inline-bump-state-tls` lesson in this series.**

**Items 42, 43, 45, 46, 47 NOT attempted, on the evidence of this series.** Each adds a side
structure to remove a scan — a per-block large-body list (42), a sentinel side list (43), a
free-block list (45), an in-header `LargeBodyId` (46), a field read replacing a map lookup (47).
That is the restructure-to-remove-a-scan shape, which has now lost twice (item 24 at +3.16 s GC,
W4 at +1.96 s) while every pure deletion has been flat-to-positive; and item 41 shows the scans
they target are themselves below the noise floor. Item 46 additionally wants 15 bits of
`Header.refcount` with an overflow-sentinel scheme — substantial header surgery for a lookup item
41 has just shown to be free. **Item 44 is the one worth revisiting**: it deletes a bulk
mark-bitmap `memset`, but only after restoring the invariant that justifies it (clear the mark bit
in `finalizePoppedCell`), which needs its own heap-validate cycle.


### W7 — promotion-path sweep coupling (item 14) — **knob kept at default 1 (unchanged); leg B REJECTED on throughput**

Three legs, one binary, selected by the new `minor_sweep_divisor` HeapConfig knob
(1 = today, 8 = throttle, 0 = full gate). All three produced `out.mlir` byte-identical to
`ecoghash.mlir` and 1924 minors. Patch `step-W7.patch`, 29 lines. E2E 1731/1731.

| leg | divisor | wall (s) | major GC (s) | minor GC (s) | **GC total** | **max minor pause** | majors | max RSS (kB) |
|---|---|---|---|---|---|---|---|---|
| **A** today | 1 | **194.64** | 8.41 | 74.01 | **82.42** | 986.37 ms | 6 | 10,805,292 |
| **C** throttle | 8 | 196.75 | 7.94 | 75.21 | 83.15 | 401.79 ms | 5 | **14,332,148** |
| **B** full gate | 0 | 201.19 | 10.96 | 77.29 | **88.25** | **186.13 ms** | 6 | 10,823,684 |

**Leg B satisfies every acceptance criterion in the plan and still must not ship.** Worst minor
pause falls **81 %** (986 -> 186 ms), majors do not increase (6 -> 6), peak RSS moves +0.17 %. But
it costs **+6.55 s wall and +5.83 s GC time**, far outside the 5.3 s band. The plan predicted the
mechanism exactly — *"sweep work deferred out of the minor pause still has to happen"* — and that
deferred work IS the +5.83 s. **Its criteria measure latency and omit throughput**, and this
workload is a batch self-compile. Recorded, not adopted; a latency-sensitive deployment should
revisit it, which is what the knob is for.

**Leg C, the conservative option, is the one that fails outright: peak RSS +32.6 % (+3.5 GB)**
against criterion 3's 5 % limit. Cause is visible in the same row — it deferred a major (6 -> 5),
so the heap grew instead of being reclaimed. **The partial throttle is more dangerous than the full
gate**, which is the opposite of the intuition that motivated offering it as the safe fallback.

Shipped state: the knob exists, defaults to **1**, and at that value the code is today's behaviour
plus one `g_in_minor_gc` test. Leg A measures 194.64 s against the `W9` reference's 197.18 s — flat
to slightly better — so the added test is free. (Leg A is n=1, not a triple; the package's
deliverable is the three-way policy comparison, and the shipped default is behaviourally unchanged.)


### W6 — old-gen virgin-page bump (item 10) — **LOSS, reverted (+77.5 s wall, +68.2 s GC, +33 % RSS)**

Per-class `VirginCursor` bumping fresh pages instead of pre-slicing them. `populateFromBlock`
carves a whole page into uniform `Tag_Free` cells — **21,845 for a 24-byte class**, each a header
`memset` plus one to three link writes — and the allocator then pops them back one at a time, in
address order. Recycled space needs a free list; virgin space is contiguous and consumed in address
order, which a bump cursor computes with no list. Patch `step-W6.patch`, 115 lines; tree `try-W6`.

Design points, all four hazards the plan names handled explicitly:
- `BlockInfo::end_of_objects` is the parse frontier, advanced on EVERY bump before the object is
  usable, so a GC firing mid-page walks a well-formed prefix and never parses the un-bumped tail.
- Reuse-before-grow preserved: the free-list pop stays step (1); the cursor is step (1b).
- `onUniformBlockDedicated` credited on claim — skipping it silently disables
  `shouldPreferBagForSmallClass` and makes the small-class budget inert.
- Cursors invalidated on block release AND re-pointed on the swap-remove reindex.
- The block keeps `size_class = cls`, so `walkStepFor` still gives sweep a fixed stride; nothing
  becomes "mixed". That is what distinguishes this from the rejected promotion-PLAB design.

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 250.84 | 130.44 | 1924 | 6 | 19861 | 14,389,864 | same |
| r2 | 272.17 | 150.58 | 1924 | 6 | 19861 | 14,402,500 | same |
| r3 | 288.85 | 159.84 | 1924 | 6 | 19861 | 14,376,676 | same |
| **median** | **272.17** | **150.58** | 1924 | 6 | 19861 | **14,389,864** | same |
| Δ vs `W7` | **+77.53 (+40 %)** | **+68.16 (+83 %)** | 0 | 0 | 0 | **+3,584,572 (+33 %)** | — |

E2E `--target check` 1731/1731, counters bit-identical, output byte-identical, deterministic across
all three legs — **the mechanism is CORRECT. The policy is catastrophic.** The legs degrade
monotonically (250.84 -> 272.17 -> 288.85 s), the signature of swapping: RSS is 14.4 GB on a 15 GB
box. (The first attempt at this triple was killed by the host's low-memory reaper — in hindsight,
that was the regression announcing itself.)

**Root cause: the cursor was placed one rung too high in the allocation ladder.** I put it at step
(1b), right after the exact-fit free-list pop, on the plan's assurance that *"reuse-before-grow is
preserved: the free-list pop stays step 1"*. **That assurance is wrong.** Step (1) is only the
EXACT-FIT pop; steps (2)-(7) that (1b) now jumps ahead of are not all growth paths —
`tryAllocateBySplittingLarger` and the `hasPendingSweepWork()` sweep-on-demand rung are REUSE paths.
So the allocator claims a fresh virgin page whenever the exact-fit list misses, instead of first
splitting a larger free cell or sweeping to reclaim garbage, and the heap grows 3.6 GB into swap.
This is precisely the discipline `plans/sweep-on-demand-allocation.md` exists to enforce.

**Retry shape, for whoever picks this up:** the cursor belongs BELOW the reuse ladder — after
splitting and sweep-on-demand, immediately before `populateFromBlock`, which is the rung it is
actually meant to replace. It should be reached only when the allocator would otherwise have
pre-sliced a fresh page. Everything else in the implementation (parse frontier, budget credit,
cursor invalidation, fixed stride) held up under E2E and the counter gate.

### The heap-validate gate is RED on this tree, for reasons predating this series

The plan makes a heap-validate build mandatory for W1, W4-item-32, W6 and W8. **It cannot pass on
this tree at all.** With W6 removed entirely, `keep-W7` under `-DECO_HEAP_VALIDATE=ON` dies in the
`NurserySpace` property-based test:

```
[gc-debug] INVARIANT VIOLATION: phase 3 child not old enough to promote!
  child obj=... tag=9 age=0 builder=0 promotion_age=2
  parent(old-gen) obj=... tag=7 size=4 age=1
Segmentation fault
```

A randomly generated graph produces an old-gen parent holding a YOUNGER nursery child. That is
exactly the case `NurserySpace.cpp`'s own comment says kernel-side mutation paths can create, and
which phase 3's re-drain loop handles — **the assertion is stricter than the collector's contract.**

**I first attributed this to the `gcdef` default (`promotion_age=1`) and that was WRONG**: setting
`PROMOTION_AGE` back to 2 and re-running reproduces it identically (the trace above IS the
`promotion_age=2` run). It is independent of both W6 and the shipped default. Three validate cycles
established that; recorded so the next reader does not spend them again.

**Consequence:** a red validate result on this tree carries no information about the change under
test, so W6 was evaluated on the gates that DO discriminate — E2E, counter identity, determinism and
fixed point — which are the four that caught every real defect in this series (W1.1's watermark,
W2's null cache, W3's and W4's regressions). Fixing the property test, or relaxing the assertion to
match the documented contract, is a prerequisite for anyone resuming W1, W4-32, W6 or W8.


## 7. Findings

(What this series learns, separated from the per-step records so the entries stay to ten lines.
Every claim traceable to a numbered entry in §6. The LSS series' findings are in
`benchmarks/lss-compile-opt-loop.md` §7; the two that already bind this loop are quoted in §4
(judge on GC time, not the minor-cycle count) and §3 (old-gen peak gates a nursery step).)

### The plan's instruction-count reasoning mispredicts, in a consistent direction

Eleven packages produced one win, six flats and two losses. The direction of error is not random:

- **Every pure deletion was flat-to-positive.** W0's dead branch and debug tripwires, W2's hoists,
  W3'`s skipped size dispatch, W5's redundant Cheney drain, W9's O(n^2) fixup, W10's rejected
  lookups. None regressed; W5 produced the series' only win (RSS -10.8 MB).
- **Every restructure-to-remove-a-branch LOST.** Item 24's table-driven `getObjectSize`
  (**+3.16 s GC**, disjoint ranges) and W4's hand-hoisted boxed-slot fast path (**+1.96 s GC**,
  disjoint ranges). Both replaced a predicted branch with a table load or an extra loop-entry
  branch, and both cost more than they saved. **Branchless is not free when the branch was already
  predicted** — the survivor tag sequence is dominated by `Cons`, `Custom` and `Tuple2`, so the
  predictor handles it.

### A large count is still not a large cost — now with four more data points

The plan's own standing caution cites `inline-bump-state-tls`: 10.46 BILLION calls deleted for
-0.03 % wall. This series reproduced that four times over:

| change | events removed | GC-time move |
|---|---|---|
| item 55 — inline `recordPromotion`/`recordSurvival` | **~1.42 billion calls** | -0.10 s |
| item 41 — delete the O(n^2) block-index fixup | **~1e8 iterations per pause** | -0.13 s |
| item 13 — delete the dead allocation-paced mark branch | every old-gen allocation | 0 |
| W2 item 17 — skip the child header load off from-space | most traced edges | -0.41 s (package) |

**Rank by events x per-event cost x criticality, and measure before writing the plan.** Every one
of these was argued from a count.

### Six specified items did not survive contact with the tree

Refuted by READING, before any build cycle: W0 items 11/12 (already done — the promotion-path timer
is already excluded by `timed = !g_in_minor_gc`, leaving 213.80 ms of mutator-context cost);
W1.3's exposure table (`FieldGroup` not exposed; `Task` and `Process` exposed and missing);
W2 item 23 (the composed forward word silently zeroes `color`, which the three writes preserve);
W3 item 25 (`scanObject` calls `getObjectSize` ZERO times, so the recomputation it removes does not
exist); W4 item 32 (**0.36 %** of scanned objects are pointer-free against a >=15 % gate — closed by
arithmetic on data already being printed); W5 item 37 (~11.5 K allocations/run, under a millisecond).

The plan warned its line numbers were taken against the 2026-09-21 tree and to "trust the name,
re-locate the line". **The same drift applies to its premises, not just its citations.**

### The one result that inverts an intuition: W7's partial throttle is worse than the full gate

Leg C (`minor_sweep_divisor=8`, offered as the SAFE fallback) blew peak RSS by **+32.6 % (+3.5 GB)**
because it deferred a major GC (6 -> 5) and the heap grew instead of being reclaimed. Leg B (the
aggressive full gate) held majors at 6 and RSS at +0.17 %. And leg B passes every acceptance
criterion the plan states — 81 % lower worst pause, majors flat, RSS flat — **and still must not
ship**, because it costs +6.55 s wall and +5.83 s GC. The criteria measure latency and omit
throughput; this workload is a batch self-compile. Recorded, not adopted; the knob exists for a
latency-sensitive deployment.

### The largest single result is a LOSS, and it is about placement, not mechanism

W6's virgin-page bump cursor is the only change in the series with a mechanism that could plausibly
have moved the number — it stops `populateFromBlock` pre-slicing 21,845 cells per page only for the
allocator to pop them back one at a time. It measured **+77.5 s wall, +68.2 s GC, +33 % RSS**: the
biggest move of the series, in the wrong direction, and larger than everything else combined.

**The implementation was correct** — E2E 1731/1731, counters bit-identical, output byte-identical,
deterministic. What failed was WHERE the cursor sits: at step (1b), directly after the exact-fit
free-list pop, following the plan's assurance that reuse-before-grow is preserved because "the
free-list pop stays step 1". Step (1) is only the exact-fit pop; the rungs below it —
cell-splitting and sweep-on-demand — are also reuse paths, and jumping them turns every exact-fit
miss into a fresh page claim. The heap grew 3.6 GB into swap.

**Generalisation worth keeping: in an allocator ladder, "preserve reuse-before-grow" is a statement
about the WHOLE ladder, not about step 1.** A new rung must be inserted at the position of the rung
it replaces — here, immediately before `populateFromBlock` — not at the first place it would
produce a correct answer.

### Where the GC time actually is

Cumulative across the series: GC time **86.66 -> 82.42 s** (-4.9 %), max RSS **-11.3 MB**, wall
inside the noise band throughout. Nothing in the collector's dispatch, scan or bookkeeping paths
moved the number materially. The remaining GC cost is memory traffic — survivor copying and mark —
not instruction count, which is consistent with the `lss-compile-opt-loop` finding that time is
SURVIVOR COPYING, and with `gcdef` (a pure policy change: promote sooner, smaller nursery, defer
majors) having bought **-30 s** where eleven packages of constant-factor work bought ~4 s of GC time.
**The next real win is algorithmic — parallel marking (working-list #57-63), which W8 item 40
gates — not another constant-factor pass.**

## 8. Provenance

- Step list and landing order: `plans/gc-tier1-constant-factors.md` — its work-package table,
  Sequencing graph and cross-package dependencies, reproduced in §0. Its Validation section
  supplies this series' gate list (§1 Phase 4) and its Disposition rule the flat-package amendment
  and the counter-identity gate (§4); that plan in turn cites `guides/perf-tune-loop.md` and
  `benchmarks/lss-opt.md:18-75`.
- Method otherwise inherited verbatim from `benchmarks/lss-compile-opt-loop.md` §§1-5 (2026-09-19
  to 2026-09-22), which in turn adapted `benchmarks/lss-payoff.md`. Changes made for this series:
  GC time promoted to a judged column (§3); `ECO_HEAP_CONFIG` re-scoped from "never touch" to
  "never in a timed run, change the compiled-in default instead" (§5); the registry-TTL touch added
  to the timed command (§2); the `rc == 0` crash-detection rule added (§5); and the two rule changes
  the plan requires — a flat correct package ships, and the GC counters become a gate rather than a
  stat (§4). **Where the two documents disagree, the plan wins and §4 says so explicitly**: the
  parent loop would revert a flat package and would read a counter move as a result rather than as
  something owing an explanation.
- Baseline: the `gcdef` row of §9 — `PROMOTION_AGE=1`, `NURSERY_MAX_BLOCKS=512`,
  `MAJOR_GC_INITIATING_OCCUPANCY=0.95`, measured 199.46 s / 86.66 s GC / 6 majors / 1924 minors /
  19861 MiB promoted / 10,816,544 kB RSS, `out.mlir` 13,241,185 B. Tree snapshot `try-gcdef`,
  binary `bin/eco-optgcdef`, patch `snapshots/lss-loop/step-gcdef.patch`.
- Where the defaults came from: `plans/gc-param-sweep/sensitivity-2026-09-22-results.md` (42-cell
  one-at-a-time sweep; ten parameters moved no counter at all) and
  `plans/gc-param-sweep/combinations-2026-09-22-results.md` (pairs, triples, the quad, and the
  refuted `nmbc_128` variant). Both carry retractions worth reading before re-testing anything
  they cover.
- Noise band, inherited and still current: wall spread ~1.3 % of median over a triple; the
  independent estimate from the 2026-09-22 sweep (21 cells whose GC counters were bit-identical to
  baseline, so their spread is pure machine noise) is **sd 2.6 s, 2σ = 5.3 s**. GC counters and
  promoted MiB are exactly deterministic per (binary × tree); wall and RSS are the noisy columns.
- Stat extraction: `benchmarks/lss-loop-extract.sh <prefix>` (five judged stats plus GC time and
  `out.mlir` bytes, as one TSV line). Snapshot tool: `benchmarks/lss-loop-snap.sh`. No git in this
  container, so snapshots ARE the history.
- Self-compile command: bootstrap Stage 7a, `compiler/CMakeLists.txt:494`; lowering command:
  Stage 6, `compiler/CMakeLists.txt:457-468`.

## 9. Summary


**Rows above `gcdef` are INHERITED from `benchmarks/lss-compile-opt-loop.md`** — the LSS
compile-time series, kept whole so this loop's deltas sit on a continuous record. `gcdef` is this
series' baseline; GC rows are appended below it.
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
are recorded individually in the parent file's §6, whose §7 explains which parts of the
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
| W0 (free deletions) | 198.43 | -1.03 | 1924 | 6 | 19861 | 10817408 | FLAT (kept) | gcdef |
| W1.1 (high-water clear) | 198.65 | +0.22 | 1924 | 6 | 19861 | 10810956 | LOSS (reverted, gate) | W0 |
| W2 (evacuate inner loop) | 197.87 | -0.56 | 1924 | 6 | 19861 | 10816820 | FLAT (kept) | W0 |
| W3 (table getObjectSize + walkStepFor) | 201.55 | +3.68 | 1924 | 6 | 19861 | 10817360 | LOSS (item 24 reverted) | W2 |
| W3' (walkStepFor hoist only) | 195.73 | -2.14 | 1924 | 6 | 19861 | 10816696 | FLAT (kept) | W2 |
| W4 (slot scanning 29/30/31) | 199.13 | +3.40 | 1924 | 6 | 19861 | 10816228 | LOSS (reverted) | W3' |
| W5 (minor-GC structure 33/35/55) | 196.17 | +0.44 | 1924 | 6 | 19861 | 10805896 | WIN on RSS (kept) | W3' |
| W10 (stackmap span check) | 197.02 | +0.85 | 1924 | 6 | 19861 | 10805692 | FLAT (kept) | W5 |
| W9 (delete block_index + O(n^2) loop) | 197.18 | +0.16 | 1924 | 6 | 19861 | 10805240 | FLAT (kept) | W10 |
| W7 (sweep-coupling knob, default 1) | 194.64 | -2.54 | 1924 | 6 | 19861 | 10805292 | KNOB kept, leg B rejected | W9 |
| W6 (virgin-page bump) | 272.17 | +77.53 | 1924 | 6 | 19861 | 14389864 | LOSS (reverted) | W7 |
