# Old-gen capacity shrink + large/pinned page reuse

## Problem

Two related issues observed in the old-gen allocator:

1. **`old_gen_committed` only ever grows.** After a major GC reclaims most live
   data, the global counter never goes down, so we can hit
   `nursery_offset` (the global cap) even when most pages are empty.
2. **`OldGenSpace::allocateLargeBlock` always asks `Allocator::acquireOldGenBlock`
   for a fresh block.** It ignores reclaimed dedicated large blocks and
   fully-free regular pages, so large/pinned allocations push `old_gen_committed`
   higher even when reusable pages exist in this `OldGenSpace`.

## Goal

- After major GC, return some completely-free pages to the global allocator so
  `old_gen_committed` shrinks below the cap.
- Make `allocateLargeBlock` reuse already-committed free pages (dedicated
  large blocks first, then fully-free regular pages) before falling back to
  `acquireOldGenBlock`.

## Files in scope

- `runtime/src/allocator/Allocator.hpp` / `Allocator.cpp` — global page release API.
- `runtime/src/allocator/OldGenSpace.hpp` / `OldGenSpace.cpp` — shrink path,
  large-block free list, reuse in `allocateLargeBlock`, sweep changes.
- `runtime/src/allocator/ThreadLocalHeap.{hpp,cpp}` — unchanged in API; large
  pinned path already routes through `OldGenSpace::allocate` →
  `allocateLargeBlock`.

## Decisions (resolved before implementation)

1. `releaseBlockToAllocator` handles only `blocks_` entries. A separate
   helper `releaseUnassignedBlockToAllocator` drains `unassigned_blocks_`
   when explicitly invoked from the shrink path.
2. Decommit gated by a new `HeapConfig::decommit_on_oldgen_release` flag
   (default `true`).
3. Treat the old-gen region as one long reserved mapping for process
   lifetime. Release uses `madvise(MADV_DONTNEED)`; reacquire reuses the
   same virtual addresses (optionally `MADV_WILLNEED`). No `munmap` /
   re-`mmap`.
4. Floor: `min_heap = max(initial_old_gen_size, alloc_buffer_size)`. No
   extra config knob.
5. Hysteresis via utilization band, no time throttling:
   - Grow when `live/committed > major_gc_initiating_occupancy` (existing).
   - Shrink only when `live/committed < major_gc_target_utilization * 0.8`
     **and** `heap_bytes > desired_heap * 1.2`.
   - Run shrink at most once per major GC (current call site already
     enforces this).
6. Shrink decisions are per-thread, based on `initial_old_gen_size`;
   independent of `getOldGenMaxBytes()` (the global cap).
7. `adjustCapacityAfterMajorGC()` does **not** acquire `thread_mutex_`.
   `Allocator::releaseOldGenBlock` acquires it internally. Add a comment
   plus a debug-build assert to catch accidental re-entry.
8. No race between shrink and `allocateFromEmptyRegularBlocks`: GC and
   shrink run with the mutator stopped; mutator allocations resume only
   afterward. `removeFreeCellsForBlock` runs *before* `is_large` flip in
   the alloc path, preventing double-accounting.
9. Shrink candidate scan does **not** skip `is_large`; only
   `live_bytes == 0 && fully_swept` matters. Order: prefer free regular
   pages first, then free `is_large` blocks (also drop them from
   `free_large_blocks_` when released).
10. Linear scans in `removeFreeCellsForBlock` and
    `fixupIndicesAfterBlockMove` are acceptable; revisit only if profiling
    flags them.
11. `ThreadLocalHeap::allocateLargePinned` API and retry-after-major-GC
    semantics unchanged.
12. `dumpHeapState` extended (Step 6) with global committed + cap,
    per-thread live/heap/utilization, `free_large_blocks_.size()`, count of
    fully-free pages, and `old_gen_free_blocks_.size()`.
13. Tests live under `test/allocator/`. Extend `OldGenSpaceTest.cpp` or
    create `test/allocator/OldGenCapacityTest.cpp` under the same CMake
    test target.

## Plan

### Step 1 — Allocator: symmetric `releaseOldGenBlock` API

**`AllocatorCommon.hpp`**

- Add `bool decommit_on_oldgen_release = true;` to `HeapConfig`. No
  validation needed (boolean).

**`Allocator.hpp`**

- Add private declaration `void releaseOldGenBlock(char* block, size_t size);`
  alongside `acquireOldGenBlock`.
