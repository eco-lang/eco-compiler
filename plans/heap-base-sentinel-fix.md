# Heap-Base Sentinel Fix (BBoP page-0 reservation)

## Goal

Replace the current "bump page 0's start by 8 bytes" hack in
`OldGenSpace::initialize` with a proper **8-byte `Tag_Free` sentinel** at
`heap_base + 0` while keeping every BBoP page extent (and therefore every
`releaseOldGenBlock` argument) page-aligned.

This eliminates the symptom where:
- The first page in `unassigned_blocks_` is `[heap_base + 8, heap_base + 128KiB)`,
  i.e. `alloc_buffer_size - 8` bytes wide;
- When that block is later released via `releaseBlockToAllocator`,
  `Allocator::releaseOldGenBlock` subtracts `131064` from `old_gen_committed`,
  leaving it at a non-page-multiple offset (`...0008`);
- The next `mmap(MAP_FIXED, ...)` from `acquireOldGenBlock` can target a
  misaligned address and fail / corrupt accounting.

The post-fix invariant: **no allocation ever returns `heap_base + 0`** (the
HPointer encoding of a real object would collide with the null sentinel),
**and** every BBoP page is tracked as a full `alloc_buffer_size`-byte extent
on `unassigned_blocks_`, in `BlockInfo`, and at every release boundary.

## Files Touched

| File | Change |
|---|---|
| `runtime/src/allocator/OldGenSpace.hpp` | Add `HEAP_BASE_SENTINEL_SIZE`; declare `isHeapBasePage`, `installHeapBaseSentinel` private helpers. |
| `runtime/src/allocator/OldGenSpace.cpp` | Stop bumping page 0; install sentinel lazily in `populateFromBlock` / `allocateFromBagPage`; force heap-base block to mixed size_class; defend sweep, large-allocation, evacuation, and reuse paths. |
| `runtime/src/allocator/Allocator.cpp` | Defensive: filter `heap_base + 0` out of `acquireOldGenBlock` first-fit reuse. |
| Tests | New unit test asserting `BlockInfo.totalBytes() == alloc_buffer_size` for the heap-base page; assert `old_gen_committed % alloc_buffer_size == 0` after a release cycle. |

## Background

Today (`OldGenSpace.cpp:147-157`):

```cpp
for (size_t i = 0; i < num_pages; ++i) {
    char* page_start = region_base + i * page_size;
    char* page_end = page_start + page_size;
    if (page_start == g_heap_base) {
        page_start += 8;          // <-- the bug
    }
    unassigned_blocks_.emplace_back(page_start, page_end);
}
```

The defense in `initObjectHeaderWithSize` (`OldGenSpace.cpp:230-235`) asserts
that no object is handed out at `heap_base + 0`, but this is detect-only —
the upstream `releaseOldGenBlock` accounting bug has already happened by then.

## Design Summary

1. Page 0's `unassigned_blocks_` extent becomes the full
   `[heap_base, heap_base + alloc_buffer_size)` — exactly like every other page.
2. The first time the heap-base page is materialized (in `populateFromBlock`
   or `allocateFromBagPage`):
   - We install an **8-byte sentinel** with `tag = Tag_Free`, `size = 8`,
     `pin = 1` at `heap_base + 0`.
   - The block is materialized with `size_class = NUM_SIZE_CLASSES` (**mixed**),
     never a uniform-fixed-cell class. (See "Critical correctness issue 1"
     below for why.)
   - The post-sentinel span `[heap_base + 8, heap_base + alloc_buffer_size)`
     is pushed via `pushSpanOnFreeLists(... block.size_class = mixed ...)`,
     which already packs descending-class cells correctly for mixed blocks.
3. Sweep, compaction, and large-block reuse paths must each skip / preserve
   the sentinel.

## Step-by-Step Plan

### Phase 1 — Header changes (no behavior change)

