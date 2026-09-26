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

**THE FOLLOW-UP PLAN IS NOW COMPLETE (2026-09-23). Every one of its eleven items is
dispositioned; see the W11-W14 table below and the entries in §6.** Two wins landed
(item 40 and item 54), three items shipped flat-or-closed by reading, and four were refuted
or closed on arithmetic. The series' last WIN is **W13c (180.08 s)**; the reference snapshot is
`keep-W13d` (W13c's code plus the sweep's documentation, `.text` identical) and `bin/eco-opt-prev`
is `bin/eco-optW13d`.

| package | items | outcome |
|---|---|---|
| W11a | 51, 43 | FLAT, kept (deletions). 43's write site in the plan was WRONG — see §6 |
| W11a | 47 | CLOSED UNBUILT by reading: the `find` is load-bearing |
| W11b | 44 | **REFUTED by its own validate assert** — the bulk clear is load-bearing for an undocumented second reason |
| W12b | 40 | **WIN, kept** (-1.83 s wall, -0.78 s GC). Needed an arena re-pack the plan did not anticipate |
| W12c | 52 | NO WIN, reverted (mark +33 ms) |
| W12d | 38 | NO WIN, reverted (mark +415 ms) — sparse set beats span-wide bitmap |
| W13 | 54 (prefetch-on-grey) | WIN, kept (mark -141 ms) — later SUPERSEDED by W13c |
| W13c | 54 (FIFO ring, depth 16) | **WIN, kept — mark -789.6 ms (-10.4 %) vs on-grey, -12.1 % vs none; output byte-identical** |
| W13d | 54 depth sweep 4/8/16/32/64 | **16 CONFIRMED OPTIMAL** — depth 4 is +23 % WORSE than no prefetch at all |
| W14 | 42, 45, 46 | CLOSED UNBUILT, bounded at <1 % of wall by the event log |

The original continuation notice follows.

**THE SERIES WAS LIVE AND THE NEXT STEPS WERE IN
`plans/gc-mark-and-bookkeeping-followup.md`.** `plans/gc-tier1-constant-factors.md` is
CLOSED — every package below has an entry in §3 except **W8, which was never run**, and W9's
items 42-47, which were never attempted. The follow-up plan lowers exactly those eleven items
(38, 40, 51, 52, 54, 42-47) to implementation detail, re-verified against the tree on
2026-09-23, and regroups them as **W11-W14**. Its reference row is `W1b` (183.57 s), and it is
run through THIS file's method unchanged.

Read the follow-up plan's §0 before picking a step: **W1 overturned this loop's closing
conclusion** that constant-factor work was exhausted, by finding -14.54 s of GC time after
eleven packages had bought ~4 s between them. Its §1 also carries the ordering rule this
series established — pure deletions have been flat-to-positive every time, and
restructure-to-remove-a-scan has lost all three times it was measured.

The original step list was `plans/gc-tier1-constant-factors.md` — its "Work packages, in
landing order" table, in that order. **One package per iteration**, named by its `W` number; a package the plan
itself sub-numbers (`W1.1`, `W1.2`, `W1.3`, `W4(29,31)` vs `W4(32)`, `W5(53)`) splits into one
entry per sub-number, because §5's one-step-per-iteration rule applies to items, not to the
plan's grouping.

| step | package | items | basis | risk | outcome |
|---|---|---|---|---|---|
| base | *(no change — the `gcdef` tree; INHERITED, not re-measured)* | — | — | — | — |
| W0 | Free deletions | 11,12,13,27,39,48,49,50 | bound | trivial | FLAT, kept (11/12 refuted) |
| W1 | Nursery zeroing | 6,7,8,9 | **5.6 % CPU, measured** | medium | **WIN** (6 LOSS; 7 shipped; 9 done in W1b; **8 untried**) |
| W2 | `evacuate` inner loop | 16–23 | bound | low | FLAT, kept (23 refuted) |
| W3 | Per-object dispatch | 24–28 | bound | low | 24 LOSS; 28 kept; 25/26 closed |
| W4 | Slot scanning | 29–31 (**32 gated**) | bound | medium | LOSS, reverted; 32 closed |
| W5 | Minor-GC structure | 33,34,35,37,53,55 (**36 closed**) | bound | low | WIN on RSS, kept |
| W6 | Old-gen virgin-page bump | 10, 15 (counter first) | bound | medium | 10 LOSS; **15 never reached** |
| W7 | Promotion-path sweep coupling | 14 | measured outlier | medium | knob kept at default |
| W8 | Mark-side data structures | 38,40,51,52,54 | bound | medium | **NEVER RUN → follow-up W12/W13** |
| W9 | Old-gen bookkeeping | 41–47 | bound | low | 41 kept; **42–47 never attempted → follow-up W11/W14** |
| W10 | Stackmap lookup | 56 | bound | low | FLAT, kept |

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
> - **GC time and the GC counters do the discriminating.** The counters are exact per
>   (binary × tree), so any movement in them is real; GC time is far tighter than wall because it
>   excludes the front-end and I/O drift. Lead every entry with GC time (§3);
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


### W11a — item 51 (inline `isInNursery`) + item 43 (skip the sentinel walk) — **FLAT, kept**

First package of `plans/gc-mark-and-bookkeeping-followup.md`. Both items are deletions; item 47
was closed by reading before any build (below). Patch `step-W11a.patch`, 121 lines, 4 files; tree
`try-W11a`. Runtime-only, so Phase 1.3 was skipped and `bin/ecoghash.mlir` was lowered again
against the changed runtime.

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 184.18 | 68.65 | 1924 | 6 | 19861 | 10,675,708 | 13,241,185 | same |
| r2 | 182.06 | 67.91 | 1924 | 6 | 19861 | 10,676,200 | 13,241,185 | same |
| r3 | 182.95 | 68.45 | 1924 | 6 | 19861 | 10,676,460 | 13,241,185 | same |
| **median** | **182.95** | **68.45** | 1924 | 6 | 19861 | **10,676,200** | 13,241,185 | same |
| Δ vs `W1b` | **-0.62** | **+0.29** | 0 | 0 | 0 | +104 | 0 | — |

Wall spread 2.12 s; both moves are deep inside the band, so **FLAT** in the sense §1's Phase 2
now defines — not a small win and not a small loss. Counter gate holds to the digit, deterministic,
fixed point green, no `[gc-stats] SIG` on any leg. **Gates:** E2E `--target check` **1730/1730**,
heap-validate `--target check` **1730/1730**. Kept under the flat-deletions-ship rule.

**Item 51 — the plan's premise was right.** `isInNursery` is called twice per marked object
(`OldGenSpace.cpp:1810` `pushMarkRoot`, `:1865` `markOneObject`) and was an out-of-line cross-TU
call wrapping two range compares. Moved into `Allocator.hpp` beside `getRootSet()`, which is there
for the same reason (needs complete `ThreadLocalHeap`). Null check kept — cold callers run before
`initThread`. Unmeasurable at this scale, as predicted.

**Item 43 — PREMISE CORRECTED, and following the plan literally would have introduced a bug.**
The plan states *"There is exactly ONE write site (verified 2026-09-23): `OldGenSpace.cpp:2407`"*.
There are TWO, and 2407 is the wrong one:

- `:2341`, inside `placeAndLink`, writes `cell->header.age = age_sentinel ? 0b01 : 0` on every cell
  it LINKS onto a free list. These are the cells the `transitionToSweeping` walk visits.
- `:2407` writes the trailing-remainder header, which is left parseable for sweep but is **never
  linked onto any list**, so it can never appear in that walk.

A counter incremented at `:2407` would therefore read zero while real sentinels sat on the lists;
the walk would be skipped, the sentinels would survive the head wipe, and lazy sweep would treat
each as a hard run boundary and leak its bytes — silently. (`setFreeCellSentinel` /
`clearFreeCellSentinel` at `OldGenSpace.hpp:189-194` have NO callers, so there is no third path.)

What was built instead counts sentinel **push calls**, at the two sites that can pass
`age_sentinel=true` (`splitter::remainder` `:1086`, `freeLargeBodyCell` `:4536`), both of which are
`OldGenSpace` members so the counter is reachable. One call can link several cells, so the count
**over-counts** — the safe direction the plan asked for, since the walk is skipped only on an exact
zero. `transitionToSweeping` resets it to 0 after the walk, so it cannot drift across cycles, and
`reset()` clears it.

**Item 43 may be entirely inert and this run cannot tell.** The walk runs ~6 times per self-compile
and the skip fires only in a cycle with zero sentinel pushes; `freeLargeBodyCell` runs whenever a
split-header body dies, so cycles with a sentinel are probably the common case. GC time moved
+0.29 s, i.e. nothing. It is kept as a correct deletion of an O(free cells) walk from the major-GC
prologue, not on evidence that it fires. Anyone wanting that evidence needs a counter print in a
separate untimed leg — do not infer it from a wall number.

**Item 47 — CLOSED UNBUILT, resolved by reading (the plan's preferred outcome).** The question was
whether a pinned body cell can reach sweep with a live `large_body_index_` entry. It can.
`OldGenSpace.cpp:4278` computes `body_is_large = (total_size >= config_->alloc_buffer_size)`, so a
split-header body BELOW that threshold is allocated into an ordinary size-class block and is swept
by the inner loop at `:2685` — the copy the plan hoped to retire — not by the `is_large` branch at
`:2640`. The comment at `:2632` asserts major sweep can reach a body cell first when its only
nursery header died, and dropping the erase would leave a stale id to clash with a recycled cell.
`OldGenSpace.hpp:568`'s "defensive idempotent guards only" is about ACCOUNTING authority
(`freeLargeBodyCell` owns `garbage_bytes`), not about reachability — reading it as the latter is
what made this item look free. The `find` already runs only for a pinned `Tag_String`/`Tag_ByteBuffer`
cell in a dead block, which was the plan's own premise correction; that correction was the entire
win available here, and it is already in the tree.


### W11b — item 44 (stop bulk-zeroing the mark bitmaps) — **REFUTED, reverted, never measured**

The plan's highest-value item, and the one it called *"structurally the same shape as the W1 win:
delete a bulk memset that a per-item path already covers."* **The per-item path does not cover it.**
No timed triple was ever run: the item died on its correctness gate. Patches `step-W11b.patch`
(154 lines); trees `try-W11b` (first form) and `try-W11b-final` (the inverted form below).

**What was built.** Two forms, both replacing the `std::fill` over every `mark_bits_[i]` at the
start of each mark cycle with a targeted clear of blocks flagged in a new per-block
`marks_dirty_` vector. Both kept `large_block_mark_`'s bulk clear (one byte per block, not a
bitmap). Both carried the gate the plan asked for: an `ECO_HEAP_VALIDATE`-only pass that
re-derives the deleted invariant — after the targeted clear, EVERY bitmap must be all-zero.

1. **Predictive form.** Flag at the mark-bit set site when the current cycle's sweep would not
   reach the block. **Aborted on the 2nd major GC of the self-compile.**
2. **Observational form.** Flag inside `setMarkBitInBlock` itself, so no caller can forget, and
   clear the flag in `markBlockFullySwept` — the only place that records "the sweeper walked this
   block to completion". **Aborted on the 2nd major GC of the self-compile, identically.**

**The evidence** (form 2, `eco-optW11b-val`, a heap-validate lowering of the same MLIR):

```
[heap-validate] item 44: carry-over mark bit
  block=1 byte=371 bits=0x10 obj=0x10000f05ce0
  block: start=0x10000f00000 end=0x10000f80000 eoo=0x10000f80000 is_large=0 size_class=40
  meta: fully_swept=1 live=18880 garbage=531928
  sweep: phase=0 buffer_index=285 pending=0
  header at obj: tag=3 size=8828 age=0 pin=1 color=2
```

