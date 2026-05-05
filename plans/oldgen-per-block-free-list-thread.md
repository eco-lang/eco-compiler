# Per-Block Free-Cell Thread in OldGenSpace

## Goal

Make `OldGenSpace::removeFreeCellsForBlock` O(cells in this block) instead of
O(total free cells × NUM_SIZE_CLASSES). On the LOT=1K stress workload this
function (inlined into `releaseBlockToAllocator`) is **87 % of all CPU time**
and **99 %** of those samples are on a single instruction:

```
f0ed0f:  mov  0x8(%rcx), %rcx    ; next = curr->next
```

That's the cache-missing pointer chase that walks every free cell of every
size class to find the ones that fall inside one block. With ~3.27 M free
cells across 60 size classes, releasing a single block scans the whole pool.
The per-block coalescing pre-pass in `maybeShrinkCapacity`
(`OldGenSpace.cpp:2664-2696`) helps on bulk release but cannot help the
per-block call inside `releaseBlockToAllocator` — that one still re-walks
every list when invoked from the partial-release / swap-remove paths.

## Design summary

Add a second thread through every free cell, rooted at the cell's owning
`BlockInfo`. Each cell continues to live on its size-class free list (so the
allocator fast paths are unchanged), and additionally lives on a doubly-
linked list rooted at `BlockInfo::free_cells_in_block`. Bulk removal walks
only that block's thread.

Two threads, intrusive (links live inside the cell):

```
BlockInfo i:          free_cells_in_block ─┐
                                            v
free_lists_[cls a]: ─> A ──> B ──> C ──> nullptr   (size-class thread)
                            |          |
                            v          v   ...
                         (size-class B is on)  (D in block i, but on cls c)
                            ^                          ^
BlockInfo i:                └──── per-block thread ────┘
```

Removing block i: walk `BlockInfo[i].free_cells_in_block`, unlink each cell
from its size-class list using a back-pointer, drop. Touches exactly the
cells that live in block i. No global walk.

## Cell layout — tiered (16 B for class 1, 24 B for classes ≥ 2)

Today (`OldGenSpace.hpp:168-171`):
```cpp
struct FreeCell {
    Header     header;     // 8 B
    FreeCell*  next;       // 8 B  size-class link
};                         // sizeof = 16  =  MIN_FREE_CELL_SIZE
```

The new layout is **tiered by size class** so we can keep small-cell recycle
(class 1, 16 B) AND get O(1) bulk-release unlink (classes 2 and up). Two
flavours; both reside at the same starting address; the size class
determines which view applies.

### Tier S (16 B, class 1 only)

```cpp
struct FreeCellSmall {        // class 1: cellSize == 16 B
    Header    header;         // 8 B
    FreeCell* next_in_class;  // 8 B   singly linked size-class list
};                            // sizeof = 16
```

Identical to today's layout. Class 1 cells do **not** participate in the
per-block thread.

### Tier M (24 B, classes ≥ 2)

```cpp
struct FreeCellMid {          // class 2 (24 B) and up
    Header    header;         // 8 B
    FreeCell* next_in_class;  // 8 B   singly linked size-class list
    CellHandle prev_in_class; // 4 B   compact back-link, see below
    uint16_t  next_in_block;  // 2 B   offset/8 within block, sentinel = 0xFFFF
    uint16_t  prev_in_block;  // 2 B   offset/8 within block, sentinel = 0xFFFF (head)
};                            // sizeof = 24
```

Class 2 (24 B) fits this layout exactly; class 3+ have ≥ 8 B of slack
(unused — slack is fine, we don't waste any allocation, just write fewer
bytes into a larger slot).

#### `CellHandle` — 4-byte cell reference

```cpp
struct CellHandle {
    uint16_t block_index;     // index into blocks_; 0xFFFF == "head, see &free_lists_[cls]"
    uint16_t cell_offset_8;   // (cell_addr - block.start) / 8
};                            // sizeof = 4
```

