# Front-end optimization loop: experiment protocol

This loop implements front-end compile-time changes one at a time. Each is measured the only way
that matters for compile time: **the compiler containing the change builds itself, and that
self-build is what we time.**

**Source of the steps:** `plans/cache-serialization-optimization.md` (§0 below). It covers per-module
cache serialization, the `.ecot` format, and the string and IO kernels behind them.

**Lineage:** this file continues `benchmarks/gc-opt-loop.md`, which closed at row `FHR` (107.04 s).
- That series in turn continued `benchmarks/lss-compile-opt-loop.md`.
- **The method below is that loop's, unchanged except where noted.**
- §9's summary table is carried over whole, and new rows are appended to it.
- The parent files keep the per-step entries and findings of the earlier series; they are not
  repeated here.

Everything here is native. Never measure on the JS build. No census of any kind runs inside a timed
leg.

## 0. The steps

The step list is `plans/cache-serialization-optimization.md` §2, in its landing order. **One item per
iteration**, named by its `S` number. An item the plan splits (S3's prototype vs rollout; S11's
(a)/(b)/(c)) gets one entry per part, because §5's one-step-per-iteration rule applies to items, not
to the plan's grouping. The S3 format break is ONE step by the plan's own rule (§5.0.7): S12a,
S12d, S3, S3b and S10 must land together.