- Add private member
  `std::vector<std::pair<char*, size_t>> old_gen_free_blocks_;` to track
  released blocks (mirrors `nursery_low_freelist_` /
  `nursery_high_freelist_`).

**`Allocator.cpp`**

- Modify `acquireOldGenBlock(size)` to first scan `old_gen_free_blocks_` for a
  block of size ≥ requested. On hit:
  - swap-remove the entry,
  - optionally `madvise(MADV_WILLNEED)` (no-op if not decommitted),
  - re-add `block_size` to `old_gen_committed`,
  - return the base. **No `mmap` call** — the virtual mapping was never
    released.
- Fallback to the existing bump path (which still does the initial `mmap`
  the first time a virtual range is touched) unchanged.
- Implement `releaseOldGenBlock(block, size)`:
  - acquire `thread_mutex_` (debug-only assert that the caller did not
    already hold it; with `recursive_mutex` re-entry is silently allowed,
    so use `try_lock`+release pattern in the assert),
  - if `config_.decommit_on_oldgen_release`:
    `madvise(block, size, MADV_DONTNEED)` (POSIX) so RSS drops,
  - push `(block, aligned_size)` onto `old_gen_free_blocks_`,
  - assert `old_gen_committed >= aligned_size` then subtract.

**Notes**:
- Reuse policy is first-fit by size. Splitting a larger reused block into a
  smaller request is *not* in scope for this step (call sites currently
  request whole pages or whole large-block extents).

### Step 2 — `OldGenSpace`: shrink path in `adjustCapacityAfterMajorGC`

**`OldGenSpace.hpp`**

- Add private helpers:
  - `void releaseBlockToAllocator(size_t block_index);`
  - `void releaseUnassignedBlockToAllocator(size_t unassigned_index);`
  - `void removeFreeCellsForBlock(size_t block_index);`
  - `void fixupIndicesAfterBlockMove(size_t old_idx, size_t new_idx);`
  - `void maybeShrinkCapacity();`

**`OldGenSpace.cpp`**

- Implement `releaseBlockToAllocator(block_index)`:
  1. `removeFreeCellsForBlock(block_index)` — walk every `free_lists_[i]` and
     unlink any `FreeCell` whose address lies in `[blk.start, blk.end)`.
  2. If the block is `is_large` and present in `free_large_blocks_`,
     swap-remove it from `free_large_blocks_`.
  3. `allocator_->releaseOldGenBlock(blk.start, blk.totalBytes())`.
  4. Update `frag_stats_.heap_bytes -= total`.
  5. Erase the matching `BufferMetadata` entry.
  6. Swap-remove from `blocks_`; if the moved-from index differed, run
     `fixupIndicesAfterBlockMove` to patch:
     - `BufferMetadata::block_index` for any meta that pointed at the
       last-index slot,
     - `evacuation_set_` entries,
     - `evac_block_index_`, `sweep_buffer_index_`, `fixup_buffer_index_`,
     - `free_large_blocks_` entries (Step 4) referencing the moved index.
  7. Recompute `region_base_` / `region_end_` if either pointed into the
     released block (linear scan over remaining blocks).

- Implement `releaseUnassignedBlockToAllocator(unassigned_index)`:
  1. Read `(start, end)` from `unassigned_blocks_[unassigned_index]`.
  2. `allocator_->releaseOldGenBlock(start, end - start)`.
  3. Swap-remove from `unassigned_blocks_`. No `blocks_` / `buffer_meta_`
     touched — these pages were never materialized.
  4. Recompute `region_base_` / `region_end_` if either was anchored to the
     released extent.

- Extend `adjustCapacityAfterMajorGC` to add a shrink branch *before* the
  current early-returns:

  ```cpp
  // SHRINK band: live/committed < target * 0.8 AND heap > desired * 1.2.
  if (occupancy <= target) {
      maybeShrinkCapacity();
      return;
  }
  if (occupancy < grow_threshold) return;
  // existing grow logic
  ```

  `maybeShrinkCapacity()`:
  1. Guard with `compact_phase_ == CompactionPhase::Idle && gc_phase_ == GCPhase::Idle`.
  2. Compute `desired_heap = ceil(live / target_utilization)`, clamped below
     by `min_heap = max(config_->initial_old_gen_size, config_->alloc_buffer_size)`.
  3. Hysteresis gate: only proceed if
     `occupancy < target * 0.8` **and** `current_heap > desired_heap * 1.2`.
  4. **First pass — fully-free regular pages**: walk `buffer_meta_` collecting
     indices where `meta.fully_swept && meta.live_bytes == 0` and the
     corresponding `blocks_[i].is_large == false`. For each, if releasing
     keeps `current_heap - blk.totalBytes() >= desired_heap`, call
     `releaseBlockToAllocator(idx)` and decrement the running counter.
  5. **Second pass — fully-free large blocks**: same scan but for
     `is_large == true`. Releasing also removes the entry from
     `free_large_blocks_` (handled inside `releaseBlockToAllocator`).
  6. **Third pass — `unassigned_blocks_`**: for each entry whose extent
     would not push committed below `min_heap`, call
     `releaseUnassignedBlockToAllocator`. Stops at the same `desired_heap`
     budget.
  7. Stop when current_heap ≤ desired_heap.