Resolves to a `FreeCell*` via:
```cpp
FreeCell* CellHandle::resolve(const std::vector<BlockInfo>& blocks) const {
    if (block_index == HEAD_SENTINEL) return nullptr;   // caller looks at &free_lists_[cls]
    return reinterpret_cast<FreeCell*>(blocks[block_index].start +
                                      static_cast<size_t>(cell_offset_8) * 8);
}
```

This gives **O(1) unlink from the size-class list** without paying for an
8-byte back-pointer. Combined with the 16-bit per-block offsets, we get
O(1) unlink from both lists per cell during bulk release.

#### Bounds and invariants for `CellHandle`

- `block_index` in `[0, 0xFFFE]`: max **65,535 blocks** (0xFFFF reserved
  for the global-head sentinel).
- `cell_offset_8` in `[0, 0xFFFF]`: max byte offset 524,280 ⇒ block byte
  size up to **524,288 (= 512 KiB)**.

These two bounds compose to give a max effective old-gen size of:

```
65535 blocks × 524288 B/block = ~32 GiB
```

Comfortably above the default `max_heap_size = 24G`. **However**, the
relationship `max_heap / alloc_buffer_size ≤ 65535` must hold at config
time. Two existing variants in `heap-profile.py:VARIANTS` violate this:

| variant | alloc_buffer_size | max_blocks at 24 G | ok? |
|---|---:|---:|---|
| baseline | 512 K | 49,152 | ✅ |
| `E1_page64K` | 64 K | 393,216 | ❌ exceeds uint16 |
| `E2_page256K` | 256 K | 98,304 | ❌ exceeds uint16 |

Mitigations (any one is sufficient — pick at config time):
1. **Static check at init**: compute `max_heap_size / alloc_buffer_size` in
   `OldGenSpace::initialize` and assert it's ≤ 65,535. Reject configs that
   violate; the user picks larger pages or a smaller cap.
2. **Auto-clamp `max_heap_size`** to fit the chosen page size (warn).
3. **Promote `block_index` to 24 bit** (3 B), drop `cell_offset_8` to 16 bit
   minus 8 = 8 bit — but a 256-byte effective block size is too small.
   Doesn't work without restructuring further.

Adopted: **option 1** (static reject). We document the constraint and the
sweep matrix's `E1_page64K`/`E2_page256K` variants will be filtered or
reduced to a smaller cap when this lands.

#### `prev_in_class = HEAD_SENTINEL` semantics

When `prev_in_class.block_index == 0xFFFF`, the cell is the **current head
of `free_lists_[cls]`**. To unlink it, the caller writes
`free_lists_[cls] = cell->next_in_class;` and (if the new head is non-null)
sets the new head's `prev_in_class.block_index = 0xFFFF`. Same shape as
today's `FreeCell** prev = &free_lists_[cls];` trick, just compactly
encoded.

### Summary table

| Class | Size | Layout | Per-block thread | Bulk-release unlink |
|---:|---:|---|---|---|
| 0 | 8 B | n/a (no free cells, today either) | — | — |
| 1 | 16 B | Tier S (16 B) | no | global walk of `free_lists_[1]` only |
| 2 | 24 B | Tier M (24 B) | yes | O(1) per cell via handle + offsets |
| 3+ | 32 B+ | Tier M (24 B used, slack discarded) | yes | O(1) per cell |

### What this costs vs a 40-B "all classes uniform" alternative

(For context: a uniform 40-B layout that puts every class on the per-block
thread was considered and rejected because it forced classes 1–3 to lose
free-list recycle entirely. The tiered design avoids that.)

- **Class 1 keeps recycle.** The 21,207 cells in class 1 from the LOT=1K
  freelist histogram remain on a free list and remain available for fast
  pop. No fragmentation regression for the smallest cell size.
- **Bulk release of class-1 cells is still slow** — we walk
  `free_lists_[1]` end-to-end on every block release. That list had ~21 K
  cells in the LOT=1K profile vs 3.27 M total. **155× shorter walk** than
  today's full traversal. Acceptable because class 1 specifically is short.
- **Class 2 cells (24 B) get the offset-encoded thread** — exactly fitting
  the 24-byte cell. No waste, full O(1) unlink.