1. In `OldGenSpace.hpp` near `MIN_FREE_CELL_SIZE`, add:
   ```cpp
   // 8-byte Tag_Free sentinel parked at heap_base + 0 so HPointer{ptr=0} stays
   // unambiguously null. NOT a FreeCell (size < MIN_FREE_CELL_SIZE), never on
   // a free list, never returned to the mutator.
   static constexpr size_t HEAP_BASE_SENTINEL_SIZE = sizeof(Header);
   ```
2. Declare two private helpers in `OldGenSpace`:
   ```cpp
   bool isHeapBasePage(char* page_start) const;
   void installHeapBaseSentinel(char* page_start);
   ```

### Phase 2 — Stop truncating page 0

In `OldGenSpace::initialize` (`OldGenSpace.cpp:147-158`), delete the
`if (page_start == g_heap_base) { page_start += 8; }` branch. Push the full
`[page_start, page_end)` extent for every page into `unassigned_blocks_`.
The bag now contains `num_pages` extents each exactly `alloc_buffer_size`
bytes wide.

### Phase 3 — Implement the helpers

In `OldGenSpace.cpp`:

```cpp
bool OldGenSpace::isHeapBasePage(char* page_start) const {
    return allocator_ != nullptr && page_start == allocator_->getHeapBase();
}

void OldGenSpace::installHeapBaseSentinel(char* page_start) {
    Header* hdr = reinterpret_cast<Header*>(page_start);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag  = Tag_Free;
    hdr->pin  = 1;          // defense: keep compaction off it
    hdr->size = static_cast<u32>(HEAP_BASE_SENTINEL_SIZE);
    // color stays White; sentinel is never marked.
}
```

### Phase 4 — Materialize heap-base page as a mixed block

#### 4a. `populateFromBlock(cls)` (`OldGenSpace.cpp:659`)

