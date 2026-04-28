# Sweep-on-Demand Allocation in OldGenSpace

## Goal

Enforce a **sweep-before-grow** discipline on the old-gen allocation slow path:
when there is unswept garbage from the current major-GC cycle, the mutator must
help drive lazy sweep until the request can be satisfied (or sweep finishes)
*before* burning a fresh bag page or growing committed capacity.

This layers cleanly on top of the existing segregated-fits + BBoP allocator,
mark-driven lazy sweep (`lazySweep`, `transitionToSweeping`, `onSweepComplete`),
post-mark all-dead reclaim, and per-block bitmaps. No invariants from
`design_docs/invariants.csv` change.

---

## Invariants we want to add

1. **Sweep-before-grow.** While `gc_phase_ == Sweeping` and any block has
   `fully_swept == false`, `allocateFromSizeClass` must not call
   `allocateFromBagPage` (and therefore must not consume an unassigned page or
   ask `Allocator` for a fresh one) until either a free cell appears or sweep
   finishes.

2. **Bounded mutator sweep work per allocation.** A single allocation may drive
   at most `MAX_SWEEP_BYTES_PER_ALLOC` (== `SWEEP_WORK_BUDGET * 256` ≈ 1 MiB)
   bytes of sweep work before falling through to the bag-page path. This caps
   the worst-case allocation latency on a multi-GB heap. Future tuning could
   make this `min(1 MiB, committed_bytes / N)` if pathologically slow drains
   show up on large heaps; not in scope for this change.

3. **No regressions to existing post-mark fast paths.** `finishMarkAndSweep`'s
   `INITIAL_SWEEP_BUDGET` slice and `reclaimAllDeadBlocksFromMeta` continue to
   run unchanged; this work is purely about the *mutator-driven* portion of
   sweep.

---

## Preconditions (already in place)

| Helper / state                                  | Used by this plan |
|-------------------------------------------------|-------------------|
| `GCPhase` state machine with `Sweeping` phase   | gating predicate  |
| `BufferMetadata { live_bytes, garbage_bytes, fully_swept }` per block | counting pending blocks |
| `lazySweep(target_class, work_budget)`          | per-allocation slice driver |
| `SWEEP_WORK_BUDGET = 4096`                      | base slice size   |
| `INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16` | initial post-mark slice (unchanged) |
| `transitionToSweeping`, `onSweepComplete`       | phase transitions |
| `MajorGCPhaseProfile::sweep_pending_blocks`     | telemetry; we'll feed this from the new counter |

---

## Step-by-step plan

### Step 1 — Add a `sweep_pending_blocks_` field to OldGenSpace

**File:** `runtime/src/allocator/OldGenSpace.hpp`

Extend the "Lazy Sweep State" section with a counter sibling to
`sweep_buffer_index_` / `sweep_cursor_`:

```cpp
// Number of blocks that still need sweeping in the current GC cycle.
// Initialised when transitioning to Sweeping; decremented as blocks become
// fully_swept; zeroed on onSweepComplete and on reset/ctor.
size_t sweep_pending_blocks_;
```

Add small inline predicates near the lazy-sweep helpers (private):

```cpp
bool hasPendingSweepWork() const {
    return gc_phase_ == GCPhase::Sweeping && sweep_pending_blocks_ > 0;
}
bool sweepComplete() const {
    return gc_phase_ != GCPhase::Sweeping || sweep_pending_blocks_ == 0;
}
```

Expose `sweep_pending_blocks_` to tests via `OldGenSpaceTestAccess` (read-only
getter), so the regression test in Step 5 can assert on it directly.

### Step 2 — Initialise / maintain `sweep_pending_blocks_`

**File:** `runtime/src/allocator/OldGenSpace.cpp`

1. **Constructor (`OldGenSpace::OldGenSpace`)** and **`reset(...)`**: add
   `sweep_pending_blocks_ = 0;` alongside the existing
   `sweep_buffer_index_/sweep_cursor_` initialisation (lines 79, 178-179).

2. **Counter init: `recomputeSweepPendingBlocks` helper.** The recount must
   run *after* `reclaimAllDeadBlocksFromMeta` (so all-dead blocks have already
   been removed from `buffer_meta_`) and *before* the initial
   `lazySweep(NUM_SIZE_CLASSES, INITIAL_SWEEP_BUDGET)` slice — i.e. before any
   mutator allocation can run in the Sweeping phase. The recount happens
   exactly once per major-GC cycle. Add a private helper:

   ```cpp
   void recomputeSweepPendingBlocks();  // private
   ```

   Implementation:

   ```cpp
   sweep_pending_blocks_ = 0;
   for (const auto& meta : buffer_meta_) {
       if (!meta.fully_swept) ++sweep_pending_blocks_;
   }
   ```

   Call it at the end of each `finishMarkAndSweep` overload, *after*
   `reclaimAllDeadBlocksFromMeta()` and *before* the initial
   `lazySweep(NUM_SIZE_CLASSES, INITIAL_SWEEP_BUDGET)` slice (lines
   1326-1329, 1357-1360, 1395-1398, 1421-1424). Counter semantics: unswept
   ⇔ `!meta.fully_swept`. No additional `live_bytes` / `garbage_bytes` gate
   — given `prepareMetaForLazySweep` and the prior all-dead reclaim, the
   only blocks that gate would exclude are ones that have already been
   removed.

   Do NOT recount inside `transitionToSweeping()`: at that point the
   all-dead reclaim has not yet run, so the count would be wrong by the time
   the first mutator slice executes.

