# Dynamic Pressure-Aware Lazy Sweep

## Motivation

Today every allocation slow-path slice in `OldGenSpace::sweepOnDemandAllocate`
sweeps at most `SWEEP_WORK_BUDGET = 4096` bytes per `lazySweep` call, capped per
allocation by a hardcoded `MAX_SWEEP_BYTES_PER_ALLOC = SWEEP_WORK_BUDGET * 256`
(1 MiB) (`runtime/src/allocator/OldGenSpace.cpp:531-543`). Under high pressure
near the 12 GiB old-gen cap with substantial unswept garbage, this fixed budget
can fail to liberate enough free cells before the allocation falls through to
`populateFromBlock` / `allocateFromBagPage`, which can no longer grow capacity
and returns `nullptr` even though large amounts of garbage are recoverable.

Goals:

1. Make per-allocation lazy-sweep work scale with (a) allocation size,
   (b) old-gen committed-to-cap pressure, and (c) fraction of unswept blocks.
2. Add an optional **panic sweep** path: when the global cap is reached and
   bag-page acquisition fails, drive any remaining lazy sweep work to
   completion before declaring OOM.

Non-goals: changing mark pacing, free-list structure, compaction, or shrink
policy. This change is confined to the slow path inside
`OldGenSpace::allocateFromSizeClass` plus tuning constants and counters.

## Step-by-step plan

### Stage 1 — Tuning constants and helpers

1. In `runtime/src/allocator/OldGenSpace.hpp`, after the existing
   `SWEEP_WORK_BUDGET` / `INITIAL_SWEEP_BUDGET` / `MARK_WORK_RATIO` block
   (lines 86–95), add a new `Adaptive Lazy-Sweep Pacing` constants section:
   - `SWEEP_BYTES_PER_ALLOC_BYTE = 2.0` (double): base proportionality factor.
     Conservative default; mark `// TODO: calibrate via GCPressureTest`.
   - `MAX_SWEEP_BYTES_PER_ALLOC = 1u << 20` (size_t): soft per-alloc cap (1 MiB).
   - `MAX_SWEEP_BYTES_HARD = 4u << 20` (size_t): absolute cap after scaling
     (4 MiB). Fixed for the first cut; if Stage 7 still dies, switch to
     `std::max<size_t>(4u << 20, getCommittedBytes() / 256)`.
   - `SWEEP_CAP_RATIO_LOW / MEDIUM / HIGH` (double): pressure thresholds.
   - `SWEEP_SCALE_LOW / MEDIUM / HIGH / CRIT` (double): pressure multipliers.
   - `SWEEP_UNSWEPT_RATIO_BOOST`, `SWEEP_UNSWEPT_SCALE`: unswept-fraction
     boost.
   - `PANIC_SWEEP_SLICE_BYTES = 1u << 20` (size_t): per-slice budget in panic
     mode (1 MiB).
2. In the same header, add private helper declarations alongside
   `tryAllocateFromFreeLists` / `sweepOnDemandAllocate`:
   - `size_t computeSweepBudgetForAlloc(size_t requested_size) const;`
   - `double committedToCapRatio() const;`
   - `void* panicSweepAndRetryAllocation(size_t cls, size_t requested_size);`
3. Update the comment on `sweepOnDemandAllocate` (currently lines 491–498) to
   describe the *dynamic* budget and remove the stale
   "MAX_SWEEP_BYTES_PER_ALLOC cap" wording.

### Stage 2 — Implementation