- **Important wiring detail**: `adjustCapacityAfterMajorGC` is already called
  at the end of `sweep()` (line 938) and inside `lazySweep`'s
  `onSweepComplete` path (line 1064). No new call sites needed; existing wiring
  drives the shrink (and once-per-GC throttle).

- **Locking**: `adjustCapacityAfterMajorGC` and `maybeShrinkCapacity` must
  not acquire `Allocator::thread_mutex_`. `releaseOldGenBlock` and
  `releaseUnassignedBlockToAllocator` acquire it transiently inside the
  Allocator. Add a comment at the top of `maybeShrinkCapacity` documenting
  this invariant.

### Step 3 — Sweeper: register dead large blocks for reuse

**`OldGenSpace.cpp`** (modifications to `sweep()` at line 880 and the
analogous coalescing path inside `lazySweep`)

- Before the per-block coalescing loop, branch on `block.is_large`:
  - Single object at `block.start`. Inspect its header color:
    - **Live (Black → White)**: do existing path (one live object, no coalescing).
    - **Dead**: do **not** push a Tag_Free cell onto `free_lists_`. Instead:
      - set `meta.live_bytes = 0; meta.garbage_bytes = block.totalBytes(); meta.fully_swept = true;`
      - call `markBlockAsFreeLarge(buf_idx)` (Step 4),
      - `continue` to next block.

- The same logic applies in `lazySweep` — when sweep advances past the last
  parseable byte of a `is_large` block, decide live vs dead and either keep
  the live header or register the block as free-large.

### Step 4 — Large-block free list and reuse in `allocateLargeBlock`

**`OldGenSpace.hpp`**

- Add private members and helpers:
  - `std::vector<size_t> free_large_blocks_;`
  - `void markBlockAsFreeLarge(size_t block_index);`
  - `void* allocateFromFreeLargeBlocks(size_t size);`
  - `void* allocateFromEmptyRegularBlocks(size_t size);`

- Extend `OldGenSpaceTestAccess` with read-only accessors for
  `free_large_blocks_` so tests can assert reuse paths.

**`OldGenSpace.cpp`**

- `markBlockAsFreeLarge(idx)`: append to `free_large_blocks_`; assert no
  duplicate.

- `allocateFromFreeLargeBlocks(size)`: align `size` to 8, scan
  `free_large_blocks_` for the first index whose `blocks_[idx].totalBytes() >= size`.
  On hit:
  - swap-remove from `free_large_blocks_`,
  - reset `BufferMetadata` to live (`live_bytes = size`, `garbage_bytes = total - size`, `fully_swept = true`),
  - update `frag_stats_.live_bytes`,
  - update `allocated_bytes += size`,
  - call `initObjectHeader(blk.start)`,
  - return `blk.start`.

  Note: `blocks_[idx].end_of_objects` should be reset to `blk.start + size` so
  later sweep walks parse only the live object (matches the convention in the
  current `allocateLargeBlock` initial materialization).

- `allocateFromEmptyRegularBlocks(size)`: aligned `size`, walk `buffer_meta_`
  for entries with `fully_swept && live_bytes == 0` whose corresponding block
  is `!is_large` and large enough. On hit:
  - flip `blocks_[idx].is_large = true`,
  - `removeFreeCellsForBlock(idx)`,
  - reset `end_of_objects` to `start + size`,
  - update bookkeeping as above,
  - return `blk.start`.

- Rewrite `allocateLargeBlock(size)`:

  ```
  if (void* p = allocateFromFreeLargeBlocks(size)) return p;
  if (void* p = allocateFromEmptyRegularBlocks(size)) return p;
  // existing path: round to PAGE_SIZE, acquireOldGenBlock, materialize BlockInfo.
  ```

