# Per-Block Mark Bitmaps for OldGenSpace

## Goal

Move old-gen liveness out of `Header::color` and into per-block bitmaps (1 bit
per 8-byte slot). Headers stay as they are for now; sweep consults the bitmap
to decide live vs. dead. Nursery handling (`nursery_visited_`) and lazy sweep
remain as-is.

This aligns with the Handbook's "bitmap marking + block-level marking" pattern,
scoped per block and dropped onto the existing BBoP + segregated-fits + lazy
sweep + page-table infrastructure already on `OldGenSpace`.

---

## Preconditions (assumed in place; finish-wire if any are stubby)

The following helpers exist on `OldGenSpace` from prior work:

| Helper                           | Used by this plan                                  |
|----------------------------------|----------------------------------------------------|
| `page_to_block_index_` page table| O(1) `blockIndexFor`                               |
| `blockIndexFor(const void*)`     | mark, sweep, mid-cycle alloc                       |
| `resizePageIndexForRegion`       | (region growth — already wired)                    |
| `assignPageIndexForBlock`        | called wherever we push to `blocks_`               |
| `clearPageIndexForBlock`         | called from `releaseBlockToAllocator`              |
| `markOneObject`                  | the per-pop helper invoked from `incrementalMark`  |
| `resetBufferMetaForMark`         | `startMark` zero of live/garbage per block         |
| `finalizeMetaAfterMark`          | post-mark `garbage_bytes` + `frag_stats_` rollup   |
| `reclaimAllDeadBlocksFromMeta`   | post-mark fast-path release of `live_bytes==0`    |
| `buffer_meta_[i].live_bytes`     | populated during MARK (via `markOneObject`)        |

If any of these is still a stub, finish wiring it before bitmap work — do not
fall back to linear scans or color-based liveness.

---

## Step-by-step plan

### Step 1 — Add bitmap storage + helpers

**File:** `runtime/src/allocator/OldGenSpace.hpp`

1.1 Add `mark_bits_` to private section, parallel to `blocks_` /
`buffer_meta_`:

```cpp
std::vector<std::vector<uint8_t>> mark_bits_;       // regular blocks
std::vector<uint8_t>              large_block_mark_; // 0/1 per block; only meaningful when blocks_[i].is_large
```

(Keep `mark_bits_[i]` length == 0 for `is_large` blocks; the bool lives in
`large_block_mark_[i]`. See Step 2 / Q8.)

1.2 Add bitmap helpers (private, inline):

- `static constexpr size_t MARK_ALIGNMENT = 8;`
- `slotsForBlock(BlockInfo&)`, `bitmapBytesForBlock(BlockInfo&)`
- `markBitLocation(block_index, obj, &byte_index, &mask)`
- `isMarkedInBlock(block_index, obj) -> bool`
- `setMarkBitInBlock(block_index, obj) -> bool` (returns prior value)
- `testAndClearMarkBitInBlock(block_index, obj) -> bool`

For each, branch on `blocks_[block_index].is_large` and route to
`large_block_mark_[block_index]` instead.

1.3 Add `OldGenSpaceTestAccess` entries (mirroring existing `getBlocks` /
`getBufferMeta` style):

```cpp
static const std::vector<uint8_t>& getMarkBitsForBlock(const OldGenSpace& o,
                                                       size_t i) {
    return o.mark_bits_[i];
}
static bool isObjectMarked(const OldGenSpace& o, void* obj) {
    if (!o.contains(obj)) return false;
    size_t i = o.blockIndexFor(obj);
    if (i >= o.blocks_.size()) return false;
    return o.isMarkedInBlock(i, obj);
}
```

### Step 2 — Wire bitmap creation/destruction into block lifecycle

**File:** `runtime/src/allocator/OldGenSpace.cpp`

Every `blocks_.push_back(bi)` site must be paired with a corresponding bitmap
push. Sites:

- `populateFromBlock` (~L545) — uniform size-class page; `mark_bits_.emplace_back(bitmapBytesForBlock(blocks_.back()))`, `large_block_mark_.push_back(0)`.
- `allocateFromBagPage` (~L472) — mixed page; same.
- `allocateLargeBlock` (~L683) — `mark_bits_.emplace_back()` (empty), `large_block_mark_.push_back(0)`.

Block removal (swap-remove) — `releaseBlockToAllocator` (~L1754): mirror the
`blocks_` / `buffer_meta_` swap-remove on both `mark_bits_` and
`large_block_mark_`. Keep this paired with the existing
`clearPageIndexForBlock` / `assignPageIndexForBlock` work the page table
already does.

Reset / init:

- `OldGenSpace::reset` (~L143) — `mark_bits_.clear(); large_block_mark_.clear();`
- Default-constructed `OldGenSpace::OldGenSpace()` is fine.

