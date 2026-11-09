---
status: done
updated: 2026-11-08
---

# Plan: bound the large bodies a mark cycle defers

A running incremental mark cycle frees no dead young large body until its handoff, and nothing ends
the cycle early on account of them. A program that holds one big buffer while streaming large
`Bytes` therefore retains a whole cycle's worth of large-body garbage: 2.67 GB on a 240 MB working
set. This plan ends the cycle early once the bytes it has deferred outgrow the live heap, through the
existing pressure-finish path.

**Read before coding:**
- `design_docs/invariants.csv`: HEAP_007, HEAP_026, HEAP_056, HEAP_062, HEAP_063, HEAP_066,
  HEAP_079, HEAP_080, HEAP_083, GC_DET_001.
- `test/tla/README.md`, "The canary". This plan edits one pinned region (`TLH.stepMarkCycle`) and one
  canary grep (`F.deferredFrees`), both pinned to M1 only (§6).
- `test/tla/M1-snapshot-mark/MAPPING.md`, rows `P_Marking`, `P_Pressure` and the trace rules for the
  `pressure` event.
- `plans/large-body-gc-trigger.md` (HEAP_079, the minor-side half of this problem) and
  `plans/threaded-gc-05a-incremental-marking.md` (the cycle schedule).
- `CLAUDE.md`: run each test command once, tee its output to `/tmp`, then grep.

## 1. Problem (verified 2026-11-07)

Found through the MAX spike (`spikes/max/`): the MNIST training run peaked at 2.83 GB RSS. The
eco-only repro `spikes/max/memgrowth` (`make -C spikes/max run-churn MODE=...`) replays its traffic
without MAX: each step builds a 485 KB `Bytes` with `Encode`, sends it on a bytes port, and receives
a 407 KB `Bytes` the host emits into the heap.

| Repro (3,000 steps unless noted) | Peak RSS | Mark cycles |
|---|---|---|
| `both`: the per-step traffic only | 239 MB, flat | none |
| `hold`: the same, plus one live 47 MB `Bytes` | 2.67 GB | 1, spanning 33 minors |
| `hold`, 9,000 steps | 2.67 GB, flat from step 3,000 | 1 |
| `hold`, `{"incremental_mark_slices": 4}` | 583 MB, flat | 1, spanning 5 minors |
| `hold`, `{"incremental_mark": false}` | 287 MB, flat | stop-the-world |
| MNIST spike, default | 2.83 GB | |
| MNIST spike, `{"incremental_mark": false}` | 456 MB (same results, faster) | |

It is not a leak: the memory is reused after the handoff, and the 9,000-step run never grows past
the first cycle's peak. The `gc-profile` line of the one cycle (`ECO_GC_PHASE_PROFILE=1`):
`span_minors=33 ... live=49724088 garbage=369259232`. The cycle had almost no mark work
(`units=0`: the live body is pointer-free) and still ran its full schedule.

## 2. Mechanism (code as of 2026-11-08)

1. The live 47 MB body makes a major trigger fire, and `ThreadLocalHeap::startMarkCycle`
   (`ThreadLocalHeap.cpp`, region `TLH.startMarkCycle`) begins a cycle of
   `T = incremental_mark_slices` = 32 steps (`AllocatorCommon.hpp:338`).
