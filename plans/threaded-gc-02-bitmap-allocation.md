# Threaded GC 02 — Promotion buffers via bitmap allocation

**Status:** DONE (2026-09-25). Compiled defaults: `old_gen_bitmap_alloc` on,
`demote_live_fraction` 0.3, LiveBudget k = 4.5 / r = 1.5, `garbage_denom_cap` 0. Snapshot `keep-TG2`,
`bin/eco-opt-prev` = `eco-optTG2`, loop entry TG2. Results and acceptance in §9 items 7–10.
(Originally PLANNED 2026-09-25.) Written against the `keep-TG1` tree
(`bin/eco-opt-prev` = `eco-optTG1f`).

**Parent:** `plans/threaded-gc-master-plan.md`, phase 2.

**Background:**
- `design_docs/parallel-gc.md` §6 (§6.1 where sweep runs, §6.3 bitmap allocation) and §7.2
  (promotion buffers);
- `benchmarks/threaded-gc-00-baseline.md` (the pause and promotion numbers this phase attacks);
- `plans/threaded-gc-01-stable-metadata.md` (the `BlockTable`, `MarkBitArena` and invariants
  HEAP_048–053 this phase builds on).

§n points into the report, P§n into this plan, 01-P§n into the phase 1 plan.

## 0. What this phase delivers, and why

After every major GC the old gen holds gigabytes of garbage. Today it is reclaimed by a **lazy
sweep** that walks every header of every block and threads the dead cells onto free lists. Almost
every old-gen allocation is a promotion, and each promotion drives a sweep slice, so that walk
runs **inside minor-GC pauses**. The first minors after each major each sweep 1–4 GB (baseline
§4.3):

| pause | size | what is in it |
|---|---|---|
| worst post-major minor | **903 ms** | 829 ms promoted drain, **3.77 GB lazy-swept inside the pause** |
| next three post-major minors | 680 / 608 / 390 ms | 2.83 / 2.11 / 1.14 GB swept |
| ordinary minor | 155–176 ms | no sweep |

Two more costs sit on the same path:
- **In-pause lazy sweep: 2.23 s** per self-compile (10.5 GB swept inside minors).
- **The promotion allocator: 21.8 s, 32 ns per promotion.** Each promotion pops a cold
  free-list cell, which is a DRAM miss, and then rewrites up to three neighbouring Tier-M cells
  to keep the list's back-links.

**This phase replaces the header-walking sweep with two cheaper mechanisms:**

1. **Uniform blocks** (one size class per page; ~half the post-major pages) are **never swept**.
   After mark, a uniform block's mark bitmap *is* its allocation map: a cell is free exactly when
   its cell-start bit is clear. The allocator takes cells straight from the bitmap through a
   **per-class cursor**, which owns one block at a time. That cursor is the *promotion buffer*
   master-plan phase 6 needs: a destination a thread can own without shared free lists.
2. **Mixed blocks** (bag pages, and uniform blocks that `demoteMostlyDeadUniformBlocks` turned
   mixed) keep a lazy sweep. It becomes a **gap sweep** that reads only *live* headers, found
   through the mark bitmap, and writes one free run per gap between them. Dead memory is never
   read.

The latest major of the reference run (residency histogram, `eco-optTG1f-rm1.stdout`) shows
why both halves matter:

| pages at major end | count | live MB | garbage MB | after this phase |
|---|---|---|---|---|
| > 50 % live (stay uniform) | 3,583 | 1,521 | 266 | bitmap, **no sweep** |
| ≤ 50 % live (demoted to mixed) | 3,358 | 187 | 916 | gap sweep, **O(187 MB live)** instead of O(1.1 GB) |

| # | Deliverable |
|---|---|
| D1 | `HeapConfig::old_gen_bitmap_alloc` (compiled default `OLD_GEN_BITMAP_ALLOC`), with **flag off bit-identical to `eco-optTG1f`** |
| D1b | **The demotion lever:** `HeapConfig::demote_live_fraction` (compiled default `DEMOTE_LIVE_FRACTION = 0.5`). A uniform block is demoted to mixed at the end of mark iff `live_bytes ≤ demote_live_fraction × totalBytes`. **`0.0` turns demotion off**, so blocks are never demoted. It is bit-identical to today at 0.5, applies in both flag modes, and is tuned by experiment E1 (P§5a) |
| D2 | Bitmap scan primitives: find the next clear cell-start bit for a class stride, word at a time |
| D3 | Per-class allocation cursor plus per-class partial-block queue; block `alloc_state` |
| D4 | Eager post-mark block classification (uniform → queue, is_large → decided, mixed → pending), plus eager retirement of dead large bodies |
| D5 | The flag-on allocation ladder: cursor → free list → bag-first → split → sweep-on-demand → **virgin block** → bag page → panic |
| D6 | `freeLargeBodyCell` without sentinels: clear one bit, or push onto a swept block's list |
| D7 | Gap sweep for mixed blocks |
| D8 | Walkers that stop parsing uniform blocks by header (compaction, validator walk), plus residency stats |
| D9 | Validators V8–V12, unit tests, an additive stats block, invariant rewording (HEAP_021/024/027) and new rows |
| D10 | Measurement, a default flip, gates, docs, tracking row |

**Out of scope:** threads, concurrent sweeping, per-thread cursors (phase 6), en-masse promotion
(§7.3), prefaulting pages, and any change to mark (P§10).

## 1. Ground rules for this phase

1. **This is a policy change, behind a flag.** With the flag **on**, which cell a promotion lands
   in changes, and so can the major-GC schedule. The counters are re-baselined deliberately:
   - **must stay identical:** `out.mlir` (byte-identical), minor-GC cycles, objects allocated,
     objects promoted, promoted MiB, copied-in-nursery, per-tag retention. Promotion and nursery
     behaviour do not depend on where in the old gen an object lands;
   - **may change, and are reported:** major-GC cycles and their timing, the major event log's
     before/after/garbage/recovered columns, old-gen peak, max RSS.
   With the flag **off**, *everything* is bit-identical to `eco-optTG1f`, like a phase 1
   checkpoint. That proves the new code does not leak into the legacy path.
