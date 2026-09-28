# Threaded GC — TLA+ model M4: old-gen allocation and mark-bitmap bytes

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). The PlusCal sketch passes the translator and
SANY; TLC has not run.

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

M4 is the one model that works at byte granularity and carries a **data-race detector** as an
invariant. Two register entries live here:
- **CR-001:** the `gc_phase_` race and its moved decision point;
- **CR-002:** the plain `clearBit` against an atomic `fetch_or` on one byte.

Building this plan also turned up two new suspicions (§2.5), which the model is built to settle.

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
- that no block is released while it still holds live cells or belongs to someone;
- that no C++ data race exists on a mark byte or on `gc_phase_`.

The last property is the rule that a plain access racing with any conflicting access is undefined
behaviour, checked with vector clocks the way ThreadSanitizer does.

## 2. The protocol in plain words

### 2.1 The pieces

- **Mark bitmap bytes.** Every old-gen block has a bitmap with one bit per 8-byte slot, so one
  byte covers 64 bytes of heap (`markBitLocation`, `OldGenSpace.hpp:1753`). An object's bit is
  the bit of its first slot. Two small objects next to each other share a byte. Different blocks
  never share a byte: each block's bitmap is its own arena slot (HEAP_050).
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
  current block per size class and take **chunks** of it: 64-cell units, so a chunk always covers
  whole bitmap bytes. They take a chunk by CASing the word `(block id + 1) << 32 | next unit`
  (`claimChunkW`, `OldGenSpace.cpp:1171`). A worker then allocates inside its own chunk with plain
  bit sets and no lock (`cursorAllocateW`, `:1146`).
- **The ladder and `promo_mu_`.** When a worker's chunk is used up and no chunk can be claimed, it
  takes the spin lock `promo_mu_` (`allocatePromotion`, `:1536`) and tries, in order:
  1. advancing the shared block (`advanceSharedW` `:1219`, `startVirginBlockShared` `:1249`);
  2. popping up to 16 cells from the free list into its **stash**;
  3. the rest of the ladder (`ladderFrom2W`, `:1306`), including **sweep-on-demand** (`:1336`)
     and the panic sweep (`:1346`), which run slices of the lazy sweep **under the lock**.
- **The stash.** Cells popped under the lock are **finalized outside it**. Finalizing writes the
  header, and, if the phase says so, sets the mark bit (atomic) and adds the cell to the block's
  `live_bytes` (atomic) (`finalizePoppedCellW`, `:1069`; consumed at `:1581` and `:1634`).
- **`gc_phase_`** (`OldGenSpace.hpp:815`) is a **plain** field: Idle, Marking or Sweeping. The
  sweep sets it to Idle when it passes the last block.
- **`live_bytes`** (per block) counts live bytes: marked objects plus allocate-black allocations.
  Its **readers decide whether a block is empty**:
  - the light-pass shrink run by `onSweepComplete` (`:5488`) → `maybeShrinkCapacity` pass 1
    (`:5796-5810`) releases every fully swept block with `live_bytes == 0`;
  - the empty-block flip `allocateFromEmptyRegularBlocks` (`:2665`).

  An **under**-count therefore means a block with live objects can be released. This is the
  historical bug in parallel-gc.md §3.5.
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

Two consequences shape the model:
1. CR-001 and CR-002 need a sweep and several workers. They live in a minor that runs outside a
   mark cycle (scenario `sweep`).
2. Lost *required* mark bits need a running cycle, and so a marker (scenarios `cycle` and `epoch`).

### 2.3 Worked timelines

**(a) A lost allocate-black bit (05c audit row H1).** A mid-cycle allocation of cell 1 and the
marker's discovery of live object 2 both land in byte M1:

| # | Worker W (plain `b |= 1`) | Marker K (`fetch_or 2`) | byte M1 |
|---|---|---|---|
| 1 | reads M1 = `{}` | | `{}` |
| 2 | | `fetch_or`: sets 2 | `{2}` |
| 3 | writes back `{} ∪ {1}` | | `{1}`: **object 2's bit is lost** |

At the handoff, object 2 looks dead and the sweep frees it: silent heap corruption. The code
therefore uses `setMarkBitAtomic` on these paths, and `test_plain_allocate_black_` is the
negative-control hook that puts the plain version back. The model's mutant
`plain_allocate_black` is this timeline.

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
checked property (`ReleasedSafe`).

**(c) CR-002: plain `clearBit` against `fetch_or` on one mixed-block byte.** Byte M1 covers cells
1, 2 and 3: cell 1 is a dead gap, cells 2 and 3 are live. The gap sweep runs in budgeted slices,
each under its own hold of `promo_mu_`:

| # | W1 (sweeping, under the lock) | W2 | byte M1 |
|---|---|---|---|
| 1 | slice 1: flushes gap 1 to the free list, clears 2's bit, budget ends, unlocks | | `{3}` |
| 2 | | locks, pops cell 1 into its stash, unlocks | `{3}` |
| 3 | slice 2 (locked): reads M1 = `{3}` to clear 3 | | `{3}` |
| 4 | | finalizes cell 1 outside the lock: `fetch_or` sets 1 | `{1, 3}` |
| 5 | writes back `{3} \ {3}` | | `{}`: **cell 1's bit is lost** |

The lost bit is behind the sweep cursor and no mark cycle is running, so it looks harmless: the
next `startMark` clears the bitmap. But steps 3–5 are a plain read-modify-write racing an atomic
one on the same byte, and that is undefined behaviour. `nextSetBit`'s plain read of the byte
races the same way.

**(d) Why IM13 makes the plain cursor, chunk and grant bit sets safe.** A plain RMW is safe when no
other thread can touch the same byte until the next synchronisation.
- **Background markers** set bits only for objects that existed at t0, so only bytes of **t0
  blocks**.
- **IM13** says every cursor, every shared promotion block and every tenure grant uses only blocks
  **created after t0**, during a cycle. Asserted in `setCursor`, `setCursorW`, `publishShared` and
  `grantTenure` (TV5).
- **Chunks** are whole bytes and belong to one worker. A **grant** block belongs to the collector,
  and every mutator path skips it.

So no other thread writes those bytes, and the plain `setBit` at `OldGenSpace.cpp:820`, `:1131`
and `OldGenTenure.cpp:177`, `:214` is race-free. The model's mutants break each premise in turn
(§5) and must produce races or double allocations.

### 2.4 What the model does not have to decide

- The allocate-black `fetch_or` against the marker's `fetch_or`: both are atomic, so this is
  fine. W3 checks the relaxed ordering at C11 level.
- The free-list links and Tier-M back-links (HEAP_052): always written under `promo_mu_` or by
  the single mutator.
- Large-object marks (`largeMark` bytes), and the `largeMark = 0` on reuse of a free t0 large
  block: the 05c audit argues these away (no S_H object lives there). The model has no large
  blocks; the audit argument is recorded in MAPPING.md.

### 2.5 Two new suspicions this model must settle

Found while writing this plan, by reading the current tree. **Not reproduced, not in the
register.** They are reported to the plan owner.