2. During the cycle, every minor ends in `OldGenSpace::sweepNurseryLargeBodies`
   (`OldGenSpace.cpp:7291`, region `OGS.sweepNurseryLargeBodies`). A dead nursery-owned large body is
   not freed while `cycle_state_ != Idle`: it is unlinked and pushed onto `deferred_frees_`
   (`OldGenSpace.cpp:7348-7357`), because the running cycle may have marked or greyed the cell
   (M1's `NoReleaseInCycle`, the `!cycleActive()` assert in `freeLargeBodyCell`).
3. `deferred_frees_` is emptied only at the handoff (`processDeferredFrees`, `OldGenSpace.cpp:4858`,
   called from the post-mark tail) and cleared at the next t0 (`:4170`).
4. The cycle ends in `ThreadLocalHeap::stepMarkCycle` (`ThreadLocalHeap.cpp:1180`) in one of two
   ways only:
   - on schedule: `HandoffDue`, set when the step at `k == T` drains the mark (`OldGenSpace.cpp:4222`
     non-concurrent, `:4802` concurrent), so the handoff is at minor `T + 1` (HEAP_063). This holds
     even when the background markers finished long before;
   - by pressure: `cyclePressureFinishDue` (`OldGenSpace.cpp:4251`), when old-gen committed bytes
     reach `incremental_mark_finish_fraction` (0.95) of the old-gen cap, which is gigabytes.
5. In this workload almost all allocation is large bodies, so minors come from HEAP_079's
   direct-allocation budget (`ThreadLocalHeap::directAllocBudget`, `ThreadLocalHeap.cpp:395`). The
   33 minors of the cycle therefore span about 33 budgets of large-body allocation, and all of its
   garbage is deferred.

Nothing relates what a cycle defers to anything the heap can afford. HEAP_079 bounds the
allocation *between minors*; this plan bounds what accumulates *across a cycle*.

## 3. Goals and non-goals

**Goals:**
- G1. While a cycle runs, the bytes in `deferred_frees_` stay within
  `max(F × live_ref, floor)` plus one minor's direct allocation (HEAP_079's budget plus one
  allocation). `live_ref` is the cycle's live estimate at t0; `F` and `floor` are configurable.
- G2. The `hold` repro peaks under 450 MB, and the MNIST spike under 600 MB, with default settings.
- G3. No change for programs that defer little: the self-compile and the E2E suite see no new
  finishes, or few enough that wall time and pause times are within noise.
- G4. Every decision stays deterministic (GC_DET_001) and inside what M1 already checks.

**Non-goals:**
- Freeing dead young large bodies during a cycle (§5, A1). That is the better-memory fix, but it
  needs new modelling.
- Returning freed memory to the OS sooner (HEAP_059, `los_empty_keep`).
- Retuning `incremental_mark_slices` or the major triggers.

## 4. Design

### D1. Deferred bytes, without touching the sweep region

`OldGenSpace` gains:

```cpp
// Returns the bytes on deferred_frees_: the cells this cycle's minors found dead but may not free
// before the handoff. Amortised O(1): it adds only the entries pushed since the last call.
uint64_t cycleDeferredBytes() const;
```

It is backed by two mutable fields, `deferred_summed_n_` and `deferred_summed_bytes_`, reset where
`deferred_frees_` is cleared or emptied (t0, `processDeferredFrees`, and the reset at `:403`). Each
call sums `cell_size` over `deferred_frees_[deferred_summed_n_ ..]`. `deferred_frees_` only grows
during a cycle, and the summing runs on the mutator at a minor end, after the parallel minor's join
(the same thread and point as the sweep; M3 MAPPING), so the read is mutator-only.

Summing in an accessor, rather than adding a counter beside the `push_back`, leaves region
`OGS.sweepNurseryLargeBodies` (pinned to M1, M5 and M8) unchanged. The new lines name
`deferred_frees_`, so the `F.deferredFrees` canary grep (M1) changes. If the accessor proves awkward,
the counter in the region is the fallback, at the price of audits in all three models.

### D2. The deferred-bytes finish

In `ThreadLocalHeap::stepMarkCycle`, beside the pressure check, before the step:

```cpp
if (old_gen_.cyclePressureFinishDue()) {
    finishMarkCycleNow(OldGenSpace::CycleFinish::Pressure);
    return;
}
if (old_gen_.cycleDeferredFinishDue(deferredFinishFloor())) {
    // The cycle has deferred more large-body garbage than the heap can carry: finish it now,
    // exactly as a pressure finish does.
    noteDeferredFinish();   // stats only
    finishMarkCycleNow(OldGenSpace::CycleFinish::Pressure);
    return;
}
```

```cpp
// Returns whether the bytes this cycle has deferred reach
// max(incremental_mark_deferred_finish × live_ref, floor); false when the factor is 0.
bool OldGenSpace::cycleDeferredFinishDue(uint64_t floor) const;
```

