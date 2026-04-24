# Old-Gen Segregated-Fits + Big Bag of Pages

## Goal

Replace the current bump-pointer-first old-gen allocator with a textbook-style
segregated-fits allocator backed by a "Big Bag of Pages" (BBoP), with:

- Extended size classes (8 B → `large_object_threshold`, default 8 KiB).
- Demand-driven population: classes start empty; first allocation slices a page.
- Coalescing in sweep (adjacent garbage merged into one free cell).
- Splitting on allocation (larger free cell carved to satisfy smaller request).
- 16 MiB (128 × 128 KiB) of old-gen pages pre-committed and pushed into the
  bag of unassigned pages at heap init time.

Mutator allocation no longer uses bump pointers in the common path; bump
allocation survives only inside compaction's evacuation buffers.

## Files Touched

| File | Change |
|---|---|
| `runtime/src/allocator/Heap.hpp` | Add `Tag_Free` |
| `runtime/src/allocator/AllocatorCommon.hpp` | Handle `Tag_Free` in `getObjectSize`; validate `initial_old_gen_size % alloc_buffer_size == 0` |
| `runtime/src/allocator/OldGenSpace.hpp` | New size-class scheme, extended `BlockInfo`, free-cell layout, new private methods |
| `runtime/src/allocator/OldGenSpace.cpp` | Rewrite `initialize`, `allocate`, `sweep`, `lazySweep`; add `populateFromBlock`, `allocateFromSizeClass`, `tryAllocateBySplittingLarger`, `findBlockFor`, large-free-list management |
| `runtime/src/allocator/ThreadLocalHeap.cpp` | Adjust to new init flow if it pokes BlockInfo directly |
| Tests | Add tests for lazy population, coalescing, splitting; update tests asserting old bump semantics |
| `THEORY.md` / design docs | Describe new old-gen model |

## Step-by-Step Plan

### Phase 1: Free-cell representation

1. **Add `Tag_Free`** to `Tag` enum in `Heap.hpp`. Place before `Tag_Forward`
   (which the comment marks as "must be last") or update that invariant.
2. **Teach `getObjectSize` about `Tag_Free`** in `AllocatorCommon.hpp`: free
   cells store byte-size directly in `hdr->size`; return that (already aligned).
3. **Update `FreeCell` initialization sites** to set
   `header.tag = Tag_Free`, `header.size = cellBytes`, `header.color = White`.
4. **Mark/scan code defensively skips `Tag_Free`** in `markChildren` and any
   object-walking code (`scanObject`, compaction walks).

### Phase 2: Size class extension

1. Replace `NUM_SIZE_CLASSES = 32` / `MAX_SMALL_SIZE = 256` with the hybrid
   scheme:
   - `NUM_SMALL_CLASSES = 32` (8 B steps to 256 B)
   - `NUM_MEDIUM_CLASSES` covers powers of two from 512 B up to
     `large_object_threshold` (default 8 KiB → 5 medium classes).
   - `NUM_SIZE_CLASSES = NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES`.
2. Rewrite `sizeClass(size)` and `classToSize(cls)` accordingly. Note
   `sizeClass` becomes non-`static` (or takes the LOS threshold as an
   argument) because the medium cap depends on `config_->large_object_threshold`.
3. Add a `highestBitIndex` helper (or use `__builtin_clzll`).

### Phase 3: BlockInfo extension and bag of pages

1. Extend `BlockInfo` with `size_class`, `total_bytes`, `free_bytes`. Keep
   `start`, `end`. `alloc_ptr` becomes vestigial for mutator allocation; reuse
   it only inside evacuation/large-block paths or remove it from the mutator
   data flow.