- The existing fallback path stays as-is. It already handles the
  `acquireOldGenBlock == nullptr` case (`return nullptr`), which the caller
  (`ThreadLocalHeap::allocateLargePinned`) handles by triggering a major GC
  and retrying once (`ThreadLocalHeap.cpp:175`).

### Step 5 — Tests

Place tests under `test/allocator/`. Either extend
`test/allocator/OldGenSpaceTest.cpp` or create
`test/allocator/OldGenCapacityTest.cpp` under the same CMake test target.
Use `OldGenSpaceTestAccess` and `AllocatorTestAccess` for privileged access
(both already exist).

1. **Capacity shrinks after major GC**:
   - Configure heap with a small old-gen cap and small `initial_old_gen_size`.
   - Allocate enough large pinned objects to push `getOldGenCommittedBytes()`
     to the cap.
   - Drop all roots, run two majorGCs.
   - Assert `getOldGenCommittedBytes() < cap` and
     `getOldGenCommittedBytes() >= initial_old_gen_size` (floor honored).
   - Allocate one more large pinned object — must succeed without abort.

2. **Large-block reuse — same address**:
   - Allocate a large pinned object of exactly `alloc_buffer_size`. Capture
     the address.
   - Drop the root, major GC.
   - Allocate another large pinned object of the same size.
   - Assert the new address equals the captured address and
     `getOldGenCommittedBytes()` is unchanged across the two allocations.

3. **Empty-page conversion to large**:
   - Fill several regular pages with small live objects.
   - Drop the small objects, major GC; verify pages are now fully free.
   - Allocate a large pinned object that fits in one page.
   - Assert no new `acquireOldGenBlock` call (committed counter unchanged) and
     the now-large block reuses one of the freed regular pages.

4. **Hysteresis**:
   - Drive utilization to just under `target_utilization` (e.g. 0.45 with
     default 0.50 target). Assert `getOldGenCommittedBytes()` is **not**
     reduced (hysteresis gate `< target * 0.8 = 0.40` not crossed).
   - Drive utilization further down (e.g. 0.30). Assert shrink fires.

5. **Floor honored**:
   - Drop all roots, major GC. Assert
     `getOldGenCommittedBytes() >= max(initial_old_gen_size, alloc_buffer_size)`.

6. **`unassigned_blocks_` shrink**:
   - Configure heap so init carves multiple unassigned pages but the workload
     leaves most of them untouched.
   - Run major GC. Assert some `unassigned_blocks_` entries are returned to
     `Allocator::old_gen_free_blocks_` and `getOldGenCommittedBytes()` drops.

7. **Decommit flag**:
   - With `decommit_on_oldgen_release = false`, run shrink and assert RSS
     does **not** drop (best-effort: check committed counter falls but
     pages remain resident).
   - With the flag `true`, the same scenario should `madvise`. We can't
     portably assert RSS in unit tests, so just exercise the code path.

8. **Invariants** (under a debug flag, e.g. `ECO_GC_DEBUG`):
   - After every major GC: `frag_stats_.heap_bytes ==
     Σ (blocks_[i].end_of_objects - blocks_[i].start)`.
   - After release: `Allocator::old_gen_committed` decreases by the released
     block size.

### Step 6 — Diagnostics: extend `dumpHeapState` and `ECO_GC_DEBUG`

**`Allocator::dumpHeapState`** (existing in `Allocator.cpp`):
- Print global `old_gen_committed`, old-gen cap (`getOldGenMaxBytes()`),
  and `old_gen_free_blocks_.size()` plus their total bytes.

**Per-thread dump** (loop body inside `dumpHeapState`):
- Per `OldGenSpace`: `getCommittedBytes()`, `frag_stats_.live_bytes`,
  `frag_stats_.heap_bytes`, utilization (`live/heap`),
  `free_large_blocks_.size()`, count of fully-free pages
  (`Σ buffer_meta_[i] where live_bytes == 0 && fully_swept`),
  `unassigned_blocks_.size()`.

**`ECO_GC_DEBUG` invariants** (only emitted when env enables verbose tracing):
- After `releaseBlockToAllocator(idx)`: assert no entry in
  `evacuation_set_`, `free_large_blocks_`, `buffer_meta_`, or any
  `free_lists_[*]` references the released block extent.
- After every `acquireOldGenBlock` reuse hit: assert the returned region was
  previously released (i.e., the entry came from `old_gen_free_blocks_`).

---

## Open questions

None — all 13 prior questions resolved (see Decisions section above).