4. In `runtime/src/allocator/OldGenSpace.cpp`, near the existing sweep helpers
   (around the current `sweepOnDemandAllocate` at line 531):
   - Implement `committedToCapRatio()` using
     `config_->max_heap_size / 2` as the local cap proxy and
     `getCommittedBytes()` as numerator (clamped to [0,1]). Comment it as
     "approximate; bounded above by Allocator's cap" — if `Allocator` later
     exposes a cheap `getOldGenCapBytes()` / `getOldGenCommittedBytes()`,
     swap to that without changing call sites.
   - Maintain a new private member `sweep_total_blocks_` initialised in
     `recomputeSweepPendingBlocks()` to the count of `buffer_meta_` entries
     where `!fully_swept && garbage_bytes > 0`. Reset to 0 on construction
     and in `onSweepComplete`. This is the meaningful denominator for the
     unswept-ratio boost, since `blocks_.size()` includes mid-cycle blocks
     pre-set to `fully_swept`.
   - Implement `computeSweepBudgetForAlloc(requested_size)`:
     a. base = clamp(`requested_size * SWEEP_BYTES_PER_ALLOC_BYTE`,
        `SWEEP_WORK_BUDGET`, `MAX_SWEEP_BYTES_PER_ALLOC`)
     b. scale by piecewise step on `committedToCapRatio()`
     c. boost by `SWEEP_UNSWEPT_SCALE` if `sweep_total_blocks_ > 0` and
        `sweep_pending_blocks_ / sweep_total_blocks_ >
        SWEEP_UNSWEPT_RATIO_BOOST`
     d. clamp final to `MAX_SWEEP_BYTES_HARD`.
5. Rewrite `sweepOnDemandAllocate(cls, requested_size)` to:
   - Call `tryAllocateFromFreeLists` first; return on success.
   - Return `nullptr` if `!hasPendingSweepWork()`.
   - Compute `max_sweep_bytes = computeSweepBudgetForAlloc(requested_size)`.
   - Loop while `hasPendingSweepWork() && swept < max_sweep_bytes`:
     - `slice = min(SWEEP_WORK_BUDGET, max_sweep_bytes - swept)`
     - `lazySweep(cls, slice); swept += slice;`
     - Retry `tryAllocateFromFreeLists`; return on success.
   - Return `nullptr` when budget exhausted.

   Note: `lazySweep` uses `work_budget` as a byte budget for `work_done` (see
   `OldGenSpace.cpp:1738`), so accounting `slice` directly is correct (it
   matches what we asked the sweeper to do; may slightly over-estimate when
   sweep ends mid-slice — safe direction for pacing). Document as
   "requested slice == accounted bytes".
6. Add `panicSweepAndRetryAllocation(cls, requested_size)`:
   - Return `nullptr` if `!hasPendingSweepWork()`. **Drop** the
     `committedToCapRatio() >= SWEEP_CAP_RATIO_HIGH` precondition: we get
     here only after `allocateFromBagPage` failed, which already implies
     "growth impossible". The invariant *panic only fires after growth has
     failed* lives at the call site.
   - While `hasPendingSweepWork()`:
     - `lazySweep(cls, PANIC_SWEEP_SLICE_BYTES);`
     - Retry `tryAllocateFromFreeLists`; return on success.
   - Return `nullptr` once sweep is exhausted.

### Stage 3 — Wire panic path into `allocateFromSizeClass`

7. In `OldGenSpace::allocateFromSizeClass` (currently
   `OldGenSpace.cpp:545-588`), insert the panic call only on the failure
   leg of `allocateFromBagPage`:
   - keep paths 1-3 unchanged
   - after path 4 (`allocateFromBagPage`) returns `nullptr`, call
     `panicSweepAndRetryAllocation(cls, requested_size)` and return its
     result if non-null
   - finally fall through to the existing `return nullptr`.

   Do **not** add a panic call between paths 1 and 4 — bag pages should be
   consumed first so panic mode only fires when capacity growth is impossible.

### Stage 4 — Telemetry (only inside `#if ENABLE_GC_STATS`)

Use **`GCStats` counters** rather than `MajorGCPhaseProfile`. Phase profile
is only allocated when `ECO_GC_PHASE_PROFILE` is on, and the wall-time side
of the story is already in `total_lazy_sweep_in_mutator_ns`
(`GCStats.hpp:210`). What we want here is *bytes swept under dynamic
budgets*, which fits the cumulative-counter model.