2. Add `std::vector<size_t> unassigned_blocks_` to `OldGenSpace` (the bag).
3. Add a `findBlockFor(void*)` helper. Since old-gen blocks are carved from a
   contiguous reservation in `acquireOldGenRegion`, the natural impl is
   `index = (ptr - region_base_) / config_->alloc_buffer_size`. Large blocks
   acquired by `allocateLargeBlock` break this assumption — they are appended
   later and may not be at page offsets. Handle them with an auxiliary lookup
   (sorted vector of `{start, end, idx}` for non-page-sized blocks).

### Phase 4: Initialization (16 MiB precommit → bag)

1. Rewrite `OldGenSpace::initialize`:
   - Acquire a contiguous region of `initial_old_gen_size` bytes via
     `acquireOldGenRegion(initial, max)`. (Currently `initialize` does **not**
     do this; the first allocation lazily acquires single blocks via
     `acquireOldGenBlock`. This is a change in policy.)
   - Slice the region into `initial_old_gen_size / alloc_buffer_size` pages.
   - Push each page index into `unassigned_blocks_`.
   - Initialize all free lists to empty.
2. Add `HeapConfig::validate()` check:
   `initial_old_gen_size % alloc_buffer_size == 0`.
3. Confirm `Allocator::acquireOldGenRegion` is the right entry point — it
   currently reserves `max_size` and commits `initial_size`; we want to slice
   only the committed prefix.

### Phase 5: Allocation path (segregated-fits)

1. New top-level `allocate(size)`:
   - Drive marking/sweeping work as today (bookkeeping unchanged).
   - If `size >= large_object_threshold`, route to `allocateLargeBlock`.
   - Else compute `cls`, call `allocateFromSizeClass(cls, size)`.
2. `allocateFromSizeClass(cls, requestedSize)`:
   - Pop from `free_lists_[cls]` if non-empty (fast path).
   - Else `tryAllocateBySplittingLarger(cls, requestedSize)`.
   - Else `populateFromBlock(cls)` (pull a page from `unassigned_blocks_`,
     slice into cells, push onto `free_lists_[cls]`, re-pop).
   - Else fall back to lazy-sweep slice + retry; if still nothing, signal OOM
     so the caller can drive a major GC.
3. `populateFromBlock(cls)`: implement per design (slice page into
   `classToSize(cls)`-byte cells, link them into the class list, set
   `BlockInfo.size_class = cls`).