Block re-purposing — defensive zero (Q3 confirmed):

- In `allocateFromFreeLargeBlocks(idx)` and `allocateFromEmptyRegularBlocks(idx)`,
  after re-establishing `BlockInfo` / `BufferMetadata`:
  ```cpp
  std::fill(mark_bits_[idx].begin(), mark_bits_[idx].end(), 0);
  large_block_mark_[idx] = 0;
  ```
  Cost is O(blockBytes / 64); these paths are rare. Defends against
  ordering bugs where mark/sweep didn't fully clear the bitmap before reuse.

Invariant: `mark_bits_.size() == large_block_mark_.size() == blocks_.size()`
at every observation point.

### Step 3 — `startMark` and `resetBufferMetaForMark`

**File:** `OldGenSpace.cpp`, `startMark` (L706).

- Continue calling `resetBufferMetaForMark` (already in place) so per-block
  `live_bytes` / `garbage_bytes` are zeroed before incremental mark begins.
- **Remove** the `ECO_GC_RESET_BLACK_AT_MARK` defense at L727–L754.
  Carry-over Black via nursery memcpy can no longer mis-classify a cell as
  reachable: with bitmaps, `Header::color` is no longer the liveness source.
  Update or delete any assertions that referenced color as authoritative.
  (See `project_stage7_carryover_black_apr26` — defense becomes moot.)
- `mark_stack` / `nursery_visited_` clear stays as-is.

Bitmap is **not** bulk-zeroed at `startMark`. We rely on the invariant that
`testAndClearMarkBitInBlock` left it zero at the end of the previous sweep.
A `#if ECO_GC_DEBUG` verifier pass that asserts all bits are zero before
mark begins is acceptable; do not pay this cost in release builds.

### Step 4 — `pushMarkRoot` sets bitmap bits for old gen

**File:** `OldGenSpace.cpp`, `pushMarkRoot` (L960).

```cpp
// Nursery branch unchanged.
if (allocator_ref_->isInNursery(obj)) {
    if (nursery_visited_.insert(obj).second) mark_stack.push_back(obj);
    return;
}

// Old-gen path: bitmap discovery via page table.
if (!contains(obj)) return;
size_t block_index = blockIndexFor(obj);
if (block_index >= blocks_.size()) return;

if (isMarkedInBlock(block_index, obj)) return;   // already grey/black
setMarkBitInBlock(block_index, obj);             // grey
mark_stack.push_back(obj);
```

`markHPointer` already delegates here; no edit needed.

### Step 5 — `incrementalMark` calls `markOneObject` (no header color writes)

**File:** `OldGenSpace.cpp`, `incrementalMark` (L803–L854).

Replace the inline grey/black/color logic with:

```cpp
void* obj = mark_stack.back();
mark_stack.pop_back();
if (markOneObject(obj)) units_done++;
```

`markOneObject` (existing helper) takes ownership of:
- skipping `Tag_Free` and `Tag_Forward` (Q10 — explicit `Tag_Forward` skip);
- nursery vs old-gen dispatch;
- live_bytes attribution (`buffer_meta_[block_index].live_bytes += getObjectSize(obj)`)
  for old-gen objects only;
- calling `markChildren(obj)`.

Header color writes (Grey/Black) are removed entirely from the old-gen path.
The bit set by `pushMarkRoot` IS the discovery record; pop+`markChildren`
IS the blackening. Bit stays set until sweep clears it.

`markOneObject` body (sketch — adapt to existing helper signature):

```cpp
bool OldGenSpace::markOneObject(void* obj) {
    if (!obj) return false;
    Header* hdr = getHeader(obj);
    if (hdr->tag == Tag_Free || hdr->tag == Tag_Forward) return false;

    if (allocator_ref_ && allocator_ref_->isInNursery(obj)) {
        markChildren(obj);
        return true;
    }

    if (!contains(obj)) return false;
    size_t block_index = blockIndexFor(obj);
    if (block_index >= blocks_.size()) return false;

    // Bit was set in pushMarkRoot. Attribute liveness now.
    buffer_meta_[block_index].live_bytes += getObjectSize(obj);
    markChildren(obj);
    return true;
}
```

### Step 6 — `finishMarkAndSweep`: `finalizeMetaAfterMark` + all-dead reclaim

**File:** `OldGenSpace.cpp`, `finishMarkAndSweep` (L987 / L1031).

After the incremental mark loop drains:

1. `finalizeMetaAfterMark` (existing) — folds per-block `live_bytes` into
   `garbage_bytes` (= `block.totalBytes() - live_bytes - existing_free`) and
   updates `frag_stats_`.