1. **The deferred shrink can release a block that holds cells allocated after the sweep
   completed (timeline b, steps 2–4).**
   - Evidence: `finalizePoppedCellW` (`OldGenSpace.cpp:1075-1086`) and `finalizePoppedCell`
     (`:2025`) → `initObjectHeaderWithSize` (`:497-520`) add `live_bytes` only when
     `gc_phase_ != Idle`; `sweepCompleteInPromotion` (`:1361-1366`) defers; `endParallelPromotion`
     runs `onSweepComplete` at the end (`:1530-1533`); pass 1 of `maybeShrinkCapacity` releases
     `fully_swept && live_bytes == 0` blocks (`:5802`).
   - Precondition: an all-free mixed block survives to the sweep (kept by `min_heap` /
     `canRelease`).
   - Checked by `ReleasedSafe` in scenario `sweep`.
2. **`lazySweep`'s tail completion path bypasses the parallel deferral.** The in-loop completion
   calls `sweepCompleteInPromotion` when `par_promo_active_` (`:5254-5255`). The tail path
   (`:5466-5472`), reached when the slice budget runs out exactly at the last block's boundary,
   sets `gc_phase_ = Idle` and calls `onSweepComplete()` **directly**, on a worker, under
   `promo_mu_`, while other workers are allocating. Then:
   - the light shrink sees the shared block's `live_bytes` without the workers' unflushed
     `pending_live`, so it may pick it. `releaseBlockToAllocator` → `detachFromAllocation` then
     aborts in every build ("detachFromAllocation during a parallel minor", `:712-717`): a loud
     crash;
   - an exhausted, retired (`kAllocNone`) shared block that a worker's last chunk still points
     into, or a mixed block whose popped cells are still unfinalized in a stash, reads
     `live_bytes == 0` and is released **silently** (detach returns early for `kAllocNone`
     blocks). The worker then writes into released memory.

   This is reachable at N = 1 too, in 7c's pause engine (`runJobParallel(…, 1)` still sets
   `par_promo_active_`). Checked by the `W_Shrink` step: the assertion models the detach FATAL,
   and `ReleasedSafe` covers the silent case.

## 3. The code the model covers

Line numbers are from the tree of 2026-09-28, after the 7c pull.

