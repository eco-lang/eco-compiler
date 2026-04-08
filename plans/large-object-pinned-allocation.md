# Large-Object Allocation via Pinned Old-Gen Path

## Motivation

`ThreadLocalHeap::allocate` currently routes every non-permanent allocation
through the nursery. The nursery's per-block bump space is `alloc_buffer_size`
(default 128 KiB), so any single object larger than that aborts with
`assert(false && "Failed to allocate to nursery, it is full.")`
(`runtime/src/allocator/ThreadLocalHeap.cpp:81`).

The new failing tests `testLargeByteBufferSurvivesMajorGCWhenRooted`,
`testLargeByteBufferReclaimedWhenUnreachable`,
`testLargeElmArraySurvivesMajorGCWhenRooted`, and
`testLargeElmArrayReclaimedWhenUnreachable` in
`test/allocator/AllocatorTest.cpp` exercise this gap by allocating
ByteBuffer/ElmArray objects > 256 KiB.

This plan introduces a large-object path that:

1. Bypasses the nursery for sufficiently large allocations.
2. Allocates them directly into the existing old generation, in dedicated
   blocks sized to fit the object.
3. Marks them with `Header.pin = 1` so the old-gen incremental compactor
   leaves them in place rather than evacuating them.

Mark/sweep handles them like any other old-gen object, so reclamation when
unreachable comes "for free."

## Non-goals

- No new heap space (no separate "large object space").
- No changes to the nursery allocator.
- No changes to write barriers or generational invariants — large objects are
  born in old gen at age 0 and behave like any other promoted object.
- Pinning of `allocatePermanent` objects is orthogonal and out of scope.

## Step-by-step plan

### Step 1 — Add `large_object_threshold` to `HeapConfig`

**File:** `runtime/src/allocator/AllocatorCommon.hpp`

- Add a `size_t large_object_threshold` field to `struct HeapConfig`.
- Default value: `std::max<size_t>(8 * 1024, ALLOC_BUFFER_SIZE / 4)`.
  With the current `ALLOC_BUFFER_SIZE = 128 KiB` this resolves to **32 KiB**.
  Rationale: 8 KiB sends too much medium traffic straight to old gen; 64 KiB
  (½-block) still leaves expensive copies in the nursery; 32 KiB cuts off
  genuinely "large to copy" objects while still letting modest arrays/records
  benefit from generational behavior.
- Extend `HeapConfig::validate()` (or the inline checks at construction) to
  reject:
  - `large_object_threshold < sizeof(Header)`.
  - `large_object_threshold > max_heap_size / 2` (would never fit in old gen).
- The field is a config knob, so callers can override it; the formula above is
  only the default.

`Allocator` already stores a `HeapConfig` and forwards a `const HeapConfig*`
to `ThreadLocalHeap` and `OldGenSpace`, so no wiring change is required.

### Step 2 — Route large allocations to old gen in `ThreadLocalHeap::allocate`

**File:** `runtime/src/allocator/ThreadLocalHeap.cpp` (function at line 38).

Modifications:

1. Align `size` to 8 bytes up front (mirrors what nursery/oldgen already do
   internally so the threshold comparison is meaningful).
2. **Before** the existing `wouldExceedThreshold` check, branch:
   ```
   if (size >= config_->large_object_threshold) {
       return allocateLargePinned(size, tag);
   }
   ```
3. Implement a new private member function
   `void* ThreadLocalHeap::allocateLargePinned(size_t size, Tag tag)` that:
   - Calls `old_gen_.allocate(size)`.
   - On failure, runs `majorGC()` once and retries `old_gen_.allocate(size)`.
   - On second failure, asserts (matching the existing OOM policy).
   - Initializes the header by reusing the same tag-dispatched
     `hdr->size` computation as the nursery path (factor it out into a
     `static void initHeaderForTag(Header*, Tag, size_t bytes)` helper to
     avoid duplication between `allocate`, `allocatePermanent`, and the new
     path).
   - Sets `hdr->pin = 1` after the tag-dispatched init (so the pin survives
     the `memset` performed by `OldGenSpace::bumpAllocate` and friends).
   - Returns the object.
4. Leave the existing nursery allocation path unchanged for
   `size < large_object_threshold`.

Add the corresponding declaration in `ThreadLocalHeap.hpp`.

### Step 3 — Allow `OldGenSpace::allocate` to satisfy requests > `alloc_buffer_size`

**File:** `runtime/src/allocator/OldGenSpace.cpp`
(`allocate` at line 123, `bumpAllocate` at line 210).

Today `bumpAllocate` asserts
`size <= config_->alloc_buffer_size` (line 236) and always requests blocks of
exactly `config_->alloc_buffer_size` from `Allocator::acquireOldGenBlock`.

Change required:

1. In `OldGenSpace::allocate`, after the free-list/lazy-sweep paths (which
   only handle small size classes anyway), add a branch:
   ```
   if (size > config_->alloc_buffer_size) {
       return allocateLargeBlock(size);
   }
   return bumpAllocate(size);
   ```
