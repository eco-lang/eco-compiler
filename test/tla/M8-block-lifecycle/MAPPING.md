# M8 — the old generation's block lifecycle: model ↔ code

The model is `BlockLifecycle.tla` (PlusCal plus its committed translation). `MC.tla` holds the
class tables, the scenario filter `Keep` and a compact trace view (`ALIAS MC_Alias`, used by the
non-pass rows). `CovMC.tla` with `coverage.cfg` reports, by hand, which code paths a
configuration exercises (§7, A8). There is no model plan: the task statement of 2026-09-29 (the
orchestrator's M8 brief) is the plan, and AUDIT.md records every decision. **This file cites
code, never plan text.**

Line numbers are for the tree of 2026-09-29 (after the M1–M7 trace hooks). Functions are named
too, because lines drift. Abbreviations: `OGS` = `runtime/src/allocator/OldGenSpace.cpp`,
`OGH` = `OldGenSpace.hpp`, `BT` = `BlockTable.hpp`, `AL` = `Allocator.cpp`,
`NS` = `NurserySpace.cpp`, `NSH` = `NurserySpace.hpp`, `TLH` = `ThreadLocalHeap.cpp`.

**Scope.** One mutator; the serial minor (`NurserySpace::minorGC`, `gc_minor_threads = 1`, legacy
nursery); stop-the-world majors (no incremental cycle: `incremental_mark` off, so `marking_active`
is true only inside the atomic major); bitmap allocation (`old_gen_bitmap_alloc = true`, the
default). Out of scope, with the model that covers them: parallel promotion, stashes, chunks
and the tail-path release inside a parallel minor (M4: CR-014, CR-016); the incremental cycle
and IM5 (M1: CR-036); region mode, tenure grants and the hand-over (M5: CR-017, CR-034,
CR-037); page work (M7); compaction (test-only: `scheduleCompaction` has no production caller);
the legacy (flag-off) ladder and header sweep (read, not modelled: AUDIT.md, CR-033).

**Scale.** Sizes are in 8-byte granules. A page (`alloc_buffer_size`) is `G = 6` granules; a
header is 1 granule; `MIN_FREE_CELL_SIZE` (16 B, `OGH:196`) is 2. Class tables (`MC.tla`):
`MC_Cells6 = <<2, 3, 4>>` (two uniform classes of 16 B and 24 B, one mixed-only class standing
for 16K–64K) and `MC_Cells6b = <<2, 4, 5>>` (a medium-like uniform class, where a 3-granule
request takes a 4-granule cell, as a 520-byte request takes a 1K cell). Routing then matches
`allocate` (`OGS:1971`): a request of `G` goes to `allocateLargeBlock`, a size-classed one to the
bitmap ladder, the rest (the `(LOT, alloc_buffer_size)` band, here 4–5 granules) to
`allocateFromBagPage`.

## 1. Variables

One variable, `h`, a record (the heap). Its fields:

| Field | Meaning | Code counterpart |
|---|---|---|
| `blk[id]` = `[live, s, cls, lg, eoo, st, lb, fs, marks, lmark]` | a `BlockId`'s record: live, page slot (start), size class (`NCLS` = mixed or large), `is_large`, `end_of_objects`, `alloc_state` (`none`/`queued`/`current`), `live_bytes`, `fully_swept`, set mark bits (granule offsets: object starts in mixed blocks, cell starts in uniform ones), the large-mark byte | `BlockInfo` (`BT:41`), `BufferMetadata` (`BT:70`), `MarkBitArena` slot (`BT:246`), `BlockTable::largeMark`; a released id keeps only its last slot (for the CR-036 ghost) |
| `order` | the iteration order (positions) | `BlockTable::order_`; `add` appends (`BT:158`), `swapRemove` (`BT:190`) |
| `freeIds`, `hw` | released ids (a stack), the high-water id | `BlockTable::free_` (LIFO), `high_water_` |
| `owner[s]` | the page-index owner of slot `s` (0: none) | `page_index_[p].primary` (`OGH` `PageOwners`); `assignPageIndexForBlock` `OGS:619`, `clearPageIndexForBlock` `OGS:671`. Every modelled block is one page, so the secondary owner never exists |
| `mem[s][g]` | the header word at granule `g` of slot `s`: an object's (`o`), a `Tag_Free` of `n` granules (`f`), or nothing written for the current block (`j`) | the heap bytes; payload granules are never read by a correct walk and are not modelled |
| `bag` | `unassigned_blocks_` (push and pop at the back) | `OGH:509`; the initial region `OGS:325-383` |
| `ext`, `bump` | `Allocator::old_gen_free_blocks_`, the bump pointer (slots above it are uncommitted) | `AL:759` (first fit, swap-remove, never the heap-base extent for a page request, `:785`), `AL:900` (push back) |
| `fl[c]` | `free_lists_[c]`, as a set of cell addresses | `OGH:1149`; pushes `OGS:5212`, pops `OGS:2150`, splits `OGS:2409` |
| `flarge` | `free_large_blocks_` | `OGH:1165`; `markBlockAsFreeLarge` `OGS:2800` |
| `part[c]` | `partial_[c]` from `partial_head_[c]` | `OGH:583` |
| `cur[c]` = `[id, nx, pend]` | `cursor_[c]`: block, `next_cell`, `pending_live` | `OGH` `AllocCursor`; `flushCursor` `OGS:785` |
| `phase`, `swIdx`, `swCur` | `gc_phase_` (`Idle`/`Sweeping`), `sweep_buffer_index_` (1-based here), `sweep_cursor_` (an offset; −1 = null) | `lazySweep` `OGS:5546` |
| `index[a]` | `large_body_index_` (0: no entry) | `OGH:1251` |
| `meta[m]` = `[base, cs, lg, color, kind, o]` | `large_bodies_[m]`: `body_base`, `cell_size`, `is_large`, `color`, `kind`; `o` is a ghost (the object it was registered for) | `OGH:1190` `LargeBodyMeta` |
| `owned`, `freeMeta`, `mhw` | `nursery_owned_bodies_`, `free_large_body_ids_`, `large_bodies_.size()` | `OGH:1252-1253` |
| `color` | `NurserySpace::minor_color_` | flipped at `NS:503` |
| `objs[o]` = `[st, s, off, sz, root, ylos, pin, age]` | an object: never allocated / allocated / freed, its address, size, whether the mutator holds it, whether it is a young large object, its header's pin bit and age | the heap objects. Liveness is `root`: there is no object graph, so the mark is exact (a rooted object is marked) |
| `minor`, `toReach`, `ops` | inside a minor; the rooted young large objects the minor has still to evacuate; the operation count | — |
| ghosts `lie`, `bad`, `bagsc`, `reissue`, `ev` | a flip or release trusted a false `live_bytes`; the gap sweep read a non-object header at a set bit; a size-classed request was carved by `allocateFromBagPage`; an id came back at the slot it was released from; the paths taken (`Cov` only) | — |

## 2. Steps: operation ↔ code ↔ invariants (A1)

The code is serial: an allocation, a pause and a mutator step never interleave with anything,
so a model step is one whole operation (A1 recorded here: nothing observes the intermediate
states of one call). Inside a step each C++ function is an operator from a heap to the set of
heaps it can end in; free choices stand for the thresholds the model cannot see (§3).

| Step (PlusCal branch of `Top`) | Code | Can break |
|---|---|---|
| mutator allocation, `AllocOp(h, sz, FALSE, TRUE)` | `ThreadLocalHeap::allocateLargePinned` `TLH:481` → `OldGenSpace::allocate` `OGS:1971` | all |
| young large object, `AllocOp(h, sz, TRUE, TRUE)` + `Register` | `TLH:463` → `allocateYoungLarge` `OGS:7445` → `allocateTrackedCell` `OGS:7379` → `allocate`; `registerLargeBody` `OGS:7526` (`index[body] = id` `:7537`) | all, `IndexFaithful` |
| drop | the mutator stops holding a reference | — |
| STW major, `Major` | `TLH:790` → `startMark` → `prepareMark` `OGS:2983` (drain `:2991-2996`, `clearForMark`, `resetAllocCursors` `:720`, `resetBufferMetaForMark` `:4018`) → the mark → `runPostMarkTail` `OGS:4191`: `finalizeMetaAfterMark` `:4040`, `demoteMostlyDeadUniformBlocks` `:4128`, `transitionToSweeping` `:5451`, `reclaimAllDeadBlocksFromMeta` `:6541`, `adjustCapacityAfterMajorGC` `:5993`, `classifyBlocksAfterMark` `:1815` (`retireDeadLargeBodies` `:1793`), the initial `lazySweep` `:4240` | all |
| minor start, `MinorStart` | `NurserySpace::minorGC`: `minor_color_ = !minor_color_` `NS:503` | — |
| promotion, `AllocOp(h, sz, FALSE, FALSE)` | `NurserySpace::promoteAllocate` `NSH:480` → `allocate` (the serial copiers; no allocate-black: no cycle) | all |
| reach, `Reach` | `NurserySpace::reachYoungLarge` `NS:1783` → `youngLargeMeta` `OGH:1217` (a kind-1 entry whose `body_base` is the address) → recolour, `promoteYoungLarge` `OGS:7476` at `promotion_age`, else age | `IndexFaithful`, `NoLostObject` |
| minor end, `MinorEnd` | `sweepNurseryLargeBodies` `OGS:7581` (called `NS:1219`) → `freeLargeBodyCell` `OGS:7686` (`erase(m.body_base)` `:7695` first) | `NoLostObject`, `IndexFaithful`, `FreeListsInLiveBlocks` |

**Operators, in call order (each is one C++ function or the named part of one):**

| Operator | Code |
|---|---|
| `Allocate` | `allocate` `OGS:1971`: the upfront slice while Sweeping `:2028-2057` (target `sizeClass(size)`; may do nothing: `minor_sweep_divisor`), then the dispatch `:2076-2091` |
| `Ladder`, `Rung2`…`Rung8` | `allocateFromSizeClassBitmap` `OGS:973`: cursor `:975`, exact pop `:977`, bag-first virgin `:984`, split `:988`, sweep-on-demand `:996`, virgin `:1005`, bag rung `:1009`, panic `:1011` |
| `CursorAlloc`, `Refill`, `SetCursor`, `FinalizeBitmapCell` | `cursorAllocate` `OGS:888`, `refillCursor` `:828`, `setCursor` `:803`, `finalizeBitmapCell` `:851` (bit always set, `pending_live`) |
| `VirginThenCursor`, `EnsureBag` | `materializeVirginBlock` `OGS:936` + `startVirginBlock` `:959`; `ensureBagPageAvailable` `:917` |
| `PopFinalize`, `Gate`, `Pad` | `tryPopFromFreeList` `OGS:2150` + `finalizePoppedCell` `:2173`; `initObjectHeaderWithSize` `OGS:512` (the phase gate `:522` decides colour and bit only; the `live_bytes` add runs in every phase: CR-018 fixed 2026-09-30, HEAP_073; mutant `idle_uncounted` = the pre-fix Idle gate); `padCellSlack` `:2127` |
| `Split`, `SplitCands` | `tryAllocateBySplittingLarger` `OGS:2409` (classes from `max(target, num_size_classes_)`, remainder 0 or ≥ `MIN_FREE_CELL_SIZE`) |
| `TryFL`, `SweepOnDemand`/`SODIter`, `Panic`/`PanicIter` | `tryAllocateFromFreeLists` `OGS:2194`, `sweepOnDemandAllocate` `:2294`, `panicSweepAndRetryAllocation` `:2326` |
| `BagPage`, `BagSweep`, `FreshPage` | `allocateFromBagPage` `OGS:2528`: step 1 split `:2581`, step 2 slices `:2592-2608`, step 3 fresh page `:2617-2692` (the remainder test `:2678`: any nonzero remainder goes through `pushSpanOnFreeLists`, CR-033 fixed 2026-09-30; mutant `bag_tail_headerless` = the pre-fix `>= MIN_FREE_CELL_SIZE` test) |
| `LargeBlock`, `FromFreeLarge`, `Flip`, `FreshLarge` | `allocateLargeBlock` `OGS:2918`; `allocateFromFreeLargeBlocks` `:2813`; `allocateFromEmptyRegularBlocks` `:2855` (the test `:2862`, `detachFromAllocation`, `removeFreeCellsForBlock` `:2876`, `retireIndexRange` over the block (CR-035 fixed 2026-09-30: retire semantics, the id is not recycled; mutant `flip_keeps_index` = the pre-fix flip), the flip `:2893-2911`); the fresh block `:2929-2975` |
| `Push`, `Pack`, `Slice`, `PlaceCell` | `pushSpanOnFreeLists` `OGS:5212` (uniform branch `:5337`, packer `:5358`, the sub-`MIN_FREE_CELL_SIZE` tail header `:5370`) |
| `SweepLoop`, `Inner`, `GapStep`, `FlushRun`, `EarlyOr`, `Finish`, `Complete` | `lazySweep` `OGS:5546`: loop head `:5570`, in-loop completion `:5572`, the `fully_swept` skip `:5598`, the gap sweep `:5662-5707` (inner head `:5667`), block boundary `:5762`, early exit `:5796`, the flush and tail completion `:5807-5827`; `onSweepComplete` `:5841` |
| `Drain` | `prepareMark`'s drain `OGS:2991-2996` (a budget of `SIZE_MAX / 2`: no stop by budget) |
| `Release`, `PurgeIndex`, `RemoveFreeCells`, `Detach` | `releaseBlockToAllocator` `OGS:6357` (detach, `removeFreeCellsForBlock` `:6259`, the `free_large_blocks_` purge, the index purge `:6424-6440`, `clearPageIndexForBlock` `:6461`, `releaseOldGenBlock` `:6464`, `swapRemove` `:6481`, the cursor fixup); `detachFromAllocation` `OGS:741` |
| `Reclaim` | `reclaimAllDeadBlocksFromMeta` `OGS:6541` (the `min_heap` floor; a batch with no class-1 pre-clean: the lists were wiped by `transitionToSweeping`) |
| `Shrink`, `ShrinkPass`, `ShrinkPick`, `BagPass` | `maybeShrinkCapacity` `OGS:6059`: sync `:6061`, pass 1 `:6156`, pass 2 `:6172`, class-1 pre-clean and batch release, pass 3 `:6242` (`releaseUnassignedBlockToAllocator` `OGS:6500` refuses the heap-base extent) |
| `AdjustCap`, `Grow` | `adjustCapacityAfterMajorGC` `OGS:5993`: heavy shrink or `Allocator::ensureOldGenCapacityFor` `AL:951` |
| `ResetForMark`, `MarkFrom`, `Clamp`, `Demote`, `ToSweeping`, `Classify`, `RetireDead` | `OGS:2983-3062`; the mark (`markOneObject`'s walk step); `finalizeMetaAfterMark` `:4040`; `demoteMostlyDeadUniformBlocks` `:4128` (never the heap-base block `:4148`); `transitionToSweeping` `:5451`; `classifyBlocksAfterMark` `:1815`; `retireDeadLargeBodies` `:1793` |
| `FreeLBC`, `FreeUniformCell`, `SweepWillReach` | `freeLargeBodyCell` `OGS:7686` (large branch; uniform → `freeUniformCell` `:1014`; unswept mixed `:7763` → bit only; else `pushSpanOnFreeLists`); `sweepWillReach` `:1783` |
| `SweepBodies`, `PromoteYL`, `Reach` | `sweepNurseryLargeBodies` `OGS:7581`; `promoteYoungLarge` `:7476`; `reachYoungLarge` `NS:1783` |
| **LOS (`LOS = TRUE`, the code since 2026-10-09, plans/large-object-space.md, HEAP_080):** `LosAlloc`, `LosPlace` | `allocateLargePinned` / `allocateYoungLarge` → `OldGenSpace::allocateOldLarge` / `allocateYoungLarge` → `allocateTrackedCell` → `allocateLos` → `LargeObjectSpace::tryAllocate`, else `addLosBlock` (`ensureBagPageAvailable` + `materializeBlock`, `BlockInfo::los`) and retry; `initObjectHeaderWithSize` (= `Gate`) | all, `LosTracked`, `LosSeparation` |
| `RegisterOld`; `Register` (kind 1) | `allocateOldLarge`'s `registerLargeBody(…, kind 2, owned = false)`; `allocateYoungLarge`'s kind-1 registration | `IndexFaithful`, `LosTracked` |
| `FreeLosCell` (`FreeLBC`'s LOS arm) | `freeLargeBodyCell`'s LOS arm → `freeLosCell` (`LargeObjectSpace::free`, mark bit, `live_bytes`) | `NoLostObject`, `NoDoubleAlloc` |
| `PromoteYL` (LOS) | `promoteYoungLarge` re-kinds the entry to 2 (no erase); `sweepNurseryLargeBodies` drops a kind-2 id without freeing | `LosTracked` (mutant `promote_untracks`) |
| `LosSweep` (in `PostDrain` after the mark) | `losSweepAtMarkEnd` inside `finalizeMetaAfterMark`: unmarked tracked LOS entries freed and retired (kind-2 ids recycled), LOS `live_bytes` = used granules | `NoLostObject`, `LosTracked` |
| `LosReleaseEmpty` (after `Reclaim`) | `losReleaseEmptyBlocks` after `reclaimAllDeadBlocksFromMeta`: empty LOS blocks beyond `los_empty_keep`, above the floor, through `releaseBlockToAllocator` | `NoLostObject`, `SideTablesFaithful` |
| the LOS exclusions | `FlipOK`, `ReclaimPick`, `ShrinkPick` skip `los`; `ResetForMark` keeps an LOS block `fully_swept` (`resetBufferMetaForMark`, `prepareMetaForLazySweep`), so the sweep never walks it | `FlipTrustsTruth`, `BlockParseable` |

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| a 512 KiB page, 8-byte granules, 40 classes | 6 granules, 3 classes (`MC_Cells6`, `MC_Cells6b`) | the paths depend on the class *kinds* (uniform vs mixed-only), on whether a request fills its cell, on a remainder being 0, under 16 B, or larger, and on a request being a whole page; both tables cover every such case |
| a sweep budget in bytes (`sweep_work_budget`, the per-allocation cap, the panic slice, the initial slice; `/minor_sweep_divisor`) | a slice may stop at any budget test (loop heads `:5570`, `:5667`) once it has done work; the upfront slice may do none | every budget is configurable, so every prefix of work is some real slice; the drain's `SIZE_MAX / 2` never stops. Stopping mid-block may be followed by the early-exit test in the model; the code reaches the same end state (flush, return) |
| `maybeShrinkCapacity`'s hysteresis gates and `desired_heap` (from live bytes and `major_gc_target_utilization`) | any desired size from the floor up | a superset of the code's choices; `desired >= current` releases nothing (the gate returning) |
| `adjustCapacityAfterMajorGC`'s occupancy tests | heavy shrink, a one-page grow, or neither | a superset (grow by more than one page adds only bag pages) |
| the free lists (LIFO, first fit by class) | sets: a pop or split may take any fitting cell | a superset; a counterexample is checked against LIFO order (AUDIT.md) |
| `shouldPreferBagForSmallClass` | the constant `BagFirst` (TRUE: the 1 GiB default budget) | at the reservation cap the virgin block fails anyway and the ladder falls through to rung 4, as with the rung skipped |
| triggers (occupancy, pressure, garbage fraction, live budget, allocation failure) | a major at any operation boundary outside a minor | a superset; the incremental cycle is M1's |
| an object graph, stacks, remembered roots | `root`: the mutator holds the object or not; the mark = the rooted objects | the lifecycle never reads pointers; an unreachable object can never be held again, so "loading" a reference is not a step |
| the nursery | promotions are `allocate()` calls inside a minor; young large objects are the only young old-gen cells | `promoteAllocate` `NSH:480` calls `allocate`; bodies (kind 0, split-header strings) share the index, colours and `freeLargeBodyCell` with young large objects and are represented by them |
| the YLOS bounding box (`ylo_lo_`, `ylo_hi_`) | not modelled: every reach looks the address up | the box is recomputed from `nursery_owned_bodies_`' kind-1 entries, so it covers every registered object; it only filters out addresses that have no entry |
| a large object of several pages, OS-page rounding | page-sized large objects only | only a page-sized request can flip a regular block (`:2870` `totalBytes() < size`); larger ones never interact with regular blocks |
| the page index's secondary owner | one owner per slot | every modelled block is one page, so a slot has one owner |
| the Tier-M per-block thread | `RemoveFreeCells` drops every class ≥ 1 cell of the block | every Tier-M push with a block context threads the cell (`placeAndLink`); the model's pushes always have one |
| a page's old bytes after a re-materialization | `mem[s]` reset to "never written" (`j`) | the code may not rely on old contents (V4 poisons reused extents in validate builds); a stale header is garbage to the new block |
| heap-base page (`heap_base`) | slot 1: never reused for a page request, never released from the bag, never demoted | `AL:785`, `OGS:6507-6512`, `OGS:4148` |
| `allocated_bytes`, `frag_stats_`, garbage bytes, the small-class budget, statistics | absent | read only by triggers and sizing, which are free choices here |
| the LOS free-space manager (`LargeObjectSpace`: 1 KiB granules, a bitmap per block, bins by largest free run, best fit, page alignment) | a model granule is an LOS granule; a run is free iff no allocated object covers it; any free run may be chosen | a superset of best fit; the bitmap/bins/largest-run bookkeeping is checked against such a shadow by `LargeObjectSpaceTest` (random churn) and `validate()` |
| raw (header-less body) vs object LOS pools | one pool: the model's LOS objects are pinned and young large objects (all headered) | a body has no children and no header; its pool only decides `greyObject`'s no-push arm (M1) and the free path, which this model represents by the object pool |
| `LOS = FALSE` | the placement before 2026-10-09 (bag pages, large blocks) | kept so the CR-018 / CR-035 rows, controls and mutants stay meaningful history; the code is `LOS = TRUE` |

## 4. Footprint rows (A3)

M8 is serial: it owns no concurrent footprint row. The rows its state touches, and where the
concurrent side is modelled: `P6.M9` (`large_body_index_`: M3's map race, CR-014) → M8's `index`
is the same table, serially; `H9` (`BlockInfo` of reachable blocks, the flip) → M8's `blk` and
`Flip`; `H3`–`H5` (page-index owners, region bounds; W4) → M8's `owner`, `ext`, `bump`;
`P6.M16` (`live_bytes`) → M8's `blk[id].lb`, whose serial maintenance is CR-018.

## 5. Invariants (A7)

| Invariant | Id | Code check |
|---|---|---|
| `NoLostObject` | HEAP_051, HEAP_054, HEAP_062 (no live object freed, released, covered or headerless) | V8, V12, IM5 (validate) |
| `NoOverwriteLive` | HEAP_054 (the bitmap / live bytes are the allocation record) | IM4 `assertCellWasWhite` (cycle only) |
| `NoDoubleAlloc` | HEAP_052, HEAP_054 (no cell handed out twice, no free cell over an allocated one) | V6, the duplicate-push check in `pushSpanOnFreeLists` (validate) |
| `BlockParseable` | HEAP_024 (a mixed block parses by header over `[start, end_of_objects)`), HEAP_055 (the gap sweep reads only live headers) | V11 (after a block's gap sweep) |
| `IndexFaithful` | HEAP_026, HEAP_056, HEAP_062 | V12, the post-release index check `OGS:6438-6459` (validate) |
| `FreeListsInLiveBlocks` | HEAP_052 | `removeFreeCellsForBlock`'s LEAK probe (validate) |
| `FlipTrustsTruth` | HEAP_051, HEAP_073 (what `live_bytes == 0` and `fully_swept` claim) | none (CR-018 fixed by counting in every phase) |
| `SideTablesFaithful` | HEAP_048, HEAP_049, HEAP_054 | V7 / `validateOldGenMetadata` |
| witnesses `NoSizeClassedBagCarve`, `NoSameIdSameStartReissue` | CR-029's route, CR-036's shape | — |
| `LosTracked` | HEAP_080 (every LOS object is tracked: the LOS frees only through the index) | `validateLosTracking` at `losSweepAtMarkEnd` (validate) |
| `LosSeparation` | HEAP_080 (pinned and young large objects live in LOS blocks, nothing else does) | `placeLarge`'s cap, `allocateTrackedCell` |

`BlockParseable` exempts uniform blocks (bitmap-parsed, HEAP_024) and a mixed block the running
sweep has still to walk (`phase = Sweeping ∧ ¬fs`: the gap sweep rewrites its dead space before
anything reads it, so demoted blocks, whose virgin cells have no headers, pass). `FlipTrustsTruth`
counts, at a flip, a rooted object or a registered young large object in the block; at a
release (reclaim, shrink), a rooted object.

## 6. Contracts

- **Provided: BlockLifecycleSerial** (to M4, M1, M5): with CR-018, CR-033 and CR-035's fixes
  (the spec's defaults since 2026-09-30; their pre-fix code is the mutants `idle_uncounted`,
  `bag_tail_headerless`, `flip_keeps_index`), the serial lifecycle keeps every invariant above (`controls/fixed_all`,
  `MC_deep_fixed`). M4's `ReleasedSafe` assumes the serial release and re-issue are sound; M8
  checks them with address reuse (`MC_quick_reuse`, the re-issue witness).
- **Assumed**: nothing from other models (serial).

## 7. The A1–A9 table

| Rule | M8 |
|---|---|
| A1 Atomicity | one operation = one step; the code is serial (§2) |
| A2 Granularity | 8-byte granules for headers, mark bits and cells; pages for blocks |
| A3 Footprint | §4 (serial: no concurrent row) |
| A4 Weak memory | none (serial) |
| A5 Trace validation | not built. A harness would drive `allocate` sequences through the flip and the bag rung (the CR-018 unit test in `test/allocator/ConcurrencyRegisterTest.cpp` is most of one) |
| A6 Negative controls | 8 mutants, one per invariant (AUDIT.md), plus 5 register reproductions, 2 witnesses and 5 fix-candidate controls |
| A7 Traceability | §5 |
| A8 Scope | 1–3 pages, ≤ 5 objects, ≤ 8 counted operations (minor reaches and ends are free), 2 large-body slots; coverage (`CovMC.tla`, `coverage.cfg`): every modelled path is exercised by the pass rows but `reach_miss` and a no-op `freeLargeBodyCell`, which only CR-035's chain produces (AUDIT.md) |
| A9 Canary | proposed pins below; the orchestrator adds them to `manifest.txt` |

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (added 2026-09-29 from this model's
proposal; the new regions it also proposes, which need `TLA-REGION` markers in the runtime, are
listed in AUDIT.md and not yet pinned). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/BlockTable.hpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.retireDeadLargeBodies` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.classifyBlocksAfterMark` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.sweepNurseryLargeBodies` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.freeLargeBodyCell` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.promoteYoungLarge` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.initObjectHeaderWithSize` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizeBitmapCell` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.resetAllocCursors` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.detachFromAllocation` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.tryPopFromFreeList` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizePoppedCell` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.tryAllocateFromFreeLists` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.sweepOnDemandAllocate` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.panicSweepAndRetryAllocation` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocateFromBagPage` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocateFromEmptyRegularBlocks` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.pushSpanOnFreeLists` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.lazySweep` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.onSweepComplete` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.maybeShrinkCapacity` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.computeFragmentationStats` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.ensureBagPageAvailable` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocateLargeBlock` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.releaseBlockToAllocator` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.releaseUnassignedBlockToAllocator` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.materializeBlock` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.assignPageIndexForBlock` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.blockIdFor` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.hasPendingSweepWork` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.youngLargeMeta` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.LargeBodyMeta` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.registerLargeBody` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.minorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.majorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.majorGCAndShrink` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.acquireOldGenBlock` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.releaseOldGenBlock` |
<!-- canary-pins end -->
