# Threaded GC — TLA+ model M4: old-gen allocation and mark-bitmap bytes

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). Had an adversarial review on 2026-09-28
against the current tree (§11): the sketch was revised and passes the translator and SANY again;
TLC has not run.

**Parents:** `plans/threaded-gc-tla-verification.md` (§2 rules A1–A9, §5.1 index) and
`plans/threaded-gc-tla-primer.md`. Read primer §3.2 (plain read-modify-writes), §3.4 (locks
with unlocked readers) and §3.7 (a data-race detector) first. **Sibling:**
`plans/threaded-gc-tla-M2-slice-control.md`, whose shape this plan follows.

**Why M4 exists.** The other models treat "set the mark bit" and "allocate a cell" as single
atomic events on single objects. The hardware does not. A mark bitmap byte holds the bits of eight
neighbouring slots, so threads working on *different* objects still share a byte. Some code paths
update that byte with an atomic `fetch_or`; others use a plain `b |= mask`, which is a load
followed by a store. Whether a plain update is safe depends on who else can touch the same byte at
that moment. That in turn depends on:
- ownership rules: IM13, the per-worker chunks, the tenure grant;
- the promotion lock `promo_mu_`;
- the phase field `gc_phase_`, which some threads read without the lock.

M4 is the one model that works at byte granularity (and at 64-bit word granularity for the
bitmap scans) and carries a **data-race detector** as an invariant. Four register entries live
here, each with its own configuration (§6):
- **CR-001:** the `gc_phase_` race and its moved decision point (its S1 half is §2.5 item 1);
- **CR-002:** the plain `clearBit` and the plain word scan against an atomic `fetch_or`;
- **CR-014:** `lazySweep`'s tail completion runs the shrink on a worker (§2.5 item 2);
- **CR-016:** the empty-block flip under `promo_mu_` (§2.5 item 3; test geometries only).

---

## 1. What the model checks, in one paragraph

Old-gen memory is handed out by several kinds of allocator:
- parallel-minor promotion workers, from per-worker chunks of a shared block, from the free lists
  under a lock, and from a stash of cells popped under the lock but finalized outside it;
- the mutator, from its own cursor and from the free lists;
- the 7c tenure collector, from blocks granted to it.

Meanwhile, a background marker sets mark bits of objects that existed when the mark cycle started,
and a lazy sweep clears mark bits and turns dead gaps into free cells.

Every one of these ends in a read-modify-write of a mark byte. M4 checks, over every interleaving
of 2–4 such threads on a heap of 7 blocks and 19 cells:
- that no mark bit that must survive is ever lost;
- that no cell is handed out twice;
- that no block is released (or flipped to large) while it still holds live cells or belongs to
  someone;
- that no C++ data race exists on a mark byte, on `gc_phase_` or on `live_bytes`.

The last property is the rule that a plain access racing with any conflicting access is undefined
behaviour, checked with vector clocks the way ThreadSanitizer does.

## 2. The protocol in plain words

### 2.1 The pieces

- **Mark bitmap bytes.** Every old-gen block has a bitmap with one bit per 8-byte slot, so one
  byte covers 64 bytes of heap (`markBitLocation`, `OldGenSpace.hpp:1753`). An object's bit is
  the bit of its first slot. Two small objects next to each other share a byte. Different blocks
  never share a byte: each block's bitmap is its own arena slot (HEAP_050).
- **Bitmap words.** Single bits are set and cleared a byte at a time (`bitscan::setBit` /
  `clearBit`, `BitmapScan.hpp:34`, `:37`). The scans `nextFreeCell` (`:84`, the cursors and the
  grant) and `nextSetBit` (`:118`, the gap sweep) read whole 64-bit words with a plain `memcpy`
  (`loadWord`, `:25`). A word covers 64 slots (512 heap bytes), so a plain scan races with a
  `fetch_or` on **any** byte of the word it reads. Arena slots are 64-byte aligned, so blocks
  never share a word either.
- **Uniform and mixed blocks.**
  - A **uniform** block holds cells of one size class. Outside a mark cycle its bitmap *is* its
    allocation map: bit set ⇔ cell allocated (HEAP_054). Allocating a cell means setting its bit.
  - A **mixed** block holds objects of varied sizes. After a mark it is **gap-swept**: the sweep
    walks the set bits (the live objects), clears each one, and turns each gap between live
    objects into a free cell on a size-class free list (HEAP_055).
- **Allocate-black.** During a mark cycle, or while a sweep is still pending, every old-gen
  allocation also sets its mark bit, so the coming sweep does not free it. In the code this is the
  `marking_active || gc_phase_ != Idle` test in `initObjectHeaderWithSize`
  (`OldGenSpace.cpp:497`), `finalizePoppedCellW` (`:1075`) and `finalizeBitmapCellW` (`:1135`).
  Non-cursor paths use an atomic `fetch_or` (`setMarkBitAtomic`, `OldGenSpace.hpp:1822`). The
  cursor paths use a plain `bitscan::setBit`, which IM13 justifies (§2.4 d).
- **Cursors, the shared block and chunks (phase 6).** Inside a parallel minor, workers share one
  current block per size class and take **chunks** of it: 64-cell units. For cells of m slots a
  unit is 64 × m bits = m whole 64-bit words, which is what the word-reading `nextFreeCell` needs
  (the code's comments at `OldGenSpace.hpp:630-631`, `:639-640`, `:689` and `OldGenTenure.cpp:202` argue only "whole bytes": premise drift, though the code is right). They take a chunk
  by CASing the word `(block id + 1) << 32 | next unit` (`claimChunkW`, `OldGenSpace.cpp:1171`);
  the chunk's end is clamped to the block (`:1189-1190`). A worker then allocates inside its own
  chunk with plain bit sets and no lock (`cursorAllocateW`, `:1146`). At the minor's start the
  mutator's cursor block becomes the shared block, from the unit of its next cell
  (`beginParallelPromotion`, `:1398-1405`).
- **The ladder and `promo_mu_`.** When a worker's chunk is used up and no chunk can be claimed, it
  takes the spin lock `promo_mu_` (`allocatePromotion`, `:1536`) and tries, in order:
  1. advancing the shared block (`advanceSharedW` `:1219`, `startVirginBlockShared` `:1249`);
  2. popping one cell plus up to 16 more (its **stash**) from the free list (`:1617-1624`);
  3. the rest of the ladder (`ladderFrom2W`, `:1306`), including **sweep-on-demand** (`:1336`),
     the virgin and bag rungs (`:1344-1345`) and the panic sweep (`:1346`). Sweep-on-demand and
     the panic sweep run slices of the lazy sweep **under the lock**, and pop a cell of the
     worker's own class after each slice (`sweepOnDemandAllocate`, `:2136`).
- **The free lists are LIFO.** `pushSpanOnFreeLists` pushes at the head (`:4989-4997`) and
  `tryPopFromFreeList` pops the head (`:2004`): the last gap the sweep flushed is popped first.
- **The stash.** Cells popped under the lock are **finalized outside it**: the first one right
  after the unlock (`:1634`), the rest by later promotions before they take the lock (`:1580-1583`).
  Finalizing writes the header, and, if the phase says so, sets the mark bit (atomic) and adds the
  cell to the block's `live_bytes` (atomic) (`finalizePoppedCellW`, `:1069`).
- **`gc_phase_`** (`OldGenSpace.hpp:815`) is a **plain** field: Idle, Marking or Sweeping. The
  sweep sets it to Idle when it passes the last block.
- **`live_bytes`** (per block) counts live bytes: marked objects plus allocate-black allocations.
  Its **readers decide whether a block is empty**:
  - the light-pass shrink run by `onSweepComplete` (`:5488`) → `computeFragmentationStats`
    (`:6369`) and `maybeShrinkCapacity` pass 1 (`:5796-5810`), which releases fully swept blocks
    with `live_bytes == 0`. Both read `live_bytes` with plain loads;
  - the empty-block flip `allocateFromEmptyRegularBlocks` (`:2665`), reached by a promotion of
    **exactly** `alloc_buffer_size` bytes: a regular block's size is `alloc_buffer_size`, and the
    flip skips blocks smaller than the request (`:2680`).

  An **under**-count therefore means a block with live objects can be released. This is the
  historical bug in parallel-gc.md §3.5. Note that a free-list cell of a **mixed** block adds to
  `live_bytes` only while `gc_phase_ != Idle` (`initObjectHeaderWithSize`, `:497`): after the
  sweep completes, a mixed block's `live_bytes` stops counting new objects.
- **Deferring the sweep's end (phase 6).** If the sweep completes inside a parallel minor with
  more than one worker, `sweepCompleteInPromotion` (`:1361`) only records
  `sweep_complete_deferred_`. `endParallelPromotion` (`:1416`) runs `onSweepComplete` after the
  join (`:1530-1533`), once all worker cursors are flushed.
- **The tenure grant (7c).** The hand-over pause gives the tenure collector whole uniform blocks,
  in state `kAllocTenure` (`grantTenure`, `OldGenTenure.cpp:44`). The collector allocates in them
  with plain bit sets (`grantAllocate` `:153` / `grantAllocateShared` `:197`) while the mutator
  runs. Every mutator-side path skips granted blocks:
  - the shrink (`:5805`), the flip (`:2679`) and requeueing (`:1710`);
  - detach, `freeUniformCell` and `resetAllocCursors` abort on one (`:698`, `:964`, `:684`).

  The grant is returned at the next minor (`returnTenureGrant`, `:288`).

### 2.2 Who runs at the same time as whom

| Actor | When it runs | Overlaps with |
|---|---|---|
| Background markers (5c) | throughout a mark cycle: mutator time **and** minor pauses | everyone below, while a cycle runs |
| Parallel-minor promotion workers (phase 6; 7c's pause engine and help) | inside a minor pause, mutator stopped | each other; background markers |
| Lazy / gap sweep | on whichever thread allocates: the mutator (between minors) or a worker inside a ladder rung (under `promo_mu_`) | a worker's sweep overlaps the other workers. A sweep never overlaps a mark cycle: `prepareMark` drains it first |
| The mutator | between pauses | background markers; the 7c tenure collector |
| 7c tenure collector | between pauses (job launched at the end of minor m, joined at the start of minor m + 1) | the mutator; background markers. **Not** the minor's workers: it is joined before the minor starts |

The promotion workers are not only the phase-6 minor's (`NurseryParallel.cpp:259`). 7c's
pause-only engine `runJobParallel` (`NurseryTenure.cpp:1168`) brackets the same promotion
context, and its workers call `allocatePromotion` (`:984`). It runs on three paths: the sync
tenure mode (`:523`), the grant fallback near the old-gen cap (`:549`), and help of a large
extent in the next pause (`:643`). All four register entries are reachable from them as well
when a lazy sweep is pending; CR-014 even with one worker (`max(1u, …)` at `:549`), the others
only with two or more (the stash exists only for N > 1).

Two consequences shape the model:
1. CR-001, CR-002, CR-014 and CR-016 need a sweep and **two workers that both reach the lock**.
   They live in a minor that runs outside a mark cycle (scenarios `sweep` and `sweep_virgin`).
   The shared block therefore has a single free cell left, so the worker that claims it also
   runs out and takes the lock (with 2 cells, as first drafted, only one worker ever did).
2. Lost *required* mark bits need a running cycle, and so a marker (scenarios `cycle` and `epoch`).
   In `cycle`, likewise, the chunks hold 3 free cells for 4 promotions, so some worker reaches
   the free list and its stash.

### 2.3 Worked timelines

**(a) A lost allocate-black bit (05c audit row H1).** A mid-cycle allocation of cell 1 and the
marker's discovery of live object 2 both land in byte M1:

| # | Worker W (plain `b \|= 1`) | Marker K (`fetch_or 2`) | byte M1 |
|---|---|---|---|
| 1 | reads M1 = `{}` | | `{}` |
| 2 | | `fetch_or`: sets 2 | `{2}` |
| 3 | writes back `{} ∪ {1}` | | `{1}`: **object 2's bit is lost** |

At the handoff, object 2 looks dead and the sweep frees it: silent heap corruption. The code
therefore uses `setMarkBitAtomic` on these paths, and `test_plain_allocate_black_` is the
negative-control hook that puts the plain version back. That hook lives only in
`initObjectHeaderWithSize` (`:515`): the mutator's pops and the pops under the lock, **not**
`finalizePoppedCellW` (`:1083` has no plain branch). The model's mutant `plain_allocate_black` is
this timeline on the mutator's pop (scenario `epoch`); `plain_stash_black` is the same timeline on
a worker's stash finalize (a model-only code change, scenario `cycle`).

**(b) CR-001: the `gc_phase_` race, and the decision that moved.** Workers W1 and W2 run a
parallel minor while a lazy sweep is pending (`gc_phase_ = Sweeping`):

| # | W1 | W2 | state |
|---|---|---|---|
| 1 | | takes `promo_mu_`, pops cell 6 (block D) into its stash, unlocks | phase Sweeping |
| 2 | takes `promo_mu_`, sweep-on-demand passes the last block: `gc_phase_ = Idle` (plain write), defers `onSweepComplete`, unlocks | | phase Idle |
| 3 | | finalizes cell 6 **outside the lock**: reads `gc_phase_` (plain read) → Idle → skips `live_bytes += cell` and the mark bit | `live_bytes[D]` unchanged |
| 4 | (join) `endParallelPromotion` runs the deferred `onSweepComplete` → light shrink | | |

Step 3 is two problems:
- **A data race.** Step 2's plain write and step 3's plain read are not ordered by any lock or
  atomic. That is undefined behaviour however harmless the values look.
- **A moved decision point.** In serial code the pop and the finalize are adjacent, so the pop's
  phase decides. Here the phase is read later, after another thread changed it. Even with an
  atomic `gc_phase_` this would happen. It also happens without a stash: a pop **under the lock**
  after step 2 reads Idle legitimately.

In both cases, cells allocated between the sweep's completion and the **deferred** shrink carry no
`live_bytes`. In serial code the shrink runs at the completion itself, before any such allocation.
If block D's `live_bytes` was 0 (an all-dead mixed block kept by the minimum-heap rule and then
swept to free cells), the shrink at step 4 releases D with a freshly promoted object in it. The
register lists CR-001 as "S2, possibly S1". The model's scenario `sweep` makes the S1 half a
checked property (`ReleasedSafe`, configuration `sweep_release`). The race itself is reachable
from two reads: the stash finalize's (`:1075`, step 3) and a chunk allocation's (`:1135`).

**(c) CR-002: plain `clearBit` against `fetch_or` on one mixed-block byte.** Byte M1 covers cells
1, 2 and 3: cell 1 is a dead gap, cells 2 and 3 are live. The gap sweep runs in budgeted slices,
each under its own hold of `promo_mu_`. One loop iteration finds the next live object with
`nextSetBit`, flushes the gap before it (`flushRun`, `:5359`) and clears its bit (`:5360`); the
budget is tested only at the loop's head (`:5336`):

| # | W1 (sweeping, under the lock) | W2 | byte M1 |
|---|---|---|---|
| 1 | slice 1: flushes gap 1 to the free list, clears 2's bit, budget ends; cell 1 is of another class than W1's, so W1 does not pop it; unlocks | | `{3}` |
| 2 | | locks, batch-pops cell 1, unlocks | `{3}` |
| 3 | slice 2 (locked): `nextSetBit` reads M1's word, then `clearBit` reads M1 = `{3}` | | `{3}` |
| 4 | | finalizes cell 1 outside the lock: `fetch_or` sets 1 | `{1, 3}` |
| 5 | writes back `{3} \ {3}` | | `{}`: **cell 1's bit is lost** |

The lost bit is behind the sweep cursor and no mark cycle is running, so it looks harmless: the
next `startMark` clears the bitmap. But steps 3–5 are a plain read-modify-write racing an atomic
one on the same byte, and that is undefined behaviour. `nextSetBit`'s plain **word** read races
the same way, with a `fetch_or` on any byte of that word: the window is 512 heap bytes, not 64.
The class mismatch in step 1 is what the one-class model expresses by letting the sweeper leave
a flushed cell on the list (§4.1); without it the sweeper takes cell 1 itself and nothing races.

**(d) Why IM13 makes the plain cursor, chunk and grant bit sets safe.** A plain RMW is safe when no
other thread can touch the same byte until the next synchronisation.
- **Background markers** set bits only for objects that existed at t0, so only bytes of **t0
  blocks**.
- **IM13** says every cursor, every shared promotion block and every tenure grant uses only blocks
  **created after t0**, during a cycle. Asserted in `setCursor`, `setCursorW`, `publishShared` and
  `grantTenure` (TV5).
- **Chunks** are whole 64-bit words and belong to one worker (L3 grant chunks too:
  `tenureChunkCells` is a multiple of 64 cells, `OldGenSpace.hpp:696-699`). Whole bytes would
  not be enough: `nextFreeCell` reads words. A **grant** block belongs to the collector, and
  every mutator path skips it.

So no other thread writes those words, and the plain `setBit` at `OldGenSpace.cpp:820`, `:1131`
and `OldGenTenure.cpp:177`, `:214`, with the plain word scans before them, is race-free. The
model's mutants break each premise in turn (§5) and must produce races or double allocations.

### 2.4 What the model does not have to decide

- The allocate-black `fetch_or` against the marker's `fetch_or`: both are atomic, so this is
  fine. W3 checks the relaxed ordering at C11 level.
- The free-list links and Tier-M back-links (HEAP_052): always written under `promo_mu_` or by
  the single mutator.
- Large-object marks (`largeMark` bytes), and the `largeMark = 0` on reuse of a free t0 large
  block: the 05c audit argues these away (no S_H object lives there). The model has no large
  blocks; the audit argument is recorded in MAPPING.md.

### 2.5 Three suspicions this model must settle

Found while writing this plan, by reading the current tree. **Not reproduced.** Item 1 is the
S1 half of CR-001 (its 2026-09-28 update); item 2 is CR-014; item 3 is CR-016.

1. **The deferred shrink can release a block that holds cells allocated after the sweep
   completed (timeline b, steps 2–4).**
   - Evidence: `finalizePoppedCellW` (`OldGenSpace.cpp:1075-1086`) and `finalizePoppedCell`
     (`:2025`) → `initObjectHeaderWithSize` (`:497-520`) add `live_bytes` only when
     `gc_phase_ != Idle`; `sweepCompleteInPromotion` (`:1361-1366`) defers; `endParallelPromotion`
     runs `onSweepComplete` at the end (`:1530-1533`); pass 1 of `maybeShrinkCapacity` releases
     `fully_swept && live_bytes == 0` blocks (`:5802`).
   - Precondition: an all-free mixed block survives to the sweep (kept by the `min_heap` floor of
     `reclaimAllDeadBlocksFromMeta`, `:6214`).
   - Checked by `ReleasedSafe` in scenario `sweep` (configuration `sweep_release`), both through
     a stashed cell and through a pop under the lock after the completion.
2. **`lazySweep`'s tail completion path bypasses the parallel deferral (CR-014).** The in-loop
   completion calls `sweepCompleteInPromotion` when `par_promo_active_` (`:5254-5255`). The tail
   path (`:5467-5472`) sets `gc_phase_ = Idle` and calls `onSweepComplete()` **directly**, on a
   worker, under `promo_mu_`, while other workers are allocating. It needs no exact coincidence:
   the last block's final loop iteration (typically its trailing dead run, counted as one step at
   `:5347-5348`) must use up the slice budget, and the target class's list must still be empty
   (else the early exit at `:5452-5460` returns first). Then:
   - `computeFragmentationStats` (`:6378`) and pass 1 (`:5802`) read every block's `live_bytes`
     with plain loads while other workers `fetch_add` it outside the lock (`flushCursorW` `:1033`,
     `finalizePoppedCellW` `:1084`): a data race whatever the shrink's sizing decides;
   - the light shrink sees the shared block's `live_bytes` without the workers' unflushed
     `pending_live`, so it may pick it. `releaseBlockToAllocator` → `detachFromAllocation` then
     aborts in every build ("detachFromAllocation during a parallel minor", `:712-717`): a loud
     crash;
   - an exhausted, retired (`kAllocNone`) shared block that a worker's last chunk still points
     into, or a mixed block whose popped cells are still unfinalized in a stash, reads
     `live_bytes == 0` and is released **silently** (detach returns early for `kAllocNone`
     blocks). The worker then writes into released memory.

   This is reachable at N = 1 too, in 7c's pause engine (`runJobParallel(…, 1)` still sets
   `par_promo_active_`). Checked by the `W_Shrink` step: the assertion models the detach FATAL
   (configuration `sweep_tail`, which needs the virgin-like shared block V), `ReleasedSafe` the
   silent case (`sweep_tail_release`) and `NoRaceLive` the race (`sweep_tail_live`).