2. Implement a new private helper `void* OldGenSpace::allocateLargeBlock(size_t size)`:
   - Call `allocator_->acquireOldGenBlock(size)` (the API already takes a
     `size` parameter and rounds it up to 8 bytes — see
     `runtime/src/allocator/Allocator.cpp:279`).
   - On failure, return `nullptr` so the caller's retry-with-`majorGC` path
     handles OOM.
   - Build a `BlockInfo` with `start = end - size = block_base`,
     `alloc_ptr = block_base + size` (the object fully consumes the block;
     no further allocations land in it).
   - Push it into `blocks_` and append a corresponding `BufferMetadata` entry
     with `live_bytes = size`, `garbage_bytes = 0`, `fully_swept = false`.
     **Do not** modify `current_block_index_` — large blocks must not become
     the bump-allocation target. The invariant we preserve is:
     "`blocks_[current_block_index_]` is the block used by `bumpAllocate`,
     but need not be the last element of `blocks_`." A quick grep over
     `current_block_index_` in `OldGenSpace.cpp` is still required to
     confirm no code assumes `current_block_index_ == blocks_.size() - 1`,
     but the strategy above is the right one regardless.
   - Update `region_base_` / `region_end_` so `contains()` still answers
     correctly. Note these fields assume a single contiguous range; large
     blocks are carved from the same old-gen reservation by
     `acquireOldGenBlock`, so the existing min/max maintenance still works as
     long as we update both bounds.
   - `allocated_bytes += size`.
   - Initialize the header (zero-fill, set color according to current GC
     phase as `bumpAllocate` does at lines 222–228). The caller in
     `ThreadLocalHeap::allocateLargePinned` then overwrites `tag`, `size`,
     and `pin`.
   - Return `block_base`.

### Step 4 — Make sweep tolerate "single-object" blocks

**File:** `runtime/src/allocator/OldGenSpace.cpp`
(`lazySweep` at line 608, full sweep around line 540).

The lazy sweeper walks `sweep_cursor_` from `block.start` to `block.alloc_ptr`
in `getObjectSize` strides (line 629). For a large-object block this loop
will execute exactly once and stop, so structurally it should already work.

Required changes:

1. Make large-object blocks participate in the same `buffer_meta_` /
   `frag_stats_` accounting as normal blocks. Their bytes count toward
   `allocated_bytes` and `frag_stats_.heap_bytes`, and their live/garbage
   bytes are tracked the same way in `buffer_meta_`. No separate "large
   object" stats fields for v1.
2. When sweeping a large-object block whose lone object is dead, the entire
   block must be released — **not** added to a free list. Free lists only
   cover sizes ≤ `MAX_SMALL_SIZE` (256 B); a ≥ 32 KiB cell would be wasted
   there.
3. Reuse the existing surplus-buffer return path. `OldGenSpace` already has
   `BUFFER_RETURN_THRESHOLD` and (per the API) a `freeEvacuatedBuffers()`
   pathway; we should plug large-object blocks into the same mechanism so
   they are returned to the OS once they go fully garbage and utilization
   drops below the target.
4. **If** inspection of `OldGenSpace.cpp` shows `BUFFER_RETURN_THRESHOLD` is
   currently inert (declared but unused), defer the actual "return to OS" path
   for v1 — accept that dead large blocks remain committed (this is captured
   in Risks) — but structure the code so plugging in the return path later
   is a one-line change. Specifically: keep large blocks in `buffer_meta_`
   with accurate live/garbage counts so a future sweep-finalize step can
   identify them.
5. If a large-object block contains a *live* object, leave it untouched.

### Step 5 — Make compaction skip pinned objects

**File:** `runtime/src/allocator/OldGenSpace.cpp`
(`evacuateSlice` at line 833, `installForwardingPointer` at line 930,
`getForwardingAddress` at line 946).

Two complementary changes:

1. **Block selection (`selectEvacuationSet`, around line 749):** never put a
   large-object block (or, equivalently, any block containing a pinned
   object) into the evacuation set. The simplest, most local change is: in
   the per-block scoring loop, skip blocks whose first/only object has
   `hdr->pin == 1`. A more general check — "block contains any pinned
   object" — is the right long-term answer but requires the sweeper to track
   it; for the initial implementation, the "starts with a pinned object" check
   is sufficient because the only pinned objects we create are large-object
   blocks containing exactly one object.
2. **Object-level guard inside `evacuateSlice`:** as a defensive belt-and-
   braces measure, when walking objects in a block selected for evacuation,
   if an object has `hdr->pin == 1`:
   - Call `installForwardingPointer(obj, obj)` so the fixup phase resolves
     references through `getForwardingAddress` to the same address.
   - Advance the cursor by `getObjectSize(obj)` without copying.
   - Do **not** count it toward the work budget.

The fixup phase (`fixHPointer`, line 1113) already calls
`getForwardingAddress`, so a self-forwarding install means no other code
needs to learn about pinning.

### Step 6 — Tests