`size_class=40` is `NUM_SIZE_CLASSES` (`NUM_SMALL_CLASSES=32` + 8 medium), i.e. a **mixed** block,
which sweep walks object-by-object rather than on a fixed stride. `fully_swept=1` with
`pending=0` says **the sweeper walked that block to completion in the previous cycle and still
left a mark bit set** on a pinned `Tag_String` split-header body (tag 3 = `Tag_String`, `pin=1`,
logical size 8828 — the `registerLargeBody` path, a body below `alloc_buffer_size` that lands in
an ordinary block rather than an `is_large` one; see item 47's entry in W11a).

**So the item's premise is false, and not in the way the code documents.** `OldGenSpace.cpp:1560`
lists exactly one reason the "bitmap is zero between cycles" invariant fails — a mid-cycle
free-list pop into a block sweep has already passed — and both forms handled that reason. There is
a SECOND path that leaves a set bit in a block sweep walked to completion. The bulk clear is
load-bearing for it. Its exact mechanism is unidentified; the candidates the evidence allows are
the sentinel arm of the sweep inner loop (`:2675`, which by contract does not touch the cell's
header or its bit and relies on `freeLargeBodyCell` having cleared it) and a cursor/footprint
disagreement on a pinned body whose `header.size` is the LOGICAL length, not the cell footprint.

**Why it is closed rather than pursued.** The failure is silent in a release build — a carry-over
bit makes `pushMarkRoot` return early, `markOneObject` never attributes the cell's bytes, the
block reads all-dead, and `madvise(DONTNEED)` zero-fills pages live objects still reference. Every
probe costs ~13 min (validate lowering + self-compile to the 2nd major). And the prize was never
large: the plan's own arithmetic is ~80 MB of bitmap per major, ~6 majors, **"expect flat on
wall"** — two orders of magnitude below W1's 246 GB. A provably-safe variant does exist (never
clear the flag at sweep completion, so "dirty" means only "a bit was set since the last prologue")
but it degenerates to flagging every block that holds a marked object, which is nearly all of
them; it would ADD state for no deletion, so it does not qualify under the flat-deletions-ship
rule.

**This makes it 4-for-4: restructure-to-remove-a-scan has now lost every time it was measured**
(item 24 +3.16 s GC, W4 +1.96 s GC, W6 +77.5 s wall, and W11b refuted before measurement), against
5-for-5 flat-to-positive for pure deletions. The follow-up plan's §1 ordering rule holds.

**The validate assertion is the transferable result.** It was written to test an analysis and
instead found the analysis wrong, twice, in under an hour — including catching that my first form
had missed `pushMarkRoot` as a second mark-bit writer. Anyone re-opening 44, or attempting
working-list #58 (atomic mark-bit set for parallel marking, which inherits this invariant), should
re-add it first: it is in `try-W11b-final`'s `startMark`, guarded by `ECO_HEAP_VALIDATE`.

**Incidental finding: `--target ecor` does not link in `build-validate`** (`undefined symbol:
Elm::PermanentSpace::instance()`), which is pre-existing and harmless in itself — but ninja stops
on it, so `libEcoRuntimeStatic.a` is left STALE and the next lowering silently tests old code. One
13-min cycle was lost to this. Build `--target EcoRuntimeStatic` explicitly (or `--target check`)
before lowering a validate candidate, and check the archive's mtime.


### W12 / W12b — item 40 (flatten `mark_bits_` into an arena) — **W12 NO WIN; W12b WIN, kept**

The gate item: working-list #58 (atomic mark-bit set for parallel marking) needs a flat array,
because a `lock or` on an element of a `vector<vector<uint8_t>>` means resolving the inner pointer
under contention. Patches `step-W12.patch` (278 lines) and `step-W12b.patch`; trees `try-W12`,
`try-W12b`.

**Change.** `std::vector<std::vector<uint8_t>> mark_bits_` becomes one `mark_bits_arena_` plus
per-block `mark_bits_offset_` / `mark_bits_len_`. Each bit operation loses a dependent load and a
bounds branch. `pushMarkRoot`'s `isMarkedInBlock` + `setMarkBitInBlock` pair collapses into one
`testAndSetMarkBitInBlock`, which is half the win and only worth fusing once the lookup is cheap.
Bit layout and `MARK_ALIGNMENT` unchanged — container only, so bitmap CONTENT is bit-identical.

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|
| W12 median | 183.58 | 68.40 | 1924 | 6 | 19861 | 10,848,384 | 13,241,185 | same |
| Δ vs `W11a` | +0.63 | -0.05 | 0 | 0 | 0 | **+172,184** | 0 | — |
| W12b r1 | 181.12 | 67.71 | 1924 | 6 | 19861 | 10,745,344 | 13,241,185 | same |
| W12b r2 | 181.14 | 67.45 | 1924 | 6 | 19861 | 10,743,020 | 13,241,185 | same |
| W12b r3 | 180.97 | 67.67 | 1924 | 6 | 19861 | 10,743,152 | 13,241,185 | same |
| **W12b median** | **181.12** | **67.67** | 1924 | 6 | 19861 | 10,743,152 | 13,241,185 | same |
| **Δ vs `W11a`** | **-1.83** | **-0.78** | 0 | 0 | 0 | +66,952 | 0 | — |

**W12 was flat on wall and +172 MB of RSS — and the RSS was my defect, not the item's.** The arena
is append-only, and `releaseBlock` moves a block's arena SLOT rather than its bytes, so every
released block leaves a hole that never comes back. Over a self-compile the holes reached 172 MB.