- **Classes 3+ accept 8+ B of unused slack** at the tail of each free
  cell. The slack is *inside* the cell that will be handed back to the
  mutator on next pop; allocations don't see it.

## BlockInfo gains a list head

`OldGenSpace.hpp:211-220`:
```cpp
struct BlockInfo {
    char*     start;
    char*     end;
    char*     end_of_objects;
    size_t    size_class;
    bool      is_large;
    uint16_t  free_cells_in_block;   // ← NEW: offset/8 of the head Tier-M cell, or
                                     //   FREE_CELLS_EMPTY (0xFFFF) if no cells from
                                     //   this block are linked. Class-1 (Tier-S)
                                     //   cells are NOT in this thread.

    size_t totalBytes() const { return static_cast<size_t>(end - start); }
};
```

Storing the head as a `uint16_t` offset (instead of a `FreeCell*`) keeps the
per-block thread independent of `std::vector<BlockInfo>` reallocation —
when blocks_ grows, each `BlockInfo`'s offset is preserved verbatim,
nothing in any cell needs fixup. The offset resolves to a `FreeCell*` via
`reinterpret_cast<FreeCell*>(block.start + offset*8)`, which uses
`block.start` from the post-realloc address.

The trade-off is that `cell.prev_in_block` cannot point at "the slot in
BlockInfo" via a stable address; instead, when the cell is the head, its
`prev_in_block == FREE_CELLS_EMPTY`. The bulk-release walker writes the new
head value into `block.free_cells_in_block` directly when removing the
current head.

## What changes, file by file

### `OldGenSpace.hpp`

1. `struct FreeCell` — split into two structurally-distinct views,
   `FreeCellSmall` (16 B, class 1) and `FreeCellMid` (24 B, classes ≥ 2).
   Both share `Header header` + `FreeCell* next_in_class` at the same
   offsets. Tier-M adds the `prev_in_class` `CellHandle` and the two
   `uint16_t` per-block offsets. Update `MIN_FREE_CELL_SIZE = 16` (we still
   accept 16 B as the minimum on-list cell — class 1 cells fit). Add a
   constant `MIN_TIER_M_SIZE = 24`.
2. `struct CellHandle` — new 4-byte struct with `block_index`,
   `cell_offset_8`, plus a `HEAD_SENTINEL = 0xFFFF` constant and a
   `resolve(blocks_)` method.
3. `struct BlockInfo` — add `uint16_t free_cells_in_block = FREE_CELLS_EMPTY;`.
4. Add a `static_assert(sizeof(FreeCellMid) == 24)` and
   `static_assert(sizeof(FreeCellSmall) == 16)`.
5. No public-API changes.

### `OldGenSpace.cpp` — layout-following edits

Every site that reads `cell->next` becomes `cell->next_in_class`. New
maintenance for the per-block thread happens **only on Tier-M cells** —
`pushSpanOnFreeLists` decides which view applies based on the cell's
size class.

**Helpers (file-local inlines)** to keep the hot paths tidy:

```cpp
inline bool isTierM(size_t cls) { return classToSize(cls) >= MIN_TIER_M_SIZE; }

inline FreeCell* resolveOff(BlockInfo& blk, uint16_t off) {
    return (off == FREE_CELLS_EMPTY)
        ? nullptr
        : reinterpret_cast<FreeCell*>(blk.start + size_t(off) * 8);
}
inline uint16_t encodeOff(BlockInfo& blk, FreeCell* c) {
    if (c == nullptr) return FREE_CELLS_EMPTY;
    return static_cast<uint16_t>(
        (reinterpret_cast<char*>(c) - blk.start) / 8);
}

// Tier-M only: link `c` at the head of block.free_cells_in_block.
inline void blockThreadPushHead(BlockInfo& blk, FreeCell* c) {
    uint16_t old_head = blk.free_cells_in_block;
    c->prev_in_block = FREE_CELLS_EMPTY;
    c->next_in_block = old_head;
    if (old_head != FREE_CELLS_EMPTY) {
        resolveOff(blk, old_head)->prev_in_block = encodeOff(blk, c);
    }
    blk.free_cells_in_block = encodeOff(blk, c);
}

// Tier-M only: unlink `c` from its block thread (O(1)).
inline void blockThreadUnlink(BlockInfo& blk, FreeCell* c) {
    if (c->prev_in_block == FREE_CELLS_EMPTY) {
        blk.free_cells_in_block = c->next_in_block;
    } else {
        resolveOff(blk, c->prev_in_block)->next_in_block = c->next_in_block;
    }
    if (c->next_in_block != FREE_CELLS_EMPTY) {
        resolveOff(blk, c->next_in_block)->prev_in_block = c->prev_in_block;
    }
}

// Tier-M only: O(1) class-list unlink via CellHandle back-link.
inline void classListUnlinkTierM(FreeCell** free_lists, FreeCell* c,
                                 size_t cls,
                                 const std::vector<BlockInfo>& blocks) {
    FreeCell* prev = c->prev_in_class.resolve(blocks);
    if (prev) prev->next_in_class = c->next_in_class;
    else      free_lists[cls]    = c->next_in_class;
    if (c->next_in_class) {
        c->next_in_class->prev_in_class = c->prev_in_class;   // copy handle
    }
}
```

**(A) `pushSpanOnFreeLists` (lines 1942–2030)** — currently the only place
that *constructs* free cells. Augment:

- **Uniform block path** (`block->size_class < NUM_SIZE_CLASSES`,
  lines 1969–1996): if `cls == 1` use Tier-S (existing behaviour, no
  per-block thread). Otherwise use Tier-M: write the FreeCellMid fields,
  push onto `free_lists[cls]` setting `prev_in_class` to the appropriate
  `CellHandle` (HEAD_SENTINEL or a handle pointing at the prior head's
  cell), and call `blockThreadPushHead`.
- **Mixed-block path** (lines 1998–2030): identical Tier-M maintenance for
  all cells (the mixed-packer always picks `cls >= 1`; class 1 routes
  through the Tier-S fast path, all others through Tier-M).
- **`block == nullptr`**: fall back to single-class linking only — the
  cell is invisible to per-block release. Audit callers; if any survive in
  paths that matter for bulk release, plumb a non-null block through.
- **Skip cells with size < `MIN_FREE_CELL_SIZE = 16 B`** — unchanged.
  16-B cells form Tier-S; 24-B and up form Tier-M. Sub-16-B spans become
  parseable Tag_Free dead cells without going on a free list (sweep
  already tolerates this; line 1933).

**(B) `tryPopFromFreeList` (lines 572–581)** — pops `free_lists_[cls]` head.
For Tier-M classes, also unlink the popped cell from its block thread and
update the new head's `prev_in_class` to `HEAD_SENTINEL`:

```cpp
FreeCell* cell = free_lists_[cls];
if (!cell) return nullptr;
free_lists_[cls] = cell->next_in_class;
if (isTierM(cls)) {
    if (free_lists_[cls]) {
        free_lists_[cls]->prev_in_class = CellHandle::head();   // {HEAD_SENTINEL,0}
    }
    BlockInfo& blk = blockOf(cell);
    blockThreadUnlink(blk, cell);
}
return cell;
```

For class 1 (Tier-S) the body collapses to today's two lines — no per-block
maintenance, no `prev_in_class` to repaint.

**(C) `tryAllocateBySplittingLarger` (lines 796–870)** — currently walks a
size-class list, finds a cell, may unlink it, may re-emit a tail span via
`pushSpanOnFreeLists`. Three changes:

- Walks use `next_in_class` instead of `next`. The `prev`/`curr` walk
  pattern at lines 833–862 stays — *we still need a manual walk to find
  the right-fit cell*; the back-link is for O(1) **unlink** once we've
  found it, not for O(1) **search**.
- When unlinking a Tier-M cell mid-walk, replace the manual splice
  (`*prev = curr->next; curr = *prev;`) with `classListUnlinkTierM(...)`
  + `blockThreadUnlink(...)`. For Tier-S (class 1) cells the manual splice
  is unchanged.