8. In `runtime/src/allocator/GCStats.hpp`, alongside
   `total_lazy_sweep_in_mutator_ns`, add:
   - `uint64_t total_lazy_sweep_bytes_in_mutator = 0;`
   - `uint64_t total_panic_sweep_bytes = 0;`
9. In `GCStats.cpp`, extend the merge in `combine` (`GCStats.cpp:245-246`
   pattern) and reset (`GCStats.cpp:877-878` pattern) for both new fields.
   Add to the existing summary printout in the same vicinity as the
   `total_lazy_sweep_in_*_ns` block.
10. In `sweepOnDemandAllocate` and `panicSweepAndRetryAllocation`, bump
    `alloc_stats_.total_lazy_sweep_bytes_in_mutator` /
    `alloc_stats_.total_panic_sweep_bytes` by `slice` /
    `PANIC_SWEEP_SLICE_BYTES` after each `lazySweep` call (gated on
    `ENABLE_GC_STATS`). `Allocator::getCombinedStats()` already merges
    `OldGenSpace::alloc_stats_` so no plumbing changes are needed.

### Stage 5 — Tests

11. New file `test/allocator/OldGenSweepBudgetTest.cpp` (or extend
    `OldGenLazySweepTest.cpp`). Use `OldGenSpaceTestAccess` to:
    - Build an oldgen with a small `max_heap_size` (e.g., 4 MiB).
    - At three committed/cap fractions (~0.30, ~0.70, ~0.97), call
      `computeSweepBudgetForAlloc(requested_size)` via a new test accessor and
      assert the returned budget grows monotonically.
    - With `sweep_pending_blocks_ / sweep_total_blocks_ > 0.5`, assert the
      boost multiplier kicks in (and that pre-`fully_swept` mid-cycle blocks
      do **not** dilute the ratio).
12. Extend `test/allocator/GCPressureTest.cpp` with a panic-sweep scenario:
    - Tiny old gen, configure to leave a large amount of garbage post-mark.
    - Drive allocations until the bag-page path must fail.
    - With `ENABLE_GC_STATS`, assert
      `combined_stats.total_panic_sweep_bytes > 0` and that subsequent
      allocations succeed without further capacity growth.
    - Also report MB allocated vs MB swept vs lazy-sweep wall time, so the
      same test doubles as the calibration harness for
      `SWEEP_BYTES_PER_ALLOC_BYTE`.
13. Extend `OldGenSpaceTestAccess` (the right pattern — don't add new
    `friend` classes) with:
    - `static size_t computeSweepBudgetForAlloc(OldGenSpace&, size_t)`
    - `static double committedToCapRatio(const OldGenSpace&)`
    - `static size_t getSweepTotalBlocks(const OldGenSpace&)`
    - a forcer for the "no growth available + pending sweep" precondition
      so the panic path is deterministic.

### Stage 6 — Validate

14. `cmake --build build --target full` (Elm + E2E).
15. Compare `ECO_GC_PHASE_PROFILE` output before/after on Stage 7-style
    pressure runs to confirm:
    - normal-pressure allocations still cost ~`SWEEP_WORK_BUDGET` per slice
    - near-cap allocations show inflated `lazy_sweep_bytes_in_mutator`
    - panic path only fires when `committedToCapRatio() >= 0.95`.

## Files touched

- `runtime/src/allocator/OldGenSpace.hpp` (constants, decls,
  `sweep_total_blocks_` member, comment refresh)
- `runtime/src/allocator/OldGenSpace.cpp` (helpers, rewritten
  `sweepOnDemandAllocate`, new `panicSweepAndRetryAllocation`,
  `allocateFromSizeClass` panic call, `recomputeSweepPendingBlocks` /
  `onSweepComplete` wiring of `sweep_total_blocks_`)