**W12b adds one thing: re-pack the arena at the mark prologue.** That is the single point in the
cycle where it is free — every bitmap is about to be zeroed, so no content needs preserving and
the offsets can simply be reassigned in place, O(#blocks), six times per run. With `resize()` never
returning capacity, it also calls `shrink_to_fit()` once the excess is worth a reallocation.

Result: **wall -1.83 s on a spread of 0.17 s** (the tightest triple in the series — ten times the
spread), **GC time -0.78 s**, counters bit-identical, deterministic, fixed point green. **Gates:**
E2E `--target check` **1730/1730** and heap-validate `--target check` **1730/1730** — the plan makes
heap-validate mandatory for this package. WIN under rule 1, kept.

Residual: RSS is still +67 MB against W11a. The arena for a ~5 GB old gen is ~78 MB contiguous,
where the vector-of-vectors spread the same bytes over ~80 K separate allocations; the peak moves
even though the total does not. Wall decreased, so rule 1 applies whatever the other stats did.

**PREMISE CORRECTED: there are TWO block-removal paths, not one.** The plan's trap list names
`releaseBlock`'s swap-remove (`:3375`). Compaction ALSO removes blocks, at `:4190`, with
`vector::erase` over a descending-sorted evacuation set — indices shift rather than swap. Both are
mirrored here. A container change that handled only the swap-remove would have desynchronised
`mark_bits_offset_` from `blocks_` after any compaction, silently pointing every later block at
another block's bitmap.

The plan's other traps held: the two test accessors (`getMarkBitsForBlock`, `getMarkBits`) still
have no users outside the header, so they collapse to one pointer+length view; and the
`byte_index >= bits.size()` guard is preserved as `byte_index >= mark_bits_len_[i]` — it is
load-bearing for objects outside a block's bitmap extent, not dead defensiveness.


### W12c — item 52 (last-block `live_bytes` accumulator) — **NO WIN, reverted**

`markOneObject` did `buffer_meta_[blk].live_bytes += step` per marked object; the plan calls that
"a third random cache line touched per object" and prescribes option (a), a last-block cache
flushed on block switch. Built exactly so, flushed additionally at every `incrementalMark` return
(the plan's trap: `initObjectHeaderWithSize` and `allocateFromEmptyRegularBlocks` also write the
field). Patch `step-W12c.patch`; tree `try-W12c`.

| run | wall (s) | GC time (s) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|
| r1 | 182.56 | 68.14 | 1924 | 6 | 19861 | 10,742,676 | same |
| r2 | 180.06 | 67.44 | 1924 | 6 | 19861 | 10,743,096 | same |
| r3 | 183.30 | 68.43 | 1924 | 6 | 19861 | 10,740,704 | same |
| **median** | **182.56** | **68.14** | 1924 | 6 | 19861 | 10,742,676 | same |
| Δ vs `W12b` | +1.44 (spread 3.24) | +0.47 | 0 | 0 | 0 | -476 | — |

**Judged on mark time, not on wall or total GC time.** This entry introduces the instrument the
rest of the mark-path items should use: the **Major GC Event Log** already printed in the banner
gives per-collection `mark` and `sweep` columns, so the quantity an item targets can be read
directly instead of through 181 s of wall or 68 s of GC time dominated by the 1924 minor cycles.

| arm | mark (median of 3) | major | sweep |
|---|---|---|---|
| W12b | 7713.3 ms | 8472.8 ms | 507.6 ms |
| W12c | **7768.3 ms** | 8525.9 ms | 515.7 ms |

**+55 ms of mark time across 186,597,868 marked objects = +0.29 ns per object.**

> **NUMBERS CORRECTED 2026-09-23.** This entry first reported 7315.0 / 7348.3 ms. Those came from
> an extractor that took the last six LINES of the event-log block — which is the last four
> collections plus two footer lines counted as zero — so the first two collections (~360 ms) were
> dropped from every arm. The extractor was applied identically to every arm, so all DELTAS and
> all verdicts in this series are unaffected; only the absolute mark totals were understated.
> Correct form: take the six lines following the `at(s) total mark` header. Every mark figure in
> §6 and §7 has been recomputed. The accumulator
does not pay for itself, and the premise is refuted: `buffer_meta_` is ~2 MB and the mark stack
has strong per-block run locality (survivor copying groups objects by block), so that "third
random cache line" was already resident in L1/L2. There was no miss to remove — only a branch to
add. Reverted; it is a restructure that adds state, so the flat-deletions-ship rule does not
apply.

**Restructures are now 0 for 5** (item 24, W4, W6, W11b, W12c) against 5 for 5 flat-or-better for
deletions, and 1 clear win for item 40 — which was a container change that REMOVED a dependent
load rather than adding a cache.

**Sizing for everything that remains, from the same banner** (W12b, r1): the six majors cost
**8.05 s total, 7.32 s of it mark**, in a 181.12 s run — mark is 4.0 % of wall. 186.6 M objects
popped from the mark stack ⇒ **39 ns per marked object**, which for a bitmap test plus a header
read plus child pushes is dominated by memory latency, not instruction count. That is why
instruction-shaving items (52 here) measure flat while a latency item (54, prefetch) still has
headroom, and it caps ANY remaining mark-path item at well under 7.32 s.


### W13 — item 54 (prefetch-on-grey) — **WIN on mark time, flat wall, kept**

The plan's cheaper variant: issue the prefetch when an object is greyed (pushed) rather than
building a FIFO between pop and scan. Nothing on the push path dereferences the object —
`isInNursery`, `contains`, `blockIndexFor` and the mark bit are all side tables — so the header is
first touched after the pop, in `markOneObject`. Two `__builtin_prefetch(obj, 0, 3)` calls, one on
each push path. **No reordering, so emission is byte-identical by construction** (the plan's first
trap, which the FIFO variant would have risked). Patch `step-W13.patch`; tree `try-W13`.

| run | wall (s) | GC time (s) | mark (ms) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 178.99 | 66.71 | — | 1924 | 6 | 19861 | 10,743,636 | same |
| r2 | 181.71 | 67.83 | 8238.1 | 1924 | 6 | 19861 | 10,741,768 | same |
| r3 | 181.85 | 67.19 | 7504.7 | 1924 | 6 | 19861 | 10,742,504 | same |
| drift triple | 181.57 (med) | 67.50 (med) | **7572.4** (med) | 1924 | 6 | 19861 | 10,742,964 | same |
| **median** | **181.71** | **67.19** | **7572.4** (drift) | 1924 | 6 | 19861 | 10,742,504 | same |
| Δ vs `W12b` | +0.59 (spread 2.86) | **-0.48** | **-140.9** | 0 | 0 | 0 | -648 | — |

(Mark figures corrected — see the note in W12c. r1's artefacts were overwritten by the drift
re-measure of this same binary, so the drift triple is quoted as this arm's mark reference; it is
the same binary measured three times, between W12d and W13c.)

Wall is FLAT (+0.59 inside the 2.86 s band) and, on the triple alone, the mark median moves -202 ms
with a 781 ms spread — not resolvable by itself. **The per-collection columns of the Major GC Event
Log resolve it**, because each run reports six collections and they can be paired across arms:

| collection | W12b (r1/r2/r3) | W13 (r1/r2/r3) |
|---|---|---|
| 5th | 1832.4 / 1837.0 / 1839.4 | **1769.7 / 1791.8 / 1790.7** |
| 6th | 3004.7 / 2989.2 / 3176.2 | **2883.6 / 2917.4 / 2887.1** |

On the two collections that dominate mark time, **every W13 run beats every W12b run** — complete
separation, six samples, no overlap. The smallest collection goes the other way (543.8/538.9/540.6
→ 547.4/550.1/549.0, about +8 ms): prefetch overhead with nothing to hide, which is the shape the
effect should have. r2's 2581 ms outlier on the 2nd collection is what inflates the triple's
spread; the pairing shows it is an outlier, not the signal.

Counters bit-identical, deterministic, fixed point green. **Gates:** E2E `--target check`
**1730/1730**, heap-validate `--target check` **1730/1730**. Kept.

**DISPOSITION CONFLICT, recorded because it changes the verdict.** The follow-up plan's §6 says
*"Flat restructures do not [ship] — 52 and 54 are reverted unless they move GC time outside the
2σ = 5.3 s band."* Item 54 moves GC time 0.48 s, far inside it, so that rule alone says revert.
**The rule cannot apply to a mark-path item.** The 5.3 s band is the 2σ of TOTAL GC time, which is
dominated by 1924 minor collections; the entire major-GC budget is 8.05 s and mark is 7.32 s of it,
so no change to mark could ever move total GC time by 5.3 s. Applying that bar to W12/W13 would
make every item in both packages unmeasurable by construction, including item 40, which won.
Judged instead on the quantity the item targets, with six paired samples showing complete
separation on the dominant collections. It is kept on that basis, and because it adds two
instructions and no state: if a later reader prefers the plan's literal rule, reverting is one
`restore keep-W12b` and costs nothing else.

**This is the only latency item in the follow-up plan, and it is the only one of 38/52/54 that
paid.** At 39 ns per marked object, mark is memory-latency-bound, so shaving instructions (52)
measures flat while hiding a miss does not. The plan's own disposition risk — "add work to save
misses, the class that has lost twice" — was right about the FIFO variant and wrong about
prefetch-on-grey, because the cheap variant adds an instruction, not a data structure.


### W12d — item 38 (`nursery_visited_` set to bitmap) — **NO WIN, reverted**

Replaced `std::unordered_set<void*> nursery_visited_` with a bitmap over the calling thread's
nursery span, one bit per `MARK_ALIGNMENT` slot. Needed two new accessors: `NurserySpace::spanBase`
/`spanBytes` (both semi-spaces as one span, so the table does not care which side is from-space)
and `Allocator::nurserySpan`. Patch `step-W12d.patch`; tree `try-W12d`.

The plan's safety question — "if a minor GC can run during an incremental major mark, addresses
shift and both the set and a bitmap are equally invalid" — resolves without needing the deeper
answer: **every pointer reaching the table has already passed `Allocator::isInNursery`**, i.e.
`contains()` on the calling thread's nursery, so it is in that thread's span by construction, and
both structures key on raw addresses, so the bitmap is exactly as valid as the set and no more.
The hazard is pre-existing and unchanged.

| run | wall (s) | GC time (s) | mark (ms) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 182.26 | 68.14 | 7958.8 | 1924 | 6 | 19861 | 10,693,732 | same |
| r2 | 180.47 | 67.78 | 8065.3 | 1924 | 6 | 19861 | 10,697,820 | same |
| r3 | 180.91 | 67.87 | 7904.6 | 1924 | 6 | 19861 | 10,697,572 | same |
| **median** | **180.91** | **67.87** | **7958.8** | 1924 | 6 | 19861 | **10,697,572** | same |
| Δ vs `W13` | -0.80 (spread 1.79) | **+0.68** | **+386.4** | 0 | 0 | 0 | **-44,932** | — |

(Mark figures corrected — see the note in W12c. W13's mark reference is its drift triple, 7572.4 ms
median, because the FIFO comparison and this one share it.)

**It slowed mark by 5.1 % — the quantity it exists to speed up.** Wall moved -0.80 s, inside the
band and therefore FLAT and uninformative; GC time and mark time both went the wrong way, and the
per-collection pairing agrees (W12d is slower on the 1st, 2nd and 4th collections, a wash on the
3rd).

**Why: the visited set is SPARSE against the span it is indexed over.** The nursery reached 256 MB,
so the two-semi-space span is ~512 MB and its bitmap is ~8 MB — touched at random, one bit per live
nursery object. The `unordered_set` allocated only as many nodes as there were distinct live
nursery objects and kept them in a much smaller working set. Replacing a sparse structure with a
dense one over a large address range trades a hash for a cache miss, and here the hash was cheaper.
This is the mirror image of item 40, where the dense structure won because it was ALREADY dense
(one bit per 8 bytes of a fully-occupied block) and the change only removed a level of indirection.

**Banked finding: max RSS is 45 MB lower with the set gone.** That is real and outside RSS noise
(~4 MB across the triple) — it is the set's node allocations. By the letter of §4's second rule
(wall did not increase, max RSS improved) this scores as a WIN; it is NOT kept, because this series
makes GC time the primary stat and the item regresses both GC time and the mark time it targets.
A future attempt that wants those 45 MB should pursue an arena-allocated or open-addressed set
rather than a span-wide bitmap — keeping the structure sparse is the property that matters.

**Consequence for parallel marking:** working-list #60 (per-worker visited bitmaps) inherits this
result. Per-worker bitmaps over a 512 MB span would multiply the 8 MB working set by the worker
count. #60 needs a different design, and item 38 should not be cited as its prerequisite.


### W14 — items 42, 45, 46 — **ALL THREE CLOSED UNBUILT, on arithmetic**

The follow-up plan's own sequencing says of this package: *"independent; lowest value, do last or
not at all"*, and for item 46 it says outright *"leave closed unless the header is being reworked
anyway."* The measurements this series produced turn "lowest value" into a number, so the closure
is recorded with its ceiling rather than as a judgement call.

**The ceiling.** The Major GC Event Log accounts for 100 % of major-GC time — across all three
W13 runs, `total - mark - sweep - roots` is 0.1 ms. So on the kept tree:

| bucket | per run (6 collections, W13 drift triple) | % of 181.71 s wall |
|---|---|---|
| mark | 7525.9 / 7694.9 / 7572.4 ms | 4.2 % |
| **sweep** (contains ALL block release and reclaim) | **497.0 / 510.8 / 511.6 ms** | **0.28 %** |
| roots | 249.2 / 258.4 / 253.9 ms | 0.14 % |

**Item 42** (stop scanning all of `large_body_index_` per released block) targets
`releaseBlockToAllocator`, which is called from `reclaimAllDeadBlocksFromMeta` and
`maybeShrinkCapacity` — both inside that 491 ms sweep bucket. Its worst case is real but small:
the largest collection recovers 5007 MB, so at 512 KiB per block roughly 10 K releases, each
walking an index whose size is bounded by live split-header bodies. Even a generous 10 M map
iterations lands around 50-100 ms per RUN, i.e. **~0.05 % of wall**, against a sweep-column
resolution of ~10 ms. It is also a restructure (it adds a per-block `vector<LargeBodyId>`), so the
flat-deletions-ship rule does not cover it, and the code it touches carries a documented past
corruption (`OldGenSpace.cpp:3271-3288`, `bugs/C-lot-8K-alignment-investigation.md` v15) whose
cleanup must be preserved exactly. Bad trade: single-digit-millisecond upside, heap-corruption
downside.

**Item 45** (index the empty-block search) is the one item here outside the GC buckets — the
`for (size_t i = 0; i < blocks_.size(); ++i)` scan at `:1421` runs per LARGE allocation, in mutator
time. Scale: the old gen peaks at 9818.70 MB, so ~20 K blocks; large allocations are rare
(`Lg-body sweep runs: 358` per run). A few thousand scans of 20 K entries is tens of milliseconds,
same order as 42. The plan already names the real cost — "the risk is keeping the index coherent
across sweep, release and the `is_large` flip" — and this series has now twice paid for exactly
that class of coherence bug (W11b's `marks_dirty_`, item 40's second removal path, which was only
caught because the count assertion fired).

**Item 46** (remove per-object large-body map lookups) stays closed for the reason the plan gives:
the natural fix wants a `LargeBodyId` in `Header`, which means claiming ~15 bits of
`Header.refcount` plus an overflow sentinel — and that **collides with working-list item 32**,
closed by arithmetic in the parent loop. If those bits are ever split, it should be done once,
deliberately, for both consumers, as a header change with its own plan. Not a constant-factor step.

**Net:** the three W14 items together are bounded by well under 1 % of wall, all three ADD an index
or a header field rather than deleting a scan, and two of the three sit on paths with a documented
corruption history. Closing them is the disposition the plan anticipated.


### Series drift check — **NO DRIFT; all intervening deltas stand**

The protocol's closing requirement (§1, Phase 0): the last kept compiler measured again, to test
whether the machine moved under the series. `bin/eco-optW13` re-run as a fresh triple after the
final step.

| stat | recorded at W13 | drift re-measure | Δ |
|---|---|---|---|
| wall (s) | 181.71 | **181.57** | **-0.14** |
| GC time (s) | 67.19 | 67.50 | +0.31 |
| minor / major | 1924 / 6 | 1924 / 6 | identical |
| promoted MiB | 19861 | 19861 | identical |
| max RSS (kB) | 10,742,504 | 10,742,964 | +460 |
| out.mlir | 13,241,185 | 13,241,185 | identical |

Wall agrees to **0.14 s** and RSS to **0.5 MB** against triples taken up to three hours apart; the
counters are exact, and determinism and fixed point are green. The machine did not drift, so the
per-step deltas recorded above are sound.

Worth noting against §1's warning about inter-triple drift (±5 s, which is why the interleaved form
existed): the observed drift across this whole session was **0.14 s**. That does not retire the
warning — one clean check is not a distribution — but on this box, on this day, the plain-triple
form was not the limiting factor. What limited the last four items was that their target is 4 % of
wall, which no wall-based form can resolve; the event log is what resolved them.


### W13c — item 54, FIFO variant (depth 16) — **WIN, kept; supersedes prefetch-on-grey**

Built at the user's request after W13 shipped the cheap variant, and with the byte-identity gate
explicitly relaxed ("so long as all tests pass"). It did not need the relaxation — see below.

**Change.** The handbook's recipe (`gc_handbook/02-mark-sweep.md §2.6`), replacing the two
prefetch-on-grey hints rather than stacking with them, so the delta reads FIFO **against** on-grey.
A 16-entry ring sits between the mark stack and the scan: `incrementalMark` pops entries into the
ring and prefetches each on the way in, then scans the entry that falls out the far end. Patch
`step-W13c.patch`, 86 lines; tree `try-W13c`.

**The one real hazard, and it is a live-object hazard.** `incrementalMark` signals completion with
`!mark_stack.empty()`. An entry left in the ring when the function returns is never scanned, its
children are never marked, and live objects are swept. The ring is therefore drained
unconditionally before every return, overshooting `work_units` by at most `MARK_FIFO_DEPTH-1`
objects. Making the ring a member and reporting `!mark_stack.empty() || count > 0` would also work;
the local-plus-drain form is smaller and has no cross-call state to get wrong.

| run | wall (s) | GC time (s) | mark (ms) | minor GC | major GC | promoted MiB | max RSS (kB) | out.mlir (B) | fixed point |
|---|---|---|---|---|---|---|---|---|---|
| r1 | 180.08 | 66.46 | 6746.0 | 1924 | 6 | 19861 | 10,743,168 | 13,241,185 | same |
| r2 | 180.58 | 66.70 | 6807.6 | 1924 | 6 | 19861 | 10,743,568 | 13,241,185 | same |
| r3 | 178.26 | 66.00 | 6782.8 | 1924 | 6 | 19861 | 10,743,276 | 13,241,185 | same |
| **median** | **180.08** | **66.46** | **6782.8** | 1924 | 6 | 19861 | 10,743,276 | 13,241,185 | same |
| Δ vs `W13` (on-grey) | **-1.63** | **-0.73** | **-789.6 (-10.4 %)** | 0 | 0 | 0 | +772 | 0 | — |
| Δ vs `W12b` (no prefetch) | **-1.04** | **-1.21** | **-930.5 (-12.1 %)** | 0 | 0 | 0 | +124 | 0 | — |

**Gates:** E2E `--target check` **1730/1730**; heap-validate **1730/1730** with the pinned seed
`1790156644220971348` (the unpinned run hit the known HEAP_044 0-field `Tag_Custom` generator flake
— pre-existing, recorded in W1b); stress suite under `heap-config-gc-pressure.json` **100/100 at
1,263 minor GC cycles**. Counters bit-identical, deterministic across all three legs.

**The output is byte-identical, so the plan's central worry about this variant is refuted.** The
plan warned that the FIFO "changes traversal order ... and therefore possibly `out.mlir`", and made
that a reason to prefer on-grey. It cannot: Elm exposes no pointer identity, so nothing the
compiler computes can depend on the order in which the collector traces a graph. Mark order is
invisible to emission by language semantics, not by luck. The byte-identity gate was available to
be spent here and did not need to be.

