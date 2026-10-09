# M4 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary is not built yet.

## 2026-09-28/29 — first implementation (plan §9 steps 1–6)

**Tree:** 2026-09-28, post-7c. On 2026-09-28 23:47 the M1 trace hooks landed in `OldGenSpace.cpp`
(`#include "TlaTrace.hpp"` at `:13`, hooks from `:3150` on). None is inside a region M4 models;
they shift the plan's line numbers by + 1 (below `:3150`) and + 25 (above `:4722`). MAPPING.md cites
the tree after the hooks. **Tools:** the dev image: tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b).
Quick runs: `run_models.py --model M4 --jobs 2 --workers 2 --java-opts=-Xmx3g`. Deep runs: one at
a time under `flock /tmp/tla-deep.lock`, `nice -n 10`, 4 workers, `-Xmx5g`.

### Results

Quick tier (`tla-check`), 44 rows, 2 workers each (the final run). States are TLC's distinct
states; times are wall-clock with two rows at a time.

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `MC_quick_cycle` | pass | pass | 2,952 | 2 s |
| `MC_quick_epoch_cycle` | pass | pass | 405 | 2 s |
| `MC_quick_epoch_idle` | pass | pass | 78 | 1 s |
| `MC_quick_epoch_idle_large` | pass | pass | 93 | 2 s |
| `MC_quick_epoch_l3` | pass | pass | 7,389 | 4 s |
| `MC_quick_sweep_functional` | pass | pass | 841,390 | 33 s |
| `MC_quick_sweep_fixed` | pass | pass | 734,610 | 27 s |
| `MC_quick_virgin_fixed` | pass | pass | 874,918 | 35 s |
| `MC_quick_minor_virgin` | pass | pass | 446 | 2 s |
| `MC_quick_sweep_race_bitmap` | violates `NoRaceBitmap` (CR-002) | as expected | 18,109 | 3 s |
| `MC_quick_sweep_race_phase` | violates `NoRacePhase` (CR-001) | as expected | 5,947 | 2 s |
| `MC_quick_sweep_release` | violates `ReleasedSafe` (CR-001 S1) | as expected | 184,173 | 10 s |
| `MC_quick_sweep_tail` | violates `DetachNotCurrent` (CR-014) | as expected | 56,654 | 4 s |
| `MC_quick_sweep_tail_release` | violates `ReleasedSafe` (CR-014) | as expected | 62,267 | 5 s |
| `MC_quick_sweep_tail_live` | violates `NoRaceLive` (CR-014) | as expected | 10,640 | 2 s |
| `MC_quick_sweep_large` | violates `ReleasedSafe` (CR-016) | as expected | 20,278 | 3 s |
| `MC_quick_minor_large` | violates `ReleasedSafe` (CR-016) | as expected | 2,466 | 2 s |
| 19 mutant rows (`mutants/*.cfg`, 14 mutants) | each its target | each as expected | 0 – 6,435 | 1 – 3 s |
| 8 control rows (`controls/*.cfg`) | 6 pass, 2 violate | each as expected | 5,703 – 858,262 | 3 – 32 s |

The whole quick tier: 44/44 as expected in 180 s (two rows at a time). A failing row's state count
is where TLC stopped, and varies from run to run with two workers.

Deep tier (`tla-check-deep`), 4 workers each, one at a time:

| Configuration | What it stretches | Expected | Result | States | Time |
|---|---|---|---|---|---|
| `MC_deep_cycle_w3` | cycle, 3 workers, 3 promotions each | pass | pass | 406,962 | 52 s |
| `MC_deep_sweep_n3` | sweep + four fix candidates, 3 promotions each | pass | pass | 9,589,876 | 3 min 30 s |
| `MC_deep_functional_n3` | sweep, the code's own finalize and phase (two S1 fixes only), 3 promotions | pass | pass | 10,122,694 | 4 min 5 s |
| `MC_deep_sweep_w3` | sweep + four fix candidates, 3 workers, 1 promotion each | pass | pass | 1,422,047 | 30 s |
| `MC_deep_sweep_1class_w3` | sweep with the modelled class only, 3 workers, 3 promotions each | pass | pass | 484,877 | 7 s |
| `MC_deep_minor_w3` | minor_virgin (the code as it is), 3 workers, 3 promotions each | pass | pass | 80,228 | 3 s |
| `MC_deep_sweep_breadth` | sweep + four fix candidates, the `Breadth` branches | pass | pass | 4,044,342 | 1 min 23 s |
| `MC_deep_virgin_breadth` | sweep_virgin + four fix candidates, `Breadth` | pass | pass | 4,606,356 | 1 min 24 s |

**The first `sweep_w3` was stopped.** Sweep + four fix candidates with 3 workers and 2 promotions
each had 107,322,082 distinct states and 13.3 M on the queue after 34 minutes, and its disk use was
growing by about 12 GB every 10 minutes (21 GB, with 48 GB left on the shared disk). It was killed
(no violation had been found) and replaced by the three bounded 3-worker rows above: two size
classes with one promotion each, one class with three, and `minor_virgin` with three.

