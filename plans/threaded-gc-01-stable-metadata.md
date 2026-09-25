# Threaded GC 01 — Stable old-gen metadata

**Status:** DONE (2026-09-24). Kept as snapshot `keep-TG1` (patch `snapshots/lss-loop/step-TG1.patch`;
the new/changed test files are under `keep-TG1/extra-test/`, which the snapshot script does not
cover); `bin/eco-opt-prev` = `eco-optTG1f`. Results: `benchmarks/gc-opt-loop.md` entry **TG1**;
as-built deviations and gate results in P§9a. Written against the `keep-T01` tree.

**Parent:** `plans/threaded-gc-master-plan.md`, phase 1.

**Background:** `design_docs/parallel-gc.md`, the design-space report. §n points into that report,
P§n into this plan, and 00-P§n into `plans/threaded-gc-00-measure-and-fix.md`. The baseline is
`benchmarks/threaded-gc-00-baseline.md`.

## 0. What this phase delivers, and why

Every threaded phase after this one has a second thread reading old-gen metadata. That can be
helper markers (phase 4), a concurrent marker (5b), parallel promotion (6) or a tenuring thread
(7c). Today that metadata lives in `std::vector`s. A vector reallocates when it grows, and blocks
are removed by swap-remove and `erase`, so **a block's index is not its identity**. Every index
stored anywhere is patched when a block moves. A second thread holding an index or a pointer
across either event reads freed memory or another block's data. Report §3.5 lists these races.

This phase removes both hazards on a single thread, where the result can be proven neutral. Two
proofs are required: GC counters bit-identical, and `out.mlir` byte-identical.

| # | Deliverable |
|---|---|
| D1 | GC collection code reads **per-heap state**, never the calling thread's TLS: nursery membership, the in-minor-GC flag, the batch-release depth |
| D2 | Free-list back-links encode the predecessor's **address**, not `{16-bit block index, offset}`. This removes the 65,535-block ceiling and a block-metadata read from every free-list unlink |
| D3 | `ReservedArray<T>`: fixed capacity, reserved in VA, committed on demand, **never moves** |
| D4 | `BlockTable`: a **stable `BlockId` per block** plus a separate iteration *order* that reproduces today's `blocks_` order exactly. It replaces `blocks_`, `buffer_meta_` and `large_block_mark_` |
| D5 | A page index reserved over the **whole old-gen reservation**, keyed from `heap_base`, holding `BlockId`s, never rebuilt |
| D6 | A mark-bit arena with **one fixed-stride slot per `BlockId`**, grown in place, with no re-pack |
| D7 | A marker-side `LiveBytesAccumulator`, merged into `BufferMetadata::live_bytes` at the mark→sweep sync point |
| D8 | `ECO_HEAP_VALIDATE` checks that re-derive every invariant this phase relies on or deletes, plus scale tests |
| D9 | New `invariants.csv` rows, doc updates, the measurement entry, and the tracking-table row |

**Out of scope:** threads, atomics, and any policy or layout change (P§10).

## 1. Ground rules for this phase

1. **No behaviour change.**
   - All GC counters must be bit-identical to a **same-session** control run of `eco-optT01`
     (00-P§6a.1): minor cycles, major cycles, allocated, promoted, copied-in-nursery, per-tag
     retention, and the major event log's promoted and mark-unit columns.
   - `out.mlir` must be byte-identical to `bin/ecoghash.mlir`.
   - The only permitted difference is behaviour above 65,535 live blocks. That is unreachable on
     every workload we run: the self-compile peaks near 30 K blocks at 15 GB.
2. **Identity is not order.** Much of the old gen iterates `blocks_` by position, and several
   policies depend on that order: lazy-sweep order, the first-fit scan in
   `allocateFromEmptyRegularBlocks`, the back-to-front reclaim, and the shrink passes. Changing
   the order changes which cells get reused, and so the counters. The design therefore keeps
   **two** things:
   - an order sequence whose semantics equal today's `std::vector` exactly, including swap-remove
     and ordered `erase`;
   - a stable identity (`BlockId`) that never changes while the block is live.
   Positions stay positions (loop variables and the two sweep/fixup cursors). **Every other stored
   block reference becomes a `BlockId`.**
3. **Strong types.** `BlockId` is a struct, not an integer alias, so a position passed where an id
   is expected fails to compile. The compiler is the migration checklist in Step 5.
4. **No new hot-path branches.** The past restructures of predicted code lost 0-for-5
   ([[gc-opt-loop-results]], `benchmarks/gc-opt-loop.md` W3/W4/W6/W11b/W12c). Each hot path in
   P§3.9 must keep its branch count. Where this phase replaces a bounds check, it replaces it with
   one of equal cost.
5. **Still single-threaded.** No `std::atomic`, fences or locks. The comments and invariants state
   what later phases may rely on. Nothing here is exercised concurrently.
6. **Only the owning heap's mutator thread releases a block,** at points where no GC work item is
   outstanding. Phase 1 has no work items, so this is a rule written down for phase 3 onward
   (HEAP_048).
7. **Assert what you delete.** Four structures are deleted: `fixupIndicesAfterBlockMove`'s id
   patching, `renamePageIndexSlots`, `rebuildPageIndexFromBlocks` and the arena re-pack. Each one
   maintained an invariant, and each gets a validator that re-derives it (Step 9), run in the
   validate tree on the unit tests, E2E and GC-pressure stress. (A validator self-compile was
   originally required here; it was dropped on 2026-09-24 as too slow, see P§9a.11.)

## 2. Verified facts the steps rely on

These were verified on 2026-09-24 against `keep-T01`. **Re-verify each one before editing**, and
where a step says "N sites", assert the count with `grep -c` before patching.