4. `tryAllocateBySplittingLarger(targetCls, allocSize)`:
   - Walk `cls = targetCls+1 .. NUM_SIZE_CLASSES-1`.
   - For each non-empty class, scan its list for a cell with
     `cellSize >= allocSize + sizeof(FreeCell)`.
   - Unlink, carve front, push remainder back to `sizeClass(remSize)` (which
     may be the same class).
   - Return the front. (The split front does **not** need a `Tag_Free` header
     — caller will overwrite the header with the real object's tag/size.)
5. Add a "large free list" or similar bucket for free chunks ≥ medium cap that
   can come out of coalescing (see Phase 6); may simply append to the largest
   medium class and rely on splitting.

### Phase 6: Sweep (coalescing)

1. Rewrite `OldGenSpace::sweep`:
   - For each block, walk objects.
   - Live (Black): clear color, advance.
   - Garbage: scan forward, accumulating bytes until next Black (or block end);
     emit a single `Tag_Free` cell of total size, push onto `sizeClass(span)`'s
     list.
2. Apply the same coalescing logic to `lazySweep` (incremental version).
3. Maintain `BlockInfo.free_bytes`, `BufferMetadata.live_bytes/garbage_bytes`,
   and `frag_stats_`.
4. **Decision needed for dedicated-page invariant**: a page populated for a
   given size class loses its uniform structure after coalescing produces
   a free span larger than that class's cell size. Two options:
   - (A) Allow heterogeneous free cells in any block. Splitting handles it
     uniformly. Simpler.
   - (B) On dedicated small-class pages, re-slice back into fixed-size cells
     (skip coalescing). Closer to BBoP textbook, may reduce fragmentation for
     small classes.
   I propose (A) for simplicity; revisit if measurements show small-class
   fragmentation regressions.

### Phase 7: Compaction interaction

1. Compaction uses `allocateForEvacuation` with its own bump cursor inside
   evacuation destination buffers. Confirm those buffers are sourced
   independently of the bag (they will be — they come from
   `acquireOldGenBlock` into a dedicated `BlockInfo`).
2. After evacuation finishes and source buffers are freed, push their indices
   back into `unassigned_blocks_` (or release them) so the bag is replenished.
3. Reference-fixup walks must skip `Tag_Free`.

### Phase 8: Tests + invariants

1. Lazy population: allocate one 80-B object → assert exactly one block leaves
   `unassigned_blocks_`, becomes dedicated to class 9, and the class's list
   has `(alloc_buffer_size / 80) - 1` cells remaining.
2. Splitting: hand-craft a free list with one large free cell and verify a
   smaller allocation splits it, returning the right remainder to the right
   class.
3. Coalescing: allocate N adjacent objects, drop refs, run major GC,
   verify a single coalesced free cell of total size on the appropriate list.
4. Sweep on dedicated pages with mixed liveness behaves correctly.
5. Update `OldGenSpaceTestAccess` if internal layout changed.
6. E2E: `cmake --build build --target full` to ensure no regressions in the
   18/31 stress baseline.

### Phase 9: Docs

1. Update `THEORY.md` and/or relevant `design_docs/theory/*.md` to describe
   the new model.
2. Add invariants to `design_docs/invariants.csv`:
   - `HEAP_*`: free cells use `Tag_Free`, size in bytes.
   - `HEAP_*`: `initial_old_gen_size` must be multiple of `alloc_buffer_size`.
   - `HEAP_*`: mutator allocation routes through size classes; bump allocation
     reserved for evacuation and large-block paths.

## Resolved Design Decisions

The following questions were raised during design review and have been
resolved. The plan above incorporates these answers.

1. **`Tag_Forward` ordering** — the "must be last" comment is documentation,
   not enforced. `Tag_Free` may be inserted before `Tag_Forward`. Update
   `getObjectSize`, `scanObject`, `markChildren`, and add HEAP_004-style
   invariants covering the new tag.

2. **`Header.size` width** — `Header.size` is a full `u32`, easily covering
   a 128 KiB (or even 4 GiB) free cell. No widening needed. Free cells
   store size in **bytes** (matching `Tag_ByteBuffer` convention).

3. **16 MiB up-front precommit** — architecturally fine: the default
   `INITIAL_OLD_GEN_SIZE` is already 16 MiB and `getCommittedBytes()` already
   reports the committed region size rather than live bytes. Keep the
   upfront slice configurable through `HeapConfig::initial_old_gen_size`
   so embedders/tests can shrink it.

4. **Medium-class cap vs LOS threshold** — strict `<`. Size classes cover
   `size < large_object_threshold`; allocations `>= large_object_threshold`
   go to LOS / dedicated pinned blocks (matching the existing
   "bypass the nursery as pinned" semantics).

5. **8–128 KiB allocations** — served from BBP size-class pages by splitting
   an unassigned page (or a coalesced free run). Only `size >= alloc_buffer_size`
   (128 KiB by default) takes the dedicated `allocateLargeBlock` path.
   Concretely: medium classes cover up to `large_object_threshold - 1`; the
   8 KiB … 128 KiB range is handled via splitting unassigned pages, since a
   single-class page would yield only one cell. Phase 5 must therefore be
   able to take an unassigned page, mark it as a single large free cell, and
   split from it.

6. **`BlockInfo.size_class` is advisory** — `BlockInfo` currently has no
   size-class field; nothing today depends on one. The new field is a hint
   ("preferred class for this page"); free-cell `Header.size` is the
   authoritative size. Coalescing across original cell boundaries is allowed
   (option A in Phase 6).

7. **`findBlockFor`** — no existing helper; current code uses explicit
   indices. With non-uniform large blocks alongside uniform BBP pages, we
   need a new auxiliary index. Plan: page arithmetic
   `(ptr - region_base_) / alloc_buffer_size` for the contiguous BBP region;
   a sorted `[start,end)` side table (binary search) for large blocks
   acquired by `allocateLargeBlock`.

8. **Sweep heap-parsability** — never parse pages that have never held
   objects. Each block needs an `end_of_objects_` watermark (or reuse
   `alloc_ptr` semantically). For unassigned pages, watermark == `start` so
   sweep skips them. This is required for correctness — sweep currently walks
   `[start, alloc_ptr)` which works because `alloc_ptr` is the bump frontier;
   under BBP, dedicated-class pages are populated all at once with `Tag_Free`
   cells (which sweep can correctly walk via `getObjectSize`), while
   unassigned pages must be skipped.

9. **Mid-cycle page population** — safe. Marking walks reachable objects
   only; it never inspects free lists or never-used pages. New cells become
   reachable only through normal allocation, which initializes a valid header
   (Black during marking, per existing convention). No existing invariant
   depends on a page being either fully unassigned or fully live.

10. **Test surface** — `OldGenSpaceTestAccess` exposes `getBlocks()`, sweep
    cursors, free lists, frag stats, size-class helpers. Tests assuming
    `blocks_.size() == 0` initially or that the first block appears lazily
    will break. Compatible mitigation: keep precommitted pages out of
    `blocks_` until first use (move from `unassigned_blocks_` into `blocks_`
    on populate). This preserves "blocks_ tracks active blocks" semantics.
    **Adopt this**: `unassigned_blocks_` holds raw `(start, end)` tuples;
    `populateFromBlock` materializes a `BlockInfo` and pushes onto `blocks_`.
    Audit tests that assert on initial `blocks_.size()` regardless.

## Plan Adjustments From Resolved Decisions

- **Phase 3**: `unassigned_blocks_` holds `std::vector<std::pair<char*,char*>>`
  (page extents), not indices into `blocks_`. `BlockInfo` is created lazily
  in `populateFromBlock` / `allocateLargeBlock`. This keeps `blocks_.size()`
  monotonic in "blocks ever used" rather than jumping to 128 at init.
- **Phase 4**: `OldGenSpace::initialize` acquires the contiguous region via
  `acquireOldGenRegion(initial_old_gen_size, max)`, then pushes 128 page
  extents into `unassigned_blocks_`. `blocks_` and `buffer_meta_` start empty.
- **Phase 5**: For requests in `[8 KiB, alloc_buffer_size)` (above LOS
  threshold but at most one page), `allocateFromSizeClass` cannot rely on
  fixed-cell slicing (page yields ≤1 cell). Treat such requests as: pull an
  unassigned page, install a single `Tag_Free` cell spanning the page, then
  split. The same path naturally handles smaller sizes when no smaller page
  is available — populate-then-split is uniform.
- **Phase 6**: Sweep walks `[block.start, block.end_of_objects_)`. For pages
  populated as one big free cell + objects, `end_of_objects_` advances as
  splits carve allocations off the front. For dedicated small-class pages,
  `end_of_objects_` is set to `block.end` at populate time (every cell is a
  parseable `Tag_Free`).
- **Phase 8 tests**: assert `blocks_.size() == 0` initially (no pages
  materialized into `BlockInfo`s yet); allocating one 80-B object grows
  `blocks_` to 1 and `unassigned_blocks_` shrinks by 1.
- **Phase 9 invariants**: add HEAP_* invariants for
  - `Tag_Free.header.size` is byte size;
  - free cells are never marked or scanned;
  - `initial_old_gen_size % alloc_buffer_size == 0`;
  - `block.end_of_objects_ <= block.end`, sweep parses `[start, end_of_objects_)`.

## Stop point

Per `/pqn`: I have not modified any code. The plan now incorporates the
resolved design decisions and is ready for implementation review.