- `runtime/src/allocator/GCStats.{hpp,cpp}` (two new cumulative byte
  counters + combine/reset/print)
- `test/allocator/OldGenLazySweepTest.cpp` or new
  `test/allocator/OldGenSweepBudgetTest.cpp`
- `test/allocator/GCPressureTest.cpp`
- `test/allocator/TestHelpers.{hpp,cpp}` (test accessor additions)

## Resolutions (from review)

1. **`committedToCapRatio` denominator.** Keep `config_->max_heap_size / 2`
   with a comment "approximate; bounded above by Allocator's cap". If
   Allocator gains a cheap `getOldGenCapBytes()` / `getOldGenCommittedBytes()`,
   swap to that without changing call sites. Don't plumb an Allocator
   back-reference into the budget calculation just for this.

2. **Panic guard threshold.** Drop the
   `committedToCapRatio() >= SWEEP_CAP_RATIO_HIGH` precondition inside
   `panicSweepAndRetryAllocation`. Invariant lives at the call site:
   panic only fires after `allocateFromBagPage` has already failed.

3. **Telemetry plumbing.** Use **GCStats counters**
   (`total_lazy_sweep_bytes_in_mutator`, `total_panic_sweep_bytes`) rather
   than plumbing through `MajorGCPhaseProfile`. Phase profile is only
   allocated when `ECO_GC_PHASE_PROFILE` is on; cumulative counters survive
   without it and are merged via existing `Allocator::getCombinedStats`.

4. **Calibration of `SWEEP_BYTES_PER_ALLOC_BYTE`.** Land at `2.0` with a
   `// TODO: calibrate via GCPressureTest` comment. The same panic-sweep
   pressure test in Stage 5 doubles as the calibration harness — it reports
   MB allocated vs MB swept vs lazy-sweep wall time so the factor can be
   tuned across 1.0 / 2.0 / 4.0 against throughput and pause histograms.

5. **`MAX_SWEEP_BYTES_HARD = 4 MiB`.** Acceptable first cut (≫ current
   4 KiB). If Stage 7 still dies under pressure, switch to
   `std::max<size_t>(4u << 20, getCommittedBytes() / 256)` so a 12 GiB heap
   allows up to ~48 MiB sweep per allocation in extreme cases.

6. **Unswept-ratio denominator.** Cache `sweep_total_blocks_` in
   `recomputeSweepPendingBlocks`, counting only entries with
   `!fully_swept && garbage_bytes > 0`. Use
   `sweep_pending_blocks_ / sweep_total_blocks_` for the boost ratio. This
   excludes mid-cycle blocks that are pre-set to `fully_swept`.

7. **Per-class vs per-allocation budget.** Heaps are thread-local — no
   global old gen, no cross-thread sweep contention. Independent multi-MiB
   budgets per size class are fine; defer a global cap until profiling
   shows pathological multi-thread CPU spikes.

8. **Compaction interaction.** Compaction is manual-trigger / incremental
   today, so panic sweep predominantly runs without it. Sweeping a block
   that's also in `evacuation_set_` is harmless but wasteful. Leave panic
   sweep ignorant of compaction for now; revisit when automatic compaction
   triggering is enabled.

9. **Test accessor surface.** Extend `OldGenSpaceTestAccess` (the existing
   pattern — see the rich set of accessors already there). Don't introduce
   new friend test classes. Specific additions enumerated in Stage 5 §13.

10. **Slice-bytes accounting.** Keep `requested slice == accounted bytes`
    and document the approximation. `lazySweep(cls, work_budget)` is
    specified to sweep *up to* `work_budget`, so `swept += slice` may
    over-estimate when sweep ends mid-slice — the safe direction for
    pacing. Refactoring `lazySweep` to return actual bytes swept is
    deferred until precise accounting is needed (e.g., hard real-time).