3. **The empty-block flip can repurpose a block that is still in use (CR-016).** A promotion of
   exactly `alloc_buffer_size` bytes takes `promo_mu_` and calls `allocateLargeBlock`
   (`:1542-1553`) → `allocateFromEmptyRegularBlocks` (`:2665`), which flips the first
   `fully_swept` block with `live_bytes == 0` to large. Inside a parallel minor it skips only
   `kAllocCurrent` and `kAllocTenure` blocks (`:2676-2679`). It can therefore pick:
   - a mixed block whose popped cells sit unfinalized in another worker's stash (their
     `live_bytes` is added only at the finalize);
   - a retired (`kAllocNone`) shared block whose cells are all in workers' unflushed chunks: the
     comment at `:2674-2675` names this hazard, but the test covers only Current blocks;
   - a mixed block whose cells were popped after the sweep completed (item 1).

   The flip also writes `live_bytes`, `is_large` and the bitmap slot (`mark_.drop`, `:2712`)
   while other workers read them without the lock. Test geometries only: a nursery object of
   exactly a block's size cannot exist at the 512 KiB default. Checked by `ReleasedSafe` with the
   precondition `large_promo` (configuration `sweep_large`).

## 3. The code the model covers

Line numbers are from the tree of 2026-09-28, after the 7c pull.