- The tail span re-emission via `pushSpanOnFreeLists` automatically threads
  the new cell onto its block (via the change in (A)).

**(D) `transitionToSweeping` (line 2106)** — wipes
`free_lists_[i] = nullptr`. Now also wipe
`BlockInfo::free_cells_in_block = FREE_CELLS_EMPTY` for every block. The
cells themselves are about to be re-walked by lazy sweep, so no per-cell
state is needed; just reset the heads.

```cpp
for (auto& blk : blocks_) blk.free_cells_in_block = FREE_CELLS_EMPTY;
for (size_t i = 0; i < NUM_SIZE_CLASSES; ++i) free_lists_[i] = nullptr;
```

**(E) `removeFreeCellsForBlock` (lines 2740–2759)** — the win:

```cpp
void OldGenSpace::removeFreeCellsForBlock(size_t block_index) {
    if (block_index >= blocks_.size()) return;
    BlockInfo& blk = blocks_[block_index];

    // Tier-M cells: per-block thread walk, O(cells_in_this_block).
    FreeCell* curr = resolveOff(blk, blk.free_cells_in_block);
    while (curr != nullptr) {
        FreeCell* next = resolveOff(blk, curr->next_in_block);
        const size_t cls = sizeClassFromHeader(curr);
        classListUnlinkTierM(free_lists_, curr, cls, blocks_);
        curr = next;
    }
    blk.free_cells_in_block = FREE_CELLS_EMPTY;

    // Tier-S (class 1) cells: bounded global walk.
    // Class 1 had ~21 K cells in the LOT=1K profile vs 3.27 M total —
    // 155× shorter than today's full-list traversal.
    if (free_lists_[1] != nullptr) {
        char* lo = blk.start;
        char* hi = blk.end;
        FreeCell** prev = &free_lists_[1];
        FreeCell* c = free_lists_[1];
        while (c != nullptr) {
            char* p = reinterpret_cast<char*>(c);
            FreeCell* nxt = c->next_in_class;
            if (p >= lo && p < hi) *prev = nxt;
            else                   prev = &c->next_in_class;
            c = nxt;
        }
    }
}
```

`sizeClassFromHeader(curr)` reads `header.size` (already maintained as the
cell's actual byte size) and converts via the existing `sizeClass()`
helper. No new state.

**(F) `maybeShrinkCapacity` batched scan (lines 2664–2696)** — the
"O(N+M)" pre-clean for the bulk-release fast path is now redundant for
Tier-M (per-block thread is faster) but is still useful for Tier-S
(class 1) when releasing many blocks at once: walking
`free_lists_[1]` once and dropping cells in any of the to-release ranges
beats walking it once per block.

Adopted: keep the batched scan but **scope it to class 1 only**. Tier-M
classes use the per-block thread inside the per-block call. Net: removes
60-1 = 59 size-class iterations from the pre-clean loop, keeps the class-1
fast bulk path intact.

```cpp
if (!to_release.empty()) {
    // Pre-clean class 1 (Tier-S, no per-block thread). One walk, drops
    // every class-1 cell in any of the to-release blocks.
    if (free_lists_[1] != nullptr) {
        // ... existing binary-search-by-range loop, but only for cls=1 ...
    }
    ++g_batch_release_depth;
    for (auto it = to_release.rbegin(); it != to_release.rend(); ++it) {
        releaseBlockToAllocator(*it);   // Tier-M: O(cells_in_block)
                                        // Tier-S: skipped (already cleaned)
    }
    --g_batch_release_depth;
    ...
}
```

`removeFreeCellsForBlock` already pre-zeroed `free_lists_[1]` as a side
effect for the to-release ranges, so the per-block call's own class-1
walk becomes a no-op (it finds no cells in `[blk.start, blk.end)`). Add
a `g_batch_release_depth > 0` skip for the class-1 walk in
`removeFreeCellsForBlock` to spare the redundant work.

## Swap-remove correctness

`releaseBlockToAllocator` swap-removes from `blocks_` (line 2892) and
`buffer_meta_` (line 2899):

```
blocks_[i] = blocks_[last];           // copy BlockInfo struct
blocks_.pop_back();
```

With the offset-encoded design every link in the per-block thread is
**relative to `block.start`**, not an absolute pointer. The moved
`BlockInfo` struct still holds the same `start` byte address, so:

- The new `blocks_[i].free_cells_in_block` (a `uint16_t` offset) is valid
  unchanged.
- Every cell's `next_in_block` and `prev_in_block` (also `uint16_t`
  offsets) are valid unchanged.