| Code | Lines | Model element |
|---|---|---|
| `markBitLocation`, `testAndSetMarkBitInBlock`, `setMarkBitInBlock`, `setMarkBitAtomic`, `isMarkedInBlockRelaxed`, `testAndClearMarkBitInBlock` | `OldGenSpace.hpp:1753`, `1780`, `1800`, `1822`, `1836`, `1853` | `bits[y]` (a byte = the set of its set cells); `ByteOf(c)` |
| `promo_mu_` (a `minorwork::SpinMutex`) | `OldGenSpace.hpp:765`; `MinorWork.hpp:85-113` | `lock`, `LockAcquire`, `LockRelease` (plus the clock `lockvc`) |
| `gc_phase_` | `OldGenSpace.hpp:815` | `phase` (a plain location for the race detector) |
| `initObjectHeaderWithSize` (allocate-black; `test_plain_allocate_black_` `:515`) | `OldGenSpace.cpp:487-534` (atomic set `:518`) | `U_PopBit`; the mutant `plain_allocate_black` |
| `finalizeBitmapCell` (mutator cursor, plain `setBit`) | `:802-836` (`:820`) | `U_Cursor`, `U_CursorSet` |
| `flushCursorW` (atomic `live_bytes` add) | `:1029` | the flush in the claim branch; `G_Flush` |
| `finalizePoppedCellW` (stash finalize; phase read `:1075`; atomic set `:1083`) | `:1069-1096` | `W_StBit` (after the finalize branch) |
| `finalizeBitmapCellW` (chunk cell; plain `setBit` `:1131`; phase read `:1135`) | `:1121-1142` | `W_R1Phase`, `W_R1Set` |
| `cursorAllocateW` | `:1146-1170` | the rung-1 branch |
| `claimChunkW` (CAS on the shared word) | `:1171-1198` | the claim branch; `SharedSync` |
| `publishShared`, `advanceSharedW`, `startVirginBlockShared` | `:1201`, `:1219`, `:1249` | `W_Locked`, first case |
| `ladderFrom2W` (sweep-on-demand, panic sweep) | `:1306-1347` | `W_SwChk` … `W_PopBit` |
| `sweepCompleteInPromotion` (defer when N > 1) | `:1361-1385` | `deferred := TRUE` in `W_SweepEnd` |
| `endParallelPromotion` (flush, stash return `:1440`, deferred `onSweepComplete` `:1530`) | `:1416-1534` | process `Merge` |
| `allocatePromotion` (stash use `:1581`, lock `:1587`, batch pop `:1619-1623`, finalize after unlock `:1634`) | `:1536-1646` | process `Worker` |
| `finalizePoppedCell` (under the lock) | `:2025` | `W_PopBit` |
| `allocateFromEmptyRegularBlocks` (grant/Current skips `:2676-2679`) | `:2665` | not modelled (the large-promotion path; §10 item 3) |
| `testAndSetMark<ParallelMark>` (`fetch_or`) | `:3039` | process `Marker` |
| `lazySweep`: loop `:5244`; in-loop completion `:5247-5255`; gap sweep `:5331-5360`; tail completion `:5466-5472` | `:5220-5479` | `W_Sweep`, `W_SweepClr`, `W_SweepEnd` (both completion paths) |
| `onSweepComplete` → `maybeShrinkCapacity` pass 1 (tenure skip `:5805`) | `:5488`, `:5699`, `:5796-5810` | `W_Shrink`, `G_Shrink`, `U_SweepDone` |
| `detachFromAllocation` (FATAL on Current during a parallel minor) | `:694-717` | the `assert` in `W_Shrink` |
| `grantTenure` (skips the mutator's cursor block `:100`), `grantAllocate` (`setBit` `:177`), `grantAllocateShared` (`:214`), `returnTenureGrant` | `OldGenTenure.cpp:44`, `:153`, `:197`, `:288` | process `Collector`; `U_Join` |
| `resetAllocCursors`' FATAL on a granted block at t0 | `OldGenSpace.cpp:675-690` | `U_T0` |
| the 7c launch/join order in `ThreadLocalHeap::minorGC` (join first; `TenureLaunchScope` last) | `ThreadLocalHeap.cpp:706-743` | `U_Pause`, `U_Join`, the mutant `launch_before_t0` |

## 4. The model

### 4.1 Abstractions, and why each is sound

| Real thing | Model | Why |
|---|---|---|
| A mark byte = 8 slots | A byte = 2–3 cells (`M1` = cells 1, 2, 3; `U1` = 8, 9; ...) | Sharing is what matters. Three cells in one byte is the smallest layout that reproduces CR-002 (a gap and two live objects, split over two sweep slices) |
| A 64-cell chunk | A chunk = one byte (2 cells) | Keeps "a chunk is whole bytes"; the mutant `chunk_unit_subbyte` breaks exactly that |
| Size classes, free-list classes | One class | All paths in M4 use one class; the interleavings do not depend on the class |
| `live_bytes` in bytes | in cells | Only "= 0?" matters to the readers |
| The shrink's `desired_heap` / `canRelease` sizing | Release **every** fully swept block with `live_bytes = 0` | Over-approximation: the real shrink releases a subset. A violation found this way must be checked against the sizing rule (§10 item 1) |
| The free-list batch of 16 | 2 cells | Enough for "popped but not finalized" |
| The gap sweep's per-slice budget | After each item, the slice may end (`either goto W_Sweep or skip`) | Every real slice boundary is a model boundary |
| Everything a worker does under `promo_mu_` in one hold | One of: advance the shared block, batch pop, or sweep slice(s) then one pop | Follows the ladder order of `allocatePromotion`; `LockUseful` prunes useless lock cycles (a real worker would fall to the next rung or abort) |
| Several tenure collector members (L3) | One collector (B = 1, the exact engine) | The L3 members share grant blocks by chunk claims just like M4's workers. The configuration `epoch_l3` (§6) is the step that adds a second member |
| The heap's objects and their fields | Absent | M4 is about metadata and bytes. Object contents are M1's and M3's |

### 4.2 Constants

| Constant | Meaning | Values |
|---|---|---|
| `Scenario` | which world is modelled (§6) | `"sweep"`, `"cycle"`, `"epoch"` |
| `CycleActive` | `epoch` only: a 5c mark cycle is running during the epoch | TRUE / FALSE |
| `NAllocs` | promotions per worker | 2 |
| `MUTANT` | negative or positive control (§5) | `"none"` or a §5 name |

The miniature heap is fixed in the module:
- `M`: mixed; cells 1–5; bytes `M1` = {1, 2, 3}, `M2` = {4, 5}.
- `D`: mixed, all dead at the mark; cells 6, 7; byte `D1`.
- `U`: uniform, the shared promotion block; cells 8–11 in two chunks, `U1` and `U2`.
- `V`: uniform, the next block for the refill; cells 12, 13.
- `Z`: uniform, a **t0** block with live object 14 and free cell 15.
- `G`: uniform, the tenure grant; cells 16, 17.
- `K`: uniform, the mutator's cursor block; cells 18, 19.

In the cycle scenarios the t0 blocks are `M` and `Z`, and the objects the marker must mark are
2, 3 and 14.

### 4.3 Variables

| Variable | Meaning | Code counterpart | Written by |
|---|---|---|---|
| `bits[y]` | set bits of byte y | the mark bitmap arena | everyone (plain or atomic) |
| `freeList` | the class free list | `free_lists_[cls]` | under `promo_mu_` (workers) or the mutator |
| `sweepQ` | the gap sweep's remaining items, in address order | `sweep_buffer_index_`, `sweep_cursor_` | the sweeper, under the lock |
| `phase` | `gc_phase_` | `gc_phase_` | the sweep's completion (plain write) |
| `liveBytes[b]`, `swept[b]`, `deferred` | `live_bytes`, `fully_swept`, `sweep_complete_deferred_` | `BufferMetadata`, `OldGenSpace` | atomic adds / pause code |
| `shared`, `partialQ` | the shared promotion word; `partial_[cls]` and virgin blocks | `PromoCtx::shared[cls]`, `partial_` | CAS (claims), under the lock (advance) |
| `chunk[w]`, `chunkLive[w]`, `stash[w]` | a worker's chunk, its unflushed `pending_live`, its stash | `PromoWorker::cur`, `pending_live`, `stash` | the worker |
| `lock` | `promo_mu_` | `promo_mu_` | workers |
| `released` | blocks the shrink released | `releaseBlockToAllocator` | the shrink |
| `grantOn`, `grantLive` | grant active; its `pending_live` | `TenureGrant::active`, `TenureCursor::pending_live` | collector / merge |
| `allocs[c]`, `need`, `marked`, `claimed` | ghosts: times c was handed out; allocate-black bits that must survive; the marker's bits; claimed chunk units | — | — |
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
- Every access to a tracked location (a mark byte, or `"phase"`) is recorded in `hist[loc]` with
  its thread, the thread's own clock value, and whether it is plain and whether it writes.
- An access by t **races** with a recorded access a by u ≠ t, if one of them is plain, one of them
  writes, and `a.c > vc[t][u]`. That last condition means t has not heard of that point of u yet.
- A race is **recorded** in `races`, not blocked on, so TLC continues and can report the property
  `NoRaceBitmap` / `NoRacePhase` with a full trace.

Example, timeline (b):
- W2's lock release after its pop gives `lockvc[W2] = c2`, and W2 ticks to `c2 + 1`.
- W1's next acquire learns `vc[W1][W2] = c2`.
- W1 writes `phase` at clock `c1` and releases, so `lockvc[W1] = c1`.
- W2 reads `phase` at clock `c2 + 1` **without** acquiring. So `vc[W2][W1]` is still older than
  `c1`, and W1's recorded write has `a.c = c1 > vc[W2][W1]`: **race**.

With `MUTANT = "phase_atomic"`, both accesses are non-plain, so there is no race.

### 4.5 Steps: model labels to code lines

| Label | Code | Operation |
|---|---|---|
| rung-1 branch, `W_R1Phase`, `W_R1Set` | `cursorAllocateW` `:1146` → `finalizeBitmapCellW` `:1121` | plain byte read (`nextFreeCell`), plain read of `gc_phase_` (`:1135`), plain `setBit` (`:1131`) |
| claim branch | `claimChunkW` `:1171` | `flushCursorW` (atomic add), CAS on `shared` (acq_rel) |
| finalize branch, `W_StBit`, `W_StPlainSet` | `allocatePromotion` `:1581` / `:1634` → `finalizePoppedCellW` `:1069` | plain read of `gc_phase_` (`:1075`) outside the lock, then an atomic `fetch_or` (`:1083`) and `fetch_add`, or nothing when Idle |
| lock branch, `W_Locked` | `allocatePromotion` `:1587-1631` | refill (`advanceSharedW` / `startVirginBlockShared`, release store), or batch pop into the stash |
| `W_SwChk`, `W_SwTest` | `hasPendingSweepWork` (`OldGenSpace.hpp:1485`) | read of `gc_phase_` under the lock |
| `W_Sweep`, `W_SweepClr` | `lazySweep` gap sweep `:5331-5360` | `flushRun` (free list), or `nextSetBit` + `clearBit` (a plain RMW of one byte) |
| `W_SweepEnd` | `:5247-5255` (in-loop), `:5466-5472` (tail) | plain write `gc_phase_ = Idle`; defer, or shrink now |
| `W_PopAfterSweep`, `W_PopBit` | `sweepOnDemandAllocate` `:2136` → `finalizePoppedCell` `:2025` → `initObjectHeaderWithSize` | pop and finalize under the lock |
| `W_Shrink` | `onSweepComplete` `:5488` → pass 1 `:5796-5810` → `releaseBlockToAllocator` `:5995` → `detachFromAllocation` `:694` | release empty blocks; FATAL if a Current block is picked |
| `W_Unlock` | end of the `unique_lock` scope | release (`lockvc`) |
| `K_Loop` | `testAndSetMark<ParallelMark>` `:3039` | relaxed `fetch_or` |
| `G_Join`, `G_Flush`, `G_Shrink` | gang join; `endParallelPromotion` `:1416-1534` | join clocks; flush `pending_live`; stash return; deferred shrink |
| `C_Loop`, `C_Set` | `grantAllocate` `OldGenTenure.cpp:153-195` | plain byte read, plain `setBit` (`:177`) |
| `U_Cursor`, `U_CursorSet` | `cursorAllocate` → `finalizeBitmapCell` `:802` | plain read and plain `setBit` on the mutator's own block |
| `U_Pop`, `U_PopBit` | `tryAllocateFromFreeLists` → `finalizePoppedCell` → `initObjectHeaderWithSize` `:487` | atomic allocate-black when not Idle |
| `U_Sweep` … `U_SweepDone` | the mutator's lazy sweep; `onSweepComplete` light shrink with the tenure skip `:5805` | plain `clearBit`; release |
| `U_Pause`, `U_Join`, `U_T0`, `U_After` | `ThreadLocalHeap::minorGC` `:706-745` (join, merge, t0), `returnTenureGrant`, `resetAllocCursors` FATAL | the ordering premise HEAP_070 |

### 4.6 The PlusCal sketch

File: `test/tla/M4-promotion-bitmap/PromoBitmap.tla`. This is the text that passed `pcal` and
`sany`; the generated translation is omitted.

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
    Scenario,      \* "sweep" | "cycle" | "epoch"
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
CellsOf(b) == {c \in Cells : BlkOf(c) = b}
Mixed   == {"M", "D"}                      \* swept by the gap sweep
Uniform == Blocks \ Mixed                  \* bitmap = allocation map (HEAP_054)
\* Blocks that existed at t0 (only meaningful while a cycle runs).
T0Blocks == IF Scenario = "sweep" \/ (Scenario = "epoch" /\ ~CycleActive)
            THEN {} ELSE {"M", "Z"}
T0Cells  == UNION {CellsOf(b) : b \in T0Blocks}
\* Objects live at t0 that the background marker must mark.
T0Live   == IF T0Blocks = {} THEN {} ELSE {2, 3, 14}
\* Chunk units of a shared promotion block (claimChunkW): whole bytes.
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
Workers    == IF Scenario \in {"sweep", "cycle"} THEN {1, 2} ELSE {}
Markers    == IF T0Blocks # {} THEN {3} ELSE {}
Collectors == IF Scenario = "epoch" THEN {4} ELSE {}
Mutators   == IF Scenario = "epoch" THEN {5} ELSE {}
Mergers    == IF Scenario \in {"sweep", "cycle"} THEN {6} ELSE {}
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
Range(sq) == {sq[i] : i \in 1..Len(sq)}
Locs == Bytes \cup {"phase"}
RECURSIVE SetToSeqAny(_)
SetToSeqAny(S) == IF S = {} THEN <<>>
                  ELSE LET x == CHOOSE y \in S : TRUE IN <<x>> \o SetToSeqAny(S \ {x})
AnyOf(S) == CHOOSE x \in S : TRUE

\* ---- Scenario starting states --------------------------------------------
\* sweep: after a mark, M holds live objects 2, 3, 5 (bits set) and dead
\*        gaps 1, 4; D was all dead but kept (min heap), so it is swept too.
SweepItems == <<[kind |-> "gap", c |-> 1], [kind |-> "live", c |-> 2], [kind |-> "live", c |-> 3],
                [kind |-> "gap", c |-> 4], [kind |-> "live", c |-> 5],
                [kind |-> "gap", c |-> 6], [kind |-> "gap", c |-> 7]>>
InitBits == [y \in Bytes |->
    CASE Scenario = "sweep" /\ y = "M1" -> {2, 3}
      [] Scenario = "sweep" /\ y = "M2" -> {5}
      [] Scenario = "epoch" /\ ~CycleActive /\ y = "M1" -> {2}
      [] OTHER -> {}]
InitQ     == CASE Scenario = "sweep" -> SweepItems
               [] Scenario = "epoch" /\ ~CycleActive -> <<[kind |-> "live", c |-> 2]>>
               [] OTHER -> <<>>
InitFree  == CASE Scenario = "cycle" -> <<1, 4>>
               [] Scenario = "epoch" -> <<1>>
               [] OTHER -> <<>>
InitPhase == CASE Scenario = "sweep" -> "Sweeping"
               [] Scenario = "cycle" -> "Marking"
               [] CycleActive        -> "Marking"
               [] OTHER              -> "Sweeping"
\* sweep: the mutator's cursor already used U's first unit, so the workers
\* get one chunk and must then take free-list cells (forcing the sweep).
InitShared == CASE "cursor_on_t0" \in MUTANT -> [b |-> "Z", u |-> 0]
                [] Scenario = "sweep"      -> [b |-> "U", u |-> 1]
                [] OTHER                   -> [b |-> "U", u |-> 0]
InitPartial == IF Scenario = "sweep" THEN <<>> ELSE <<"V">>
InitLive   == [b \in Blocks |-> CASE Scenario = "sweep" /\ b = "M" -> 3
                                  [] Scenario = "epoch" /\ ~CycleActive /\ b = "M" -> 1
                                  [] OTHER -> 0]
InitSwept  == [b \in Blocks |-> ~(b \in Mixed /\ InitQ # <<>>)]
InitVC     == [t \in Threads |-> [u \in Threads |-> IF t = u THEN 1 ELSE 0]]

(* --algorithm PromoBitmap
variables
    bits      = InitBits,                       \* mark bytes: the set bits of each byte
    freeList  = InitFree,                       \* the class free list (mixed cells)
    sweepQ    = InitQ,                          \* gap sweep: items not yet swept, in address order
    phase     = InitPhase,                      \* gc_phase_ (a PLAIN field)
    liveBytes = InitLive,                       \* BufferMetadata::live_bytes, in cells
    swept     = InitSwept,                      \* BufferMetadata::fully_swept
    deferred  = FALSE,                          \* sweep_complete_deferred_
    shared    = InitShared,                     \* PromoCtx::shared[cls]: (block, next unit)
    partialQ  = InitPartial,                    \* partial_[cls] / virgin blocks for the refill
    lock      = 0,                              \* promo_mu_ (0 = free)
    chunk     = [w \in Threads |-> {}],         \* each worker's current chunk (its cursor)
    chunkLive = [w \in Threads |-> 0],          \* cursor pending_live (flushed at the merge)
    stash     = [w \in Threads |-> {}],         \* PromoWorker::stash (popped, not finalized)
    released  = {},                             \* blocks the shrink released
    grantOn   = (Scenario = "epoch"),           \* the tenure grant is live
    grantLive = 0,                              \* grant pending_live (folded at the merge)
    \* ---- ghosts ----
    allocs    = [c \in Cells |-> 0],            \* times each cell was handed out
    need      = {},                             \* allocate-black bits that must survive (IM4)
    marked    = {},                             \* bits the marker set (must survive)
    claimed   = {},                             \* chunk units claimed: <<block, unit>>
    \* ---- the data-race detector (vector clocks, primer §3.7) ----
    vc        = InitVC,                         \* vc[t][u]: what t knows of u's clock
    lockvc    = [u \in Threads |-> 0],          \* the clock promo_mu_ carries
    sharedvc  = [u \in Threads |-> 0],          \* the clock shared[cls] carries (acq_rel CAS)
    hist      = [l \in Locs |-> {}],            \* accesses to each location
    races     = {};                             \* locations with an unordered conflicting pair

define
    Allocated == {c \in Cells : allocs[c] > 0}
    PhasePlain == "phase_atomic" \notin MUTANT     \* gc_phase_ is a plain field today
    SetBits   == UNION {bits[y] : y \in Bytes}
    ChunkFree(w) == {c \in chunk[w] : c \notin bits[ByteOf(c)]}
    CanClaim  == shared.b # "none" /\ shared.u < Len(Units(shared.b))
    \* ---- properties (§6 of the plan) ----
    NoRaceBitmap == races \cap Bytes = {}
    NoRacePhase  == "phase" \notin races
    NoDoubleAlloc == \A c \in Cells : allocs[c] <= 1
    NoOverwriteLive == \A c \in T0Live : allocs[c] = 0
    ReleasedSafe == \A b \in released :
                        /\ \A c \in Allocated : BlkOf(c) # b
                        /\ \A w \in Threads : \A c \in chunk[w] : BlkOf(c) # b
                        /\ ~(b = GrantBlock /\ grantOn)
    \* Model-level pruning (not code): take the lock only when some rung can progress.
    LockUseful == ((shared.b = "none" \/ ~CanClaim) /\ partialQ # <<>>)
                  \/ freeList # <<>> \/ (phase = "Sweeping" /\ sweepQ # <<>>)
    FreeBehindCursor ==
        \A c \in Range(freeList) \cup UNION {stash[w] : w \in Threads} :
            ~\E i \in 1..Len(sweepQ) : sweepQ[i].c = c
    ClaimsInRange == \A x \in claimed : x[2] <= Len(Units(x[1]))
    IM13 == \A w \in Workers : chunk[w] \cap T0Cells = {}
    TV5  == Scenario = "epoch" =>
                (GrantBlock # "K" /\ (CycleActive => GrantBlock \notin T0Blocks))
end define;

\* One access to location `loc` by self: records a race if an earlier
\* conflicting access by another thread is not ordered before this one.
macro Access(loc, isPlain, isWrite) begin
    if \E a \in hist[loc] : a.t # self /\ (a.p \/ isPlain) /\ (a.w \/ isWrite)
                              /\ a.c > vc[self][a.t] then
        races := races \cup {loc};
    end if;
    hist[loc] := hist[loc] \cup {[t |-> self, c |-> vc[self][self], p |-> isPlain, w |-> isWrite]};
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
            cell := CHOOSE x \in ChunkFree(self) : TRUE;
            seen := bits[ByteOf(cell)];               \* nextFreeCell: plain byte read
            Access(ByteOf(cell), TRUE, FALSE);
          W_R1Phase:                                  \* finalizeBitmapCellW: colour
            ph := phase;                              \* plain read, NO lock (CR-001)
            Access("phase", PhasePlain, FALSE);
          W_R1Set:                                    \* bitscan::setBit: plain write (IM13)
            bits[ByteOf(cell)] := seen \cup {cell};
            Access(ByteOf(cell), TRUE, TRUE);
            allocs[cell] := allocs[cell] + 1;
            chunkLive[self] := chunkLive[self] + 1;   \* c.pending_live
            if ph = "Marking" then need := need \cup {cell}; end if;
            n := n + 1; cell := 0; seen := {}; ph := "Idle";
        or
            \* ---- claim the next chunk of the shared block (claimChunkW) ----
            await ChunkFree(self) = {};
            await CanClaim \/ ("claim_after_exhaustion" \in MUTANT /\ shared.b = "U");
            SharedSync();
            if chunk[self] # {} then                  \* flushCursorW: atomic fetch_add
                liveBytes[BlkOf(AnyOf(chunk[self]))] :=
                    liveBytes[BlkOf(AnyOf(chunk[self]))] + chunkLive[self];
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
            cell := CHOOSE x \in stash[self] : TRUE;
            stash[self] := stash[self] \ {cell};
            ph := phase;                              \* plain read, NO lock (CR-001)
            Access("phase", PhasePlain, FALSE);
          W_StBit:
            if (ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred))
               /\ "plain_allocate_black" \in MUTANT then
                seen := bits[ByteOf(cell)];               \* setMarkBitInBlock: plain read
                Access(ByteOf(cell), TRUE, FALSE);
                goto W_StPlainSet;
            elsif ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred) then
                bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};   \* setMarkBitAtomic
                Access(ByteOf(cell), FALSE, TRUE);
                liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;   \* atomic fetch_add
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
            Access(ByteOf(cell), TRUE, TRUE);
            liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
            if ph = "Marking" then need := need \cup {cell}; end if;
            allocs[cell] := allocs[cell] + 1;
            n := n + 1; cell := 0; seen := {}; ph := "Idle";
        or
            \* ---- rung 1 failed: take promo_mu_ ----
            await ChunkFree(self) = {} /\ ~CanClaim /\ stash[self] = {} /\ LockUseful;
            LockAcquire();
          W_Locked:
            if (shared.b = "none" \/ ~CanClaim) /\ partialQ # <<>> then
                \* advanceSharedW / startVirginBlockShared + publishShared (release)
                shared := [b |-> Head(partialQ), u |-> 0];
                partialQ := Tail(partialQ);
                SharedSync();
                goto W_Unlock;
            elsif freeList # <<>> then
                \* rung 2 batch (N > 1): pop up to 2 cells into the stash
                stash[self] := Range(SubSeq(freeList, 1, Min(2, Len(freeList))));
                freeList := SubSeq(freeList, Min(2, Len(freeList)) + 1, Len(freeList));
                goto W_Unlock;
            end if;
          W_SwChk:                                    \* hasPendingSweepWork(): phase under the lock
            ph := phase;
            Access("phase", PhasePlain, FALSE);
          W_SwTest:
            if ph # "Sweeping" \/ sweepQ = <<>> then
                ph := "Idle";
                goto W_Unlock;                        \* nothing to sweep (the model has no rung 6+)
            end if;
          W_Sweep:                                    \* lazySweep: one gap-sweep item
            if Head(sweepQ).kind = "gap" then
                freeList := Append(freeList, Head(sweepQ).c);   \* flushRun
                sweepQ := Tail(sweepQ);
                goto W_SweepEnd;
            else
                cell := Head(sweepQ).c;               \* nextSetBit + clearBit: plain RMW
                seen := bits[ByteOf(cell)];
                Access(ByteOf(cell), TRUE, FALSE);
            end if;
          W_SweepClr:
            bits[ByteOf(cell)] := seen \ {cell};
            Access(ByteOf(cell), TRUE, TRUE);
            sweepQ := Tail(sweepQ);
            cell := 0; seen := {};
          W_SweepEnd:
            if sweepQ = <<>> then
                \* the last block's boundary: gc_phase_ = Idle (plain write under the lock)
                phase := "Idle";
                Access("phase", PhasePlain, TRUE);
                swept := [b \in Blocks |-> TRUE];
                either
                    deferred := TRUE;                 \* in-loop path: sweepCompleteInPromotion
                or
                    await "tail_defers" \notin MUTANT;     \* tail path (lazySweep end): onSweepComplete NOW
                    goto W_Shrink;
                end either;
            else
                either goto W_Sweep; or skip; end either;   \* this slice's budget may end here
            end if;
          W_PopAfterSweep:                            \* sweepOnDemandAllocate: pop, finalize UNDER the lock
            if freeList # <<>> then
                cell := Head(freeList);
                freeList := Tail(freeList);
                ph := phase;
                Access("phase", PhasePlain, FALSE);
              W_PopBit:                               \* finalizePoppedCell -> initObjectHeaderWithSize
                if ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred) then
                    bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};
                    Access(ByteOf(cell), FALSE, TRUE);
                    liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
                end if;
                allocs[cell] := allocs[cell] + 1;
                n := n + 1; cell := 0; ph := "Idle";
            end if;
          W_PopDone:
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
          W_Unlock:
            LockRelease();
        or
            \* ---- the same stash finalize, moved INSIDE the lock (positive control) ----
            await stash[self] # {} /\ "finalize_in_lock" \in MUTANT;
            LockAcquire();
          W_InLockFin:
            cell := CHOOSE x \in stash[self] : TRUE;
            stash[self] := stash[self] \ {cell};
            ph := phase;
            Access("phase", PhasePlain, FALSE);
          W_InLockBit:
            if ph # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred) then
                bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};
                Access(ByteOf(cell), FALSE, TRUE);
                liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
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
variables todo = T0Live;
begin
  K_Loop:
    while todo # {} do
        with c \in todo do
            bits[ByteOf(c)] := bits[ByteOf(c)] \cup {c};
            Access(ByteOf(c), FALSE, TRUE);
            marked := marked \cup {c};
            todo := todo \ {c};
        end with;
    end while;
