# Mark-driven live bytes, all-dead block fast path, and lazy-sweep wiring

## Problem

The Stage-7 bootstrap workload exposes three weaknesses in the current major-GC
path (`OldGenSpace::finishMarkAndSweep` → `sweep`):

1. **Sweep walks every cell in every block, even when 100% of the block is
   garbage.** Per-block live/garbage bytes are computed *during* sweep
   (`OldGenSpace.cpp:1174` and `1208`), so we cannot short-circuit on
   "this whole block is dead". Stage-7 traces show one major GC spending
   ~117 s walking ~3 GB of cells, the vast majority of which are dead.
2. **Trigger and shrink policy is too coarse.** `shouldTriggerMajorGC`
   already has a per-thread occupancy trigger plus a global-pressure trigger
   at `cap/3`, but post-GC shrink in `maybeShrinkCapacity` defers to a
   `target_utilization * 0.8` band whose hysteresis sometimes leaves
   committed at multi-GB after the live working set has collapsed. We want
   the post-GC shrink to be tighter and to use mark-derived `live_bytes`
   directly, not garbage-bytes accounting from sweep.
3. **`finishMarkAndSweep` calls the monolithic `sweep()` synchronously.**
   `transitionToSweeping` and `lazySweep` already exist (`OldGenSpace.hpp:406-408`)
   and `OldGenSpace::allocate` is already wired to drive `lazySweep` from the
   slow path (`OldGenSpace.cpp:246-249`), but no major-GC path actually
   leaves the space in `GCPhase::Sweeping` for the mutator to drive — the
   STW `sweep()` call always runs to completion and resets `gc_phase_` to
   Idle. So sweep cost is paid as one long pause, never amortized.

## Goal

After this change, a major GC should:

- Reclaim entirely-dead blocks in O(#blocks) without scanning their cells.
- Use mark-time `live_bytes` to drive shrink immediately after mark, before
  any sweep work runs.
- Leave per-cell sweep to incremental work driven from the allocation
  slow-path, so the STW pause is dominated by mark only.

These map to the three improvements in the design doc the user supplied:
all-dead block fast path; earlier major triggers + strict post-GC shrink;
lazy sweep wired into the allocation slow-path.

## Files in scope

- `runtime/src/allocator/OldGenSpace.hpp` — declarations for
  `blockIndexFor`, `reclaimAllDeadBlocksFromMeta`, signature change to
  `maybeShrinkCapacity` (takes a `desired_heap_bytes`), helper to attribute
  live bytes during mark.
- `runtime/src/allocator/OldGenSpace.cpp` — mark attribution in
  `incrementalMark` (and its inline twin in `OldGenSpace::allocate`),
  finalize per-block meta after mark, all-dead reclaim, finishMarkAndSweep
  rewrite, lazy-sweep tweaks, shrink rewrite, computeFragmentationStats
  consistency.
- `runtime/src/allocator/ThreadLocalHeap.cpp` — verify `majorGC` does not
  assume `gc_phase_` returns to `Idle` when `finishMarkAndSweep` returns
  (it currently does via `sweep()`); add a comment for the new contract,
  no behavioral change required.
- `test/allocator/OldGenSpaceTest.{hpp,cpp}` and/or
  `test/allocator/OldGenCapacityTest.{hpp,cpp}` — new test cases for the
  three behaviors (all-dead block reclaim; mark-driven shrink; lazy-sweep
  driven from allocation).

## Decisions (resolved before implementation)

1. **Mark-time attribution: refactor.** Introduce a private
   `markOneObject(void* obj)` helper that:
   - loads the header,
   - performs the White → Grey → Black transition,
   - skips already-Black or `Tag_Free` objects,
   - attributes `live_bytes` to `buffer_meta_[blockIndexFor(obj)]`
     using the same `walkStep` sweep uses.
   Call it from both `incrementalMark` (`OldGenSpace.cpp:803-829`) and
   the inline marker inside `OldGenSpace::allocate`
   (`OldGenSpace.cpp:218-241`). Stats counters (the
   `GC_STATS_MAJOR_INC_INCREMENTAL_MARK` accumulation) stay at the call
   sites.

2. **`blockIndexFor` is O(1) via a page index.** Maintain a
   `std::vector<size_t> page_to_block_index_` keyed by
   `page = (p - region_base_) / alloc_buffer_size`. Strategy:
   - For non-large blocks: write the `blocks_` index into every page
     slot the block covers when it enters `blocks_`; clear/patch the
     entries on `releaseBlockToAllocator` and `fixupIndicesAfterBlockMove`.
   - For `is_large` blocks: also fill `page_to_block_index_` over every
     page the extent covers so the lookup remains O(1) regardless of
     block kind. Falls back to a linear scan only if the page index is
     out of range (e.g. a stray pointer past the current `region_end_`).
   - Re-sized whenever `region_end_` grows (in
     `populateFromBlock`/`allocateFromBagPage` paths and in the
     bulk-grow path used by `ensureOldGenCapacityFor`); reset entries
     on shrink.
   - Sentinel `NO_BLOCK` (== `SIZE_MAX`) marks "page is currently
     unassigned (in `unassigned_blocks_`) or just-released".

3. **`is_large` blocks: preserve reuse path.** Exclude `is_large`
   blocks from `reclaimAllDeadBlocksFromMeta`. Continue routing dead
   large blocks through `markBlockAsFreeLarge` /
   `allocateFromFreeLargeBlocks` as today (`OldGenSpace.cpp:563-609`).
   Revisit only if cap pressure shows large-block hoarding.

4. **Two-pass shrink, second pass gated.** Keep both:
   - After mark (Step 4): the primary shrink, sized from
     mark-derived `live_bytes`.
   - In `onSweepComplete`: a *light* second pass that fires only when
     `current_heap > desired_heap * 1.5`. This handles fully-swept
     blocks that mark-time live attribution couldn't yet identify as
     all-dead (in practice: rare, since mark already gives an exact
     `live_bytes`; the second pass mostly catches blocks that became
     fully empty through `padCellSlack` or splitting).

5. **Compaction blocked during sweep.** Make `shouldCompact()` return
   false when `gc_phase_ != GCPhase::Idle`, and have
   `scheduleCompaction()` early-return in the same condition. The
   `meta.fully_swept` gate alone is correct but confusing; an explicit
   phase check makes the contract obvious.

6. **`computeFragmentationStats` semantics during lazy sweep.**
   - Immediately after mark (in `finishMarkAndSweep`):
     - `frag_stats_.live_bytes = sum(meta.live_bytes)`.
     - `frag_stats_.heap_bytes = sum(blocks_[i].end_of_objects - .start)`
       (current parseable region).
     - `frag_stats_.total_free_bytes = heap_bytes - live_bytes`
       (estimate, until lazy sweep produces real free cells).
   - During lazy sweep: each `pushSpanOnFreeLists` increments
     `frag_stats_.total_free_bytes` by the span size (it currently
     does this only via `meta.garbage_bytes`; we'll wire the
     side-effect explicitly).
   - At `onSweepComplete`: re-run `computeFragmentationStats()` for
     a precise post-sweep snapshot before the second-pass shrink
     decision.

7. **Trigger thresholds unchanged.** "Earlier triggers" means
   "earlier than the pre-fix behavior where committed could balloon
   to 12 GB before any major fired" — not lower configured thresholds.
   - Keep `major_gc_initiating_occupancy = 0.75`.
   - Keep the global-pressure threshold at `initiating_occupancy / 3`
     (`OldGenSpace.cpp:1438-1444`).
   The cap-bound behavior we want comes from (a) accurate per-thread
   `allocated_bytes` and (b) committed not ballooning unchecked
   between majors — both of which fall out of Steps 1–4.

8. **`INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16` (64 KB).** Add
   `static constexpr size_t INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16;`
   in `OldGenSpace.hpp`. Big enough to seed free lists for the first
   few allocations after major GC; small enough to keep the post-mark
   pause bounded on a multi-GB heap.

9. **Extend `MajorGCPhaseProfile`.** Add:
   - `size_t alldead_blocks_released = 0;`
   - `size_t alldead_bytes_released = 0;`
   - `size_t initial_sweep_budget_bytes = 0;`
   - `size_t sweep_pending_blocks = 0;` (count after Step 7's initial
     slice — i.e. how much sweep work is being deferred to the mutator).
   These appear in the `[gc-profile]` log line in `ThreadLocalHeap::majorGC`.

10. **Test ordering: targeted tests in the same branch.** Land the
    code changes alongside at least one focused test per feature:
    - All-dead block reclaim (1 live + 1 all-dead block, asserts on
      `blocks_.size()` and that no per-cell sweep traffic occurred).
    - Lazy sweep advances from allocation: after `finishMarkAndSweep`
      with `gc_phase_ == Sweeping`, calling `og.allocate(N)` repeatedly
      moves `sweep_cursor_` and populates `free_lists_`, eventually
      reaching `gc_phase_ == Idle`.
    - Shrink reduces `committed` after a "live ≪ committed" GC.
    Existing suite + a Stage-7 run validate the production win;
    fine-grained matrix can be expanded after.

## Plan

### Step 1 — Page-index for O(1) `blockIndexFor`

1.1 In `OldGenSpace.hpp` (private section), add:

```cpp
// Maps page slot (= (p - region_base_) / alloc_buffer_size) to the
// blocks_ index that owns the page. NO_BLOCK marks "unassigned".
// Sized to ceil(committed / alloc_buffer_size); resized when the
// committed region grows.
std::vector<size_t> page_to_block_index_;

// Returns the blocks_ index of the block containing obj, or
// blocks_.size() if obj lies outside the committed region. O(1) via
// page_to_block_index_; falls back to a linear scan only if the page
// slot is NO_BLOCK (e.g. just-released).
size_t blockIndexFor(const void* obj) const;
```

1.2 Maintenance points (all in `OldGenSpace.cpp`):
- On commit/grow (`initialize`, `populateFromBlock` /
  `allocateFromBagPage` paths that extend `region_end_`, plus any
  `ensureOldGenCapacityFor`-driven grow): resize
  `page_to_block_index_` to cover the new region, fill new entries
  with `NO_BLOCK`.
- When a block enters `blocks_` (in `populateFromBlock`,
  `allocateFromBagPage`, `allocateLargeBlock`,
  `allocateFromFreeLargeBlocks`, `allocateFromEmptyRegularBlocks`):
  for every page slot the block covers, set
  `page_to_block_index_[slot] = blocks_.size() - 1`.
- On `releaseBlockToAllocator` (`OldGenSpace.cpp:1722`): clear the
  block's page slots to `NO_BLOCK` BEFORE the swap-remove; after the
  swap-remove, walk the moved-from block's page slots and rewrite
  them to point at the new index. Hook into the existing
  `fixupIndicesAfterBlockMove` (`OldGenSpace.cpp:1700`).
- On `releaseUnassignedBlockToAllocator` (`OldGenSpace.cpp:1795`):
  page slots are already `NO_BLOCK` (the bag-page extents never
  entered `blocks_`); no change needed.

1.3 Implement `blockIndexFor`:
- If `obj < region_base_ || obj >= region_end_`: return `blocks_.size()`.
- Compute `page = (p - region_base_) / alloc_buffer_size`.
- If `page < page_to_block_index_.size()` and the entry isn't
  `NO_BLOCK`: return it.
- Else fall back to `findBlockContaining`-equivalent linear scan
  (defensive; should be unreachable in steady state).

1.4 Verification:
- Add an internal debug assert (gated on `ECO_OLDGEN_DEBUG`) that
  `blockIndexFor(obj)` matches a linear scan for every block-resident
  object encountered in mark for the first N runs.

### Step 2 — Mark-time live-bytes attribution via `markOneObject`

2.1 In `OldGenSpace.hpp` (private section), add:

```cpp
// Performs the White → Grey → Black transition on obj, recursively
// pushes children via markChildren, and attributes the object's
// walkStep-aligned size to buffer_meta_[blockIndexFor(obj)].live_bytes.
// Skips Tag_Free and already-Black objects. Returns true if the
// object transitioned (i.e. did real work).
bool markOneObject(void* obj);

// O(#blocks) reset of buffer_meta_ to match blocks_, called at
// major-GC start so live_bytes attribution can begin from zero.
void resetBufferMetaForMark();

// Sets meta.garbage_bytes = blockTotal - meta.live_bytes (clamped),
// and frag_stats_.live_bytes = sum(meta.live_bytes). Called from
// finishMarkAndSweep after the mark stack drains.
void finalizeMetaAfterMark();
```

2.2 Implementation:
- `markOneObject` body matches the existing inline marker in
  `OldGenSpace::allocate` (`OldGenSpace.cpp:227-233`) plus the
  `live_bytes` attribution. Step size = `walkStep(block, getObjectSize(obj))`
  to stay consistent with sweep's accounting.
- `incrementalMark` (`OldGenSpace.cpp:803-829`) becomes a thin loop:
  pop `obj`, call `markOneObject(obj)`, increment `units_done` if the
  call returned true, repeat until `work_units` budget is exhausted
  or stack empty. Stats counters (`GC_STATS_MAJOR_INC_INCREMENTAL_MARK`)
  remain in `incrementalMark`.
- The inline marker inside `OldGenSpace::allocate`
  (`OldGenSpace.cpp:218-241`) becomes the same loop, calling
  `markOneObject(obj)` instead of duplicating the body.
- `resetBufferMetaForMark`: clear/resize `buffer_meta_` to match
  `blocks_.size()`; for every entry set `block_index = i`,
  `live_bytes = 0`, `garbage_bytes = 0`, `fully_swept = false`.
- Call `resetBufferMetaForMark()` from `startMark`
  (`OldGenSpace.cpp:704-706`) after the defense-in-depth Black-reset
  block, before pushing roots.

2.3 `finalizeMetaAfterMark` runs once in `finishMarkAndSweep`, after
the mark stack drains and before any reclaim/sweep work. Defensively
clamps `meta.live_bytes <= block.totalBytes()` and writes
`frag_stats_.live_bytes`, `frag_stats_.heap_bytes`, and the estimate
`frag_stats_.total_free_bytes = heap_bytes - live_bytes`.

2.4 Verification at this step:
- Existing `sweep()` still runs after this (the rewrite of
  `finishMarkAndSweep` is in Step 4). Because `sweep()` zeroes
  `meta.live_bytes` at `OldGenSpace.cpp:1174` before recomputing,
  attribution introduced here does not perturb sweep output.
- Debug assert (gated on `ECO_OLDGEN_DEBUG`) at the end of `sweep()`:
  `frag_stats_.live_bytes_after_mark` (snapshotted before sweep)
  equals `frag_stats_.live_bytes_after_sweep`.

### Step 3 — All-dead block fast path

3.1 In `OldGenSpace.hpp`, add:

```cpp
// After mark + finalizeMetaAfterMark, releases every non-large block
// whose live_bytes == 0. Returns the number of blocks released so the
// caller can record it on MajorGCPhaseProfile. Walks back-to-front so
// swap-removes don't disturb later indices; brackets the loop with
// g_batch_release_depth and recomputes region_base_/region_end_ once
// at the end, mirroring maybeShrinkCapacity (OldGenSpace.cpp:1645-1664).
struct AllDeadReclaimStats { size_t blocks_released = 0; size_t bytes_released = 0; };
AllDeadReclaimStats reclaimAllDeadBlocksFromMeta();
```

3.2 In `OldGenSpace.cpp`:
- Implement `reclaimAllDeadBlocksFromMeta()`:
  - Build a vector of indices with `meta.live_bytes == 0 && !blocks_[i].is_large`.
  - Sort descending; bracket the release loop with
    `++/--g_batch_release_depth`; for each idx call
    `releaseBlockToAllocator(idx)` (which already drops the free-list
    cells, large-block entries, and updates `frag_stats_.heap_bytes`).
  - After the loop, recompute `region_base_`/`region_end_` once.
  - Page-index maintenance from Step 1.2 fires inside
    `releaseBlockToAllocator`.
  - Return `{blocks_released, bytes_released}`.
- `is_large` blocks are intentionally excluded; they continue to flow
  through `markBlockAsFreeLarge` /
  `allocateFromFreeLargeBlocks`.

3.3 Profile reporting: extend `MajorGCPhaseProfile` with
`size_t alldead_blocks_released; size_t alldead_bytes_released;`
(per Decision 9) and surface them in the `[gc-profile]` line in
`ThreadLocalHeap::majorGC` (`ThreadLocalHeap.cpp:420-451`). This is
load-bearing for measuring whether the fast path is paying off.

### Step 4 — Lazy sweep replaces STW sweep in finishMarkAndSweep

4.1 Refactor `finishMarkAndSweep` (both ENABLE_GC_STATS and non-stats
overloads, both with-profile and without-profile variants — four call
sites in `OldGenSpace.cpp:955-1036`):

```
1. Drain mark stack (as today).
2. finalizeMetaAfterMark()                       // sets meta.live_bytes, garbage_bytes,
                                                 // fully_swept=false; writes
                                                 // frag_stats_.live_bytes,
                                                 // frag_stats_.heap_bytes,
                                                 // frag_stats_.total_free_bytes (estimate).
3. reclaimAllDeadBlocksFromMeta()                // Step 3.
4. adjustCapacityAfterMajorGC()                  // shrink (Step 5) using mark-derived live;
                                                 // runs BEFORE transitionToSweeping so
                                                 // shrink can release fully-empty blocks
                                                 // without lazy-sweep needing to touch them.
5. transitionToSweeping()                        // sets gc_phase_ = Sweeping; clears
                                                 // free lists; resets meta to be rebuilt
                                                 // by lazySweep (preserving the
                                                 // mark-derived live_bytes — see 4.2).
6. lazySweep(NUM_SIZE_CLASSES, INITIAL_SWEEP_BUDGET)
                                                 // small initial slice to seed free lists.
7. marking_active = false.
```

The final `gc_phase_ = Idle` is set by `lazySweep` /
`onSweepComplete` once it has walked every block. This means
`finishMarkAndSweep` returns with `gc_phase_ == Sweeping` for any
non-trivial heap.

4.2 `transitionToSweeping` currently zeroes
`meta.live_bytes`/`garbage_bytes`/`fully_swept` for every block
(`OldGenSpace.cpp:1280-1284`). With mark now producing `live_bytes`,
that wipe destroys information the shrink path just used. Two
approaches:
- Move the `meta.live_bytes`/`garbage_bytes`/`fully_swept` reset out
  of `transitionToSweeping` and into a separate
  `prepareMetaForLazySweep()` that only zeroes `garbage_bytes` and
  `fully_swept` (preserving `live_bytes`). Lazy sweep recomputes
  `live_bytes` as it walks, just like `sweep()` does today. The
  overlap (mark counts `live_bytes`; lazy sweep also counts it) is
  fine because the values are equal by construction; the assert in
  Step 2.4 catches drift.
- OR: have lazy sweep skip `live_bytes` accounting entirely and
  trust the mark-derived value. Less defensive — harder to detect
  drift. Default plan: prefer the first approach.

4.3 `INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16` (64 KB; per
Decision 8). Add as `static constexpr size_t INITIAL_SWEEP_BUDGET`
in `OldGenSpace.hpp`. (Not env-tunable in v1; revisit if needed.)

4.4 Keep `sweep()` as a thin loop over `lazySweep` (used by tests
and as a defensive fallback). Make it:
```cpp
void OldGenSpace::sweep() {
    if (gc_phase_ != GCPhase::Sweeping) {
        transitionToSweeping();
    }
    while (gc_phase_ == GCPhase::Sweeping) {
        lazySweep(NUM_SIZE_CLASSES, std::numeric_limits<size_t>::max() / 2);
    }
}
```
This means the existing per-cell sweep code at
`OldGenSpace.cpp:1159-1260` becomes dead and gets removed. Confirm no
test relies on `sweep()` performing the rebuild atomically (Step 7).

4.5 Confirm `OldGenSpace::allocate` already drives lazy sweep
(`OldGenSpace.cpp:246-249`) — yes, it does. No change required there
beyond auditing that `SWEEP_WORK_BUDGET = 4096` is the right per-call
slice now that this is the only sweep path.

4.6 Lazy-sweep free-cell accounting: today
`pushSpanOnFreeLists` writes only into `meta.garbage_bytes` indirectly
(via `pushCoalescedFreeCell` callers). With Decision 6, lazy sweep
must also bump `frag_stats_.total_free_bytes` for each pushed cell
so the running estimate converges to the true value before
`onSweepComplete`'s recompute. Wire this in `lazySweep`'s
`flushRun`/coalescing-flush paths (`OldGenSpace.cpp:1299-1394`).

4.7 `onSweepComplete` already calls `computeFragmentationStats` and
`adjustCapacityAfterMajorGC` (`OldGenSpace.cpp:1406-1409`). With Step
5 those calls become the "second pass" shrink — see Step 5 for the
gating.

4.8 `ThreadLocalHeap::majorGC` does not currently inspect `gc_phase_`
after `finishMarkAndSweep` returns. Audit:
- `dumpHeapState("majorGC end")` (`ThreadLocalHeap.cpp:454`) — read
  the implementation to confirm it doesn't assert `gc_phase_ == Idle`.
- The `[gc-profile]` log line — extend with
  `sweep_pending=<bytes>` so the deferred sweep work is visible.

### Step 5 — Strict shrink after mark, using mark-derived live bytes

5.1 Change `OldGenSpace.hpp` declaration:

```cpp
// Inspects post-mark live/heap and, if heap is well above the
// desired capacity, releases fully-free pages until heap ≈ desired_heap.
// `desired_heap_bytes` is computed by adjustCapacityAfterMajorGC.
// `light_pass` skips releases unless current_heap > desired_heap * 1.5
// — used at onSweepComplete (Decision 4) to avoid double-shrink churn.
void maybeShrinkCapacity(size_t desired_heap_bytes, bool light_pass = false);
```

5.2 Rework `adjustCapacityAfterMajorGC` (`OldGenSpace.cpp:1450-1482`):
- Use `frag_stats_.live_bytes` (mark-derived after Step 2).
- Compute `desired_heap = ceil(live / target_utilization)`, clamp by
  `min_heap = max(initial_old_gen_size, alloc_buffer_size)` (current
  floor in `maybeShrinkCapacity`, kept unchanged).
- If `live == 0 || occupancy <= target`: `maybeShrinkCapacity(desired_heap)`.
- Else if `occupancy < initiating_occupancy`: no-op (band).
- Else (above initiating): grow as today via
  `allocator_->ensureOldGenCapacityFor(*this, desired_heap)` clamped by
  the global cap.
- This call from `finishMarkAndSweep` runs as the **primary** shrink
  (heavy pass).

5.3 Rework `maybeShrinkCapacity` to take the desired-heap target and
a `light_pass` flag:
- Drop the recomputation of `desired_heap` here (caller passes it).
- Keep the "global pressure bypasses hysteresis" branch
  (`OldGenSpace.cpp:1545-1558`) — it remains relevant.
- Keep the three release passes (regular, large, unassigned) and the
  batched free-list unlink pass (`OldGenSpace.cpp:1600-1664`)
  unchanged.
- Hysteresis (heavy pass): `current_heap > desired_heap * 1.2` AND
  `occupancy < target * 0.8`, as today, unless overridden by global
  pressure.
- Hysteresis (light pass): `current_heap > desired_heap * 1.5`
  (stricter), no occupancy gate, no global-pressure bypass.

5.4 `onSweepComplete` (`OldGenSpace.cpp:1406-1409`):
- Call `computeFragmentationStats()` to get a precise post-sweep
  snapshot (`total_free_bytes` is now accurate; `live_bytes` should
  be unchanged since mark, asserted in Step 2.4).
- Re-derive `desired_heap` from the precise `live_bytes`.
- Call `maybeShrinkCapacity(desired_heap, /*light_pass=*/true)` — the
  second-chance shrink. Cleans up blocks that became fully-empty
  through `padCellSlack`/splitting after the heavy pass.

5.5 Compaction guard:
- In `shouldCompact()` (`OldGenSpace.cpp:1854`): early-return `false`
  when `gc_phase_ != GCPhase::Idle`.
- In `scheduleCompaction()` (`OldGenSpace.cpp:1862`): early-return
  when `gc_phase_ != GCPhase::Idle`.

### Step 6 — Triggers (verification only)

6.1 Inspect `shouldTriggerMajorGC` (`OldGenSpace.cpp:1411-1448`).
Confirm the per-thread occupancy trigger and global-pressure trigger
already match the user's design. The only change is to the comment
header to reflect "lazy sweep means earlier triggers are cheap" and
that the cap-bound behavior comes from accurate `allocated_bytes`
plus committed-not-ballooning, NOT from lowered thresholds (Decision 7).

6.2 No threshold changes.

### Step 7 — Tests

7.1 Targeted tests landed alongside the implementation (Decision 10),
in `OldGenSpaceTest.cpp` (or a new `OldGenLazySweepTest.cpp`
registered in the same CMake target):

a. **`testAllDeadBlockReclaimSkipsCells`** — build a heap with two
   blocks: one fully-live (one root pointing into it), one fully-dead
   (no roots into it). Run `startMark`, drain mark, call
   `finalizeMetaAfterMark`, verify `buffer_meta_[dead].live_bytes == 0`
   AND `buffer_meta_[live].live_bytes > 0`. Call
   `reclaimAllDeadBlocksFromMeta`; verify the dead block is gone from
   `blocks_` and that no per-cell sweep traffic was needed (e.g.
   instrument `pushCoalescedFreeCell` call count and assert zero
   for the dead block).

b. **`testLazySweepDrivenFromAllocation`** — after
   `finishMarkAndSweep` with a non-trivial heap, assert
   `OldGenSpaceTestAccess::getGCPhase(og) == GCPhase::Sweeping`.
   Snapshot `getSweepCursor(og)` and `getSweepBufferIndex(og)`. Call
   `og.allocate(N)` repeatedly; verify the cursor advances, free
   lists become non-empty, and `gc_phase_` eventually transitions to
   `Idle`.

c. **`testShrinkUsesMarkLiveBytes`** — set up so that the live
   working set is small and `committed` is large pre-GC. After
   `finishMarkAndSweep`, assert `committed_after < committed_before`
   without having driven any lazy sweep work — the shrink decision
   ran from mark-derived `live_bytes` alone.

d. **`testCompactionBlockedDuringSweep`** — after `finishMarkAndSweep`
   leaves `gc_phase_ == Sweeping`, assert `shouldCompact()` returns
   false; call `scheduleCompaction()` and assert
   `getCompactPhase(og) == CompactionPhase::Idle`.

e. **`testPageIndexBlockLookup`** (Step 1) — drive
   `populateFromBlock` and `releaseBlockToAllocator` cycles; assert
   `blockIndexFor(p)` matches a brute-force linear scan for every
   live object across multiple grow/shrink cycles.

7.2 Existing tests to re-validate:
- `testCapacityShrinksAfterMajorGC` (in `OldGenCapacityTest.cpp`) —
  must still pass under new shrink path.
- `OldGenSpaceTest.cpp` sweep-coalescing tests — must still pass with
  `sweep()` rerouted through `lazySweep`.

7.3 E2E:
- `cmake --build build --target full` (full pipeline rebuild).
- Run `stress` filter to confirm Stage-7 advances further (or at
  least doesn't regress).
- Run with `ECO_GC_PHASE_PROFILE=1` and capture `[gc-profile]` lines
  for one Stage-7 run; report mark_ns, alldead reclaim, sweep_pending
  bytes, and verify the long sweep has been broken into many small
  slices driven from allocation.

### Step 8 — Documentation and follow-ups

8.1 Update `design_docs/theory/major-gc-75-50-policy.md` (referenced
from `OldGenSpace.hpp:413`) to describe:
- mark-driven `live_bytes`,
- all-dead fast path,
- lazy-sweep + slow-path drive,
- two-pass shrink (mark-time heavy + onSweepComplete light).

8.2 Add invariants in `design_docs/invariants.csv`:
- `HEAP_NNN`: After `finalizeMetaAfterMark`,
  `frag_stats_.live_bytes` equals the sum of `walkStep`-aligned sizes
  of all Black objects in old gen.
- `HEAP_NNN+1`: `gc_phase_` may be `Sweeping` outside of major-GC
  pauses; the mutator drives `lazySweep` to completion.
- `HEAP_NNN+2`: Compaction may be scheduled only when
  `gc_phase_ == Idle`.

8.3 Future follow-ups (not in scope):
- Parallel / background sweep (run `lazySweep` on a helper thread
  between allocations).
- Make `INITIAL_SWEEP_BUDGET` env-tunable if Stage-7 profile data
  shows it needs tuning per workload.
- Consider releasing dead `is_large` blocks back to the allocator
  after some reuse-attempt threshold (Decision 3 deferral).

## Risk and rollback

- The mark-time attribution touches the hottest GC path
  (`incrementalMark` and the inline mark in `allocate`, both routed
  through the new `markOneObject`). A bug in `walkStep` step
  accounting can leave `live_bytes` either too small (over-aggressive
  shrink, possible re-trigger churn) or too large (no shrink at all,
  regression). Mitigation: defense-in-depth assert (Step 2.4)
  comparing post-mark `live_bytes` against post-sweep `live_bytes`
  for every cycle when `ECO_OLDGEN_DEBUG` is set.
- The page-index maintenance (Step 1) touches every block-lifecycle
  call site. A missed update leaves `blockIndexFor` returning a stale
  index and live-bytes attributed to the wrong block. Mitigation: the
  Step 1.4 cross-check assert against linear scan, and the Step 7.1e
  unit test exercising grow/shrink cycles.
- The lazy-sweep wiring removes the "sweep is finished by the time
  `majorGC` returns" invariant, which a few code paths or tests may
  depend on. Mitigation: `sweep()` retained as a defensive
  loop-to-completion helper that any caller can invoke if they need
  the old behavior; document each removal.
- Rollback path: each step (1, 2, 3, 4, 5) lands as a separate commit
  and can be reverted independently. Step 4 (lazy sweep replaces
  STW sweep) is the riskiest behavior change; it can be
  feature-flagged behind `ECO_OLDGEN_LAZY_SWEEP=1` for an interim
  release if desired.

## Open questions

All previously-listed open questions have been resolved by the user's
follow-up answers; see the "Decisions" section above for the agreed
behavior. Implementation can proceed.