**No fixup is needed.** This is the main payoff of the offset encoding.

The `prev_in_class` `CellHandle` of any *other* cell that pointed at a
cell in the moved block via `block_index = last` is now stale, however:
the cell formerly at index `last` now lives at index `i`. Fix this in the
existing `fixupIndicesAfterBlockMove(last, block_index)` (line 2761) by
adding a per-block-thread walk:

```cpp
// After the swap, walk the moved block's per-block thread and rewrite
// any cell whose `prev_in_class.block_index == new_idx` (impossible —
// they pointed at us before, via old_idx). The fixup target is cells in
// the *moved* block that are pointed to from the global class lists.
// The class-list slot `&free_lists_[cls]` is encoded as HEAD_SENTINEL,
// so nothing in free_lists_ needs touching. The cells whose
// `next_in_class` field points at a moved cell carry a CellHandle in
// their own `prev_in_class`, which encodes the moved cell's *block index*
// — not the slot's. So when the moved cell's block index changed
// (last → block_index), every cell that had us as predecessor now has
// a stale handle.
for (FreeCell* c = resolveOff(blocks_[block_index],
                              blocks_[block_index].free_cells_in_block);
     c != nullptr;
     c = resolveOff(blocks_[block_index], c->next_in_block)) {
    if (c->next_in_class != nullptr) {
        c->next_in_class->prev_in_class.block_index = block_index;
    }
}
```

This is O(cells in moved block) per swap. Since swap-remove only happens
once per block release, and `removeFreeCellsForBlock` already pre-zeroed
the *released* block's thread, the moved block's thread is the only
non-empty one — bounded.

`std::vector` reallocation during `push_back` *does not* break offset-
encoded threads (offsets are relative to `block.start`, which is preserved
across BlockInfo copies — `block.start` is a `char*` to a separately
allocated page, not into `blocks_` itself). **No `blocks_.reserve()` is
required** with the offset encoding. This is a strict simplification over
the pointer-based draft.

`CellHandle::block_index` references *do* break on `blocks_` realloc only
if a `block_index` value gets reassigned to a different block — but the
swap-remove case above handles that explicitly, and `push_back` only
appends, so existing handles stay valid.

`buffer_meta_` doesn't carry the head, so no fixup needed.

## Edge cases

1. **`block == nullptr` in `pushSpanOnFreeLists`**: leave Tier-M
   per-block fields as `FREE_CELLS_EMPTY`. Cell becomes invisible to bulk
   release; falls back to global class-list scan (slow path). Audit
   callers; preference is to plumb a non-null block in all callers. Mark
   with a `// TODO(perf):` comment if any caller stays null.
2. **Heap-base sentinel** (`HEAP_BASE_SENTINEL_SIZE = 8 B`): NOT a
   FreeCell. Below `MIN_FREE_CELL_SIZE = 16 B` already. Unaffected.
3. **`Tag_Free` cells with the sentinel age bit** (already on a free
   list): the sentinel just means "don't merge during sweep coalescing".
   Still threaded normally. No code changes here.
4. **Mid-cycle materialization**: when a block is freshly acquired during
   sweep, its `fully_swept` is pre-set to true and lazy sweep walks past
   it (line 2191). Its cells were allocated via `populateFromBlock`, which
   already calls `pushSpanOnFreeLists`, so (A) handles this for free.
5. **Per-block thread vs major-GC mark**: marking follows live HPointers
   only; free cells are not marked. The new per-block thread fields live
   in Tag_Free cells, never visited by mark. Unaffected.