2. `reclaimAllDeadBlocksFromMeta` (existing) — releases blocks with
   `live_bytes == 0` via `releaseBlockToAllocator` BEFORE sweep walks them.
   Since their bitmaps are all-zero (no marks set during this cycle), the
   swap-remove drops the bitmap automatically; no extra bookkeeping needed.
3. Then enter sweep on the remaining blocks.

This is the all-dead fast path the design calls for, which the existing
infra already supports.

### Step 7 — Switch sweep to bitmap liveness (preserves coalescing)

**Files:** `OldGenSpace.cpp` `sweep()` (L1191) AND `lazySweep()` (L1323).

Replace `hdr->color == Black` with `testAndClearMarkBitInBlock(buf_idx, ptr)`.

**Coalescing semantics — design's §4.1 has a bug, do NOT skip Tag_Free.**
Current sweep coalesces *any* non-live entry — including pre-existing
`Tag_Free` cells from prior cycles — into the run. Free lists are cleared
before sweep, so leftover Tag_Free is just "dead bytes available to merge".
The design's snippet `if (hdr->tag == Tag_Free) { scan += obj_size; continue; }`
would break coalescing and produce fragmented free lists / parse errors.

Correct bitmap-based loop body:

```cpp
bool live = testAndClearMarkBitInBlock(buf_idx, ptr);
if (live) {
    flushRun();
    // meta.live_bytes already populated during mark; do not double-count.
    // optional debug: hdr->color = White (gated #if ECO_GC_DEBUG)
} else {
    if (run_start == nullptr) { run_start = ptr; run_bytes = 0; }
    run_bytes += step;
}
ptr += step;
```

Apply the same change to `lazySweep`'s walk and to the `is_large`
single-object decision in both `sweep` and `lazySweep` (route through
`testAndClearMarkBitInBlock`, which forwards to `large_block_mark_[i]`).

Live-bytes accounting note: since `markOneObject` populates
`buffer_meta_[i].live_bytes`, **sweep no longer needs to accumulate it**.
Drop the `meta.live_bytes += step` writes from both sweep paths (or convert
to a debug-only cross-check that `Σ live cells == meta.live_bytes`).
`garbage_bytes` accumulation in sweep stays, since coalescing produces
the actual reclaimed-byte total.

Post-sweep invariant: every `mark_bits_[i]` is all-zero and every
`large_block_mark_[i] == 0`.

### Step 8 — Mid-cycle allocation interaction

`initObjectHeader` (L181) currently sets `hdr->color = Black` when
`marking_active || gc_phase_ != Idle` to prevent the in-progress sweep from
reclaiming a fresh allocation.

Bitmap equivalent — when GC is active, also:

```cpp
size_t block_index = blockIndexFor(obj);
if (block_index < blocks_.size()) {
    setMarkBitInBlock(block_index, obj);
}
```

Block has been pushed to `blocks_` (and its page-table entries assigned)
before the first `initObjectHeader` call in that block, so the lookup
succeeds in all three push-paths.

The `hdr->color = Black` write itself can be dropped (color is no longer
load-bearing) — leave it as a no-op or `#if ECO_GC_DEBUG` only.

Lazy-sweep race: if `gc_phase_ == Sweeping && buf_idx == sweep_buffer_index_
&& obj < sweep_cursor_`, the sweep cursor has already passed this address
and would have cleared any prior bit. Setting it now keeps the new object
live for the *remainder* of the sweep — but the object is past the cursor,
so no further sweep action will look at it this cycle. The bit will be
cleared by the next cycle's `testAndClear`. Correct.

### Step 9 — Compaction audit

**Files:** `evacuateSlice` (L1978), `fixReferencesSlice` (L2133),
`fixPointersInObject` (L2180), `selectEvacuationSet` (L1907).

Per Q6: design intent is that compaction's live predicate is **evacuation-set
membership + Tag_Forward**, not `hdr->color`. Audit these four functions and
confirm:
- `selectEvacuationSet` chooses blocks via `buffer_meta_.live_bytes` and
  fragmentation stats — no color dependence.
- `evacuateSlice` walks evacuation-set blocks and copies non-Tag_Free
  objects; should not rely on color to decide "this object is live".
- `fixPointersInObject` / `fixHPointer` walk via tag/pointer fields, not
  color.

If any path uses color as a liveness gate, replace with either
`isMarkedInBlock` (if mid-mark) or "tag is not Tag_Free" (post-sweep).
If audit finds none, no edit needed.

### Step 10 — Header.color cleanup

After Steps 4–9, `Header::color` is no longer load-bearing for old-gen
correctness. In this plan:

- **Keep the field** in the bitfield layout (no struct re-layout this
  change).