The deep rows ran on scratch copies of the model directory. The first five were copied before
`minor_virgin` and `sweep_1class` were added to `MC.tla`; that change does not touch their
scenarios (the quick tier's passing counts are unchanged).

**Plan §9 step 5 (the heap as constants).** The fixed-heap version was checked first (in scratch
space). After moving the heap into `MC.tla` the step-2 configurations gave identical distinct-state
counts: `cycle` 2,952, `epoch_cycle` 405, `epoch_idle` 57 (78 after V joined the epoch heap, below),
`sweep_functional` 841,390, `sweep_fixed` 734,610.

### The register entries, reproduced (shortest counterexamples, TLC with 1 worker)

W1, W2 are the two workers. "Other class" is a promotion of the second size class (see change 3).
Each trace was checked against the code; the model over-approximates only the shrink's sizing
(any subset of candidates) and the class of a flushed cell.

- **CR-002, `MC_quick_sweep_race_bitmap` → `NoRaceBitmap`, 23 states.** W1 claims U's unit 2 and
  allocates cell 11. W2 (other class) locks and sweeps D's dead run and the iteration `[1, 2]`
  (flushes gap 1, clears 2's bit), ends the slice and pops nothing. W1's next promotion flushes
  its exhausted chunk, fails to claim, locks, batch-pops `{1, 6}` and unlocks, then finalizes cell 1
  outside the lock: `fetch_or` on byte M1 (`finalizePoppedCellW` `OGS:1084`). W2 locks again and
  sweeps `[3]`: `nextSetBit`'s plain `memcpy` of M's word (`OGS:5364`) is unordered with W1's
  `fetch_or`. The plan's timeline (c).
- **CR-001 (race), `MC_quick_sweep_race_phase` → `NoRacePhase`, 19 states.** W1 allocates cell 11
  from its chunk and reads `gc_phase_` for the colour (`finalizeBitmapCellW` `OGS:1136`, no lock). W2
  (other class) sweeps D and M in one hold and completes on the in-loop path: `gc_phase_ = Idle`
  (`OGS:5272`) under `promo_mu_`. Nothing orders the two.
- **CR-001 (S1 half), `MC_quick_sweep_release` → `ReleasedSafe`, 32 states.** W1 allocates 11. W2
  (other class) sweeps D's run and ends the slice. W1 batch-pops D's cells `{6, 7}` and unlocks. W2
  sweeps M to the end and completes on the in-loop path (deferred, `OGS:1365`). W1 finalizes cell 6:
  it reads Idle (`OGS:1076`), so no bit and no `live_bytes`. The merge returns 7 to the free list; the
  deferred shrink (`OGS:1531-1534`) releases D (fully swept, `live_bytes` 0) with cell 6 in it. The
  same trace fails with `phase_atomic` (`controls/phase_atomic_release`): the moved decision point.
- **CR-014 (FATAL), `MC_quick_sweep_tail` → `DetachNotCurrent`, 25 states.** W1 claims U's last
  unit. W2 fails to claim, locks, `advanceSharedW` publishes V from `partial_`, W2 claims V's only
  chunk and allocates cell 12 inside the hold: V is Current with `live_bytes` 0 (W2's `pending_live`
  is unflushed). W2's next promotion is of the other class: it locks, sweeps D and M in one hold, and
  completes on the tail path (`OGS:5492-5498`). Pass 1 of the light shrink picks V; its
  `releaseBlockToAllocator` → `detachFromAllocation` aborts (`OGS:713-718`).
- **CR-014 (silent release), `MC_quick_sweep_tail_release` → `ReleasedSafe`, 26 states** (with
  `count_until_shrink`, so CR-001's path is closed). W2 (other class) sweeps D, `[1, 2]`, `[3]` and
  ends the slice. W2 (modelled class) batch-pops `{1, 6}`, finalizes 1 (counted), keeps 6 in its
  stash. W2 (other class) sweeps `[4, 5]` and completes on the tail path: the shrink releases D while
  W2's stash holds cell 6.
- **CR-014 (race), `MC_quick_sweep_tail_live` → `NoRaceLive`, 21 states, on the code as it is.** W1
  allocates 11; its next promotion finds the chunk exhausted and flushes it (`flushCursorW`, relaxed
  `fetch_add` `OGS:1035`, no lock). W2 (other class) sweeps everything and completes on the tail
  path: `computeFragmentationStats`' plain reads (`OGS:6403`) are unordered with that `fetch_add`.
- **CR-016 (stash), `MC_quick_sweep_large` → `ReleasedSafe`, 17 states** (with `tail_defers` and
  `count_until_shrink`). W1 allocates 11. W2 (other class) sweeps D's run. W1 batch-pops `{6, 7}` and
  unlocks. W2's exact-size promotion locks and flips D (`allocateFromEmptyRegularBlocks`: fully swept,
  `live_bytes` 0, not Current) while W1's stash holds both cells.
- **CR-016 (retired chunk), `MC_quick_minor_large` → `ReleasedSafe`, 16 states: new.** No sweep is
  pending and no cycle runs. W1 allocates 11 and flushes. W2 locks and publishes V. W1 claims V's only
  chunk lock-free before W2 does. W2's claim fails, so its `advanceSharedW` retires V (`kAllocNone`,
  `OGS:1227`), and W2 allocates outside the model. W2's exact-size promotion flips V: the skip at
  `OGS:2677` covers only `kAllocCurrent`, `detachFromAllocation` returns early for `kAllocNone`, and
  W1's cursor still points into V. The comment at `OGS:2674-2675` names this hazard.

Checked but **not** reachable as a separate path in the model's heap: CR-001's S1 half "through a
pop under the lock after the completion". With N > 1 rung 2 is always the batch pop, whose first
cell is finalized after the unlock (`OGS:1635`). The ladder's in-lock pop (`finalizePoppedCell`)
follows only a sweep slice of the same hold, and a sweeper of the popping class completes only with
its list empty. A probe invariant found only the stash path.

### Negative controls (A6): every invariant has at least one

Each counterexample was read; each is the intended story in its shortest form.

| Mutant row | Target | Shortest story (states) |
|---|---|---|
| `plain_allocate_black` | `NoLostRequiredBit` | mid-cycle the mutator pops cell 1 and loads M1 = `{2}` plainly; the marker sets 3; the mutator stores `{1, 2}`: bit 3 lost (20) |
| `plain_allocate_black_race` | `NoRaceBitmap` | the marker's `fetch_or` on M1 vs the mutator's plain load (5) |
| `plain_stash_black` | `NoLostRequiredBit` | W1 batch-pops `{1, 4}`; its finalize of 1 loads M1 = `{}`; the marker sets 2; W1 stores `{1}` (29) |
| `cursor_on_t0` | `IM13` | W1 claims a chunk of t0 block Z (3) |
| `cursor_on_t0_live` | `NoOverwriteLive` | W1 allocates cell 14, live but not yet marked (5) |
| `chunk_unit_subbyte` | `AllocMapExact` | units `{8}`, `{9, 10}`, `{11}`: W1 (10) and W2 (11) both load U2 = `{}` and store their own bit; 10's bit is lost (30) |
| `chunk_unit_subbyte_race` | `NoRaceBitmap` | W1's last scan of unit `{8}` reads U1; W2's `setBit` of 9 writes U1 (8) |
| `chunk_unit_subword` | `NoRaceBitmap` | W1's `nextFreeCell` reads the word U1+U2; W2's `setBit` of 10 writes U2 (8) |
| `claim_after_exhaustion` | `ClaimsInRange` | after units 1 and 2, W2 claims unit 3 (10) |
| `grant_t0_block` | `NoOverwriteLive` | the collector allocates cell 14 in t0 block Z (3) |
| `grant_t0_block_tv5` | `TV5` | the initial state |
| `grant_includes_cursor` | `NoDoubleAlloc` | the collector and the mutator's cursor both take cell 18 (5) |
| `grant_claim_plain` (new, L3) | `NoDoubleAlloc` | both members load claim word 0, both claim unit 1, both allocate 16 (9) |
| `shrink_ignores_tenure` | `ReleasedSafe` | the mutator's sweep completes; the light shrink releases the live grant G (7) |
| `flip_ignores_tenure` | `ReleasedSafe` | the mutator's exact-size allocation flips G (8) |
| `marker_on_post_t0` | `NoRaceBitmap` | W2's fast-path read of U2 vs the marker's `fetch_or` of stale cell 11 (7) |
| `marker_on_post_t0_epoch` | `NoRaceBitmap` | the marker's `fetch_or` of stale cell 16 vs the collector's read of G1 (3) |
| `launch_before_t0` | `NoGrantAtT0` | the grant is still live at `U_T0` (8) |
| `virgin_unswept` (new) | `FreeBehindCursor` | W2 publishes V while V is still in the sweep queue, and claims its chunk (8) |

`NoRacePhase`, `NoRaceLive` and `DetachNotCurrent` are rejected by the register rows above (the
code as it is), as M1's `MarkerFootprint` is by CR-017.

### Fix candidates (plan §5 positive controls): evidence for the fix designs

| Row | Result | Meaning |
|---|---|---|
| `controls/finalize_in_lock` | pass (695,772) | finalizing every popped cell under `promo_mu_` (the first one before the unlock, stashed ones by taking the lock) removes CR-002 |
| `controls/finalize_in_lock_phase` | violates `NoRacePhase` (19) | it does not fix CR-001: rung 1 reads `gc_phase_` too |
| `controls/phase_atomic` | pass (831,220) | a relaxed-atomic `gc_phase_` removes CR-001's race |
| `controls/phase_atomic_release` | violates `ReleasedSafe` (32) | but not its S1 half: the decision still moves from pop to finalize |
| `controls/count_until_shrink` | pass (841,390) | counting `live_bytes` while the shrink is deferred removes CR-001's S1 half |
| `controls/tail_defers` (sweep_virgin), `_release`, `_live` | pass (858,262; 841,390; 831,364) | routing the tail path through `sweepCompleteInPromotion` removes all three CR-014 consequences |
| `MC_quick_sweep_fixed`, `MC_quick_virgin_fixed` | pass, every property | the four candidates together |
| `MC_quick_sweep_large`, `MC_quick_minor_large` | fail with the other fixes on | CR-016 needs its own fix (none modelled): the flip must skip blocks with popped-unfinalized cells and retired shared blocks referenced by chunks, or stay off inside a parallel minor |

### Changes from the plan's sketch (plan §4.6), and why

1. **Assertions became named invariants** (brief; parent plan §6.1). `W_Shrink`'s assert is
   `DetachNotCurrent`, `U_T0`'s is `NoGrantAtT0`, through a ghost `fatal`.
2. **`TV5` is a state predicate** (`grantOn => ...`). As a constant formula TLC reports "The
   invariant of TV5 is equal to FALSE", which the runner cannot match.
3. **A second size class** (`TwoClasses`, sweep scenarios). With one class `sweep_tail` passed:
   a worker reaches sweep-on-demand only after `advanceSharedW` returned false, and that call
   retires its class's exhausted shared block (`kAllocNone`, relaxed store 0, `OGS:1227-1228`).
   So the Current block the FATAL needs always belongs to another class than the sweeper's: pass 1
   is class-blind. The other class also expresses the plan's "the sweeper leaves the flushed cells
   for another class" (CR-002). A sweeper of the modelled class now always pops the head after its
   slice, as `tryAllocateFromFreeLists` does.
4. **`lazySweep`'s early exit** (`OGS:5478-5486`): at a block boundary, a sweeper of the modelled
   class with a non-empty list must return; the in-loop and tail completions need an empty list.
   The sketch allowed any of the three at any time.
5. **`advanceSharedW` retires the exhausted block** (`shared := none`) before the batch pop and the
   ladder. **The refill's claim and first allocation stay inside the hold** (`OGS:1607-1611`); the
   sketch moved them after the unlock, which loses the lock's ordering of that allocation's
   `gc_phase_` read.
6. **The chunk's flush happens at exhaustion** (`cursorAllocateW` `OGS:1161`), at the start of the
   next promotion, not at the next claim: `claimChunkW`'s own flush (`OGS:1187`) finds nothing.
7. **`cursorAllocateW`'s fast path** reads the next cell's byte only (`OGS:1151`); only a miss runs
   `nextFreeCell`'s word reads. The model keeps the cursor position (`pos`).
8. **The first popped cell** is finalized right after the unlock (`fin`, `OGS:1635`), as part of the
   same promotion; the rest wait in the stash until the cursor and the claims fail (`OGS:1581`). A
   cell stays in `stash` until its finalize completes, so `ReleasedSafe` covers the whole finalize.
9. **`finalizeBitmapCellW`'s order**: `setBit` (`OGS:1132`), then the `gc_phase_` read (`:1136`). The
   sketch read the phase first.
10. **A failed claim acquires** the shared word's release sequence (`sharedvc`); the retire's relaxed
    store resets it (a plain store heads no release sequence). The sketch did not model it.
11. **The shrink releases any subset** of its candidates, and the flip may take none (a free large
    block or a fresh one). The sketch released every candidate, which is not an over-approximation.
    Candidates are restricted to the blocks of the scenario (`Present`).
12. **`FreeBehindCursor` also covers chunk cells**, and has a mutant (`virgin_unswept`, new).
13. **`sweep_tail_live` runs on the code as it is** (`MUTANT = {}`): its only path is CR-014's.
14. **New rows:** `minor_virgin` (pass) and `minor_large` (CR-016's retired-chunk variant);
    `epoch_idle_large` (the flip with its tenure skip intact; V joined the epoch heap so the flip
    has a real candidate); `epoch_l3` in quick (7,389 states); `sweep_1class` (deep only: the
    sweep with the modelled class alone, for three workers).
15. **`Breadth`** (deep only): promotions of the other class that finish lock-free, and the ladder's
    virgin or split rung before sweeping. Their only modelled effects are `n + 1`, reads and lock
    synchronisation, so they cannot create a violation of a checked property; they cost 5× states
    (`sweep_functional` 4.2 M vs 0.84 M).
16. **L3 (step 6):** `grantAllocateShared` with the relaxed claim CAS (no synchronisation), a
    shared survivor count `gwork`, grant G of two chunk units (G1, G2); mutant `grant_claim_plain`.
17. **Tool traps met:** a macro parameter named like a bound variable of another macro (`x` in
    `FinPhase` vs `Acc`'s `{x.l : x \in ...}`) is captured by the substitution; and in a macro, a
    use of the argument after an assignment to the argument's variable in the same step is primed
    (`fin := 0; cell := fin` made `cell` 0). Both are primer rule 13's cousins.

### Code reading findings (for the register)

- **06 P§3.11 has two holes.** `live_bytes` has no row (relaxed adds outside the lock, plain reads
  and a plain write under it). Row M6 lists `gc_phase_` with the rule `promo_mu_`, which CR-001's
  readers break; the plan's A3 says the row is missing, but it is there. Row M5's "distinct blocks
  never share a bitmap byte" is out of date for chunked cursors (CR-022).
- **CR-014's tail path needs an empty target list** after the last block's flush (else the early
  exit at `OGS:5478` returns first), and the FATAL needs a Current block of another class (change 3).
- **Stale comment:** `allocate()` (`OGS:1871-1875`) says `gc_phase_` is "never Marking";
  `beginMarkCycle` sets it (`OGS:4156`). Premise drift only.

### Left for the next wave

- **The gc-heap-tsan scenario and trace validation** (plan §8, §9 step 7). What the model now says
  the scenario needs, beyond plan §8:
  - promotions of **at least two size classes** in one parallel minor: CR-014's FATAL needs a
    Current shared block of a class other than the sweeper's, and the tail path needs the sweeper's
    own list empty after the last block's flush;
  - a queued or virgin uniform block that the refill publishes (V), so a Current block can have
    `live_bytes` 0;
  - an exact-size (`alloc_buffer_size`) promotion both with a pending sweep (CR-016, stash) and
    without one (CR-016, retired chunk).
  - Hooks, in addition to plan §8's table: `cls` on every lock, claim and sweep event; `retire`
    (`advanceSharedW`'s relaxed store 0); `claimFail` (a failed claim's acquire load); `flush`
    (`flushCursorW`, block and amount); `fastPath` vs `scan` on cursor reads; `fin` vs `stashFin`;
    `earlyExit` at a block boundary. They go through `TlaTrace.hpp`'s `ECO_TLA_TRACE`, with a
    `traces.txt` row on the `gc-heap-trace` harness.
  - `TracePromoBitmap.tla` reads the heap layout from the log's first line into the constants of
    §9 step 5 (already constants), and replays with the race detector on.
- **The canary lines** (plan A9, parent plan §7): listed in the orchestrator report of 2026-09-29.
- **W3, W3f, W4b** (A4): W pending.

## 2026-09-29 — trace validation and the TSan scenario (plan §8, §9 step 7; rule A5)

**Tree:** 2026-09-29, with the shared trace infrastructure (`TlaTrace.hpp`, `test/tla/trace/`,
`common/Trace*.tla`, `run_traces.py`) and M1's, M3's and M7's hooks; other agents were adding hooks
to the same files the same day. **Tools:** as the first entry, plus g++ 12 with TSan, gdb.
**Verdict:** every trace accepted and every negative control rejected, after two model fixes the
traces forced (below). The replays with the race detector on find CR-002 in every multi-threaded
run; the TSan stress reports CR-001, CR-002 and CR-016 (with heap corruption), not CR-014; two new
defects: a data race in the validate-only V11 walk and a debug assert on the ladder's bag rung.

### What was built

- **Hooks** in `runtime/src/allocator/OldGenSpace.cpp` only (compiled out unless `ECO_TLA_TRACE`,
  and even then recorded only while `::Elm::tla_m4` is set): 38 `m4.*` call sites in 17 functions,
  plus a trace-only capture in `allocateFromEmptyRegularBlocks`; MAPPING.md §8 lists them. Trace-only state: `tla_m4`, `tla_m4_tick`
  (the `promo_mu_` clock, touched only under the lock), `tla_m4_flip`, and captures (`m4_old`,
  `m4_rs`, `m4_rb`) inside `ECO_TLA_TRACE_ONLY`. **Production compile unchanged:** preprocessing
  `OldGenSpace.cpp` with `build/`'s `EcoRuntimeStatic` flags gives one `((void)0)` per hook call site
  (46 in the file, M1's included), no `tla_m4`, `m4_` or `tlatrace` token, and the object compiles
  with the same single pre-existing warning (`NO_BLOCK` unused).
- **Harness** `test/gc-heap-tsan/promo_sweep.cpp` (in both builds; `heap_driver.cpp` dispatches
  `promo`): the TSan stress `gc-heap-tsan promo …` (README.md there) and the trace scenario
  `gc-heap-trace promo <seed> [workers [trees [jitter]]]` with its heap header (MAPPING.md §8).
  The default `gc-heap-tsan` run is unchanged (`promo` must be the first argument).
- **Specs:** `TracePromoBitmapData.tla` (the log's header as constants), `TracePromoBitmap.tla`
  (`Matched`, hidden steps), `TracePromoBitmap.cfg`, `.keep`, and `TraceRace.cfg` (by hand, below).
- **Rows** in `test/tla/traces.txt`: 5 accept, 7 `mutate=` rejects.

### Model changes (the traces found the first two)

1. **The ladder's virgin rung was missing.** The first replay stopped at an `m4.pub` of a block not
   in the header: after a failed sweep-on-demand, `ladderFrom2W`'s `virgin()` publishes a fresh
   block and claims from it, still in the hold. New label `W_Virgin` and constant `VirginQ` (`MC`:
   `<<>>`, so no quick or deep row changes its heap; the trace: the log's virgin blocks).
2. **A spurious retry.** After a failed ladder the model went back to `W_Loop` with `n` unchanged
   and could retry the whole promotion (claim, lock, sweep) any number of times; the code never
   does (the virgin rung, then bag and panic, all in the same hold). `W_PopAfterSweep` with no cell
   of the class now goes to `W_Virgin`, and an empty `VirginQ` completes the promotion outside the
   model. This removed behaviours the code does not have, and shrank the sweep rows about 55×.
3. For the trace's scale: `NAllocs` is a function (per-worker promotion counts from the log);
   `ClaimK` (a claim's units; `MC`: `{1}`) and `BatchMax` (`MC`: 2) are constants; `NextPos` fixes
   the cursor's next position for bit-indexed cell ids (`pos := cell + 1` was right only for
   `MC`'s consecutive ids; no `MC` count changed).

**Re-checked:** quick tier 44/44 as expected in 70 s (two rows at a time). The counts that moved:
`sweep_functional` 841,390 → 15,312, `sweep_fixed` 734,610 → 14,804, `virgin_fixed` 874,918 →
16,732, `sweep_release` 184,173 → 14,715, `sweep_tail` 56,654 → 11,112, the controls alike
(5,703–858,262 → 2,563–16,502), `minor_virgin` 446 → 500, `minor_large` 2,466 → 2,667; mutants by
a few states. Deep tier (under the lock, 4 workers) 8/8 pass in 80 s: `cycle_w3` 501,030,
`sweep_n3` 200,680, `functional_n3` 232,160, `sweep_w3` 13,547, `sweep_1class_w3` 428,831,
`minor_w3` 102,776, `sweep_breadth` 62,544, `virgin_breadth` 62,538. The eight register
reproductions (TLC, 1 worker) still fail with their invariants at the same lengths (23, 19, 32,
25, 26, 21, 17 states) except `minor_large`, now 17 (the retired chunk's owner passes `W_Virgin`).

### Trace validation results (`run_traces.py --model M4`, 2 × 2 TLC workers)

| Row | Threads | Events | Expected | Result | TLC states | Time |
|---|---|---|---|---|---|---|
| `promo,1,3,4` | 3 | 348 | accept | accept | 975 | 9 s |
| `promo,2,3,4` | 3 | 360 | accept | accept | 1,359 | 7 s |
| `promo,4,4,4` | 3 of 4 | 349 | accept | accept | 768 | 7 s |
| `promo,5,3,5` | 3 | 459 | accept | accept | 1,514 | 8 s |
| `promo,7,4,3,100` (jitter 100 µs) | 1 (`mut` alone) | 236 | accept | accept | 323 | 6 s |
| `promo,1,3,4` `drop:m4.clr:1` (a clearBit that never happened) | | 347 | reject | reject | 127 | 4 s |
| `set:m4.sw:1:l=1` (a sweep iteration at the wrong cell) | | 348 | reject | reject | 126 | 4 s |
| `set:m4.cur:1:c=1` (a cursor cell that is not the next free one) | | 348 | reject | reject | 24 | 3 s |
| `set:m4.fin:1:black=false` (a stashed cell finalized White while the phase read was Sweeping) | | 348 | reject | reject | 105 | 4 s |
| `set:m4.batch:1:cnt=99` (a batch larger than the list) | | 348 | reject | reject | 103 | 4 s |
| `set:m4.ladder:1:pend=false` (no pending sweep while sweeping) | | 348 | reject | reject | 122 | 4 s |
| `swap:m4.sw:1` (a clearBit before its iteration's scan) | | 348 | reject | reject | 126 | 4 s |

12/12 as expected on five runs (the logs differ every run; the table is the fourth). Events logged
per run: claims of 1, 2 and 4 units, publishes, retires, lock holds, batch pops of up to 3 cells,
first-cell and stash finalizes (`fin` + `finb`), ladders, failed pops, sweep iterations and clears,
early exits and budget ends, in-lock pops, the merge. **Not in any log:** sweep completions
(`swend` paths 2 and 3), the shrink, the virgin rung, the flip, splits, other size classes; the
`m4.split`, `m4.large`, `m4.rel` and `m4.shrink` events are not matched yet, so a log with one is
rejected (conservative).

**The race detector on the replays** (`TraceRace.cfg`: the trace spec plus `NoRaceBitmap`,
`NoRacePhase`, `NoRaceLive`, `NoDoubleAlloc`, `ClaimsInRange`, `FreeBehindCursor`,
`DetachNotCurrent`, `ReleasedSafe`): all 20 kept logs (four runs × five rows). **Every
multi-threaded log (16 of 16) violates `NoRaceBitmap`: CR-002 on the real allocator.** Each time a
worker holding `promo_mu_` sweeps M (`m4.sw`: `nextSetBit`'s plain word read) while another worker,
outside the lock, finalizes a batch-popped cell of the same word (`m4.finb`: `setMarkBitAtomic`'s
relaxed `fetch_or`); its last lock acquisition does not order the `finb`. Seed 1: `mut` finalizes
cells 3 and 9 of M (bytes 0 and 1) after its unlock, `eco-mark1` locks and sweeps M's word 0.
The single-threaded jitter row is race-free and accepted. No other invariant is violated.

### The TSan stress (`gc-heap-tsan promo`, under the lock, `nice`, `history_size=4`)

The first version promoted directly rooted young values: worker 0 copies what the roots point at
before the gang starts, so every promotion was worker 0's, and 40 rounds gave 0 warnings. It now
promotes young trees (the gang steals subtrees), uses 144-byte sweep slices and
`demote_live_fraction = 0.5`, alternates rounds with a long and a short sweep backlog, and takes
`exact` (the exact-size Arrays) and `sweep_bytes` arguments. 17 runs with reports on (seeds 1–11;
2, 3 or 4 workers; jitter 0–500 µs; slices 144 B – 64 KiB; 10 or 40 rounds; 13 without Arrays)
and 12 more under gdb with reports off (to catch the aborts and count completions):

| Entry | Reported? | The pair TSan shows |
|---|---|---|
| **CR-002** | **yes**, at every slice size (≥ 1 report in 10 of the 13 runs without Arrays) | `lazySweep` → `nextSetBit` → `loadWord` (plain 8-byte read, `OGS:5447`, via `sweepOnDemandAllocate` ← `ladderFrom2W`, holding `promo_mu_`) vs `setMarkBitAtomic`'s `fetch_or` (`OGH:1832`) in `finalizePoppedCellW` (`OGS:1100`, after the unlock); both orders |
| **CR-001** | **yes**, in every run with slices ≥ 4 KiB (8 of 8), never at 144 B (the sweep then never completes inside a minor) | `lazySweep`'s in-loop completion `gc_phase_ = Idle` (`OGS:5352`, under `promo_mu_`) vs `finalizePoppedCellW`'s plain `gc_phase_` read (`OGS:1089`, no lock) |
| **CR-014** | **no** | the tail completion never ran: under gdb, 0 hits of its line (`OGS:5594`) in 4 runs of 40 rounds (one cut short by the V11 abort), against 35 and 56 in-loop completions inside parallel minors in two of them. The tail path needs the slice to run out on the last block's final iteration with the sweeper's own list empty; the stress does not produce that |
| **CR-016** | **yes**, with `exact` = 1 (in 2 of 4 such runs) | `allocatePromotion`'s exact-size path → `allocateFromEmptyRegularBlocks` flips a block another worker is still allocating in: `MarkBitArena::drop`'s `memset` (`BlockTable.hpp:320`) and the Array's copy (`NurseryParallel.cpp:301`) over that worker's `setBit` (`finalizeBitmapCellW`) and its copied objects; also the flip's plain `live_bytes` read (`OGS:2750`) vs `flushCursorW`'s `fetch_add` (`OGS:1048`). One run aborted on heap corruption: `Allocator::resolve`: "Invalid tag after forward resolution" (another, in the first smoke run: HEAP_BUILDER_001 in `scanObject`) |

**Validator aborts:** no IM* abort and no `detachFromAllocation` FATAL. One **V11** abort
(`[heap-validate] lazySweep: V11 block id 13 parse breaks … (step 22544392 …)`, slice 4 KiB), and
the V11 walk's reads are the most frequent report (next section). The default run
(`gc-heap-tsan` with no argument) is unchanged: rebuilt with the scenario, it prints "heap_driver PASS", exit 0, 0 TSan warnings (under the lock, about 11 minutes).

### Findings

1. **New: the validate-only V11 walk races with parallel promotion** (`lazySweep`, `#if
   ECO_HEAP_VALIDATE`, `OGS:5548-5566`). At a gap-swept block's boundary it reads every header of
   the block (`getObjectSize`, `AllocatorCommon.hpp:424`), holding `promo_mu_`, while other workers
   write headers and copy objects into cells they popped from that block and finalize after the
   unlock (`finalizePoppedCellW` `OGS:1090`, `copyClaimed` `NurseryParallel.cpp:304`). TSan: in 11
   of 17 runs; a half-written header aborts the walk (seen once under TSan, and in the trace
   harness with 8 trees, which is why the trace rows use 3 to 5). Validate builds only; the
   register has no entry for it.
2. **New: the ladder's bag rung breaks `allocateFromBagPage`'s precondition.** `ladderFrom2W`
   (`OGS:1395`) calls `allocateFromBagPage(requested_size)` for a size-classed promotion when
   `virgin()` fails; its assert (`OGS:2460-2462`) requires `request_cls >= num_size_classes_`. 5 of
   21 runs of the final stress without Arrays aborted there (gdb: a gang member, `cls` 3, 32 bytes), with no
   out-of-space message, so `startVirginBlockShared` had published the fresh block and the
   publisher's own `claimChunkW` loop failed: the other workers' lock-free claims took the whole
   block first (2 units of 64 cells for 32-byte cells in a 4 KiB block; a claim takes up to 16).
   The model has the window only when `VirginQ` is non-empty (the trace spec; every `MC` row has
   none), and there it sends the failed claim back to `W_Locked` instead of to the bag rung, so it
   cannot show the assert; a trace build aborts there, so no log has the path. A model row would
   need a virgin block in an `MC` heap and a `fatal` for the bag rung. What the release build does
   there is not checked. The mutator's ladder (`OGS:971`) and `panicSweepAndRetryAllocation`
   (`OGS:2307`) make the same call, reachable there only when no page is left.
3. **CR-016 corrupts the heap in practice**, as `minor_large` predicts: the flipped block is a
   retired chunk still in use.
4. **CR-002 happens in real runs** (the replays above, and TSan).
5. **Stale comments:** `demote_live_fraction`'s default is 0.3 (`AllocatorCommon.hpp:325`); the
   comments at `OldGenSpace.hpp:1893` and `OldGenSpace.cpp:3939` say 0.5.
6. **Tool traps:** (a) TLC evaluates a constant bound with `<-` to a zero-arity definition at every
   use, and the definitions are processed module by module; a definition derived from the log
   (`ndJsonDeserialize`) must live in a module extended **before** the spec, else every reference
   re-parses the log (start-up went from over 10 minutes to 6 s with `TracePromoBitmapData.tla`);
   a recursive definition over the log is slow too (a function constructor replaced it). (b) The
   merger reserves `t s ts ev i n vc nxt pk` as field names (`m4.batch`'s count is `cnt`). (c) A
   write hook must log **after** its store, or a reader of the old value may be ordered after it
   and the merge finds no interleaving (`pub`, `retire`, the completions). (d) The merger treats a
   failed merge as an error, not a rejection: `mutate=` rows must not drop or doctor events that
   carry `rmw`, `rd` or `clk` fields.

### Limits

- The trace scenario has one mixed block and one class; no log reaches a completion, the shrink,
  the virgin rung or the flip (their events are logged but not matched yet).
- The TSan stress never reaches CR-014's tail path (above).

### Canary lines for the hooks' files (for `test/tla/manifest.txt`; not built yet)

```
census  -  runtime/src/allocator/OldGenSpace.cpp  -                               M1,M4,…
region  -  runtime/src/allocator/OldGenSpace.cpp  m4-trace-hooks                  M4   (the ECO_M4_TRACE macros and trace-only globals)
region  -  runtime/src/allocator/OldGenSpace.cpp  finalizePoppedCellW             M4
region  -  runtime/src/allocator/OldGenSpace.cpp  finalizeBitmapCellW             M4
region  -  runtime/src/allocator/OldGenSpace.cpp  cursorAllocateW                 M4
region  -  runtime/src/allocator/OldGenSpace.cpp  claimChunkW                     M4
region  -  runtime/src/allocator/OldGenSpace.cpp  publishShared                   M4
region  -  runtime/src/allocator/OldGenSpace.cpp  advanceSharedW                  M4
region  -  runtime/src/allocator/OldGenSpace.cpp  startVirginBlockShared          M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  ladderFrom2W                    M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  beginParallelPromotion          M4
region  -  runtime/src/allocator/OldGenSpace.cpp  endParallelPromotion            M4
region  -  runtime/src/allocator/OldGenSpace.cpp  allocatePromotion               M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  finalizePoppedCell              M4
region  -  runtime/src/allocator/OldGenSpace.cpp  tryAllocateFromFreeLists        M4
region  -  runtime/src/allocator/OldGenSpace.cpp  sweepOnDemandAllocate           M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  panicSweepAndRetryAllocation    M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  allocateFromBagPage             M4,M7  (the precondition of finding 2)
region  -  runtime/src/allocator/OldGenSpace.cpp  allocateFromEmptyRegularBlocks  M4
region  -  runtime/src/allocator/OldGenSpace.cpp  lazySweep                       M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  onSweepComplete                 M4
region  -  runtime/src/allocator/OldGenSpace.cpp  releaseBlockToAllocator         M4,M7
region  -  runtime/src/allocator/OldGenSpace.cpp  pushSpanOnFreeLists             M4   (the harness replays its packer)
file    -  runtime/src/allocator/BitmapScan.hpp   -                               M4
file    -  test/gc-heap-tsan/promo_sweep.cpp      -                               M4
```

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 62 pins
name this model (3 census, 4 file, 15 grep, 40 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.

## 2026-09-29 — ABA audit: a released block re-issued at the same id and start (`reuse_released`)

**Why.** Register CR-034 is an ABA found outside the models (an address reused by another object
after a STW major). M4's release contract `ReleasedSafe` treats a released block as gone for good,
so it cannot see what happens once the block's id and extent are handed out again. In the code both
are recycled: `BlockTable::add` takes the most recently freed id (LIFO, `BlockTable.hpp:158-186`),
and `Allocator::acquireOldGenBlock` takes the first fitting extent of `old_gen_free_blocks_`
(`Allocator.cpp:782-793`), which is the one just released when that list was empty.
`releaseBlockToAllocator` (`OGS:6357`) detaches the block from `partial_` and the mutator cursor,
unlinks its free-list cells and clears its page-index slots, but it cannot reach a worker's chunk
or stash (CR-014, CR-016). No code checks that a re-issued id is a new block: `mark_.slot(id)` is
the same arena slot (zeroed by `mark_.assign`, `BlockTable.hpp:310-319`), and `blockIdFor` maps the
old cell's address to the new block.

**Model change (constant-guarded, off in every earlier configuration).**
- `W_Virgin` (`ladderFrom2W`'s `virgin()` → `startVirginBlockShared`, `OGS:1349`): with
  `"reuse_released" \in MUTANT` and a released block that has chunk units, the worker may
  re-materialise that block as the class's shared block: its mark bytes cleared (`mark_.assign`'s
  memset, recorded as plain writes), `live_bytes` 0, fully swept, removed from `released`, then
  published and claimed inside the hold, as for `VirginQ`. The other choice is the old one (a cell
  outside the model). Only the code's virgin rung in a parallel minor re-issues a block here.
- `MC.tla`: under `reuse_released` block D (the all-dead mixed block) has one chunk unit `{6, 7}`,
  the cells of the virgin uniform block re-carved at its start; `MC_NAllocsReuse` (worker 1 gets one
  promotion more than worker 2); `MC_NoFatal == fatal = {}`, used as a `CONSTRAINT` by the new
  rows, because a FATAL ends the process and nothing after it is a behaviour of the code (the rows
  list only `NoDoubleAlloc`, not `DetachNotCurrent`).

**Results** (TLC, 2 workers, in `run_models.py --model M4`: 47/47 as expected in 123 s; every
earlier row's state count unchanged, e.g. `cycle` 2,952, `minor_virgin` 500, `epoch_l3` 7,389):

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `MC_quick_sweep_tail_reuse` (`reuse_released`, NA = 3, worker 1: 4) | violates `NoDoubleAlloc` | as expected | 1,143,358 | 43 s |
| `MC_quick_sweep_tail_nda` (the same, no re-issue) | pass | pass | 1,165,203 | 39 s |
| `controls/tail_defers_reuse` (CR-014's fix candidate + re-issue) | pass | pass | 699,789 | 32 s |

**The counterexample** (44 states, the code as it is: no fix candidate on). W1 (other class)
sweeps D's dead run and `[1, 2]` and ends the slice. W1 claims U's unit 2 and allocates 11. W2
fails to claim, locks and batch-pops `{1, 6}`: cell 6 (of D) is in its stash. W1 (other class)
sweeps `[3]` and `[4, 5]` and completes on the **tail path** (CR-014): the light shrink releases D
(fully swept, `live_bytes` 0) and unlinks 7. W2 finalizes 1, then (next promotion) its stashed 6,
reading Idle: a White header, no bit, in released memory. W1 batch-pops 4, the last list cell. W2's
third promotion finds no cell and no pending sweep: `virgin()` re-issues D (same id, same start,
bitmap zeroed) as the shared block, W2 claims its chunk and allocates cell 6 again: **two promoted
objects at one address, inside one minor.** Read against the code: every step is the code's
(`allocatePromotion` → `ladderFrom2W` → `startVirginBlockShared` → `ensureBagPageAvailable` →
`acquireOldGenBlock`), given the bag (`unassigned_blocks_`) empty — the light shrink's pass 3
releases bag pages right after pass 1 — and D's extent the first fit. The id is certain (LIFO);
the start depends on the order of `old_gen_free_blocks_`. With another start but the same id the
stash cell lives in released memory (CR-014 as recorded) and a stale chunk's `c.bits` (= `mark_.slot(id)`)
writes allocation bits into the new block's map.

**What this adds to the register:** CR-014's silent release becomes an immediate S1 inside the same
pause (a double allocation), not only a later reuse of released memory; `ReleasedSafe` cannot flag
it once the id is live again (the release contract is ABA-blind by construction). CR-014's fix
candidate `tail_defers` closes it (`controls/tail_defers_reuse`). Not reproduced within these
bounds: the chunk variant (`sweep_virgin` + `reuse_released`, NA 4/3: pass, 1,805,592 states in
scratch), which needs more promotions after the release than the model allows.

**Code-reading findings of the same audit (no model change):**
- IM5's handoff check (`checkT0BlocksUnchanged`, `OGS:5146`) compares `{id, start, size_class,
  is_large}`: a t0 block released mid-cycle and re-materialised with the same id at the same start
  and class (both LIFO) passes it. The primary guard is `assert(!cycleActive())` in every release
  path (structurally, no release path runs during a cycle), so this is a blind spot of the
  validate-only backstop, not a defect. A per-id generation counter in `BlockTable` would close it.
- `endParallelPromotion` re-queues a worker's last chunk block by id (`OGS:1611-1618`); after
  CR-014's release and a re-issue of that id as a mixed, large or other-class block it sets
  `kAllocQueued` on a non-uniform block, and a later `detachFromAllocation` indexes
  `partial_[size_class]` with `size_class = NUM_SIZE_CLASSES` (an assert, then an out-of-bounds read
  in NDEBUG builds). Another CR-014 consequence; not modelled (one class of blocks).


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: OGS.lazySweep (3019e316a801), file promo_sweep.cpp (d7dbcbdf5c41), greps F.parPromoActive (dd3dd6ba15de), F.promoMu (2da021596e6c).

Change (plans/threaded-gc-register-repros-impl.md, register reproductions; snapshot of the
prior tree `snapshots/register-repros/pre-impl-2026-09-30.tgz`). Code-level guards were added for
the open register entries. The runtime changes are of three kinds only, and none adds, removes or
reorders an atomic step, a lock, a shared location or a memory order on a production path:
- **test accessors** (`AllocatorTestAccess`: `acquireOldGenBlock`, `releaseOldGenBlock`,
  `freeBlocks`, `threadMutexHeldElsewhere`, `adoptThreadHeap`; `OldGenSpaceTestAccess`:
  `sweepCompleteDeferred`, `promoMuHeld`, `cyclePressureFinishDue`). They forward to existing
  functions or read existing fields; unit tests and harnesses call them only. They fire the
  footprint greps `F.promoMu`, `F.threadMutex`, `F.pageWorkCalls`, `F.oldGenFreeBlocks`,
  `F.setThreadHeap`, `F.parPromoActive` and the `Allocator.hpp` census by name only.
- **trace-only probes** (`ECO_TLA_TRACE_ONLY`, compiled out of every other build):
  `m5.item.taken`, `m5.item.copied`, `m5.item.popped` (`TenureWork.hpp`, gated by the new
  `tla_probes`, default false), `m5.l3.claimed` (`NT.TenureParEnv`), `m6.tlh.dtor`
  (`TLH.destructor`), `m6.census.locked` (`P1Census.cpp`). `tlatrace::probe` emits no event;
  it only calls the harness's callback while recording, so no recorded trace changes.
- **a stats-only counter** in `OGS.lazySweep`'s tail completion (`sweep_tail_completions`,
  `sweep_tail_in_promotion`), inside the existing `#if ENABLE_GC_STATS` block in the same
  `promo_mu_` section as the existing `total_post_sweep_shrink_ns` write.
`test/gc-heap-tsan/promo_sweep.cpp` gained non-trace arms (`promoDetMain`, tail mode, exact arrays
every minor); its trace section (`promoTraceMain`, the M4 trace harness) is byte-identical.

Runs (2026-09-30, this tree): `run_traces.py` (every harness rebuilt): **135/135 as expected** in 83 s.

The counter is stats-only and adds no step to M4's sweep or completion actions (the tail path's phase write and `onSweepComplete` call are unchanged). The M4 trace scenario is byte-identical. The new code-level guards reproduce M4's CR-014 (`sweep_tail`, `sweep_tail_release`, `sweep_tail_live`), CR-001, CR-002, CR-016 and CR-028 counterexamples on the real allocator; see the register.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes §3.1: CR-033 fixed (GC_MODEL_001)

Pin fired: region `OGS.allocateFromBagPage`, new hash prefix **8e85cd8f9aa1**.

Change (plans/threaded-gc-register-fixes.md §3.1; snapshot `snapshots/register-fixes/pre-phase1.tgz`):
the fresh-page carve's remainder test `remainder >= MIN_FREE_CELL_SIZE` became `remainder != 0`
(plus an 8-alignment assert), so an 8-byte tail goes through `pushSpanOnFreeLists` and gets an
unlinked `Tag_Free` header (HEAP_024 amended). Serial code under the same locks as before; no atomic
step, lock, shared location or memory order changes.

M4 models the bag rung as one step of the locked ladder (`W_Virgin`'s else-branch); the carve's header layout is not state in M4. The rung still runs under `promo_mu_` exactly as before. **Verdict: no model change needed.**

## 2026-09-30 — register-fixes §3.2: CR-018 fixed, CR-001's S1 half closed (GC_MODEL_001)

Pins fired: region `OGS.initObjectHeaderWithSize` (**2d1af3f18a67**), region `OGS.finalizePoppedCellW`
(**26356efabd55**), grep `P6.M16` (**dff5ec5a9d43**: the new plain owner add
`blocks_.meta(block_id).live_bytes += cell_bytes;` at Idle outside a parallel promotion), grep
`F.parPromoActive` (**453a067480d5**: the new read `if (black || par_promo_active_)` choosing the
atomic add).

Change (plans/threaded-gc-register-fixes.md §3.2; HEAP_073 new, HEAP_051 amended): every allocator
path adds `live_bytes` in every phase. In `finalizePoppedCellW` the add left the black branch: it is
now an unconditional relaxed `fetch_add` (one add per path); the colour and bit stay phase-gated,
and the phase is still read plain (CR-001's race half, Phase 2). In `initObjectHeaderWithSize` the
Idle add is atomic while `par_promo_active_` (workers add lock-free) and a plain owner write
otherwise (no promotion worker, no marker at Idle: P6.M16 stays "atomic adds outside `promo_mu_`,
plain reads under it"; the plain write happens only while no worker exists).

**Model updated first (the M4 `Counts` split, made ONCE here as the plan requires):** `Counts(p)`
became `CountsBit(p) == p # "Idle"` (colour and bit) plus `IdleCounts == "idle_uncounted" \notin
MUTANT` (the live count). `FinPhase`'s Idle branch and `W_PopAfterSweep`'s Idle branch add
`liveBytes[BlkOf(c)] + 1` with `Acc1("live", FALSE, TRUE)`; re-translated. `MC_quick_sweep_release`
now passes (CR-001 S1; 15,172 states); A6 mutant `mutants/idle_uncounted_release.cfg` violates
`ReleasedSafe` (14,931 states); `controls/count_until_shrink.cfg` and its row deleted and the name
dropped from every config (the default is a superset). `controls/phase_atomic_release.cfg` now
PASSES (was `violates:ReleasedSafe`): its failure was the phase-dependent count, exactly as §4.2
predicted; the row is flipped with a note (Phase 2 deletes it). `TracePromoBitmap`: `m4.pop`'s
colour is `CountsBit`; `m4.fin` carries `cnt` (the code emits it) and a not-black finalize raises its
block's `liveBytes` by `cnt` = `IdleCounts`. Runs: M4 quick 47/47 as expected; `run_traces.py
--model M4` 12/12 as expected.

**Verdict: model updated.**

## 2026-09-30 — register-fixes §3.3 + §3.4: CR-035 and CR-016 fixed (GC_MODEL_001, one audit)

Pins fired: region `OGS.allocateFromEmptyRegularBlocks` (**241b815c0313**), grep `P6.M9`
(**cc48c7eb8f67**: the flip's `retireIndexRange` loop over `large_body_index_` and its validate
post-check), grep `F.parPromoActive` (**8c0450e863af**: the new first statement
`if (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1)`).

Change: (1) CR-016 (§3.4): `allocateFromEmptyRegularBlocks` flips nothing inside a parallel
promotion with more than one worker; `allocateLargeBlock` then takes a free large block or a fresh
one. (2) CR-035 (§3.3): the flip retires the index entries inside the block (M8's concern; M4 does
not model the index). Both run under `promo_mu_` exactly as before (the flip's reads and its plain
`live_bytes` write).

**Model updated first (NEW RULE):** a MUTANT-gated guard in `W_Large` (`FlipCands` is empty when
`Cardinality(Workers) > 1`) was checked BEFORE the code change: `controls/flip_skips_parallel`
(sweep_large + the name, pass, 38,160 states), `controls/flip_skips_parallel_chunk` (minor_large + the
name, pass, 2,010 states) and `controls/flip_one_worker` (minor_virgin, `NWorkers = 1`,
`large_promo`, CR-018's count on; pass, 59 states; a flip is reachable there: a scratch
`released = {}` witness fails in 40 states). `MC.tla`'s `MC_Workers` gained `NWorkers = 1 -> {1}`.
Then the rule became the default and the old behaviour the A6 mutant `flip_in_parallel`:
`MC_quick_sweep_large` (38,160 states) and `MC_quick_minor_large` (2,010) now pass;
`mutants/flip_in_parallel_stash.cfg` (7,987) and `mutants/flip_in_parallel_chunk.cfg` (2,794)
violate `ReleasedSafe`; the two `flip_skips_parallel*` controls were deleted (identical to the
defaults); `flip_one_worker` stays. Re-translated. M4 quick 50/50 as expected. MAPPING's `W_Large`
row updated.

**Verdict: model updated.**

## 2026-09-30 — register-fixes Phase 2 (§4.1-§4.4): CR-014, CR-001 (race), CR-002, CR-028 fixed (GC_MODEL_001, one audit for the batch)

Pins fired for M4: file `test/gc-heap-tsan/promo_sweep.cpp` (**4f6ac56ce006**: the det arms' path
witness is now `sweep_tail_in_promotion`, det-cr002's message), regions `OGS.finalizePoppedCellW`
(**4d8b93453093**), `OGS.finalizeBitmapCellW` (**296d0825c9c5**), `OGS.beginParallelPromotion`
(**61cd0f2c82b6**: `v11_deferred_.clear()`), `OGS.endParallelPromotion` (**edc1da416447**: the
deferred V11 walk before the deferred shrink), `OGS.allocatePromotion` (**9551468c0f86**),
`OGS.lazySweep` (**b033f3f0c837**), `OGS.onSweepComplete` (**9a0fe8aa36e1**), census
`OldGenSpace.cpp` (**2afe7bc4cf4d**), census `OldGenSpace.hpp` (**493c238780a8**), grep `F.gc_phase`
(**e0a73570b77c**, re-derived as `gc_phase_ =|atomic_ref<GCPhase>`: the two plain completion writes
became one atomic store), grep `F.parPromoActive` (**abb69658de8b**: the tripwire, `completeSweep`'s
trace field, CR-028's `par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1`).

**Model updated first, fix by fix (A6: the old behaviour is a mutant each time):**
1. **CR-014 (§4.1).** The tail branch of `W_SweepEnd` is `await "tail_immediate" \in MUTANT`;
   every completion sets `deferred`. `MC_quick_sweep_tail` (16,574 states), `_release`, `_live`
   (14,912 each) and `_reuse` (635,554) pass; mutants `tail_immediate` (DetachNotCurrent, 13,444),
   `tail_immediate_release` (ReleasedSafe, 13,338), `tail_immediate_live` (NoRaceLive, 4,249),
   `tail_immediate_reuse` (+`reuse_released`, `CONSTRAINT MC_NoFatal`; NoDoubleAlloc, 1,158,754).
   `controls/tail_defers*` deleted and the name dropped from every config. `W_Shrink` is reached
   only under the mutant.
2. **CR-001 race (§4.2).** `PhasePlain == "phase_plain" \in MUTANT`; reads under `promo_mu_`
   (`Ladder`, `W_PopAfterSweep`, the batch) use `PhLocked` (plain, as the code). `MC_quick_sweep_race_phase`
   passes; mutant `phase_plain` violates `NoRacePhase` (2,439). `controls/phase_atomic{,_release}`
   and `finalize_in_lock_phase` deleted.
3. **CR-002 (§4.3, NEW RULE).** `W_Locked`'s batch: `Unswept(h) == phase = "Sweeping" /\ ~swept[BlkOf(h)]`
   → the head is finalized under the lock (`W_Fin` → `W_StUnlock`), nothing stashed; otherwise only
   `SweptPrefix(freeList)` is stashed. `W_StLk` and the `finalize_in_lock` control are gone. TLC
   passed the rule on every sweep row, `MC_quick_sweep_fixed` (now `MUTANT = {}`, 14,912) and the 8
   deep rows **before** the runtime changed; a scratch witness (`pc # "W_StUnlock"`) shows the
   in-lock branch is reachable (1,610 states). Mutant `finalize_outside_lock` violates
   `NoRaceBitmap` (5,811): W1 finalizes an M cell outside the lock (W_StBit on M1), then W2's
   `W_Sweep` word read — the intended story. `MC_quick_sweep_race_bitmap` passes.
Every config lost the retired names (`tail_defers`, `phase_atomic`, `finalize_in_lock`); the fixed
configs' comments say "the defaults". Re-translated after each step.

**Runs.** Quick: 48/48 as expected. Deep: 8/8 pass (2 TLC workers): `sweep_n3` and
`functional_n3` 208,230 states each, `sweep_w3` 13,247, `cycle_w3` 501,030, `minor_w3` 102,776,
`sweep_1class_w3` 709,187, `sweep_breadth` 62,240, `virgin_breadth` 62,404. (The deep table at the
top of this file predates later model changes: the pre-Phase-2 model gives `sweep_n3` 194,516,
`sweep_w3` 13,487, `sweep_breadth` 62,276 distinct states, so the Phase 2 defaults did not shrink
the deep rows.)

**Trace spec.** `m4.swend` paths 2 and 3 both map to a deferred completion; `m4.batch` carries
`inlock` (the code logs it before the in-lock finalize) and requires the lock still held iff
`inlock`; `m4.unlock` also matches `W_StUnlock`; `W_StLk` removed from `m4.fin`.
`TraceRace.cfg` is promoted to five `traces.txt` accept rows (the registered runs); `run_traces.py`
names rows with a non-default config `…:<config stem>` so they do not collide. `run_traces.py
--model M4`: 17/17 as expected (5 accept, 5 TraceRace accept, 7 mutate rejects); the registered
logs take the in-lock branch in about half of their batches (e.g. 25 of 51 batch events in
`promo,1,3,4`); no registered log completes the sweep.

MAPPING.md updated (`phase`, `W_R1Ph`, `W_Stash`/`W_Fin`, `W_Locked`, `W_SweepEnd`, `W_Shrink`,
P6.M6, §6 contracts, A4, A5, A6, §8 events).

**Verdict: model updated.**

## 2026-10-01 — register-fixes §6.1: CR-019 fixed, relaxed atomic whole-word YLOS header access (GC_MODEL_001)

Pins fired: region `OGS.lazySweep`, new hash prefix **6066819cec59**; new census pin `AllocatorCommon.hpp`.

Change (plans/threaded-gc-register-fixes.md §6.1, CR-019; HEAP_062/HEAP_067 amended): every
access to a header word that another thread may touch during a legacy parallel minor is a relaxed
atomic whole-word access through the new helpers `loadHeaderRelaxed` / `storeHeaderRelaxed`
(`AllocatorCommon.hpp`, newly census-pinned for M3, M4). Writers: `reachYoungLargeP` (age++ under
`ylos_mu_`), `promoteYoungLarge` (age = 0), region `reachYoungLargeR` (age = 1). Readers:
`lazySweep`'s gap sweep (one load per live object, reused for the trace event), the header walk
(one load reused for tag, sentinel and pin), the large-block branch's pin read, and the
validate-only `validateV11` walk. The values written are unchanged (tag/size/pin kept); no lock,
step order or memory order beyond "relaxed" is added, so no happens-before edge changes. TSan:
`det-cr019` both orders and `ylos-sweep` are clean (were: a report every run).

M4 models the gap sweep's step over a live object as reading that object's size (`W_SweepStep`); it never modelled the header word's other bits or a concurrent YLOS writer. The step now comes from one relaxed atomic load instead of a plain read; the size, the bit clear and the order of the trace events (`m4.sw` carries the same `end` value, computed from the same step) are unchanged. **Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.3: CR-007 fixed, no-wait acquire for a promotion holder with n > 1 (GC_MODEL_001)

Pins fired: region `OGS.allocateFromBagPage` (**8707d299ec96**), grep `F.parPromoActive` (**4bd31a55ef87**: the new `acquireWaitPolicy()` reads `par_promo_active_` and `promo_ctx_->n`).

Change (plans/threaded-gc-register-fixes.md §6.3, CR-007; HEAP_058/HEAP_059 amended): a promotion
holder of a parallel promotion with n > 1 workers (`OldGenSpace::acquireWaitPolicy()` =
`AcquireWait::AvoidUnderPromo`, passed at `ensureBagPageAvailable`, `allocateFromBagPage` and
`allocateLargeBlock`) gets the no-wait policy in `Allocator::acquireOldGenBlock` (modes 1/2 with
decommit on): (1) the first fitting **Pending** extent (`PageWork::isPending`, job-blind; `onReuse`
cancels it, never waits), (2) else a fresh bump, (3) else -- the old-gen cap leaves no bump room --
today's first fit (may wait; counted). The first-fit body was factored into a `takeFreeAt` lambda
(no behaviour change for `Allowed`). New PageWork API: `isPending`, `decommitOn`, `noteNoWait` (the
counters `nowait_pending_reuse_bytes`, `nowait_fresh_bytes`, `nowait_fallback_waits` and the M7 trace
event `nw`), `noteNoWaitSkip` (`nowait_skipped_extents`). Validate builds: a no-wait Pending reuse
must not raise `reuse_waits`, and `releaseBlockToAllocator` / `releaseUnassignedBlockToAllocator` abort
while `acquireWaitPolicy() != Allowed`. No lock, atomic or memory order is added; every new
PageWork call runs under `thread_mutex_` like the old ones.

`acquireWaitPolicy()` reads `par_promo_active_` / `promo_ctx_->n` where the CR-016 test already does (under `promo_mu_` or before the workers start); M4 models the page source abstractly (`W_Virgin` / `W_Large` take "a fresh block"), so which extent the allocator returns is invisible to it. **Verdict: no model change needed.**


## 2026-10-01 — register-fixes Phase 5: owner check at minorGC entry (GC_MODEL_001)

Pins fired: region `TLH.minorGC` (**896f924a1e35**).

Change (plans/threaded-gc-register-fixes.md §7, Phase 5; HEAP_007 fork contract, HEAP_058, HEAP_065,
HEAP_070 amended, HEAP_075 new): (1) `GCFork.{hpp,cpp}`: ONE `pthread_atfork` registration with fixed
layers (gangs: registry -> each background gang's `m_` to set `fork_hold_` -> `stopAllForFork` -> each
gang's `m_` held -> `GCMarkGang` `run_m_` -> its `m_`; allocator: `thread_mutex_`; census: the P1 census
mutex and detector N's; pool: `GCHelperPool::m_`, drained and held); the three old registrations are
gone. (2) No teardown holds `thread_mutex_` while it takes a gang lock (`cleanupThread`,
`finishTenureForExit`, `reset`, `~Allocator`). (3) CR-003/015: `post`'s Idle->Posted CAS and the enqueue
in one `m_` section; the pool prepare drains and keeps `m_` in one section; the allocator layer locks
`thread_mutex_`, the child re-creates it and records `fork_child_` / `fork_owner_`. (4) CR-013/004:
`GCBackgroundGang::launch` returns false (refuses) while `fork_hold_`; `launchBackground` then leaves
`bg_ep_ = None` (`cm.episodes_refused`), `tenureLaunch` / `tenureConcLaunch` count `rs.fork_refusals`
and the join's orphan path finishes the job. (5) CR-023: `stopAndJoin` waits for
`generation_ != my_gen || finished_ >= members` and clears `running_` only for its own generation;
`launch` notifies `cv_done_`. (6) CR-005: `closingFinish` accepts `bg_ep_ == None`. (7) CR-031:
`~Allocator` (and `initThread`, `getCombinedStats`, `validatePageWork`) never touch a heap the forker
does not own in a forked child; validate builds check `ThreadLocalHeap::owner_` in `minorGC` /
`majorGC`. (8) CR-032: the census layer; `atexitReport` returns in a forked child. Trace-only: the
probe `m6.tm.held` in `onGCPauseEnd` (under `thread_mutex_`), `fork.bghold`, `gang.refuse`, the step
event's `refused` field and an M1 `stop` after a refused launch.

`TLH.minorGC` gained only a validate-only `assertOwner("minorGC")` before the pause starts (HEAP_007 /
CR-031). No promotion, sweep or bitmap step changes. **Verdict: no model change needed.**

## 2026-10-01 — frontend-heap-release P1: explicit release, ShrinkPass::Forced (GC_MODEL_001)

Pins fired: regions `OGS.onSweepComplete` (**fecf4917088c**), `OGS.maybeShrinkCapacity` (**16f2d7bb56c4**).
New pin: region `TLH.majorGCAndShrink` (M1, M4, M8).

plans/frontend-heap-release.md P1 (§3, HEAP_076): the explicit release. New `ThreadLocalHeap::majorGCAndShrink` (TLA-REGION `TLH.majorGCAndShrink`): ONE pause and ONE sync point (an outermost `PauseEndHook` around a nested `majorGC(MajorReason::Explicit)`, then `OldGenSpace::finishSweepForRelease` (lazy sweep driven to Idle, `while (gc_phase_ != GCPhase::Idle)`, aborts if a cycle is active) and `shrinkToFloorForRelease` = `maybeShrinkCapacity(0, ShrinkPass::Forced)`). New `Allocator::collectMajorAndRelease` (after that pause, under `thread_mutex_` only: TLA-REGION `AL.releaseDiscard` = `page_work_->drainAll(decommitOn())` + counter reads; `malloc_trim` after the lock) and `Allocator::collectMinor` (two `thread_mutex_` snapshot sections around a plain `minorGC`). Both are fatal inside a pause (`pause_depth_ != 0`).

What changed in the pinned regions: `maybeShrinkCapacity`'s `bool light_pass` became
`enum class ShrinkPass { Heavy, Light, Forced }` (`onSweepComplete` passes `Light`, the heavy caller
`Heavy`: identical behaviour and billing), plus the `Forced` arm: it returns at once if
`gc_phase_ != GCPhase::Idle` or a cycle is active, skips the hysteresis gate, keeps the floor
and bills `total_maybe_shrink_forced_ns`. Passes 1-3 are untouched, including the `kAllocTenure` skip (T6)
and the `live_bytes == 0` / `fully_swept` candidate test (HEAP_073).

Re-audit. M4's shrink steps (`W_Shrink`, `G_Shrink`, `U_Sweep*`) abstract the sizing and every gate as
"any subset of the candidates" (MAPPING §3), so a pass without hysteresis is one of the modelled choices.
The forced pass runs on the mutator inside its own STW pause, after a STW major that joined the tenure job
and finished any cycle, with the sweep at Idle and no parallel promotion (`pause_depth_ == 0` at entry, so
no minor and no gang is running: the CR-014 tripwire cannot fire); that is the mutator-side release
`U_Sweep`/`G_Shrink` already covers (`ReleasedSafe`: only blocks with no live or in-flight cell, the
granted `kAllocTenure` blocks skipped). No atomic, lock, shared location or memory order was added; the
F.gc_phase and F.allocTenure greps are unchanged. **Verdict: no model change needed.**

## 2026-10-05 — macOS build: BufferMetadata::live_bytes declared uint64_t (GC_MODEL_001)

Pin fired: grep `P6.M16` (**2be50684b09d**): `size_t live_bytes;` became `uint64_t live_bytes;` in
`BlockTable.hpp`.

Change: as in M8's entry of the same date. `liveBytes[b]` (P6.M16) is the same location with the same
accesses: relaxed `atomic_ref<uint64_t>` adds outside `promo_mu_` (`initObjectHeaderWithSize`,
`flushCursorW`, `finalizePoppedCellW`, none of them edited) and plain reads under it. The declared type
now matches the `atomic_ref`'s on every platform; on Linux it already did. No atomic step, lock, shared
location or memory order changed. **Verdict: no model change needed.**

## 2026-10-09 — plans/large-object-space.md: the large-object space, header-less bodies, O7 (GC_MODEL_001)

Change (plans/large-object-space.md, HEAP_080/HEAP_081): every old-gen-direct large object (split String/Bytes bodies, YLOS, pinned pointer-free objects, the permanent fallback) now lives in LOS blocks: ordinary `alloc_buffer_size` blocks acquired like bag pages and materialized with `BlockInfo::los` (page index, mark arena, region bounds unchanged), whose free space a mutator-only `LargeObjectSpace` manages (1 KiB granules, a bitmap per block); larger objects keep is_large blocks. Every LOS object is tracked in `large_bodies_` (kind 0 body, 1 YLOS, 2 old: `promoteYoungLarge` and `promoteLargeHeader` re-kind to 2 instead of erasing); `losSweepAtMarkEnd` (inside `finalizeMetaAfterMark`) frees unmarked tracked LOS entries and sets LOS `live_bytes` to used granules; empty LOS blocks beyond `los_empty_keep` are released after the reclaim. LOS blocks are excluded from the flip, reclaim, shrink, evacuation and lazy sweep (`fully_swept` stays true). Bodies are header-less in raw blocks (`kLosRaw`): `greyObject` marks them without a push. O7: `takeFreeAt` releases a reused extent's tail.

Pins fired: regions `OGS.allocateFromEmptyRegularBlocks` (**01961268bb26**), `OGS.lazySweep` (**f2052ad635f1**), `OGS.maybeShrinkCapacity` (**90bb953ccd90**); census `OldGenSpace.cpp` (**714b07d48107**); greps `H2` (**548900ba8616**), `H9` (**88d1d8251ae0**), `P6.M7` (**72090451cef4**), `P6.M9` (**0ec81764e070**), `P6.M16` (**775e4a9c5e8c**), `F.parPromoActive` (**73c591603c9e**).

LOS blocks never enter M4's paths: they are never `Current`/`Queued`/tenure-granted, never on `partial_` or a free list, born and kept `fully_swept` (the sweep and its slices under `promo_mu_` skip them), and the flip and shrink now skip them explicitly (`los != 0`). A promotion never allocates an LOS cell (nursery placement is capped at the largest uniform class). `lazySweep`'s legacy is_large arm no longer reads a raw block's header (a branch the bitmap-mode model does not take). The census/P6.M16/F.parPromoActive lines are `attributeNewCell`'s, a mutator-only copy of `initObjectHeaderWithSize`'s live-bytes add (atomic when `par_promo_active_`, as there). **Verdict: no model change needed.**

## 2026-10-09 — plans/region-nursery-everywhere.md: promo_sweep keeps the legacy nursery, explicitly (GC_MODEL_001)

Pin fired: file `test/gc-heap-tsan/promo_sweep.cpp` (**1b739c760ed8**).

Change: comments only. `promoConfig` still sets `cfg.nursery_regions = 0`; the one-line comment beside
it became four lines explaining why it stays legacy now that every other harness defaults to the region
nursery. The route M4 models, parallel promotion workers allocating cells in blocks that a pending lazy
sweep still owns, exists only on the legacy minor. The region tenure job promotes only into
`kAllocTenure` grant blocks, which no sweep path may select (HEAP_070). The driver's heap, scenario,
probes and trace output are unchanged, and no runtime code is touched. **Verdict: no model change needed.**