2. **The W6 ladder rule** (`benchmarks/gc-opt-loop.md` W6, +77 s / +33 % RSS). A source of *new*
   memory goes exactly at the rung it replaces and never above a reuse rung. Here the **virgin
   block replaces `populateFromBlock`** (today's rungs 2 and 5), and nothing else. Partial-block
   reuse, free-list pops, splitting and sweep-on-demand all come before it.
3. **The W3/W4 rule: branchy rewrites of predicted code can lose.** The bitmap scan replaces a
   predicted pointer pop. The bet is that the pop is a cache miss and the bitmap word is in L1.
   **Measure it** (promotion-allocator ns per promotion, phase-timer build, P§7). The scan kernel
   is written so its hit path has one predictable branch (Step 2).
4. **The retention gate comes before timing** (master plan §2). Judge old-gen peak and max RSS
   first: a change that lifts them compounds (the Sep-22 sweep).
5. **Assert what you delete or rely on** (01-P§1 rule 7). This phase deletes several things:
   - the header walk of uniform blocks;
   - the header walk of dead objects in mixed blocks;
   - the lazy decision on is_large blocks;
   - the sweep's retirement of dead bodies;
   - the sentinel protocol.
   Each gets a validator (Step 9) exercised by the validate-tree gates. **No validator
   self-compile:** it is too slow (master plan §2, 2026-09-24).
6. **Measure mark per collection, and mind code alignment.** `-falign-loops=64` is pinned for
   `OldGenSpace.cpp`, so new code in that file cannot silently move `markChildren`'s loop
   (01-P§9a.13). If mark moves by a few percent with no mark-path change, check the loop address
   before blaming the design.
7. **Single-threaded, but build the shape phase 6 needs.** A block is owned by at most one cursor
   (`alloc_state == Current`), and a queued block is owned by nobody. Phase 6 turns the one cursor
   per class into one per thread without changing that ownership model.

## 2. Verified facts the steps rely on

Verified 2026-09-25 against `keep-TG1`. **Re-verify each before editing.** Line numbers are in
`runtime/src/allocator/OldGenSpace.cpp` unless a file is named.

| # | Fact | Where |
|---|---|---|
| F1 | The size-class ladder: (1) exact-fit pop `tryPopFromFreeList`; (2) bag-first `populateFromBlock` when `shouldPreferBagForSmallClass`; (3) `tryAllocateBySplittingLarger`; (4) sweep-on-demand `sweepOnDemandAllocate` while `hasPendingSweepWork()`; (5) `populateFromBlock`; (6) `allocateFromBagPage`; (7) `panicSweepAndRetryAllocation`. | `allocateFromSizeClass` `:996` |
| F2 | `allocate()` runs one `lazySweep` slice (`sweep_work_budget`, divided by `minor_sweep_divisor` when `in_minor_gc_`) **before every allocation** while `gc_phase_ == Sweeping`. This is how the sweep lands inside minor pauses. | `:653` |
| F3 | `free_lists_[cls]` for a *uniform* class holds cells from uniform blocks (`populateFromBlock` slicing, sweep re-emission) **and** from mixed blocks (the any-class packer in `pushSpanOnFreeLists` places tails on small classes). `tryAllocateBySplittingLarger` walks only classes `>= num_size_classes_`, which exist only in mixed blocks. | `:1022-1060` comments, `pushSpanOnFreeLists` |
| F4 | `populateFromBlock` writes a `Tag_Free` header into **every** cell of a fresh page and links it (21,845 cells for 24 B): the W6 cost. | `:1309` |
| F5 | The uniform-block free cell exists only as a `Tag_Free` header plus a list link. The mark bitmap (1 bit per 8 B granule, at object start) has a bit exactly at the start of every marked cell. A uniform block's cells lie at `start + k·cell_bytes` for `k < num_cells = alloc_buffer_size / cell_bytes`, and `end_of_objects = start + num_cells·cell_bytes`. | `populateFromBlock`, HEAP_050 |
| F6 | The mark bitmap is zeroed for every live block at `startMark` (`MarkBitArena::clearForMark`), and marking sets bits via `testAndSetMarkBitInBlock`. Nothing allocates between `startMark` and `finishMarkAndSweep` (STW, 01-F11). | `:1565`, `BlockTable.hpp` |
| F7 | Allocate-black: `initObjectHeaderWithSize` sets the object's bit and adds `cell_bytes` to `live_bytes` only while `marking_active || gc_phase_ != Idle`. **After sweep completes (Idle), `live_bytes` stops tracking allocations**, while `allocated_bytes` keeps counting. | `:416` |
| F8 | `padCellSlack` writes a trailing `Tag_Free` header over a size-class cell's slack. `demoteMostlyDeadUniformBlocks` relies on it so that a demoted block walks correctly with the mixed stride (`getObjectSize`). | `:799`, `:2100` |
| F9 | Post-mark sequence, in each of the **four** `finishMarkAndSweep` overloads (`:2155`, `:2191`, `:2270`, and the profile-only one after it): `finalizeMetaAfterMark` → `gatherFreeListSnapshotInto` (stats builds) → `demoteMostlyDeadUniformBlocks` → `transitionToSweeping` (wipes `free_lists_` and `free_large_blocks_`, and sets `fully_swept = false` on every block) → `reclaimAllDeadBlocksFromMeta` → `adjustCapacityAfterMajorGC` (heavy shrink) → `gatherResidencySnapshotFrom` (stats) → `recomputeSweepPendingBlocks` → one `lazySweep` of `initial_sweep_budget`. | `:2155`–`:2300` |
| F10 | `lazySweep` handles three block kinds: skips `fully_swept`; decides an is_large block in one shot (dead → `markBlockAsFreeLarge`, plus erasing a dead body's `large_body_index_` entry); and walks every header of a regular block, clearing mark bits and coalescing dead objects and non-sentinel `Tag_Free` into runs pushed by `pushCoalescedFreeCell`. It stops at an on-free-list **sentinel** (HEAP_027) and **erases the `large_body_index_` entry of any dead pinned body** it walks over. | `:2697` |
| F11 | `large_body_index_` holds **only nursery-owned** bodies: `promoteLargeHeader` erases the entry when the header is promoted. A dead nursery-owned body is retired either by the major sweep (F10) or by `sweepNurseryLargeBodies` → `freeLargeBodyCell` at the next minor. **If neither runs before the cell is reused, a later `freeLargeBodyCell` double-frees it.** | `:4424`, `promoteLargeHeader` |
| F12 | `freeLargeBodyCell` (non-large body): clears the bit, pushes the cell with `pushSpanOnFreeLists`, and sets a **sentinel** (`age = 1`) when `Sweeping && !fully_swept` (or `Marking`, which is unreachable). It debits `live_bytes` (clamped), `allocated_bytes` and `frag_stats_.live_bytes`, and adds to `garbage_bytes`. The is_large case parks the block on `free_large_blocks_`. | `:4507` |
| F13 | The splitter sets a sentinel on a remainder whose block is unswept (`need_sentinel = Sweeping && !fully_swept`). A cell on a free list can be in an unswept block only because `freeLargeBodyCell` pushed it there (F12). | `tryAllocateBySplittingLarger` |
| F14 | **Three** header walkers exist besides the sweep: compaction's `evacuateSlice` `:3837` and `fixReferencesSlice` `:3989` (test-only, 01-F4), and the validate-only old-gen→nursery walk in `NurserySpace.cpp:876-900` (`[gc-old-check]`). **Report §6.3's "no validator walks whole blocks" is wrong**: the last one does. | as listed |
| F15 | `gatherFreeListSnapshotInto` (stats builds) attributes free bytes per block from the free lists. The residency histogram reports `free_MB` vs `garb_MB` from it. | `:3597` |
| F16 | `allocateFromEmptyRegularBlocks` repurposes any regular block with `fully_swept && live_bytes == 0` as a large block. The light shrink at `onSweepComplete` releases blocks under the same condition. With F7, a block retained by the min-heap floor and allocated into after Idle would read `live_bytes == 0` while holding live objects. That is a latent hazard on today's tree, and D3's exact accounting closes it for uniform blocks. | `:1459`, `maybeShrinkCapacity` |
| F17 | `HeapConfig` fields are parsed by `HeapConfigJson.cpp`: a known-key list (`:170-190`), plus one `doc.find` block per key. JSON is applied *onto* the defaults (`applyHeapConfigFromEnv`, from `ECO_HEAP_CONFIG`). Timed runs change the compiled default, never `ECO_HEAP_CONFIG` (`gc-opt-loop.md` §5). | `HeapConfigJson.cpp`, `AllocatorCommon.hpp:~490` |
| F18 | `BlockInfo` is 40 bytes with 5 bytes of tail padding after `is_large` / `free_cells_in_block`, so adding a `uint8_t` keeps it at 40 B. | `BlockTable.hpp` |
| F19 | Reference numbers (TG1f, same machine): minor 58.4 s, major 8.6 s, GC 67.0 s, wall 181.6 s; worst minor-only pause 915 ms (`eco-optTG1pt`); 1,924 minors, 6 majors, 19,861 promoted MiB, max RSS 9,664,108 kB; old-gen in-use peak ~8.8 GB. | `benchmarks/gc-opt-loop.md` TG1 |

## 3. Design

### 3.1 Block kinds after a major GC (flag on)

| kind | test | after mark | how free space is reached |
|---|---|---|---|
| **uniform** | `!is_large && size_class < num_size_classes_` (after demotion) | `fully_swept = true`; queued on `partial_[cls]` if `live_bytes < num_cells·cell_bytes` | the class cursor scans its mark bitmap for clear cell-start bits |
| **is_large** | `is_large` | decided at once: dead → `free_large_blocks_`; `fully_swept = true` | `allocateFromFreeLargeBlocks` (unchanged) |
| **mixed** | `!is_large && size_class >= num_size_classes_` | `fully_swept = false`; lazy **gap sweep** | free lists (unchanged) |

**Uniform-block bitmap semantics (flag on): bit set at cell start ⇔ the cell is allocated.**
That means live at the last mark, or allocated since. The bitmap is set by marking, then by the
cursor on every allocation, and cleared by `freeLargeBodyCell`. `startMark` zeroes it (F6).
Dead cells keep **stale headers**, and never-allocated cells in a virgin block have **no header
at all**, so uniform blocks are **not header-parsable**. Every walker of a uniform block must
iterate its set bits (P§3.6). HEAP_021 and HEAP_024 are reworded accordingly (P§8).

**Uniform-block accounting (flag on): `live_bytes == popcount(cell-start bits) × cell_bytes` at
every point outside the mark window.** The cursor adds `cell_bytes` on every allocation, and
`freeLargeBodyCell` subtracts it. That differs from F7 (allocate-black only while not Idle) on
purpose: it closes F16's hazard for uniform blocks. It is validator V8.

### 3.2 The cursor and the partial queue

```
struct AllocCursor {             // one per size class < num_size_classes_
    BlockId  block = NO_BLOCK_ID;  // the block this class allocates into (alloc_state == Current)
    uint32_t next_cell = 0;        // first cell index not yet examined
    uint32_t num_cells = 0;        // cells in this block
    uint32_t stride_bits = 0;      // cell_bytes / 8 (= m)
    uint8_t* bits = nullptr;       // mark_.slot(block) (stable, HEAP_050)
    char*    base = nullptr;       // block start
};
AllocCursor cursor_[NUM_SIZE_CLASSES];
std::vector<BlockId> partial_[NUM_SIZE_CLASSES];   // FIFO; consumed from partial_head_[cls]
size_t               partial_head_[NUM_SIZE_CLASSES];
```

- `BlockInfo` gains `uint8_t alloc_state`: `None = 0`, `Queued = 1`, `Current = 2` (F18: no size
  change).
- **Reset:** at `startMark`, when the flag is on, every cursor and queue is cleared and every
  block's `alloc_state` is set to `None`. The bitmap is about to be rebuilt, so a cursor position
  means nothing across a major GC.
- **Build:** P§3.3 fills the queues in **order position**, so consumption order is deterministic
  and follows the same order the lazy sweep used.
- **Refill:** pop from the queue head. Skip any entry that is no longer
  `isLive && alloc_state == Queued && size_class == cls`: it was detached in the meantime. Set it
  `Current` and point the cursor at cell 0.
- **Exhaust:** when the scan runs off `num_cells`, the block becomes `None`. It is full or nearly
  full, and the cells it still has were freed behind the cursor, which the rewind rule below
  prevents.
- **Detach** (`detachFromAllocation(id)`) is called before a block is released, flipped to large
  or demoted: `Current` → the cursor is cleared; `Queued` → the entry is erased from its queue
  (linear, rare); then `None`.
- **Rewind:** `freeLargeBodyCell` clearing a bit at cell `k` in the class's `Current` block with
  `k < next_cell` sets `next_cell = k`. For a block that is `None`, it pushes the block onto
  `partial_[cls]` and sets `Queued`. A freed cell is never lost until the next major.

### 3.3 Eager post-mark classification (`classifyBlocksAfterMark`)

This runs in every `finishMarkAndSweep` overload, flag on only, **after**
`adjustCapacityAfterMajorGC` and **before** `recomputeSweepPendingBlocks` (F9). Released blocks
are gone by then, and `fully_swept` values are final before the pending count is taken.

```
retireDeadLargeBodies();                  // P§3.5 — before any cell can be reused
for pos in 0..blocks_.size():             // position order = former sweep order
    id = idAt(pos); b = info(id); m = meta(id)
    if b.is_large:                        // the former lazySweep is_large branch, verbatim
        live = largeMark(id) != 0
        if !live: m.garbage_bytes = b.totalBytes(); markBlockAsFreeLarge(id)
        largeMark(id) = 0                 // same post-state as testAndClear in sweep
        m.fully_swept = true
    elif b.size_class < num_size_classes_:            // uniform
        m.fully_swept = true              // never lazily swept (flag on)
        if m.live_bytes < cellsIn(b)·classToSize(b.size_class):
            partial_[b.size_class].push_back(id); b.alloc_state = Queued
    else:                                 // mixed: left for the gap sweep
        (fully_swept stays false)
```

- **The is_large branch must reproduce `lazySweep`'s is_large branch exactly** (F10): dead ⇒
  garbage, parked, large-mark cleared.
- `fully_swept = true` on uniform and is_large blocks makes `recomputeSweepPendingBlocks` count
  **only mixed blocks**. It also makes `lazySweep` skip them through its existing `fully_swept`
  test.

### 3.4 The flag-on allocation ladder (`allocateFromSizeClassBitmap`)

`allocateFromSizeClass` gains one branch at the top:
`if (config_->old_gen_bitmap_alloc) return allocateFromSizeClassBitmap(cls, requested_size);`.
The flag-off body is untouched.

| rung | action | kind | replaces |
|---|---|---|---|
| 1 | `cursorAllocate(cls, req)`: scan the current block; on exhaustion refill from `partial_[cls]` and retry | **reuse** (garbage from the last major) | exact-fit pop of uniform cells |
| 2 | `tryPopFromFreeList(cls)` + `finalizePoppedCell` | reuse (mixed-block tails) | (unchanged) |
| 3 | if `shouldPreferBagForSmallClass(cls)`: `startVirginBlock(cls)` then rung 1 | growth, **budgeted** | today's rung 2 (`populateFromBlock`) |
| 4 | `tryAllocateBySplittingLarger(cls, classToSize(cls))` + `padCellSlack` | reuse | (unchanged) |
| 5 | if `hasPendingSweepWork()`: `sweepOnDemandAllocate(cls, req)` (gap-sweeps mixed blocks) | reuse | (unchanged) |
| 6 | `startVirginBlock(cls)` then rung 1 | **growth** | today's rung 5 (`populateFromBlock`) — **the W6 rung** |
| 7 | `allocateFromBagPage(req)` | growth | (unchanged) |
| 8 | `panicSweepAndRetryAllocation(cls, req)` | reuse, last resort | (unchanged) |

Virgin blocks enter at the rungs `populateFromBlock` occupied, and nowhere else (rule 2). A
virgin block is **not sliced**: no headers, no links (F4).

**`startVirginBlock(cls)`**
1. Obtain a bag page exactly as `populateFromBlock` does, including the `acquireOldGenBlock`
   fallback, the region update and `resizePageIndexForRegion`.
2. `materializeBlock(bi, {0, 0, /*fully_swept=*/true}, bitmapBytesForBlock(bi))`, with
   `bi.size_class = cls` and `bi.end_of_objects = start + num_cells·cell_bytes`.
3. `onUniformBlockDedicated(id)`.
4. `alloc_state = Current` and set the cursor to it.

`fully_swept = true` holds even when the lazy sweep isn't running: a virgin block never needs
sweeping.

**`cursorAllocate(cls, req)` → `finalizeBitmapCell(c, k, cls, req)`:**
```
char* p = c.base + k·cell;          setBit(c.bits, k·c.stride_bits)   // always (P§3.1)
Header* h = (Header*)p; memset(h, 0, 8)
h->color = (marking_active || gc_phase_ != Idle) ? Black : White     // as initObjectHeader
meta(c.block).live_bytes += cell;   allocated_bytes += cell
padCellSlack(p, req, cell)          // kept: a later demotion walks this block mixed (F8)
return p
```
- No `blockIdFor` lookup: the cursor knows its block.
- `initObjectHeaderWithSize` is **not** called, because it would add `live_bytes` a second time
  when not Idle.

### 3.5 Retiring dead large bodies eagerly (`retireDeadLargeBodies`)

`retireDeadLargeBodies` runs first in `classifyBlocksAfterMark`:

- For every `(body, id)` in `large_body_index_`, take `bid = blockIdFor(body)`.
- If `bid` is valid, the block is not is_large, and `!isMarkedInBlock(bid, body)`: erase the
  entry and set `large_bodies_[id].body_base = nullptr`. **Do not recycle the id.** That is exactly
  what `lazySweep` did when it walked over a dead pinned body (F10), and
  `sweepNurseryLargeBodies` later drains the stale slot as it does today.
- Bodies in is_large blocks are handled by the is_large branch of P§3.3, which already erases the
  entry (mirroring F10's is_large branch).

The iteration order of the unordered map does not matter: the erasures are independent.

Why eagerly: the gap sweep and the bitmap cursor never read dead headers, so nothing else would
retire them, and F11's double free would follow.

### 3.6 Gap sweep for mixed blocks

Under the flag, `lazySweep`'s per-header inner loop for a regular (necessarily mixed) block is
replaced by a gap walk over the block's mark bits. Slices stay resumable through `sweep_cursor_`,
exactly as now, and `work_done` keeps counting **span bytes covered**, so the pacing formulas and
knobs keep their units.

```
bits = mark_.slot(id); lo = sweep_cursor_
while lo < end_of_objects && work_done < budget:
    L = nextSetBitAddress(bits, block, lo, end_of_objects)  // word scan + ctz; end if none
    if L > lo:  extend run by [lo, L)                       // the gap: dead objects/unlinked free
    if L == end_of_objects: work_done += L - lo; lo = L; break
    flushRun(pos)                                            // push the gap as free cells
    clearBit(L)                                              // same post-state as testAndClear
    step = walkStep(block, getObjectSize(L))                 // only LIVE headers are read
    work_done += (L + step) - lo;  lo = L + step
sweep_cursor_ = lo;  (block boundary handling as today: flush, markBlockFullySwept, advance)
```

Why this is equivalent to today's walk (with no sentinels, P§3.7): today's loop extends a run
over every dead object and every non-sentinel `Tag_Free` cell, and flushes at every live
(marked) object. The set bits of a mixed block are **exactly** its live objects:
- marking set them;
- nothing allocates into an unswept block (only swept blocks feed the lists, and mid-cycle pages
  are `fully_swept`);
- `startMark` cleared any stale ones.

So the maximal runs between set bits are exactly today's runs, and `pushSpanOnFreeLists` packs
them identically. **The only reads of the object area are the live headers.**

`getObjectSize` on a live object in a demoted block returns the logical size. The cell's slack
carries a `padCellSlack` `Tag_Free`, which falls inside the next gap and is coalesced. That is
the same outcome as today.

### 3.7 `freeLargeBodyCell` without sentinels (flag on)

For a non-large body in block `bid`:

| block state | action | garbage accounting |
|---|---|---|
| uniform (any phase) | clear the cell's bit; `live_bytes −= cell` (exact, P§3.1); rewind or queue (P§3.2) | `garbage_bytes += cell` |
| mixed, `!fully_swept` (the gap sweep will reach it) | clear the bit **only**; the gap sweep reclaims the cell as part of a gap | **none here**: the gap sweep's `flushRun` counts it |
| mixed, `fully_swept` or Idle | `pushSpanOnFreeLists(..., age_sentinel=false)` as today | `+= cell` (as today) |

`allocated_bytes` and `frag_stats_.live_bytes` debits stay as they are.

With the flag on, **no code path produces a sentinel**. The splitter's `need_sentinel` can only
be true for a cell in an unswept block (F13), and no such cell is ever on a list. Validator V9
enforces that. HEAP_027 becomes "flag on: no sentinels; freeing a body in an unswept block
clears its bit" (P§8).

### 3.8 Walkers of uniform blocks (flag on)

- **`evacuateSlice` / `fixReferencesSlice`** (compaction, test-only): before reading the header
  at the cursor in a block with `size_class < num_size_classes_`, add
  `if (!isMarkedInBlock(id, cursor)) { cursor += step; continue; }`. After sweep (Idle), a set
  bit means "allocated". Mixed blocks walk as before.
- **`NurserySpace.cpp:876` `[gc-old-check]` walk** (validate builds): the same skip.
- **`gatherFreeListSnapshotInto` / residency histogram** (stats builds): a uniform block's free
  cells are no longer on lists, so its non-live bytes show as garbage. **Additively**, record
  per-class "bitmap-free" bytes from `partial_` blocks as `cells·cell − live_bytes`.
  Changing an existing banner line's meaning is not allowed (00-P§1 rule 4), so the existing
  histogram keeps its definition. Its `free_MB` column simply shrinks under the flag, and the
  plan and loop entry say so.

### 3.9a Demotion becomes a tunable lever (`demote_live_fraction`)

`demoteMostlyDeadUniformBlocks` exists so that the free space of mostly-dead uniform blocks
becomes splittable for *other* size classes (F8). It is a **retention** lever, bought with sweep
work. Phase 2 changes its price:

- with the flag on, a demoted block is gap-swept (O(live), P§3.6). Its free space then feeds any
  class through the free lists;
- a block that is *not* demoted stays uniform and costs nothing to sweep, but its free cells can
  only serve its own class, through the bitmap cursor.

Where the balance lies is an empirical question. It depends on how much a class's demand
drifts between majors. So the threshold becomes a parameter instead of the hard-coded
`live * 2 > total` (`:2122`):

| `demote_live_fraction` | meaning |
|---|---|
| `0.5` (default) | today's behaviour, **bit-identical**. `(double)live <= 0.5 * (double)total` equals `live * 2 <= total` exactly, because both operands are integers below 2^53 |
| `0.0` | **off**: no block is ever demoted, and every uniform block stays uniform. This is an explicit early return, **not** the formula. With the formula, `live <= 0` would still demote the all-dead blocks, which `reclaimAllDeadBlocksFromMeta` then releases. Today that is harmless, but "0.0 = off" must mean *off* |
| `(0, 1]` | demote iff `live_bytes ≤ f × totalBytes`. At `1.0` every uniform block is demoted, which disables bitmap allocation in practice: useful only as a bounding experiment |

- **Validation:** `HeapConfig::validate` rejects values outside `[0.0, 1.0]` with a clear message.
- **The parameter is independent of `old_gen_bitmap_alloc`,** so it can be tuned in the legacy
  mode too (P§5a).
- **Bookkeeping:** nothing else changes with it. `onBlockTransitioningToLarge` (the small-class
  debit) and `detachFromAllocation` (flag on) are called for exactly the blocks demoted.

### 3.9 Hot paths after the change

| path | today | flag on |
|---|---|---|
| promotion into a small class | `tryPopFromFreeList`: load `cell->next` (a **cold miss**), Tier-M `blockIdFor` + `blockThreadUnlink` (2–3 neighbour writes), repaint the new head's back-link; `finalizePoppedCell` → `initObjectHeaderWithSize` (mid-cycle `blockIdFor` + bit + `live_bytes`) | load one bitmap word (L1), mask, ctz, compute the address; set one bit; header `memset`; `live_bytes +=`. **No list, no neighbour writes, no page-index lookup.** Consecutive promotions land at consecutive cells of one block |
| per-allocation sweep slice (post-major) | walks every header in 4 KiB slices | gap-sweeps mixed blocks only; uniform blocks cost nothing |
| major pause | unchanged | adds `classifyBlocksAfterMark`: O(#blocks), and `retireDeadLargeBodies`: O(#nursery-owned bodies), both small |

## 4. Steps

Do the steps in order. Every step ends with:
- `cmake --build build --target check` green;
- **checkpoint C-off** after steps 1, 5 and 9: a self-compile with the flag at its default
  (**off**). Every counter and `out.mlir` must be identical to the same-session `eco-optTG1f`
  control (01-P§5);
- **checkpoint C-on** after steps 5, 7 and 9: one self-compile with
  `ECO_HEAP_CONFIG=<scratch>/bitmap-on.json` containing `{"old_gen_bitmap_alloc": true}`. It is a
  correctness run, not a timing run: `out.mlir` identical, minors and promoted identical,
  `rc == 0`, no abort. Record majors, old-gen peak and RSS.

**Before you start:**
- Take the snapshot `try-TG2-pre`.
- Name the lowered binaries `eco-optTG2-cN`.
- Run the control `eco-optTG1f` once in the session.
- Lower a **phase-timer** reference now: `build-phasetimers` on the current sources gives
  `eco-optTG1fpt`. Steps 1–9 change `OldGenSpace.cpp`, so it cannot be rebuilt later without a
  source swap.

Scripts from phase 1 are in the session scratchpad (`run1.sh`, `counters.sh`, `checkpoint.sh`,
`extract.py`, `diag.sh`). Recreate them from 01-P§5 if they are gone.

### Step 1 — D1: the flag

**Files:** `AllocatorCommon.hpp`, `HeapConfigJson.cpp`, `test/allocator/` (the new suite, Step 10).

1. `AllocatorCommon.hpp`:
   - add `constexpr bool OLD_GEN_BITMAP_ALLOC = false;` next to `DECOMMIT_ON_OLDGEN_RELEASE`;
   - add to `HeapConfig`: `bool old_gen_bitmap_alloc = OLD_GEN_BITMAP_ALLOC;`, with a comment
     naming this plan and HEAP_054.
2. `HeapConfigJson.cpp`: add `"old_gen_bitmap_alloc"` to the known-key list (F17) and a
   `parseBool` block beside `decommit_on_oldgen_release`.
3. **The flag is read, never cached across a `reset()`** (`config_->old_gen_bitmap_alloc`).
4. **The demotion lever (D1b, P§3.9a).**
   - `AllocatorCommon.hpp`: add `constexpr double DEMOTE_LIVE_FRACTION = 0.5;` and
     `double demote_live_fraction = DEMOTE_LIVE_FRACTION;` in `HeapConfig`, with a comment
     giving the semantics and "0.0 = never demote".
   - `HeapConfig::validate` (`AllocatorCommon.hpp:611`): abort with
     `"demote_live_fraction must be in [0, 1]"` outside that range.
   - `HeapConfigJson.cpp`: add the key to the known-key list and a
     `parseFraction(*it, "demote_live_fraction")` block (as `major_gc_target_utilization`,
     `:244-246`).
     `parseFraction` already enforces `[0, 1]` and returns a `float`. 0.5 and 0.0 are exact in
     `float`, so the default's bit-identity and the "off" test are unaffected. Other values
     carry float rounding, which is harmless for a threshold.
   - `demoteMostlyDeadUniformBlocks`:
     - add at the top: `const double f = config_->demote_live_fraction; if (f <= 0.0) return stats;`;
     - replace `if (live * 2 > total) continue;` with
       `if (static_cast<double>(live) > f * static_cast<double>(total)) continue;`;
     - update the function comment (and the `.hpp` one, which says "at most half") to name the
       parameter.
   - **Unit test** `testDemoteLiveFractionLever` in `test/allocator/OldGenBitmapAllocTest.cpp`
     (Step 10). Build a heap with uniform blocks at known live fractions (10 %, 40 %, 60 %).
     After `runMarkAndSweep`, check that:
     - `f = 0.5` demotes only the 10 % and 40 % blocks;
     - `f = 0.0` demotes none, including an all-dead block retained by the min-heap floor;
     - `f = 0.75` demotes all three;
     - `f = 1.2` is rejected by `validate`.
     Run it in both flag modes.
5. **Checkpoint C-off.** It must be identical: nothing reads the flag yet, and the lever at 0.5 is
   bit-identical by construction.

### Step 2 — D2: bitmap scan primitives

**Files:** new `runtime/src/allocator/BitmapScan.hpp` (header-only, `namespace Elm::bitscan`).
These are pure functions over a byte array: no heap, no `OldGenSpace`.

1. `inline uint64_t loadWord(const uint8_t* bits, size_t w)`: `memcpy` 8 bytes. Arena slots are
   64 B-aligned (stride is a multiple of 64, 01 HEAP_050), so every word is aligned.
2. `constexpr uint64_t strideMask(uint32_t m)`: bits at 0, m, 2m, … below 64 (for `m < 64`).
3. **`uint32_t nextFreeCell(const uint8_t* bits, uint32_t m, uint32_t from_cell, uint32_t num_cells)`**
   returns the first cell `k >= from_cell` whose bit `k·m` is clear, or `num_cells` if there is
   none.
   - **`m < 64`** (cells ≤ 504 B; small classes are `m = 2..32`):
     - Start at bit `g = from_cell·m` in word `w = g / 64`.
     - Keep the phase `r = (w·64) mod m` incrementally: per word, `r += 64 mod m`, and if
       `r >= m` then `r -= m`. Precompute `64 mod m` once per call.
     - The candidate mask is `strideMask(m) << ((m − r) mod m)`, which marks bit positions `b`
       with `(w·64 + b) mod m == 0`, AND-ed with `~0ull << (g mod 64)` for the first word only.
     - `free = ~loadWord(bits, w) & mask`. If `free != 0`, then `g' = w·64 + ctz(free)` and
       `k = g' / m`. That division is exact; for power-of-two `m` use a shift. Return `k` if
       `k < num_cells`, else `num_cells`.
     - Else advance to `w + 1`, stopping past word `(num_cells·m − 1) / 64`.
   - **`m >= 64`** (cells ≥ 512 B, at most one cell start per word): loop
     `k = from_cell..num_cells−1`, testing byte `bits[(k·m) >> 3] & (1 << ((k·m) & 7))`.
   - **Hit-path shape (the W3/W4 rule):** in the common case the first word has a free bit. The
     code is then load, and, test (one branch, predicted taken), ctz and multiply. Keep the phase
     update and the word loop *out* of that path.
4. `inline void setBit(uint8_t* bits, size_t bit)`, `clearBit`, `testBit`.
5. `uint64_t nextSetBit(const uint8_t* bits, size_t from_bit, size_t end_bit)` returns the first
   set bit in `[from_bit, end_bit)`, or `end_bit`. It works word at a time with ctz and is used
   by the gap sweep.
6. `uint64_t popcountCellStarts(const uint8_t* bits, uint32_t m, uint32_t num_cells)` counts set
   bits at cell starts (validator V8; a per-cell loop is fine).
7. **Unit tests** in `test/allocator/BitmapScanTest.cpp`, registered like the phase 1 tests
   (01-P Step 2.9):
   - for every `m` in `{2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 31, 32, 64, 128, 1024}` and
     `num_cells = (512 KiB / 8) / m`;
   - fill the bitmap from a seeded RNG at densities 0 %, 10 %, 50 %, 90 %, 99 %, 100 %;
   - from 1,000 random `from_cell` values, check that `nextFreeCell` equals a naive per-cell
     reference;
   - check `nextSetBit` the same way;
   - edge cases: the last cell, `from_cell == num_cells`, and a partial last word.

### Step 3 — D3: allocation state, cursor, queues

**Files:** `BlockTable.hpp` (`BlockInfo::alloc_state`), `OldGenSpace.hpp/.cpp`.

1. Add to `BlockInfo`: `uint8_t alloc_state = 0;` (`None`/`Queued`/`Current` as `enum class
   AllocState : uint8_t`, stored as `uint8_t` to keep the struct trivially copyable).
   `static_assert(sizeof(BlockInfo) == 40)`.
2. Add to `OldGenSpace` (private): `AllocCursor`, `cursor_[NUM_SIZE_CLASSES]`,
   `partial_[NUM_SIZE_CLASSES]`, `partial_head_[NUM_SIZE_CLASSES]` (P§3.2), plus:
   - `void resetAllocCursors();`: clear all cursors and queues, and set `alloc_state = None` on
     every live block (a loop over positions);
   - `void detachFromAllocation(BlockId id);`
   - `bool refillCursor(size_t cls);`
   - `void setCursor(size_t cls, BlockId id);`: fill `bits = mark_.slot(id)`, `base`,
     `num_cells = cellsIn(info)`, `stride_bits = classToSize(cls) / 8`, `next_cell = 0`, and set
     `alloc_state = Current`;
   - `static uint32_t cellsIn(const BlockInfo&)` = `(end_of_objects − start) / classToSize(size_class)`.
3. Call `detachFromAllocation(id)` **when the flag is on**, at:
   - the top of `releaseBlockToAllocator` (before any other work);
   - `allocateFromEmptyRegularBlocks` before `removeFreeCellsForBlock`;
   - `demoteMostlyDeadUniformBlocks` for each demoted block;
   - compaction's `freeEvacuatedBuffers` erase loop.
   Grep for every place that changes `size_class` or `is_large`, or removes a block. **Assert the
   count**: 4 removal/flip sites plus demotion. A missed site leaves a cursor pointing at a
   released or retyped block.
4. `startMark`: when the flag is on, call `resetAllocCursors()` right after `clearForMark`.
5. `reset()`: clear the cursors and queues unconditionally.
6. Build, then run `check`. There is no checkpoint: nothing uses the state yet.

### Step 4 — D4: eager classification and dead-body retirement

**Files:** `OldGenSpace.hpp/.cpp`.

1. Implement `retireDeadLargeBodies()` (P§3.5) and `classifyBlocksAfterMark()` (P§3.3).
2. Insert `if (config_->old_gen_bitmap_alloc) classifyBlocksAfterMark();` in **all four**
   `finishMarkAndSweep` overloads, immediately before `recomputeSweepPendingBlocks()`.
   `grep -c 'recomputeSweepPendingBlocks();'` inside them must equal 4 before editing (F9).
   - In the two profile overloads, account its time in the existing `sweep_ns` bracket (it is
     sweep-phase work). The event log's "sweep" column then keeps meaning "post-mark work in the
     pause".
3. `lazySweep` with the flag on: the is_large branch becomes unreachable, because every is_large
   block is `fully_swept`. Add `assert(!(config_->old_gen_bitmap_alloc && block.is_large))` at its
   top.
4. Build, then run `check`.

### Step 5 — D5: the flag-on ladder and virgin blocks [C-off, C-on]

**Files:** `OldGenSpace.hpp/.cpp`.

1. Implement `startVirginBlock(cls)`. Factor the page-acquisition prologue out of
   `populateFromBlock` into `bool takeBagPage(char** start, char** end)`, so the two share it
   byte for byte (the flag-off behaviour must not change: C-off).
2. Implement `cursorAllocate`, `finalizeBitmapCell` (P§3.4) and `allocateFromSizeClassBitmap`
   (the ladder table, rungs 1–8 in that order).
3. The top branch in `allocateFromSizeClass` (P§3.4).
4. `populateFromBlock` must be **unreachable** with the flag on: add
   `assert(!config_->old_gen_bitmap_alloc)` at its top. Any hit means a rung is wired wrong
   (rule 2).
5. **Checkpoint C-off** (identical).
6. **Checkpoint C-on.** Expected at this point:
   - uniform blocks are allocated from bitmaps;
   - mixed blocks still use the *header* sweep;
   - there are no sentinel changes yet, so `freeLargeBodyCell` into a uniform block still pushes
     a list cell. **That is unsafe with the flag on:** a list cell inside a uniform block that a
     cursor also scans means a double allocation.

   So before running C-on, implement **Step 6's uniform row** (a one-line redirect to "clear the
   bit") in the same step. Record the result.

### Step 6 — D6: `freeLargeBodyCell` without sentinels

**Files:** `OldGenSpace.cpp`.

1. Implement P§3.7's table under the flag. The flag-off branch is unchanged.
2. The uniform row calls a small helper `freeUniformCell(bid, cell_addr, cell_bytes)`: clear the
   bit, apply the accounting, and rewind the cursor or queue the block (P§3.2 rewind rule).
3. In `tryAllocateBySplittingLarger`, with the flag on, `need_sentinel` must be false. Assert it,
   and keep computing it so the flag-off path is identical.
4. Build, then run `check`.

### Step 7 — D7: gap sweep [C-on]

**Files:** `OldGenSpace.cpp`.

1. In `lazySweep`, with the flag on, replace the regular-block inner `while` loop (the one that
   calls `walkStep(block, getObjectSize(sweep_cursor_))` for every object) with P§3.6's gap walk.
   - Reuse `flushRun` and the run state.
   - Keep the block-boundary code (flush, `markBlockFullySwept`, advance) and the
     early-exit-on-`target_class` check verbatim.
   - The `isFreeCellSentinel` branch and the dead-pinned-body erasure disappear from the flag-on
     path: P§3.5 and P§3.7 made them unnecessary.
2. `nextSetBitAddress` maps a byte address to a bit index in the block's slot, calls
   `bitscan::nextSetBit`, and maps back.
3. **Checkpoint C-on.** Compare the major event log with Step 5's C-on: the "sweep" and in-pause
   sweep time should fall; old-gen peak and RSS should be within noise. A retention jump here
   means the gap sweep dropped or mis-sized a run.

### Step 8 — D8: walkers and stats

**Files:** `OldGenSpace.cpp`, `NurserySpace.cpp`, `GCStats.hpp/.cpp`.

1. The uniform-block skip in `evacuateSlice`, `fixReferencesSlice` and the `NurserySpace.cpp:876`
   walk (P§3.8). All three are guarded by the flag.
2. **Stats** (`ENABLE_GC_STATS`, flag on). Add a new *additive* banner block, "Old-gen Bitmap
   Allocation", after the existing blocks (00-P§1 rule 4: no existing label changes, no new label
   containing a string an existing parser searches for). Counters:
   - `bitmap_allocs` and `bitmap_alloc_bytes`;
   - `cursor_refills` (queue pops);
   - `virgin_blocks`;
   - `list_pops_in_bitmap_mode` (rung 2 hits);
   - `split_allocs`;
   - `sweep_on_demand_hits`;
   - `gap_sweep_live_objects`, `gap_sweep_gaps` and `gap_sweep_bytes`;
   - `uniform_cells_freed` (by `freeLargeBodyCell`);
   - `blocks_classified_{uniform,large,mixed}` per major (cumulative).
   Each lives in the old-gen `alloc_stats_`, **and each needs a `combine()` and a `reset()`
   entry** (00-F1): a missing entry shows as zero, not as a crash.
3. The additive per-class "bitmap-free bytes" in the residency snapshot (P§3.8).
4. Build, then run `check`.

### Step 9 — D9: validators [C-off, C-on]

**Files:** `OldGenSpace.cpp` (`#if ECO_HEAP_VALIDATE`), called from `validateOldGenMetadata`
(01-P Step 9) when the flag is on.

| id | invariant re-derived | cost |
|---|---|---|
| **V8** | For every live uniform block, outside the mark window: `popcountCellStarts × cell == live_bytes`; no set bit off a cell start; no set bit at or past `num_cells·m` | O(bitmap) per block |
| **V9** | No free-list cell lies in a uniform block. No free-list cell lies in a mixed block with `!fully_swept`. **No `Tag_Free` cell on any list carries the sentinel** (flag on) | O(free cells); runs inside V6's walk |
| **V10** | Each `cursor_[cls].block` is `NO_BLOCK_ID` or a live uniform block of class `cls` with `alloc_state == Current`; at most one `Current` per class; every `Queued` block appears exactly once in `partial_[its class]` from the head onward; no `None` block appears there | O(#blocks) |
| **V11** | After the gap sweep finishes a block (call it from `markBlockFullySwept` when the flag is on): a header walk over `[start, end_of_objects)` parses; every object is either `Tag_Free` or a live object whose start was a set bit; `Σ Tag_Free bytes + Σ live walk-steps == end_of_objects − start` | O(block), after each mixed block |
| **V12** | After `classifyBlocksAfterMark`: every `large_body_index_` entry's body is marked | O(#bodies) |

Also:
- keep the existing V1–V7;
- **extend V3:** the cursor blocks and queue entries are live (the detach invariant).

Run **checkpoint C-off** and **C-on**. Then run the **validate tree** with the flag on (Step 11,
G5).

### Step 10 — unit tests (flag on)

**Files:** new `test/allocator/OldGenBitmapAllocTest.cpp` (+ `.hpp`). Each test builds a
`HeapConfig` with `old_gen_bitmap_alloc = true` programmatically; never through `ECO_HEAP_CONFIG`,
which would leak into every suite (00-P Step 1 idiom).

1. **Virgin block:** the first allocations of a class come from one block in address order; no
   `Tag_Free` headers are written (bytes after the cursor stay untouched: fill the page with a
   pattern first, via a test hook); `live_bytes == n·cell`.
2. **Reuse after a major:** allocate and root every other object, drop the rest, run
   `runMarkAndSweep`. The next allocations of that class land exactly on the dead cells, in
   address order, before any new block is materialized (rung order). Check this with
   `OldGenSpaceTestAccess` accessors for the cursor (add `cursorBlock(og, cls)`,
   `partialQueue(og, cls)`).
3. **The W6 rule:** with the partial queue empty, mixed free cells of a larger class available,
   and a pending mixed sweep, allocation must split or sweep *before* `virgin_blocks` increments.
4. **`freeLargeBodyCell` in a uniform block:** the cell is reused by the next allocation (the
   rewind case and the queued case), `live_bytes` is decremented, and no list cell appears.
5. **`freeLargeBodyCell` in an unswept mixed block:** the bit clears, no list push happens, the
   gap sweep reclaims the cell, and `garbage_bytes` counts it exactly once.
6. **Gap sweep equivalence:** build a mixed block with a known object pattern (live/dead
   interleaved, including a demoted block's `padCellSlack` tails). After the sweep, the free
   lists hold exactly the expected runs (sizes and addresses), and V11 holds.
7. **Detach:** releasing the current block (force a light shrink) and flipping a queued block to
   large (`allocateFromEmptyRegularBlocks`) both leave V10 true, and no later allocation lands in
   the released range.
8. **Dead body retirement:** a nursery-owned body whose header died before a major has its
   `large_body_index_` entry gone after `finishMarkAndSweep`, and the next minor's
   `sweepNurseryLargeBodies` does not free it twice (V9 stays silent).
9. **Flag off:** the whole existing suite passes unchanged (G1).

### Step 11 — gates with the flag on (JSON), then measurement

The gates are those of 01-P§6, run twice (flag off at its default, then flag on through
`ECO_HEAP_CONFIG`), except where the table says otherwise.

| # | Gate | Flag off (default) | Flag on (`ECO_HEAP_CONFIG=bitmap-on.json`) |
|---|---|---|---|
| G1 | runtime unit tests | all pass | the Step 10 suite passes. (The legacy suite is not run with the env var: it would override the programmatic configs of tests that pin the legacy mode) |
| G2 | elm-tests | reference set | — (compiler-only) |
| G3 | E2E, **run once, on an idle machine** | 1,746/1,746 | all pass |
| G4 | GC-pressure stress | 100/100, ≳1,000 minors | combine the pressure config and the flag in one JSON file; 100/100 |
| G5 | validate tree: unit (pinned seed `1790156644220971348`), E2E, GC-pressure stress | as phase 1 (stress: the 5 known `JsonRoundtrip*` aborts) | same pass sets, **zero `[heap-validate]` lines** |
| G6 | stats-off `ecoc` builds | yes | — |
| G7 | static: `grep -n 'populateFromBlock(' OldGenSpace.cpp`: every call is in flag-off code | — | — |
| G8 | counters and `out.mlir` | identical to `eco-optTG1f` | `out.mlir` identical; minors, promoted, allocated and per-tag identical; majors reported |

## 5. Measurement

Timed runs **never** use `ECO_HEAP_CONFIG` (F17). Lower the candidate with the compiled default
flipped:

1. Set `OLD_GEN_BITMAP_ALLOC = true`, build, and lower `eco-optTG2` (main tree) and `eco-optTG2pt`
   (`build-phasetimers`).
2. **Retention first** (rule 4): one run of `eco-optTG2`. Read "Old-gen in-use peak" and max RSS.
   If either exceeds the P§5 table, stop and diagnose (it is most likely the queue order, or a
   gap-sweep run bug) before any timed triple.
3. **Timed triples**, strictly serial, idle machine: `eco-optTG1f` ×3 then `eco-optTG2` ×3
   (`gc-opt-loop.md` §2 loop; phase 1's `measure.sh` / `extract.py`).
4. **Pause and promotion runs:** `eco-optTG1fpt` and `eco-optTG2pt` once each, with
   `ECO_GC_EVENT_LOG`. Report:
   - the pause block (max, p99, minor-only max, MMU);
   - `gc-event-log-summary.py` output;
   - the promotion-allocator estimate (ns per promotion, from the 1-in-256 sampler) and the
     in-pause lazy-sweep bytes and time (the 1-in-16 sampler);
   - the 20 worst pauses, with lazy-sweep bytes per pause.

**Acceptance.** This phase is a policy change and is expected to **win**. A flat result is kept
only if the pause criterion holds (the phase's purpose); a loss is diagnosed, not shipped.

| # | Criterion | Pass |
|---|---|---|
| P | **Pauses** | no minor pause contains more than 256 MB of in-pause lazy sweep (today up to 3.77 GB), **and** the max minor-only pause is ≤ 400 ms (today 915 ms). The post-major minors fall back towards ordinary-minor size plus promotion |
| R | Retention | old-gen in-use peak ≤ +2 %; max RSS ≤ +1 % (≈ +100 MB) vs `eco-optTG1f` |
| A | Promotion allocator | sampled ns per promotion **below** the reference's (today 32.2 ns). If it is higher, the W3/W4 risk has materialised: see the traps |
| G | GC time | median ≤ reference median. Expected −1 to −4 s (report §6.3) |
| W | Wall | within the larger spread, or better |
| M | Mark | per-collection paired median within ±2 %. Mark does not change in this phase, so a move means code placement (rule 6) |
| C | Counters | G8 flag-on column |

**If A fails** (bitmap scan slower than the pop):
1. Check which scan dominates: the `bitmap_allocs` vs `cursor_refills` ratio, and the density of
   queued blocks. Highly live blocks (> 90 %) make the scan skip many words.
2. The scan-kernel alternative is a per-cell byte-test loop for all classes. Build it behind a
   `constexpr` switch and measure it on the same promotion sampler.
3. A third option is to **not queue** blocks above a free-fraction floor (for example < 5 %
   free), leaving those cells until the next major. That is a policy knob, and it affects
   retention (criterion R).

**If R fails:** compare the residency histograms. A rise in `(0.5, 1.0]` pages or in committed
pages means reuse got worse:
- verify the ladder order (rule 2);
- verify that the queues hold every partial block (V10);
- verify that the gap sweep produces the same runs (V11).

### 5a. Experiment E1: tuning `demote_live_fraction`

Run E1 **after** the flag-on candidate has passed acceptance at the default (0.5), and before
the default flip in Step 12.

1. **Cheap exploration first,** with the `heap-profile.py` harness (`plans/gc-param-sweep/`). It
   sweeps `ECO_HEAP_CONFIG` variants without the bootstrap, which is where parameter exploration
   belongs (`gc-opt-loop.md` §1). Sweep `demote_live_fraction ∈ {0.0, 0.1, 0.25, 0.5, 0.75}` with
   `old_gen_bitmap_alloc: true`, one run each. Record per value:
   - old-gen in-use peak and max RSS;
   - GC time, minor time and the major event log's sweep column;
   - the worst minor pause (phase-timer binary);
   - the residency histogram's page counts per live-fraction bucket;
   - the new stats block's `blocks_classified_{uniform,mixed}`, `gap_sweep_bytes` and
     `virgin_blocks`.
2. **Pick at most two candidates:** the best GC time among the values that pass criterion R
   against `eco-optTG1f`. Measure each as a **compiled default** (lowered binary
   `eco-optTG2-dF`, where F is the value) with a timed triple against `eco-optTG2` (0.5). Timed
   runs never use `ECO_HEAP_CONFIG` (F17).
3. **Adopt a new default only if:**
   - old-gen peak and RSS are no worse than at 0.5 (R holds against 0.5, not just against TG1f);
   - GC time median is better by more than the larger spread;
   - the worst minor pause is no worse.
   Otherwise keep 0.5.
4. **What to expect:**
   - **Lower values** (towards 0.0) mean fewer mixed blocks, so less gap sweep and less
     in-pause sweep. But free space in mostly-dead blocks serves only its own class, which risks
     a higher peak.
   - **Higher values** mean more reusable free space across classes, but more gap sweep and fewer
     blocks on the cheap bitmap path.
   - The E1 table records this trade-off whatever the outcome, and it stays in the loop entry as
     the lever's calibration.

**Record** the result as loop entry **TG2** in `benchmarks/gc-opt-loop.md`, with the tables
above and the E1 table.

**Keep:** snapshot `keep-TG2` (copy the new test files into `keep-TG2/extra-test/`, because the
snapshot script does not cover `test/allocator/`), then `eco-optTG2` → `bin/eco-opt-prev`.

### Step 12 — flip the default, clean up, document

1. With acceptance met, the compiled default is already `true` from P§5.1. **Rerun G1–G8 with
   the default on.** Existing unit tests that assert legacy sweep semantics fail at this point.
   For each one:
   - **it tests the legacy path deliberately** (free lists of uniform classes,
     `populateFromBlock`, sentinels): set `cfg.old_gen_bitmap_alloc = false` in that test's
     config, and say so in a comment;
   - **it tests an allocator property** that should hold in both modes: fix the test to hold in
     both, or add a flag-on twin.
   List every changed test in P§9a.
2. **Do not delete the flag-off path in this phase.** The master plan removes a flag once it has
   been default-on for a release.
3. **Invariants** (P§8): reword HEAP_021, HEAP_024 and HEAP_027; add HEAP_054–056.
4. **`THEORY.md`**, old-gen section:
   - uniform blocks allocate from the bitmap through a per-class cursor;
   - mixed blocks are gap-swept;
   - there are no sentinels.
   Replace step 4 ("Mark-driven live attribution + lazy sweep") accordingly.
5. **Master plan** §4 row 2: status, this plan, and 3–5 facts for phases 6/7. At least:
   - the cursor ownership model;
   - the `demote_live_fraction` lever and its E1-chosen default;
   - uniform blocks are not header-parsable;
   - `live_bytes` is exact for uniform blocks;
   - where the remaining sweep cost is.
   Also update §5's pause trajectory row for phase 2 with the measured worst pause.
6. **The decision on `demoteMostlyDeadUniformBlocks` (master plan scope item): KEEP it as a
   tunable lever, default 0.5,** and set the shipped default from experiment E1 (P§5a).
   - Its former cost was the header sweep of the demoted blocks, which the gap sweep removes:
     3,358 demoted pages hold 187 MB of live data and 916 MB of garbage, and now cost O(live).
   - Turning it off could strand the free space of mostly-dead blocks in their original class
     and hurt retention (criterion R). Whether it does is exactly what E1 measures.
   - If E1 changes the default, change the compiled `DEMOTE_LIVE_FRACTION`, **rerun G8's flag-on
     column**, and record the before/after in the loop entry.

## 6. Traps (read before starting)

1. **The W6 rung.** The virgin block goes at `populateFromBlock`'s rungs *only*. Any rung above
   splitting or sweep-on-demand repeats W6's +33 % RSS into swap. Step 5.4's assert, Step 10.3's
   test and criterion R guard it.
2. **Double allocation from a list cell inside a uniform block.** With the flag on, nothing may
   push a cell of a uniform block onto a free list. The only former producer is
   `freeLargeBodyCell` (P§3.7). V9 checks for it.
3. **Dead large bodies** (F11). Skipping `retireDeadLargeBodies`, or running it after any
   allocation can reuse a cell, reintroduces a double free that shows up as a free-list cycle
   minutes later. It must run before the queues are built.
4. **The four `finishMarkAndSweep` overloads** (F9). Wiring one or two leaves the flag half-on in
   some build configurations (the profile overloads are used by stats builds, which is every timed
   run).
5. **`live_bytes` double counting.** `finalizeBitmapCell` adds `live_bytes` itself and must not
   call `initObjectHeaderWithSize` (P§3.4). V8 catches it.
6. **Header parsing of uniform blocks** (F14). Anything new that walks old-gen blocks must use the
   bitmap for uniform blocks. V11 covers mixed blocks only.
7. **Stats must not change existing banner lines** (P§3.8). `heap-profile.py` and
   `lss-loop-extract.sh` parse them.
8. **Machine hygiene** (phase 1):
   - don't rebuild `build/` while a lowering is running;
   - don't run E2E alongside heavy work (the loopback HTTP tests time out);
   - don't use `pkill -f` with a pattern that matches your own command line;
   - `cp -a`-restored sources keep old mtimes, so `touch` them.
9. **`rc == 0` is not success.** Verify `out.mlir` every time.
10. **Judge counters against a same-session control.**

## 7. Expected result, stated up front

| quantity | reference (TG1f) | expected (TG2) | basis |
|---|---|---|---|
| worst minor-only pause | 915 ms | ≤ 400 ms (the burst is gone; residual: gap sweep of mixed blocks) | baseline §4.3; P§0 table |
| in-pause lazy sweep | 2.23 s, 10.5 GB | < 0.5 s | only mixed blocks; O(live) |
| promotion allocator | 21.8 s, 32.2 ns | lower (bitmap word in L1; no list miss, no neighbour writes) | P§3.9; **unproven: rule 3** |
| GC time | 67.0 s | −1 to −4 s | report §6.3 |
| old-gen peak / RSS | 8.8 GB / 9.66 GB | ±2 % / ±1 % | the same cells are reused; only the order changes |

## 8. Invariants (land in Step 12)

**Reword** (keep each row's id; append "(Reworded 2026-09-2x, threaded-gc-02)"):
- **HEAP_021 FreeCellTag:**
  - free cells in **mixed** blocks (and in all blocks when `old_gen_bitmap_alloc` is off) use
    `Tag_Free` with `header.size` = cell bytes;
  - with the flag on, a free cell in a **uniform** block is a clear cell-start bit in its mark
    bitmap, and its header is stale (a dead object) or absent (a never-allocated cell in a
    virgin block);
  - walkers must not interpret uniform-block headers except at set bits.
- **HEAP_024 BlockParseRange:**
  - mixed blocks parse by header over `[start, end_of_objects)`;
  - with the flag on, uniform blocks are **not header-parsable**, and any walker iterates their
    set cell-start bits instead;
  - unassigned pages remain unparseable.
- **HEAP_027 FreeCellSentinel:** the sentinel protocol applies only with the flag off. With the
  flag on:
  - there are no sentinel producers;
  - `freeLargeBodyCell` clears the body's bit, so it is either reclaimed by the gap sweep
    (unswept mixed block) or immediately reusable by the cursor (uniform block);
  - only a *swept* mixed block receives a free-list push.

**Add:**
- **HEAP_054 BitmapAllocation.**
  - With `old_gen_bitmap_alloc`, a uniform block's mark bitmap is its allocation map: a
    cell-start bit is set ⇔ the cell is allocated (live at the last mark, or allocated since).
  - Uniform blocks are never lazily swept: `classifyBlocksAfterMark` marks them `fully_swept`
    and queues each partially free one on `partial_[class]` in position order.
  - Per class, one `AllocCursor` owns at most one block (`alloc_state == Current`). It scans
    the block's bitmap for clear cell starts and sets the bit on allocation.
  - A block is detached from cursor and queue before it is released, flipped to large, demoted
    or compacted.
  - `live_bytes` of a uniform block equals `popcount(cell-start bits) × cell_bytes` outside the
    mark window.
  - Virgin blocks replace `populateFromBlock` at exactly its ladder rungs (the W6 rule).
  - Demotion to mixed happens iff `live_bytes ≤ demote_live_fraction × totalBytes`
    (`HeapConfig`, default 0.5, bit-identical to the former `live * 2 <= total`); `0.0` disables
    demotion entirely (an explicit early return).
- **HEAP_055 GapSweep.** With the flag on, a mixed block's lazy sweep reads only the headers of
  live objects (its set mark bits) and writes one free run per maximal gap between them. It
  never reads a dead object.
- **HEAP_056 DeadBodyRetirement.** With the flag on, `classifyBlocksAfterMark` erases the
  `large_body_index_` entry of every unmarked nursery-owned body before any cell can be reused
  (the duty the header sweep used to perform), so `sweepNurseryLargeBodies` cannot free a
  reclaimed cell a second time.

## 9. As-built deviations

1. **`sweepWillReach` (a premise correction to P§3.7).** "A mixed block with `!fully_swept`"
   is not the same as "the sweep will still walk over this cell". The lazy sweep of the block
   currently being swept may already have passed the cell: the initial slice steps over live
   objects inside the first mixed block.
   - `freeLargeBodyCell`'s "clear the bit only" row would then lose the cell until the next
     major. The row now tests `sweepWillReach(id, cell)`: the block is not fully swept, and it is
     at a later position, or it is the current block and the cell lies at or after
     `sweep_cursor_`.
   - A cell the sweep has passed is pushed onto a list (no sentinel is needed, since the sweep
     never comes back).
   - The splitter assertion and V9 use the same predicate. The unit test
     `testBitmapFreeBodyInUnsweptMixedBlock` exercises both outcomes.
2. **`populateFromBlock` is untouched.** Instead of factoring a shared `takeBagPage` out of it
   (Step 5.1), `startVirginBlock` uses a new `ensureBagPageAvailable` that duplicates the
   ~10-line acquisition prologue. The flag-off path is then byte-for-byte the old code, with no
   refactor risk.
3. **Legacy sweep-loop condition.** The flag test for the gap sweep is hoisted into a local
   `const bool gap_sweep`. A `config_->…` read in the legacy loop condition would be reloaded on
   every iteration, because the loop body stores through `char*`, which may alias `config_`
   (the W3/W4 rule).
4. **The residency "bitmap-free bytes" stat** is one cumulative counter,
   `bitmap_free_bytes_at_major`, in the new "Old-gen Bitmap Allocation" banner block, not a
   per-class array.
5. **Trap: changing `HeapConfig` needs a FULL rebuild before lowering.** The first C-off/C-on
   checkpoint lowered against a rebuilt `EcoRuntimeStatic` but stale kernel archives, which
   compile `AllocatorCommon.hpp` too. The binary aborted at start-up in `HeapConfig::validate`
   on a mismatched struct layout (rc 139, no output). Run `cmake --build build` (all targets),
   not just `EcoRuntimeStatic`, whenever a shared header's layout changes.
6. **Test-object trap.** A test object's `getObjectSize` must equal the cell it claims.
   - An `Int` header in a 24 B cell makes a demoted (mixed) block's walk land mid-cell and loop
     forever.
   - A `Tag_String`'s `header.size` counts UTF-16 characters, not bytes.
   The bitmap tests use `Int` / `Tuple2` / `Tuple3` objects and `Tag_ByteBuffer` bodies.
7. **The first flag-on checkpoint failed criterion R (RSS 14.4 GB vs 9.66 GB), and the cause
   was the major-GC trigger, not allocation.** The diagnosis (2026-09-25):
   - **Virgin blocks are never taken while reusable space exists.** A temporary trace at every
     `startVirginBlock` recorded:

     | rung | count | same-class block with free cells | class list non-empty | mixed list non-empty |
     |---|---|---|---|---|
     | 3 (bag-first) | 3,270 | 0 | 0 | 3,270 |
     | 6 (growth) | 34,639 | 0 | 0 | 0 |

     So growth happens only when nothing is reusable. The bag-first rung preempting mixed
     spans within its budget is intended (user decision, 2026-09-25): a fixed-size virgin
     block beats carving mixed space.
   - **Legacy takes about the same number of fresh pages:** a bpftrace count shows 38,108
     `populateFromBlock` calls vs 37,909 virgin blocks.
   - **The trigger runs away.** Bitmap mode's post-major sweep covers only mixed blocks, so it
     completes sooner. `post_sweep_live_bytes_` is reset at that point, and majors 3–5 fire
     earlier. The 5th major then landed on the program's live-set peak (~3.2 GB live near minor
     850, sampled by both bitmap runs; the legacy schedule happens to miss it).
   - **After that, the garbage-fraction trigger chases itself.** Garbage cannot be reused before
     the next major, so every byte allocated grows committed.
     `(alloc since sweep) / current committed ≥ 0.7` then needs ≈ 2.3× the old committed to
     fire: the 6th major came at 12.7 GB after 682 minors (14 s mark, 16.8 s sweep). This
     pathology exists in legacy mode too; its schedule just never hit a peak.
   - **Denominator variants (bitmap mode, gf 0.70, majors / RSS / GC).** Reference: 6 /
     9.66 GB / 67.0 s.

     | variant | demote 0.5 | demote off |
     |---|---|---|
     | frozen at `committed_at_major_` | 12 / 10.26 GB / 80.5 s | 14 / 9.05 GB / 84.9 s |
     | damped | 13 / 10.83 GB / 78.4 s | 16 / 6.72 GB / 77.4 s |
     | capped `min(committed, 2·cam)` | 7 / 11.85 GB / 73.0 s | 10 / 7.41 GB / 75.4 s |

     The cap is now the `garbage_denom_cap` lever (default 2; 0 = uncapped).
   - **The trigger is chaotic in LEGACY mode too (garbage-fraction sweep, same binary,
     2026-09-25).** The reference point is lucky. Legacy at gf 0.65 / 0.66 / 0.68 /
     **0.70** / 0.72 / 0.74 / 0.75 gives:
     - majors: 7 / 7 / 6 / **6** / 6 / 5 / 4
     - old-gen peak (GB): 11.8 / 12.7 / 10.1 / **8.8** / 9.2 / 13.9 / 16.2

     The peak depends on whether a major lands on the ~3 GB transient live peak: the
     trigger sizes the heap at about 3.3× the live set seen at one instant.
   - **Bitmap mode at gf 0.66 / 0.68 / 0.70 / 0.72:**

     | variant | majors | old-gen peak (GB) |
     |---|---|---|
     | uncapped | 7 / 6 / 6 / 5 | 11.9 / 10.5 / 13.8 / 13.4 |
     | cap 2 | 8 / 7 / 7 / 7 | 10.1 / 10.5 / 10.9 / 11.7 |
     | cap 3 | 7 / 7 / 6 / 5 | 10.0 / 12.9 / 13.5 / 16.1 |

     - Uncapped bitmap has the same majors as legacy (or fewer); cap 2 adds one.
     - No cap setting dominates, so the fix is a peak-robust trigger, not a denominator
       tweak.
     - This machine has 15 GB: runs above ~14 GB RSS swap, so their wall and GC times are
       invalid.
   - **Peak-robust trigger under test: `LiveBudget`.** Levers `major_gc_live_budget` k and
     `live_growth_bound` r, both modes, 0 = off. A major fires when bytes allocated since the
     last major reach k · min(L_i, r · L_{i−1}), where L is the mark-derived live set.

     Results, bitmap uncapped, r = 1.5, gf 0.66 / 0.70 / 0.72 (`eco-optTG2pt-c14`, output
     identical in every run):

     | k | majors | old-gen peak (GB) | major GC time |
     |---|---|---|---|
     | off | 7 / 6 / 5 | 11.9 / 13.8 / 13.4 | 6.6–9.7 s |
     | 2.33 | 10 / 10 / 9 | 9.8 / 9.9 / 8.6 | 12–14 s |
     | 3.5 | 9 / 8 / 8 | 8.3 / 8.0 / 8.3 | 12–13.5 s |
     | 4.0 | 8 / 7 / 7 | 7.6 / 10.0 / 11.9 | 9–14.6 s |
     | 4.5 | 7 / 6 / 6 | 11.2 / 10.5 / 10.4 | 8.0–10.5 s |

     - Legacy with k = 2.33: 10 / 11 majors, peak 10.4 / 8.9 GB at gf 0.66 / 0.70.
     - Wall is 2:58–3:06 everywhere, legacy 3:03–3:08.
     - LiveBudget trades majors for a bounded peak. Only k = 3.5 has a tight band so far
       (3 samples per point).
     - **Default chosen (user, 2026-09-25): k = 4.5, r = 1.5, `garbage_denom_cap` = 0.**
9. **Experiment E1 (`demote_live_fraction`),** run on `eco-optTG2pt-c14` with LiveBudget
   k = 4.5 and r = 1.5, uncapped, at gf 0.66 / 0.70 / 0.72. Output was identical in every run.
   Promotion cost is 15.3–18.6 ns at every value.

   | demote | majors | old-gen peak (GB) | major GC | minor GC | worst minor pause | gap-swept | mixed blocks |
   |---|---|---|---|---|---|---|---|
   | 0.0 | 9 / 8 / 8 | 8.82 / 8.81 / 8.81 | 13.1–13.7 s | 53.7–54.1 s | 152–158 ms | 0.5–0.6 GB | ~1.0 k |
   | 0.1 | 7 / 6 / 7 | 13.1 / 13.1 / 9.4 | 9.6–11.1 s | 54.4–55.1 s | 152–160 ms | 1.8–3.5 GB | 3.4–6.8 k |
   | 0.25 | 8 / 7 / 6 | 9.7 / 8.5 / 10.2 | 8.1–12.1 s | 54.4–55.2 s | 158–177 ms | 2.3–4.8 GB | 4.4–9.2 k |
   | 0.3 | 7 / 7 / 7 | 9.9 / 8.8 / 9.9 | 9.3–12.7 s | 55.0–55.3 s | 162–238 ms | 2.7–4.5 GB | 5.1–8.6 k |
   | 0.4 | 7 / 7 / 6 | 10.7 / 10.0 / 10.4 | 8.1–11.2 s | 54.4–55.5 s | 205–221 ms | 2.7–5.1 GB | 5.1–9.7 k |
   | **0.5** | 7 / 6 / 6 | 11.2 / 10.5 / 10.4 | 8.0–10.5 s | 54.8–55.2 s | 211–267 ms | 3.0–3.6 GB | 5.7–6.8 k |
   | 0.75 | 7 / 6 / 7 | 13.8 / 10.3 / 10.2 | 8.4–28.7 s | 55.2–56.3 s | 560–683 ms | 5.3–9.2 GB | 10–17.5 k |

   - **0.0** pins the peak at the reference's 8.8 GB (occupancy triggers take over) and has the
     lowest pauses. It costs 1–3 extra majors: about +3–5 s of major GC and +2 s wall.
   - **0.75** brings back half-second pauses through the gap sweep.
   - **0.1 and 0.25** are noisy.
   - **Decision by the P§5a rule** (adopt only if memory, GC time and worst pause are all no
     worse than at 0.5): **0.5 is kept.** Use 0.0 when memory or pause predictability matters
     more than major count.
8. **The P§4 Step 2 scan as specified was SLOWER than the legacy free-list pop.** It measured
   32.9–33.6 ns per promotion allocation vs 31.1 ns (phase-timer sampler, 675.8 M calls).
   `perf annotate` put the cost in `nextFreeCell`: four integer `div`s per call
   (`(w*64) % m`, `64 % m`, `(m - r) % m`, `g / m`) plus a runtime `strideMask` loop.
   - **Fix, part 1: a hit path in `cursorAllocate`.** It tests the next cell's bit directly
     (one multiply, one byte load). That always hits in a virgin block and inside a free run.
   - **Fix, part 2: the scan runs only on a miss** and uses a `constexpr` per-stride table:
     the pattern, `64 % m`, and a `ceil(2^32/m)` reciprocal (exact `g/m` for `g < 2^16`).
     The phase advances by add-and-compare per word.
   - **Result (`eco-optTG2pt-c12`, output byte-identical): 15.2 ns (demote off) and 16.7 ns
     (demote 0.5)** — 2× faster than legacy.
   - Most strides are not powers of 2 (m = 3, 5, 6 for 24/40/48 B cells), so shifts alone
     cannot replace the division. If the scan's one entry `%` ever shows up in a profile, keep
     the cursor in bit units (`next_bit += m`; address = `base + (bit << 3)`).

10. **Acceptance and gates, default on (2026-09-25).** `eco-optTG2` vs the same-session
    control `eco-optTG1f`, medians of 3, strictly serial:

    | criterion | result |
    |---|---|
    | P | minor-only max 976 → 178 ms (≤ 400 ✓). The byte bound (≤ 256 MB in-pause sweep per pause) fails as written — the largest pause covers 938 MB — but that bound was calibrated for the header walk. The gap sweep's worst in-pause sweep TIME is 63 ms (was 820 ms), so the intent holds |
    | R | old-gen peak 8,790 vs 8,824 MB (−0.4 %); max RSS 9,622,612 vs 9,663,784 kB (−0.4 %) ✓ |
    | A | 16.1 vs 32.0 ns per promotion ✓ (after item 8's fix; 33 ns as first built) |
    | G | GC 67.32 vs 67.38 s ✓ (flat: minor −4.14 s, major +4.18 s for one extra major) |
    | W | wall 180.97 vs 183.37 s, inside the control's 5.6 s spread ✓ |
    | M | mark 41.27 vs 40.16 ns per marked object (+2.8 %): marginal, inside the control's own 4 % spread. Collections cannot be paired (7 vs 6 at different points); the +3.85 s mark total is volume (279 M vs 191 M marked objects) |
    | C | output identical ×7; minors, promoted, objects allocated (254,094,414 — the control reads the same today) and per-tag retention identical ✓ |

    - **The worst pause containing a major grew, 2.64 → 4.72 s:** the extra LiveBudget major
      collects a larger live set. Phases 4/5 target exactly that pause.
    - **Gates:**
      - G1: unit + E2E 1,757/1,757 in the main and phase-timer trees.
      - G2: elm-tests 13,565/12 (the reference set).
      - G3: `--target full` 1,757/1,757.
      - G4: stress 100/100 at 1,263 minors.
      - G5: validate 1,758/1,758 with the pinned seed and zero `[heap-validate]` lines;
        validate stress 95/100, the 5 known `JsonRoundtrip*` aborts.
      - G6: stats-off `ecoc` builds.
      - G7: clean.
    - **G5 found a latent defect.** In bitmap mode a major leaves nothing to sweep when there are
      no mixed blocks, so the GC is Idle at once and `scheduleCompaction` (which bails while
      sweeping) can now run right after a major.
      - `fixReferencesSlice` calls `freeEvacuatedBuffers()` with the fixup cursor at the old
        block count. The erase then leaves it past the end, and the HEAP_048 cursor-range check
        fired, reading a dead position.
      - Fixed by resetting the dead fixup cursor in `freeEvacuatedBuffers`.
      - Proved new by building `keep-TG1`'s runtime in the validate tree: the same seeds pass
        there because the GC is still Sweeping when compaction is asked.
    - **Trap: `ECO_HEAP_CONFIG` does not reach the old gen in `test/test`.** `initAllocator` →
      `AllocatorTestAccess::reset` installs the raw config. A JSON "flag-off" unit run is
      silently flag-on (the G1 "flag on (JSON)" column's premise). Set the field in the test's
      config instead. The seed is pinned with `--seed`, not an environment variable.
    - **No unit test needed repinning to legacy:** the whole suite passes in bitmap mode.

## 10. Out of scope (and where it goes)

| item | where |
|---|---|
| per-thread cursors; parallel promotion into owned blocks; object-bytes minor trigger | phase 6 |
| a concurrent sweeper for the residual mixed-block work | phase 8 (report §6.2 option A), only if a residual remains |
| prefaulting virgin pages (`MADV_POPULATE_WRITE`) for the 4.9 M in-minor page faults | phase 3's helper pool (first user) or phase 8 |
| en-masse survivor-prefix promotion | phase 6 variant (report §7.3) |
| deleting the flag-off path and `populateFromBlock` | after one release default-on |
| any mark-path change | phases 4–5 |

## 11. Done means

- G1–G8 are green with the default **on**; the flag-off column was green before the flip.
- P§5 acceptance holds: P, R, A, G, W, M and C, with any A exception diagnosed and recorded.
- Experiment E1 has been run and the `demote_live_fraction` default chosen by its rule; its table
  is in the loop entry.
- HEAP_021/024/027 are reworded, and HEAP_054–056 are added.
- Snapshot `keep-TG2` is taken, and `eco-opt-prev` is updated.
- The loop entry TG2 is written.
- The master plan's row 2 and §5 are filled in.