3. **`lazySweep()`** (line 1633): at every spot that sets
   `buffer_meta_[idx].fully_swept = true`, decrement
   `sweep_pending_blocks_` (clamped to 0). The relevant sites are:
   - Large/pinned block fast path that sets `meta.fully_swept = true` after
     the single-object check (around line 1713).
   - Block-boundary handler that sets
     `buffer_meta_[sweep_buffer_index_].fully_swept = true;` (line 1749).

   Wrap the mutation in a small private helper to keep the two sites in sync:

   ```cpp
   void markBlockFullySwept(size_t idx) {
       if (idx >= buffer_meta_.size()) return;
       if (buffer_meta_[idx].fully_swept) return;  // idempotent
       buffer_meta_[idx].fully_swept = true;
       if (sweep_pending_blocks_ > 0) --sweep_pending_blocks_;
   }
   ```

4. **`onSweepComplete()`** (line 1782): set `sweep_pending_blocks_ = 0`
   defensively, immediately before `computeFragmentationStats()`.

5. **`fixupIndicesAfterBlockMove`** (line 2126 region): if a block is
   removed mid-cycle via `releaseBlockToAllocator`, check whether its
   `BufferMetadata` was `fully_swept == false` and decrement
   `sweep_pending_blocks_` accordingly *before* the swap-remove. (The current
   code keeps `sweep_buffer_index_` consistent across the move; we need the
   pending-blocks counter to track the same way.)

6. **`MajorGCPhaseProfile::sweep_pending_blocks`**: replace the
   `(sweep_buffer_index_ < blocks_.size()) ? ... : 0` computation in both
   profile-recording overloads of `finishMarkAndSweep` (lines 1379-1382 and
   1441-1444) with `profile.sweep_pending_blocks = sweep_pending_blocks_;`.
   This makes the telemetry reflect the real "blocks not yet `fully_swept`"
   count rather than a sweep-cursor proxy.

### Step 3 — Factor out free-list-only allocation

**File:** `runtime/src/allocator/OldGenSpace.cpp` (and `.hpp` declaration)

Extract the first two paragraphs of `allocateFromSizeClass` into a private
helper that *only* tries the free list and the splitter:

```cpp
void* OldGenSpace::tryAllocateFromFreeLists(size_t cls, size_t requested_size) {
    if (free_lists_[cls] != nullptr) {
        FreeCell* cell = free_lists_[cls];
        free_lists_[cls] = cell->next;
        void* result = static_cast<void*>(cell);
        initObjectHeaderWithSize(result, classToSize(cls));
        padCellSlack(result, requested_size, classToSize(cls));
        allocated_bytes += classToSize(cls);
        return result;
    }
    if (void* result = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(result, requested_size, classToSize(cls));
        return result;
    }
    return nullptr;
}
```

This is a behaviour-preserving refactor — `populateFromBlock` and
`allocateFromBagPage` stay outside this helper because they consume bag
pages.

### Step 4 — Wire sweep-on-demand into `allocateFromSizeClass`

Add a private helper that drives lazy sweep until either it produces a usable
cell or it hits the per-allocation cap:

```cpp
void* OldGenSpace::sweepOnDemandAllocate(size_t cls, size_t requested_size) {
    constexpr size_t MAX_SWEEP_BYTES_PER_ALLOC = SWEEP_WORK_BUDGET * 256;
    size_t swept = 0;
    while (hasPendingSweepWork()) {
        lazySweep(cls, SWEEP_WORK_BUDGET);
        swept += SWEEP_WORK_BUDGET;
        if (void* obj = tryAllocateFromFreeLists(cls, requested_size)) {
            return obj;
        }
        if (swept >= MAX_SWEEP_BYTES_PER_ALLOC) break;
    }
    return nullptr;
}
```

Restructure `allocateFromSizeClass` (line 459) to:

1. Call `tryAllocateFromFreeLists(cls, requested_size)`. Return on success.
2. If `hasPendingSweepWork()`, call `sweepOnDemandAllocate(cls, requested_size)`.
   Return on success.
3. Try `populateFromBlock(cls)` followed by another free-list pop. Return on
   success. **`populateFromBlock` is intentionally NOT gated behind
   `sweepComplete()`** — consuming a bag page is part of normal allocation
   behaviour, and gating it would underutilise already-available capacity
   without bounded benefit.
4. Fall through to `allocateFromBagPage(requested_size)`.
5. Return `nullptr` if nothing works.