**Why the FIFO beats on-grey by 5x.** Both issue the same number of prefetches; the difference is
distance. The mark stack is LIFO, so on-grey's hint lands 1 object ahead for the last child pushed
and an unbounded number ahead for the first — a smear of distances, most of them too short to
cover a DRAM miss. The ring fixes the distance at 16 objects of real scanning work, which at
41.3 ns per object is ~660 ns of cover — comfortably more than a miss. **Distance, not hint count,
was the variable.**

**It is not uniform, and the exception is informative.** Per-collection mark (all three runs):

| collection | W13 on-grey | W13c FIFO | Δ |
|---|---|---|---|
| 2nd | 318.1 / 327.3 / 318.8 | 280.3 / 282.7 / 282.9 | **-12 %** |
| 3rd | 553.2 / 568.1 / 552.1 | 455.8 / 458.7 / 457.4 | **-17 %** |
| 4th | 1886.6 / 1947.5 / 1892.5 | 1994.8 / 2009.3 / 2011.5 | **+6 %** |
| 5th | 1788.2 / 1814.6 / 1789.0 | 1395.5 / 1400.9 / 1397.1 | **-22 %** |
| 6th | 2904.7 / 2962.3 / 2940.8 | 2540.3 / 2576.0 / 2553.9 | **-13 %** |

Four collections improve by 12-22 %; the 4th is consistently 6 % WORSE, in all three runs against
all three. That collection is the one with the smallest heap-to-live ratio in the event log
(2336.5 MB before, 1599.9 MB after — 68 % survives, against 19-30 % for the others). When most of
what you trace is live and densely connected, the lines are already resident and the ring's extra
copy, modulo and branch are pure overhead — the same shape as on-grey's +8 ms on the smallest
collection, and the same lesson as item 38: **prefetching pays in proportion to the miss rate, so a
phase with no misses can only lose.** A depth that adapts to survival ratio is the obvious follow-up
and is NOT built here.

Also worth noting: W13c's mark spread is **61 ms** across three runs against W13's 733 ms. Fixing
the prefetch distance fixed the variance too.

**What this -930.5 ms is actually made of** (measured later, W13f): the ring's interleaving costs
**+4841.2 ms** of mark on its own, and the prefetch buys back **-5771.7 ms**. This is not a small
local optimization; it is a 63 % regression paired with a larger recovery, and the two are
coupled. If the prefetch stops working — other hardware, a compiler that drops the hint, a
workload whose objects are already resident — the collector does not degrade to the old
behaviour, it degrades to something far worse. Read W13f before porting or re-tuning this.


### W13d — item 54 FIFO depth sweep (4 / 8 / 16 / 32 / 64) — **16 confirmed optimal**

Requested after W13c shipped at depth 16, to find whether the handbook's suggested start was
actually the sweet spot. Five candidates, each its own build + lowering + cold triple, all with
IDENTICAL code shape so the only variable is distance. Reference points: **no prefetch (W12b)
7713.3 ms**, **prefetch-on-grey (W13) 7572.4 ms**.

| depth | mark medians (3 runs, ms) | median | vs no prefetch | wall (med) | GC (med) |
|---|---|---|---|---|---|
| 4 | 9738.6 / 9363.3 / 9492.1 | **9492.1** | **+1778.8 (+23.1 %)** | 184.68 | 69.87 |
| 8 | 7269.8 / 7267.2 / 7393.5 | 7269.8 | -443.5 (-5.8 %) | 182.29 | 67.19 |
| **16** | 6880.2 / 6770.6 / 6897.6 | **6880.2** | **-833.1 (-10.8 %)** | 181.65 | 67.00 |
| 32 | 6947.5 / 6945.2 / 6972.6 | 6947.5 | -765.8 (-9.9 %) | 182.56 | 67.59 |
| 64 | 7043.8 / 7058.0 / 7106.0 | 7058.0 | -655.3 (-8.5 %) | 180.21 | 66.84 |

All five deterministic, all five byte-identical output, counters bit-identical throughout.

> **RESOLUTION CORRECTION (W13h).** Mark-time SD is 79.8 ms, so with n=3 anything under ~200 ms is
> not resolvable. Depths 4 (32.7 SD) and 8 (4.9 SD) are clearly worse; **16, 32 and 64 are
> statistically indistinguishable** (67 ms = 0.8 SD, and 178 ms = 2.2 SD). The top of this curve
> is a PLATEAU, not a point. 16 is still the right choice — smallest depth on the plateau, so the
> smallest L1 footprint — but on parsimony, not on a measured optimum over 32.

So **the shipped depth is right**, and the tree keeps it. Wall does not discriminate (178-185 s across the sweep); mark does, and its
within-depth spread is 30-375 ms against between-depth gaps of 70-2200 ms.

**DEPTH 4 IS WORSE THAN NOT PREFETCHING AT ALL (+23 %), and that is the finding.** The prediction
going in — from 41.3 ns of mark work per object, depth 4 buys ~165 ns of cover against a ~90 ns
miss, so the knee should be at 2-3 and everything above flat — was wrong, and wrong in the specific
way named in advance as its falsifier.

**The arithmetic double-counted.** 41.3 ns/object is the average INCLUDING the stall the prefetch
exists to hide. The issue-to-use distance is the NON-stall work, ~10-15 ns/object, so depth 4 buys
only ~50 ns — the line is still in flight when it is needed. Depth 8 buys ~100 ns, about one miss,
and lands 390 ms behind 16. Depth 16 buys ~190 ns, enough for the miss plus queueing. **When
sizing a prefetch distance, divide by the work that ISN'T the miss.**

**It also exposes a fixed cost that the depth-16 result alone concealed.** The ring trades the mark
stack's depth-first locality (children scanned near their parents, which for a copying collector
means near in address too) for an interleaved frontier of DEPTH partial traversals. That cost is
paid at every depth. At 4 it is paid for nothing, so the +1.8 s over no ring is a LOWER BOUND on
the cost at that depth — not a measurement of it, since a too-late prefetch still overlaps part of
its miss. So W13c's win is a NET of a large penalty against a larger win, not a
pure gain — **measured in W13f: the ordering cost is +4841.2 ms (+62.8 %) and the prefetch benefit
-5771.7 ms**, reconciling to the -930.5 ms measured here. Worth knowing before anyone extends the
ring idea elsewhere in the collector.

The upper end behaved as predicted: 32 and 64 are only mildly worse (+67 / +178 ms against 16),
consistent with the core running out of line-fill buffers — no more than ~10-16 misses can be in
flight regardless of ring size — plus growing L1 pressure at 64, where the ring alone holds 4 KiB
of prefetched lines.

**Shipped guard.** `MARK_FIFO_DEPTH` now carries the sweep table in a comment and a
`static_assert` that it is a power of two: the ring index is `% MARK_FIFO_DEPTH`, which is a mask
while that holds and a real DIVISION on mark's hottest path otherwise. (The sweep itself ran a
branch-wrap form, `if (++tail == D) tail = 0;`, so that a non-power-of-two depth could have been
measured fairly had one been wanted; at 16 the two forms measure the same within noise, and the
kept tree uses the mask.) Verified codegen-neutral, but NOT by the whole-file `cmp` I
first reached for: that reported 6.46 MB differing, all past byte 70 M. Adding ~25 lines of comment
shifts every later line number in the header, so in a RelWithDebInfo build the DWARF line tables
move even though nothing executable does. The check that answers the question compares the CODE:
`.text` hashes identically between `eco-optW13d` and the measured, gated `eco-optW13c`, and so does
each whole image with `--strip-debug` applied. So W13c's triple and its three gates stand unchanged
and no re-measurement is owed. **A whole-file `cmp` is the wrong instrument for "did this comment
change the binary" whenever debug info is on** — it answers a strictly stronger question than the
one being asked, and answers it "no" for reasons that do not matter.


### W13e — FIFO as a worklist member (the handbook's structure) — **NO WIN, reverted**

The handbook models the prefetch FIFO as a field of `MarkWorklist`, drained only when the stack
runs dry (`design_docs/gc_handbook/02-mark-sweep.md` §2.6). W13c made it a LOCAL of
`incrementalMark`, drained before every return, because an entry left in flight would never be
scanned and live objects would be swept. `incrementalMark` is called **186,601 times** per
self-compile, so that local ring ramps from empty and drains at every call boundary: ~16 objects
per call at less than the full prefetch distance, about 3 M objects or 1.6 % of all marking. This
step persisted the ring across calls, as the handbook has it. Patch `step-W13e.patch`, 109 lines;
tree `try-W13e`.

Correctness work, since "the stack is empty" stops meaning "marking is done": the early-out, the
return value, and both reset points (`startMark` and `reset`) all had to account for in-flight
entries. `finishMarkAndSweep`'s `while (incrementalMark(1000, stats))` is the only caller.

| run | wall (s) | GC time (s) | mark (ms) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 182.97 | 67.95 | 7077.4 | 1924 | 6 | 19861 | 10,744,376 | same |
| r2 | 179.52 | 66.83 | 7001.5 | 1924 | 6 | 19861 | 10,743,432 | same |
| r3 | 179.23 | 66.73 | 6993.1 | 1924 | 6 | 19861 | 10,743,272 | same |
| **median** | **179.52** | **66.83** | **7001.5** | 1924 | 6 | 19861 | 10,743,272 | same |
| Δ vs `W13c` | -0.56 (spread 3.74) | +0.37 | **+218.7 (+3.2 %)** | 0 | 0 | 0 | +768 | 0 |

E2E `--target check` **1730/1730**, deterministic, fixed point green, counters bit-identical.
**Mark got 218.7 ms SLOWER**, so the ramp-loss theory was right about the mechanism and wrong about
the sign of the net.

**Why the handbook's structure loses here: C++ aliasing across a non-inlined call.** As locals,
`head`, `tail` and `count` have addresses that never escape, so the compiler keeps them in
registers across the whole drain loop. As members they are reached through `this`, and
`markOneObject` — a non-inlined call that also writes members — could modify them for all the
compiler knows, so they must be reloaded and re-stored around every iteration. At 186.6 M objects,
+218.7 ms is **+1.17 ns per object**, which is about what a reload/store pair costs. The 1.6 %
ramp saving is real but smaller than the register-allocation tax it pays for.

**The synthesis was built as W13g and it LOST.** The prediction here — that a
`markToCompletion()` draining stack and ring in one call with a LOCAL ring would get the register
allocation and lose the ramp, and so beat both arms — is **refuted**: it measured 6877.1 ms,
94.3 ms WORSE than W13c. The ramp is not a cost to remove; draining the ring periodically
partially restores depth-first order, which matters because W13f showed the ordering effect
(+4841 ms) dwarfs everything else here. See W13g. The remainder of this paragraph is kept as
written because the reasoning was wrong in an instructive way. It needs the `Incremental marks`
stat kept meaningful (increment per 1000 units rather than per call) and is only safe while no
caller wants to interleave work with marking — which is true today but is exactly what
incremental marking exists to allow. Recorded as the open follow-up.


### W13f — ring with prefetch REMOVED (diagnostic, not a candidate) — **the ordering cost, measured**

Built to settle a claim this file was carrying as inference: that the FIFO ring trades the mark
stack's depth-first locality for an interleaved frontier, and that W13c's win is a NET of that cost
against a larger prefetch benefit. The W13d entry could only bound the cost from below (via depth
4) because a too-late prefetch still overlaps part of its miss. This arm removes the single
`__builtin_prefetch` and changes nothing else, so the ordering change is measured with ZERO
prefetch benefit. Tree `try-W13f`; **reverted immediately after measuring — it is not a shipping
configuration.**

| run | wall (s) | GC time (s) | mark (ms) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 187.66 | 73.29 | 12661.4 | 1924 | 6 | 19861 | 10,742,840 | same |
| r2 | 188.29 | 73.29 | 12533.6 | 1924 | 6 | 19861 | 10,743,048 | same |
| r3 | 185.22 | 72.08 | 12554.5 | 1924 | 6 | 19861 | 10,743,216 | same |
| **median** | **187.66** | **72.08** | **12554.5** | 1924 | 6 | 19861 | 10,743,048 | same |

**The decomposition, and it closes exactly:**

| configuration | mark (median) | vs no ring |
|---|---|---|
| no ring at all (W12b) | 7713.3 ms | — |
| ring, no prefetch (W13f) | **12554.5 ms** | **+4841.2 (+62.8 %)** |
| ring + prefetch, depth 16 (W13c) | 6782.8 ms | -930.5 (-12.1 %) |