The four large-object survival tests in
`test/allocator/AllocatorTest.cpp` will start passing as-is. In addition, add:

1. **Header inspection test** (new, in `AllocatorTest.cpp` or a new file): allocate a large
   ByteBuffer, assert `getHeader(obj)->pin == 1`, `alloc.isInOldGen(obj)`,
   `!alloc.isInNursery(obj)`.
2. **Large-object address stability under compaction**: allocate a large
   object, capture its raw address, allocate enough garbage in old gen to
   trigger compaction (`shouldCompact()`), run a major GC, assert the
   object's address is unchanged via `readBarrier`.
3. **Large-object reclamation**: allocate one large object unrooted alongside
   a rooted control, run major GC, assert that
   `OldGenSpace`'s committed/live bytes decreased by ≥ the large object's
   size (or that `acquireOldGenBlock`'s committed counter decreased,
   depending on which counter is observable from tests).
4. **Threshold boundary test**: allocate at exactly `large_object_threshold`
   and exactly `large_object_threshold - 8` bytes, verify the former lands in
   old gen with `pin = 1` and the latter in nursery with `pin = 0`.
5. **Stress test**: in a loop, allocate and drop large objects of varying
   sizes; run periodic major GCs; verify no crash and that committed bytes
   remain bounded.

### Step 7 — Update memories / docs

- Add a brief entry to `design_docs/invariants.csv` if a new HEAP_* invariant
  is appropriate (e.g. "HEAP_LARGE_OBJ_PINNED: any object allocated via the
  large-object path has Header.pin == 1 and lives in a dedicated old-gen
  block").
- Mention the new threshold + pinned-object semantics in
  `design_docs/theory/` (whichever file currently documents the heap layout).

## Resolved decisions

1. **Default threshold:** `large_object_threshold = max(8 KiB, ALLOC_BUFFER_SIZE / 4)`.
   With current defaults that's **32 KiB**. Exposed as a config knob.

2. **`current_block_index_` invariant:** preserved as
   "`blocks_[current_block_index_]` is the bump-allocation target, but need
   not be the last element of `blocks_`." Large-object blocks are appended
   to `blocks_` without touching `current_block_index_`. A grep audit is
   still part of Step 3, but the strategy does not depend on the audit's
   outcome.

3. **Whole-block release:** large-object blocks participate in the existing
   `buffer_meta_` / `frag_stats_` accounting and the existing surplus-buffer
   return mechanism (`BUFFER_RETURN_THRESHOLD` / `freeEvacuatedBuffers`).
   If that mechanism turns out to be inert today, defer the return-to-OS path
   for v1 but keep accounting accurate so plugging it in later is trivial.

4. **`region_base_` / `region_end_` contiguity:** confirmed. The allocator
   reserves a single contiguous virtual range and per-thread
   `acquireOldGenRegion` carves a contiguous slice; `acquireOldGenBlock`
   commits within that slice. Large blocks therefore only extend
   `region_end_` within an already-reserved contiguous range, and `contains()`
   continues to work.

5. **`allocatePermanent` pinning:** **not** changed in this plan. Compaction
   may legally move string literals; pinning would only be a perf
   optimization. Leave for a follow-up if profiling justifies it. The shared
   `initHeaderForTag` helper introduced in Step 2 makes it a one-line change
   later.

6. **GC stats for large blocks:** for v1, fold into existing old-gen counters
   (`allocated_bytes`, `frag_stats_.heap_bytes`, `buffer_meta_.live_bytes`,
   `buffer_meta_.garbage_bytes`). No new stats fields. Optional finer
   "large object bytes allocated/live" fields are a follow-up.

7. **`Header.pin` field width:** single bit (`Heap.hpp:90`). Sufficient. No
   change.

8. **Test threshold interaction:** the existing failing tests use
   `LARGE_BYTEBUFFER_BYTES = 320 KiB` and `LARGE_ARRAY_LENGTH = 33 K * 8 B
   = 264 KiB`. Both comfortably exceed the chosen 32 KiB threshold, so no
   test changes are needed.

## Risks

- **Old-gen fragmentation / RSS growth.** Each large object owns its own
  block. If the application churns large objects and the
  `BUFFER_RETURN_THRESHOLD` return-to-OS path is deferred (decision 3), old
  gen will accumulate committed-but-unused large blocks, increasing RSS.
  Acceptable for v1 as long as large objects are relatively rare for target
  workloads; must be documented as a known limitation until the return path
  is wired up.
- **Compactor invariants.** The compactor was written assuming all blocks
  are `alloc_buffer_size`-sized and contain many objects. The Step-5 changes
  must not break the existing assumption that blocks have uniform layout.
  Risk mitigated by the "skip block at selection time" approach rather than
  trying to compact within a large block.
- **Header re-init ordering.** Both `OldGenSpace::bumpAllocate` and the
  large-object path `memset` the header to zero, then set fields. The pin
  bit must be set *after* the memset and *after* any subsequent field
  initialization that touches the same word. Mitigated by setting pin last
  in `allocateLargePinned`.