6. **Reset / reconfigure** (`OldGenSpace.cpp:195`): the existing
   `free_lists_[i] = nullptr` reset clears the class lists. The existing
   `blocks_.clear()` removes BlockInfos (and their `free_cells_in_block`
   heads with them). No new code needed here.
7. **Class-1 cell that becomes 24 B via merge**: sweep coalescing can
   produce a cell larger than the class it was originally on. The
   coalesced span goes through `pushSpanOnFreeLists`, which picks the
   right class via `freeListClassFor(span_bytes)` and writes the
   appropriate Tier (S or M). No special transition logic required.
8. **Tier-M cell shrunk by `tryAllocateBySplittingLarger`**: when the
   splitter carves a tail, the *original* cell is unlinked completely
   (both threads) and the carved-prefix is returned to the mutator; the
   tail span is re-emitted via `pushSpanOnFreeLists`, which threads it
   afresh. No partial in-place update of either thread.
9. **Block index = `HEAD_SENTINEL` collision**: 0xFFFF is reserved. Static
   assert at init that `blocks_.size() < 0xFFFF`. Combined with the
   `max_heap / alloc_buffer_size <= 0xFFFE` check, this is enforced.
10. **`max_heap_size / alloc_buffer_size > 65,535`**: reject in
    `OldGenSpace::initialize` with a clear error message. Documented in
    the BlockInfo section above.

## Validation

1. **Existing assertion family**: keep the `pushSpanOnFreeLists` OOB-checker
   (line 1951) gated on `ECO_OLDGEN_DEBUG`. Add a sibling under the same
   flag — `validatePerBlockThreads()` — that walks every block's
   `free_cells_in_block` thread end-to-end and asserts:
   - Every offset resolves to an address in `[blk.start, blk.end)`.
   - Every visited cell's `header.tag == Tag_Free`.
   - Every visited cell's size class is ≥ 2 (Tier-M only).
   - The chain has no cycles (visited-set bounded by `(blk.end - blk.start) / 8`).
   - For each visited cell, `prev_in_class` resolves through the
     `CellHandle` to a cell whose `next_in_class == this`, OR
     `prev_in_class.block_index == HEAD_SENTINEL` and
     `free_lists_[cls] == this`.
   Run after every major GC's `transitionToSweeping`/`finishMarkAndSweep`
   and after every `maybeShrinkCapacity`. Production builds skip the check.
2. **Class-1 invariant** (also debug-only): walk `free_lists_[1]` and
   assert every cell's size is exactly 16 B and `header.tag == Tag_Free`.
3. **Unit tests** in `test/allocator/OldGenSpaceTest.cpp` (already
   exists):
   - Tier-S only: push/pop/remove for class 1, ensure global walk
     fallback works.
   - Tier-M only: push N cells of class 5+ across M blocks, then call
     `removeFreeCellsForBlock(b)`; assert per-block thread emptiness for
     `b` and class-list invariants intact.
   - Mixed Tier-S+M: same workload with classes 1, 2, 4 mixed; assert
     class-1 cells in block `b` were removed via the bounded global
     walk and Tier-M cells were removed via the per-block thread.
   - Pop, split, re-emit: assert both threads stay consistent.
   - Swap-remove: release block `i`, then assert that any cell in
     `blocks_[last]` (now moved to slot `i`) has `prev_in_class.block_index
     == i`, not `last`.
   - Stress: 10 K random push/pop/release operations, compare against a
     naïve reference implementation (full re-walk).
4. **`max_heap / alloc_buffer_size` bounds check**: unit test that
   `OldGenSpace::initialize` rejects a config with
   `max_heap_size = 24G` and `alloc_buffer_size = 64K` (393 K blocks > 65535).
5. **E2E smoke**: `cmake --build build --target full` with both LOT=1K
   and LOT=16K configs; expect:
   - 1143/1143 pass (no regression)
   - perf delta on the LOT=1K profile: `releaseBlockToAllocator` falls
     from 87 % to < 5 % of CPU.