Ordering cost **+4841.2 ms**, prefetch benefit **-5771.7 ms**, net **-930.5 ms** — and -930.5 is
exactly W13c's independently measured delta against W12b. Two separately measured quantities
reconciling to the digit is the strongest evidence in this series that the model is right.

**The ring is a much bigger bet than the shipped number suggests.** Interleaving 16 traversal
strands makes marking **63 % slower** on its own. The prefetch then wins back all of that and 12 %
more. Anyone reading "-930 ms, keep it" without this entry would reasonably assume a small, safe,
local change; it is in fact a large regression paired with a larger recovery, and the two are
coupled — degrade the prefetch (different hardware, a compiler that drops the hint, a workload
whose objects are already cached) and the collector does not fall back to the old behaviour, it
falls back to something 63 % worse.

**This also corrects two earlier statements in this file.** W13d said depth 4's +1778.8 ms was a
LOWER BOUND on the ordering cost; at depth 16 the cost is 4841.2 ms, so that bound was very loose
(as expected — fewer strands, less damage). And W13c's "-833 ms is a net of a large penalty against
a larger win" is now quantified rather than asserted.

Per-collection (r1), ring-without-prefetch against no ring — worse everywhere, 45-90 %:

| collection | c1 | c2 | c3 | c4 | c5 | c6 |
|---|---|---|---|---|---|---|
| live after | 100 % | 52 % | 33 % | 68 % | 19 % | 32 % |
| no ring | 79.9 | 318.4 | 543.8 | 1934.1 | 1832.4 | 3004.7 |
| ring, no prefetch | 151.3 | 501.0 | 831.7 | 3644.9 | 2652.1 | 4880.4 |
| ratio | **1.89x** | 1.57x | 1.53x | **1.88x** | 1.45x | 1.62x |

The two densest collections (c1 at 100 % live, c4 at 68 %) lose the most, which is what the
mechanism predicts: the denser and more connected the surviving graph, the more parent-child
adjacency a depth-first walk gets for free, and the more there is to destroy by interleaving. The
handbook says the same thing from the other direction (`06-comparing.md`): prefetching helps most
"when the proportion of live data in the heap is small".


### W13g — `markToCompletion` (single drain, local ring) — **NO WIN, reverted; refutes the ramp theory**

W13e's entry predicted this would beat both measured arms: keep the ring in LOCALS (so
head/tail/count stay in registers, which W13e lost) AND drain the stack in one call (so the ring
ramps once per collection instead of once per `incrementalMark`, which W13c pays). Built exactly
that: `markToCompletion()` replacing `while (incrementalMark(1000, stats)) {}` in BOTH
`finishMarkAndSweep` variants — the ENABLE_GC_STATS one and the plain one, which would otherwise
have silently diverged between build configurations. The `Incremental marks` / `Total work units`
counters are preserved by emitting the stats macro on the same 1000-unit cadence; both came out
**identical to W13c** (183,865 and 186,597,868), so the change is invisible to the banner.
Patch `step-W13g.patch`, 116 lines; tree `try-W13g`.

| run | wall (s) | GC time (s) | mark (ms) | minor GC | major GC | promoted MiB | max RSS (kB) | fixed point |
|---|---|---|---|---|---|---|---|---|
| r1 | 183.15 | 67.88 | 6994.2 | 1924 | 6 | 19861 | 10,740,948 | same |
| r2 | 181.54 | 67.23 | 6877.1 | 1924 | 6 | 19861 | 10,741,472 | same |
| r3 | 181.57 | 66.83 | 6854.7 | 1924 | 6 | 19861 | 10,743,104 | same |
| **median** | **181.57** | **67.23** | **6877.1** | 1924 | 6 | 19861 | 10,741,472 | same |
| Δ vs `W13c` | +1.49 (spread 1.61) | +0.77 | **+94.3** | 0 | 0 | 0 | -1,804 | 0 |

E2E `--target check` **1730/1730**, deterministic, fixed point green, counters bit-identical.
**It is 94.3 ms SLOWER than W13c**, and the three arms rank cleanly with no overlap between
adjacent distributions:

| arm | ring lives in | ramps | mark (median) |
|---|---|---|---|
| **W13c (shipped)** | locals, per call | **once per ~1000 objects** | **6782.8 ms** |
| W13g | locals, one call | once per collection | 6877.1 ms |
| W13e | members, across calls | never | 7001.5 ms |

> **RETRACTED by W13h (see below).** The +94.3 ms this entry reports is 1.2 SD of mark-time
> run-to-run variability (SD = 79.8 ms, measured over 12 runs of four indistinguishable arms), so
> it is NOT resolvable with n=3. The two triples not overlapping was luck — W13c's spread was
> 61.6 ms against a typical 126-165 ms. W13h then swept the drain interval over 64-4096 and found
> it FLAT, so the mechanism proposed below is unsupported. The entry is kept as written because
> the error is instructive: I built a mechanism on a 1.2 SD difference without an estimate of SD.

**The per-call ramp is not a cost. It is a benefit, and the ranking is monotone in how OFTEN the
ring drains.** That refutes the theory in W13e's entry, which this entry replaces: W13e's
+218.7 ms is NOT "register tax minus ramp saving", because removing the ramp entirely (W13g) does
not help — it hurts. W13e's regression is the register/aliasing tax alone, and the ramp is worth a
further ~94 ms on top.

**Why draining helps, consistent with W13f.** W13f measured the ring's ordering cost at +4841 ms —
interleaving 16 strands is by far the largest single effect in this whole area, and the prefetch
only just outruns it. Anything that partially restores depth-first order is therefore valuable.
Draining the ring does exactly that: when it empties, the next 16 entries are popped from one
contiguous region of the stack top — the most recently pushed children, spatially clustered — so
each drain re-synchronises the ring with the stack's locality before the strands diverge again.
A ring that never drains sits permanently in the maximally-interleaved state.

**Follow-up this opens (NOT built):** if draining every ~1000 objects beats draining every ~65 M
(W13g) and never (W13e), the drain interval is a tunable in its own right, and 1000 is an accident
— it is `finishMarkAndSweep`'s work_unit budget, chosen for pause control that nothing uses. A
sweep over an explicit drain interval (say 64 / 256 / 1000 / 4096) is the obvious next experiment,
and it is independent of `MARK_FIFO_DEPTH`. My guess is now worth little here: the two structural
predictions I made in this area (depth 4 flat, ramp costly) were both wrong, and both times the
ordering effect was larger than the latency effect.


### W13h — drain-interval sweep (64 / 256 / 1024 / 4096) — **FLAT, reverted; and it measures the noise floor**

Built to test W13g's explanation, that the three ring variants ranked by how often the ring drains.
`MARK_DRAIN_INTERVAL` was made explicit — a single-call drain loop that empties the ring every N
scanned objects, with the ring still in LOCALS (W13e priced making it a member at +218.7 ms) and
the stats cadence pinned at 1000 so the banner stays comparable. Separating the drain from the
call boundary matters: sweeping via `incrementalMark(N)` would have confounded the interval with
call frequency, since N=64 would also mean 2.9 M calls instead of 186 K. Patch `step-W13h.patch`;
tree `try-W13h`. E2E `--target check` 1730/1730; all four arms deterministic, fixed point green,
`Incremental marks` 183,865 and `Total work units` 186,597,868 identical in every arm.

| interval | mark (ms, 3 runs) | median | within-arm spread |
|---|---|---|---|
| 64 | 6772.1 / 6898.0 / 6784.0 | 6784.0 | 125.9 |
| 256 | 7006.3 / 6890.9 / 6867.6 | 6890.9 | 138.7 |
| 1024 | 6830.3 / 6735.5 / 6881.5 | 6830.3 | 146.0 |
| 4096 | 6761.2 / 6925.9 / 6794.9 | 6794.9 | 164.7 |

**Between-arm range 107 ms; within-arm spreads 126-165 ms.** Across a 64x range of intervals the
variation BETWEEN configurations is smaller than the variation WITHIN one. There is no effect.
Reverted: a flat restructure that adds a tunable constant does not ship.

**The real result is the noise floor.** Four arms that are statistically indistinguishable are
twelve independent samples of the same quantity, which is the first proper estimate of mark-time
variability this series has had:

> **mark time, 12 runs: mean 6845.7 ms, SD 79.8 ms. SE of a 3-run median ≈ 46 ms.**
> **With n=3, differences below ~200 ms (2.5 SD) are NOT resolvable.**

Applying that to every mark-time claim in this file:

| claim | delta | in SD | verdict |
|---|---|---|---|
| ring without prefetch (W13f) | 5771.7 ms | 72.3 | solid |
| depth 4 vs 16 (W13d) | 2611.9 ms | 32.7 | solid |
| depth 8 vs 16 (W13d) | 389.6 ms | 4.9 | solid |
| item 38 bitmap (W12d) | 386.4 ms | 4.8 | solid |
| FIFO as member (W13e) | 218.7 ms | 2.7 | borderline, has a mechanism |
| depth 64 vs 16 (W13d) | 177.8 ms | 2.2 | **NOT resolvable** |
| **W13g single-drain** | **94.3 ms** | **1.2** | **NOT resolvable — RETRACTED** |
| depth 32 vs 16 (W13d) | 67.3 ms | 0.8 | **NOT resolvable** |
| item 52 accumulator (W12c) | 55.0 ms | 0.7 | NOT resolvable (disposition unchanged: no evidence of benefit) |

**Two earlier conclusions are retracted.** W13g's +94.3 ms was reported as real because the two
triples did not overlap — W13c's happened to be unusually tight (spread 61.6 ms against a typical
126-165 ms). Three runs are not enough to establish non-overlap as significance, and this sweep
shows the drain interval has no effect over 64-4096 anyway, so the mechanism W13g proposed — that
drains re-synchronise the ring with the stack's locality — is unsupported. What remains true is
that W13e (member ring) is slower, at 2.7 SD with an independent explanation in C++ aliasing.

And W13d's "clean U with the minimum at 16 and monotone degradation either side" **overstated the
resolution at the top end.** What the data supports: depths 4 and 8 are clearly worse, and 16, 32
and 64 are statistically indistinguishable — a PLATEAU, not a point. 16 remains the right choice
because it is the smallest depth on the plateau and therefore the smallest L1 footprint, but the
justification is parsimony, not a measured optimum over 32.