end process;

\* =========================================================================
\* The merge after the gang join (endParallelPromotion, OldGenSpace.cpp:1416).
\* =========================================================================
fair process Merge \in Mergers
begin
  G_Join:
    await \A w \in Workers \cup Markers : pc[w] = "Done";
    vc[self] := [u \in Threads |->
                   Max(vc[1][u], Max(vc[2][u], Max(vc[3][u], vc[self][u])))];
  G_Flush:                                        \* flushCursorW + stash return
    liveBytes := [b \in Blocks |-> liveBytes[b]
        + (IF chunk[1] # {} /\ BlkOf(AnyOf(chunk[1])) = b THEN chunkLive[1] ELSE 0)
        + (IF chunk[2] # {} /\ BlkOf(AnyOf(chunk[2])) = b THEN chunkLive[2] ELSE 0)];
    freeList := freeList \o SetToSeqAny(stash[1] \cup stash[2]);
    stash := [w \in Threads |-> {}];
  G_Shrink:                                       \* the deferred onSweepComplete
    if deferred then
        released := released \cup
            {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b # shared.b};
        partialQ := SelectSeq(partialQ, LAMBDA b : b # shared.b /\ (~swept[b] \/ liveBytes[b] # 0));
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
        gseen := bits[ByteOf(gcell)];                  \* the bitmap scan: plain read
        Access(ByteOf(gcell), TRUE, FALSE);
      C_Set:
        bits[ByteOf(gcell)] := gseen \cup {gcell};     \* bitscan::setBit: plain write
        Access(ByteOf(gcell), TRUE, TRUE);
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
        Access(ByteOf(mcell), TRUE, FALSE);
      U_CursorSet:
        bits[ByteOf(mcell)] := mseen \cup {mcell};
        Access(ByteOf(mcell), TRUE, TRUE);
        allocs[mcell] := allocs[mcell] + 1;
        mcell := 0; mseen := {};
    end if;
  U_Pop:                                          \* a free-list pop: initObjectHeaderWithSize
    if freeList # <<>> then
        mcell := Head(freeList);
        freeList := Tail(freeList);
        mph := phase;
      U_PopBit:
        if mph # "Idle" then
            bits[ByteOf(mcell)] := bits[ByteOf(mcell)] \cup {mcell};   \* setMarkBitAtomic
            Access(ByteOf(mcell), FALSE, TRUE);
            liveBytes[BlkOf(mcell)] := liveBytes[BlkOf(mcell)] + 1;
            if mph = "Marking" then need := need \cup {mcell}; end if;
        end if;
        allocs[mcell] := allocs[mcell] + 1;
        mcell := 0; mph := "Idle";
    end if;
  U_Sweep:                                        \* outside a cycle: a lazy-sweep item of M
    if phase = "Sweeping" /\ sweepQ # <<>> then
        mcell := Head(sweepQ).c;
        mseen := bits[ByteOf(mcell)];
        Access(ByteOf(mcell), TRUE, FALSE);
      U_SweepClr:
        bits[ByteOf(mcell)] := mseen \ {mcell};
        Access(ByteOf(mcell), TRUE, TRUE);
        sweepQ := Tail(sweepQ);
        mcell := 0; mseen := {};
      U_SweepDone:                                \* completion: onSweepComplete's light shrink
        phase := "Idle";
        swept := [b \in Blocks |-> TRUE];
        released := released \cup
            {b \in Blocks : swept[b] /\ liveBytes[b] = 0 /\ b # "K"
                            /\ (b # GrantBlock \/ ~grantOn \/ "shrink_ignores_tenure" \in MUTANT)};
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
| `NoRaceBitmap` | invariant | no mark byte has an unordered conflicting pair of accesses with a plain one among them (§4.4) | timeline (c): the sweeper's plain `clearBit` and a stash finalize's `fetch_or` on byte `M1` |
| `NoRacePhase` | invariant | no unordered plain access pair on `gc_phase_` | timeline (b): the completion's plain write and a finalize's plain read |
| `NoDoubleAlloc` | invariant | no cell is handed out twice | two allocators read the same byte, both pick cell 18, both write it back (`grant_includes_cursor`) |
| `NoOverwriteLive` | invariant | no allocator hands out a cell holding a live t0 object | a cursor on t0 block `Z` treats object 14's still-clear bit as "free" (IM13's reason: mid-cycle, a t0 bitmap is being rebuilt, not an allocation map) |
| `ReleasedSafe` | invariant | a released block holds no allocated cell, is nobody's chunk, and is not a live grant | timeline (b) step 4 (suspicion 1); the shrink releasing the grant (`shrink_ignores_tenure`) |
| `FreeBehindCursor` | invariant | no free or stashed cell lies ahead of the sweep cursor (HEAP_055's premise "nothing allocates into an unswept block") | a free cell the sweep would later coalesce over |
| `ClaimsInRange` | invariant | every claimed chunk unit exists in its block | `claim_after_exhaustion` claims unit 3 of a 2-unit block |
| `IM13` | invariant | no worker chunk lies in a t0 block during a cycle | `cursor_on_t0` |
| `TV5` | invariant (constant-level) | the grant is neither the mutator's cursor block nor, mid-cycle, a t0 block | `grant_includes_cursor`, `grant_t0_block` |
| `NoLostRequiredBit` | end-state (under `AllDone`) | every allocate-black bit set during a cycle, and every bit the marker set, is still set | timeline (a) |
| `AllocMapExact` | end-state | in every uniform post-t0 block, bit set ⇔ cell allocated (HEAP_054) | a lost bit in a chunk byte shared by two workers (`chunk_unit_subbyte`) |
| `assert shared.b \notin rel` in `W_Shrink` | assertion | the shrink never picks the Current shared block during a parallel minor (the `detachFromAllocation` FATAL) | suspicion 2: the tail completion path shrinks on a worker |
| `assert ~grantOn` in `U_T0` | assertion | no grant is live when a mark cycle starts (`resetAllocCursors`' FATAL; HEAP_070) | `launch_before_t0` |

**Expected failures of the faithful model.** Like M2's `episode_stop` (CR-005), the configurations
marked "expected: FAIL" in §6 reproduce known or suspected defects. They stay in `models.txt` as
expected failures and flip to "pass" in the same change that fixes the code. The fix-candidate
controls of §5 show beforehand that the proposed fix removes the violation.

## 5. Negative and positive controls

`MUTANT` is a **set**, so fix candidates can be combined. `{}` is the code as it is.

| Element | Code change it represents | Configuration | Must |
|---|---|---|---|
| `plain_allocate_black` | `test_plain_allocate_black_` (`initObjectHeaderWithSize` `:515`): plain `setMarkBitInBlock` for mid-cycle allocate-black | `cycle` | violate `NoLostRequiredBit` (and `NoRaceBitmap`) |
| `cursor_on_t0` | `test_cursor_takes_t0_block_` (`runCycleStepConcurrent`): a cursor refills from a t0 uniform block | `cycle` | violate `IM13`, and `NoOverwriteLive` or `NoLostRequiredBit` |
| `chunk_unit_subbyte` | chunk units that do not cover whole bitmap bytes (drop the 64-cell unit rule, `OldGenSpace.hpp:646`) | `cycle` | violate `NoRaceBitmap` and `AllocMapExact` |
| `claim_after_exhaustion` | `claimChunkW` without its `lo >= ncell` test (`:1181`) | `cycle` | violate `ClaimsInRange` and `NoDoubleAlloc` |
| `grant_t0_block` | `test_grant_t0_block_` (`OldGenTenure.cpp:114`) | `epoch_cycle` | violate `TV5` and `NoOverwriteLive` |
| `grant_includes_cursor` | `grantTenure` without its skip of the mutator's cursor block (`OldGenTenure.cpp:100`; the hazard 7b found) | `epoch_cycle` | violate `TV5` and `NoDoubleAlloc` |
| `shrink_ignores_tenure` | `test_shrink_ignores_tenure_` (`OldGenSpace.cpp:5805`) | `epoch_idle` | violate `ReleasedSafe` |
| `launch_before_t0` | the tenure launch placed before a same-pause cycle start (`TenureLaunchScope`, `ThreadLocalHeap.cpp:738-743`) | `epoch_cycle` | fail the `U_T0` assertion |
| `finalize_in_lock` (**fix candidate**) | finalize stashed cells under `promo_mu_` | `sweep_race_bitmap` | make `NoRaceBitmap` **pass** (removes CR-002). `NoRacePhase` still fails: rung 1 reads `gc_phase_` too |
| `phase_atomic` (**fix candidate**) | make `gc_phase_` a relaxed atomic | `sweep_race_phase` | make `NoRacePhase` **pass** (removes CR-001's race). The decision-point problem stays: see the next two rows |
| `tail_defers` (**fix candidate**) | the tail completion path calls `sweepCompleteInPromotion` like the in-loop one | `sweep_tail` | make the `W_Shrink` assertion unreachable (suspicion 2) |
| `count_until_shrink` (**fix candidate**) | a finalize attributes `live_bytes` while the shrink is still deferred, not only while `gc_phase_ != Idle` | `sweep_release` + `tail_defers` | make `ReleasedSafe` **pass** (suspicion 1) |

## 6. Configurations

Every configuration uses `NAllocs = 2`. `CycleActive` matters only for `epoch`, but is set in
every file because it is a constant.

| Config | `Scenario` / `CycleActive` / `MUTANT` | Checks | Tier | Expected |
|---|---|---|---|---|
| `sweep_race_bitmap` | sweep / — / `{"tail_defers"}` | `NoRaceBitmap` | quick | **FAIL: CR-002** |
| `sweep_race_phase` | sweep / — / `{"tail_defers"}` | `NoRacePhase` | quick | **FAIL: CR-001 (race)** |
| `sweep_tail` | sweep / — / `{}` | the `W_Shrink` assertion | quick | **FAIL: suspicion 2** |
| `sweep_release` | sweep / — / `{"tail_defers"}` | `ReleasedSafe` | quick | **FAIL: suspicion 1** (CR-001's S1 half) |
| `sweep_fixed` | sweep / — / `{"tail_defers", "count_until_shrink", "finalize_in_lock", "phase_atomic"}` | all invariants | quick | pass: the combined fix candidates |
| `sweep_functional` | sweep / — / `{"tail_defers", "count_until_shrink"}` | `NoDoubleAlloc`, `FreeBehindCursor`, `ClaimsInRange`, `AllocMapExact` | quick | pass |
| `cycle` | cycle / — / `{}` | `NoRaceBitmap`, `NoRacePhase`, `NoDoubleAlloc`, `NoOverwriteLive`, `FreeBehindCursor`, `ClaimsInRange`, `IM13`, `NoLostRequiredBit`, `AllocMapExact` | quick | pass |
| `epoch_cycle` | epoch / TRUE / `{}` | `NoRaceBitmap`, `NoDoubleAlloc`, `NoOverwriteLive`, `ReleasedSafe`, `TV5`, `NoLostRequiredBit`, `AllocMapExact` | quick | pass |
| `epoch_idle` | epoch / FALSE / `{}` | `ReleasedSafe`, `NoRaceBitmap`, `NoDoubleAlloc`, `AllocMapExact` | quick | pass |
| `epoch_l3` (to add) | epoch with two collector members claiming grant chunks (`grantAllocateShared`) | as `epoch_cycle` | deep | pass |
| one configuration per §5 control | as the table says | the named property | quick | as the table says |

Every `.cfg` needs `INIT Init` and `NEXT Next`; M4 has no procedures, so no `defaultInitValue`.
`MC.tla` only `EXTENDS PromoBitmap` until step 5 of §9 moves the heap into constants.

## 7. Accuracy notes (parent plan rules A1–A9)

| Rule | M4 |
|---|---|
| A1 | Every byte update is one step if atomic, two if plain (read into `seen`, write back). Every `gc_phase_` read is its own step. The stash finalize is split from its pop by at least one lock release, as in the code. A lock hold does one ladder action, and a sweep slice ends after any item. |
| A2 | **Bytes, not bits:** `bits[y]` is a byte. Chunks are whole bytes. Different blocks never share a byte. |
| A3 | Footprint rows: 05c H1, H1b, H2, H9; 06 P§3.11 (`PromoCtx`, `partial_`, the free lists, `promo_mu_`, `gc_phase_`, `live_bytes`); 07 P§3.17 T5 (granted blocks) and T6 (mutator-owned metadata the collector never touches). `gc_phase_` is **missing** from 06 P§3.11; add it with CR-001's fix. |
| A4 | W3 (every mark-byte access pattern at C11 level: relaxed `fetch_or` against relaxed `fetch_or`; plain `setBit` on a post-t0 byte against nothing; CR-002's plain `clearBit` against `fetch_or`). The SC model with vector clocks finds data races by the C++ definition, but not weak-memory reorderings; W3 covers those. |
| A5 | §8: a new gc-heap-tsan scenario. |
| A6 | §5: eight negative controls, four of them existing hooks (`test_plain_allocate_black_`, `test_cursor_takes_t0_block_`, `test_grant_t0_block_`, `test_shrink_ignores_tenure_`), plus four fix-candidate positive controls. |
| A7 | `NoLostRequiredBit` = IM4 + the 05c H1 argument; `IM13` = IM13; `TV5` = 07 TV5; `AllocMapExact` = HEAP_054; `FreeBehindCursor` = HEAP_055's premise; `ReleasedSafe` = HEAP_051/HEAP_070 (live bytes, grant skip); the `W_Shrink` assertion = the `detachFromAllocation` FATAL (HEAP_054); `U_T0` = HEAP_070's `resetAllocCursors` FATAL. `NoRace*` = `MODEL_M4_RACE`. |
| A8 | 2 workers + merge, or marker + collector + mutator; 7 blocks, 19 cells, 9 bytes; `NAllocs = 2`. No counter wraps. The vector clocks grow only with lock releases, so they are bounded because every process terminates. |
| A9 | `region` markers on: `initObjectHeaderWithSize`'s allocate-black branch; `finalizeBitmapCell`; `finalizePoppedCellW`; `finalizeBitmapCellW`; `cursorAllocateW`; `claimChunkW`; `publishShared`/`advanceSharedW`/`startVirginBlockShared`; `allocatePromotion`; `sweepCompleteInPromotion`; `endParallelPromotion`; `lazySweep` (the gap-sweep loop and **both** completion paths); `maybeShrinkCapacity` pass 1; `allocateFromEmptyRegularBlocks`' skip list; `grantTenure`, `grantAllocate`, `grantAllocateShared`, `returnTenureGrant`. `census`: `OldGenSpace.cpp`, `OldGenTenure.cpp`, `OldGenSpace.hpp`. `grep` rows: `gc_phase_ =`, `setMarkBitInBlock\|bitscan::setBit\|bitscan::clearBit`, `alloc_state == kAllocTenure`, `par_promo_active_`. |

## 8. Trace validation

**Harness.** No existing harness forces a sweep inside a parallel minor: `gc-heap-tsan` runs
`gc_thread_mode = 0` and small geometries, and never checks for it. Add a scenario to
`test/gc-heap-tsan/heap_driver.cpp`:
- a small old gen with many small mixed blocks, some of them all dead;
- a major, so a lazy sweep is pending;
- a parallel minor large enough that workers exhaust the shared block and reach sweep-on-demand;
- repeat with `ECO_GC_HELPER_JITTER_US` jitter.

This scenario is also the TSan reproduction for CR-001 and CR-002, and the natural test for the
two suspicions. A variant with a tenure job (region mode, mode 2) and a running cycle feeds the
`epoch` scenarios.

**Hooks** (`ECO_TLA_TRACE`, compiled out otherwise):

| Event | Where | Fields |
|---|---|---|
| `lock` / `unlock` | around `promo_mu_` holds in `allocatePromotion` | `t` |
| `bitRead` / `bitWrite` / `bitAtomic` | the plain byte read before a plain set/clear; the plain write; each `fetch_or` | `t`, block id, byte index, mask |
| `phaseRead` / `phaseWrite` | each `gc_phase_` access listed in §3 | `t`, value, `locked` |
| `sweepItem` | the gap-sweep loop | block id, offset, `gap`/`live` |
| `sweepDone` | both completion paths | `path` (`loop`/`tail`), `deferred` |
| `claimChunk` | `claimChunkW` CAS | word before / after |
| `stashPop` / `finalize` | `allocatePromotion` batch pop; `finalizePoppedCellW` | cell, phase seen |
| `release` | `releaseBlockToAllocator` | block id |
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
   `sweep_fixed`. All must pass. If one exceeds about two minutes, drop `NAllocs` to 1 for the
   worker that does not sweep before touching anything else.
3. Run the four "expected: FAIL" configurations. For each trace:
   - check it against the code (primer §4.3: the model over-approximates the shrink's sizing and
     the ladder's hold granularity);
   - record it in the register: CR-001 and CR-002 go to Reproduced (model); suspicions 1 and 2
     get register entries of their own by the register's process;
   - keep the configuration as an expected failure in `models.txt`.
4. Run every §5 control; each must behave as its row says. The four fix candidates are the
   evidence for the fixes' designs.
5. Parameterise the heap (constants in `MC.tla`) without changing behaviour. Re-run step 2 and
   confirm the same state counts.
6. Add `epoch_l3`: two collector members, grant chunks claimed by CAS (`grantAllocateShared`,
   units ≥ 1,024 bits in the code; whole bytes in the model).
7. The gc-heap-tsan scenario (§8) and trace validation. The scenario doubles as the TSan
   reproduction for CR-001 and CR-002.
8. Wire into `models.txt` and `test/tla/manifest.txt` (A9). Close-out: AUDIT.md entry, register
   updates, the parent plan's §11 row.

## 10. Open questions for the implementer

1. **Suspicion 1 needs a mixed block with `live_bytes == 0` that is still swept.** Does the
   heavy pass (`reclaimAllDeadBlocksFromMeta`, `OldGenSpace.cpp:6175`, called from the handoff tail at `:3977`, and
   `maybeShrinkCapacity` at the handoff) always release all-dead mixed blocks, or can the
   `min_heap` / `canRelease` rules keep one? If it can never happen, suspicion 1 reduces to CR-001's
   S2, and `D` should be justified or removed in MAPPING.md. Also check whether the light shrink's
   `desired_heap` would really release it: the model releases every candidate.
2. **Is the tail completion path reachable inside a ladder rung?** It needs the slice budget to run
   out exactly at the last block's boundary, with the target class's free list still empty
   (otherwise the early return at `:5454-5460` fires first). The gc-heap-tsan scenario should count
   `sweepDone{path=tail}` inside parallel minors.
3. **A third, unmodelled path.** `allocateFromEmptyRegularBlocks` (`:2665`) runs under
   `promo_mu_` for promotions of at least `alloc_buffer_size` (small test geometries only, never
   at the 512 KiB default). It skips only `kAllocCurrent` and `kAllocTenure` blocks, and it
   checks `live_bytes == 0`. A mixed block whose free cells all sit in some worker's stash
   (popped, not yet finalized) passes that test. The block is flipped to large while the stashed
   cells are finalized into it, and `endParallelPromotion` later pushes unused stashed cells
   (`:1440-1443`) back into what is now a large block. Add a `sweep_large` configuration if test
   geometries matter (the gc-heap-tsan driver uses small ones).
4. Should `gc_phase_` get a row in the 06 P§3.11 shared-state table even after CR-001 is fixed?
   Yes if any unlocked reader remains; the model's `NoRacePhase` is the check.