| Code | Lines | Model element |
|---|---|---|
| `markBitLocation`, `testAndSetMarkBitInBlock`, `setMarkBitInBlock`, `setMarkBitAtomic`, `isMarkedInBlockRelaxed`, `testAndClearMarkBitInBlock` | `OldGenSpace.hpp:1753`, `1780`, `1800`, `1822`, `1836`, `1853` | `bits[y]` (a byte = the set of its set cells); `ByteOf(c)` |
| `bitscan::loadWord` (plain `memcpy` of a word), `setBit`, `clearBit`, `nextFreeCell`, `nextSetBit` | `BitmapScan.hpp:25`, `:34`, `:37`, `:84`, `:118` | `WordOf(y)`, `WordRd(y)` (a scan reads every byte of its word); byte writes |
| `promo_mu_` (a `minorwork::SpinMutex`) | `OldGenSpace.hpp:765`; `MinorWork.hpp:85-113` | `lock`, `LockAcquire`, `LockRelease` (plus the clock `lockvc`) |
| `gc_phase_` | `OldGenSpace.hpp:815` | `phase` (a plain location for the race detector) |
| `initObjectHeaderWithSize` (allocate-black; `test_plain_allocate_black_` `:515`) | `OldGenSpace.cpp:487-534` (atomic set `:518`) | `U_PopBit`; the mutant `plain_allocate_black` |
| `finalizeBitmapCell` (mutator cursor, plain `setBit`) | `:802-836` (`:820`) | `U_Cursor`, `U_CursorSet` |
| `flushCursorW` (atomic `live_bytes` add `:1033`) | `:1029` | the flush in the claim branch (location `"live"`); `G_Flush` |
| `finalizePoppedCellW` (stash finalize; phase read `:1075`; atomic set `:1083`) | `:1069-1096` | `W_StBit` (after the finalize branch) |
| `finalizeBitmapCellW` (chunk cell; plain `setBit` `:1131`; phase read `:1135`) | `:1121-1142` | `W_R1Phase`, `W_R1Set` |
| `cursorAllocateW` | `:1146-1170` | the rung-1 branch |
| `claimChunkW` (CAS on the shared word) | `:1171-1198` | the claim branch; `SharedSync` |
| `publishShared`, `advanceSharedW`, `startVirginBlockShared` | `:1201`, `:1219`, `:1249` | `W_Locked`, first case |
| `ladderFrom2W` (sweep-on-demand, panic sweep) | `:1306-1347` | `W_SwChk` … `W_PopBit` |
| `sweepCompleteInPromotion` (defer when N > 1) | `:1361-1385` | `deferred := TRUE` in `W_SweepEnd` |
| `endParallelPromotion` (flush, stash return `:1440`, deferred `onSweepComplete` `:1530`) | `:1416-1534` | process `Merge` |
| the callers of `allocatePromotion`: the phase-6 parallel minor (`copyClaimed`); 7c's `runJobParallel` (sync `:523`, grant fallback `:549`, help `:643`) and its workers; the serial identity switch (stats builds) | `NurseryParallel.cpp:259`; `NurseryTenure.cpp:1168-1200`, `:984`; `NurserySpace.hpp:481` | process `Worker` (the same code on every path) |
| `allocatePromotion` (large path under the lock `:1542-1553`, stash use `:1580-1583`, lock `:1587`, batch pop `:1617-1624`, finalize after unlock `:1634`) | `:1536-1646` | process `Worker`; the large path is the branch before `W_Large` |
| `beginParallelPromotion` (the mutator's cursor block becomes the shared block) | `:1387-1414` (`:1398-1405`) | `InitShared`, `PreAlloc`, `InitLive` of `U` |
| `tryPopFromFreeList` (pops the head), `finalizePoppedCell` (under the lock), `sweepOnDemandAllocate` (a slice, then a pop of the worker's class) | `:2004`, `:2025`, `:2136` | `W_PopAfterSweep`, `W_PopBit` |
| `pushSpanOnFreeLists` via `pushCoalescedFreeCell` (push at the head: LIFO) | `:4989-5005`, `:5057` | `freeList := g \o freeList` in `W_Sweep`, `U_Sweep` |
| `allocateLargeBlock` → `allocateFromEmptyRegularBlocks` (grant/Current skips `:2676-2679`; size test `:2680`; flip `:2701-2713`) | `:2725`, `:2665` | `W_Large` (precondition `large_promo`, CR-016) |
| `testAndSetMark<ParallelMark>` (`fetch_or`) | `:3039` | process `Marker` |
| `lazySweep`: loop `:5244`; in-loop completion `:5247-5255`; gap sweep `:5331-5369` (budget test `:5336`, `nextSetBit` `:5339`, `flushRun` `:5359`, `clearBit` `:5360`); block boundary `:5423-5451`; early exit `:5452-5460`; tail completion `:5467-5472` | `:5220-5479` | `W_Sweep`, `W_SweepClr`, `W_SweepEnd` (early exit and both completion paths) |
| `onSweepComplete` → `computeFragmentationStats` (plain `live_bytes` reads `:6378`) → `maybeShrinkCapacity` pass 1 (tenure skip `:5805`) | `:5488`, `:6369`, `:5699`, `:5796-5810` | `W_Shrink`, `G_Shrink`, `U_SweepDone` (a plain read of `"live"`) |
| `detachFromAllocation` (FATAL on Current during a parallel minor) | `:694-717` | the `assert` in `W_Shrink` |
| `grantTenure` (skips the mutator's cursor block `:100`), `grantAllocate` (`setBit` `:177`), `grantAllocateShared` (`:214`), `returnTenureGrant` | `OldGenTenure.cpp:44`, `:153`, `:197`, `:288` | process `Collector`; `U_Join` |
| `resetAllocCursors`' FATAL on a granted block at t0 | `OldGenSpace.cpp:675-690` | `U_T0` |
| the 7c launch/join order in `ThreadLocalHeap::minorGC` (join first; `TenureLaunchScope` last) | `ThreadLocalHeap.cpp:706-743` | `U_Pause`, `U_Join`, the mutant `launch_before_t0` |

## 4. The model

### 4.1 Abstractions, and why each is sound

| Real thing | Model | Why |
|---|---|---|
| A mark byte = 8 slots | A byte = 2–3 cells (`M1` = cells 1, 2, 3; `U1` = 8, 9; ...) | Sharing is what matters. Three cells in one byte is the smallest layout that reproduces CR-002 (a gap and two live objects, split over two sweep slices) |
| A 64-bit bitmap word = 8 bytes | `WordOf(y)`: `M1` and `M2` form one word (M's cells fit in 64 slots); every other byte is its own word | The scans read words (§2.1). A scan records a plain read of **every** byte of its word, so a `fetch_or` on a neighbouring byte is a race, as in C++ |
| A 64-cell chunk | A chunk = one byte (2 cells), and one word | Keeps "a chunk is whole words"; the mutants `chunk_unit_subbyte` and `chunk_unit_subword` break exactly that |
| Size classes, free-list classes | One class, plus two nondeterministic choices | The interleavings **do** depend on the class, in two places, and the model keeps both as choices: after a slice the sweeper may leave the cells it flushed (another class's) for the other worker (`W_PopAfterSweep`), which CR-002 needs; and at the last block the slice may take the early exit (the target class already has a cell) instead of completing the sweep (`W_SweepEnd`), leaving `gc_phase_` Sweeping for the rest of the minor |
| The free list, a LIFO stack | A sequence pushed and popped at the head | `pushSpanOnFreeLists` pushes at the head, `tryPopFromFreeList` pops it. A FIFO list (the first draft) pops D's cells last and hides CR-001's S1 half |
| `live_bytes` in bytes | in cells | Only "= 0?" matters to the readers |
| The shrink's `desired_heap` / `canRelease` sizing | Release **every** fully swept block with `live_bytes = 0` | Over-approximation: the real shrink releases a subset. A violation found this way must be checked against the sizing rule (§10 item 1) |
| The batch pop of 1 + 16 cells; the stash's LIFO order | Up to 2 cells, finalized in any order (`with x \in stash[self]`) | Enough for "popped but not finalized"; any order over-approximates the code's |
| The gap sweep's per-slice budget | One `sweepQ` item = one loop iteration (the gap before a live object, that object's bit, and the block's end if it is the last); after each item the slice may end | The budget is tested only at the loop's head (`:5336`), so a flush and the next clear never straddle a slice boundary. Every real slice boundary is a model boundary |
| Everything a worker does under `promo_mu_` in one hold | One of: advance the shared block; batch pop; sweep slice(s) then at most one pop; or the virgin/bag rungs, as a cell outside the modelled heap (`W_SwTest`) | Follows the ladder order of `allocatePromotion`. Every hold makes progress, so no worker can wait forever and TLC's deadlock check stays on. The advance's claim and allocation happen after the unlock in the model (inside the hold in the code): more interleavings, no fewer |
| Several tenure collector members (L3) | One collector (B = 1, the exact engine) | The L3 members share grant blocks by chunk claims just like M4's workers. The configuration `epoch_l3` (§6) is the step that adds a second member |
| The heap's objects and their fields | Absent | M4 is about metadata and bytes. Object contents are M1's and M3's; each promotion is one allocation request, whatever copies it (§4.8) |
| `BlockInfo` fields read without the lock (`is_large`, `start`, `alloc_state`) | Absent | Only the flip (`W_Large`, CR-016) writes them during a parallel minor; the release it causes is what `ReleasedSafe` checks. The field race itself is recorded in §2.5 item 3, not modelled |

### 4.2 Constants

| Constant | Meaning | Values |
|---|---|---|
| `Scenario` | which world is modelled (§6) | `"sweep"`, `"sweep_virgin"` (as `sweep`, plus a live-bytes-0 block V for the refill), `"cycle"`, `"epoch"` |
| `CycleActive` | `epoch` only: a 5c mark cycle is running during the epoch | TRUE / FALSE |
| `NAllocs` | promotions per worker | 2 |
| `MUTANT` | negative and positive controls, and the precondition `large_promo` (§5) | a set of §5 names; `{}` is the code as it is |

The miniature heap is fixed in the module:
- `M`: mixed; cells 1–5; bytes `M1` = {1, 2, 3}, `M2` = {4, 5}, one word.
- `D`: mixed, all dead at the mark; cells 6, 7; byte `D1`. In `sweep` it comes **before** M in
  block order, so its cells reach the free list while M is still being swept.
- `U`: uniform, the mutator's cursor block and so the shared promotion block; cells 8–11 in two
  chunks, `U1` and `U2`. The mutator already allocated 8, 9 and 10 in `sweep` (the workers start
  at unit 2, one free cell), and 8 in `cycle` (units 1 and 2, three free cells) (`PreAlloc`).
- `V`: uniform, the next block for the refill (`sweep_virgin` only; `claim_after_exhaustion` uses
  its cells as "past the end"); cells 12, 13.
- `Z`: uniform, a **t0** block with live object 14 and free cell 15.
- `G`: uniform, the tenure grant; cells 16, 17.
- `K`: uniform, the mutator's cursor block in `epoch`; cells 18, 19.

In the cycle scenarios the t0 blocks are `M` and `Z`, and the objects the marker must mark are
2, 3 and 14.

### 4.3 Variables

| Variable | Meaning | Code counterpart | Written by |
|---|---|---|---|
| `bits[y]` | set bits of byte y | the mark bitmap arena | everyone (plain or atomic) |
| `freeList` | the class free list, head first (LIFO) | `free_lists_[cls]` | under `promo_mu_` (workers) or the mutator |
| `sweepQ` | the gap sweep's remaining loop iterations `[g, l, e]`, in address order | `sweep_buffer_index_`, `sweep_cursor_` | the sweeper, under the lock |
| `phase` | `gc_phase_` | `gc_phase_` | the sweep's completion (plain write) |
| `liveBytes[b]`, `swept[b]`, `deferred` | `live_bytes`, `fully_swept` (set at each block's end), `sweep_complete_deferred_` | `BufferMetadata`, `OldGenSpace` | atomic adds, plain reads and the flip's plain write (race location `"live"`) / the sweep / pause code |
| `shared`, `partialQ` | the shared promotion word; `partial_[cls]` and virgin blocks | `PromoCtx::shared[cls]`, `partial_` | CAS (claims), under the lock (advance) |
| `chunk[w]`, `chunkLive[w]`, `stash[w]` | a worker's chunk, its unflushed `pending_live`, its stash | `PromoWorker::cur`, `pending_live`, `stash` | the worker |
| `lock` | `promo_mu_` | `promo_mu_` | workers |
| `released` | blocks a shrink released or the flip made large | `releaseBlockToAllocator`, `allocateFromEmptyRegularBlocks` | the shrinks, `W_Large` |
| `grantOn`, `grantLive` | grant active; its `pending_live` | `TenureGrant::active`, `TenureCursor::pending_live` | collector / merge |
| `allocs[c]`, `need`, `marked`, `claimed` | ghosts: times c was handed out (1 at the start for `PreAlloc`); allocate-black bits that must survive; the marker's bits; claimed chunk units | — | — |
| `vc`, `lockvc`, `sharedvc`, `hist`, `races` | the race detector (§4.4) | — | — |

### 4.4 The race detector, explained

C++ calls it a **data race** when:
1. two threads access the same location;
2. at least one access writes;
3. at least one access is not atomic;
4. neither happens before the other.

"Happens before" comes from synchronisation: in M4, a lock release followed by the next acquire,
an acq_rel RMW on the shared chunk word, and the gang join at the merge. Relaxed atomics
(`fetch_or` on mark bytes, `fetch_add` on `live_bytes`) do **not** synchronise.

The model tracks this with **vector clocks**, as ThreadSanitizer does:
- Each thread t has a clock `vc[t]`. `vc[t][u]` is the latest point of thread u that t knows
  happened before its present.
- A lock release copies the releaser's clock into `lockvc` and ticks the releaser. The next
  acquire takes the pointwise maximum.
- The tracked locations are the mark bytes, `"phase"` (`gc_phase_`) and `"live"` (every block's
  `live_bytes` as one location: the shrink and the flip read them all). A byte write is an access
  to its byte; a scan (`nextFreeCell`, `nextSetBit`) is a plain read of **every** byte of its word
  (`WordRd`), because C++ counts a word-wide `memcpy` as an access to each byte it covers.
- Every access is recorded in `hist[loc]` with its thread, the thread's own clock value, and
  whether it is plain and whether it writes. Only the **latest** access of each (thread, plain,
  write) kind is kept: an older one has a smaller clock, so it can race only if the latest one
  does. This is exact and keeps otherwise-equal states equal.
- One step may make several accesses (`Acc(S)`, S a set); the clock is passed in from the step,
  so the claim step, which ticks its clock with the CAS before its flush, records the new value.
- An access by t **races** with a recorded access a by u ≠ t, if one of them is plain, one of them
  writes, and `a.c > vc[t][u]`. That last condition means t has not heard of that point of u yet.
- A race is **recorded** in `races`, not blocked on, so TLC continues and can report the property
  `NoRaceBitmap` / `NoRacePhase` / `NoRaceLive` with a full trace.
- The detector sees a race between two steps of a lock-free path, however far apart, because
  `hist` keeps every thread's latest access. It gives no alarm on accesses ordered by
  `promo_mu_`, by the shared word's CAS or publish, or by a join. The acquire loads of a
  **failed** claim are not modelled as synchronisation; that can only add alarms, and every such
  path goes on to take the lock, which synchronises anyway.

Example, timeline (b):
- W2's lock release after its pop gives `lockvc[W2] = c2`, and W2 ticks to `c2 + 1`.
- W1's next acquire learns `vc[W1][W2] = c2`.
- W1 writes `phase` at clock `c1` and releases, so `lockvc[W1] = c1`.
- W2 reads `phase` at clock `c2 + 1` **without** acquiring. So `vc[W2][W1]` is still older than
  `c1`, and W1's recorded write has `a.c = c1 > vc[W2][W1]`: **race**.

With `"phase_atomic"` in `MUTANT`, both accesses are non-plain, so there is no race.

### 4.5 Steps: model labels to code lines

| Label | Code | Operation |
|---|---|---|
| rung-1 branch, `W_R1Phase`, `W_R1Set` | `cursorAllocateW` `:1146` → `finalizeBitmapCellW` `:1121` | plain word read (`nextFreeCell`; the fast path's byte read is covered by it), plain read of `gc_phase_` (`:1135`), plain `setBit` (`:1131`) |
| claim branch | `claimChunkW` `:1171` | CAS on `shared` (acq_rel), then `flushCursorW` (atomic add, `:1033`) |
| finalize branch, `W_StBit`, `W_StPlainSet` | `allocatePromotion` `:1580-1583` / `:1634` → `finalizePoppedCellW` `:1069` | plain read of `gc_phase_` (`:1075`) outside the lock, then an atomic `fetch_or` (`:1083`) and `fetch_add` (`:1084`), or nothing when Idle. `W_StPlainSet` exists only for `plain_stash_black` |
| lock branch, `W_Locked` | `allocatePromotion` `:1587-1631` | refill (`advanceSharedW` → `publishShared`, release store), or batch pop into the stash |
| `W_SwChk`, `W_SwTest` | `hasPendingSweepWork` (`OldGenSpace.hpp:1485`); `ladderFrom2W`'s virgin and bag rungs `:1344-1345` | read of `gc_phase_` under the lock; with nothing to sweep, a cell outside the model |
| `W_Sweep`, `W_SweepClr` | `lazySweep` gap sweep `:5331-5369`, block boundary `:5423-5451` | one iteration: `flushRun` (push at the head) and the plain word read of `nextSetBit`; then `clearBit`'s plain byte write, and `markBlockFullySwept` at a block's end. A trailing run (`l = 0`) makes no bitmap access that can race: its cells reach the free list only in this step |
| `W_SweepEnd` | `:5452-5460` (early exit), `:5247-5255` (in-loop), `:5467-5472` (tail) | at the last item: early exit, or the plain write `gc_phase_ = Idle` and then defer or shrink now; otherwise the slice may end |
| `W_PopAfterSweep`, `W_PopBit` | `sweepOnDemandAllocate` `:2136` → `tryAllocateFromFreeLists` → `finalizePoppedCell` `:2025` → `initObjectHeaderWithSize` | pop the head (or leave it: another class) and finalize under the lock |
| `W_Shrink` | `onSweepComplete` `:5488` → `computeFragmentationStats` `:6369` and pass 1 `:5796-5810` → `releaseBlockToAllocator` `:5995` → `detachFromAllocation` `:694` | plain reads of `live_bytes`; release empty blocks; FATAL if a Current block is picked; then back to the rung's pop |
| `W_Large` | `allocatePromotion` `:1542-1553` → `allocateLargeBlock` `:2725` → `allocateFromEmptyRegularBlocks` `:2665` | under the lock: plain reads of `live_bytes`, flip one candidate (`released`), plain write `live_bytes = size` |
| `W_Unlock` | end of the `unique_lock` scope | release (`lockvc`) |
| `K_Loop` | `testAndSetMark<ParallelMark>` `:3039` | relaxed `fetch_or` |
| `G_Join`, `G_Flush`, `G_Shrink` | gang join; `endParallelPromotion` `:1416-1534` | join the workers' clocks (the markers keep running: not joined); flush `pending_live`; stash return; cursors reset; deferred shrink |
| `C_Loop`, `C_Set` | `grantAllocate` `OldGenTenure.cpp:153-195` | plain word read (`nextFreeCell`), plain `setBit` (`:177`) |
| `U_Cursor`, `U_CursorSet` | `cursorAllocate` → `finalizeBitmapCell` `:802` | plain word read and plain `setBit` on the mutator's own block |
| `U_Pop`, `U_PopBit`, `U_PopPlainSet`, `U_PopDone` | `tryAllocateFromFreeLists` → `finalizePoppedCell` → `initObjectHeaderWithSize` `:487` | atomic allocate-black when not Idle; the plain RMW of `test_plain_allocate_black_` (`:515`) under `plain_allocate_black` |
| `U_Sweep` … `U_SweepDone` | the mutator's lazy sweep; `onSweepComplete` light shrink with the tenure skip `:5805` | plain word read and `clearBit`; plain `live_bytes` reads; release |
| `U_Large` | the mutator's `allocate()` of exactly a block's size (`:1933`) → `allocateLargeBlock` → `allocateFromEmptyRegularBlocks` | flip one candidate; the grant skip `:2679` (T6), off under `flip_ignores_tenure` |
| `U_Pause`, `U_Join`, `U_T0`, `U_After` | `ThreadLocalHeap::minorGC` `:706-745` (join, merge, t0), `returnTenureGrant`, `resetAllocCursors` FATAL | the ordering premise HEAP_070 |

### 4.6 The PlusCal sketch

File: `test/tla/M4-promotion-bitmap/PromoBitmap.tla`. This is the text that passed `pcal` and
`sany` (tla2tools 1.8.0) after the review of 2026-09-28; the generated translation is omitted.
One translator detail matters: pcal primes a variable assigned earlier in the same step only
where the step's own text names it, never inside a `define` operator. So `Acc` passes the
clock `vc[self]` into `Conflicts` and `Recorded` instead of letting them read `vc`.

```tla
----------------------------- MODULE PromoBitmap -----------------------------
(***************************************************************************)
(* M4: old-gen allocation and mark-bitmap BYTES under concurrency.         *)
(* Parallel-minor promotion workers (OldGenSpace::allocatePromotion and    *)
(* its *W helpers), the lazy/gap sweep run inside promo_mu_, background    *)
(* markers (testAndSetMark<ParallelMark>), the mutator's allocate-black    *)
(* (initObjectHeaderWithSize), and 7c's tenure grant (OldGenTenure.cpp).   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Scenario,      \* "sweep" | "sweep_virgin" | "cycle" | "epoch"
    CycleActive,   \* epoch only: a 5c mark cycle is running
    NAllocs,       \* promotions per worker
    MUTANT         \* a SET of control names (§5 of the plan); {} = the code as it is

\* ---- The miniature heap: 7 blocks, 19 cells, 9 bitmap bytes -------------
\* A real mark byte covers 8 slots of 8 bytes; here a byte covers 2-3 cells.
Cells  == 1..19
Blocks == {"M", "D", "U", "V", "Z", "G", "K"}
Bytes  == {"M1", "M2", "D1", "U1", "U2", "V1", "Z1", "G1", "K1"}
BlkOf(c) == CASE c \in 1..5   -> "M" [] c \in 6..7   -> "D" [] c \in 8..11 -> "U"
              [] c \in 12..13 -> "V" [] c \in 14..15 -> "Z" [] c \in 16..17 -> "G"
              [] c \in 18..19 -> "K"
ByteOf(c) == CASE c \in {1, 2, 3} -> "M1" [] c \in {4, 5} -> "M2" [] c \in {6, 7} -> "D1"
               [] c \in {8, 9} -> "U1" [] c \in {10, 11} -> "U2" [] c \in {12, 13} -> "V1"
               [] c \in {14, 15} -> "Z1" [] c \in {16, 17} -> "G1" [] c \in {18, 19} -> "K1"
\* The bitmap scans (nextSetBit, nextFreeCell) read whole 64-bit WORDS with a
\* plain memcpy (BitmapScan.hpp:25). M's cells share one word; a chunk is
\* whole words (64 cells x m bits = m words); blocks never share a word.
WordOf(y) == IF y \in {"M1", "M2"} THEN {"M1", "M2"}
             ELSE IF "chunk_unit_subword" \in MUTANT /\ y \in {"U1", "U2"} THEN {"U1", "U2"}
             ELSE {y}
CellsOf(b) == {c \in Cells : BlkOf(c) = b}
Mixed   == {"M", "D"}                      \* swept by the gap sweep
Uniform == Blocks \ Mixed                  \* bitmap = allocation map (HEAP_054)
IsSweep == Scenario \in {"sweep", "sweep_virgin"}
\* Blocks that existed at t0 (only meaningful while a cycle runs).
T0Blocks == IF IsSweep \/ (Scenario = "epoch" /\ ~CycleActive)
            THEN {} ELSE {"M", "Z"}
T0Cells  == UNION {CellsOf(b) : b \in T0Blocks}
\* Objects live at t0 that the background marker must mark.
T0Live   == IF T0Blocks = {} THEN {} ELSE {2, 3, 14}
\* Chunk units of a shared promotion block (claimChunkW): whole words.
Units(b) == IF "chunk_unit_subbyte" \in MUTANT /\ b = "U" THEN <<{8}, {9, 10}, {11}>>
            ELSE CASE b = "U" -> <<{8, 9}, {10, 11}>>
                   [] b = "V" -> <<{12, 13}>>
                   [] b = "Z" -> <<{14, 15}>>
                   [] OTHER   -> <<>>
\* 7c: the block the hand-over pause grants to the tenure collector.
GrantBlock == CASE "grant_t0_block" \in MUTANT        -> "Z"
                [] "grant_includes_cursor" \in MUTANT -> "K"
                [] OTHER                            -> "G"
Threads == 1..6
Workers    == IF IsSweep \/ Scenario = "cycle" THEN {1, 2} ELSE {}
Markers    == IF T0Blocks # {} THEN {3} ELSE {}
Collectors == IF Scenario = "epoch" THEN {4} ELSE {}
Mutators   == IF Scenario = "epoch" THEN {5} ELSE {}
Mergers    == IF IsSweep \/ Scenario = "cycle" THEN {6} ELSE {}
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
Range(sq) == {sq[i] : i \in 1..Len(sq)}
\* Race-detector locations: the mark bytes, gc_phase_, and live_bytes (one
\* location: the shrink and the flip read every block's live_bytes).
Locs == Bytes \cup {"phase", "live"}
\* One access descriptor, and a plain scan read of y's whole word.
Acc1(loc, p, w) == [l |-> loc, p |-> p, w |-> w]
WordRd(y) == {Acc1(z, TRUE, FALSE) : z \in WordOf(y)}
RECURSIVE SetToSeqAny(_)
SetToSeqAny(S) == IF S = {} THEN <<>>
                  ELSE LET x == CHOOSE y \in S : TRUE IN <<x>> \o SetToSeqAny(S \ {x})
AnyOf(S) == CHOOSE x \in S : TRUE

\* ---- Scenario starting states --------------------------------------------
\* sweep: after a mark, D (all dead, kept by the min-heap floor) comes first
\* in block order, then M with live objects 2, 3, 5 and dead gaps 1, 4. One
\* item = one iteration of the gap-sweep loop, whose budget is tested only at
\* its head (lazySweep :5336): flush the gap before the next live object (g),
\* clear that object's bit (l, 0 = none), and at a block's end mark it fully
\* swept (e). D's dead cells are one trailing run, flushed at D's boundary.
SweepItems == <<[g |-> <<6, 7>>, l |-> 0, e |-> "D"], [g |-> <<1>>, l |-> 2, e |-> "none"],
                [g |-> <<>>, l |-> 3, e |-> "none"], [g |-> <<4>>, l |-> 5, e |-> "M"]>>
InitBits == [y \in Bytes |->
    CASE IsSweep /\ y = "M1" -> {2, 3}
      [] IsSweep /\ y = "M2" -> {5}
      [] IsSweep /\ y = "U1" -> {8, 9}
      [] IsSweep /\ y = "U2" -> {10}
      [] Scenario = "cycle" /\ y = "U1" -> {8}
      [] Scenario = "epoch" /\ ~CycleActive /\ y = "M1" -> {2}
      [] OTHER -> {}]
\* Cells of U the mutator's cursor allocated before the minor.
PreAlloc  == CASE IsSweep -> {8, 9, 10} [] Scenario = "cycle" -> {8} [] OTHER -> {}
InitQ     == CASE IsSweep -> SweepItems
               [] Scenario = "epoch" /\ ~CycleActive -> <<[g |-> <<>>, l |-> 2, e |-> "M"]>>
               [] OTHER -> <<>>
InitFree  == CASE Scenario = "cycle" -> <<1, 4>>
               [] Scenario = "epoch" -> <<1>>
               [] OTHER -> <<>>
InitPhase == CASE IsSweep -> "Sweeping"
               [] Scenario = "cycle" -> "Marking"
               [] CycleActive        -> "Marking"
               [] OTHER              -> "Sweeping"
\* The mutator's cursor block U becomes the shared block from the chunk of its
\* next cell (beginParallelPromotion :1398-1405). sweep: one free cell (11) is
\* left, so the claiming worker reaches the lock too; cycle: cells 9-11.
InitShared == CASE "cursor_on_t0" \in MUTANT -> [b |-> "Z", u |-> 0]
                [] IsSweep                 -> [b |-> "U", u |-> 1]
                [] OTHER                   -> [b |-> "U", u |-> 0]
\* sweep_virgin: the refill publishes V, whose live_bytes stays 0 until a
\* worker flushes a chunk of it (as for a virgin block).
InitPartial == IF Scenario = "sweep_virgin" THEN <<"V">> ELSE <<>>
InitLive   == [b \in Blocks |-> CASE IsSweep /\ b \in {"M", "U"} -> 3
                                  [] Scenario = "cycle" /\ b = "U" -> 1
                                  [] Scenario = "epoch" /\ ~CycleActive /\ b = "M" -> 1
                                  [] OTHER -> 0]
InitSwept  == [b \in Blocks |-> ~\E i \in 1..Len(InitQ) : InitQ[i].e = b]
InitVC     == [t \in Threads |-> [u \in Threads |-> IF t = u THEN 1 ELSE 0]]

(* --algorithm PromoBitmap
variables
    bits      = InitBits,                       \* mark bytes: the set bits of each byte
    freeList  = InitFree,                       \* the class free list, LIFO (pushed at the head)
    sweepQ    = InitQ,                          \* gap sweep: iterations not yet run, in address order
    phase     = InitPhase,                      \* gc_phase_ (a PLAIN field)
    liveBytes = InitLive,                       \* BufferMetadata::live_bytes, in cells
    swept     = InitSwept,                      \* BufferMetadata::fully_swept
    deferred  = FALSE,                          \* sweep_complete_deferred_
    shared    = InitShared,                     \* PromoCtx::shared[cls]: (block, next unit)
    partialQ  = InitPartial,                    \* partial_[cls]: blocks for the refill
    lock      = 0,                              \* promo_mu_ (0 = free)
    chunk     = [w \in Threads |-> {}],         \* each worker's current chunk (its cursor)
    chunkLive = [w \in Threads |-> 0],          \* cursor pending_live (flushed at a claim or the merge)
    stash     = [w \in Threads |-> {}],         \* PromoWorker::stash (popped, not finalized)
    released  = {},                             \* blocks released by a shrink or flipped to large
    grantOn   = (Scenario = "epoch"),           \* the tenure grant is live
    grantLive = 0,                              \* grant pending_live (folded at the merge)
    \* ---- ghosts ----
    allocs    = [c \in Cells |-> IF c \in PreAlloc THEN 1 ELSE 0],   \* times c was handed out
    need      = {},                             \* allocate-black bits that must survive (IM4)
    marked    = {},                             \* bits the marker set (must survive)
    claimed   = {},                             \* chunk units claimed: <<block, unit>>
    \* ---- the data-race detector (vector clocks, primer §3.7) ----
    vc        = InitVC,                         \* vc[t][u]: what t knows of u's clock
    lockvc    = [u \in Threads |-> 0],          \* the clock promo_mu_ carries
    sharedvc  = [u \in Threads |-> 0],          \* the clock shared[cls] carries (acq_rel CAS)
    hist      = [loc \in Locs |-> {}],          \* per location: the latest access of each kind
    races     = {};                             \* locations with an unordered conflicting pair

define
    Allocated == {c \in Cells : allocs[c] > 0}
    PhasePlain == "phase_atomic" \notin MUTANT     \* gc_phase_ is a plain field today
    SetBits   == UNION {bits[y] : y \in Bytes}
    ChunkFree(w) == {c \in chunk[w] : c \notin bits[ByteOf(c)]}
    CanClaim  == shared.b # "none" /\ shared.u < Len(Units(shared.b))
    \* ---- the race detector (plan §4.4) ----
    \* Access x by thread t (whose clock is tv) races with a recorded access a
    \* of another thread if one is plain, one writes, and t has not yet heard
    \* of a's point of a.t. The clock is passed in, not read from vc, so that
    \* a step that ticks vc before its access (a claim) records the new value.
    Conflicts(t, tv, x) == \E a \in hist[x.l] : a.t # t /\ (a.p \/ x.p) /\ (a.w \/ x.w)
                                                  /\ a.c > tv[a.t]
    \* Keep only the LATEST access of each (thread, plain, write) kind: an older
    \* one has a smaller clock, so it races only if the latest one does.
    Recorded(t, tv, loc, S) ==
        LET mine == {x \in S : x.l = loc} IN
        {a \in hist[loc] : ~\E x \in mine : a.t = t /\ a.p = x.p /\ a.w = x.w}
          \cup {[t |-> t, c |-> tv[t], p |-> x.p, w |-> x.w] : x \in mine}
    \* ---- properties (§6 of the plan) ----
    NoRaceBitmap == races \cap Bytes = {}
    NoRacePhase  == "phase" \notin races
    NoRaceLive   == "live" \notin races
    NoDoubleAlloc == \A c \in Cells : allocs[c] <= 1
    NoOverwriteLive == \A c \in T0Live : allocs[c] = 0
    \* M7's release contract: nothing still refers to a released block.
    ReleasedSafe == \A b \in released :
                        /\ \A c \in Allocated : BlkOf(c) # b
                        /\ \A w \in Threads : \A c \in chunk[w] \cup stash[w] : BlkOf(c) # b
                        /\ ~(b = GrantBlock /\ grantOn)
    FreeBehindCursor ==
        \A c \in Range(freeList) \cup UNION {stash[w] : w \in Threads} :
            ~\E i \in 1..Len(sweepQ) : c \in Range(sweepQ[i].g) \/ c = sweepQ[i].l
    ClaimsInRange == \A x \in claimed : x[2] <= Len(Units(x[1]))
    IM13 == \A w \in Workers : chunk[w] \cap T0Cells = {}
    TV5  == Scenario = "epoch" =>
                (GrantBlock # "K" /\ (CycleActive => GrantBlock \notin T0Blocks))
end define;

\* The accesses in the set S, made by self in one step: record a race for
\* each one that conflicts with an unordered earlier access, then log them.
macro Acc(S) begin
    races := races \cup {x.l : x \in {y \in S : Conflicts(self, vc[self], y)}};
    hist := [loc \in Locs |-> Recorded(self, vc[self], loc, S)];
end macro;

macro LockAcquire() begin
    await lock = 0;
    lock := self;
    vc[self] := [u \in Threads |-> Max(vc[self][u], lockvc[u])];
end macro;

macro LockRelease() begin
    lock := 0;
    lockvc := vc[self];
    vc[self][self] := vc[self][self] + 1;
end macro;

\* An acq_rel RMW on shared[cls] (claimChunkW's CAS; publishShared's release).
macro SharedSync() begin
    sharedvc := [u \in Threads |-> Max(vc[self][u], sharedvc[u])];
    vc[self] := [u \in Threads |-> IF u = self THEN vc[self][u] + 1
                                   ELSE Max(vc[self][u], sharedvc[u])];
end macro;

\* =========================================================================
\* Parallel-minor promotion worker (allocatePromotion, OldGenSpace.cpp:1536).
\* =========================================================================
fair process Worker \in Workers
variables n = 0, cell = 0, seen = {}, ph = "Idle";
begin
  W_Loop:
    while n < NAllocs do
        either
            \* ---- rung 1: the next free cell of my chunk (cursorAllocateW) ----
            await ChunkFree(self) # {};
            cell := CHOOSE x \in ChunkFree(self) : TRUE;   \* the lowest: address order
            seen := bits[ByteOf(cell)];
            Acc(WordRd(ByteOf(cell)));                \* nextFreeCell: a plain WORD read
          W_R1Phase:                                  \* finalizeBitmapCellW: colour
            ph := phase;                              \* plain read, NO lock (CR-001)
            Acc({Acc1("phase", PhasePlain, FALSE)});
          W_R1Set:                                    \* bitscan::setBit: plain write (IM13)
            bits[ByteOf(cell)] := seen \cup {cell};
            Acc({Acc1(ByteOf(cell), TRUE, TRUE)});
            allocs[cell] := allocs[cell] + 1;
            chunkLive[self] := chunkLive[self] + 1;   \* c.pending_live
            if ph = "Marking" then need := need \cup {cell}; end if;
            n := n + 1; cell := 0; seen := {}; ph := "Idle";
        or
            \* ---- claim the next chunk of the shared block (claimChunkW) ----
            await ChunkFree(self) = {};
            await CanClaim \/ ("claim_after_exhaustion" \in MUTANT /\ shared.b = "U");
            SharedSync();
            if chunk[self] # {} /\ chunkLive[self] > 0 then   \* flushCursorW: atomic fetch_add
                liveBytes[BlkOf(AnyOf(chunk[self]))] :=
                    liveBytes[BlkOf(AnyOf(chunk[self]))] + chunkLive[self];
                Acc({Acc1("live", FALSE, TRUE)});
            end if;
            chunkLive[self] := 0;
            if CanClaim then
                chunk[self] := Units(shared.b)[shared.u + 1];
            else
                chunk[self] := Units("V")[1];         \* past the end: the next block's cells
            end if;
            claimed := claimed \cup {<<shared.b, shared.u + 1>>};
            shared.u := shared.u + 1;
        or
            \* ---- finalize one stashed cell OUTSIDE the lock (finalizePoppedCellW) ----
            await stash[self] # {} /\ "finalize_in_lock" \notin MUTANT;
            with x \in stash[self] do                 \* the stash order is abstracted
                cell := x;
                stash[self] := stash[self] \ {x};
            end with;
            ph := phase;                              \* plain read, NO lock (CR-001)
            Acc({Acc1("phase", PhasePlain, FALSE)});
          W_StBit:
            if (ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred))
               /\ "plain_stash_black" \in MUTANT then
                seen := bits[ByteOf(cell)];               \* a plain set: the read ...
                Acc({Acc1(ByteOf(cell), TRUE, FALSE)});
                goto W_StPlainSet;
            elsif ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred) then
                bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};   \* setMarkBitAtomic
                liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;   \* atomic fetch_add
                Acc({Acc1(ByteOf(cell), FALSE, TRUE), Acc1("live", FALSE, TRUE)});
                if ph = "Marking" then need := need \cup {cell}; end if;
                allocs[cell] := allocs[cell] + 1;
                n := n + 1; cell := 0; ph := "Idle";
                goto W_Loop;
            else
                allocs[cell] := allocs[cell] + 1;         \* Idle: no bit, no live_bytes
                n := n + 1; cell := 0; ph := "Idle";
                goto W_Loop;
            end if;
          W_StPlainSet:                               \* ... then a plain write-back
            bits[ByteOf(cell)] := seen \cup {cell};
            liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
            Acc({Acc1(ByteOf(cell), TRUE, TRUE), Acc1("live", FALSE, TRUE)});
            if ph = "Marking" then need := need \cup {cell}; end if;
            allocs[cell] := allocs[cell] + 1;
            n := n + 1; cell := 0; seen := {}; ph := "Idle";
        or
            \* ---- rung 1 failed: take promo_mu_ ----
            await ChunkFree(self) = {} /\ ~CanClaim /\ stash[self] = {};
            LockAcquire();
          W_Locked:
            if (shared.b = "none" \/ ~CanClaim) /\ partialQ # <<>> then
                \* advanceSharedW: publishShared (release) of the next queued block
                shared := [b |-> Head(partialQ), u |-> 0];
                partialQ := Tail(partialQ);
                SharedSync();
                goto W_Unlock;
            elsif freeList # <<>> then
                \* rung 2 batch (N > 1): 1 + up to 16 cells; the model takes up to 2
                stash[self] := Range(SubSeq(freeList, 1, Min(2, Len(freeList))));
                freeList := SubSeq(freeList, Min(2, Len(freeList)) + 1, Len(freeList));
                goto W_Unlock;
            end if;
          W_SwChk:                                    \* hasPendingSweepWork(): phase under the lock
            ph := phase;
            Acc({Acc1("phase", PhasePlain, FALSE)});
          W_SwTest:
            if ph # "Sweeping" \/ sweepQ = <<>> then
                \* the virgin-block and bag rungs (ladderFrom2W :1344-1345): a cell
                \* in a block outside the model, so every lock hold makes progress
                n := n + 1; ph := "Idle";
                goto W_Unlock;
            end if;
          W_Sweep:                                    \* lazySweep: one gap-sweep iteration
            freeList := Head(sweepQ).g \o freeList;   \* flushRun: pushed at the HEAD
            if Head(sweepQ).l = 0 then                \* a trailing run: the block boundary
                swept[Head(sweepQ).e] := TRUE;        \* markBlockFullySwept
                sweepQ := Tail(sweepQ);
                goto W_SweepEnd;
            else
                cell := Head(sweepQ).l;
                seen := bits[ByteOf(Head(sweepQ).l)];
                Acc(WordRd(ByteOf(Head(sweepQ).l)));  \* nextSetBit: a plain WORD read
                sweepQ := <<[Head(sweepQ) EXCEPT !.g = <<>>]>> \o Tail(sweepQ);   \* cursor past the gap
            end if;
          W_SweepClr:                                 \* bitscan::clearBit: the plain write
            bits[ByteOf(cell)] := seen \ {cell};
            Acc({Acc1(ByteOf(cell), TRUE, TRUE)});
            if Head(sweepQ).e # "none" then swept[Head(sweepQ).e] := TRUE; end if;
            sweepQ := Tail(sweepQ);
            cell := 0; seen := {};
          W_SweepEnd:
            if sweepQ = <<>> then
                either
                    skip;   \* early exit (:5452-5460): the target class already has a
                            \* cell; gc_phase_ stays Sweeping for the rest of the minor
                or
                    phase := "Idle";                  \* completion: plain write under the lock
                    Acc({Acc1("phase", PhasePlain, TRUE)});
                    either
                        deferred := TRUE;             \* in-loop path: sweepCompleteInPromotion
                    or
                        await "tail_defers" \notin MUTANT;   \* tail path: onSweepComplete NOW
                        goto W_Shrink;
                    end either;
                end either;
            else
                either goto W_Sweep; or skip; end either;   \* this slice's budget may end here
            end if;
          W_PopAfterSweep:                            \* tryAllocateFromFreeLists (the sweeper's class)
            if freeList # <<>> then
                either
                    cell := Head(freeList);
                    freeList := Tail(freeList);
                    ph := phase;
                    Acc({Acc1("phase", PhasePlain, FALSE)});
                or
                    skip;   \* the cells are of another class: left for the other workers
                end either;
            end if;
          W_PopBit:                                   \* finalizePoppedCell -> initObjectHeaderWithSize
            if cell # 0 then
                if ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred) then
                    bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};
                    liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
                    Acc({Acc1(ByteOf(cell), FALSE, TRUE), Acc1("live", FALSE, TRUE)});
                end if;
                allocs[cell] := allocs[cell] + 1;
                n := n + 1; cell := 0; ph := "Idle";
            end if;
            goto W_Unlock;
          W_Shrink:                                   \* maybeShrinkCapacity pass 1, on this worker
            with rel = {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b \notin released} do
                \* releaseBlockToAllocator -> detachFromAllocation: FATAL on a
                \* Current block during a parallel minor (every build)
                assert shared.b \notin rel;
                released := released \cup rel;
                freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel);
                partialQ := SelectSeq(partialQ, LAMBDA b : b \notin rel);   \* detach: erase queued
            end with;
            Acc({Acc1("live", TRUE, FALSE)});         \* computeFragmentationStats, pass 1: plain reads
            goto W_PopAfterSweep;                     \* lazySweep returns; the rung pops next
          W_Unlock:
            LockRelease();
        or
            \* ---- a promotion of exactly alloc_buffer_size bytes (CR-016's precondition) ----
            await "large_promo" \in MUTANT;
            LockAcquire();
          W_Large:                                    \* allocateLargeBlock -> allocateFromEmptyRegularBlocks
            with cand = {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b \notin released
                                        /\ b # shared.b /\ ~(b = GrantBlock /\ grantOn)} do
                if cand # {} then
                    with f \in cand do                \* flipped to large: its cells are gone
                        released := released \cup {f};
                        freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) # f);
                        partialQ := SelectSeq(partialQ, LAMBDA x : x # f);
                    end with;
                end if;
            end with;
            Acc({Acc1("live", TRUE, TRUE)});          \* plain reads, then live_bytes = size
            n := n + 1;
            LockRelease();
        or
            \* ---- the same stash finalize, moved INSIDE the lock (fix candidate) ----
            await stash[self] # {} /\ "finalize_in_lock" \in MUTANT;
            LockAcquire();
          W_InLockFin:
            with x \in stash[self] do
                cell := x;
                stash[self] := stash[self] \ {x};
            end with;
            ph := phase;
            Acc({Acc1("phase", PhasePlain, FALSE)});
          W_InLockBit:
            if ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred) then
                bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};
                liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
                Acc({Acc1(ByteOf(cell), FALSE, TRUE), Acc1("live", FALSE, TRUE)});
            end if;
            allocs[cell] := allocs[cell] + 1;
            n := n + 1; cell := 0; ph := "Idle";
          W_InLockRel:
            LockRelease();
        end either;
    end while;
end process;

\* =========================================================================
\* Background marker (testAndSetMark<ParallelMark>, OldGenSpace.cpp:3039):
\* sets the mark bits of t0 objects with a relaxed fetch_or.
\* =========================================================================
fair process Marker \in Markers
\* marker_on_post_t0 (CR-017's worst case): a stale grey in a block that became
\* a post-t0 chunk (11), grant (16) or mutator cursor (19) block.
variables todo = T0Live \cup (IF "marker_on_post_t0" \in MUTANT THEN {11, 16, 19} ELSE {});
begin
  K_Loop:
    while todo # {} do
        with c \in todo do
            bits[ByteOf(c)] := bits[ByteOf(c)] \cup {c};
            Acc({Acc1(ByteOf(c), FALSE, TRUE)});
            marked := marked \cup {c};
            todo := todo \ {c};
        end with;
    end while;
end process;

\* =========================================================================
\* The merge after the gang join (endParallelPromotion, OldGenSpace.cpp:1416).
\* The background markers keep running: they are not joined here.
\* =========================================================================
fair process Merge \in Mergers
begin
  G_Join:
    await \A w \in Workers : pc[w] = "Done";
    vc[self] := [u \in Threads |-> Max(vc[1][u], Max(vc[2][u], vc[self][u]))];
  G_Flush:                                        \* flushCursorW + stash return; cursors reset
    liveBytes := [b \in Blocks |-> liveBytes[b]
        + (IF chunk[1] # {} /\ BlkOf(AnyOf(chunk[1])) = b THEN chunkLive[1] ELSE 0)
        + (IF chunk[2] # {} /\ BlkOf(AnyOf(chunk[2])) = b THEN chunkLive[2] ELSE 0)];
    freeList := SetToSeqAny(stash[1] \cup stash[2]) \o freeList;
    stash := [w \in Threads |-> {}];
    chunk := [w \in Threads |-> {}];
    chunkLive := [w \in Threads |-> 0];
  G_Shrink:                                       \* the deferred onSweepComplete
    if deferred then
        with rel = {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b # shared.b
                                   /\ b \notin released} do
            released := released \cup rel;
            freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel);
            partialQ := SelectSeq(partialQ, LAMBDA b : b \notin rel);
        end with;
        deferred := FALSE;
    end if;
end process;

\* =========================================================================
\* 7c tenure collector (grantAllocate, OldGenTenure.cpp:153), B = 1.
\* =========================================================================
fair process Collector \in Collectors
variables nk = 0, gcell = 0, gseen = {};
begin
  C_Loop:
    while nk < 2 /\ \E x \in CellsOf(GrantBlock) : x \notin bits[ByteOf(x)] do
        gcell := CHOOSE x \in CellsOf(GrantBlock) : x \notin bits[ByteOf(x)];
        gseen := bits[ByteOf(gcell)];
        Acc(WordRd(ByteOf(gcell)));                    \* nextFreeCell: a plain WORD read
      C_Set:
        bits[ByteOf(gcell)] := gseen \cup {gcell};     \* bitscan::setBit: plain write
        Acc({Acc1(ByteOf(gcell), TRUE, TRUE)});
        allocs[gcell] := allocs[gcell] + 1;
        grantLive := grantLive + 1;
        nk := nk + 1; gcell := 0; gseen := {};
    end while;
end process;

\* =========================================================================
\* The mutator during the 7c epoch (running Elm code between minors).
\* =========================================================================
fair process Mutator \in Mutators
variables mcell = 0, mseen = {}, mph = "Idle";
begin
  U_Cursor:                                       \* its own cursor block K (finalizeBitmapCell)
    if \E x \in CellsOf("K") : x \notin bits[ByteOf(x)] then
        mcell := CHOOSE x \in CellsOf("K") : x \notin bits[ByteOf(x)];
        mseen := bits[ByteOf(mcell)];
        Acc(WordRd(ByteOf(mcell)));
      U_CursorSet:
        bits[ByteOf(mcell)] := mseen \cup {mcell};
        Acc({Acc1(ByteOf(mcell), TRUE, TRUE)});
        allocs[mcell] := allocs[mcell] + 1;
        mcell := 0; mseen := {};
    end if;
  U_Pop:                                          \* a free-list pop: initObjectHeaderWithSize
    if freeList # <<>> then
        mcell := Head(freeList);
        freeList := Tail(freeList);
        mph := phase;
      U_PopBit:
        if mph # "Idle" /\ "plain_allocate_black" \in MUTANT then
            mseen := bits[ByteOf(mcell)];          \* test_plain_allocate_black_: plain RMW
            Acc({Acc1(ByteOf(mcell), TRUE, FALSE)});
          U_PopPlainSet:
            bits[ByteOf(mcell)] := mseen \cup {mcell};
            liveBytes[BlkOf(mcell)] := liveBytes[BlkOf(mcell)] + 1;
            Acc({Acc1(ByteOf(mcell), TRUE, TRUE), Acc1("live", FALSE, TRUE)});
            if mph = "Marking" then need := need \cup {mcell}; end if;
        elsif mph # "Idle" then
            bits[ByteOf(mcell)] := bits[ByteOf(mcell)] \cup {mcell};   \* setMarkBitAtomic
            liveBytes[BlkOf(mcell)] := liveBytes[BlkOf(mcell)] + 1;
            Acc({Acc1(ByteOf(mcell), FALSE, TRUE), Acc1("live", FALSE, TRUE)});
            if mph = "Marking" then need := need \cup {mcell}; end if;
        end if;
      U_PopDone:
        allocs[mcell] := allocs[mcell] + 1;
        mcell := 0; mseen := {}; mph := "Idle";
    end if;
  U_Sweep:                                        \* outside a cycle: a lazy-sweep iteration of M
    if phase = "Sweeping" /\ sweepQ # <<>> then
        freeList := Head(sweepQ).g \o freeList;
        mcell := Head(sweepQ).l;
        mseen := bits[ByteOf(Head(sweepQ).l)];
        Acc(WordRd(ByteOf(Head(sweepQ).l)));
        sweepQ := <<[Head(sweepQ) EXCEPT !.g = <<>>]>> \o Tail(sweepQ);
      U_SweepClr:
        bits[ByteOf(mcell)] := mseen \ {mcell};
        Acc({Acc1(ByteOf(mcell), TRUE, TRUE)});
        if Head(sweepQ).e # "none" then swept[Head(sweepQ).e] := TRUE; end if;
        sweepQ := Tail(sweepQ);
        mcell := 0; mseen := {};
      U_SweepDone:                                \* completion: onSweepComplete's light shrink
        phase := "Idle";
        with rel = {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b # "K"
                        /\ (b # GrantBlock \/ ~grantOn \/ "shrink_ignores_tenure" \in MUTANT)} do
            released := released \cup rel;
            freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel);
        end with;
        Acc({Acc1("live", TRUE, FALSE)});
    end if;
  U_Large:                                        \* an allocation of exactly a block's size (large_promo)
    if "large_promo" \in MUTANT then
        \* allocateFromEmptyRegularBlocks: syncCursorLiveBytes makes K's live_bytes
        \* exact (K holds cell 18), and the kAllocTenure skip (:2679) keeps the grant
        with cand = {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b \notin released /\ b # "K"
                        /\ (b # GrantBlock \/ ~grantOn \/ "flip_ignores_tenure" \in MUTANT)} do
            if cand # {} then
                with f \in cand do
                    released := released \cup {f};
                    freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) # f);
                end with;
            end if;
        end with;
        Acc({Acc1("live", TRUE, TRUE)});
    end if;
  U_Pause:                                        \* the next minor: tenureJoin, merge, t0
    if "launch_before_t0" \in MUTANT then goto U_T0; end if;
  U_Join:
    await \A x \in Collectors : pc[x] = "Done";
    vc[self] := [u \in Threads |-> Max(vc[4][u], vc[self][u])];
    liveBytes[GrantBlock] := liveBytes[GrantBlock] + grantLive;   \* returnTenureGrant
    grantOn := FALSE;
  U_T0:                                           \* resetAllocCursors: FATAL on a granted block
    assert ~grantOn;
  U_After:                                        \* the returned block is an allocation map again
    if \E x \in CellsOf(GrantBlock) : x \notin bits[ByteOf(x)] then
        with x = CHOOSE y \in CellsOf(GrantBlock) : y \notin bits[ByteOf(y)] do
            bits[ByteOf(x)] := bits[ByteOf(x)] \cup {x};
            allocs[x] := allocs[x] + 1;
        end with;
    end if;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
\* END TRANSLATION

-----------------------------------------------------------------------------
AllDone == \A p \in DOMAIN pc : pc[p] = "Done"
\* End-state checks: allocate-black bits and the marker's bits survived
\* (IM4; no lost update); uniform post-t0 bitmaps are exact allocation maps.
NoLostRequiredBit == AllDone => (need \cup marked) \subseteq SetBits
PostT0Uniform == UNION {CellsOf(b) : b \in Uniform \ T0Blocks}
AllocMapExact == AllDone => \A c \in PostT0Uniform : (c \in SetBits) <=> (allocs[c] > 0)
=============================================================================
```

### 4.7 The properties, explained

| Property | Kind | What it says | A violation looks like |
|---|---|---|---|
| `NoRaceBitmap` | invariant | no mark byte has an unordered conflicting pair of accesses with a plain one among them, a word scan counting as a read of each byte of its word (§4.4) | timeline (c): the sweeper's plain word read or `clearBit` and a stash finalize's `fetch_or` on byte `M1` |
| `NoRacePhase` | invariant | no unordered plain access pair on `gc_phase_` | timeline (b): the completion's plain write and a finalize's (or a chunk allocation's) plain read |
| `NoRaceLive` | invariant | no unordered pair on `live_bytes` with a plain one among them | CR-014: the tail shrink's plain reads against another worker's `fetch_add`; CR-016: the flip's plain write |
| `NoDoubleAlloc` | invariant | no cell is handed out twice | two allocators read the same byte, both pick cell 18, both write it back (`grant_includes_cursor`) |
| `NoOverwriteLive` | invariant | no allocator hands out a cell holding a live t0 object | a cursor on t0 block `Z` treats object 14's still-clear bit as "free" (IM13's reason: mid-cycle, a t0 bitmap is being rebuilt, not an allocation map) |
| `ReleasedSafe` | invariant | a released (or flipped) block holds no allocated cell, is nobody's chunk or stash, and is not a live grant: M7's release contract (§4.8) | timeline (b) step 4 (§2.5 item 1); the tail shrink or the flip taking D while a stash holds its cells (CR-014, CR-016); the shrink releasing the grant (`shrink_ignores_tenure`) |
| `FreeBehindCursor` | invariant | no free or stashed cell lies ahead of the sweep cursor (HEAP_055's premise "nothing allocates into an unswept block") | a free cell the sweep would later coalesce over |
| `ClaimsInRange` | invariant | every claimed chunk unit exists in its block (model-level: the code also clamps the chunk's end, §5) | `claim_after_exhaustion` claims unit 3 of a 2-unit block |
| `IM13` | invariant | no worker chunk lies in a t0 block during a cycle | `cursor_on_t0` |
| `TV5` | invariant (constant-level) | the grant is neither the mutator's cursor block nor, mid-cycle, a t0 block | `grant_includes_cursor`, `grant_t0_block` |
| `NoLostRequiredBit` | end-state (under `AllDone`) | every allocate-black bit set during a cycle, and every bit the marker set, is still set | timeline (a) |
| `AllocMapExact` | end-state | in every uniform post-t0 block, bit set ⇔ cell allocated (HEAP_054) | a lost bit in a chunk byte shared by two workers (`chunk_unit_subbyte`) |
| `assert shared.b \notin rel` in `W_Shrink` | assertion | the shrink never picks the Current shared block during a parallel minor (the `detachFromAllocation` FATAL) | CR-014 in `sweep_virgin`: the tail completion shrinks on a worker while V's cells are in an unflushed chunk. TLC checks assertions in **every** configuration, so each `sweep` configuration that is not about CR-014 carries `tail_defers` |
| `assert ~grantOn` in `U_T0` | assertion | no grant is live when a mark cycle starts (`resetAllocCursors`' FATAL; HEAP_070) | `launch_before_t0` |

**Expected failures of the faithful model.** Like M2's `episode_stop` (CR-005), the configurations
marked "expected: FAIL" in §6 reproduce known or suspected defects. They stay in `models.txt` as
expected failures and flip to "pass" in the same change that fixes the code. The fix-candidate
controls of §5 show beforehand that the proposed fix removes the violation.

### 4.8 Contracts with the other models (parent plan §5.0)

- **Used from M1: the marker footprint, not the closure.** The `Marker` process sets bits only of
  objects live at t0 in t0 blocks (`T0Live`). That is M1's `MarkerFootprint` (IM3). M4 does not
  use SnapshotCycle's conclusion ("everything reachable at the handoff is marked or allocated
  after t0").
- **Not used: M3's `CopyOnceContract`.** M4 treats each promotion as one allocation request and
  checks its properties for any sequence of requests, so it holds whether or not a young object
  could be copied twice. Nothing in M4 depends on slots or copies.
- **Provided to M1 and M5: bit faithfulness.** A bit set by allocate-black or by a marker is never
  lost (`NoLostRequiredBit`, `NoRaceBitmap`), and cursor, chunk and grant bit sets never touch a
  t0 byte or another owner's word (`IM13`, `TV5`, `AllocMapExact`). M1 and M5 model one bit per
  object and assume this (M1 A2; M5 A2).
- **Provided to M7: the release contract.** No released block is still referred to by a cursor,
  chunk, stash, grant or free-list cell (`ReleasedSafe`; the free-list part holds by
  construction). CR-014 and CR-016 are its expected violations.

## 5. Negative and positive controls

`MUTANT` is a **set**, so fix candidates can be combined. `{}` is the code as it is.

| Element | Code change it represents | Configuration | Must |
|---|---|---|---|
| `plain_allocate_black` | `test_plain_allocate_black_` (`initObjectHeaderWithSize` `:515`): plain `setMarkBitInBlock` for mid-cycle allocate-black, on the mutator's pop | `epoch_cycle` | violate `NoLostRequiredBit` (and `NoRaceBitmap`) |
| `plain_stash_black` | the same plain set in `finalizePoppedCellW` (`:1083`); no hook exists, a model-only change | `cycle` | violate `NoLostRequiredBit` (and `NoRaceBitmap`) |
| `cursor_on_t0` | `test_cursor_takes_t0_block_` (`runCycleStepConcurrent`, `:4666-4686`): a cursor refills from a t0 uniform block. The hook breaks the mutator's cursor; the model breaks the shared promotion block (IM13 at `publishShared`), the same premise | `cycle` | violate `IM13`, and `NoOverwriteLive` or `NoLostRequiredBit` |
| `chunk_unit_subbyte` | chunk units that do not cover whole bitmap bytes (drop the 64-cell unit rule, `OldGenSpace.hpp:646`) | `cycle` | violate `NoRaceBitmap` and `AllocMapExact` |
| `chunk_unit_subword` | chunk units of whole bytes but not whole words (e.g. `kChunkUnitCells = 8`): the code's comment would still hold, but `nextFreeCell` reads the neighbour's word | `cycle` | violate `NoRaceBitmap` |
| `claim_after_exhaustion` | `claimChunkW` without its `lo >= ncell` test (`:1181`) **and** without the clamp of the chunk's end to the block (`:1189-1190`). Dropping the test alone is harmless (the clamped cursor finds no cell), so the model's "past the end" chunk is the next block's cells | `cycle` | violate `ClaimsInRange` |
| `grant_t0_block` | `test_grant_t0_block_` (`OldGenTenure.cpp:114`) | `epoch_cycle` | violate `TV5` and `NoOverwriteLive` |
| `grant_includes_cursor` | `grantTenure` without its skip of the mutator's cursor block (`OldGenTenure.cpp:100`; the hazard 7b found) | `epoch_cycle` | violate `TV5` and `NoDoubleAlloc` |
| `shrink_ignores_tenure` | `test_shrink_ignores_tenure_` (`OldGenSpace.cpp:5805`) | `epoch_idle` | violate `ReleasedSafe` |
| `marker_on_post_t0` | a background marker greys a stale cell in a post-t0 block: CR-017's worst case (M1's review: the t0 young walk greys an old cell a STW major freed, whose block is later reused as a cursor or grant block). IM13's premise is broken from the marker's side | `cycle` (chunk cell 11), `epoch_cycle` (grant cell 16, cursor cell 19) | violate `NoRaceBitmap` (the marker's `fetch_or` against the owner's plain `setBit`); a lost bit may also fail `NoLostRequiredBit` |
| `launch_before_t0` | the tenure launch placed before a same-pause cycle start (`TenureLaunchScope`, `ThreadLocalHeap.cpp:738-743`) | `epoch_cycle` | fail the `U_T0` assertion |
| `large_promo` (**precondition**, not a code change) | an object of exactly `alloc_buffer_size` bytes is promoted (test geometries: `W_Large`) or allocated by the mutator (`U_Large`), so the flip can run | `sweep_large` | enables CR-016 |
| `flip_ignores_tenure` | `allocateFromEmptyRegularBlocks` without its `kAllocTenure` skip (`:2679`) | `epoch_idle` + `large_promo` | violate `ReleasedSafe` (T6) |
| `finalize_in_lock` (**fix candidate**) | finalize stashed cells under `promo_mu_` | `sweep_race_bitmap` | make `NoRaceBitmap` **pass** (removes CR-002). `NoRacePhase` still fails: rung 1 reads `gc_phase_` too |
| `phase_atomic` (**fix candidate**) | make `gc_phase_` a relaxed atomic | `sweep_race_phase` | make `NoRacePhase` **pass** (removes CR-001's race). The decision-point problem stays: see the next two rows |
| `tail_defers` (**fix candidate**) | the tail completion path calls `sweepCompleteInPromotion` like the in-loop one | `sweep_tail`, `sweep_tail_release`, `sweep_tail_live` | make each **pass** (CR-014) |
| `count_until_shrink` (**fix candidate**) | a finalize attributes `live_bytes` while the shrink is still deferred, not only while `gc_phase_ != Idle` | `sweep_release` | make `ReleasedSafe` **pass** (§2.5 item 1). It does not fix CR-016: a stashed cell is not finalized at all |

## 6. Configurations

Every configuration uses `NAllocs = 2`. `CycleActive` matters only for `epoch`, but is set in
every file because it is a constant. One configuration per register entry, each listing only
its target property, so a violation cannot be reported under the wrong entry. TLC checks the two
assertions in every configuration: every `sweep` configuration that is not about CR-014 carries
`tail_defers`, and the `epoch` ones never reach `U_T0` with a live grant. Deadlock checking stays
on: every lock hold makes progress (§4.1), so a deadlock is a model bug.

| Config | `Scenario` / `CycleActive` / `MUTANT` | Checks | Tier | Expected |
|---|---|---|---|---|
| `sweep_race_bitmap` | sweep / — / `{"tail_defers"}` | `NoRaceBitmap` | quick | **FAIL: CR-002** |
| `sweep_race_phase` | sweep / — / `{"tail_defers"}` | `NoRacePhase` | quick | **FAIL: CR-001 (race)** |
| `sweep_release` | sweep / — / `{"tail_defers"}` | `ReleasedSafe` | quick | **FAIL: CR-001's S1 half** (§2.5 item 1) |
| `sweep_tail` | sweep_virgin / — / `{}` | the `W_Shrink` assertion | quick | **FAIL: CR-014** (the detach FATAL) |
| `sweep_tail_release` | sweep / — / `{"count_until_shrink"}` | `ReleasedSafe` | quick | **FAIL: CR-014** (the silent release) |
| `sweep_tail_live` | sweep / — / `{"count_until_shrink"}` | `NoRaceLive` | quick | **FAIL: CR-014** (the `live_bytes` race) |
| `sweep_large` | sweep / — / `{"tail_defers", "count_until_shrink", "large_promo"}` | `ReleasedSafe` | quick | **FAIL: CR-016** |
| `sweep_fixed` | sweep / — / `{"tail_defers", "count_until_shrink", "finalize_in_lock", "phase_atomic"}` | all invariants | quick | pass: the combined fix candidates |
| `sweep_functional` | sweep / — / `{"tail_defers", "count_until_shrink"}` | `NoDoubleAlloc`, `FreeBehindCursor`, `ClaimsInRange`, `AllocMapExact` | quick | pass |
| `cycle` | cycle / — / `{}` | `NoRaceBitmap`, `NoRacePhase`, `NoRaceLive`, `NoDoubleAlloc`, `NoOverwriteLive`, `FreeBehindCursor`, `ClaimsInRange`, `IM13`, `NoLostRequiredBit`, `AllocMapExact` | quick | pass |
| `epoch_cycle` | epoch / TRUE / `{}` | `NoRaceBitmap`, `NoRaceLive`, `NoDoubleAlloc`, `NoOverwriteLive`, `ReleasedSafe`, `TV5`, `NoLostRequiredBit`, `AllocMapExact` | quick | pass |
| `epoch_idle` | epoch / FALSE / `{}` | `ReleasedSafe`, `NoRaceBitmap`, `NoRaceLive`, `NoDoubleAlloc`, `AllocMapExact` | quick | pass |
| `epoch_l3` (to add) | epoch with two collector members claiming grant chunks (`grantAllocateShared`) | as `epoch_cycle` | deep | pass |
| one configuration per §5 control | as the table says | the named property | quick | as the table says |

**The shortest expected violations** (hand-traced; W = the worker that claims U's last cell, S =
the other). Each fits the bounds with room to spare.
- `sweep_race_bitmap`: W claims unit 2 and allocates cell 11. S locks and sweeps the D run and
  `[1, 2]`, then ends the slice, leaving the cells for another class. W locks and batch-pops
  cell 1; after its unlock it finalizes cell 1 (`fetch_or` M1). S locks and sweeps `[3]`: its
  word read and its `clearBit` of M1 are unordered with W's `fetch_or`. About 20 steps.
- `sweep_race_phase`: W's chunk allocation reads `gc_phase_` while S completes the sweep in one
  hold.
- `sweep_release`: as above to W's batch pop, but W pops D's cells `{6, 7}`. S sweeps to the end
  and completes on the in-loop path (deferred). W finalizes cell 6, reads Idle and adds no
  `live_bytes`. The merge's deferred shrink releases D with cell 6 allocated.
- `sweep_tail`: W allocates 11, advances to V and claims V's chunk; S sweeps everything and
  completes on the tail path. `W_Shrink` sees V (Current, `live_bytes` 0) in its release set.
- `sweep_tail_release` / `sweep_tail_live`: W batch-pops D's cells after the D run is flushed;
  S completes on the tail path. The shrink releases D while W's stash holds its cells, and its
  plain reads of `live_bytes` are unordered with W's `fetch_add`.
- `sweep_large`: W batch-pops D's cells; S's large promotion flips D.

**If a `sweep` configuration exceeds about two minutes:** first cap the batch pop at 1 cell,
then drop the last sweep item (`[4, 5]`). Every trace above uses one stashed cell and the first
three items only.

Every `.cfg` needs `INIT Init` and `NEXT Next`; M4 has no procedures, so no `defaultInitValue`.
`MC.tla` only `EXTENDS PromoBitmap` until step 5 of §9 moves the heap into constants.

## 7. Accuracy notes (parent plan rules A1–A9)

| Rule | M4 |
|---|---|
| A1 | Every byte update is one step if atomic, two if plain (read into `seen`, write back); the read step also records the plain word scan before it. Every `gc_phase_` read is its own step. The stash finalize is split from its pop by at least one lock release, as in the code. A lock hold does one ladder action. One sweep item is one iteration of the gap-sweep loop (its budget is tested only at the head), and a slice may end after any item. Known merges, all over-approximations: the advance's claim and allocation happen after the unlock; the rung-1 byte read is taken at `nextFreeCell` time, so the lost-update window is wider than `setBit`'s own load and store. |
| A2 | **Bytes, not bits:** `bits[y]` is a byte. **Words for the scans:** `nextFreeCell` and `nextSetBit` read 64-bit words, so a scan is a read of every byte of its word (`WordOf`). Chunks are whole words; different blocks never share a word. |
| A3 | Footprint rows: 05c H1, H1b, H2, H9; 06 P§3.11 (`PromoCtx`, `partial_`, the free lists, `promo_mu_`, `gc_phase_`, `live_bytes`); 07 P§3.17 T5 (granted blocks) and T6 (the skip rule: `grant_includes_cursor`, `shrink_ignores_tenure`, `flip_ignores_tenure`, `launch_before_t0`; the refill's `kAllocQueued` test is not modelled, as a granted block has left `partial_` already). `gc_phase_` is **missing** from 06 P§3.11; add it with CR-001's fix. `live_bytes` is one race location (`"live"`). **Not modelled:** `marking_active` (plain, read with `gc_phase_`, written only in pauses); the `BlockInfo` fields the flip writes (§2.5 item 3); the markers' live-bytes accumulators (folded in pauses). |
| A4 | W3 (every mark-byte access pattern at C11 level: relaxed `fetch_or` against relaxed `fetch_or`; plain `setBit` and word scans on a post-t0 word against nothing; CR-002's plain word read and `clearBit` against `fetch_or`), W3f (`minorwork::SpinMutex` gives lock semantics: acquire on `exchange`, release on the unlocking store; `MinorWork.hpp:87-110`) and W4b (a chunk of a freshly published shared block is fully visible). The SC model with vector clocks finds data races by the C++ definition, but not weak-memory reorderings; W3 covers those. |
| A5 | §8: a new gc-heap-tsan scenario. |
| A6 | §5: twelve negative controls, four of them existing hooks (`test_plain_allocate_black_`, `test_cursor_takes_t0_block_`, `test_grant_t0_block_`, `test_shrink_ignores_tenure_`), plus four fix-candidate positive controls and the precondition `large_promo`. |
| A7 | `NoLostRequiredBit` = IM4 + the 05c H1 argument; `IM13` = IM13; `TV5` = 07 TV5; `AllocMapExact` = HEAP_054; `FreeBehindCursor` = HEAP_055's premise; `ReleasedSafe` = HEAP_051/HEAP_070 (live bytes, grant skip) and M7's release contract; the `W_Shrink` assertion = the `detachFromAllocation` FATAL (HEAP_054); `U_T0` = HEAP_070's `resetAllocCursors` FATAL. `NoRace*` = `MODEL_M4_RACE`. |
| A8 | 2 workers + merge + (in `cycle`) a marker, or marker + collector + mutator; 7 blocks, 19 cells, 9 bytes; `NAllocs = 2`. No counter wraps. The vector clocks grow only with lock releases and claims, so they are bounded because every process terminates (every lock hold makes progress). Under `claim_after_exhaustion` the claims do not terminate, but `ClaimsInRange` fails at the first extra claim. |
| A9 | `region` markers on: `initObjectHeaderWithSize`'s allocate-black branch; `finalizeBitmapCell`; `finalizePoppedCellW`; `finalizeBitmapCellW`; `cursorAllocateW`; `claimChunkW`; `publishShared`/`advanceSharedW`/`startVirginBlockShared`; `beginParallelPromotion`'s shared-word setup; `allocatePromotion`; `ladderFrom2W`; `sweepOnDemandAllocate`; `sweepCompleteInPromotion`; `endParallelPromotion`; `lazySweep` (the gap-sweep loop, the early exit and **both** completion paths); `onSweepComplete`, `computeFragmentationStats`, `maybeShrinkCapacity` pass 1; `allocateFromEmptyRegularBlocks` (skip list and flip); `grantTenure`, `grantAllocate`, `grantAllocateShared`, `returnTenureGrant`. Whole file: `BitmapScan.hpp`. `census`: `OldGenSpace.cpp`, `OldGenTenure.cpp`, `OldGenSpace.hpp`. `grep` rows: `gc_phase_ =`, `setMarkBitInBlock\|bitscan::setBit\|bitscan::clearBit\|loadWord`, `alloc_state == kAllocTenure`, `par_promo_active_`, `live_bytes`. Callers of `allocatePromotion`: `NurseryParallel.cpp:259`, `NurseryTenure.cpp:984`, `NurserySpace.hpp:481`. |

## 8. Trace validation

**Harness.** No existing harness forces a sweep inside a parallel minor: `gc-heap-tsan` runs
`gc_thread_mode = 0` and small geometries, and never checks for it. Add a scenario to
`test/gc-heap-tsan/heap_driver.cpp`:
- a small old gen with many small mixed blocks, some of them all dead;
- a major, so a lazy sweep is pending;
- a parallel minor large enough that workers exhaust the shared block and reach sweep-on-demand;
- repeat with `ECO_GC_HELPER_JITTER_US` jitter.

This scenario is also the TSan reproduction for CR-001 and CR-002, and the natural test for
CR-014. CR-002 needs a gap cell of another class than the sweeper's (several size classes in the
dead gaps). CR-016 needs a promoted object of **exactly** `alloc_buffer_size` bytes (32 KiB in
this driver), which today's driver never makes: add one. A variant with a tenure job (region
mode, mode 2) and a running cycle feeds the `epoch` scenarios, and one with 7c's pause engine
(`tenure_mode = 1`, `tenure_sync_threads > 1`) covers `runJobParallel`.

**Hooks** (`ECO_TLA_TRACE`, compiled out otherwise):

| Event | Where | Fields |
|---|---|---|
| `lock` / `unlock` | around every `promo_mu_` hold in `allocatePromotion` (both the ladder's and the large path's) | `t` |
| `wordRead` / `bitWrite` / `bitAtomic` | each plain scan (`nextFreeCell`, `nextSetBit`) and the fast path's byte read; the plain write; each `fetch_or` | `t`, block id, word or byte index, mask |
| `liveAdd` / `liveRead` / `liveSet` | each atomic `live_bytes` add outside a pause; `computeFragmentationStats` and pass 1; the flip's store | `t`, block id (none for a whole-table read) |
| `phaseRead` / `phaseWrite` | each `gc_phase_` access listed in §3 | `t`, value, `locked` |
| `sweepItem` | the gap-sweep loop, once per iteration | block id, offset, gap cells, live object, `blockEnd` |
| `sweepDone` | the early exit and both completion paths | `path` (`early`/`loop`/`tail`), `deferred` |
| `publish` | `publishShared` | block id |
| `claimChunk` | `claimChunkW` CAS | word before / after |
| `stashPop` / `finalize` | `allocatePromotion` batch pop; `finalizePoppedCellW` | cell, phase seen |
| `release` / `flip` | `releaseBlockToAllocator`; `allocateFromEmptyRegularBlocks` | block id |
| `grantAlloc` / `grantReturn` | `grantAllocate`, `returnTenureGrant` | cell / block |

**Trace spec.** M4's heap is fixed in the module, but a real trace has real blocks. So the
implementation first moves `Cells`, `Blocks`, `Bytes`, `BlkOf`, `ByteOf`, `T0Blocks` and the
initial states into **constants** that `MC.tla` defines (§9 step 5). `TracePromoBitmap.tla` then
reads the heap layout from the trace's first line (block ids, cell offsets, byte indices) and
replays the events against the model's steps. The vector-clock race detector runs on the replayed
behaviour too, so a trace can show a race that TSan missed in the same run.

## 9. Implementation steps

1. Create `test/tla/M4-promotion-bitmap/` with `PromoBitmap.tla` (§4.6), `MC.tla`, the §6
   configurations, MAPPING.md (§4.5 + A3's rows) and AUDIT.md.
2. `pcal` + `sany`; then TLC on `cycle`, `epoch_cycle`, `epoch_idle`, `sweep_functional` and
   `sweep_fixed`. All must pass. If a `sweep` one exceeds about two minutes, apply the §6
   reductions (batch pop of 1, then drop the last sweep item) before touching anything else.
   Do **not** lower `NAllocs`: with one promotion per worker no worker both uses a chunk and
   reaches the lock, and the expected failures of step 3 become unreachable.
3. Run the seven "expected: FAIL" configurations. For each trace:
   - check it against the code (primer §4.3: the model over-approximates the shrink's sizing,
     the ladder's hold granularity and the class of a flushed cell);
   - record it in the register: CR-001, CR-002, CR-014 and CR-016 go to Reproduced (model);
   - keep the configuration as an expected failure in `models.txt`.
4. Run every §5 control; each must behave as its row says. The four fix candidates are the
   evidence for the fixes' designs.
5. Parameterise the heap (constants in `MC.tla`) without changing behaviour. Re-run step 2 and
   confirm the same state counts.
6. Add `epoch_l3`: two collector members, grant chunks claimed by CAS (`grantAllocateShared`,
   units ≥ 1,024 bits in the code; whole words in the model). The claim CAS is relaxed
   (`OldGenTenure.cpp:245-249`): model it without `SharedSync`.
7. The gc-heap-tsan scenario (§8) and trace validation. The scenario doubles as the TSan
   reproduction for CR-001, CR-002 and CR-014.
8. Wire into `models.txt` and `test/tla/manifest.txt` (A9). Close-out: AUDIT.md entry, register
   updates, the parent plan's §11 row.

## 10. Open questions for the implementer

1. **§2.5 item 1 needs a mixed block with `live_bytes == 0` that is still swept.** The heavy
   pass (`reclaimAllDeadBlocksFromMeta`, `OldGenSpace.cpp:6175`, called from the handoff tail at
   `:3977`) keeps such a block when releasing it would take the heap below `min_heap` (`:6214`),
   so it can exist. Still open: whether the light shrink's `desired_heap` (1.5 × desired, `:5759`)
   would release it; the model releases every candidate. If it never would, `sweep_release`'s
   trace is spurious for the shrink but the same stale `live_bytes` still feeds the flip (item 3).
2. **How often does the tail completion path fire inside a ladder rung?** Not only "exactly at
   the boundary": the last block's final iteration must use up the slice budget (a trailing dead
   run is one step, `:5347-5348`) with the target class's list still empty (else the early exit
   at `:5452-5460`). The gc-heap-tsan scenario should count `sweepDone{path=tail}` inside
   parallel minors.
3. **The flip in serial code.** `allocateFromEmptyRegularBlocks` trusts `live_bytes == 0`, but a
   mixed block's `live_bytes` stops counting at the sweep's completion (§2.1). So the mutator's
   `allocate()` of an object of exactly `alloc_buffer_size` bytes (`:1931-1933`, any geometry)
   can flip a mixed block that holds objects allocated after the sweep. That is not a
   concurrency defect and M4 does not model it; it is reported with this review (§11) as the
   common root of CR-016 and §2.5 item 1.
4. Should `gc_phase_` get a row in the 06 P§3.11 shared-state table even after CR-001 is fixed?
   Yes if any unlocked reader remains; the model's `NoRacePhase` is the check.

## 11. Adversarial review (2026-09-28)

Against the current tree; the sketch was revised and passes `pcal` + `sany` (tla2tools 1.8.0).
TLC was not run: every reachability claim below is a hand trace (§6).

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | In `sweep`, the one claimable chunk held both free cells, so its claimer finished with `NAllocs = 2` and never took the lock. Only one worker ever swept or stashed: CR-002 and the stash half of CR-001 were unreachable, and `sweep_race_bitmap` would have passed | U's last unit keeps one free cell (the mutator's `PreAlloc`); both workers reach the lock |
| R2 | Blocker | Same in `cycle`: two chunks of two cells for two workers, so no worker used the free list. `plain_allocate_black` (stash path) and `claim_after_exhaustion` could not fire | three free chunk cells for four promotions; no refill block in `cycle` |
| R3 | Blocker | `plain_allocate_black` was attached to `finalizePoppedCellW`, which has no plain hook; `test_plain_allocate_black_` lives in `initObjectHeaderWithSize` (`:515`) | the mutant moved to the mutator's pop (`epoch_cycle`); the stash variant is the model-only `plain_stash_black` |
| R4 | Blocker | The free list was FIFO; the code pushes and pops at the head (`:4989-4997`, `:2004`). D's cells came out last, so §2.5 item 1 (CR-001's S1 half) was unreachable; `CHOOSE` on the stash also fixed its order | LIFO free list; stash finalized in any order |
| R5 | Blocker | One class and an always-popping sweeper: the sweeper took every cell it flushed, so no other worker could hold a cell next to a live object still to clear. CR-002 needs a cell of another class | the sweeper may leave flushed cells (class abstraction), and may take the early exit at the last block (`:5452-5460`, previously absent) |
| R6 | Blocker | `sweep_tail`'s assertion fired only because `U` started with `live_bytes = 0` while its first unit was used, an inconsistent state (the mutator's cells are flushed at `beginParallelPromotion`). With a consistent `U` it was unreachable | consistent `U`; new scenario `sweep_virgin` (V, `live_bytes` 0, published by the refill) for the FATAL |
| R7 | Major | Word granularity: `nextFreeCell` and `nextSetBit` read 64-bit words (`BitmapScan.hpp:25`); the detector knew bytes only. CR-002's window is a word, and chunks must be whole words (the code's comments say bytes) | `WordOf`, `WordRd`; mutant `chunk_unit_subword` |
| R8 | Major | CR-014 also races on `live_bytes`: the tail shrink's plain reads (`:6378`, `:5802`) against other workers' `fetch_add` outside the lock, whatever the sizing | race location `"live"`, `NoRaceLive`, `sweep_tail_live` |
| R9 | Major | CR-016 (the register's M4 entry) was not modelled at all | `W_Large` with precondition `large_promo`, `sweep_large`; `ReleasedSafe` also checks stashes. The flip also needs a promotion of exactly `alloc_buffer_size` bytes (`:2680`) |
| R10 | Major | No virgin/bag rung: after a release a worker could wait forever, and TLC would report a deadlock instead of the target invariant | `W_SwTest` allocates outside the model when nothing is left to sweep; `LockUseful` removed |
| R11 | Major | pcal primes a variable in a step's own text but not inside `define` operators: the claim's flush would have been recorded at the pre-CAS clock | `Acc` passes `vc[self]` explicitly |
| R12 | Major | Sweep items split a gap's flush from the next live object's clear, and D's dead run into two flushes; the code does both in one loop iteration (budget test at `:5336`); `fully_swept` was set only at completion | items are iterations `[g, l, e]`; per-block `swept`; D first in block order |
| R13 | Minor | The merge awaited and joined the background marker, which keeps running across the minor | joins the workers only |
| R14 | Minor | `claim_after_exhaustion` described a harmless change (the chunk's end is clamped, `:1189-1190`) | the mutant drops the test and the clamp |
| R15 | Minor | T6 (M5 delegates the grant skip rule to M4) lacked the flip's skip (`:2679`) | `U_Large`, mutant `flip_ignores_tenure` |
| R16 | Minor | Contracts: M4 uses M1's `MarkerFootprint`, not SnapshotCycle's closure, and not M3's `CopyOnceContract`; it provides bit faithfulness (M1, M5) and the release contract (M7) | §4.8 |
| R17 | Minor | Drift: suspicions 1–3 now have register ids; 7c's `runJobParallel` also runs the ladder; `hist` kept every access (now the latest per kind); line numbers | §1, §2.2, §2.5, §3, §4.4, §7 |
| R18 | Major | IM13 was checked only from the owners' side (cursors, chunks, grants on t0 blocks); nothing broke it from the marker's side, which CR-017 (M1's review) does | mutant `marker_on_post_t0` |