| step | item(s) | plan § | byte-identical output? | outcome |
|---|---|---|---|---|
| fe-base | *(no change: the current tree, re-measured. The tree moved since `FHR`, e.g. plan 04's ConstThunks)* | — | — | |
| S1 | `Set.member` guard in the string collectors | 5.1 | yes | WIN −10.03 s |
| S2 | `computeVarSupers` without the `Set` | 5.2 | yes | WIN −4.38 s |
| S5 | skip the erased optimizer on the typed path (+ `graphHasMain`) | 5.5 | yes | WIN (rule 2) |
| S3p | type-table prototype (go/no-go, not a scored step) | 5.3.1 | — | skipped: S3 built directly |
| S3 | `.ecot` v2: type table + S3b + S10 + S12a + S12d | 5.3, 5.10, 5.12a, 5.12d | `.mlir` yes; `.ecot` changes (format v2) | WIN −23.36 s |
| S3k | native `Eco.Hash.deepWith` kernel for the type-table hash | 5.3.2 | yes | LOSS, reverted |
| S12b | `--builddir` path fix (+ harness pre-cleans) | 5.12b | yes | FLAT, kept (fix) |
| S11a | no `strToIdx` on decode | 5.11 | yes | FLAT, kept |
| S11b+S12c | direct-to-heap `readBytes` + atomic writes (one `File.cpp` license audit) | 5.11, 5.12c | yes | FLAT, kept (fix) |
| S11c | stack snapshot in `makeUtf8LeafFromBytes` | 5.11 | yes | FLAT, kept |
| S9 | `StringOps::compare` hot/cold split | 5.9 | yes | kept, likely WIN |
| S4 | `--no-cache` one-shot mode (scored with the flag on, in a separate leg) | 5.4 | yes | WIN with flag (−6.87 s); default FLAT |
| S8 | `variableToCanType` memo experiment | 5.8 | yes | WIN −3.42 s |

**Order is constrained** (plan §2 and §5.0):

```
S1 ─► S2 ─► S5 ─► S3p ─(go)─► S3 ─► S12b ─► S11a ─► S11b+S12c ─► S11c ─► S9 ─► S4 ─► S8
```

- **S2 before S3** (§5.0.1). S3 must switch `computeVarSupers` to S3b in the same step.
- **S12a only with S3** (§5.0.7). The version bump moves the cache directory: `eco-stuff/0.1.2`,
  `~/.eco/0.1.2`. Update `REG` in §2 at that step.
- **S11b and S12c share one license audit** (G9, §5.0.6).

**What this loop scores.**
- The timed workload is the cold self-compile to `.mlir` (Stage 7a shape). Phase 2 deletes
  `eco-stuff`, so every per-module cache write the plan targets is inside the measured wall. The
  plan's main effect shows as front-end time.
- **This series' primary stat is the front-end phase split**: "parse / check / build" from `--stats`,
  plus wall. The GC columns stay as recorded stats; see §3.
- Warm-decode items (S3's decode side, S11) are additionally scored in a labelled warm leg: the same
  command with `eco-stuff` kept from the previous run. The warm leg is never mixed with the cold
  triple.

**Snapshot names are prefixed `fe-`** (`try-fe-S1`, `keep-fe-S1`, `step-fe-S1.patch`), because older
series already own `try-S1`-style names and snapshots are never overwritten. Binaries keep the
plain step id (`eco-optS1`, `ecoS1.mlir`).

**C++-only steps** (S9, S11b/c, S12c) change the runtime or kernels, not the compiler source.
- They still go through the same loop: **the candidate is the same compiler MLIR lowered against the
  changed runtime**. Phase 1.3 is skipped, and Phase 1.4 lowers the reference MLIR again.
- **Elm steps** (S1, S2, S5, S3, S12b, S11a, S4, S8) need Phase 1.3.

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
`bin/eco-opt-prev` = the last kept compiler (for this series it starts at `bin/eco-optfe-base`,
the `fe-base` row), `N` = the step number.

**Phase 0: series baseline (`fe-base`).**
- The tree has moved since `FHR` (plans 01–07, including plan 04's front-end ConstThunks), so this
  series measures its own baseline. Do NOT inherit `FHR`.
- `bin/eco-optfe-base` is the current tree's compiler, built by Phase 1.3/1.4 on the unchanged tree:
  1. compile with the newest native compiler available (`$BK/bin/eco-compiler-boot`);
  2. lower;
  3. self-compile once more to reach the fixed point.
- Then measure three cold runs (Phase 2's commands with `ARM=eco-optfe-base`).
- Snapshot `keep-fe-base`. This row is the reference until the first win replaces it, and it is NOT
  re-run per step.
- The one repeat, after the final step, is a drift check on the series.

**Phase 1 — implement and build the candidate (untimed).**
0. `lss-loop-snap.sh verify <ref>` — the live tree must be byte-identical to the reference snapshot
   before a single line is changed (catches a botched revert or an edit left over from elsewhere).
1. Implement step N in the source tree, following its plan section exactly: `compiler/src/...` for
   the Elm steps; `runtime/src/...`, `elm-kernel-cpp/src`, `eco-kernel-cpp/src` for the C++ steps.
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

> **PLAIN TRIPLE ONLY. The interleaved A/B form is RETIRED for this series (2026-09-23).**
> Every step is three cold runs of the CANDIDATE, judged against the RECORDED medians of the
> last win. The reference arm is never re-run beside the candidate, and
> `benchmarks/lss-loop-ab.sh` is not used here. One triple per step, ~3 runs × ~3 min.
>
> **The cost is known and accepted.** The wall column drifts about ±5 s between triples measured
> hours apart on this machine (parent loop §7; two re-runs in this series proved it), and that is
> larger than every step still on the list. Consequences, which are now part of the method:
> - a wall move inside §4's noise band carries NO information about the step — it is FLAT, never
>   a small win and never a small loss, and the entry says so in those words;
> - **In this series, the `--stats` phase split does the discriminating.** `parse / check / build`
>   is single-threaded and contains the work under test, so it is much tighter than wall. Lead
>   every entry with it, then wall, then GC time (§3);
> - a step whose entire claim rests on a wall move smaller than the band cannot be settled by this
>   protocol. Record it as flat, ship it if it is a deletion (§4's amendment), and do not
>   re-measure it hoping the number firms up.

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

**Gate batching (user rule 2026-10-01, `fast-iteration-defer-checks`).** In perf loops, measure,
fix and re-measure only; batch ALL correctness gates at the END of the series. Two exceptions run
inside the series:
- the cheap mechanical checks of Phase 2 (fixed point, determinism, crash grep);
- any check that a later step would make impossible. In particular, the S1/S2/S5 `.ecot`
  artifact-identity check must run before S3 changes the format: after S5, run the same source
  through `eco-optfe-base` vs `eco-optS5` and `diff -r` the two `eco-stuff` trees.

**Phase 4: on a win (or a shipping FLAT), gates, then keep.** Run the gates as a SEPARATE pass, never
interleaved with a timed run. The gate list is the plan's §1 (G1–G10) restricted to what the step
touches:
- **Every step:** G1 `cmake --build build --target elm-tests` (known baseline of 12 failures) and
  G2 `cmake --build build --target full`. Use `--target check` only for C++-only steps that do not
  regenerate `.mlir`.
- **Steps touching caching or the build pipeline** (S3, S12b, S12c, S4): G3 `run-aot-e2e`. Move
  `build/test/aot-e2e/*/eco-stuff` aside first until S12b lands. Also G6
  `benchmarks/incremental-cache-check.sh`.
- **The format step S3:** G4 a full bootstrap (`--target bootstrap` + `eco-verify`), G5 native
  cold→warm, G7 JS-vs-native `.ecot` equality (with step 0), and G8 stale format.
- **C++ kernel steps** (S11b+S12c): G9, the LSS_022 re-audit per
  `plans/kernel-parametricity-license.md`.
- Plus each section's own extra checks:
  - §5.1–5.5: the artifact identity check, `diff -r` of two cold `eco-stuff` trees excluding `d.dat`;
  - §5.3.8: the codec tests;
  - §5.5: the error-parity apps.

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
REG=~/.eco/0.1.1/packages/registry.dat           # see the touch below; becomes 0.1.2 at step S3 (V.compiler bump)

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
      "./bin/$ARM" make --stats --optimize --kernel-package eco/compiler \
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
| parse / check / build (s) | `$ARM-rR.stderr` | `--stats` "Front-end timing": `parse / check / build` |
| monomorphization (s) | `$ARM-rR.stderr` | `--stats`: `monomorphization` |
| MLIR codegen (s) | `$ARM-rR.stderr` | `--stats`: `MLIR codegen` |
| `.ecot` bytes | `$BK/eco-stuff` after r3 | `du -cb $(find $BK/eco-stuff -name '*.ecot') \| tail -1` |

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

**This series' primary stats are wall and the `parse / check / build` phase** (`--stats`). The plan
moves serialization, which lives in that phase. `--stats` is on in every timed run of this series,
the baseline included, so the instrument is constant. The GC paragraph below is inherited; GC time
stays a recorded column. **Inherited:** GC time was the primary stat in the GC series, and a footnote in the parent loop before that. It is what
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

**Amendment (inherited from the GC series, and kept for this one).** **A flat-but-correct
package that deletes work still SHIPS** — the precedent is `inline-bump-state-tls`, `stringLengthOp`
(−0.12 %) and `appendSplit` (+0.80 %), all default-on. It is recorded as **flat**, not as a win, and
its wall number still goes in the entry. This overrides the plain reading of the third rule above:
a flat wall is not a loss here. A wall REGRESSION outside the noise band is still a loss.

**Counter identity was a GATE in the GC series. It is NOT a gate in this one.** The counters are
deterministic per binary × tree (n=6, `benchmarks/lss-opt.md` Run R), so any movement is real.
**In this series, nearly every step changes allocation** (S1, S2, S3 and S5 delete allocation by
design), so the GC counters WILL move. Record them and say why; they are not a gate here. **Output
byte-identity of `.mlir` IS the gate** (the fixed point in Phase 2). S3 also changes the `.ecot`
bytes by design: gate them with G7/G8, not `cmp` against the reference.

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

- `rm -rf $BK/eco-stuff` before EVERY cold run, timed or not. Never delete `~/.eco`. Exception: after
  the S3 version bump, the first build repopulates `~/.eco/0.1.2` (package downloads). Do that in an
  untimed warm-up run before the triple.
- **Never edit `compiler/src`, `src-xhr` or `eco-kernel-cpp` while a build or triple runs.** The
  harness compiles the LIVE tree; edits mid-triple show up as fake nondeterminism (S3k entry).
- After any `eco-kernel-cpp` Elm change, move `~/.eco/0.1.2/packages/eco/kernel/1.0.0` aside: the
  local package is copied into the cache once and never refreshed.
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

Entries are appended here, newest last, in the §3 format.

### fe-base: series baseline (the current tree, no change)

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 109.17 | 65.2 | 24.1 | 13.1 | 8.13 | 2533 | 11 | 20506 | 11859280 | 13307791 | | same |
| r2 | 108.33 | 64.6 | 24.0 | 13.1 | 8.07 | 2533 | 11 | 20506 | 11867924 | 13307791 | | same |
| r3 | 108.44 | 64.8 | 23.9 | 13.1 | 8.07 | 2533 | 11 | 20506 | 11859508 | 13307791 | 449154923 | same |
| **median** | **108.44** | **64.8** | **24.0** | **13.1** | **8.07** | 2533 | 11 | 20506 | 11859508 | 13307791 | 449154923 | |

- **Binary:** `eco-optfe-base` = the bootstrap's `eco-compiler-boot` from 2026-10-03: plan 07 tree plus
  the Stage 9a/subst CMake change, with Stage 7a solver+LSS MLIR `ecofe-base.mlir` and 8c passed.
- **Spreads:** wall 0.84 s, parse/check/build 0.6 s.
- **Stats:** `--stats` is on (new for this series). Every GC counter moved versus `FHR` because the
  tree moved (plans 01–07), as expected.
- **Reference:** snapshot `keep-fe-base`. This is the reference row for S1.

### S1: `Set.member` guard in the string collectors (plan §5.1): **WIN, kept**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 99.09 | 54.7 | 24.0 | 13.2 | 7.87 | 1671 | 11 | 20631 | 12950444 | 13308250 | | same |
| r2 | 98.41 | 54.5 | 23.8 | 13.1 | 7.75 | 1671 | 11 | 20631 | 12953596 | 13308250 | | same |
| r3 | 98.30 | 54.0 | 24.2 | 13.1 | 7.77 | 1671 | 11 | 20631 | 12955216 | 13308250 | 449155888 | same |
| **median** | **98.41** | **54.5** | **24.0** | **13.1** | **7.77** | 1671 | 11 | 20631 | 12953596 | 13308250 | 449155888 | |
| Δ vs fe-base | **−10.03** | **−10.3** | 0.0 | 0.0 | −0.30 | −862 | 0 | +125 | +1,094,088 | +459 | +965 | |

- **Change:** `StringTable.addString` (`Set.member` then `Set.insert`) replaces all 54 `Set.insert`s
  in the 8 collector modules. Patch `step-fe-S1.patch`, 9 files.
- **Effect:** parse/check/build −10.3 s, well outside the 0.6 s spread. Wall −10.03 s.
- **Allocation:** minor GCs −34 %, from the deleted path-copy allocation.
- **RSS:** max RSS +1.09 GB. Fewer, larger collections let the old generation grow before a major
  GC; the same 11 majors run. Recorded per §3, not a gate.
- **Byte deltas:** `out.mlir` +459 B and `.ecot` +965 B come from the compiler's own source growing
  (the new helper). They are not an encoding change; the S1/S2/S5 identity check is batched after S5.

### S2: `computeVarSupers` via a supers-mode `Collector` (plan §5.2): **WIN, kept**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 94.56 | 50.6 | 24.2 | 13.4 | 7.56 | 1644 | 11 | 20554 | 10974800 | 13309621 | | same |
| r2 | 93.65 | 50.8 | 23.4 | 12.9 | 7.58 | 1644 | 11 | 20554 | 10972828 | 13309621 | | same |
| r3 | 94.03 | 51.0 | 23.6 | 12.9 | 7.60 | 1644 | 11 | 20554 | 10963708 | 13309621 | 449142019 | same |
| **median** | **94.03** | **50.8** | **23.6** | **12.9** | **7.58** | 1644 | 11 | 20554 | 10972828 | 13309621 | 449142019 | |
| Δ vs S1 | **−4.38** | **−3.7** | −0.4 | −0.2 | −0.19 | −27 | 0 | −77 | −1,980,768 | +1,371 | −13,869 | |

- **Change:** `StringTable.Collector` (`CollectAll` | `CollectSupers`) replaces `Set String` as the
  accumulator of every collector. These are signature-only changes; `add` replaces S1's `addString`.
  `computeVarSupers` and `varSupersOfType` run the same traversal in supers mode: 4 prefix tests per
  string, and a Set touched only on a hit.
- **New test:** `compiler/tests/Compiler/AST/VarSupersEquivalenceTest.elm` (3 tests incl. fuzz,
  passing) pins supers mode to the collect-all-then-filter reference and `isSuperName` to
  `superOfName`.
- **Effect:** parse/check/build −3.7 s, matching the plan's ~4 s estimate. Max RSS −1.98 GB, which
  gives back S1's +1.09 GB and more.
- **Bytes:** the `.ecot` byte delta is the compiler source changing (it is its own workload); the
  identity check is batched after S5.

### S5: skip the erased optimizer on the typed path (plan §5.5): **WIN (rule 2), kept**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 93.84 | 50.4 | 23.8 | 13.1 | 7.64 | 1642 | 11 | 20395 | 11007760 | 13309028 | | same |
| r2 | 93.19 | 50.2 | 23.8 | 12.9 | 7.62 | 1642 | 11 | 20395 | 11007468 | 13309028 | | same |
| r3 | 92.80 | 49.9 | 23.7 | 12.9 | 7.56 | 1642 | 11 | 20395 | 11010004 | 13309028 | 449142469 | same |
| **median** | **93.19** | **50.2** | **23.8** | **12.9** | **7.62** | 1642 | 11 | 20395 | 11007760 | 13309028 | 449142469 | |
| Δ vs S2 | −0.84 | −0.6 | +0.2 | 0.0 | +0.04 | −2 | 0 | **−159** | +34,932 | −593 | +450 | |

- **Change:** `compileTyped` stores `Opt.emptyLocalGraph` instead of running the erased optimizer.
  `Terminal/Make.elm` `getMain`/`isMain`/`getNoMain` read `main` through the new `graphHasMain`
  (the typed graph's `main` when present).
- **Verdict:**
  - Wall −0.84 s is inside the band (spreads 0.91 / 1.04 s), so flat.
  - Promoted MiB −159 with wall not increased, so a WIN by rule 2.
  - It is also a deletion, so it would ship flat anyway.
- **`main` detection** is exercised by the self-compile itself (a broken `graphHasMain` makes the
  `.mlir` build refuse its root).
- **Batched S1+S2+S5 artifact-identity check (PASSED):**
  - `eco-optfe-base` and `eco-optS5` compiled the same source (the S5 tree) cold;
  - `diff -r --exclude=d.dat` of the two `eco-stuff` trees is empty: all 275 `.ecot` and 275 `.eci`
    are byte-identical;
  - the two MLIR outputs are identical and equal `ecoS5.mlir`.

  S1, S2 and S5 are output-neutral as the plan claims.
- **Pending (batched):** the error-parity apps (§5.5) are batched with the end-of-series gates.

### S3: `.ecot` v2 — per-file type table + S3b + S10 + S12a + S12d (plan §5.3, §5.10, §5.12a, §5.12d): **WIN, kept**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 69.83 | 27.0 | 23.8 | 12.9 | 4.05 | 1235 | 7 | 7710 | 7534764 | 13370430 | | same |
| r2 | 70.09 | 26.6 | 24.1 | 13.2 | 4.07 | 1235 | 7 | 7710 | 7525076 | 13370430 | | same |
| r3 | 69.81 | 27.2 | 23.3 | 13.0 | 4.18 | 1235 | 7 | 7710 | 7530584 | 13370430 | 8736930 | same |
| **median** | **69.83** | **27.0** | **23.8** | **13.0** | **4.07** | 1235 | 7 | 7710 | 7530584 | 13370430 | 8736930 | |
| Δ vs S5 | **−23.36** | **−23.2** | 0.0 | +0.1 | −3.55 | −407 | −4 | **−12,685** | **−3,477,176** | (new source) | **−98.1 %** | |

- **Change (one change set, the format break):**
  - new `Compiler/AST/TypeTable.elm`: distinct `Can.Type`s interned children-first through
    `Data.HashMap` (`getHashed`/`insertNew`, new) under `(==)`; refs u8/u16/u32 by count;
  - `TypedOptimized`: every type position is a `TypeTable.ref`; the string collectors no longer
    visit types (`TypeTable.collectStrings` adds the distinct entries' strings); new
    `internTypesFrom*` walkers and `prePassLocal`/`prePassGlobal`; `computeVarSupers` runs the same
    pre-pass in supers mode (S3b); `typedGraphFormatVersion` 2;
  - S10: `uintV`/`sintV` (LEB128/zigzag), `regionEncoderV`, `zeroBasedEncoderV`, the other
    non-literal `BE.int`s in the graph codec (Int literals stay float64; the Canonical union/ctor
    ints are left alone, TypeEnv is 0.24 MB);
  - S12a: `V.compiler` 0.1.1 → 0.1.2 (`~/.eco/0.1.2` seeded from 0.1.1 minus every `*artifacts.dat`,
    plus one untimed warm-up); S12d: ECOT_001/002/003 rows in `design_docs/invariants.csv`.
- **Deviation:** S3 lands with the pure-Elm hash (`hashTypeElm`, the plan's fallback B). The
  prototype S3p was skipped as a scored step: the real build is the measurement. The native
  `Eco.Hash.deepWith` kernel is the next step, **S3k**, measured on top.
- **Verdict:** wall −23.36 s, far outside the band (spreads 0.28 s): **WIN**. Parse/check/build
  halves (50.2 → 27.0 s), GC time −47 %, promoted −62 %, peak RSS −3.3 GB, `.ecot` 449 MB → 8.7 MB.
- **Checks done now:** new unit tests `TypeTableTest` (dedup, must-not-merge, opposite-order records
  merge, round trip incl. 200 fuzzed lists and 2-byte refs, self-ref decode fails, drift) and
  `VarintCodecTest` pass with `VarSupersEquivalenceTest` (26/26). The fixed point holds: the S3
  compiler's output equals `ecoS3.mlir` (built by S5 from the same source), so the v2 round trip
  through every module's `.ecot` is MLIR-neutral.
- **Pending (batched):** G1–G4, the plan's S3 gates G5–G8 (`TypedOptimizedCodecTest`, JS == native
  bytes, incremental check).

### S3k: native `Eco.Hash.deepWith` for the type-table hash (plan §5.3.2): **LOSS (flat-to-worse), reverted**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 71.32 | 27.5 | 23.9 | 13.6 | 4.07 | 1235 | 7 | 7709 | 7535932 | 13370653 | | same |
| r2 | 71.03 | 27.8 | 23.6 | 13.1 | 4.10 | 1235 | 7 | 7709 | 7530376 | 13370653 | | same |
| r3 | 70.87 | 27.9 | 23.5 | 12.9 | 4.14 | 1235 | 7 | 7709 | 7536396 | 13370653 | 8737024 | same |
| **median** | **71.03** | **27.8** | **23.6** | 13.1 | 4.10 | 1235 | 7 | 7709 | 7535932 | 13370653 | 8737024 | |
| Δ vs S3 | +1.20 | +0.8 | −0.2 | +0.1 | +0.03 | 0 | 0 | −1 | +5,348 | (new source) | +94 | |

- **Change:** `Hash::deep` in `eco-kernel-cpp/src/eco/Hash.cpp` (an allocation-free structural walk
  mirroring `eqHelp`: strings by content, Cons/ConsChunk alike, Dicts in order, boxed = unboxed
  primitives, constants by word), exported as `Eco_Kernel_Hash_deepWith`; JS and `src-xhr` twins
  return `fallback x`; `TypeTable.hashType t = Eco.Hash.deepWith hashTypeElm t`.
- **Verdict:** an S3 control run taken right after measured 70.50 s (parse/check/build 27.1 s),
  so S3k is +0.5 s wall / +0.7 s parse/check/build against a same-session control: not a win on
  either. It adds a kernel with three twins, so it does not ship flat. Reverted to `keep-fe-S3`.
- **Why:** the type table already made type hashing cheap. Interning hashes each distinct subtree
  plus a whole-subtree probe per occurrence, and the pure-Elm hash runs in compiled native code
  with no call boundary; the kernel call is not gc-leaf (no `KernelFacts` row), so every probe pays
  a statepoint. The plan's "native ~0.6–1.7 s vs pure Elm several s" premise does not hold after
  lowering.
- **Trap recorded (cost one run triple):** the first S3k triple reported NONDETERMINISTIC output
  (r1/r2/r3 all differed). The cause was editing `compiler/src` (S12b) while the triple ran: the
  harness compiles the LIVE tree, so r1/r2/r3 compiled three different sources. Four repeat runs on
  a fixed tree were byte-identical. **Never edit the compiled trees while a triple runs** (§5).
- **Trap 2:** a changed `eco-kernel-cpp` Elm module is invisible until the cached copy of the local
  package is moved aside: `~/.eco/<ver>/packages/eco/kernel/1.0.0` is copied from the seed path
  ONCE (`Stuff.localPackageSource`). Move it aside after any kernel-package Elm change.

### S12b: `--builddir` artifact paths + dead `to.dat` read (plan §5.12b): **FLAT, kept (correctness fix)**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 70.20 | 27.1 | 23.3 | 13.3 | 4.12 | 1235 | 7 | 7710 | 7544032 | 13367233 | | same |
| r2 | 69.67 | 26.6 | 23.3 | 13.3 | 4.08 | 1235 | 7 | 7710 | 7538056 | 13367233 | | same |
| r3 | 70.46 | 26.9 | 23.7 | 13.4 | 4.14 | 1235 | 7 | 7710 | 7539920 | 13367233 | 8736065 | same |
| **median** | **70.20** | **26.9** | **23.3** | 13.3 | 4.12 | 1235 | 7 | 7710 | 7539920 | 13367233 | 8736065 | |
| Δ vs S3 | +0.37 | −0.1 | −0.5 | +0.3 | +0.05 | 0 | 0 | 0 | +9,336 | (new source) | | |

- **Change:** Build reads and writes `.eci`/`.eco`/`.ecot` under `eco-stuff/<ver>/<builddir>/`, the
  same place Generate and `d.dat`/`i.dat`/`o.dat` use (`maybeBuildDir` threaded through
  `checkDeps`/`checkDepsHelp`/`loadInterfaces`/`loadInterface`, the four compile functions and
  `CompileResultContext`). Root-only `Stuff.eci`/`eco`/`ecot`/`toArtifactPath` deleted so the bug
  cannot recur; the never-written `to.dat` read, `combineTypedArtifacts` and
  `Stuff.typedObjectsWithBuildDir` deleted; `--builddir` help text says `<version>`.
  Harness: `aot_e2e_main.cpp` / `mlir_equivalence_main.cpp` pre-cleans now wipe every version dir
  except `mlir/` (they named `1.0.0` and `eco-stuff/aot_e2e_*`, which never existed) and their
  comments are corrected. The two `.cpp` files are outside the snapshot lists; copies are in
  `snapshots/lss-loop/try-fe-S12b-harness/`.
- **Verdict:** wall +0.37 s, inside the band and under the same-session S3 control (70.50 s): flat.
  The self-compile never passes `--builddir`, so no win was expected here; it ships as a correctness
  fix plus deletions.
- **Pending (batched):** G6 builddir mode (the regression test: step A0 must now pass), G2, G3 with the
  fixed pre-clean, `mlir_equivalence`, G4.

### S11a: decode-only string table (plan §5.11a): **FLAT, kept (deletion + JS-stack fix)**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 69.94 | 27.1 | 23.5 | 13.2 | 4.09 | 1260 | 7 | 7738 | 7547240 | 13367460 | same |
| r2 | 69.64 | 26.7 | 23.6 | 13.1 | 4.09 | 1260 | 7 | 7738 | 7552548 | 13367460 | same |
| r3 | 71.18 | 27.0 | 24.3 | 13.4 | 4.18 | 1260 | 7 | 7738 | 7564404 | 13367460 | same |
| **median** | **69.94** | **27.0** | **23.6** | 13.2 | 4.09 | 1260 | 7 | 7738 | 7552548 | 13367460 | |
| Δ vs S12b | −0.26 | +0.1 | +0.3 | −0.1 | −0.03 | +25 | 0 | +28 | +12,628 | (new source) | |

- **Change:** `StringTable.tableDecoder` no longer builds the encoder-only `strToIdx` (left
  `Dict.empty`, documented as decode-only). Also `decodeStrings` is a `BD.loop` instead of a
  recursive `andThen` chain: the new `StringTableTest` showed the chain fails to decode a
  70,000-string table under JS (stack overflow surfaces as `Nothing`), which the JS bootstrap
  stages could hit. Same wire format.
- **Verdict:** flat (cold self-compiles decode only package artifacts; the saving is on warm builds).
  The minor-GC/promoted deltas track the compiled source, which changed. Ships as a deletion.
- **Tests:** `StringTableTest` (widths 1/2/4 at 3/300/70,000 strings) passes with `TypeTableTest`.

### S11b+S12c: direct-to-heap `readBytes` + atomic artifact writes (plan §5.11b, §5.12c): **FLAT, kept (correctness)**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 70.27 | 27.3 | 23.7 | 13.1 | 4.13 | 1260 | 6 | 7732 | 7942236 | 13366980 | same |
| r2 | 69.64 | 26.6 | 24.0 | 13.2 | 3.97 | 1260 | 6 | 7732 | 7935912 | 13366980 | same |
| r3 | 70.16 | 26.9 | 24.0 | 13.0 | 4.12 | 1260 | 6 | 7732 | 7942620 | 13366980 | same |
| **median** | **70.16** | **26.9** | **24.0** | 13.1 | 4.12 | 1260 | 6 | 7732 | 7942236 | 13366980 | |
| Δ vs S11a | +0.22 | −0.1 | +0.4 | −0.1 | +0.03 | 0 | −1 | −6 | +389,688 | (new source) | |

- **Change:**
  - S11b: `File.cpp` `readBytesBody` allocates the heap ByteBuffer first and reads straight into
    it (no zero-filled `std::vector` + copy); `tellg() < 0`, > 4 GiB and short reads are now
    `Err IOError` instead of a huge vector / zero-padded buffer.
  - S12c: new kernel `Eco.File.writeBytesAtomic` (C++: O_EXCL temp `<path>.tmp-<pid>-<seq>` +
    `rename`, write/close errors reported; JS kernel and the xhr `eco-io-handler.js` twin do the
    same). `Utils.binaryEncodeFile` (every `.eci`/`.eco`/`.ecot`/`*.dat`/registry write) switches
    to it. `writeObjectsAndFinalizeCompile` writes the `.eci` FIRST and the gating `.ecot`/`.eco`
    last (replaces `checkInterfaceAndFinalize`/`finalizeBasedOnInterface`).
  - G9 re-audit: all 25 `File.*` evidence strings remapped to the new line numbers (diff-mapped,
    then every `file:function:a-b` range re-verified against the source; the `mime`/`name` rows and
    the elm half of `size` cite `elm-kernel-cpp/src/file/FileExports.cpp`, which is unchanged) and
    dated 2026-10-03; new `File.writeBytesAtomic` row; manifest `--update` LAST (369 pins); the check
    passes and `kernel-license-check` is green in a full `cmake --build build`.
  - New E2E tests `FileWriteBytesAtomicTest`, `FileReadBytesRoundtripTest` (run in the batched G2).
- **Verdict:** wall flat. Peak RSS +0.39 GB with one FEWER major GC (7 → 6): the trigger moved, and
  the series memory says the trigger is chaotic. Neither change touches retention (the read buffer
  was heap-allocated before too). Ships as a correctness fix; RSS is re-checked at the series
  end. No `*.tmp-*` left in `eco-stuff` or `~/.eco/0.1.2` after the triple.
- **Pending (batched):** G2 (incl. the two new kernel tests), G3 + the 20× parallel-make stress,
  G4, G6.

### S11c: no heap snapshot for non-heap sources in `makeUtf8LeafFromBytes` (plan §5.11c): **FLAT, kept (deletes work)**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 69.25 | 26.9 | 23.6 | 12.7 | 4.09 | 1260 | 6 | 7732 | 7950440 | 13366980 | same |
| r2 | 69.64 | 26.9 | 23.6 | 13.0 | 4.07 | 1260 | 6 | 7732 | 7931968 | 13366980 | same |
| r3 | 70.41 | 27.2 | 23.9 | 13.1 | 4.17 | 1260 | 6 | 7732 | 7957936 | 13366980 | same |
| **median** | **69.64** | **26.9** | **23.6** | 13.0 | 4.09 | 1260 | 6 | 7732 | 7950440 | 13366980 | |
| Δ vs S11b+S12c | −0.52 | 0.0 | −0.4 | −0.1 | −0.03 | 0 | 0 | 0 | +8,204 | 0 (same source) | |

- **Change:** the source is copied to a 256-byte C-stack buffer (or a vector if longer) only when it
  lies in the movable heap (`Allocator::isInHeap`); C-stack/rodata/C-heap sources (`fromInt`,
  `fromFloat`, `fromChar`, `tinyFromU16`, `tryMakeAsciiString`) are copied directly with no malloc.
- **Verdict:** −0.52 s is inside the band (spread 1.16 s): flat. It removes a malloc/free per short
  leaf, so it ships under the deletion amendment.
- **Test:** new unit test `Utf8String: leaf from heap bytes under GC (S11c)` (rooted nursery
  ByteBuffer source, 4,000 leaves at lengths 1/31/128/256/257 under the pressure config, asserts the
  source was relocated mid-call at least once). **Negative control:** with the snapshot disabled the
  first version of the test still PASSED: a normal build leaves from-space readable, so a stale
  read sees the right bytes. The rewritten test proves the GC really moves the source; the stale
  read itself fails only where from-space is poisoned, i.e. the `ECO_HEAP_VALIDATE` unit gate
  (batched).

### S9: `StringOps::compare`/`equal` hot/cold split (plan §5.9): **kept — likely WIN (non-overlapping triples), FLAT by the band clause**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 68.72 | 27.0 | 23.6 | 12.0 | 4.13 | 1260 | 6 | 7732 | 7962504 | 13366980 | same |
| r2 | 68.11 | 26.9 | 23.5 | 11.9 | 4.07 | 1260 | 6 | 7732 | 7935792 | 13366980 | same |
| r3 | 69.11 | 27.2 | 23.7 | 12.1 | 4.13 | 1260 | 6 | 7732 | 7939556 | 13366980 | same |
| **median** | **68.72** | **27.0** | **23.6** | **12.0** | 4.13 | 1260 | 6 | 7732 | 7939556 | 13366980 | |
| Δ vs S11c | −0.92 | +0.1 | 0.0 | **−1.0** | +0.04 | 0 | 0 | 0 | −10,884 | 0 (same source) | |

- **Change:** `compare` and `equal` keep only the both-UTF-8 (memcmp) and both-UTF-16-leaf paths
  inline; slices, large headers, ropes and mixed widths move verbatim to out-of-line
  `[[gnu::noinline, gnu::cold]] compareSlow`/`equalSlow` in `StringOps.cpp`, so the segment
  vectors no longer set the hot frame. `utf8Bytes`, `singleSegmentView` and `forEachSegmentEx`
  use `Allocator::resolveFast` (always-heap fields; the 35 existing sites do the same). No
  pinned file touched (`UtilsExports.cpp`/`BytesExports.cpp` unchanged; license check green with
  no `--update`). The optional 8-byte prefix (S9b) was not enabled.
- **Verdict:** −0.92 s is inside the 1.16 s max-spread band, so FLAT by the band clause, but the
  triples do not overlap (S9 68.11–69.11 vs S11c 69.25–70.41) and the MLIR-codegen phase (string
  compares in emission maps) is −1.0 s in every run. Counters identical. Kept.
- **Tests:** new `Utf8String: compare/equal split, all forms (S9)` (16 strings incl. prefix pairs
  around 8 bytes, non-ASCII, astral, 5,000-unit large strings × {UTF-16 leaf/large, UTF-8 leaf,
  UTF-8 view, slice, rope}, > 1,000 pairs, sign and equality vs `u16string`). All 12 Utf8String,
  26 StringOps and 48 `string`-filtered unit tests pass.

### S4: `eco make --no-cache` one-shot mode (plan §5.4): **WIN when used (−6.87 s); default leg FLAT; kept**

Default leg (flag off):

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 68.37 | 26.7 | 23.5 | 12.1 | 4.07 | 1260 | 6 | 7730 | 7961304 | 13369268 | same |
| r2 | 68.10 | 26.6 | 23.5 | 12.1 | 3.99 | 1260 | 6 | 7730 | 7915340 | 13369268 | same |
| r3 | 69.20 | 27.2 | 23.6 | 12.1 | 4.13 | 1260 | 6 | 7730 | 7948624 | 13369268 | same |
| **median** | **68.37** | 26.7 | 23.5 | 12.1 | 4.07 | 1260 | 6 | 7730 | 7948624 | 13369268 | |
| Δ vs S9 | −0.35 (flat) | −0.3 | −0.1 | +0.1 | −0.06 | 0 | 0 | −2 | +9,068 | (new source) | |

`--no-cache` leg (same binary, `EXTRA_FLAGS=--no-cache`):

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 61.82 | 20.1 | 23.3 | 12.0 | 4.12 | 1217 | 7 | 7694 | 7499908 | 13369268 | | same |
| r2 | 61.85 | 19.8 | 23.6 | 12.1 | 4.10 | 1217 | 7 | 7694 | 7519840 | 13369268 | | same |
| r3 | 62.12 | 20.1 | 23.4 | 12.2 | 4.11 | 1217 | 7 | 7694 | 7467088 | 13369268 | 0 | same |
| **median** | **61.85** | **20.1** | 23.4 | 12.1 | 4.11 | 1217 | 7 | 7694 | 7499908 | 13369268 | 0 | |
| Δ vs default leg | **−6.52** | **−6.6** | −0.1 | 0.0 | +0.04 | −43 | +1 | −36 | −448,716 | same bytes | | |
| Δ vs S9 | **−6.87** | **−6.9** | | | | | | | | | | |

- **Change:** `Build.CacheMode = WriteCaches | OneShot` in `EnvData` and `CompileResultContext`
  (threaded like S12b's `maybeBuildDir`); `fromPaths = fromPathsWith WriteCaches` (API/Test callers
  untouched). One-shot skips the `.eci`/`.eco`/`.ecot` encodes+writes (the old `.eci` is still READ,
  so a warm one-shot keeps `RSame`) and the local `d.dat` write in `writeDetailsAndCollectRoots`.
  `Details.load`'s package-level regeneration still writes `d.dat`/`i.dat`/`o.dat` with no locals
  (claims nothing). CLI: `--no-cache` on `eco make`, threaded as one Bool through
  `Terminal/Make.elm`; `fe-loop-run.sh` gained `EXTRA_FLAGS` for this leg.
- **Verdict:** opt-in WIN, −6.87 s (−10 %) and −0.45 GB RSS on a cold self-compile, identical MLIR;
  the default path is flat. After the leg, `eco-stuff` held only `d.dat`/`i.dat`/`o.dat` (no
  per-module artifact). The remaining 6.6 s is what serialization still costs after S3 (encode +
  write of 8.7 MB of `.ecot` plus `.eci`). Not used by the bootstrap stages (R4).
- **Pending (batched):** G6 one-shot extension (`-n`: one-shot after A leaves `eco-stuff` unchanged
  and the next warm build equals A).

### S8: `variableToCanType` memo per naming scope (plan §5.8): **WIN, kept**

| run | wall (s) | parse/check/build (s) | mono (s) | MLIR codegen (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | `.ecot` (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | 64.74 | 23.4 | 23.3 | 12.0 | 3.38 | 1168 | 6 | 6392 | 6571668 | 13373511 | | same |
| r2 | 65.89 | 23.9 | 23.6 | 12.2 | 3.54 | 1168 | 6 | 6392 | 6522624 | 13373511 | | same |
| r3 | 64.95 | 23.4 | 23.5 | 12.1 | 3.41 | 1168 | 6 | 6392 | 6588780 | 13373511 | 8742299 | same |
| **median** | **64.95** | **23.4** | 23.5 | 12.1 | **3.41** | 1168 | 6 | **6392** | **6571668** | 13373511 | 8742299 | |
| Δ vs S4 (default leg) | **−3.42** | **−3.3** | 0.0 | 0.0 | −0.66 | −92 | 0 | **−1,338** | **−1,376,956** | (new source) | | |

- **Change:** `IO.NameState` gains `canMemo : Dict Int (Can.Type String)` (seeded empty by
  `emptyNameState`, `Type.makeNameState` and `Engine.freshStore`, so its lifetime is one
  `withFreshNames` scope). `variableToCanType` resolves `UF.repr` once and returns the memoized
  tree for that root; on a miss it converts as before and records structural nodes with children
  (`App1` with args, `Fun1`, `FunL`, `Record1`, `Tuple1`) and `Alias`; leaves are not memoized.
  Always on (no env switch: the loop's triple against the last kept compiler is the A/B).
- **Output gate (plan (c)) PASSED:** the fixed point holds (eco-optS8's output == the S4-built
  `ecoS8.mlir` of the same source), and `diff -r` of the `eco-stuff` trees produced by eco-optS4
  (phase 1.3) and eco-optS8 (run 3) on the same source is EMPTY: every `.ecot`/`.eci` byte is equal.
- **Verdict:** WIN on all three plan criteria: wall −3.42 s (far outside the 1.15 s band),
  parse/check/build −3.3 s (≥ 1.0 s), output identical.
- **Finding — the plan's premise was wrong in our favour:** §5.8 argued the sharing could not
  survive (stamping expands the DAG back into trees), so only transient allocation would be saved.
  Promoted −1.34 GB and peak RSS −1.38 GB say the sharing IS retained: the memoized subtrees live
  on in the stamped node types / typed graph until the module is written. The follow-on "memoize
  `stampArrowRoots` too" may add more; it was not part of this step.
- **Pending (batched):** G1 (plus the plan's `CanMemoTest`), G2, G4 fixed points, G5.

## 6a. Batched end-of-series gates (run once each, after S8)

- **G5 `TypedOptimizedCodecTest` (new):** 135/135 standard-suite modules round-trip the v2 codec
  (local and global re-encode idempotence, annotations equal, deterministic bytes, every
  super-prefixed `TVar` in the decoded type table is a `computeVarSupers` key).
- **G1 elm-tests (`--target elm-tests`, `/tmp/g1_elm_tests.txt`):** 13,730 passed, **12 failed —
  all PRE-EXISTING**: the same 12 (`GoldenConstraintTest` "if-chain" fingerprint; POST_010 ×6 and
  TYPE_007 ×5 orphan-TVar reports on if/binop nodes) fail identically on `keep-fe-S4` (S8 removed)
  and on `keep-fe-base` (the series start), 271 pass / 12 fail in all three trees. Not caused by
  this series; left for a separate investigation.
- **G6 `benchmarks/incremental-cache-check.sh -n synth` (new script, eco-optS8):** PASS (rc 0) in
  both modes: A0 == A, one-shot N/N1/N2 == A, and incremental B == cold C for touch/body/iface/
  sem/shape (sem and shape change the MLIR, so the check discriminates). Builddir mode passes,
  which is the S12b regression test (it failed at A0 before S12b per the plan's repro).
- **G2 first attempt: 944 E2E failures — a REAL S5 regression, now fixed.** Every guida-compiled
  test reported `NO MAIN` on a fresh build (cached rebuilds passed). Bisect over snapshots with
  guida: `keep-fe-base` ok, `keep-fe-S2` ok, `keep-fe-S5` NO MAIN. Root cause: in the JS build a
  `Build.Fresh` module crosses an MVar SERIALIZED (`moduleEncoder`), and
  `TOpt.localGraphEncoder` drops `main` by design (ECOT_001). S5 made `graphHasMain` read the typed
  graph's `main` because the erased graph became an empty stub, so in guida `main` was always
  `Nothing`; native MVars hold heap values, so the native self-compile and the S1+S2+S5 identity
  check (native only) could not see it. Fix: `Opt.typedPathStub hasMain` — the typed path's erased
  stub carries a presence-only `main = Just Opt.Static` marker (its codec keeps `main`), and
  `graphHasMain` accepts either graph. Repro output after the fix equals the baseline's (1,225 B).
  Snapshot `keep-fe-final`. **Lesson: a change to what crosses an MVar must be checked under the
  JS/xhr build too.**
- **G2 second attempt (with the S5 fix): 2,030 passed, 2 failed — both my new kernel tests.**
  (1) The JIT `test` runner never linked `EcoKernel_File` (no earlier E2E test used `Eco.File`):
  added to the whole-archive lists in `test/CMakeLists.txt` (3 platform branches).
  (2) `FileReadBytesRoundtripTest` then aborted on size 0: `writeBytesBody` (PRE-EXISTING) and
  `writeBytesAtomicBody` (copied it) called `Allocator::resolve` on the empty-`Bytes` embedded
  constant. Both now map a constant to `nullptr` (length 0); same line, so the File evidence line
  numbers are unchanged; manifest re-pinned. Re-run of the eco-kernel group: **16/16 pass.**
  **G2 is green.**
- **G4 bootstrap (`--target bootstrap`, `/tmp/g4_bootstrap.txt`): PASS** in 9 m 52 s — all 16
  steps incl. the Stage 4b JS fixed point and the Stage 8c native fixed point; `eco-verify` green.
- **G3 AOT E2E (`run-aot-e2e`, `/tmp/g3_aot.txt`, old `eco-stuff` moved aside): 902 passed, 2 failed
  — exactly the two known harness gaps (`FlagsRecordTest`, `PortEchoTest`; memory
  bootstrap-gate-b-aot-harness-gaps). PASS.**
- **G5 native cold→warm (Stage 9 `eco`): PASS** — cold 68.83 s, warm (decoding native-written v2
  caches) **43.35 s** / RSS 4.90 GB, identical MLIR.
- **G7 JS vs native `.ecot` bytes:** stress project (guida vs Stage 9 `eco`): all 4 `.ecot` + 4 `.eci`
  byte-identical. Large modules: see below.
- **G8 stale format: PASS** for the specified case — a project with an old compiler's v1 tree
  (`eco-stuff/0.1.1`) and v1 package caches builds cleanly with the new compiler (relocated to
  `0.1.2` by the S12a bump). **Follow-up (PRE-EXISTING, not fixed):** a corrupt `.ecot` placed in
  the CURRENT version dir (v1 bytes or 64 random bytes) makes the compiler SEGFAULT instead of
  recompiling or reporting CORRUPT CACHE — the series baseline `eco-optfe-base` segfaults the same
  way on random bytes in its own `0.1.1` dir. The version bump is what keeps format changes safe.
- **G9 license:** green (`kernel-license-check` in a full build after the S12c re-audit).

- **G7 large modules: PASS** — the Stage 5 JS compiler (`eco-boot-2-runner.js`, subst, 3 m 43 s)
  and the native Stage 9 `eco` wrote **276/276 byte-identical `.ecot`** for the compiler itself
  (largest: `Compiler-Reporting-Error-Syntax`, `Compiler-Generate-MLIR-Expr`,
  `Compiler-MonoSolver-Translate`). JS hash ≠ native hash never reaches the bytes.
- **G3 `run-mlir-equivalence` (`/tmp/g3_mlireq.txt`): 915 passed, 1 failed** — `elm/IntOverflowTest`:
  the literal `9223372036854775807` is emitted as `2048` by the JS-hosted Stage 2 compiler (a JS
  double cannot hold 2^63−1) and exactly by native Stage 6. JS-hosting limitation, independent of
  this series. **Follow-up (PRE-EXISTING, latent):** `.ecot` stores Int literals as float64 (v1 and
  v2; S10 left them alone), so a CACHED module with a literal beyond 2^53 decodes imprecisely even
  natively — a v3 candidate (`sintV` for Int literals).

## 6b. Series result

| | wall (s) | parse/check/build (s) | promoted MiB | max RSS (GB) | `.ecot` |
|---|---|---|---|---|---|
| fe-base | 108.44 | 64.8 | 20,506 | 11.86 | 449 MB |
| final (S8) | **64.95** | **23.4** | **6,392** | **6.57** | **8.7 MB** |
| final with `--no-cache` (S4 leg, measured on S4) | 61.85 | 20.1 | | | 0 |

**−43.49 s (−40.1 %)** on the cold self-compile with default flags; warm rebuild (G5) 43.35 s.
Plan goals: cold serialization ~40 s → what `--no-cache` saves is now 6.5 s (goal "< 6 s": just
short, measured as the whole S4 delta incl. writes); `.ecot` volume −98 % (goal ≥ 10×: met);
fixed points 4b/8c preserved (met). Every plan item was implemented and measured: WIN S1, S2, S3,
S8, S4 (flag), S9 (likely); FLAT kept S5, S12b, S11a, S11b+S12c, S11c; LOSS reverted S3k; S3p
folded into S3. Correctness gates G1–G9 pass, with these recorded exceptions, all PRE-EXISTING at
the series baseline or JS-hosting limits: 12 type-checker elm-tests, 2 AOT harness gaps,
`IntOverflowTest` in mlir-equivalence, and the corrupt-`.ecot` segfault (G8 follow-up). One real
regression found by the gates (S5 `main` lost through the JS MVar codec) was FIXED.

## 7. Findings

(Series-level findings are added here as they emerge.)

## 8. Provenance

- **Step list:** `plans/cache-serialization-optimization.md`. It was profiled, written, adversarially
  reviewed and lowered on 2026-10-03:
  - its §2 is the item table;
  - §5 has the per-item implementation specifications;
  - §5.0 records the cross-item decisions;
  - §1 lists the gates G1–G10 that §1 Phase 4 restricts per step.
- **Evidence behind the plan:**
  - `stats-backend-opt/boot-1003-1354/` (cold Stage 9b perf profiles with frame-pointer call graphs:
    `9b-fp.data`, `9b-stages.txt`, `ser-profile.txt`);
  - the `.ecot` decoder `/tmp/claude-1000/agentA/ecot.py`.
- **Method** inherited from `benchmarks/gc-opt-loop.md` §§1–5, which inherited it from
  `benchmarks/lss-compile-opt-loop.md`. Changes for this series:
  - its own `fe-base` baseline instead of inheriting `FHR`;
  - `--stats` on every timed run, with the front-end phase split as the primary stat;
  - the GC counters are recorded, not gated;
  - per-step gates are taken from the plan's G1–G10;
  - a labelled warm leg for the decode items.
- **Stat extraction:** `benchmarks/lss-loop-extract.sh <prefix>` (judged stats plus GC time and
  `out.mlir` bytes), plus the `--stats` phase lines from stderr.
- **Snapshot tool:** `benchmarks/lss-loop-snap.sh`. Snapshots ARE the loop's history, with the
  project's git history alongside them.

## 9. Summary


**Rows are INHERITED and kept whole**, so this loop's deltas sit on a continuous record:
- rows above `gcdef` come from `benchmarks/lss-compile-opt-loop.md` (the LSS compile-time series);
- `gcdef` to `FHR` come from `benchmarks/gc-opt-loop.md` (the GC series).

This series' baseline is `fe-base`; its rows are appended below `FHR`. From `fe-base` on, every run
has `--stats` on, and the front-end `parse / check / build` time is quoted in each row's entry.
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

Table conventions. `verdict` is WIN, FLAT (kept) or LOSS; LOSS covers every change not kept
(reverted, refuted, superseded, or a sweep that kept the existing value). `—` marks a row that is
not a step: the baseline, the drift checks and the closed-unbuilt W14. `-r` is a re-measure. The
walls of 14, 20, 13s and 16-D4 are approximate. From `drift-W13c` on, `delta (s)` is against a
same-sitting control run, not the `ref` row's recorded wall. Details live in each row's entry.

| step | wall (s) | delta (s) | minor GC | major GC | promoted MiB | max RSS (kB) | verdict | ref |
|---|---|---|---|---|---|---|---|---|
| base | 398.71 | — | 1825 | 10 | 20846 | 12708052 | — | — |
| 1 | 370.18 | -28.53 | 1825 | 10 | 20846 | 12705760 | WIN | base |
| 2 | 359.47 | -10.71 | 1821 | 10 | 20836 | 12690812 | WIN | 1 |
| 3 | 340.70 | -18.77 | 1583 | 10 | 20376 | 12457544 | WIN | 2 |
| 4b | 334.85 | -5.85 | 1600 | 10 | 20863 | 12711764 | WIN | 3 |
| 4a | 291.93 | -42.92 | 1312 | 10 | 20354 | 12026400 | WIN | 4b |
| 5a | 289.43 | -2.50 | 1287 | 10 | 20341 | 12048496 | WIN | 4a |
| 6 | 286.85 | -2.58 | 1281 | 10 | 20201 | 12052184 | WIN | 5a |
| 7 | 289.08 | +2.23 | 1280 | 10 | 20183 | 12044660 | WIN | 6 |
| 8a | 288.94 | -0.14 | 1291 | 10 | 20233 | 12118144 | LOSS | 7 |
| 8b | 287.24 | -1.84 | 1273 | 10 | 20207 | 12105460 | WIN | 7 |
| 9 | 289.18 | +1.94 | 1252 | 10 | 20269 | 12095116 | WIN | 8b |
| 11b | 278.11 | -11.07 | 1243 | 10 | 20284 | 12058368 | WIN | 9 |
| 11a | 277.42 | -0.69 | 1238 | 10 | 20301 | 12073940 | WIN | 11b |
| 14 | 279.4 | +1.98 | 1238 | 10 | 20301 | 12073960 | LOSS | 11a |
| 19' | 281.54 | +4.12 | 1239 | 10 | 20316 | 12134468 | LOSS | 11a |
| 22a | 278.01 | +0.59 | 1237 | 10 | 20293 | 12075144 | WIN | 11a |
| 16a | 276.01 | -2.00 | 1252 | 10 | 20317 | 12083308 | LOSS | 22a |
| 24(i) | 282.38 | +4.37 | 1250 | 10 | 20239 | 12028904 | LOSS | 22a |
| 12s | 275.58 | -2.43 | 1256 | 10 | 20292 | 12046092 | LOSS | 22a |
| 27 | 311.63 | +33.62 | 1310 | 11 | 20825 | 12048200 | LOSS | 22a |
| 20 | 279.0 | +0.99 | 1237 | 10 | 20293 | 12107848 | LOSS | 22a |
| 13s | 285.3 | +7.29 | 1262 | 11 | 20325 | 11988428 | LOSS | 22a |
| 23 | 280.87 | +2.86 | 1237 | 10 | 20255 | 12109264 | LOSS | 22a |
| 17 | 279.02 | +1.01 | 1262 | 10 | 20284 | 12090480 | LOSS | 22a |
| 16-D4 | 281.6 | +3.59 | 1238 | 10 | 20387 | 12120732 | LOSS | 22a |
| 15 | 280.81 | +2.80 | 1238 | 10 | 20318 | 12022700 | LOSS | 22a |
| 18b | 275.76 | -2.25 | 1237 | 10 | 20293 | 12126548 | WIN | 22a |
| 18a | 281.54 | +5.78 | 1259 | 10 | 20293 | 12130068 | LOSS | 18b |
| 22b | 278.43 | +2.67 | 1237 | 10 | 20335 | 11916868 | WIN | 18b |
| 22d | 270.19 | -8.24 | 1250 | 10 | 20004 | 10686984 | WIN | 22b |
| 22c | 274.37 | +4.18 | 1250 | 10 | 20000 | 11594052 | LOSS | 22d |
| 24(iii+iv) | 276.42 | +6.23 | 1248 | 10 | 19929 | 11513336 | LOSS | 22d |
| 24(i') | 270.59 | +0.40 | 1246 | 10 | 19962 | 11541556 | WIN | 22d |
| 21a | 275.46 | +4.87 | 1247 | 10 | 19966 | 11583856 | LOSS | 24(i') |
| 24(vii)a | 264.73 | -5.86 | 1243 | 10 | 19972 | 11562648 | WIN | 24(i') |
| 24(vii)b | 271.70 | +6.97 | 1243 | 10 | 19961 | 11563724 | LOSS | 24(vii)a |
| 24(ii) | 264.89 | +0.16 | 1241 | 10 | 19977 | 11529796 | WIN | 24(vii)a |
| 5b | 266.64 | +1.75 | 1214 | 10 | 20009 | 11486464 | LOSS | 24(ii) |
| 16-D10 | 272.88 | +7.99 | 1241 | 10 | 20079 | 11528320 | LOSS | 24(ii) |
| 24(v) | 272.09 | +7.20 | 1242 | 10 | 20061 | 11770580 | LOSS | 24(ii) |
| 25 | 265.28 | +0.39 | 1241 | 10 | 19982 | 11479276 | WIN | 24(ii) |
| 26a | 271.61 | +6.33 | 1248 | 10 | 19951 | 11529312 | LOSS | 25 |
| 10 | 237.17 | -28.11 | 1118 | 10 | 17482 | 10415980 | WIN | 25 |
| 16a-r | 237.27 | +1.82 | 1112 | 10 | 17404 | 10384340 | WIN | 10 |
| 12s-r | 234.76 | -2.51 | 1113 | 10 | 17600 | 10398400 | WIN | 16a-r |
| ghash | 234.40 | -0.36 | 1113 | 10 | 17633 | 10506704 | WIN | 12s-r |
| ghash63 | 239.13 | +4.73 | 1113 | 10 | 17633 | 10394976 | LOSS | ghash |
| gc-p1 | 235.60 | +1.20 | 1113 | 10 | 17633 | 10523820 | FLAT (kept) | ghash |
| gc-all | 235.80 | +1.40 | 1113 | 10 | 17634 | 10451604 | FLAT (kept) | ghash |
| gc-all2 | 229.55 | -4.85 | 1108 | 10 | 17599 | 10437876 | WIN | ghash |
| gcdef | 199.46 | -30.09 | 1924 | 6 | 19861 | 10816544 | WIN | gc-all2 |
| W0 | 198.43 | -1.03 | 1924 | 6 | 19861 | 10817408 | FLAT (kept) | gcdef |
| W1.1 | 198.65 | +0.22 | 1924 | 6 | 19861 | 10810956 | LOSS | W0 |
| W2 | 197.87 | -0.56 | 1924 | 6 | 19861 | 10816820 | FLAT (kept) | W0 |
| W3 | 201.55 | +3.68 | 1924 | 6 | 19861 | 10817360 | LOSS | W2 |
| W3' | 195.73 | -2.14 | 1924 | 6 | 19861 | 10816696 | FLAT (kept) | W2 |
| W4 | 199.13 | +3.40 | 1924 | 6 | 19861 | 10816228 | LOSS | W3' |
| W5 | 196.17 | +0.44 | 1924 | 6 | 19861 | 10805896 | WIN | W3' |
| W10 | 197.02 | +0.85 | 1924 | 6 | 19861 | 10805692 | FLAT (kept) | W5 |
| W9 | 197.18 | +0.16 | 1924 | 6 | 19861 | 10805240 | FLAT (kept) | W10 |
| W7 | 194.64 | -2.54 | 1924 | 6 | 19861 | 10805292 | FLAT (kept) | W9 |
| W6 | 272.17 | +77.53 | 1924 | 6 | 19861 | 14389864 | LOSS | W7 |
| W1 | 183.82 | -10.82 | 1924 | 6 | 19861 | 10677000 | WIN | W7 |
| W1b | 183.57 | -0.25 | 1924 | 6 | 19861 | 10676096 | FLAT (kept) | W1 |
| W11a | 182.95 | -0.62 | 1924 | 6 | 19861 | 10676200 | FLAT (kept) | W1b |
| W11b | — | — | — | — | — | — | LOSS | W11a |
| W12 | 183.58 | +0.63 | 1924 | 6 | 19861 | 10848384 | LOSS | W11a |
| W12b | 181.12 | -1.83 | 1924 | 6 | 19861 | 10743152 | WIN | W11a |
| W12c | 182.56 | +1.44 | 1924 | 6 | 19861 | 10742676 | LOSS | W12b |
| W13 | 181.71 | +0.59 | 1924 | 6 | 19861 | 10742504 | WIN | W12b |
| W12d | 180.91 | -0.80 | 1924 | 6 | 19861 | 10697572 | LOSS | W13 |
| W14 | — | — | — | — | — | — | — | W13 |
| drift-W13 | 181.57 | -0.14 | 1924 | 6 | 19861 | 10742964 | — | W13 |
| W13c | 180.08 | -1.63 | 1924 | 6 | 19861 | 10743276 | WIN | W13 |
| W13d | — | — | 1924 | 6 | 19861 | — | LOSS | W13c |
| W13e | 179.52 | -0.56 | 1924 | 6 | 19861 | 10743272 | LOSS | W13c |
| W13f | 187.66 | +7.58 | 1924 | 6 | 19861 | 10743048 | LOSS | W13c |
| W13g | 181.57 | +1.49 | 1924 | 6 | 19861 | 10741472 | LOSS | W13c |
| W13h | — | — | 1924 | 6 | 19861 | — | LOSS | W13c |
| drift-W13c | 181.86 | +1.78 | 1924 | 6 | 19861 | 9726024 | — | W13c |
| T00 | 184.71 | +2.85 | 1924 | 6 | 19861 | 9726340 | FLAT (kept) | W13c |
| T01 | 183.86 | +2.31 | 1924 | 6 | 19861 | 9725408 | FLAT (kept) | W13c |
| TG1 | 181.61 | -3.73 | 1924 | 6 | 19861 | 9664108 | FLAT (kept) | T01 |
| TG2 | 180.97 | -2.40 | 1924 | 7 | 19861 | 9622612 | WIN | TG1 |
| TG3 | 172.67 | -8.54 | 1924 | 7 | 19861 | 9770964 | WIN | TG2 |
| TG4 | 172.77 | -1.96 | 1924 | 7 | 19861 | 9776948 | FLAT (kept) | TG3 |
| TG4b | 170.70 | -3.72 | 1924 | 7 | 19862 | 9781300 | FLAT (kept) | TG4 |
| TG5a | 170.20 | -0.80 | 1924 | 7 | 19862 | 9844144 | WIN | TG4b |
| TG5b | 163.90 | -5.84 | 1924 | 7 | 19862 | 9845612 | WIN | TG5a |
| TG5c | 162.60 | -0.99 | 1924 | 7 | 19862 | 9849108 | WIN (pause) | TG5b |
| TG6 | 123.30 | -39.30 | 1924 | 8 | 19862 | 12426732 | WIN (wall, pause; retention gate overridden) | TG5c |
| TG7d | 112.09 | -11.21 | 1924 | 8 | 19862 | 13359864 | WIN (wall, pause; keep-up gate overridden) | TG6 |
| TA | 119.60 | +7.51 | 1924 | 7 | 18476 | 11982016 | LOSS (k = 2, v1) | TG7d |
| TA2 | 112.45 | +0.36 | 1924 | 8 | 19862 | 13349532 | FLAT (kept, k = 1; k = 2 118.11 / k = 3 123.39 LOSS) | TG7d |
| SG4 | 106.54 | -5.91 | 2521 | 8 | 20320 | 12985716 | WIN (incl. untracked 09-29 nmbc384/sfl128K; granule alone FLAT wall, RSS -446 MB, CPU -4.4 s) | TA2 |
| LB3 | 106.42 | -0.12 | 2521 | 10 | 20320 | 10870280 | WIN (flat wall, RSS -2.12 GB / -16.3 %, worst pause 115 -> 86 ms, p50-p99.9 unchanged; incl. untracked bug-2 fix, inert here) | SG4 |
| REGFIX | 106.50 | +0.08 | 2521 | 10 | 20320 | 10864068 | FLAT (kept; correctness: register fixes; counters identical, output identical; E2E 2003/2003) | LB3 |
| FHR | 107.04 | +0.54 | 2558 | 11 | 20525 | 9840052 | WIN (flat wall, RSS -1.02 GB / -9.4 %, old-gen peak -976 MB; Stage 9b peak 15.27 -> 9.73 GB; gates INCOMPLETE, not promoted) | REGFIX |
| fe-base | 108.44 | — | 2533 | 11 | 20506 | 11859508 | — (baseline; parse/check/build 64.8 s) | — |
| S1 | 98.41 | -10.03 | 1671 | 11 | 20631 | 12953596 | WIN (parse/check/build 64.8 -> 54.5 s; RSS +1.09 GB) | fe-base |
| S2 | 94.03 | -4.38 | 1644 | 11 | 20554 | 10972828 | WIN (parse/check/build 54.5 -> 50.8 s; RSS -1.98 GB) | S1 |
| S5 | 93.19 | -0.84 | 1642 | 11 | 20395 | 11007760 | WIN (rule 2: flat wall, promoted -159 MiB; parse/check/build 50.2 s; S1+S2+S5 artifacts byte-identical) | S2 |
| S3 | 69.83 | -23.36 | 1235 | 7 | 7710 | 7530584 | WIN (.ecot v2 type table + varints; parse/check/build 50.2 -> 27.0 s; .ecot 449 -> 8.7 MB; RSS -3.3 GB) | S5 |
| S3k | 71.03 | +1.20 | 1235 | 7 | 7709 | 7535932 | LOSS (native deepWith hash; +0.5 s vs same-session S3 control 70.50; reverted) | S3 |
| S12b | 70.20 | +0.37 | 1235 | 7 | 7710 | 7539920 | FLAT, kept (builddir artifact-path correctness fix + deletions) | S3 |
| S11a | 69.94 | -0.26 | 1260 | 7 | 7738 | 7552548 | FLAT, kept (decode-only string table; BD.loop fixes JS overflow at 70k strings) | S12b |
| S11b+S12c | 70.16 | +0.22 | 1260 | 6 | 7732 | 7942236 | FLAT, kept (direct readBytes + atomic writes, eci-first; RSS +0.39 GB with one fewer major) | S11a |
| S11c | 69.64 | -0.52 | 1260 | 6 | 7732 | 7950440 | FLAT, kept (no malloc snapshot for non-heap leaf sources) | S11b+S12c |
| S9 | 68.72 | -0.92 | 1260 | 6 | 7732 | 7939556 | kept, likely WIN (triples non-overlapping; MLIR codegen -1.0 s; inside band) | S11c |
| S4 | 68.37 | -0.35 | 1260 | 6 | 7730 | 7948624 | FLAT default leg; kept for the flag | S9 |
| S4 --no-cache | 61.85 | -6.87 | 1217 | 7 | 7694 | 7499908 | WIN when used (opt-in one-shot; parse/check/build 27.0 -> 20.1 s) | S9 |
| S8 | 64.95 | -3.42 | 1168 | 6 | 6392 | 6571668 | WIN (canType memo; parse/check/build 26.7 -> 23.4 s; promoted -1.34 GB; RSS -1.38 GB; .ecot/.eci byte-identical) | S4 |