When the page popped from `unassigned_blocks_` is the heap-base page:
- Do **not** slice into uniform `cellSize` cells (see "Critical correctness
  issue 1").
- Instead, materialize as `size_class = NUM_SIZE_CLASSES` (mixed).
- Install the sentinel at `page_start`.
- Push the span `[page_start + 8, page_end)` via `pushSpanOnFreeLists`
  using the new mixed `BlockInfo` so the recursive splitter packs cells onto
  appropriate classes.
- Return `true`. The original caller wanted `free_lists_[cls]` populated;
  whether it is depends on whether `freeListClassFor` routes any of the
  span to `cls`. If not, the caller will fall through to
  `tryAllocateBySplittingLarger` or `allocateFromBagPage` next, exactly as
  it does today when a populated page yields no cells of the requested class.

The cleanest implementation is to factor the heap-base detour into a small
helper called from both `populateFromBlock` and `allocateFromBagPage`:
```cpp
size_t OldGenSpace::materializeMixedBagPage(char* page_start, char* page_end);
// Returns the new blocks_ index. Caller may then carve from free_lists_.
```

#### 4b. `allocateFromBagPage(requested_size)` (`OldGenSpace.cpp:589`)

If the popped page is the heap-base page:
- Materialize the `BlockInfo` with `size_class = NUM_SIZE_CLASSES` (already
  the case today — good).
- Install the sentinel at `page_start`.
- Initialize the "whole page" Tag_Free cell at `page_start + 8` with size
  `page_size - 8`, not at `page_start` with size `page_size`.
- The subsequent `requested_size`-from-front carve and remainder push
  proceed unchanged, but operate on the post-sentinel span.

`BlockInfo.start` stays at `page_start` (so `totalBytes()` is the full page
size). `BlockInfo.end_of_objects` stays at `page_end`. Sweep can walk
`[page_start, page_end)` and will encounter the sentinel as a Tag_Free cell
of size 8 (mixed block uses `getObjectSize` for stride; correct).

### Phase 5 — Defend sweep, compaction, and reuse paths

#### 5a. Sweep coalescing must not destroy the sentinel

**Critical correctness issue 2 below** identifies this: when the heap-base
block has no live cells upstream of the sentinel, lazy sweep's coalescing
run will start at `block.start = heap_base + 0`, accumulate the 8-byte
sentinel into the run, and `pushSpanOnFreeLists` will write a normal
`FreeCell` header at offset 0 — handing out `heap_base + 0` to the next
allocation.

Fix in `OldGenSpace::lazySweep` (`OldGenSpace.cpp:1659`-ish): when entering
a fresh block (`sweep_cursor_ == nullptr`-branch), if
`block.start == allocator_->getHeapBase()`:
- Re-install the sentinel at `block.start` (in case anything wrote over it).
- Set `sweep_cursor_ = block.start + HEAP_BASE_SENTINEL_SIZE` so the walk
  begins at offset 8.
- Optionally attribute the 8 bytes to `meta.live_bytes` so block-utilization
  shrink decisions don't consider the page wholly dead.

This also keeps `flushRun` from ever including offset 0 in a span pushed to
free lists.

#### 5b. Block release: never release the heap-base block

`releaseBlockToAllocator` (`OldGenSpace.cpp:2129`) calls
`Allocator::releaseOldGenBlock(blk.start, totalBytes())`. If `blk.start ==
heap_base`, the released page goes back into `Allocator::old_gen_free_blocks_`
and a later `acquireOldGenBlock` could hand it out fresh — at which point
the next caller (e.g. `allocateLargeBlock`, `populateFromBlock`,
`allocateFromBagPage`) would need to re-install the sentinel.

Choose **option A: never release the heap-base block**. At entry of
`releaseBlockToAllocator`:
```cpp
if (allocator_ != nullptr &&
    blocks_[block_index].start == allocator_->getHeapBase()) {
    return;  // heap-base block is permanently committed
}
```
And mirror in `releaseUnassignedBlockToAllocator`:
```cpp
if (allocator_ != nullptr &&
    unassigned_blocks_[unassigned_index].first == allocator_->getHeapBase()) {
    return;
}
```

Cost: 128 KiB of address space stays committed forever. Benefit: no
re-acquisition path can ever expose `heap_base + 0`.

#### 5c. `allocateFromEmptyRegularBlocks` must skip the heap-base page

`OldGenSpace.cpp:793` repurposes a fully-empty regular page as a large
block for an allocation `>= alloc_buffer_size`. If the heap-base page is
empty, this would flip its `is_large = true` and place the large object
header at `heap_base + 0`, which would then trip the `initObjectHeader`
defense assert.

Add:
```cpp
if (allocator_ != nullptr &&
    blocks_[i].start == allocator_->getHeapBase()) continue;
```
inside the loop.

#### 5d. Compaction — no special handling required

`selectEvacuationSet` evacuates only objects with mark bits set;
`markOneObject` explicitly skips `Tag_Free` cells, so compaction never
touches the sentinel regardless of `pin`. `pin = 1` on the sentinel is
purely defensive; **no change to `selectEvacuationSet` is required for
correctness**. Skip this step.

#### 5e. `acquireOldGenBlock` defensive filter (page-sized requests only)

The release path in **5b** already prevents the heap-base block from ever
entering `old_gen_free_blocks_`, but we add a narrow filter in
`Allocator::acquireOldGenBlock` (`Allocator.cpp:441`) as a regression
guard. The filter must **only gate the page-sized request path**, not
arbitrary large-block requests (which legitimately use non-page-multiple
extents).

When the requested size equals `config_.alloc_buffer_size` (BBoP page
request), skip first-fit candidates whose size is not a multiple of 4096
or whose start equals `heap_base`:
```cpp
const bool page_request = (size == config_.alloc_buffer_size);
for (auto it = old_gen_free_blocks_.begin();
     it != old_gen_free_blocks_.end(); ++it) {
    if (page_request) {
        if (it->first == heap_base) continue;     // 5b regression guard
        if (it->second % 4096 != 0)  continue;    // misaligned size guard
    }
    if (it->second >= size) { /* take it */ }
}
```
For non-page-sized large blocks the existing first-fit logic is unchanged.

#### 5f. Page-aligned-accounting asserts (debug)

Add debug-build asserts that catch any future drift in page accounting:
- In `Allocator::acquireOldGenBlock` and `releaseOldGenBlock`, when
  `size == config_.alloc_buffer_size`, assert `size % 4096 == 0` (trivially
  true today; future-proofing if `alloc_buffer_size` ever changes) and
  assert `old_gen_committed % 4096 == 0` after the increment / decrement.
- In `OldGenSpace::releaseBlockToAllocator`, when the released block is
  not `is_large`, assert `blk.totalBytes() == config_->alloc_buffer_size`.

These run only under `assert` (debug builds) and cost nothing in release.

### Phase 6 — Tests

1. **Initialization invariant**: after `OldGenSpace::initialize`, every
   entry in `unassigned_blocks_` has `second - first == alloc_buffer_size`.
   Use `OldGenSpaceTestAccess::getUnassignedBlocks`.
2. **LIFO drain order**: drain the bag by repeated allocations until
   `unassigned_blocks_` is empty; assert that the *last* `BlockInfo`
   materialized has `start == heap_base`. This documents the
   "heap-base page is consumed last" property the design relies on.
3. **Sentinel is installed on first use**: keep allocating until the
   heap-base page is materialized, then assert
   `*reinterpret_cast<Header*>(heap_base)` has `tag == Tag_Free`,
   `size == HEAP_BASE_SENTINEL_SIZE`, `pin == 1`.
4. **No allocation lands at `heap_base + 0`**: stress test that allocates
   until at least the first page is fully consumed; assert no returned
   pointer equals `heap_base`.
5. **Page-aligned release accounting**: configure a small heap, force a
   block release path (e.g., reclaim-all-dead), assert
   `old_gen_committed % config.alloc_buffer_size == 0` after the release.
6. **Heap-base block is never released**: drive a major GC where the
   heap-base block becomes fully dead; assert it remains in `blocks_`
   afterward (release should be skipped per 5b).
7. **Mid-cycle materialization**: simulate `gc_phase_ == Sweeping` and
   force the heap-base page to materialize; assert the resulting
   `BufferMetadata` has `fully_swept = true` and that the next
   `lazySweep` slice does not enter the block.

## Files / Functions Audit Checklist

Before shipping, verify each touchpoint behaves under the new sentinel:
- [ ] `OldGenSpace::initialize` — page-0 truncation removed.
- [ ] `populateFromBlock` — heap-base detour to mixed-block materialization.
- [ ] `allocateFromBagPage` — sentinel install, post-sentinel cell wrap.
- [ ] `lazySweep` — start cursor at +8 for heap-base block; reinstall
      sentinel; never include offset 0 in a coalesced run.
- [ ] `releaseBlockToAllocator` — early-return for heap-base block.
- [ ] `releaseUnassignedBlockToAllocator` — early-return for heap-base extent.
- [ ] `allocateFromEmptyRegularBlocks` — skip heap-base block.
- [ ] `Allocator::acquireOldGenBlock` — page-sized-request filter (heap-base
      address + non-page-multiple sizes).
- [ ] `Allocator::acquireOldGenBlock` / `releaseOldGenBlock` — debug
      asserts on page-multiple size and `old_gen_committed` alignment.
- [ ] `markChildren` / `markOneObject` — already skip `Tag_Free`; no change
      needed (compaction inherits the same skip via mark bits, so
      `selectEvacuationSet` needs no change either).

## Critical Correctness Issues with the Submitted Design

The submitted design under-specifies three points that, if implemented
literally, would regress correctness:

### 1. Uniform-class `populateFromBlock` would break sweep walks

The submitted patch slices `[cell_start, page_end)` into uniform
`classToSize(cls)` cells starting at `page_start + 8`, but keeps
`BlockInfo.start = page_start` and `BlockInfo.size_class = cls`. Sweep's
`walkStepFor` for a uniform block returns `classToSize(cls)`, ignoring
`hdr->size`. So sweep walking from `block.start = page_start = heap_base + 0`
with step `classToSize(cls)` lands on offsets `0, cellSize, 2·cellSize, …`
— missing every actual cell at offsets `8, 8+cellSize, 8+2·cellSize, …`.
Sweep then reinterprets mid-cell bytes as `Header`s and corrupts the heap.

**Resolution**: materialize the heap-base page as a mixed block
(`size_class = NUM_SIZE_CLASSES`) and use `pushSpanOnFreeLists` to seed
free lists. Mixed blocks use `getObjectSize` for stride, and the 8-byte
sentinel is walked correctly.

### 2. Sweep coalescing destroys the sentinel

A `Tag_Free` cell at `block.start = heap_base` has no upstream live cell
to flush a coalescing run. Sweep accumulates the sentinel into a run that
is eventually pushed via `pushSpanOnFreeLists`, which writes a `FreeCell`
header at `span_start = heap_base + 0`. The next allocation that pops
that free-list cell hands `heap_base + 0` to the mutator — defeating the
whole point of the sentinel.

`hdr->pin = 1` does not help: lazy sweep does not test `pin` before
including a cell in a coalesced run.

**Resolution**: in `lazySweep`, special-case the heap-base block by
starting `sweep_cursor_` at `block.start + 8` and reinstalling the
sentinel each cycle (5a above).

### 3. Block release re-exposes `heap_base + 0`

If the heap-base block becomes fully dead and is released, the allocator's
free-block pool now contains an extent based at `heap_base + 0`. The next
`acquireOldGenBlock` (e.g. for a large block via `allocateLargeBlock`)
could reuse that extent, and `initObjectHeader` would write a real object
header at offset 0 → defense assert fires.

**Resolution**: never release the heap-base block (5b), and add a
defensive filter in `acquireOldGenBlock` (5e).

## Resolved Decisions

The following questions were raised during plan review and resolved
before implementation:

1. **128 KiB permanently pinned (option A)** — **accepted**. Old-gen caps
   are multi-GiB; one permanently reserved page is negligible and avoids
   the every-acquirer reinstall complexity of option B.
2. **`unassigned_blocks_` LIFO order** — confirmed: `initialize` pushes
   pages low-to-high, the bag is consumed via `pop_back`, so the
   heap-base page is materialized **last**. The sentinel rarely needs to
   exist in practice; codify this with the LIFO-drain test (Phase 6 test 2).
3. **Compaction and `Tag_Free`** — confirmed: liveness is driven by
   per-block mark bitmaps, `markOneObject` skips `Tag_Free` cells, and
   compaction evacuates only marked objects. The sentinel is never
   evacuated regardless of `pin`. **5d removed from the plan**;
   `pin = 1` retained as cheap defense only.
4. **Mid-cycle materialization** — confirmed safe: blocks created while
   `gc_phase_ == Sweeping` are added with `fully_swept = true`,
   `live_bytes = 0`, `garbage_bytes = 0`, so lazy sweep skips them in
   the current cycle. Installing the sentinel before any allocation in
   the heap-base block (which both materialization paths now do) is
   compatible with this.
5. **Filter vs. assert in `acquireOldGenBlock`** — keep both, narrowed:
   - **Filter** is gated to **page-sized requests** only (size ==
     `alloc_buffer_size`). Skips candidates whose start equals
     `heap_base` or whose size is not a page multiple. Non-page-sized
     large blocks pass through unchanged.
   - **Asserts** added in `acquireOldGenBlock`/`releaseOldGenBlock` for
     page-sized paths to catch any future regression in
     `old_gen_committed` alignment.

## Remaining Open Questions

None blocking. The existing `initObjectHeaderWithSize` assert
(`OldGenSpace.cpp:230-235`) is kept as-is: after this fix it should
never fire; if it ever does, that flags a regression in the sentinel
discipline.

## Non-Goals

- This plan does **not** change `Allocator::releaseOldGenBlock`'s
  page-rounding policy. With BBoP page extents always equal to
  `alloc_buffer_size` after this fix, releases are already exact page
  multiples; no rounding-up logic is needed there.
- This plan does not introduce a new `Tag` value. The sentinel reuses
  `Tag_Free` and relies on `size < MIN_FREE_CELL_SIZE` to keep it off
  free lists.