- **Threshold.** `live_ref` is `pacing_t0_.live_ref` (`OldGenSpace.cpp:4119-4125`): the last
  major's live bytes, capped by `live_growth_bound`, fixed at t0. With `F` = 1.0, the cycle is
  finished once its deferred garbage equals the live heap, so peak occupancy stays near twice the live
  heap plus one budget. `floor` is `incremental_mark_deferred_floor` × the HEAP_079 budget
  (`directAllocBudget()`), or × `NurserySpace::minorThresholdBytes()` when the budget is 0. The
  default is 1 (planned as 4; see §10, 2026-11-08: at 4 the `hold` repro peaked at 583 MB).
  After a cycle, `major_live_` is the bytes the markers traced (HEAP_057), so raw bodies, which are
  never scanned, add nothing to `live_ref`: a heap of pointer-free bodies is bound by the floor.
  That matches the cost the finish moves into a pause, which is the mark work.
- **Determinism (GC_DET_001).** The inputs are deferred bytes (from the minor's own sweep, which is
  deterministic), `live_ref` (fixed at t0), and the configuration and nursery size. The rule
  deliberately ignores whether the mark is done: "finish when the background markers are idle" reads
  helper progress (`bg_ep_`, `finishedApprox`) and is exactly what GC_DET_001 forbids (§5, A2). In
  validate builds `cycleDeferredFinishDue` opens IM16's `DecisionScope`, as `cyclePressureFinishDue`
  does.
- **Placement.** The check sits before `cycleStep`, like the pressure check. M1's trace rule allows
  a `pressure` event at `P_Marking` only before any reap in that minor, so a check after the step
  (which reaps) would not map onto the model.
- **Path.** It reuses `CycleFinish::Pressure`: `finishMarkCycleNow` drains what is left of the mark
  (`drainCycleMark`: a closing join with background markers, or the remaining slices), then
  `completeMarkCycle` hands off and `processDeferredFrees` frees everything deferred. Regions
  `TLH.finishMarkCycleNow` and `TLH.completeMarkCycle` and the trace event (`pressure`) are
  unchanged; only the stats tell the two reasons apart.
- **Cost.** An early finish moves the rest of the mark into this minor's pause. With `F` = 1.0 that
  happens only once the cycle holds more garbage than live data. When the background markers have
  finished (MNIST: `units=0`), the drain is a join and costs almost nothing.

### D3. Configuration

| Key | Type | Default | Meaning |
|---|---|---|---|
| `incremental_mark_deferred_finish` | double, 0 or [0.25, 64] | 1.0 | `F`: finish a cycle when its deferred bytes reach `F × live_ref`; 0 turns the trigger off |
| `incremental_mark_deferred_floor` | double, [1, 1024] | 1.0 | the minimum threshold, in HEAP_079 budgets (in minor thresholds when the budget is 0) |

Added as constants beside `INCREMENTAL_MARK_FINISH_FRACTION` (`AllocatorCommon.hpp:335-347`), as
`HeapConfig` fields beside it (`:788-792`), validated with the others (`:1064-1080`), and as
`HeapConfigJson.cpp` keys (list `:248`, parse `:419-429`). Each gets a row in `docs/options.md`'s
heap-configuration table, beside `incremental_mark_finish_fraction` (`:683`).

### D4. Statistics

- `IncrMarkStats` gains `finish_deferred` (a subset of `finish_pressure`) and
  `deferred_bytes_at_finish_max`.
- The banner line that prints `finish_schedule` / `finish_pressure` (`GCStats.cpp:2841`) adds
  `(deferred N)`.
- The `gc-profile` cycle-handoff line adds `deferred=<bytes>`, so the repro shows the bound directly.

### D5. Invariants and documentation

- New row **HEAP_084 DeferredFreeBound**. While a mark cycle runs, at every minor end
  `stepMarkCycle` finishes it by the pressure path once `cycleDeferredBytes()` reaches
  `max(incremental_mark_deferred_finish × live_ref, floor)`, so the deferred bytes exceed that bound
  by at most one minor's direct allocation (HEAP_079). The decision reads only mutator state
  (GC_DET_001). Code: `ThreadLocalHeap.cpp`, `OldGenSpace.{hpp,cpp}`, `AllocatorCommon.hpp`,
  `HeapConfigJson.cpp`, `LargeBodyChurnTest.cpp`.