The existing `padCellSlack` calls inside step 3 and the bag-page fallback are
preserved as in the current code. The current `allocate(size_t)` already does
a `lazySweep(sizeClass(size), SWEEP_WORK_BUDGET)` when
`gc_phase_ == GCPhase::Sweeping` (line 404-407): keep it. That gentle
background slice provides steady progress; Step 4's loop is the *emergency
driver* that runs only when the free-list path fails. The two are layered, not
alternatives.

### Step 5 — Tests

**New file:** `runtime/test/test_OldGen_sweep_on_demand.cpp`. Reuse helpers
from `test_OldGen_lazy_sweep.cpp` where possible (heap-construction
fixtures, `OldGenSpaceTestAccess` driving), but keep the sweep-on-demand
scenarios isolated so they're easy to extend.

1. **`SweepBeforeGrow`**: build a heap with `N` populated blocks, where each
   block has one live cell at the front and the rest is garbage. Trigger a
   major-GC cycle so `gc_phase_` ends up in `Sweeping` with
   `sweep_pending_blocks_ > 0`. Drive a loop of small allocations that would,
   under the *previous* behaviour, exhaust the bag and return `nullptr` /
   trigger growth. Assert:
   - `getUnassignedBlocks().size()` is non-decreasing across the loop until
     `sweepComplete()` becomes true.
   - `sweep_pending_blocks_` strictly decreases during the loop and reaches 0.
   - Allocations succeed throughout (no `nullptr` while sweep work remains).

2. **`PerAllocSweepCap`**: construct a pathological case where free lists
   never fill (e.g. all garbage is on a class that the request can't consume
   directly). Verify that a single allocation does not exceed
   `MAX_SWEEP_BYTES_PER_ALLOC` bytes of sweep work, and that the call falls
   through to `allocateFromBagPage`.

3. **`PendingBlocksCounterTracksFullySwept`**: drive `lazySweep` in small
   slices and assert `sweep_pending_blocks_` matches the count of
   `BufferMetadata` entries with `fully_swept == false`.

4. **`MidCycleBlockReleaseDecrementsCounter`**: trigger a path that calls
   `releaseBlockToAllocator` mid-sweep on an unswept block; assert
   `sweep_pending_blocks_` decremented by exactly one.

5. **Regression sanity**: existing tests in `test_OldGen_lazy_sweep.cpp`,
   `test_OldGen_capacity.cpp`, and `test_GC_pressure.cpp` should still pass
   without modification.

### Step 6 — Defensive checks (debug assert + release log)

These guard accounting invariants and sweep bookkeeping. Failure is serious
but not yet well-understood enough to crash production builds, so the policy
is: **debug-build `assert`, release-build optional log via the existing
`ECO_OLDGEN_DEBUG=1` env-gated path** (mirroring the BBoP free-list validator
already in the file).

- In `adjustCapacityAfterMajorGC`: `assert(gc_phase_ == GCPhase::Sweeping || sweepComplete());`
  (it runs *between* `transitionToSweeping` and the initial `lazySweep` slice,
  so we cannot assert `sweepComplete()` outright — only that the counter has
  been initialised).
- In `scheduleCompaction`: `assert(sweepComplete());`
- After `lazySweep` returns: in debug, recount `fully_swept == false` blocks
  and assert it equals `sweep_pending_blocks_`. In release with
  `ECO_OLDGEN_DEBUG=1`, log a single line if the recount mismatches.

These are scaffolding that can be removed once the invariant is well-trusted.

---

## Files touched

- `runtime/src/allocator/OldGenSpace.hpp` — new field, predicates, helper
  declarations, test-access getter.
- `runtime/src/allocator/OldGenSpace.cpp` — counter init/maintenance,
  `tryAllocateFromFreeLists`, `sweepOnDemandAllocate`,
  `markBlockFullySwept` helper, restructured `allocateFromSizeClass`,
  profile field source change.
- `runtime/test/test_OldGen_sweep_on_demand.cpp` (new) — Step 5 tests.

No changes to `Allocator`, `NurserySpace`, or `ThreadLocalHeap`.

---

## Out of scope

- Changing `INITIAL_SWEEP_BUDGET` or `SWEEP_WORK_BUDGET` defaults.
- Replacing the existing per-allocation `lazySweep` slice in
  `OldGenSpace::allocate` (line 404-407) — Step 4's loop runs in addition to
  it on the slow path.
- Touching nursery / minor-GC sweep logic.
- Compaction scheduling changes beyond the optional debug assert.

---

## Risk assessment

| Risk                                                | Mitigation                                        |
|-----------------------------------------------------|---------------------------------------------------|
| `MAX_SWEEP_BYTES_PER_ALLOC` cap too low → mutator stalls under fragmentation | Cap chosen as `SWEEP_WORK_BUDGET * 256 ≈ 1 MiB`; loop falls back to bag page if exceeded. |
| Counter drift between `sweep_pending_blocks_` and actual `fully_swept` count | Centralise mutations in `markBlockFullySwept`; debug-only recount assert (Step 6). |
| `releaseBlockToAllocator` mid-sweep undercounts     | Step 2.5 explicitly handles this case.            |
| Stage-7 latency regression from per-alloc loop      | Loop only runs while `hasPendingSweepWork()`; otherwise zero overhead. Tested in Step 5. |