**Method note for the rest of this series.** Mark time is a much better instrument than wall or
total GC time, but it is not exact, and three runs buy ~200 ms of resolution. Anything smaller
needs more runs, paired per-collection comparison (which is what actually carried W13's verdict),
or a different instrument. The per-collection pairing remains the strongest tool here: it yields
six matched samples per run instead of one, and it was already the basis on which W13 and W13c
were decided.


### T00 — threaded-gc-00 instruments (cost measurement, not an optimization) — **FLAT wall, GC +1.52 s (+2.3 %), measurable**

**What was measured.** `plans/threaded-gc-00-measure-and-fix.md` added:
- minor-GC phase timers;
- 1-in-16 / 1-in-256 promotion-path sampling;
- a pause bracket and pause log (percentiles, MMU);
- named external root scanners;
- the `ECO_GC_EVENT_LOG` check;
- the validate-only survivor-write census.

Everything except the validate-only parts is compiled in under `ECO_GC_STATS`, which is ON for
the standard `build` preset. The question this entry answers is **what those instruments cost
the self-compile when they are simply left on**, to decide whether they need their own
compile-time flag. The candidate is `bin/eco-optT00` (renamed `eco-optT00b` for the run), which
is `ecoghash.mlir` lowered against the `keep-T00` runtime: a runtime-only step, Phase 1.4. The
reference is the last WIN, `W13c` (`bin/eco-optW13c`): the same MLIR against the pre-phase-0
runtime. It has no instrument at all compiled in.

**Method.** §2 Phase 2 plain triples, strictly serial, idle machine (load 0.1 at start), cold
`eco-stuff`, no census variables. Because the object-level counters depend on the launch
session (threaded-gc-00 plan §6a.1) and wall drifts between sittings, the reference was
re-measured **in the same sitting** as the series drift check, immediately after the candidate.

| run | wall (s) | GC (s) | minor (s) | major (s) | true mutator (s) |
|---|---|---|---|---|---|
| T00b r1 | 182.50 | 68.58 | 59.93 | 8.51 | 113.60 |
| T00b r2 | 184.71 | 68.82 | 60.18 | 8.50 | 115.56 |
| T00b r3 | 188.32 | 69.88 | 61.08 | 8.66 | 118.11 |
| **T00b median** | **184.71** (spread 5.82) | **68.82** | **60.18** | 8.51 | 115.56 |
| W13c r1 | 182.26 | 67.85 | 59.23 | 8.48 | 114.04 |
| W13c r2 | 181.86 | 67.30 | 58.78 | 8.39 | 114.24 |
| W13c r3 | 181.86 | 67.25 | 58.75 | 8.36 | 114.29 |
| **W13c median** | **181.86** (spread 0.40) | **67.30** | **58.78** | 8.39 | 114.24 |
| **Δ** | **+2.85** | **+1.52 (+2.3 %)** | **+1.40** | +0.12 | +1.32 |

**Gates.**
- All six `out.mlir` are byte-identical to `ecoghash.mlir`.
- Counters are identical in all six runs: 1924 minors, 6 majors, 19,861 MiB promoted, 254,094,395
  objects allocated, 675,767,781 promoted.
- Drift check: W13c re-measured at 181.86 s against its recorded 180.08 s, +1.78 s, inside the
  5.3 s band. **No drift**, and the intervening rows stand.

**Verdict.**
- **Wall is FLAT** under §4: +2.85 s is inside the candidate's own 5.82 s spread. r3 alone
  carries most of it.
- **The GC-time cost is real.** All three candidate GC times (68.58–69.88 s) lie above all three
  reference GC times (67.25–67.85 s): complete separation, with +1.40 s of it in the minor pause.
- Split, using the earlier same-binary A/B in `benchmarks/threaded-gc-00-baseline.md` §2:
  - about **0.77 s** is the fine-grained phase timers and sampling (the part `ECO_GC_PHASE_TIMERS=0`
    turns off);
  - the remaining ~0.75 s is what stays on even then: the per-GC pause bracket and log, the
    per-minor record plumbing, and per-scanner indirection.
- The §4 amendment ("a flat package that DELETES work still ships") does not apply: this package
  ADDS work.

**Decision input, not a ship decision.**
- **~1.5 s of GC (~0.8 % of wall)** is a small but real tax on every stats-build benchmark in this
  loop.
- It is below the wall noise band, but not below the GC-time noise floor: GC-time SD for identical
  work is ~0.4–0.8 s, and here the separation is complete.
- **Recommendation:** compile the threaded-gc-00 instruments out by default behind their own CMake
  option (default OFF), and keep a runtime opt-in inside it.
- With the instruments on, a future phase's GC-time deltas would carry this constant; that is
  harmless for A/B within one binary, and misleading against rows recorded without instruments.
- The two always-compiled pieces (scanner labels, stack-walk frame counters) are one-off or
  per-frame increments. They are unmeasurable here and can stay.

### T01 — threaded-gc-00 instruments compiled OUT (`ECO_GC_PHASE_TIMERS` OFF, the new default) — **FLAT, unmoved within noise**

**What changed after T00.** The instruments moved behind a compile-time CMake option,
`ECO_GC_PHASE_TIMERS`: default OFF, requires `ECO_GC_STATS`, defines `ENABLE_GC_PHASE_TIMERS`.
The runtime env var was removed.

With the option OFF, `nm` confirms that `NurserySpace`, `ThreadLocalHeap` and `OldGenSpace`
reference no instrument symbol (`gcEventLog*`, `recordPause`, `recordMinorPhases`,
`GCPhaseTotals::add*`, `sampledEstimateNs`, clock reads). What remains compiled in:
- the scanner-label vector (filled once at registration);
- two integer increments per stack frame walked;
- `lazySweep` returning its work count;
- the ordered-compare `ensureHeadroom` fix.

The candidate is `bin/eco-optT01` (`ecoghash.mlir` lowered against the flag-OFF runtime). The
reference is W13c (no instruments at all), re-measured in the same sitting, straight after the
candidate. Tests: `build/test/test` 1734/1734 and `build-validate/test/test` 1735/1735. The
flag-ON tree (`build-phasetimers`) builds and passes its threaded-gc-00 tests.

| run | wall (s) | GC (s) | minor (s) | major (s) | true mutator (s) |
|---|---|---|---|---|---|
| T01 r1 | 184.63 | 69.47 | 60.82 | 8.48 | 114.81 |
| T01 r2 | 181.66 | 67.82 | 59.32 | 8.34 | 113.49 |
| T01 r3 | 183.86 | 68.70 | 60.14 | 8.40 | 114.81 |
| **T01 median** | **183.86** (spread 2.97) | **68.70** | **60.14** | 8.40 | 114.81 |
| W13c r1 | 179.49 | 67.09 | 58.57 | 8.37 | 112.04 |
| W13c r2 | 183.35 | 68.06 | 59.44 | 8.47 | 114.94 |
| W13c r3 | 181.55 | 68.10 | 59.05 | 8.90 | 113.10 |
| **W13c median** | **181.55** (spread 3.86) | **68.06** | **59.05** | 8.47 | 113.10 |
| **Δ** | **+2.31** (inside band) | **+0.64** | +1.09 | -0.07 | +1.71 |

**Gates.** All six `out.mlir` are byte-identical to `ecoghash.mlir`. Counters are identical in
all six (1924 / 6 / 19,861 MiB / 254,094,395 / 675,767,781). No threaded-gc-00 banner block is
printed.

**Verdict: FLAT.**
- **Wall:** +2.31 s is inside the larger spread (3.86 s).
- **GC time:** the ranges now **overlap**: T01 67.82–69.47 s against W13c 67.09–68.10 s.
  Under T00 they were fully separated, with a +1.52 s median gap. The remaining +0.64 s median gap
  is below this sitting's own reference spread (1.01 s of GC), so it is not resolvable with n=3.
- **Minor time:** also overlaps (59.32–60.82 against 58.57–59.44).
- **This sitting was noisier than T00's:** the W13c wall spread was 3.86 s here against 0.40 s
  there.
- Compiling the instruments out removed the measurable cost. Any residual is below the
  protocol's resolution. A tighter bound would need per-collection pairing on the minor event
  distribution, which a flag-OFF build cannot log, or more runs.

### TG1 — threaded-gc-01 stable old-gen metadata (prerequisite, not an optimisation) — **FLAT on mark (+1.2 %, inside the band), GC −1.47 s, RSS −62 MB, counters bit-identical**

**What changed** (`plans/threaded-gc-01-stable-metadata.md`):
- stable `BlockId`s in a VA-reserved `BlockTable`, with an iteration order that reproduces the
  former `blocks_` vector exactly;
- a page index keyed from `heap_base` over the whole reservation;
- a per-id mark-bit arena;
- a marker-side live-bytes accumulator;
- address-encoded free-list back-links;
- per-heap state instead of the GC-path thread-locals.

Candidate `eco-optTG1f` (snapshot `try-TG1f`); same-session control `eco-optT01`, measured in
the same sitting.

| arm | wall (s) | GC (s) | minor (s) | major (s) | mark (ms) | max RSS (kB) | counters |
|---|---|---|---|---|---|---|---|
| T01 median (3 + 1 drift re-run) | 185.34 | 69.47 | 60.71 | 8.54 | 7,559 | 9,725,780 | reference |
| **TG1f median of 3** | **181.61** | **67.00** | **58.36** | 8.59 | 7,652 (pooled 5) | **9,664,108** | identical ×3 |
| Δ | −3.73 | −2.47 | −2.35 | +0.05 | **+1.2 %** | −61,672 | — |

- **Mark was judged per collection on the event log** (criterion M ≤ +2 %). Pooling the 5 runs
  of the byte-identical binary (2 as `eco-optTG1al`, 3 as `eco-optTG1f`) gives per-collection
  deltas of −2.1 / −1.7 / +0.6 / +0.6 / +2.5 / +1.0 %, and a total of **+1.2 %**.
- **The run-to-run spread of this binary's mark time is ~430 ms** (7,571 to 7,997). That is
  wider than the control's 82 ms. Three runs are not enough to resolve 2 % on mark.
- **The GC and wall gains are real but not the point.** The minor-GC −2.35 s most likely comes
  from dropping the TLS `g_in_minor_gc` load and the block-table indirections on the promotion
  path. That is not separately attributed.

**Two traps found on the way** (plan P§9a.13, memory `gc-mark-loop-alignment-trap`):

1. **Loop alignment.** The first candidate measured mark **+5.5 %**, yet every mark function got
   *smaller*. perf put the extra time at the child-field load of `markChildren`'s Custom loop.
   That loop had moved from a 64 B-aligned address to offset 48 through unrelated code-size
   changes. `-falign-loops=64` on `OldGenSpace.cpp` restored the control's mark time, and is now
   pinned in `runtime/src/codegen/CMakeLists.txt`. **Some of the "restructures lose" record may
   be alignment**; check the hot loop's address before blaming a design.
2. **Tail-committed VA gets no THP.** Committing an array at its tail in small `MAP_FIXED` steps
   left the 134 MiB mark arena on 4 KiB pages (0 MiB `AnonHugePages`, vs 196 MiB for the
   `malloc`'d vector), costing ~1 % of mark. Fixed with a 2 MiB-aligned, 2 MiB-granule
   `ReservedArray` for the arena.

**Pauses** (phase-timer builds, one run each, pre-alignment-fix candidate): max 2,633 vs
2,620 ms, p99 154 vs 156 ms, minor-only max 915 vs 911 ms, MMU identical. **Unchanged.**

**Gates:**
- E2E 1,746/1,746;
- validate E2E 1,747/1,747;
- validate unit tests clean (pinned seed);
- stress 100/100 at 1,263 minors;
- validate stress 95/100, the same 5 pre-existing `JsonRoundtrip*` nursery-check aborts as the
  pre-change sources;
- elm-tests 13,565/12 (the reference set);
- zero `[heap-validate]` lines anywhere.

The **validator self-compile is no longer a gate** (user decision; too slow).

### TG2 — threaded-gc-02 bitmap allocation — **WIN on pauses and allocation: minor-only max 976 → 178 ms, promotion 32.0 → 16.1 ns, minor GC −4.1 s; GC flat (+1 major); peak/RSS −0.4 %; wall −2.4 s (inside spread)**

**What changed** (`plans/threaded-gc-02-bitmap-allocation.md`, now the compiled defaults):
- a uniform block's mark bitmap is its allocation map; one per-class cursor allocates from it,
  with no header sweep of uniform blocks (HEAP_054);
- mixed blocks keep a gap sweep that reads only live headers (HEAP_055);
- dead large bodies are retired at mark end (HEAP_056);
- `demote_live_fraction` default 0.3 (from E1);
- a new **LiveBudget** major trigger, k = 4.5 and r = 1.5 (HEAP_057).

Candidate `eco-optTG2`; same-session control `eco-optTG1f`, strictly serial on an idle machine.

| arm | wall (s) | GC (s) | minor (s) | major (s) | mark (s) | majors | old-gen peak (MB) | max RSS (kB) |
|---|---|---|---|---|---|---|---|---|
| TG1f median of 3 | 183.37 (spread 5.6) | 67.38 | 58.73 | 8.49 | 7.67 | 6 | 8,824 | 9,663,784 |
| **TG2 median of 3** | **180.97** (spread 1.3) | 67.32 | **54.59** | 12.67 | 11.52 | 7 | **8,790** | **9,622,612** |
| Δ | −2.40 | −0.06 | **−4.14** | +4.18 | +3.85 | +1 | −0.4 % | −0.4 % |

- **Counters (G8):** output identical ×7. Minors 1,924, promoted 675,767,781, objects allocated
  254,094,414 and per-tag retention are identical to the control. Yesterday's 395 allocated was
  the environment: today's control reads 414 too.
- **Mark cost per marked object: 41.27 vs 40.16 ns (+2.8 %).** That is marginally outside M's
  ±2 %, inside the control's own 4 % run spread. It cannot be paired per collection: 7 vs 6
  collections at different points. The +3.85 s of mark is volume: 279 M vs 191 M marked objects.
- **Pauses** (phase-timer builds, one run each):

  | | TG1fpt | TG2pt |
  |---|---|---|
  | minor-only max | 976 ms | **178 ms** |
  | minor-only p99.9 | 705 ms | 162 ms |
  | minor-only p99 | 153 ms | 142 ms |
  | minor-only p50 | 5.9 ms | 5.4 ms |
  | worst pause containing a major | 2.64 s | **4.72 s** (the extra LiveBudget major at a larger live set) |
  | promotion allocator | 32.0 ns/call | **16.1 ns/call** |
  | in-pause lazy sweep | 10.5 GB covered, est 2.28 s, worst 820 ms in one pause | 3.7 GB covered, est 0.24 s, worst **63 ms** |

  Criterion P's byte bound (≤ 256 MB in-pause sweep per pause) fails as written: 5 pauses exceed
  it in both arms, and the largest covers 938 MB. The bound was calibrated for a header walk; the
  gap sweep covers bytes without reading them, so its intent (sweep time in a pause) holds 13×.
- **The allocator was SLOWER than the free-list pop as first built** (33 ns). Four integer
  `div`s per scan plus a runtime stride-mask loop were the cost. A next-cell hit path plus
  per-stride constant tables fixed it (plan §9 item 8).

**The trigger finding** (plan §9 item 7, memory `gc-trigger-is-chaotic`). The garbage-fraction
trigger sizes the heap at about 3.3× the live set seen at ONE instant.
- The reference's 6 majors / 8.8 GB is a lucky point: legacy at gf 0.65 / 0.70 / 0.75 gives
  7 / 6 / 4 majors and 11.8 / 8.8 / 16.2 GB peak.
- The bitmap mode's first flag-on run (RSS 14.4 GB) was that chaos, not allocator retention.
- LiveBudget k = 4.5 bounds it. The E1 table (plan §9 item 9) calibrates `demote_live_fraction`
  from 0 to 0.75.

**Gates** (default on):
- **G1:** unit + E2E 1,757/1,757 in the main and phase-timer trees.
- **G2:** elm-tests 13,565/12 (the reference set).
- **G3:** `--target full` 1,757/1,757.
- **G4:** stress 100/100 at 1,263 minors.
- **G5:** validate unit + E2E 1,758/1,758 with the pinned seed and zero `[heap-validate]` lines;
  validate stress 95/100, the same 5 pre-existing `JsonRoundtrip*` aborts.
- **G6:** stats-off `ecoc` builds.
- **G7:** every `populateFromBlock(` call is in flag-off code.
- **G5 found a real (latent) defect.** A major now leaves nothing to sweep, so compaction runs
  right after it. The HEAP_048 fixup-cursor check then read a dead position after
  `freeEvacuatedBuffers`' erase. Fixed by resetting the dead cursor.
- **Trap:** `ECO_HEAP_CONFIG` does NOT reach the old gen in `test/test`
  (`initAllocator` → `reset` installs the raw config).

### TG3 — threaded-gc-03 helper threads (deferred decommit + commit-ahead) — **WIN: in-minor page faults −99.4 %, minor GC −6.55 s, GC −7.17 s, wall −8.54 s; counters bit-identical in every mode; RSS +142 MB (the 128 MiB window)**

**What changed** (`plans/threaded-gc-03-helper-threads.md`; compiled defaults `gc_thread_mode` 2,
`decommit_delay_majors` 1, `decommit_delay_syncs` never, `commit_ahead_bytes` 128 MiB):
- **The pool.** `GCHelperPool` is a process-wide GC helper pool. The mutator posts jobs at the
  pause end and collects them at `acquire`/`release`. `ECO_GC_THREAD` selects the mode: 0 off,
  1 sync, 2 concurrent.
- **U1, deferred decommit (HEAP_059).** A released extent stays resident until it has gone
  unused for a whole major cycle. A reuse before then cancels the discard. The discard runs
  on a helper.
- **U2, commit-ahead (HEAP_060).** 128 MiB above the old-gen bump is mapped by the mutator and
  `MADV_POPULATE_WRITE`d by a helper.
- **GC_DET_001.** No decision reads helper progress.

**Pre-plan diagnostic (TG3-0, `eco-optTG2pt`, one run each).** 4.76 M page faults inside minors.
With `decommit_on_oldgen_release=false` (via `ECO_HEAP_CONFIG`):
- in-minor faults 2.20 M;
- minor GC −5.8 s, pauses −7.0 s, max RSS +17 MB.

So half the faults were refaults of blocks the majors `MADV_DONTNEED`ed (~12.3 GB/run) and the
minors reacquired. The rest ≈ the 8.8 GB commit high-water mark.

Candidate `eco-optTG3`; same-session control `eco-optTG2` with `ECO_GC_THREAD=0`. Every arm
sets `ECO_GC_THREAD` and `ECO_GC_HELPER_JITTER_US` to same-length values.

| arm | wall (s) | GC (s) | minor (s) | major (s) | mark (s) | sweep col (s) | sys (s) | process minflt | max RSS (kB) |
|---|---|---|---|---|---|---|---|---|---|
| TG2 control, mode 0, median of 3 | 181.21 (spread 1.79) | 66.89 | 54.15 | 12.67 | 11.59 | 0.74 | 6.72 | 4,803,717 | 9,625,344 |
| TG3 mode 1 (sync), median of 3 | 175.79 | 60.40 | 48.16 | 12.27 | 11.55 | 0.35 | 2.55 | 1,833,426 | 9,770,800 |
| **TG3 mode 2 (concurrent), median of 3** | **172.67** (spread 2.99) | **59.72** | **47.60** | **12.13** | 11.44 | 0.34 | 2.61 | 1,826,365 | 9,770,964 |
| Δ mode 2 vs control | **−8.54** | **−7.17** | **−6.55** | −0.54 | −0.15 | −0.40 | −4.11 | −62 % | +145,620 |
| TG3 mode 2 + jitter 500 µs | 173.71 | 60.26 | 48.01 | 12.23 | 11.52 | 0.35 | 2.68 | 1,820,202 | 9,770,672 |
| TG3 mode 0 | 182.45 | 67.40 | 54.64 | 12.69 | 11.60 | 0.74 | 6.82 | 4,803,105 | 9,626,916 |

- **Counters (G8):** every counter line and the major event log are identical across all 11 runs
  (control ×3; TG3 modes 0, 1 ×3, 2 ×3, 2+jitter). `out.mlir` is identical to `ecoghash.mlir`
  every time.
- **Mode 0 is physically inert:** faults −0.01 %, RSS +0.02 % vs control.
- **Pauses** (phase-timer builds, one run each):

  | | TG2pt (mode 0) | TG3pt mode 1 | TG3pt mode 2 |
  |---|---|---|---|
  | page faults inside minors | 4,708,246 | 29,416 | **28,904** |
  | minor-only pause total | 55.05 s | 49.78 s | **47.35 s** |
  | minor-only p50 / p99 / max | 5.33 / 141.5 / 178.2 ms | 5.20 / 126.8 / 179.3 ms | **4.93 / 113.7 / 175.7 ms** |
  | promotion allocator | 16.5 ns/call | 10.1 | 12.0 |
  | populate helper cpu / inline cpu | — | 0 / 1.90 s | 1.94 s / 0 |
  | stalls | — | 0 | 0 |

  The worst pause is the last major. In the phase-timer single runs it reads 4.86 s (control) vs
  5.07 s / 5.09 s, but the triples' major event logs say the opposite: median 5,341 ms (control)
  vs 5,158 ms (mode 2). The single control run was a low draw. Major 6 drops 2,093 → 1,912 ms,
  which is the inline `madvise` leaving its sweep.
- **Interference** (non-helper CPU, mode 2 − mode 1): −3.1 s. Negative, because sync mode runs
  the populate on the mutator.
- **Pinning (E3)** made no difference (48.29 vs 48.32 s minor), so the helper is not pinned.

**E1: the pause-end delay was the wrong unit** (plan §9 item 1).
- D ∈ {0, 4, 16, 64, 256} pause ends gave 4.82 / 4.69 / 4.38 / 3.96 / 2.87 M process faults,
  against 2.22 M for "never discard".
- Minors reacquire released blocks throughout a whole major cycle. So a block unused by the next
  major is the surplus: `decommit_delay_majors = 1` reproduces "never" exactly while bounding
  retention to one cycle.
- A 1 GiB pending cap returned 5.9 GB of refaults (+2.4 s minor) without lowering max RSS, so the
  default cap is 0.

**E2:** commit-ahead of 32 / 128 / 512 MiB covered 74 % / 100 % / 100 % of fresh commits, for
minor GC 47.94 / 46.77 / 46.81 s and max RSS +37 / +131 / +515 MB. 128 MiB was chosen.

**Defects found and fixed on the way:**
1. **Fork safety.** The unit-test runner forks per test. A child inherited "workers started" but
   had no workers, and a condition variable with dead waiters, so jobs never ran: 60 s
   timeouts. Fixed with `pthread_atfork` handlers:
   - prepare: drain, then lock;
   - child: re-construct the mutex and both condition variables, and restart workers lazily.

   Pinned by `testHelperPoolSurvivesFork`. It matters for any embedder that forks without exec.
2. **First-configuration-wins in test harnesses.** A `reset()` configured the pool before
   `initialize()`, and the latter aborted in mode 1. Fixed: an *idle* pool restarts when the
   settings differ.

**Gates:**
- G1 unit 1,779/1,779;
- G2 elm-tests 13,565/12 (the reference set);
- G4 stress 100/100 at 1,263 minors in modes 0, 1 and 2;
- G6 stats-off `ecoc` builds;
- G7 TSan harness: 0 warnings, and its negative control fails as it must;
- G10 static checks;
- G3 `full` 1,779/1,779, plus `check` in modes 1 and 0;
- G5 validate 1,780/1,780 (mode 2 + jitter, and mode 1) with zero `[heap-validate]` lines;
  validate stress 95/100 (the 5 pre-existing `JsonRoundtrip*` aborts, same in mode 0).

### TG4 — threaded-gc-04 frozen published heap (P1) — **correctness phase: P1 measured at full scale (0 violations in 744 M + 265 M + 18.8 M checks), two real hazards fixed, production counters identical but +1 nursery copy, wall flat**

**What changed** (`plans/threaded-gc-04-frozen-published-heap.md`):
- **The census.** `-DECO_P1_CENSUS=ON` gives a P1 census build that is not heap-validate. It has
  three detectors:
  - N: nursery survivors;
  - O: a sampled table of promoted objects, pruned at mark end;
  - W: the mutating heap helpers, keyed by caller.

  Validate builds run it in abort mode: the tripwire.
- **Fixes:**
  - S1: chunk-chain backings and views are built as builders, bounded by `chunkChainFits`;
  - S2: a born-old pending list (HEAP_061), which fixes a latent loss of the young children of
    large pointer-bearing objects allocated directly in the old gen;
  - `ListOps::member` deleted (FORBID_HEAP_005).

| arm | wall (s) | minor GC (s) | minors | majors | promoted | copied-in-nursery | max RSS (kB) | out.mlir |
|---|---|---|---|---|---|---|---|---|
| TG3 control (same session) | 174.73 | 47.53 | 1924 | 7 | 675,767,785 | 744,329,942 | 9,776,448 | same |
| **TG4** | **172.77** | 47.31 | 1924 | 7 | 675,767,785 | **744,329,943** | 9,776,948 | same |
| TG4 census (sample 16) | 195.37 | — | 1924 | 7 | — | — | 10,343,016 | same |

- **Single runs.** This is a correctness phase: the wall delta is inside the band.
- **The one counter change is +1 nursery copy**, the S1 builder effect, recorded as the plan's D7
  delta.
- **Census result:**
  - N: 744,021,406 re-hashes, 0 mismatches;
  - O: 264,970,501 re-hashes of 42.2 M sampled promotions, 0 mismatches;
  - W: 18,800,426 helper writes, 0 violations.
- **Census tree, abort mode:** unit + E2E 1,792 / 1,792; stress 100/100.
- **Gates:** G1–G9 green. Validate stress keeps the 5 pre-existing `JsonRoundtrip*` aborts,
  which are not P1: a stale closure in `eco_apply_closure_eval`.

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

> **AMENDED 2026-09-23 by W1/W1b.** That conclusion was drawn with W8 unbuilt and W1 still on
> the table, and W1 then bought **-14.54 s of GC time** — three and a half times what these
> eleven packages bought between them — by deleting a bulk memset rather than tightening a
> loop. Read "the bound is small" as "unmeasured", not "closed". The eleven never-built items,
> item 40 among them, are lowered in `plans/gc-mark-and-bookkeeping-followup.md`.

### Entry W1 — per-site nursery zeroing, retiring the bulk to-space memset (WIN, KEPT)

**This entry overturns the section above.** W1 was the one package in the plan backed by a
measurement (5.6 % CPU) and it was left unbuilt when `W1.1`'s high-water variant lost its gate.
The conclusion "the next real win is algorithmic, not constant-factor" was drawn with W1 still
on the table. It was wrong in that respect: W1 alone is **-14.54 s of GC time**, three and a half
times what eleven packages of constant-factor work bought between them.

**Change** (`plans/nursery-per-site-zeroing.md`, Phase 1). Every allocation site zeroes its own
payload; `NurserySpace::clearToSpaceFreeRegion` — the whole-semi-space memset that ran at the end
of every minor GC — is switched off (`ECO_NURSERY_BULK_CLEAR=1` restores it for bisection). Four
allocation paths had to be covered, not the two that are obvious:

| path | site | was |
|---|---|---|
| inline codegen (13 sites) | `emitInlineAllocWithHeader` | no payload zeroing at all |
| runtime slow/generic | `initHeaderForTag` | `memset(hdr, 0, sizeof(Header))` — **8 bytes** |
| runtime fast calls | `eco_alloc_{custom,record,string,closure}_fast` | 8 bytes |
| region / group + PAP extend | `eco_init_{record,custom,string}_at`, closure-group init, papExtend | 8 bytes |

Every one of those set `hdr->size` to the full field count while zeroing only the header, and
free-rode on the bulk clear for the rest.

**Result** (median of 3 cold self-compiles, reference `W7`):

| stat | W7 | W1 | delta |
|---|---|---|---|
| wall | 194.64 s | **183.82 s** | **-10.82 s (-5.6 %)** |
| Total GC/Alloc | 82.42 s | **67.88 s** | **-14.54 s (-17.6 %)** |
| Minor GC | 77.29 s | 59.19 s | -18.10 s |
| Major GC | 10.96 s | 8.55 s | -2.41 s |
| True mutator | 112.10 s | ~115.6 s | +3.5 s |
| minor / major cycles | 1924 / 6 | 1924 / 6 | identical |
| promoted | 19861 MiB | 19861 MiB | identical |
| max RSS | 10,805,292 kB | **10,677,000 kB** | **-128 MB** |

**Why it wins is NOT "fewer bytes zeroed" — Phase 1 zeroes MORE eagerly than before.** The bulk
clear wrote the whole semi-space every cycle (~1924 x 128 MiB ~ 246 GB) whether the mutator would
use it or not, and zeroed bytes that each object's own field stores immediately overwrote. Per-site
zeroing writes only what is allocated. The ~17 s that left minor GC minus ~3.5 s back on the
mutator is the whole story, and it reconciles to the memset bandwidth of this machine.

**Gates.** E2E `--target check` 1731/1731. Determinism across all three runs and `out.mlir`
byte-identical to `bin/ecoghash.mlir`. Heap-validate `-DECO_HEAP_VALIDATE=ON` **1731/1731** —
that gate had been RED and blocking W1/W4-32/W6/W8, and repairing it was part of this step (two
validator-only defects: the phase-3 assertion was armed over the to-space Cheney drain as well as
the promoted queue, and its diagnostic read `parent[-1]` off the front of an old-gen block and
segfaulted before printing). Stress suite 100/100 at 1,263 minor GCs. Poison tripwire with a
demonstrated positive control: zero hits.

**Traps this step set, all of them things that would have produced a confident wrong answer:**

1. **A gate that cannot fail is not a gate.** The stress suite at shipped defaults runs **0 minor
   GCs** — 62 MB against a 256 MB semi-space. It passes 100/100 without ever re-using a byte of
   the nursery. `benchmarks/heap-config-gc-pressure.json` is what makes it mean something.
2. **`0xDD` is the wrong poison byte** — bit 2 is `ptr_ind`, so poison decodes as a constant and
   is never followed. Use `0xD8`. The plan had specified `0xDD`, and the earlier `W1.3` "zero
   hits" result is best treated as void.
3. **Two of the four allocation paths are easy to miss**, because `emitInlineAllocWithHeader` and
   `initHeaderForTag` look like the whole story and are not.
4. **Build BOTH `test` and `ecoc`** in a validator tree; `test` alone fails 12 Elm cases with
   `exit 127` and reads exactly like a codegen regression.

**Follow-up DONE — the inline-path control, and it decided Phase 2's design.** No compiler
lowering was needed: `stress-test` links `EcoRunner` whole-archive and JIT-compiles each Elm
program in-process, so `ECO_INLINE_NO_ZERO=1` reaches the emitted code directly and isolates the
inline path. Suppressing it fires the tripwire hard (72 hits, 76/100 cases failing), so both
paths are demonstrably watched. Run in census mode (`ECO_POISON_NONFATAL=1`, which nulls the slot
and carries on):

| arm | cycles | poison hits | classes |
|---|---|---|---|
| inline path suppressed | 903 | 2,704 | **`Tag_Closure` — 100 %** |
| runtime path suppressed | 933 | 420 | **`Tag_Closure` — 100 %** |
| shipped (both on) | 1,032 | 0 | — |

**Not one hit from Cons, Tuple2/3, Record, Custom or String on either path.** The scan walks a
closure's full CAPACITY (`NurserySpace.cpp:1535`, `i < hdr->size` where `hdr->size == max_values`),
while only `n_values` captures are written at creation and the rest are filled later by
`papExtend` across safepoints. So Phase 2 can drop the mark for 12 of the 13 inline sites on
evidence rather than assumption, and for closures should zero only the unfilled tail
`[n_values, max_values)` rather than the whole payload.

**Still owed:** 5 stress cases (6 of 7 in the JSON decoder kernel) abort under the validator at GC
pressure on a stale unrooted HPointer. That reproduces with the bulk clear restored, so it is
pre-existing and wants its own plan.

### Entry W1b — bound the closure scan on n_values, delete payload zeroing (FLAT, kept)

**Change.** W1 retired the bulk to-space memset and replaced it with per-site payload zeroing.
This step removes that replacement as well, so allocation writes an 8-byte header and nothing
more. What makes it safe is a separate fix: the six closure trace loops now bound on
`n_values` (applied captures) rather than `hdr->size` (the allocated capacity). Slots at or
above `n_values` are unapplied argument space nothing reads — tracing them was the ONLY reason
a payload had to be zeroed. Also: `eco_store_field*` asserts on `Tag_Closure` (it writes a
value slot without maintaining `n_values`, and has no compiled-code or kernel callers), and
the heap-validate build's phase-3 promotion assertion is armed over the promoted queue only.

**Result** (median of 3 cold self-compiles, reference `W1`):

| stat | W1 | W1b | delta |
|---|---|---|---|
| wall | 183.82 s | 183.57 s | -0.25 |
| Total GC/Alloc | 67.88 s | 68.16 s | +0.28 |
| minor GC | 59.19 s | 59.43 s | +0.24 |
| max RSS | 10,677,000 kB | 10,676,096 kB | -904 |
| minor / major cycles | 1924 / 6 | 1924 / 6 | identical |
| promoted | 19861 MiB | 19861 MiB | identical |

Deterministic across all three; `out.mlir` byte-identical to `bin/ecoghash.mlir`. Everything
inside the 2σ = 5.3 s band ⇒ **FLAT**. Kept under the flat-deletions-ship rule: one mechanism
fewer, 110 KB smaller compiler binary, and the scan now traces exactly what the mutator wrote.

**THE PREDICTION WAS WRONG AND THE REASON MATTERS.** W1's mutator time rose 112.10 → 115.7 s
when it added per-site zeroing, and this step was expected to hand that back. Deleting every
memset moves the mutator **+0.39 s**. So the per-site zeroing never cost that; memsetting
`[obj+8, obj+size)` for a 24-64 byte object touches the very cache lines its field stores are
about to write. The +3.5 s is far more likely the cost of RETIRING THE BULK CLEAR — the mutator
used to allocate into memory a memset had just pulled into cache, and now allocates into cold
lines. That cost is not recoverable by deleting more zeroing.

**Gates.** E2E `--target check` **1730/1730** (1731 before `test_eco_store_field_closure` was
removed as vacuous once the arm asserts). Heap-validate **1730/1730**. Stress suite **100/100**
at 1,263 minor GCs. Poison tripwire (`ECO_NURSERY_POISON=1`, 0xD8) **zero hits** over 1,032
cycles with a demonstrated positive control.

**Traps.**

1. **The census that said "no hazard" was pointed at the wrong workload.** `ECO_CLOSURE_NVALUES_CENSUS`
   found ZERO live captures at/above `n_values` over 1,032 cycles — but the stress suite never
   fills closure captures via `eco_store_field`, and `GCPressureTest` does. Absence of a hit
   bounds only what was run.
2. **Do NOT "fix" `eco_store_field` by raising `n_values` to `index + 1`.** Stores can arrive
   out of order (RuntimeExportsTest used a random index), which then has the scan trace the
   unwritten slots below. `closureCapture` is correct because it appends.
3. **Do NOT reorder `eco_pap_extend` to publish `n_values` after its copy loop.** There is no
   safepoint in the window, so the original order is already guaranteed; the reorder only
   swaps an over-count for an under-count.
4. **The validator suite is SEED-FLAKY.** Its heap-graph generator can emit a 0-field
   `Tag_Custom` (HEAP_044 forbids it) and aborts in the from-space pre-walk — pre-existing.
   Gate with `--seed 1790156644220971348`.

### The instrument for any mark-path item is the Major GC Event Log, not GC time

Established at W12c and used for every item after it. The banner already prints one row per major
collection with `total`, `mark`, `sweep` and `roots` columns, and on this tree those four account
for 100 % of major-GC time (`total - mark - sweep - roots` = 0.1 ms across three runs). That gives
three properties the protocol's headline stats do not:

1. **It isolates the target.** Total GC time is 67 s dominated by 1924 minor collections; mark is
   7.7 s. An item that moves mark by 3 % moves total GC time by 0.3 %, which no triple can resolve.
2. **It gives six paired samples per run instead of one number.** Collections can be compared
   pairwise ACROSS arms (collection 4 of arm A against collection 4 of arm B), which controls for
   the fact that the six collections differ hugely in size — 543 ms to 3004 ms. W13 was decided
   this way: complete separation on the two dominant collections, with an outlier visible as an
   outlier rather than as spread.
3. **It prices the remaining work before you build it.** `markunits` (186,597,868 objects popped)
   over 7.71 s of mark gives **41.3 ns per marked object** — which is memory latency, not instruction
   count, and that single number predicted all three W12/W13 outcomes correctly in hindsight:
   instruction-shaving lost (52), a dense-structure swap lost (38), removing a dependent load won
   (40), and hiding a miss won (54).

**Corollary for the disposition rule.** The follow-up plan's §6 says flat restructures are reverted
"unless they move GC time outside the 2σ = 5.3 s band". No mark-path item can ever do that, since
all of major GC is 8 s. Applying that bar literally would have reverted item 40 as well. The band
belongs to the wall/GC-time columns of the parent loop; per-bucket items need per-bucket evidence.

### Dense beats sparse only when the data is already dense

Items 40 and 38 are the same shape — replace a pointer-chasing container with a flat bitmap — and
they went opposite ways. 40 won because old-gen mark bits are already dense (one bit per 8 bytes of
an occupied block) and the change only removed a level of indirection from a structure that was
going to be touched anyway. 38 lost because `nursery_visited_` is SPARSE: a handful of live nursery
objects scattered over a 512 MB span, so a span-wide bitmap is an 8 MB working set touched at
random where the hash set's working set was proportional to the live count. **Occupancy, not
container type, decides it** — and occupancy is measurable before building.

### Every plan premise that could be checked by reading was worth checking

Four of eleven items had a premise that did not survive contact with the tree, and in three cases
the plan stated a specific line number or count that was wrong in a way that would have caused a
defect, not just a miss:

- **Item 43:** "exactly ONE write site, `:2407`" — that site writes an UNLINKED trailing cell; the
  linked one is `:2341`. Counting at the stated site would have made the counter read zero while
  sentinels sat on the lists, and the walk would have been skipped.
- **Item 40:** the trap list names `releaseBlock`'s swap-remove; compaction ALSO removes blocks, by
  `vector::erase` at `:4190`. Handling only the documented path would have desynchronised the
  offset array from `blocks_` after any compaction.
- **Item 44:** the premise that sweep leaves the bitmap all-zero is false, by a path the code's own
  comment does not list.
- **Item 47:** "the `find` can move behind `ECO_HEAP_VALIDATE`" — it is load-bearing, because a
  body below `alloc_buffer_size` lands in an ordinary block and IS reached by the inner sweep loop.

Three of those four were caught by an assertion or a count check rather than by review. **Write the
check that re-derives the invariant you are deleting** — that is what turned item 44 from a silent
`madvise` corruption into a 13-minute refutation.

## 8. Provenance

- **Continuation: `plans/gc-mark-and-bookkeeping-followup.md`** (W11-W14) — the eleven Tier-1
  items this series never built (38, 40, 51, 52, 54, 42-47), lowered to implementation detail
  against the 2026-09-23 tree. It reuses this file's method, gates and disposition rule
  verbatim; new rows append to §9 below, reference row `W1b`.
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