- Remove `ECO_GC_RESET_BLACK_AT_MARK` defense (Step 3).
- Stop writing color from mark / blacken paths.
- Allow optional `hdr->color = White` writes in sweep gated under
  `#if ECO_GC_DEBUG` for asserts that still inspect color.
- Update any assertions that still treat color as authoritative to call
  `isMarkedInBlock` or check `Tag_Free` instead.

Removing the `color` field entirely is a separate follow-up plan.

### Step 11 — Tests

In `runtime/test/` (OldGen test file):

- **Single-block correctness**: allocate mixed objects in one size-class
  block, mark a known subset, assert `isObjectMarked` reflects exactly
  that subset post-mark; run sweep; assert `getMarkBitsForBlock` is
  all-zero post-sweep and unmarked spans are now `Tag_Free`.
- **Lifecycle invariant**: assert
  `mark_bits_.size() == large_block_mark_.size() == blocks_.size()` after
  every allocation pattern, including paths through `releaseBlockToAllocator`,
  `allocateFromFreeLargeBlocks`, `allocateFromEmptyRegularBlocks`.
- **Re-purpose defensive zero**: stash a non-zero bitmap on a block,
  re-purpose via `allocateFromEmptyRegularBlocks`, assert bitmap is now
  zero before any allocation occurs in the new block.
- **Mid-cycle allocation**: drive `startMark` via test access, allocate
  before `finishMarkAndSweep`, assert the new object survives sweep AND
  `isObjectMarked` returns true on it pre-sweep.
- **Cross-block reference**: heap with refs spanning two blocks; assert
  marking sets bits in both bitmaps via `blockIndexFor`.
- **`is_large` single-bit path**: allocate a large object; assert
  `mark_bits_[i].size() == 0` and `large_block_mark_[i]` toggles correctly
  through mark + sweep.
- **`Tag_Forward` skip**: install a forwarding stub by hand; assert
  `markOneObject` returns false and does not call `markChildren`.
- **All-dead reclaim**: fill several pages, drop all roots, run major GC;
  assert `reclaimAllDeadBlocksFromMeta` releases the expected pages and
  `mark_bits_.size()` matches `blocks_.size()` post-reclaim.
- **Stage 7 regression**: re-run with `ECO_GC_PHASE_PROFILE=1`; expected
  live-set / heap-shape unchanged from header-color baseline.

E2E:
```
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```
Stress with bitmap debug verifier:
```
ECO_OLDGEN_DEBUG=1 ECO_GC_DEBUG=1 cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

---

## Files touched

- `runtime/src/allocator/OldGenSpace.hpp` — add `mark_bits_`,
  `large_block_mark_`, helpers, test access entries.
- `runtime/src/allocator/OldGenSpace.cpp` — push/release pairing,
  `pushMarkRoot`, `incrementalMark` → `markOneObject`, `markOneObject`
  body, `sweep`, `lazySweep`, `initObjectHeader`, `startMark` (remove
  Black-reset defense), possibly compaction (after audit).
- `runtime/test/...` — bitmap unit tests (file path TBD).

No invariants doc change anticipated; `REP_HEAP_*` rules concern field
layout, not GC mark mechanism.

---

## Resolved decisions (from review)

- **Q1**: O(1) page table — use existing `page_to_block_index_` /
  `blockIndexFor`; no linear scans.
- **Q2**: Treat infra as in place; finish-wire any stub helpers, do not
  downscope.
- **Q3**: Defensive `std::fill` on bitmap re-purpose paths
  (`allocateFromFreeLargeBlocks`, `allocateFromEmptyRegularBlocks`).
- **Q4**: Keep `markOneObject` as a real helper.
- **Q5**: Remove `ECO_GC_RESET_BLACK_AT_MARK` defense.
- **Q6**: Compaction expected to use evacuation-set + `Tag_Forward`, not
  color; audit and confirm in Step 9.
- **Q7**: `vector<vector<uint8_t>>` per block is fine at 128 KiB
  granularity (~32k blocks at 4 GB → ~64 MB bitmap, ~768 KB vector
  headers). No pooling. No bulk-zero between cycles; rely on `testAndClear`
  invariant. Optional `#if ECO_GC_DEBUG` "all bits zero" verifier.
- **Q8**: `is_large` blocks use a separate `large_block_mark_[i]` byte;
  their `mark_bits_[i]` stays empty.
- **Q9**: Add `getMarkBitsForBlock` and `isObjectMarked` to
  `OldGenSpaceTestAccess`.
- **Q10**: `markOneObject` skips both `Tag_Free` and `Tag_Forward`;
  compaction follows forwarding pointers in its own phase.

---

## Outstanding (small)

- Step 9 still needs the actual read of `evacuateSlice` /
  `fixReferencesSlice` to confirm "no color liveness gate". If the audit
  surfaces a gate, this step grows. Will read before implementing.