- **Amend HEAP_063.** A cycle spans T + 1 minors unless a pressure or deferred-bytes finish ends it
  sooner.
- **Amend HEAP_066.** H_c = T + 1 stays the pacing horizon; an early finish only shortens a cycle,
  so the headroom trigger remains conservative.
- Point `spikes/max/README.md` and the "Large-body deferral pacing" note at this plan. Once G2 holds,
  drop the `ECO_HEAP_CONFIG` workaround from the README.

## 5. Alternatives considered

- **A1. Free dead post-t0 bodies immediately.** `NoReleaseInCycle` protects only `t0Old ∪ t0Ylos`,
  so a body allocated after t0 and dead at a minor is not obviously off limits. But freeing it during
  a cycle crosses several boundaries:
  - `freeLargeBodyCell` asserts `!cycleActive()`;
  - the LOS free path writes the mark bit and `live_bytes` that background markers test-and-set
    (M4, GenMC W3);
  - the freed cell can be handed out again mid-cycle (M1's ABA audit).

  This needs new M1, M8 and GenMC work. It is the follow-up if D2's bound proves too loose; it is
  not this plan.
- **A2. Hand off as soon as the mark is done.** That is the cheapest early finish, but "done" is
  helper progress (`reapBackground`'s `finishedApprox`), which GC_DET_001 rules out as a policy
  input.
- **A3. Choose fewer slices at t0.** This is deterministic, but it only scales the problem down
  (the 4-slice run still peaks at 583 MB) and does not bound it by bytes. HEAP_066 also assumes a
  fixed H_c.
- **A4. Change the defaults** (fewer slices, or incremental marking off). That moves pause times
  for every program to fix a pattern some programs have. `ECO_HEAP_CONFIG` stays the workaround
  until this lands.
- **A5. Count deferred bytes in `cyclePressureFinishDue`.** They are already in the committed
  bytes; that line is 95% of the old-gen cap, the wrong scale for a 50 MB live heap.

## 6. TLA+ and canary obligations

| Pin | Models | Change | Expected verdict |
|---|---|---|---|
| region `TLH.stepMarkCycle` | M1 | a second finish condition before the step, taking the `P_Pressure` path | no model change: M1's `P_Marking` already chooses `P_Pressure` nondeterministically at any `k` ("every real schedule is a model schedule"); update the `P_Marking` row of MAPPING.md to name `cycleDeferredFinishDue` |
| grep `F.deferredFrees` | M1 | the accessor's reads of `deferred_frees_`, the resets | no model change: mutator-only reads after the minor's join; `deferred` in M1 is unchanged |

Also check, and record in the same AUDIT entries:
- M5 and M6: a pressure-finish handoff runs where the scheduled one does (`stepMarkCycle` →
  `completeMarkCycle` → `handoffMarkCycle`), which M6's `U_Handoff` row already describes. Confirm
  there is nothing new to map; no M5 or M6 pin changes.
- The M1 trace specs (`TraceCycle.tla`, `TraceHeap.tla`) accept the event, because the new finish
  traces `pressure` before any reap.

Procedure (README, "When it fires"): read the change against MAPPING.md; add an AUDIT.md entry to
M1 with the date, verdict and new hash prefixes; run `tla-check` (M1's quick rows) and `tla-trace`
once each; then `test/scripts/check-tla-manifest.sh . --update`.

## 7. Tests

Unit tests in `test/allocator/LargeBodyChurnTest.cpp`, which already drives the split path on a
small heap. Add:
- **(f) Held body, churn during a cycle.** Keep one large pointer-free body alive in a root, sized
  so a cycle starts, then drop a stream of large bodies.
  - With the defaults: `cycleDeferredBytes()` never exceeds the bound plus one budget; the cycle
    ends with `finish_deferred` ≥ 1 and before `k == T`.
  - With `incremental_mark_deferred_finish` = 0: the deferred bytes do exceed the bound, so the test
    can detect the bug it guards against.
- **(g) Determinism.** The same allocation sequence with `gc_thread_mode` 0 and with background
  marking finishes its cycles at the same minor numbers (GC_DET_001).
- **(h) Knobs.** The HeapConfig defaults, JSON parsing, and validation bounds of both keys, as (e)
  does for `direct_alloc_minor_budget`.

E2E: `test/eco-system/src/LargeBytesHoldChurnTest.elm`, modelled on `LargeBytesChurnTest.elm`.
- **Shape.** Hold one 64 MiB `Bytes`, then stream 2 GiB of 64 KiB chunks from `/dev/zero`,
  dropping each.
- **Checks.** `-- CHECK: rss growth under 512 MiB: True`, sampled after warm-up.
- **Before the fix.** It must fail on the current tree, or it is not testing this (Phase 0).

## 8. Steps

**Phase 0: baselines and failing tests (no runtime change)**
1. Write (f) and the E2E. Confirm both fail on the current tree, and record the failing numbers in
   §10.
2. Record the baselines:
   - the `memgrowth` `hold` and `both` peaks, and MNIST's peak and wall;
   - the GC banner of a Stage 7 self-compile: cycles, `finish_*`, max pause, deferred bytes.

   Measure under the `release` preset, or with `-DECO_GC_STATS=OFF -DECO_ASSERTS_ON=OFF` (the
   `build` preset times its own instrumentation), and keep a stats build for the counters.

**Phase 1: D1, D4**
3. `cycleDeferredBytes()` with its resets, and the statistics.

**Phase 2: D2, D3**
4. `cycleDeferredFinishDue`, `deferredFinishFloor`, the check in `stepMarkCycle`, the two keys, and
   `docs/options.md`.
5. (f), (g), (h) and the E2E pass.

**Phase 3: §6**
6. The audits, MAPPING row, `tla-check`, `tla-trace`, and canary update.

**Phase 4: D5**
7. HEAP_084, the HEAP_063 and HEAP_066 amendments, and the README and memory pointers.

**Phase 5: gates and measurements**
8. Run each once, tee'd:
   - `cmake --build build --target full`;
   - the allocator unit tests in a heap-validate build (`ECO_HEAP_VALIDATE`; `docs/options.md`);
   - `tla-check`;
   - `tla-trace`.
9. Re-measure everything from step 2. Acceptance:
   - G2;
   - `both` within 5% of its baseline;
   - self-compile wall within noise, max pause not worse, and `finish_deferred` reported (expected
     0 or near 0);
   - MNIST results identical.

## 9. Risks

- **Pause spikes.** An early finish drains the rest of the mark in a minor pause. Bounded by
  `F × live_ref`: it fires only once the cycle has deferred as much as the live heap. Watch
  `slice_ns_max` and the pause distribution in Phase 5. If a workload pays, a larger `F` trades
  memory back for pauses.
- **Back-to-back cycles.** Finishing earlier must not make the next trigger fire at once.
  - `hold` ran one cycle in 9,000 steps; check it still runs few (the banner's cycle count).
  - Check LiveBudget's `alloc_since_major` against the bytes the handoff frees.
- **Thrash on small heaps.** `floor` (4 budgets) keeps a tiny `live_ref` from finishing every
  other minor; (f) covers a small heap.
- **Host callbacks (HEAP_083).** The check runs only at minor ends, which never happen inside a
  host callback, so nothing changes there.

## 10. Progress log

**2026-11-08: done (Phases 0–5).**

Code: `OldGenSpace::cycleDeferredBytes` / `cycleDeferredFinishDue`, `ThreadLocalHeap::deferredFinishFloor`
and the check in `stepMarkCycle` (D1, D2); the two keys in `AllocatorCommon.hpp`, `HeapConfigJson.cpp` and
`docs/options.md` (D3); `IncrMarkStats::finish_deferred` / `deferred_bytes_at_finish_max`, the banner's
`(deferred N)` and the `[gc-profile] cycle handoff ... deferred=` field (D4); HEAP_084 and the HEAP_063 /
HEAP_066 amendments (D5).

Deviations from the design:
- **Floor default 1, not 4.** On the `hold` repro (first cycle, so `live_ref` is 0 and the floor rules)
  the budget is about 64 MB: floor 4 peaked at 583 MB, floor 2 at 435 MB, floor 1 at 362 MB (G2 asks
  < 450 MB). The floor applies only when the traced live heap is smaller than it, so the mark work an
  early finish moves into a pause is small too.
- **More pins than §6 listed**, all M1 except one: `TLH.completeMarkCycle` (reads the deferred bytes for
  the stats and the `gc-profile` field), `OGS.beginMarkCycle` (resets the running sum at t0) and
  `OGS.reset` (M6; the same reset). Audited in M1's and M6's AUDIT.md: no model change.
- **`live_ref` counts traced bytes only** (HEAP_057), so a raw held body does not raise the threshold; the
  unit test (f) holds a traced list as well, so it checks the `F × live_ref` branch.

Phase 0 (failing first). With `incremental_mark_deferred_finish = 0`, which is the code path before the
change, `LargeBytesHoldChurnTest` grew RSS by 2,028,236 KiB (FAIL) and (f)'s control exceeds the bound
(`span_minors = T + 1`). The E2E first built its 64 MiB `Bytes` by doubling, which left about 200 MB
committed, so no trigger fired; it now builds it in one `Encode`.

Results (`build` preset, same binary, on vs. off by `ECO_HEAP_CONFIG`):

| Run | Before (finish off) | After (defaults) |
|---|---|---|
| `memgrowth hold`, 3,000 steps | 2.67 GB peak; 1 cycle, 33 minors, 2.11 GB deferred | 362 MB; 1 cycle, 2 minors, 127 MB deferred |
| `memgrowth both` | 239 MB | 239 MB |
| `LargeBytesHoldChurnTest` RSS growth | 2,028,236 KiB | 65,816 KiB; 1 finish, 122 MB deferred |
| `memgrowth hold`, 9,000 steps | 2.67 GB | 361 MB, flat |
| MNIST spike | 2.83 GB peak; 1 cycle, 33 minors, 2.12 GB deferred | 527 MB; 1 cycle, 2 minors, 134 MB deferred; accuracies and losses identical |
| Self-compile (Stage 6 `eco-compiler`, cold, solver+LSS) | 71.35 s wall, 6.34 GB RSS, 1,359 minors, 8 cycles (8 schedule) | 71.69 s, 6.37 GB, 1,359 minors, 8 cycles (8 schedule, 0 deferred); max deferred at a finish 1.69 MB; byte-identical output |

G2 holds (`hold` 361 MB < 450, MNIST 527 MB < 600); G3 holds (no finish on the self-compile, its GC
counts unchanged, wall and max pause within noise: max major pause 58.6 vs 60.4 ms). The MNIST walls
(4.2 vs 4.5 s) were taken while a bootstrap ran beside them, so they compare only with each other.
Measured under the `build` preset (stats and asserts on), not `release`: the comparison is one binary
with the finish on and off, so the instrument costs both arms alike.

Gates: `cmake --build build --target full` passed (3,091 native tests; JS target 265, 8 skipped;
node-addon and driver-cli); `LargeBodyChurn` (8 cases) and `threaded-gc` (168) pass in a heap-validate build
(`build-validate`); `tla-check` M1 quick tier 24/24, then the full quick tier (M1–M8) 297/297 on 2026-11-09; `tla-trace` 152/152, including the new
`cycle,deferred-b2` row and its negative control; canary updated.

Risk seen (§9, back-to-back cycles): on a heap whose triggers are always due, an early finish starts
the next cycle sooner. The new trace scenario (16 dying 60 KiB `Bytes` per step) runs 121 cycles of
9-10 minors in 1,208 minors with the finish off (always marking already: the paced LiveBudget counts
the churn in P_hat), and 400 cycles of about 3 minors with it on. Each early finish follows `F × live_ref`
bytes of deferred churn, so the added mark work is at most one live heap per `F × live_ref` deferred
bytes: a space-for-mark-work trade, set by `F`.