| # | Fact | Where |
|---|---|---|
| F1 | `blocks_` grows at **four** sites, each followed by `buffer_meta_.push_back`, `markBitsAppendForBlock`, `large_block_mark_.push_back(0)` and `assignPageIndexForBlock`: `allocateFromBagPage` `:1245`, `populateFromBlock` `:1334`, `allocateLargeBlock` `:1525` (calls `markBitsAppendForBlock(0)`, and assigns the page index only after `resizePageIndexForRegion`) and `allocateForEvacuation` `:3981`. The comment at `:272` names a `materializeBlock` that **does not exist**, and the "block-count bound checked at each push" it describes is absent too. | `OldGenSpace.cpp` |
| F2 | Blocks leave by **two** paths: swap-remove in `releaseBlockToAllocator` (`:3441-3480`), and order-preserving `erase` over a descending-sorted evacuation set in `freeEvacuatedBuffers` (`:4270-4299`). The same `blocks_` order is also `clear()`ed in `reset()` (`:320-328`) and the destructor (`:233`). | `OldGenSpace.cpp` |
| F3 | `fixupIndicesAfterBlockMove(last, idx)` (`:3275-3327`) patches `evacuation_set_`, `free_large_blocks_`, `evac_block_index_`, `sweep_buffer_index_`, `fixup_buffer_index_` and Tier-M `CellHandle`s. Of these, **only `sweep_buffer_index_` and `fixup_buffer_index_` are positions**; the rest name a block. | `OldGenSpace.cpp` |
| F4 | Compaction is **test-only**: `scheduleCompaction` / `incrementalCompactionSlice` have no caller outside `OldGenSpaceTestAccess`. It must keep working because the tests drive it. | `grep -rn scheduleCompaction runtime/src` |
| F5 | `page_to_block_index_` is indexed `(p - region_base_) / alloc_buffer_size`. `region_base_` moves on release, so every bounds change calls `recomputeRegionBoundsAndRebuildIndex` (`:457`), which rebuilds the whole index. `blockIndexFor` (`:598`) returns `blocks_.size()` for "not found" and has **no** linear fallback, whatever its header comment says. | `OldGenSpace.cpp`, `.hpp:1055-1059` |
| F6 | A page slot has **at most two** owners. Every block is at least `alloc_buffer_size` long, so a slot of that size intersects at most two disjoint blocks. This holds for any slot origin, so moving the origin from `region_base_` to `heap_base` keeps it. | arithmetic; `assignPageIndexForBlock` `:491` |
| F7 | `Allocator::ensureOldGenCapacityFor` (`Allocator.cpp:~770-807`) writes `space.unassigned_blocks_`, `region_base_`/`region_end_` and calls `space.resizePageIndexForRegion()`. It is a friend-access writer outside `OldGenSpace.cpp`. | `Allocator.cpp` |
| F8 | Old-gen blocks all lie in `[heap_base, heap_base + nursery_offset)`, one reservation shared by every heap. `nursery_offset` is fixed at the first `Allocator::initialize` (HEAP_043). There is no public getter for it (`getOldGenMaxBytes` is `min(config cap, nursery_offset)`). | `Allocator.hpp:245-256, 289-305` |
| F9 | The mark bitmap is `mark_bits_arena_` + `mark_bits_offset_[i]` + `mark_bits_len_[i]` (`.hpp:578-603`), re-packed and zero-filled in `startMark` (`:1603-1621`). The bulk zero is **load-bearing**: a second, unidentified path leaves a set bit in a block that sweep walked to completion (W11b, `gc-opt-loop.md:910`). The `byte_index >= mark_bits_len_[i]` guard is load-bearing too (W12b). | `OldGenSpace.hpp`, `.cpp` |
| F10 | `BufferMetadata::live_bytes` is written by the **allocator side**: `initObjectHeaderWithSize` `:405` (+=, mid-cycle), `allocateFromFreeLargeBlocks` `:1426` and `allocateFromEmptyRegularBlocks` `:1473` (=), and `freeLargeBodyCell` `:4656-4660` (a **clamped** −=). The **marker** writes it in `markOneObject` `:1984` (+=). It is reset in `resetBufferMetaForMark` `:2002`, and first read after mark in `finalizeMetaAfterMark` `:2018`. | `OldGenSpace.cpp` |
| F11 | Marking is stop-the-world. `ThreadLocalHeap::majorGC` (`ThreadLocalHeap.cpp:604`) calls `startMark` … `finishMarkAndSweep` with no mutator code in between. No allocation, and no `freeLargeBodyCell`, runs between `resetBufferMetaForMark` and `finalizeMetaAfterMark`, except in unit tests that drive `OldGenSpaceTestAccess::startMark` / `incrementalMark` by hand. | `ThreadLocalHeap.cpp:604-719` |
| F12 | `CellHandle {u16 block_index, u16 cell_offset_8}` sits in `FreeCellMid::prev_in_class` (`.hpp:139-166`). Blocks with index > 0xFFFE silently get **no Tier-M threading** (`populateFromBlock` `:1353`, `pushSpanOnFreeLists` `:2355`). Above that count, the neighbours' back-links go stale: a latent defect past 65,535 blocks. Write sites: `:171`, `:804`, `:1089-1090`, `:1369-1373`, `:2435-2439`, `:3320-3321`, `:4330-4338`. | `OldGenSpace.cpp` |
| F13 | `Header` word 0 is `tag:5 color:2 pin:1 age:2 unboxed:6 refcount:15 builder:1`. `refcount` is "unused currently", and no runtime or kernel code reads it on a `Tag_Free` cell (`grep -rn refcount runtime/src elm-kernel-cpp/src`: only the declaration and `NurserySpace.cpp`'s verbatim-copy check, which runs on nursery objects). For free cells, `age` bit 0 is the on-free-list sentinel. HPointer addresses are < 2^43 (`POINTER_BITS 40`, 8-byte granules). | `Heap.hpp:164-175`, `:65-67` |
| F14 | TLS reached by GC code: `Allocator::isInNursery` reads `tl_heap_` and is called from `pushMarkRoot` `:1891` and `markOneObject` `:1946`; `g_in_minor_gc` (`GCStats.cpp:29`) is set/cleared at `NurserySpace.cpp:431/1087` and read at `OldGenSpace.cpp:657,685,694,722` and `NurserySpace.cpp:244`; `g_batch_release_depth` (`OldGenSpace.cpp:53`) has 9 references, all in `OldGenSpace.cpp`. `in_phase3_` is **already** a `NurserySpace` member (report §3.1 is stale on it). | as listed |
| F15 | `ThreadLocalHeap` constructs `old_gen_.initialize(parent_, config_)` (`:174`) before `nursery_.initialize(this, config_)` (`:177`). `NurserySpace::contains` is inline (`NurserySpace.hpp:249`). | `ThreadLocalHeap.cpp` |
| F16 | `OldGenSpace::reset()` has **no caller** in runtime or tests. `OldGenSpace` is only ever reached through a `ThreadLocalHeap`: tests use `heap->getOldGen()`. | grep |
| F17 | The tests touching the containers use `OldGenSpaceTestAccess::getBlocks` (`OldGenLazySweepTest.cpp:75,86,218`, `OldGenCapacityTest.cpp:66`, `OldGenSmallClassBudgetTest.cpp:44,249`), `getBufferMeta` (`OldGenCapacityTest.cpp:65`, `OldGenSweepOnDemandTest.cpp:40`) and `blockIndexFor` (`OldGenLazySweepTest.cpp:221`). `getMarkBitsForBlock`, `getLargeBlockMark`, `getEvacuationSet` and `getPageToBlockIndex` have **no** test users. The runtime has one non-friend-file reader of `blocks_`: the validator walk at `NurserySpace.cpp:873`. | grep |
| F18 | `platform::decommit` remaps to `PROT_NONE`: pages become **inaccessible**, not zero. `platform::commitAt` is `mmap(MAP_FIXED, RW)`: applied to an already-committed range, it yields fresh zero pages and drops the old RSS. | `PlatformVirtualMemory_posix.cpp` |
| F19 | `MIN_BUFFER_SIZE = OS_PAGE_SIZE` (4 KiB; 16 KiB on Apple Silicon), so the smallest per-block bitmap is 64 B. | `AllocatorCommon.hpp:727` |
| F20 | This series is runtime-only. The candidate is `$BK/bin/ecoghash.mlir` lowered against the changed runtime (00-P F13). | `benchmarks/gc-opt-loop.md` §2 |

## 3. Design

### 3.1 Identity versus order

```
            BlockTable
  order_  : [ id7, id2, id9, id0, ... ]     positions 0..size()-1, identical semantics to today's blocks_
  pos_of_ : id -> position                  O(1) swap-remove by id
  info_   : id -> BlockInfo                 stable address for the heap's lifetime
  meta_   : id -> BufferMetadata
  lmark_  : id -> uint8_t                   today's large_block_mark_
  live_   : id -> uint8_t                   1 while the id names a block
  free_   : LIFO stack of released ids
```

- **`add(info, meta)`** takes an id from the free stack (LIFO), or else `high_water_++`. It appends
  the id to `order_`, exactly like `push_back`.
- **`swapRemove(id)`** moves `order_[last]` into `pos_of_[id]` and pushes `id` onto the free stack,
  exactly like today's swap-remove of the vector element.
- **`eraseOrdered(id)`** shifts `order_` left, exactly like `vector::erase` (compaction only).
- **`clear()`** empties everything and resets `high_water_` to 0.

Id values never feed a policy, so the recycling order cannot move a counter. Positions come out
of the same operations in the same sequence, so every order-dependent policy sees today's order.

### 3.2 `ReservedArray<T>`

- `reserve(capacity)` reserves `round_up(capacity * sizeof(T), OS_PAGE_SIZE)` bytes of VA with
  `platform::reserveAddressSpace` and commits nothing.
- `ensureCommitted(n)` commits whole chunks (`kCommitChunkBytes = 64 KiB`, rounded to the OS
  page) with `platform::commitAt` until `[0, n)` is addressable. Fresh pages are zero.
- `discard(first, count)` zeroes the range and returns its physical pages. It calls the new
  `platform::resetPagesToZero` on the OS pages wholly inside the range, and `memset`s the partial
  edge pages.
- `release()` returns the reservation (destructor and `reset()`).
- The data pointer is fixed from `reserve` to `release`. There is **no** code path that moves
  data, which is the property later phases rely on.
- `T` must be trivially copyable and trivially destructible (`static_assert`).

### 3.3 Capacity arithmetic

Let `R` = old-gen reservation = `nursery_offset` (F8), and `P` = `alloc_buffer_size`. Every block
is at least `P` bytes and lies inside `R`, so a heap can never hold more than
`max_blocks = R / P + 1` live blocks. That bound sizes every table, **so no table can overflow**.
`BlockTable::add` still aborts with a clear message if it would exceed capacity.

| Table | Bytes per unit | 24 GiB, P = 512 KiB | 8 TB, P = 512 KiB |
|---|---|---|---|
| `info_` + `meta_` + `lmark_` + `live_` + `pos_of_` + `order_` + `free_` | ~80 B per id | 49,153 ids ≈ 3.9 MB VA | 16.8 M ids ≈ 1.3 GB VA |
| `LiveBytesAccumulator` | 8 B per id | 0.4 MB VA | 134 MB VA |
| page index (`{u32, u32}` per slot) | 8 B per slot | 0.4 MB VA | 128 MB VA |
| mark arena (`stride = round_up(P/64, 64)` per id) | 8 KiB per id | 384 MB VA | 128 GB VA |

- All of this is **address space, not memory**. Committed bytes track the high-water live-block
  count, about 1/64 of the old-gen high-water, as today.
- At 8 TB each heap reserves about 130 GB of VA. x86-64 user space is 128 TiB, so about 900 heaps
  could coexist.
- Real Elm programs run one heap. Hoisting the mark arena to one process-wide table is recorded
  as a phase 8 option.

### 3.4 Page index

- The slot for address `p` is `(p - heap_base) / P`, over `[0, R / P + 1)`. It is reserved at
  `initialize()` and committed through `region_end_` wherever `resizePageIndexForRegion` runs
  today.
- Owners are `BlockId`s (`NO_BLOCK_ID` = empty). Blocks are added and removed incrementally, and
  the index is **never rebuilt**. A region-bounds change only recomputes `region_base_` and
  `region_end_`.
- `blockIndexFor` → `blockIdFor`. It keeps today's early `region_base_`/`region_end_` check, so
  its results are identical, and it keeps the slot `< committed` guard. Reading an uncommitted
  slot would SIGSEGV (Trap 4).
- `renamePageIndexSlots` and `rebuildPageIndexFromBlocks` are deleted, and
  `recomputeRegionBoundsAndRebuildIndex` becomes `recomputeRegionBounds`.

### 3.5 Mark-bit arena

- Slot `id` lives at `arena + id * stride`. Each id has a valid length `len_[id]`: the block's
  bitmap bytes for a regular block, 0 for `is_large`. That preserves the load-bearing guard (F9).
- **`assign(id, len)`**, at `materializeBlock`, commits through the slot, `memset`s `len` bytes to
  zero and sets `dirty_[id] = 1`. This is the same zeroing work as today's append.
- **`drop(id)`**, at the flip to `is_large`, zeroes the slot and sets `len_[id] = 0`. This is
  today's `markBitsDropBlock`.
- **`retire(id)`**, at release, sets `len_[id] = 0` and leaves the bytes and `dirty_[id]` alone.
- **`startMark`** replaces the re-pack:
  1. For every **live** id, in order, `memset(slot, 0, len_[id])` and zero `lmark_[id]`. This is
     the same bytes the packed fill zeroes today, so the load-bearing bulk clear is kept.
  2. Then, for maximal runs of **free and dirty** ids below `high_water_`, `discard` the run and
     clear `dirty_`. This returns the RSS that today's re-pack plus `shrink_to_fit` returned: the
     W12 +172 MB hole problem. It costs one syscall per run, per major GC.
- Correctness does **not** depend on `dirty_`: `assign` always zeroes. `dirty_` only decides what
  to discard.
- The bit accessors take a `BlockId`. The four functions `isMarkedInBlock`,
  `testAndSetMarkBitInBlock`, `setMarkBitInBlock` and `testAndClearMarkBitInBlock` keep their
  bodies. Only the address computation changes: `arena + id * stride + byte_index` replaces
  `arena.data() + offset_[i] + byte_index`, one dependent load **fewer**.

### 3.6 Live-bytes accumulator

- `LiveBytesAccumulator` is a `ReservedArray<uint64_t>` indexed by `BlockId`.
- The marker writes **only** the accumulator. `markOneObject` changes
  `buffer_meta_[i].live_bytes += step` to `acc_.add(id, step)`.
- The allocator side writes **only** `BufferMetadata::live_bytes`, at the F10 sites, unchanged.
- **Merge** happens as the first action of `finalizeMetaAfterMark`, the mark→sweep sync point. For
  every live id in order, `meta.live_bytes += acc[id]` and `acc[id] = 0`. The clamp that follows
  runs on the merged value, as today.
- Equivalence: marking is stop-the-world (F11). Between the reset and the merge, the only writers
  are the marker and allocate-black, and both are additions, which commute. The one non-commuting
  writer is `freeLargeBodyCell`'s clamped subtraction. It is reachable mid-mark only from unit
  tests, and while `marking_active` it first folds that id's accumulator entry into `live_bytes`
  (Step 8.4).
- Phase 4 gives each marker thread its own accumulator and merges them all at the same point.
  That is the "per-thread accumulators merged at sync points" of the master plan.

### 3.7 Free-list back-links

`FreeCellMid::prev_in_class` (a `CellHandle`) becomes `uint32_t prev_lo`. `sizeof` stays 24 B.

```
predecessor p (8-aligned, < 2^43)  ->  e = p >> 3  (40 bits)
  prev_lo                            =  e & 0xFFFFFFFF
  header.refcount bits [0, 8)        =  e >> 32
  header.refcount bit 8 (0x100)      =  "no predecessor: head of free_lists_[cls]"
```

- Resolving the predecessor needs **no block metadata**. `classListUnlinkTierM` stops taking the
  blocks table, and the unlink path stops reading `blocks_` at all.
- Every cell with a block context gets Tier-M threading, whatever the block count. The `<= 0xFFFE`
  gates go, and so does the whole `CellHandle` fixup on block moves.
- This is an encoding change only. Which cell is popped, split or coalesced does not change, so
  counters are unaffected.

### 3.8 Per-heap state versus TLS

| TLS item | Reached by collection code? | This phase |
|---|---|---|
| `Allocator::tl_heap_` via `isInNursery` in `pushMarkRoot`/`markOneObject` | yes, per marked object | **convert**: `OldGenSpace::nursery_` (a `const NurserySpace*` bound at heap construction) |
| `g_in_minor_gc` | yes: promotion allocation policy (`minor_sweep_divisor`) and stats | **convert**: `OldGenSpace::in_minor_gc_` + `NurserySpace::in_minor_gc_`, set and cleared at the two existing statements |
| `g_batch_release_depth` | yes: block release | **convert**: `OldGenSpace::batch_release_depth_` |
| `g_scan_parent/tag/size`, `g_push_origin` | validator diagnostics only | **keep TLS.** They describe what *this worker* is scanning or pushing, and per-thread is the correct semantics for a parallel collector. Record the rationale in a comment |
| `g_first_push_origin` (a validator map) | validator diagnostics only | keep TLS for now. Phase 6 (parallel promotion) revisits it; recorded in P§10 |
| `in_phase3_` | — | already a member; no change |
| `eco_tl_bump_state`, `eco_tl_root_*`, `ListScratch`, the unwind `Context` | mutator-only by design (§3.3) | keep; state that they are mutator-only in HEAP_053 |

### 3.9 Hot paths and what they cost after the change

| Path | Frequency | Before | After |
|---|---|---|---|
| `pushMarkRoot` → `blockIndexFor` → test-and-set | 1.9×10⁸ per self-compile | `tl_heap_` load; region check; slot load; `blocks_` bounds; `offset_[i]` load; len check | nursery bounds from `this`; region check; slot load; `id != NO_BLOCK_ID`; **no offset load**; len check |
| `markOneObject` live attribution | 1.9×10⁸ | `buffer_meta_[i].live_bytes +=` (24 B stride) | `acc[id] +=` (8 B stride, denser) |
| promotion `allocate` → free-list pop | 6.8×10⁸ | `g_in_minor_gc` TLS load; Tier-M head repaint = 4 B store | member load; head repaint = one header-word bitfield store |
| mid-cycle `initObjectHeaderWithSize` | per mutator alloc during sweep | `blockIndexFor` + set + meta add | same shape with ids |

None adds a branch. The candidates for a measurable change are the head-repaint store and the
extra `order_[pos]` indirection in per-block loops. Both are cold relative to the per-object
paths.

### 3.10 Inventory: report §3.5, row by row

| §3.5 structure | Disposition in this phase |
|---|---|
| `blocks_` (vector; push/swap-remove) | **fixed**: `BlockTable` (D4) |
| `mark_bits_arena_` (reallocating, re-packed) | **fixed**: per-id arena (D6) |
| mark bits: plain byte RMW | unchanged. Single writer this phase; phase 4 makes it `fetch_or`. The flat per-id address is its prerequisite |
| `buffer_meta_[i].live_bytes` from both sides | **fixed**: accumulator plus merge (D7) |
| `page_to_block_index_`, `large_block_mark_`, `region_end_` | index **fixed** (D5); `large_block_mark_` → `BlockTable::lmark_` (D4); `region_base_/region_end_` stay owner-written. A collector copies them at t0 (phase 5a) |
| `free_lists_[]`, Tier-M back-links | back-links made block-independent (D2); the lists stay owner-only. Phase 2 hands whole blocks to promotion buffers |
| `large_body_index_`, `free_large_blocks_`, `unassigned_blocks_` | stay owner-only `std::` containers, **documented** as such in HEAP_048; `free_large_blocks_` now holds ids |
| `GCStats` counters | already three mergeable objects (00-P F1); per-thread instances arrive with phase 3 |
| mark stack, `nursery_visited_` | owner/marker-only; entries now carry `BlockId`; phase 4 replaces them with deques |

## 4. Steps

Do the steps in order. Each ends building and passing `cmake --build build --target check`, and
the steps marked **[C]** also end in a checkpoint run (P§5).

- Take the snapshot first: `benchmarks/lss-loop-snap.sh snap try-TG1-pre "threaded-gc-01 start"`.
- There is no working git in the container (`benchmarks/gc-opt-loop.md` §1).
- Name every intermediate lowered binary `eco-optTG1-cN`.

### Step 1 — D1: per-heap state replaces GC-path TLS [C]

**Files:** `OldGenSpace.hpp/.cpp`, `NurserySpace.hpp/.cpp`, `ThreadLocalHeap.cpp`,
`GCStats.hpp/.cpp`.

1. **Nursery membership.**
   - Add `const NurserySpace* nursery_ = nullptr;` and a public
     `void bindNursery(const NurserySpace* n) { nursery_ = n; }` to `OldGenSpace`.
   - In the `ThreadLocalHeap` constructor, call `old_gen_.bindNursery(&nursery_);` right after
     `nursery_.initialize(this, config_)` (F15).
   - `#include "NurserySpace.hpp"` in `OldGenSpace.cpp`.
   - Replace the **two** `allocator_ref_->isInNursery(obj)` calls (assert the count is 2):
     `pushMarkRoot` becomes `nursery_->contains(obj)`, and `markOneObject` becomes
     `nursery_ != nullptr && nursery_->contains(obj)`. The second keeps the existing null guard's
     shape.
   - Under `#if ECO_HEAP_VALIDATE`, at both sites, `assert(nursery_->contains(obj) ==
     allocator_ref_->isInNursery(obj))`. This re-derives the "calling thread's heap == this heap"
     premise that HEAP_007 guarantees today.
   - `allocator_ref_` stays: it is still used for `isInHeap`, which reads no TLS.
2. **In-minor-GC flag.**
   - Add `bool in_minor_gc_ = false;` to `OldGenSpace` (public `setInMinorGC(bool)`) and to
     `NurserySpace`.
   - At `NurserySpace.cpp:431`, replace `g_in_minor_gc = true;` with
     `in_minor_gc_ = true; oldgen.setInMinorGC(true);`. At `:1087`, clear both the same way.
     Keep the **exact** statement positions (early returns between them, if any, behave as
     today).
   - Replace the four reads in `OldGenSpace.cpp` (`:657, :685, :694, :722`) with `in_minor_gc_`,
     and the read at `NurserySpace.cpp:244` with the nursery's own flag.
   - Delete the global (`GCStats.cpp:29`, `GCStats.hpp:44`). Then
     `grep -rn g_in_minor_gc runtime elm-kernel-cpp eco-kernel-cpp test` must return nothing.
3. **Batch-release depth.**
   - Replace the TLS `g_batch_release_depth` (9 references, all in `OldGenSpace.cpp`) with a
     member `int batch_release_depth_ = 0;`, zeroed in `reset()`.
   - Keep its comment, moved to the member.
4. **Audit.**
   - List every `Allocator` method whose body reads `tl_heap_`:
     `grep -n 'tl_heap_' runtime/src/allocator/Allocator.{hpp,cpp}`.
   - `grep` for calls to each of them from `OldGenSpace.cpp`, `NurserySpace.cpp`,
     `ThreadLocalHeap.cpp` (GC functions only) and `RootSet.cpp`.
   - Any hit inside collection code (evacuate, scan, mark, sweep, release, promotion allocate) is
     converted the same way. Record the audit's result, even if it is "none", in P§6a.
5. Add the "stays TLS, per-worker semantics" comment above `g_scan_parent` (`NurserySpace.cpp:65`)
   and `g_push_origin` (`OldGenSpace.cpp:71`) (P§3.8).

**Checkpoint C1.**

### Step 2 — D2: address-encoded free-list back-links [C]

**Files:** `OldGenSpace.hpp/.cpp`.

1. In `OldGenSpace.hpp`:
   - Delete `CellHandle` and `HEAD_SENTINEL`.
   - Change `FreeCellMid::prev_in_class` to `uint32_t prev_lo;` and keep the `static_assert`s on
     24 B and on the `next_in_class` offset.
   - Rewrite the block comment (`:95-126`) to describe P§3.7 and delete the "max 65,535 blocks"
     bound.
   - Add `static_assert(POINTER_BITS == 40, "back-link encoding assumes heap addresses < 2^43")`.
2. In the anonymous namespace of `OldGenSpace.cpp`, replace `resolveHandle` with:
   ```cpp
   // P§3.7: predecessor address >> 3 in 40 bits — low 32 in prev_lo, high 8 in
   // header.refcount[0,8). refcount bit 8 = "head of its class list". refcount
   // is unused on Tag_Free cells (F13); only these three helpers touch it.
   constexpr u32 kPrevHiMask  = 0xFFu;
   constexpr u32 kPrevHeadBit = 0x100u;
   inline void setPrevHead(FreeCellMid* m) { m->header.refcount = kPrevHeadBit; m->prev_lo = 0; }
   inline void setPrev(FreeCellMid* m, const FreeCell* pred) {
       const uint64_t e = reinterpret_cast<uintptr_t>(pred) >> 3;
       m->prev_lo = static_cast<uint32_t>(e);
       m->header.refcount = static_cast<u32>(e >> 32) & kPrevHiMask;
   }
   inline FreeCell* getPrev(const FreeCellMid* m) {
       if (m->header.refcount & kPrevHeadBit) return nullptr;
       const uint64_t e = (uint64_t(m->header.refcount & kPrevHiMask) << 32) | m->prev_lo;
       return reinterpret_cast<FreeCell*>(e << 3);
   }
   ```
3. Rewrite each write site from F12:
   - `m->prev_in_class = CellHandle::head()` → `setPrevHead(m)`;
   - `x->prev_in_class = CellHandle{b, encodeOff(blk, cell)}` → `setPrev(x, cell)`;
   - `succ->prev_in_class = m->prev_in_class` (unlink) → copy **both** halves:
     `succ->prev_lo = m->prev_lo; succ->header.refcount = m->header.refcount & (kPrevHiMask|kPrevHeadBit);`.
     Wrap that in `copyPrev(dst, src)` and use it at `:171` and `:1089-1090`.
   - Check the count first: there must be exactly 7 `prev_in_class` write sites (F12). Any extra
     site is a premise failure. Stop and re-read.
4. `classListUnlinkTierM` drops its `blocks` parameter and uses `getPrev`. Update its callers:
   `removeFreeCellsForBlock` and any other `grep -n classListUnlinkTierM` site.
5. Delete the Tier-M gates:
   - `populateFromBlock` `:1353`: `tier_m = isTierMSize(cell_bytes)`;
   - `pushSpanOnFreeLists` `:2355`: `can_thread = (block != nullptr)`.
   - Delete the `b_idx16` locals.
6. Delete the `CellHandle` fixup block in `fixupIndicesAfterBlockMove` (`:3295-3327`). An address
   does not change when its block's index does.
7. In `freeEvacuatedBuffers`' rebuild loop (`:4311-4345`), rebuild the back-links with
   `setPrevHead` / `setPrev(m, prev_kept)`. The loop is still needed: the filter pass removed
   cells, so a kept cell's predecessor may be gone. Keep the re-threading onto the block.
8. **Validator V6** (`ECO_HEAP_VALIDATE`): add `validateFreeListBackLinks()`.
   - It walks every class list. For each Tier-M cell, `getPrev(c)` must equal the actual
     predecessor, or `nullptr` at the head.
   - Call it at the end of `finishMarkAndSweep`, and after every `maybeShrinkCapacity` or
     `reclaimAllDeadBlocksFromMeta` batch.
   - Abort with the class, depth, and both addresses.
9. **Unit test** `test/allocator/FreeListBackLinkTest.cpp`, registered in `test/main.cpp` like its
   neighbours:
   - encode/decode round-trips for `0x8`, `(1ull<<35) - 8`, `1ull<<35`, `(1ull<<43) - 24`, and
     the head sentinel;
   - a pop → split → re-push sequence on a small heap, checking `getPrev` consistency with V6's
     function.

**Checkpoint C2.**

### Step 3 — D3: `ReservedArray<T>` and a zero-reset primitive

**Files:** new `runtime/src/allocator/ReservedArray.hpp`; `PlatformVirtualMemory.hpp`,
`PlatformVirtualMemory_posix.cpp`, `PlatformVirtualMemory_win32.cpp`; new
`test/allocator/ReservedArrayTest.cpp`.

1. Add `bool resetPagesToZero(void* addr, std::size_t size);` to `platform`. Its contract: the
   pages stay committed and read/write, read as zero afterwards, and their physical memory is
   returned.
   - **POSIX:** `mmap(addr, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED|MAP_NORESERVE, -1, 0) == addr`.
     This is correct on both Linux and Darwin. Darwin's `MADV_DONTNEED` does not guarantee
     zeros, so do not use `madvise`.
   - **Win32:** `VirtualFree(addr, size, MEM_DECOMMIT)`, then `VirtualAlloc(addr, size,
     MEM_COMMIT, PAGE_READWRITE) == addr`.
   - `addr` and `size` must be OS-page aligned (assert).
2. Write `ReservedArray<T>` as specified in P§3.2. Required members:
   - `reserve(size_t capacity) -> bool`, `release()`;
   - `ensureCommitted(size_t n)`, `discard(size_t first, size_t count)`;
   - `operator[]`, `data()`, `capacity()`, `committed()`.
   - `operator[]` asserts `i < committed_` in debug builds only. No release-build check: callers
     guarantee it.
   - `ensureCommitted` aborts with `[oldgen] ReservedArray commit failed (n=…, cap=…)` on
     failure. Callers cannot recover from losing metadata.
   - Non-copyable and non-movable.
3. Tests, in `ReservedArrayTest.cpp`:
   1. `data()` is unchanged across 1,000 `ensureCommitted` growths, and new elements read zero.
   2. `discard` zeroes a range that straddles page edges, and neighbours keep their values.
   3. **Scale, Linux only** (`#ifdef __linux__`, else skip with a message):
      - reserve a `ReservedArray<uint8_t>` of 128 GiB (the 8 TB mark arena) and a
        `ReservedArray<std::array<uint8_t,80>>` of 16,777,217 elements (the 8 TB block table);
      - touch elements `0`, `capacity/2` (after `ensureCommitted`) and the last;
      - assert that `VmRSS` from `/proc/self/status` grew by less than 16 MiB. If `reserve`
        itself fails (a restricted-VA CI box), print `SKIP` and pass.

### Step 4 — D4: `BlockId` and `BlockTable` (standalone)

**Files:** new `runtime/src/allocator/BlockTable.hpp` (header-only is fine); new
`test/allocator/BlockTableTest.cpp`.

1. Define the types:
   ```cpp
   struct BlockId {
       uint32_t v;
       static constexpr uint32_t kNone = UINT32_MAX;
       constexpr bool valid() const { return v != kNone; }
       friend constexpr bool operator==(BlockId a, BlockId b) { return a.v == b.v; }
       friend constexpr bool operator!=(BlockId a, BlockId b) { return a.v != b.v; }
   };
   inline constexpr BlockId NO_BLOCK_ID{BlockId::kNone};
   ```
   Give it no implicit conversion from or to integers. Use `BlockId{n}` and `.v` explicitly.
2. Move `BlockInfo` and `BufferMetadata` out of `OldGenSpace.hpp` into `BlockTable.hpp`,
   unchanged. `OldGenSpace.hpp` then includes it.
3. `BlockTable` has the members of P§3.1, each a `ReservedArray`: `info_`, `meta_`, `lmark_`,
   `live_`, `pos_of_`, `order_` and `free_`, plus `size_t size_`, `free_count_` and
   `uint32_t high_water_`. Public API:
   ```cpp
   bool   reserve(size_t max_blocks);   // all arrays, VA only
   void   releaseStorage();
   size_t size() const;                 // live count == order length
   size_t capacity() const;
   uint32_t highWater() const;
   BlockId idAt(size_t pos) const;      // order_[pos]
   size_t  posOf(BlockId) const;
   bool    isLive(BlockId) const;
   BlockInfo&      info(BlockId);       const BlockInfo&      info(BlockId) const;
   BufferMetadata& meta(BlockId);       const BufferMetadata& meta(BlockId) const;
   uint8_t&        largeMark(BlockId);
   BlockId add(const BlockInfo&, const BufferMetadata&);  // LIFO free id, else high_water_++
   void    swapRemove(BlockId);
   void    eraseOrdered(BlockId);
   void    clear();
   ```
   - `add` commits each array through the new id (`ensureCommitted(id+1)`, and `order_` through
     `size_+1`).
   - `add` sets `lmark_ = 0` and `live_ = 1`.
   - `add` **aborts** if `high_water_ == capacity()` and the free stack is empty. By P§3.3 that
     is unreachable, so reaching it is a bug report, not an OOM path.
   - The accessors `assert(isLive(id))` in debug builds.
4. Tests, in `BlockTableTest.cpp`:
   1. **Order equivalence (the key test).** Apply a seeded random sequence of 200,000 operations
      (add 55 %, swapRemove at a random position 40 %, eraseOrdered 5 %) both to a `BlockTable`
      and to a `std::vector<Tag>` model, where `Tag` is a unique serial stored in
      `BlockInfo::start`. After every operation, `idAt(pos)`'s `info.start` must equal
      `model[pos]` for every position, and `posOf(idAt(p)) == p`.
   2. Ids are stable: an id's `info()` address never changes while it is live.
   3. More than 65,536 simultaneously live ids work (fake extents; no memory behind them).
   4. `clear()` resets the high water mark, and the next id is `0`.

### Step 5 — D4 wired in: `BlockTable` replaces `blocks_`, `buffer_meta_`, `large_block_mark_` [C]

This is the large mechanical step. Do it in the sub-steps below, and build after each.

**Files:** `OldGenSpace.hpp/.cpp`, `Allocator.cpp` (F7), `NurserySpace.cpp` (the `:873` walk),
and the tests from F17.

**5.1 — Consolidate the four push sites (pure refactor, still on vectors).**
- Add `size_t materializeBlock(const BlockInfo& bi, const BufferMetadata& m, size_t mark_bytes)`.
  It performs the push, the meta push, `markBitsAppendForBlock(mark_bytes)`, the `lmark` push and
  `assignPageIndexForBlock`, and returns the index.
- Replace the four sites (F1). `allocateLargeBlock` passes `mark_bytes = 0` and does its region
  update **before** the call, because it currently assigns the page index after
  `resizePageIndexForRegion`. Preserve that order.
- Fix the `:272` comment: the capacity check now lives in `BlockTable::add`.
- Build and run `--target check`. No checkpoint is needed here.

**5.2 — Swap the containers.**
- Replace `std::vector<BlockInfo> blocks_`, `std::vector<BufferMetadata> buffer_meta_` and
  `std::vector<uint8_t> large_block_mark_` with `BlockTable blocks_`.
- In `initialize()`, reserve `max_blocks = R / P + 1`. Add a public getter
  `size_t Allocator::getOldGenReservationBytes() const { return nursery_offset; }` (F8), and
  `assert(allocator_ != nullptr)`, since every real path has one (F16).
- The destructor calls `releaseStorage()`.
- `reset()`: `clear()`. If `alloc_buffer_size` changed, release and re-reserve (F16: no caller
  today; keep it correct).
- Then let the compiler drive the change. Use this translation table:

| Today | After |
|---|---|
| loop `for (size_t i = 0; i < blocks_.size(); ++i)` using `blocks_[i]` / `buffer_meta_[i]` | keep the loop over `pos`; first line `const BlockId id = blocks_.idAt(pos);` then `blocks_.info(id)` / `blocks_.meta(id)` |
| `for (auto& b : blocks_)` / `for (const auto& b : blocks_)` | position loop as above (NurserySpace `:873` too) |
| back-to-front loops that release (`reclaimAllDeadBlocksFromMeta`, shrink pass 2) | keep them back-to-front **over positions**; take `idAt(pos)` fresh each iteration (the swap-remove moves `order_[last]`, exactly as today) |
| `blockIndexFor(obj)` returning `size_t`, `>= blocks_.size()` = not found | `blockIdFor(obj)` returning `BlockId`, `NO_BLOCK_ID` = not found (Step 6 rewrites its body; for now it translates the old result) |
| `idx < blocks_.size()` validity checks on a stored or looked-up index | `id != NO_BLOCK_ID` (+ `assert(blocks_.isLive(id))`) |
| `buffer_meta_.size()` comparisons (29 sites) | delete. Meta exists for every live id by construction; keep one `assert` in `resetBufferMetaForMark` |
| `buffer_meta_.resize(blocks_.size(), …)` (`resetBufferMetaForMark` `:1996`, `prepareMetaForLazySweep` `:2108`) | delete, with the assert above (W9's invariant makes them no-ops today) |
| `large_block_mark_[i]` | `blocks_.largeMark(id)` |
| `&blocks_.back()` after a push | `&blocks_.info(id)` |
| `MarkStackEntry::block_index` (`uint32_t`) | `BlockId block`; `NO_BLOCK_U32` → `NO_BLOCK_ID` |
| `markOneObject(void*, uint32_t)` | `markOneObject(void*, BlockId)` |
| `free_large_blocks_` (`vector<size_t>` of indices) | `std::vector<BlockId>`; same push/swap-remove code |
| `evacuation_set_`, `evac_block_index_` | `std::vector<BlockId>`, `BlockId` (`NO_BLOCK` → `NO_BLOCK_ID`) |
| `sweep_buffer_index_`, `fixup_buffer_index_` | **stay positions** (`size_t`) |
| every `size_t block_index` parameter (14 in `.cpp`, 14 in `.hpp`) | `BlockId` (`onUniformBlockDedicated`, `onBlockReleased`, `onBlockTransitioningToLarge`, `markBlockAsFreeLarge`, `markBlockFullySwept`, `releaseBlockToAllocator`, `removeFreeCellsForBlock`, `isInEvacuationSet`, `assign/clearPageIndexForBlock`, `pushSpanOnFreeLists`, `flushRun`, …) |
| `findBlockContaining` | loop over positions |

**5.3 — Release without renaming.** In `releaseBlockToAllocator(BlockId id)`:
- Read `pos = blocks_.posOf(id)` and `last = blocks_.size() - 1` **before** removing.
- Call `blocks_.swapRemove(id)` in place of the three swap-remove blocks for `blocks_`,
  `buffer_meta_` and `large_block_mark_`. The mark-arena swap block stays until Step 7.
- Replace the `fixupIndicesAfterBlockMove(last, block_index)` call with
  `fixupCursorsAfterOrderMove(last, pos)`. It holds only the two position cursors'
  `if (x == old) x = new;` lines.
- Delete `fixupIndicesAfterBlockMove`: the id-valued fields no longer move.
- The `sweep_pending_blocks_` decrement, `removeFreeCellsForBlock`, the `free_large_blocks_`
  scrub, the `large_body_index_` scrub and the page-index clear stay **in their current order,
  before** the removal.

**5.4 — Compaction.**
- `selectEvacuationSet` returns ids.
- `freeEvacuatedBuffers` erases each evacuated id with `blocks_.eraseOrdered(id)`. The result is
  independent of processing order, so the descending sort may stay or go.
- Before erasing, clear each id's page-index slots. Today the code relies on the rebuild instead,
  which Step 6 deletes.
- `evac_block_index_`: set it to `NO_BLOCK_ID` if it was erased. Delete the "decrement if
  greater" branch, since ids do not shift.
- Every `isInEvacuationSet(x)` caller must pass an **id**. `fixReferencesSlice` iterates
  positions, so it converts with `idAt`. Grep every caller and check each.

**5.5 — Test access.**
- Replace `getBlocks` / `getBufferMeta` with `blockCount(og)`, `blockIdAt(og, pos)`,
  `blockInfoAt(og, pos)` and `bufferMetaAt(og, pos)`. Positions match the old vector
  subscripts, so the tests keep their meaning.
- Change `blockIndexFor(og, p)` to return `BlockId`. Update the F17 call sites. The
  "`blockIndexFor` agrees with linear scan" test compares the returned id with a linear scan
  over positions that returns `idAt(pos)`.
- Update `getLargeBlockMark`, `getMarkBitsForBlock` and `getEvacuationSet` to ids (they have no
  users).
- Update `Allocator::ensureOldGenCapacityFor` if the compile demands it (F7). It touches only
  `unassigned_blocks_`, the region fields and `resizePageIndexForRegion`.

**Checkpoint C3.**

### Step 6 — D5: page index over the whole reservation [C]

**Files:** `OldGenSpace.hpp/.cpp`, `Allocator.cpp`.

1. Replace `std::vector<PageOwners> page_to_block_index_` with
   `ReservedArray<PageOwners> page_index_`, where `struct PageOwners { BlockId primary, secondary; }`
   (8 B). Add the member `char* index_base_` (= `allocator_->getHeapBase()`), and
   `size_t index_slots_ = R / P + 2`, which covers a large block straddling the last slot.
   Reserve both in `initialize()`.
2. Slot math is `(p - index_base_) / P` in `firstPageIndex`, `lastPageIndex` and `blockIdFor`.
   `region_base_` no longer appears in slot arithmetic.
3. `resizePageIndexForRegion()` becomes `commitPageIndexThrough(region_end_)`, which calls
   `page_index_.ensureCommitted(slotOf(region_end_ - 1) + 1)`. Keep its call sites, including
   `Allocator.cpp` (F7). Newly committed slots are zero, so **`NO_BLOCK_ID` must not be zero**.
   Either store owners as `id + 1` (with 0 = empty), or explicitly fill newly committed slots
   with `NO_BLOCK_ID`. **Use `id + 1`.** Zero-fill is then correct for free, and the conversion
   lives in two helpers, `encodeOwner` and `decodeOwner`.
4. `blockIdFor(obj)` keeps its structure (F5):
   1. the region-bounds early-out;
   2. slot `< page_index_.committed()` (**required**: Trap 4);
   3. primary, then secondary, each with the extent check.
5. `assignPageIndexForBlock` and `clearPageIndexForBlock` keep their two-owner logic, on ids.
   Under `ECO_HEAP_VALIDATE`, `assign` aborts if both owners are already occupied by live
   **other** blocks: F6 says that cannot happen, and today the code silently overwrites.
6. Delete `rebuildPageIndexFromBlocks` and `renamePageIndexSlots`. Rename
   `recomputeRegionBoundsAndRebuildIndex` to `recomputeRegionBounds`: the same min/max scan, no
   rebuild. Update its callers and comments: the shrink batch end, the single-release tail, and
   `releaseUnassignedBlockToAllocator`.
7. **Validator V2** (`validatePageIndex()`), called wherever V6 is:
   - every live id's covered slots name it;
   - every committed slot's owners are live ids whose extent intersects the slot.

**Checkpoint C4.**

### Step 7 — D6: per-id mark-bit arena [C]

**Files:** `OldGenSpace.hpp/.cpp` (a small `MarkBitArena` class may live in `BlockTable.hpp`).

1. Replace `mark_bits_arena_`, `mark_bits_offset_` and `mark_bits_len_` with `MarkBitArena`:
   - storage: `ReservedArray<uint8_t> bytes_` (capacity `max_blocks * stride_`),
     `ReservedArray<uint32_t> len_` and `ReservedArray<uint8_t> dirty_`;
   - `stride_ = round_up(P / 64, 64)` bytes, computed in `initialize()`;
   - API: `reserve(max_blocks, stride)`, `uint8_t* slot(BlockId)`, `uint32_t len(BlockId)`,
     `assign(BlockId, uint32_t len)`, `drop(BlockId)`, `retire(BlockId)`, and
     `clearForMark(const BlockTable&)` (P§3.5).
   - The arena is a single `ReservedArray`, so a slot's address is fixed. Assert
     `len <= stride_` in `assign`.
2. `materializeBlock` calls `mark_.assign(id, mark_bytes)`, and the flip to large calls
   `mark_.drop(id)`. The release calls `mark_.retire(id)` in place of the arena swap block, and
   compaction's erase calls it too.
3. The four bit functions (`.hpp:1106-1181`) take `BlockId`. Their byte reference is
   `mark_.slot(id)[byte_index]` and their guard is `byte_index >= mark_.len(id)`. Their
   `is_large` branches use `blocks_.largeMark(id)`. The leading `block_index >= blocks_.size()`
   check becomes `if (!id.valid()) return false;`.
4. In `startMark`, replace the re-pack block (`:1596-1621`), including both `std::fill`s, with
   `mark_.clearForMark(blocks_)`:
   - for each position, `memset(slot(id), 0, len(id))` and `largeMark(id) = 0`;
   - then scan ids `[0, highWater)` for maximal runs where `!isLive && dirty`, call
     `bytes_.discard(run_first * stride_, run_len * stride_)`, and clear `dirty_` over the run.
   - **Keep the long comment about carry-over bits (F9).** Update only the re-pack paragraph.
5. **Validator V4:**
   - after `clearForMark`, every live slot's first `len` bytes are zero;
   - every free id has `len == 0`;
   - every `is_large` live id has `len == 0`.
   This is the assertion W11b asked to be kept, now over the new layout.

**Checkpoint C4b.** Also compare max RSS against the control (P§7 criterion R).

### Step 8 — D7: marker-side live-bytes accumulator [C]

**Files:** `OldGenSpace.hpp/.cpp`, `BlockTable.hpp`.

1. Add `class LiveBytesAccumulator { ReservedArray<uint64_t> bytes_; … }` with
   `reserve(max_blocks)`, `add(BlockId, uint64_t)` (commit through the id, then `+=`),
   `take(BlockId) -> uint64_t` (read and zero) and `mergeInto(BlockTable&)`.
   - `add` must not branch on commit in the hot path. Commit the accumulator through `id + 1` in
     `materializeBlock` instead, so `add` is a plain `+=`.
2. Add the member `LiveBytesAccumulator mark_live_;`. In `markOneObject`, replace
   `buffer_meta_[…].live_bytes += step` (F10 `:1984`) with `mark_live_.add(id, step)`.
3. `finalizeMetaAfterMark`: its **first** statement becomes `mark_live_.mergeInto(blocks_);`
   (position order, `meta.live_bytes += take(id)`). Everything after it is unchanged.
4. `freeLargeBodyCell` (F10 `:4656`): before the clamped subtraction, add
   `if (marking_active) blocks_.meta(id).live_bytes += mark_live_.take(id);`. That is reachable
   only from hand-driven unit tests (F11), and keeps them exact.
5. `resetBufferMetaForMark`: under `ECO_HEAP_VALIDATE`, assert every live id's accumulator entry
   is zero. That is **validator V5**, the merge-completeness check from the previous cycle.
6. The accumulator is per-marker by design. Add a comment naming phase 4 as the place where there
   are N of them, merged at the same statement.

**Checkpoint C5.** This is the last checkpoint, and it runs the full candidate.

### Step 9 — D8: the remaining validators and the validate-tree gates

**Files:** `OldGenSpace.cpp` (all `#if ECO_HEAP_VALIDATE`).

1. **V1 `validateBlockTable()`:**
   - `order_` and `pos_of_` are a bijection over live ids;
   - `size() + freeCount == highWater`;
   - free ids are not live and are unique on the stack.
2. **V3 `validateStoredBlockRefs()`:**
   - every `free_large_blocks_` entry is live and `is_large`;
   - `evac_block_index_` is `NO_BLOCK_ID` or live;
   - every `evacuation_set_` entry is live;
   - `sweep_buffer_index_ <= size()` and `fixup_buffer_index_ <= size()`.
   V3 replaces the invariant that `fixupIndicesAfterBlockMove` maintained.
3. **V7 `validateStorageStable()`:**
   - Record every `ReservedArray::data()` in `initialize()`.
   - Assert that each is unchanged. This is trivially true by construction, but it is the stated
     property, and it is cheap.
4. One entry point, `validateOldGenMetadata(const char* where)`, runs V1, V2, V3, V6 and V7.
   Call it:
   - at the end of `finishMarkAndSweep`;
   - at the end of `maybeShrinkCapacity`, `reclaimAllDeadBlocksFromMeta` and
     `freeEvacuatedBuffers`;
   - and at the end of every 64th minor GC, counted by a member counter (deterministic).
   V4 and V5 run where Steps 7 and 8 put them.
5. Run the validate-tree gates (P§6 G5) before starting the timed runs.

### Step 10 — Scale tests (the exit criterion)

**Files:** `test/allocator/OldGenScaleTest.cpp`.

1. Make the geometry a pure function, e.g. a `static` helper in `OldGenSpace`:
   `OldGenGeometry geometryFor(size_t reservation_bytes, size_t page)`. It returns `max_blocks`,
   `index_slots`, `stride` and the reserved bytes per table.
   - Assert the P§3.3 column for 8 TB at P = 512 KiB: `max_blocks = 16,777,217`, and so on.
   - `initialize()` must use this function, so the test covers the real arithmetic.
2. On Linux, `reserve` every table at the 8 TB geometry in a standalone `BlockTable` +
   `MarkBitArena` + page index + accumulator. Add three blocks with fake extents high in the
   range (for example at 7 TB), mark a bit in each, and assert that the `VmRSS` growth is under
   16 MiB. Skip, as in Step 3, if VA is restricted.
3. On a real heap with a small `alloc_buffer_size` config, push the block count past 65,536
   **ids**. Use the table directly if a real heap would need too much memory, and **say so in the
   test comment**. Then run V1 and V6.

### Step 11 — D9: invariants and documentation

1. Add rows HEAP_048–HEAP_053 (P§8) to `design_docs/invariants.csv`. First confirm the numbers are
   free: `grep -c '^HEAP_04[89]\|^HEAP_05' design_docs/invariants.csv` must print 0.
2. `THEORY.md` §"Big Bag of Pages" / old-gen metadata:
   - blocks have stable ids; iteration order is separate;
   - the page index is keyed from `heap_base`;
   - the mark arena uses per-id slots;
   - the live-bytes accumulator.
   One paragraph, with pointers to the invariants.
3. `OldGenSpace.hpp` class comment: add "metadata storage is VA-reserved and never moves
   (HEAP_048)".
4. Update the stale comments this phase touches:
   - `BlockInfo::free_cells_in_block`'s "independent of `std::vector` reallocation";
   - `MarkStackEntry`'s "CellHandle bounds blocks_ at 65,535";
   - `blockIndexFor`'s nonexistent "linear fallback".

## 5. Checkpoint procedure (C1 … C5)

A checkpoint is one cheap self-compile. Its only purpose is to localise a counter divergence to
one step. It is not a timing run.

```bash
BK=build/compiler/build-kernel; BOOT=build/runtime/src/codegen/eco-boot-native
cmake --build build --target eco-boot-native
ls -l --time-style=full-iso build/runtime/src/codegen/CMakeFiles/EcoRuntimeStatic.dir/__/allocator/*.o | head   # relink really happened (trap 3 of 00-P§6)
$BOOT "$BK/bin/ecoghash.mlir" -o "$BK/bin/eco-optTG1-cN"
# One run of the gc-opt-loop.md §2 Phase-2 loop body with ARM=eco-optTG1-cN, R=1
```

- **Once per session, before C1**, run the same loop body once with `ARM=eco-optT01`. That is the
  same-session control (00-P§6a.1).
- **Pass:**
  - `cmp "$BK/bin/eco-optTG1-cN-r1-out.mlir" "$BK/bin/ecoghash.mlir"` succeeds;
  - `diff` of `grep -E 'Minor GC cycles:|Major GC cycles:|totals: promoted|allocated|copied'` over
    the two stdouts is empty;
  - the Major GC Event Log's promoted and mark-unit columns are equal.
- **Fail:** stop. The divergence is inside this step. Bisect within the step. Do not continue and
  hope that a later step cancels it.

## 6. Gates

Run these after Step 11, in order. They are correctness gates, separate from the timed runs.

| # | Gate | Command / check | Pass condition |
|---|---|---|---|
| G1 | Runtime unit tests | `cmake --build build --target test && build/test/test` | all pass, including `ReservedArray*`, `BlockTable*`, `FreeListBackLink*`, `OldGenScale*` |
| G2 | Elm unit tests | `cmake --build build --target elm-tests` | same pass/fail set as the reference |
| G3 | E2E | `cmake --build build --target full 2>&1 \| tee /tmp/test_output.txt`, run **once** (CLAUDE.md) | all pass (1731/1731 at T00) |
| G4 | GC-pressure stress | `ECO_HEAP_CONFIG=/work/benchmarks/heap-config-gc-pressure.json cmake --build build --target stress` | 100/100, **and** the banner shows ≳1,000 minor cycles; the default config runs zero |
| G5 | Heap validator: unit tests, E2E and GC-pressure stress | validate tree (`-DECO_HEAP_VALIDATE=ON`); build `test`, `ecoc` **and `EcoRuntimeStatic` explicitly** (the W11b trap: `--target ecor` fails to link there and leaves a stale archive). Run G1, G3 and G4 there, only after the main tree is fully built (00-P§6a.7). **No validator self-compile** (too slow; P§9a.11) | green, and no `[heap-validate]` line in any output |
| G6 | Release / stats-off build | `cmake --preset build -B build-nostats -DECO_GC_STATS=OFF && cmake --build build-nostats --target ecoc` (the release preset cannot configure on this machine, 00-P§6a.2) | builds |
| G7 | Static check: no reallocating per-block storage | `grep -nE 'std::vector<(BlockInfo\|BufferMetadata\|PageOwners)>\|mark_bits_offset_\|mark_bits_arena_\|page_to_block_index_\|CellHandle\|g_in_minor_gc\|g_batch_release_depth' runtime/src/allocator/*.{hpp,cpp}` | no output |
| G8 | Counters, determinism, fixed point | the P§7 triples | counters identical in all six runs and equal to the control; all `out.mlir` identical to `ecoghash.mlir` |

## 7. Measurement

Use the Phase-2 loop of `benchmarks/gc-opt-loop.md` §2, strictly serial, on an idle machine:

- **Control:** `ARM=eco-optT01`, R = 1, 2, 3.
- **Candidate:** `ARM=eco-optTG1` (the final lowering), R = 1, 2, 3.

Record wall, GC, minor, major, **mark** and **sweep** (from the Major GC Event Log block in the
banner: the six lines after the `at(s) total mark` header, per the W12c correction), max RSS,
the counters, and the `out.mlir` bytes.

**Pause data.** The standing rule asks for max pause, p99 pause and MMU. Those need the
phase-timer instruments.
- Build `build-phasetimers` (`-DECO_GC_PHASE_TIMERS=ON`) with this phase's runtime.
- Lower `ecoghash.mlir` into `eco-optTG1pt` and run it once with
  `ECO_GC_EVENT_LOG=$PWD/eco-optTG1pt-r1.gclog.tsv`.
- Compare against `eco-optT00`, which is the reference runtime with timers on, also run once.
- Report the pause block and `gc-event-log-summary.py` for both.
- Pauses are expected to be unchanged. A pure refactor must not move them.

**Acceptance.** This phase is a prerequisite, not an optimisation. **FLAT is the target, and a
LOSS is a defect to fix, not a reason to close the phase.**

| Criterion | Pass |
|---|---|
| Counters and output (G8) | bit-identical; byte-identical |
| M: mark time | the per-collection paired median delta is ≤ +2 %. Pair collection k of the candidate with collection k of the control; the six majors are the same collections |
| G: GC time | the median delta is inside the control's own spread |
| W: wall | the median delta is inside the larger of the two spreads |
| R: max RSS | the median delta is ≤ +50 MB (0.5 %). W12's hole defect cost +172 MB, so a regression here means the Step 7 discard is not firing |

If M or G fail, look first at the P§3.9 paths:
- `blockIdFor` codegen: the committed-bound compare and the `id + 1` decode;
- the free-list head repaint;
- the accumulator's commit (it must not be in `add`).

Measure with the major event log, not with wall time.

**Record** the result as loop entry **TG1** in `benchmarks/gc-opt-loop.md`, in the same table
format as T01.

**Keep:**
```bash
benchmarks/lss-loop-snap.sh snap keep-TG1 "threaded-gc-01 stable metadata"
mkdir -p snapshots/lss-loop/keep-TG1/bin && cp -p "$BK/bin/eco-optTG1" snapshots/lss-loop/keep-TG1/bin/
cp -p "$BK/bin/eco-optTG1" "$BK/bin/eco-opt-prev"    # same MLIR, same counters: the new reference
```
Then fill in the master plan §4 row 1 (status, this plan, and 3–5 facts for later phases). Write
the outcome into P§6a.

## 8. Invariants (land in Step 11)

Draft rows, using the file's `;`-separated format (`id;phase;category;status;description;source`),
all `Runtime_Heap`, `enforced`:

- **HEAP_048 OldGenStableBlockIds.** Every old-gen block has a `BlockId`, assigned by
  `BlockTable::add` and stable until the block is released.
  - The block's `BlockInfo`, `BufferMetadata`, large-mark byte, mark-bit slot and live-bytes
    accumulator entry live at fixed addresses. Storage is VA-reserved at `initialize()` for
    `max_blocks = old-gen reservation / alloc_buffer_size + 1`, committed on demand, and never
    reallocated or moved.
  - Iteration order (`BlockTable` order, which equals the former `blocks_` order including
    swap-remove and ordered erase) is distinct from identity. Only loop variables and the
    sweep/fixup cursors are positions. Every other stored block reference is a `BlockId`.
  - Only the owning heap's mutator thread releases blocks or recycles ids, at points where no GC
    work item holds an id.
  - `large_body_index_`, `free_large_blocks_`, `unassigned_blocks_`, `free_lists_` and the mark
    stack are owner-only.
- **HEAP_049 OldGenPageIndex.** The page index covers `[heap_base, heap_base + nursery_offset)` at
  `alloc_buffer_size` granularity. It is VA-reserved and committed through `region_end_`, and
  never rebuilt. A slot has at most two owners because every block is ≥ `alloc_buffer_size`.
  Owners are stored as `BlockId + 1` (0 = empty). Lookups must bounds-check against the
  committed slot count.
- **HEAP_050 MarkBitArena.** Block `id`'s mark bits live at `arena + id * stride`, with
  `stride = round_up(alloc_buffer_size / 64, 64)` and a per-id valid length (0 for `is_large` and
  free ids). `startMark` zeroes every live slot and every live large-mark byte (the bulk clear is
  load-bearing, per W11b), and discards dirty free slots. `assign` zeroes a slot whenever an id is
  (re)materialized.
- **HEAP_051 LiveBytesAttribution.** Marking attributes live bytes only to a
  `LiveBytesAccumulator`, never directly to `BufferMetadata::live_bytes`. Allocator-side writes
  go only to `BufferMetadata`. The accumulators merge into `BufferMetadata` as the first action
  of `finalizeMetaAfterMark`, before any post-mark reader, and are all-zero outside
  [`resetBufferMetaForMark`, merge].
- **HEAP_052 FreeListBackLink.** A Tier-M free cell's class-list predecessor is encoded as
  `address >> 3` (40 bits): 32 bits in `FreeCellMid::prev_lo`, 8 in `Header.refcount[0,8)` of
  the same `Tag_Free` cell, with `refcount` bit 8 marking the list head. Only `setPrevHead`,
  `setPrev` and `copyPrev` write these bits. Tier-M threading does not depend on the block
  count.
- **HEAP_053 GCStateIsPerHeap.** Collection code for a heap reads that heap's state — nursery
  bounds, the in-minor-GC flag, the batch-release depth — never the calling thread's TLS.
  Thread-local state is allowed only for mutator-only state (`eco_tl_bump_state`, `eco_tl_root_*`,
  `ListScratch`, the unwind context) and for per-worker validator diagnostics (`g_scan_*`,
  `g_push_origin`, `g_first_push_origin`).

HEAP_007 is **not** amended here. Phase 3 amends it (report §11.1).

## 9. Traps (read before starting)

1. **Positions and ids look alike.** Two cursors are positions. Everything else stored is an id.
   The strong `BlockId` type is the defence, so never add an implicit conversion to "make it
   compile".
2. **Swap-remove happens inside back-to-front loops** (reclaim, shrink). Re-read `idAt(pos)` on
   every iteration. Never cache the id list up front: the order of releases must equal today's.
3. **Compaction is the second removal path** (F2, and the Item 40 lesson). It must clear the page
   index **before** it erases, now that there is no rebuild.
4. **Uncommitted page-index slots are `PROT_NONE`.** A lookup of an address inside
   `[region_base_, region_end_)` whose slot was never committed SIGSEGVs, where the vector
   version read "not found". The `slot < committed()` guard is mandatory, and every site that
   grows `region_end_` must commit through it. That includes `Allocator::ensureOldGenCapacityFor`
   (F7).
5. **Fresh pages are zero,** so an empty owner must be 0. Hence `id + 1` encoding.
   `NO_BLOCK_ID = UINT32_MAX` stored raw in a zero-filled table would read as "block 0 owns
   everything".
6. **The bulk mark-bit clear is load-bearing** (W11b). `clearForMark` zeroes every live slot. Do
   not "optimise" it to dirty slots only.
7. **`refcount` on free cells now carries data.** Any future code that `memset`s or copies the
   header of a **linked** Tier-M free cell must go through the three helpers. V6 catches
   violations in the validate-tree gates.
8. **`rc == 0` does not prove a run completed.** Verify `out.mlir` every time.
9. **`eco-boot-native` can no-op,** so check the object mtimes. In the validate tree, build
   `EcoRuntimeStatic` explicitly.
10. **Judge counters against a same-session control** with the same argument shape (00-P§6a.1).
11. **Do not reorder** the operations in `releaseBlockToAllocator` (P Step 5.3). Several of them
    read the block's metadata, and it must still be live when they do.
12. **VA reservations fail loudly.** If `reserve` fails in `initialize()`, abort with the sizes
    requested. A silently smaller table would overflow later.

## 9a. As-built deviations (recorded during implementation, 2026-09-24)

1. **Steps 6 and 7 were folded into Step 5.** Converting `blocks_` to ids forces every page-index
   owner and every mark-bit accessor to change anyway, so the final page index (HEAP_049) and
   the final `MarkBitArena` (HEAP_050) were written in the same pass instead of through an
   id-indexed vector intermediate. Checkpoints C3/C4/C4b collapsed into one checkpoint (C3).
2. **C2 was lost and not re-run on its own.** The runtime archive was rebuilt (for Step 5) while
   C2's lowering was still running, so its link would have picked up an ambiguous mix; it was
   killed. C3 therefore covers Steps 2–7 together (C1 had already passed Step 1 alone). Trap for
   next time: **never rebuild `build/` while a checkpoint is lowering** — use `build-validate/`
   for concurrent compile checks.
3. **Step 1.4 audit result: none.** No other `tl_heap_`-reading `Allocator` method is called
   from collection code; the `HeapHelpers.hpp` hits (`getRootSet`, `validateInNurserySafe`,
   `isInNursery`) are mutator-side root guards and kernel helpers.
4. **Nursery flag name.** `NurserySpace` already had a validate-only `in_minor_gc_` with a
   *narrower* bracket (`:440`–`:1001`), used by the stale-pointer detector. The always-on
   replacement for `g_in_minor_gc` is therefore `NurserySpace::minor_gc_running_`, set and
   cleared at the two former `g_in_minor_gc` statements. `NurserySpace` befriends `OldGenSpace`
   so the mark path can call the private inline `contains`.
5. **The back-link helpers live in `OldGenSpace.hpp`**, next to `FreeCellMid`, not in the
   `.cpp`'s anonymous namespace, so the unit test can reach them.
6. **Validator V3's cursor check is phase-gated.** A completed sweep leaves
   `sweep_buffer_index_` at the old block count, and the light shrink pass in `onSweepComplete`
   then drops the count below it. That is harmless (the cursor is reset by
   `transitionToSweeping`) and was the same before; the check now applies only while
   `gc_phase_ == Sweeping` (resp. `FixingRefs` for the fixup cursor). Found by the validate
   unit suite in `OldGenCapacityTest`.
7. **Scale test access pattern.** `ReservedArray` commits a *prefix*; ids are handed out densely
   from 0, so the 8 TB test touches the first three ids' storage, not the middle of the range
   (touching index `capacity/2` of a 128 GiB arena would commit 64 GiB). Measured: **+64 KiB RSS**
   for the whole 8 TB metadata set with three blocks.
8. **G7 grep hits two test-only accessors.** `OldGenSpaceTestAccess::getBlocks` /
   `getBufferMeta` were kept as *order-position snapshot copies* (`std::vector<BlockInfo>` built
   on demand), so the four F17 test files kept their subscripts. They are not storage.
9. **`reset()`** re-reserves the metadata unconditionally (fresh zero tables, ids restart at 0);
   it still has no caller.
10. **`geometryFor` / `reserveMetadata`** are the single source of the capacity arithmetic;
    `initialize()` uses them and the scale test checks them at 8 TB.

11. **The validator self-compile was dropped as a gate** (user decision, 2026-09-24). The run of
    `eco-optTG1v` was killed after 18.6 CPU-minutes, at module 157 of the compile, with **no
    `[heap-validate]` output** (empty stderr); it had not reached the end, so it produced no banner
    and no `out.mlir`. G5 is now the validate tree's unit tests, E2E and GC-pressure stress. The
    master plan's standing rule was updated the same way.

12. **Gate results (2026-09-24).**
    - **Checkpoints.** C1 (Step 1) and C3 (Steps 1–7) and C5 (full candidate, `eco-optTG1`):
      `out.mlir` byte-identical and every counter line identical to the same-session control
      (`eco-optT01`: 1924 minor / 6 major / 254,094,395 allocated / 675,767,781 promoted /
      744,329,992 copied-in-nursery, per-tag retention and the major event log's non-time columns).
    - **G1** unit tests 1,743/1,743 (main), **G2** elm-tests 13,565 pass / 12 fail (the reference
      set), **G4** stress 100/100 at 1,263 minor GCs, **G6** stats-off `ecoc` builds, **G7** clean
      except the two test-only snapshot accessors (item 8).
    - **G3** main E2E: 1,726/1,745 on the one mandated run; the 19 failures were all
      `elm-http`/`HttpGetArchiveTest` returning `NetworkError`, because that run overlapped a
      validate-tree rebuild and stress run. On the idle machine `--filter Http` passes 23/23.
      Trap: **never overlap E2E with other heavy work — the loopback HTTP tests time out.**
    - **G5** (new form): validate unit tests 1,744/1,744 with the pinned seed
      `1790156644220971348` (the default seed hits the known 0-field `Tag_Custom` generator
      flake); validate E2E 1,746/1,746; validate GC-pressure stress 95/100 at 1,032 minor GCs.
      The 5 failures are `JsonRoundtrip{Int,NestedTree,Nullable,Object,OneOf}` aborting in the
      *nursery* stale-pointer check (`debugAssertValidNurseryPointer`); the **pre-change sources
      give the identical 5** (verified by swapping `try-TG1-pre`'s `runtime/src` into the validate
      tree). Zero `[heap-validate]` lines in every validate run. Trap: restoring sources with
      `cp -a` keeps their old mtimes, so a tree built from the swapped-in sources goes stale —
      `touch` the changed files afterwards.

13. **The mark-time investigation (criterion M).** The first full candidate (`eco-optTG1`)
    measured mark **7,976 ms vs 7,558 ms (+5.5 %)** with counters identical, although every mark
    function got smaller (`pushMarkRoot` 100→92 instructions, `blockIdFor` 68→59,
    `markChildren` unchanged at 501). Two causes were found and fixed:
    - **No transparent huge pages on the arena (≈1 %).** `ReservedArray` committed the arena
      at its tail in 64 KiB `MAP_FIXED` steps, so a 2 MiB-aligned range was never wholly
      committed at first touch. `smaps` showed 0 of 134 MiB `AnonHugePages`, against 196 of
      201 MiB for the former `malloc`'d vector. Fix: `ReservedArray::reserve(cap,
      kHugePageBytes)` aligns the base to 2 MiB, commits and discards in whole 2 MiB units, and
      is used for the `MarkBitArena`. After the fix: 136/136 MiB huge, mark 7,898 ms (+4.5 %).
      Huge pages on the small tables (`info_`, page index, accumulator) did **not** help
      (`eco-optTG1c`, 8,037 ms) and were reverted.
    - **Loop alignment (the rest).** `perf annotate` put the extra time at the child-field load in
      `markChildren`'s Custom loop, and event sampling showed no extra cache or TLB misses. The
      loop sat at a 64 B-aligned address in the control and at offset 48 in the candidate,
      shifted by unrelated code-size changes. Recompiling only `OldGenSpace.cpp` with
      `-falign-loops=64` gave mark 7,571–7,620 ms, equal to the control. This is now pinned in
      `runtime/src/codegen/CMakeLists.txt` for `OldGenSpace.cpp` (not MSVC).
    The final binary is `eco-optTG1f` (snapshot `try-TG1f`).

14. **Cost of the huge-page arena for small programs.** With THP `always`, the first touched
    2 MiB granule of the mark arena is backed by a whole huge page, so a tiny heap pays up to
    **~2 MiB of RSS** for its first mark slot (the former `std::vector` paid 8 KiB). That is
    negligible against the 4 GB budget for normal programs; noted in case a small-footprint
    target ever matters.

## 10. Out of scope (and where it goes)

| Item | Where |
|---|---|
| Threads, the helper pool, atomics, handshakes, amending HEAP_007 | phase 3 |
| Atomic mark bits (`fetch_or`), work-stealing deques, several accumulators | phase 4 |
| Snapshot copies of `region_base_/region_end_` and deferral of `freeLargeBodyCell` | phase 5a |
| Promotion buffers; handing whole blocks to them; the fate of `demoteMostlyDeadUniformBlocks` | phase 2 |
| Per-thread `GCStats`; `g_first_push_origin` as per-heap state | phases 3/6 |
| One process-wide mark arena, instead of one per heap (VA at many-heap × TB scale) | phase 8 candidate |
| Deleting compaction (dead in production) | not this plan. It is ported, not removed |

## 11. Done means

- G1–G8 are green and P§7 acceptance holds.
- The validate-tree unit tests, E2E and GC-pressure stress are clean.
- HEAP_048–053 have landed.
- `keep-TG1` is taken and `eco-opt-prev` has been updated.
- The master-plan row 1 is filled in.
- The scale tests show that the old-gen metadata for an 8 TB reservation costs address space and
  under 16 MiB of memory.