6. **Benchmark via heap-profile.py**:
   - Pre-fix LOT=1K 30 s baseline (captured 2026-05-04):
     `oldgen_alloc_in_mutator = 8.91 s`, `mutator% = 63.7 %`,
     `bytes_alloc_MB = 5735`.
   - Target: `mutator% > 92 %` and `bytes_alloc_MB > 25,000` in the same
     30 s budget.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 24-B Tier-M minimum makes class 1 (16 B) ineligible — class-1 cells use Tier-S, *retain* recycle, but bulk release walks `free_lists_[1]` | Low | Class 1 had ~21 K cells in LOT=1K vs 3.27 M total — 155× shorter walk than today; acceptable |
| `max_heap / alloc_buffer_size > 65535` configs reject at init | Low (only `E1_page64K`, `E2_page256K` in current sweep matrix) | Static check at `OldGenSpace::initialize`; document in heap-config example; the matrix variants either reduce `max_heap_size` or are skipped |
| `CellHandle.block_index` stale after swap-remove | Medium | `fixupIndicesAfterBlockMove` walks the moved block's per-block thread and rewrites every dependent cell's predecessor handle; covered by unit test |
| `pushSpanOnFreeLists(block=nullptr)` callers leak cells from per-block thread | Medium | Audit all callers; plumb block through in production paths; cells without a block fall back to global scan (correctness preserved, perf degraded) |
| Steady-state allocator hot path slowed by extra writes per push/pop on Tier-M | Low | Tier-M push: 4 extra writes (prev_in_class handle + 2 offsets + neighbor's prev_in_block). All to memory already in L1 (the cell + the block header). Expected overhead < 5 ns; the dispatch path is microseconds. Validate via heap-profile.py on LOT=16K (no bulk-release pressure). |
| Tier-S vs Tier-M dispatch in `tryPopFromFreeList` adds a branch on the hot path | Low | The branch (`isTierM(cls)`) is on a constant-after-class-known basis; the compiler can hoist it via `__builtin_expect`. Profiles will show whether it matters. |

## Rollback

Behind a build flag `ECO_OLDGEN_PER_BLOCK_THREAD` (default on). If the
debug-build invariant walker fires, set the flag off in `cmake-presets.json`
and the old `removeFreeCellsForBlock` walk is restored. Cell layout
fields exist in both modes (cheap to leave unused on Tier-M) — only the
maintenance code paths are gated.

## Implementation order (suggested commits)

1. **Layout + helpers**: introduce `FreeCellSmall`, `FreeCellMid`,
   `CellHandle`, `FREE_CELLS_EMPTY`, `HEAD_SENTINEL`,
   `MIN_TIER_M_SIZE = 24`. Add static asserts on sizeof. No callers
   updated yet — purely additive. Run `cmake --build build`; should be
   pure-additive build pass.
2. **Push/pop maintenance**: implement `pushSpanOnFreeLists` Tier-M
   threading + `tryPopFromFreeList` block-thread unlink + Tier-M
   `tryAllocateBySplittingLarger`. Add `BlockInfo::free_cells_in_block`
   field. Add `OldGenSpace::initialize` config check for max-blocks
   bound. Run unit tests; `cmake --build build --target full` should
   remain 1143/1143.
3. **Bulk-release rewrite**: switch `removeFreeCellsForBlock` to
   per-block thread walk + bounded class-1 walk. Add swap-remove
   `prev_in_class.block_index` fixup. Scope the `maybeShrinkCapacity`
   batched scan to class 1 only. Verify debug-build
   `validatePerBlockThreads()` passes after every major GC.
4. **Benchmark**: 30 s heap-profile runs at LOT=1K and LOT=16K; compare
   to the pre-fix baselines; commit results to a `bugs/` note.

## Out of scope (deferred to follow-up plans)

- "Avoid `maybeShrinkCapacity` on every `allocateLargeBody`" amortization
  (recommendation #2 from the LOT=1K profile report).
- "Raise the BBoP page-as-single-cell short-circuit" so 16 KiB
  allocations at LOT=1K bypass the splitter (recommendation #3).
- `__builtin_prefetch(curr->next, 0, 0)` two iterations ahead —
  recommendation #4 stop-gap; not needed once this plan lands.
