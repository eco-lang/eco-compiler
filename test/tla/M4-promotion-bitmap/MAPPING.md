# M4 — old-gen promotion and the mark bitmap at byte granularity: model ↔ code

The model is `PromoBitmap.tla` (PlusCal plus its committed translation). `MC.tla` holds the
miniature heaps, one per scenario. The plan is `plans/threaded-gc-tla-M4-promotion-bitmap.md`;
its §2 explains the protocol. **This file cites code, never plan text** (parent plan §12, trap 1).

Line numbers are for the tree of 2026-09-29, **after** the M1 trace hooks landed in
`OldGenSpace.cpp` (an `#include "TlaTrace.hpp"` at `:13` and hooks from `:3150` on). They are the
plan's numbers + 1 below `:3150` and + 25 above `:4722`. No hook is inside a region M4 models.
Functions are named too, because lines drift. **Since 2026-09-29 (trace wave) M4's own `m4.*`
hooks are in those regions** (§8). With other models' hooks of the same day they shift the `OGS`
numbers of §1–§6 by + 13 (`detachFromAllocation`) to + 106 (`releaseBlockToAllocator`); §8 cites
the tree after them. Match by function name.

Abbreviations: `OGS` = `runtime/src/allocator/OldGenSpace.cpp`, `OGH` = `OldGenSpace.hpp`,
`OGT` = `OldGenTenure.cpp`, `BS` = `BitmapScan.hpp`, `MW` = `MinorWork.hpp`,
`TLH` = `ThreadLocalHeap.cpp`.

## 1. Variables

| Variable | Meaning | Code counterpart |
|---|---|---|
| `bits[y]` | the set bits of mark byte `y`, as a set of cells | the mark bitmap arena (`mark_.slot(id)`); `markBitLocation` `OGH:1753` |
| `freeList` | the modelled size class's free list, head first | `free_lists_[cls]`; push at the head `OGS:5022`/`:5030` (`pushSpanOnFreeLists`), pop the head `OGS:2007` (`tryPopFromFreeList`): LIFO |
| `sweepQ` | the gap sweep's remaining loop iterations `[g, l, e]`, in address order | `sweep_buffer_index_`, `sweep_cursor_` (`lazySweep`) |
| `phase` | `gc_phase_` | `OGH` `gc_phase_`; since 2026-09-30 (CR-001, HEAP_067) its in-minor write (`lazySweep`'s `completeSweep`) is a relaxed `atomic_ref` store and the reads outside `promo_mu_` (`finalizePoppedCellW`, `finalizeBitmapCellW`) relaxed `atomic_ref` loads (`PhasePlain` = FALSE; mutant `phase_plain` = the pre-fix plain field); reads under `promo_mu_` stay plain (`PhLocked`) |
| `liveBytes[b]` | `live_bytes` of block `b`, in cells | `BufferMetadata::live_bytes` (06 P§3.11 row M16, footprint row `P6.M16`: atomic adds outside `promo_mu_`, plain reads under it) |
| `swept[b]` | `fully_swept` | `BufferMetadata::fully_swept`; `markBlockFullySwept` (`OGS:5342`, `:5473`) |
| `deferred` | the deferred `onSweepComplete` | `sweep_complete_deferred_` (`OGS:1365`, `:1531`) |
| `shared` | the modelled class's shared promotion word: block and next unit | `PromoCtx::shared[cls].w` (`(id + 1) << 32 \| unit`) |
| `partialQ` | the refill queue | `partial_[cls]` / `partial_head_[cls]` |
| `lock` | `promo_mu_` | `OGH:765`, a `minorwork::SpinMutex` (`MW:85-110`) |
| `chunk[w]`, `pos` (local), `chunkLive[w]` | a worker's cursor: its chunk's cells, `next_cell`, `pending_live` | `PromoWorker::cur[cls]` (`AllocCursor`) |
| `stash[w]`, `fin` (local) | popped, not yet finalized cells; the first popped cell, finalized right after the unlock | `PromoWorker::stash[cls]`, `stash_n[cls]`; `popped` in `allocatePromotion` |
| `other` (local) | this promotion is of the other size class | the `cls` argument of `allocatePromotion` |
| `released` | blocks released by a shrink or flipped to large; with `reuse_released` (2026-09-29) a released block can leave the set again, re-issued by the virgin rung | `releaseBlockToAllocator` (`OGS:6020`), `allocateFromEmptyRegularBlocks` (`OGS:2666`); the re-issue: `BlockTable::add`'s LIFO id (`BlockTable.hpp:158-186`) and `acquireOldGenBlock`'s first fit (`Allocator.cpp:782-793`) |
| `grantOn`, `grantLive` | the grant is live; its `pending_live` | `TenureGrant::active`; `TenureCursor::pending_live` |
| `gclaim`, `gch`/`gpos` (locals) | L3: the grant claim word; a member's chunk and position | `TenureGrant::claim[cls].w`; `TenureMemberCursor::Cls` |
| `gwork` | survivors the tenure collector still copies | the tenure job's work (M5's domain) |
| ghosts `allocs`, `need`, `marked`, `claimed`, `fatal` | times a cell was handed out; allocate-black bits that must survive; the marker's bits; claimed chunk units; FATALs that fired | — |
| `vc`, `lockvc`, `sharedvc`, `hist`, `races` | the vector-clock data-race detector (plan §4.4, primer §3.7) | — |

## 2. Steps: label ↔ code ↔ footprint row ↔ invariants (A1)

A plain read-modify-write is two steps (load, store). Every `gc_phase_` read outside the lock is its
own step. "Row" is the footprint row id of `test/tla/footprint-greps.txt` (§4): `H*` = 05c P§3.6, `P6.M*` = 06 P§3.11, `T*` = 07 P§3.17.

| Label | Code (function, line) | Atomic step | Row | Invariants it can break |
|---|---|---|---|---|
| `W_Loop` / `W_R1`: `Rung1` fast path | `cursorAllocateW` `OGS:1147`, byte test `:1151`; `bitscan::setBit`'s load | plain byte read (+ the setBit load) | P6.M5 | `NoRaceBitmap`, `AllocMapExact`, `NoDoubleAlloc` |
| `Rung1` scan | `bitscan::nextFreeCell` `OGS:1156` → `BS:84`, `loadWord` `BS:25` | plain WORD reads, pos → found cell | P6.M5 | `NoRaceBitmap` |
| `Rung1` exhausted | `cursorAllocateW`'s last scan, `flushCursorW` `OGS:1161` → `fetch_add` `OGS:1035` | word read + relaxed atomic add of `live_bytes` | P6.M5, `live_bytes` | `NoRaceLive` |
| `W_R1Set` | `finalizeBitmapCellW` `OGS:1122`, `bitscan::setBit` `:1132` | plain byte store | H1b, P6.M5 | `NoRaceBitmap`, `AllocMapExact`, `NoOverwriteLive`, `IM13` (with `cursor_on_t0`) |
| `W_R1Ph` | `finalizeBitmapCellW` colour | a relaxed `atomic_ref` load of `gc_phase_`, no lock (CR-001 fixed 2026-09-30; plain under `phase_plain`) | P6.M6 (`gc_phase_`) | `NoRacePhase` (CR-001) |
| `W_Claim` | `claimChunkW` `OGS:1172`: acquire load `:1174`, `lo >= ncell` `:1182`, CAS `:1184` (acq_rel), clamp `:1191` | one successful CAS, or one failed acquire load | P6.M5 | `ClaimsInRange`, `IM13` |
| `W_Stash` / `W_Fin` (`FinPhase`) | `allocatePromotion` stash use and the batch's first cell, finalized after the unlock or, for a cell of a block not `fully_swept`, BEFORE it (CR-002, `W_Fin` with the lock held → `W_StUnlock`) → `finalizePoppedCellW`, phase read (relaxed `atomic_ref` load, CR-001); `CountsBit(phase)` = the colour and bit; at Idle the `live_bytes` `fetch_add` runs in the same step (`IdleCounts`: CR-018 fixed 2026-09-30, HEAP_073; mutant `idle_uncounted` = the pre-fix code) | a relaxed atomic read of `gc_phase_` (outside the lock, or under it for CR-002's in-lock finalize); the Idle add is a relaxed atomic RMW | P6.M6, P6.M16 | `NoRacePhase`, `ReleasedSafe` (CR-001 S1: closed by the Idle count) |
| `W_StBit` | `finalizePoppedCellW` `setMarkBitAtomic` `OGS:1084` (`OGH:1822`) + `fetch_add` `:1086` | two relaxed atomics on different locations, merged (§3) | H1, `live_bytes` | `NoRaceBitmap`, `NoRaceLive`, `NoLostRequiredBit` |
| `W_StBit` / `W_StPlainSet` (`plain_stash_black`) | a plain set in `finalizePoppedCellW` (no hook exists: model-only) | plain load, then plain store | H1 | `NoLostRequiredBit`, `NoRaceBitmap` |
| `W_Stash` lock branch | `allocatePromotion` `OGS:1588-1596` (`unique_lock`, `try_to_lock` then `lock`) | `promo_mu_` acquire (`exchange`, acquire `MW:89`) | P6.M6 | — |
| `W_Locked` | `advanceSharedW` (retire, relaxed store 0) → `publishShared` (release store); the refill loop; rung 2 batch pop in `allocatePromotion`: **CR-002 fixed 2026-09-30 (HEAP_055)**: a popped head of a block not `fully_swept` (`cellInUnsweptBlock`, `OGH`) is finalized before the unlock and nothing is stashed; otherwise only the prefix of the list in fully swept blocks is stashed (`SweptPrefix`, the peek); mutant `finalize_outside_lock` = the pre-fix batch; unlock (`MW:109`, release) | one lock hold's decision; the publish is a release store | P6.M6 | `DetachNotCurrent` (the published block), `NoRaceBitmap` (CR-002) |
| `W_LadderB`, `Ladder` | `ladderFrom2W` `OGS:1307`: `hasPendingSweepWork()` `:1337` (`OGH:1485`), virgin `:1328`/`:1345`, bag `:1346`, panic `:1347` | a read of `gc_phase_` under the lock | P6.M6 | — |
| `W_Virgin` | `ladderFrom2W`'s `virgin()` after a failed `sweepOnDemandAllocate`: `startVirginBlockShared` (`publishShared`'s release store), then `claimChunkW` inside the hold; else `allocateFromBagPage` / `panicSweepAndRetryAllocation`. **`reuse_released` (2026-09-29):** the virgin block may be a released block re-issued at the same id and start (`startVirginBlockShared` `OGS:1349` → `ensureBagPageAvailable` → `acquireOldGenBlock` → `materializeBlock` `OGS:700`, whose `mark_.assign` zeroes the bitmap slot) | one lock hold's decision; the publish is a release store; the re-issue's memset is a plain write of the block's mark bytes | P6.M5, P6.M6 | `DetachNotCurrent` (the published block has `live_bytes` 0); with `reuse_released`, `NoDoubleAlloc` (a stash or chunk cell of the released block handed out again) |
| `W_Sweep` | `lazySweep` `OGS:5245`, gap sweep `:5356-5394`: `nextSetBit` `:5364`, `flushRun` `:5384`; block boundary `:5448-5476` | a plain WORD read and the push at the head, under the lock (+ clearBit's load) | H1 (t0 bytes: none mid-sweep), P6.M6 | `NoRaceBitmap` (CR-002), `FreeBehindCursor` |
| `W_SweepClr` | `bitscan::clearBit` `OGS:5385` (`BS:37`) | plain byte store | P6.M6 | `NoRaceBitmap` (CR-002) |
| `W_SweepEnd` | budget test; early exit; **both completions (in-loop path 2, tail path 3) call `lazySweep`'s `completeSweep` lambda (CR-014 fixed 2026-09-30, HEAP_067): `gc_phase_ = Idle` (a relaxed `atomic_ref` store, CR-001) then `sweepCompleteInPromotion` inside a promotion**; mutant `tail_immediate` = the pre-fix tail path (`→ W_Shrink`) | an atomic write of `gc_phase_` under the lock, at completion | P6.M6 | `NoRacePhase` |
| `W_PopAfterSweep` | `sweepOnDemandAllocate` `OGS:2137` → `tryAllocateFromFreeLists` `:2040` → `finalizePoppedCell` `:2026` → `initObjectHeaderWithSize` `:488` (phase `:498`, atomic set `:519`, add `:528`; the add runs at Idle too, atomic while `par_promo_active_`: CR-018, HEAP_073), then the unlock | everything under the lock; the atomics are relaxed | P6.M6, H1 | `NoRaceBitmap`, `NoRaceLive`, `ReleasedSafe` |
| `W_Shrink` | **`tail_immediate` only (the pre-fix tail path; since CR-014's fix `onSweepComplete` aborts inside a parallel promotion, PM7)**: `onSweepComplete` → `computeFragmentationStats` `:6394` (plain reads `:6403`) → `maybeShrinkCapacity` `:5724`, pass 1 `:5821-5835` → `releaseBlockToAllocator` `:6020` → `detachFromAllocation` `:695` (FATAL `:713-718`) | under the lock; plain reads of every `live_bytes` | `live_bytes`, P6.M6 | `DetachNotCurrent`, `ReleasedSafe`, `NoRaceLive` (CR-014) |
| `W_Large` | `allocatePromotion` large path `OGS:1543-1555` (`lock_guard` `:1548`) → `allocateLargeBlock` `:2726` → `allocateFromEmptyRegularBlocks` `:2666` (**CR-016 fixed 2026-09-30, HEAP_054: returns nullptr first when `par_promo_active_ && promo_ctx_->n > 1`, so `FlipCands` is empty for `Cardinality(Workers) > 1`; one worker keeps it, `controls/flip_one_worker`; mutant `flip_in_parallel` = the pre-fix code**; test `:2673`, Current skip `:2677`, tenure skip `:2680`, `detachFromAllocation` `:2686`, `retireIndexRange` (CR-035), flip `:2702-2714`, `live_bytes = size` `:2708`) | one lock hold; plain reads and a plain write of `live_bytes` | `live_bytes`, H9 | `ReleasedSafe` (CR-016) |
| `K_Loop` | `testAndSetMark<ParallelMark>` `OGS:3040` (test-before-set, `fetch_or` `:3069`) | relaxed `fetch_or` | H1 | `NoRaceBitmap` (with `marker_on_post_t0`) |
| `G_Join` | `endParallelPromotion` `OGS:1417`: flush `:1423`, stash return `:1441-1452`, shared word reset, the gang join before it | the join publishes the workers' clocks (LaunchJoin) | P6.M5/M6/M7 | — |
| `G_Shrink` | the deferred `onSweepComplete` `OGS:1531-1534` | after the join | `live_bytes` | `ReleasedSafe` (CR-001 S1) |
| `C_Loop` (one member) | `grantAllocate` `OGT:153`: next-cell byte test, `nextFreeCell` | plain byte or word read (+ setBit's load) | T5 | `NoRaceBitmap`, `NoDoubleAlloc`, `NoOverwriteLive` |
| `C_Loop` claim (L3) | `grantAllocateShared` `OGT:197`: claim CAS `OGT:245-249` (relaxed) | one relaxed CAS: no synchronisation | T5 | `NoDoubleAlloc` (with `grant_claim_plain`) |
| `C_ClaimStore` | `grant_claim_plain` only: the claim as a plain load and store | — | T5 | `NoDoubleAlloc` |
| `C_Claimed`, `C_Set` | `grantAllocateShared` `nextFreeCell`; `bitscan::setBit` `OGT:177` / `:214` | word read; plain byte store | T5 | `NoRaceBitmap`, `AllocMapExact` |
| `U_Cursor`, `U_CursorSet` | `cursorAllocate` → `finalizeBitmapCell` `OGS:803`, `setBit` `:821` | plain read, plain store | H1b | `NoDoubleAlloc` (with `grant_includes_cursor`), `NoRaceBitmap` |
| `U_Pop`, `U_PopPlainSet` | `tryAllocateFromFreeLists` → `finalizePoppedCell` → `initObjectHeaderWithSize` `OGS:488`: `test_plain_allocate_black_` `:516` (plain), `setMarkBitAtomic` `:519` | one atomic step, or a plain load then store | H1 | `NoLostRequiredBit`, `NoRaceBitmap` (`plain_allocate_black`) |
| `U_Sweep`, `U_SweepClr`, `U_SweepDone` | `allocate()`'s `lazySweep` slice; `onSweepComplete`'s light shrink with the tenure skip `OGS:5830` | the mutator's own steps | T6 | `ReleasedSafe` (`shrink_ignores_tenure`) |
| `U_Large` | `allocate()` of exactly `alloc_buffer_size` `OGS:1932-1934` → `allocateFromEmptyRegularBlocks` (tenure skip `:2680`) | one step | T6 | `ReleasedSafe` (`flip_ignores_tenure`) |
| `U_Pause`, `U_Join`, `U_T0`, `U_After` | `TLH::minorGC` `TLH:707` (tenure join `:728`/`:734`, `TenureLaunchScope` `:740`); `returnTenureGrant` `OGT:288`; `resetAllocCursors` FATAL `OGS:685-690` | pause steps | T6 (HEAP_070) | `NoGrantAtT0` |

Promotion callers (the same `allocatePromotion` on every path): the phase-6 parallel minor
(`NurseryParallel.cpp:259`); 7c's pause engine `runJobParallel` (`NurseryTenure.cpp:1184-1196`, its
workers `:984`); the serial identity switch (`NurserySpace.hpp:481`, `per_alloc_sweep = true`,
N = 1: not modelled, no concurrency inside it).

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| a mark byte = 8 slots | a byte = 2–3 cells (`M1` = cells 1–3, ...) | sharing is what matters; three cells in one byte reproduce CR-002 |
| a 64-bit word = 8 bytes | `ByteWord`: `M1`+`M2` one word, every other byte its own | scans read words (`BS:25`); a scan is a plain read of every byte of its word |
| a 64-cell chunk | a chunk = one byte, one word | keeps "a chunk is whole words"; `chunk_unit_subbyte` / `_subword` break it |
| a chunk grows (`chunk_units` doubles, `OGS:1186`) | `k \in ClaimK` units per claim (`MC`: `{1}`; the trace: `{1, 2, 4, …, 32}`) | a larger chunk is a union of whole-word units: the same ownership argument |
| size classes | the modelled class + an **other class** (`TwoClasses`, sweep scenarios) | see AUDIT.md: a sweeper of another class does not retire this class's shared block, and does not pop the cells it flushes. Both are needed (CR-014's FATAL, CR-002) |
| the other class's cursor, chunks, stash and list | outside the model; its lock holds, `gc_phase_` reads and flushes are modelled | its bytes are in other blocks; `live_bytes` is one race location |
| early exit of `lazySweep` at a block boundary (`OGS:5478`) | forced for my class when `freeList` is non-empty; a choice for the other class | exactly the code's test on `free_lists_[target_class]` |
| the slice budget | after any iteration inside a block the slice may end | the budget is tested only at the loop head (`OGS:5361`), so every real boundary is a model boundary |
| a batch pop of 1 + 16 | 1 + up to `BatchMax - 1` (`MC`: `BatchMax = 2`; the trace: 17); stash order any | "popped but not finalized" needs one cell; any order over-approximates LIFO |
| the refill's claim and first allocation inside the hold | inside the hold (`W_Locked` → `W_Claim` → `W_R1`, unlock at `W_R1Ph`) | the code's order (`OGS:1607-1611`) |
| a failed claim | an acquire of the shared word's release sequence (`sharedvc`); a relaxed store 0 (retire) resets it | C++20 release sequences: a plain store heads none |
| the shrink's sizing (`desired_heap`, `canRelease`) and the light-pass gate | any subset of the candidates | over-approximation: a violation must be checked against the sizing (AUDIT.md) |
| `allocateLargeBlock`'s free-large-block and fresh-block paths | the flip, or `"none"` | a superset of the code's choices |
| a released block's id and extent handed out again (`reuse_released`, 2026-09-29) | the virgin rung may re-issue a released block with chunk units as the shared block: same cells, mark bytes cleared, `live_bytes` 0, fully swept (under `reuse_released` D gets the unit `{6, 7}`) | the id is certain (LIFO); the same start needs the bag empty and the released extent the first fit. A cell of the old block and the overlapping cell of the new one are one model cell (the same bytes). Only the virgin rung re-issues; the mutator's and the grant's re-issues are not modelled. The rows cut behaviours after a FATAL (`CONSTRAINT MC_NoFatal`): a FATAL ends the process |
| virgin / split / bag / panic rungs | after a failed sweep-on-demand, still in the hold: `W_Virgin` publishes the head of `VirginQ` and claims from it (`MC`: `VirginQ = <<>>`; the trace: the log's virgin blocks), else a cell outside the model (`n + 1`); before sweeping only with `Breadth` | they allocate outside the modelled blocks; the `Breadth`-only branches change no modelled state except `n` and add lock synchronisation, so they cannot create a violation (AUDIT.md). The ladder never goes back to the lock-free claim in the same promotion (`ladderFrom2W`'s `virgin()` claims inside the hold) |
| two consecutive relaxed atomics of one thread on different locations (`W_StBit`: `fetch_or` + `fetch_add`) | one step | no checked property distinguishes the intermediate state: the cell stays in `stash` until the step, so `ReleasedSafe` covers the whole finalize |
| `setBit`'s load | taken with the read that found the cell (`W_R1`, `W_Sweep`) | the lost-update window is wider than the code's; under the ownership rules nothing writes the byte in between, so values are exact, and the race detector records the same plain read |
| the trailing dead run's `nextSetBit` word read (D) | not recorded | no D cell is free-listed before that step (`FreeBehindCursor`), and no marker runs during a sweep |
| `marking_active` | folded into `phase` | written only in pauses |
| heap objects, headers, slack | absent | M4 is about metadata and bytes (M1, M3) |
| `BlockInfo` fields the flip writes (`is_large`, `size_class`, `end_of_objects`, `mark_.drop`) | the block joins `released` | the release is what `ReleasedSafe` checks; the field race itself is noted in plan §2.5 item 3, not modelled |
| the markers' `live_bytes` accumulators | absent | folded in pauses |
| the tenure job's work queue | `gwork`, an atomic counter with no synchronisation | M5's domain; members touch disjoint chunk words |
| the mutator's cursor block `live_bytes` in the shrink | excluded from candidates | `syncCursorLiveBytes` makes it exact, and it holds a cell |

## 4. Footprint rows (A3)

| Row | Location | Model |
|---|---|---|
| H1 | mark bytes of t0 blocks (allocate-black `fetch_or`, marker `fetch_or`) | `bits` of `M1`, `M2`, `Z1`; `K_Loop`, `U_Pop`, `W_StBit`, `W_PopAfterSweep` |
| H1b | mark bytes of post-t0 blocks (cursor `setBit`, IM13) | `bits` of `U*`, `V1`, `G*`, `K1`; `IM13`, `TV5`, `marker_on_post_t0` |
| H2 | mark bytes read by validators | not modelled (validate builds; atomic loads) |
| H9 | `BlockInfo` of reachable blocks (the flip) | the flip's release (`released`); the field writes are not modelled (§3) |
| P6.M5 | worker cursor blocks: cells, bitmap bytes, `pending_*` | `chunk`, `chunkLive`, `pos`; **the row's rule "distinct blocks never share a bitmap byte" is out of date**: chunked cursors share a block, and the rule the scans need is "chunks own whole words" (CR-022) |
| P6.M6 | rungs 2–8 state, including "sweep cursor and `gc_phase_`", rule `promo_mu_` | `freeList`, `sweepQ`, `partialQ`, `phase`, `lock`. **`gc_phase_` broke the row's rule** (`finalizePoppedCellW` and `finalizeBitmapCellW` read it outside the lock, CR-001): since 2026-09-30 those reads and the in-minor write are relaxed `atomic_ref` accesses (HEAP_067). The gap sweep's mark words of the block under the cursor are exclusive under `promo_mu_` (CR-002, HEAP_055) |
| P6.M7 | `allocated_bytes` deltas | not modelled (per-worker, merged after the join) |
| P6.M9 | `large_body_index_` | not modelled (CR-014's map race is M3's) |
| P6.M15 | 5c background markers | `Marker` |
| **no row** | `BufferMetadata::live_bytes`: relaxed `fetch_add` outside the lock (`flushCursorW` `OGS:1035`, `finalizePoppedCellW` `:1086`), plain reads and a plain write under the lock (`computeFragmentationStats` `:6403`, pass 1 `:5827`, the flip `:2673`/`:2708`) | `liveBytes`, race location `"live"`. **A hole in 06 P§3.11**: add a row (CR-014, CR-016) |
| **no row** | `PromoWorker::stash` | `stash`: owner-only until the merge (`OGS:1441`) |
| T5 | granted blocks: cells, bitmap bytes, `TenureCursor` | `G1`/`G2`, `grantLive`, `gclaim`; `TV5`, `grant_*` mutants |
| T6 | mutator-side selection paths skip `kAllocTenure` | the shrink skip (`shrink_ignores_tenure`), the flip skip (`flip_ignores_tenure`), `grantTenure`'s cursor-block skip `OGT:100` (`grant_includes_cursor`), `resetAllocCursors` (`launch_before_t0`). The refill's `kAllocQueued` test is not modelled: a granted block has left `partial_` already |
| H1 (large) | `largeMark` bytes | not modelled: no S_H object lives in a free large block (05c audit) |
| free-list links, Tier-M back-links (HEAP_052) | always under `promo_mu_` or the single mutator | `freeList` as a sequence |

## 5. Invariants (A7)

| Invariant | Id | Code check |
|---|---|---|
| `NoRaceBitmap`, `NoRacePhase`, `NoRaceLive` | MODEL_M4_RACE (C++ [intro.races]) | TSan (`test/gc-heap-tsan`, later wave) |
| `NoLostRequiredBit` (end state) | IM4 + the 05c H1 argument | `assertCellWasWhite`; IM4 in `allocatePromotion` (`OGS:1638-1646`) |
| `NoDoubleAlloc` | HEAP_054 (bitmap = allocation map) | V8 popcount validator |
| `NoOverwriteLive` | IM13's purpose (a t0 bitmap is being rebuilt) | — |
| `ReleasedSafe` | HEAP_051, HEAP_070; M7's ReleaseContract | IM5 asserts in `releaseBlockToAllocator` (cycle only) |
| `FreeBehindCursor` | HEAP_055's premise | V11 (`lazySweep`, validate builds) |
| `ClaimsInRange` | MODEL_M4_CLAIM | `claimChunkW`'s `lo >= ncell` and clamp |
| `IM13` | IM13 | `setCursorW`, `publishShared` (`OGS:1203-1210`) |
| `TV5` | 07 TV5 | `grantTenure` (`OGT:102-109`, validate builds) |
| `AllocMapExact` (end state) | HEAP_054 | V8 |
| `DetachNotCurrent` | HEAP_054 (worker cursors) | the FATAL in `detachFromAllocation` `OGS:713-718` (every build) |
| `NoGrantAtT0` | HEAP_070 | the FATAL in `resetAllocCursors` `OGS:685-690` (every build) |

## 6. Contracts (parent plan §5.0)

- **Used from M1: `MarkerFootprint`.** The `Marker` sets bits only of `T0Live` objects in t0 blocks.
  `marker_on_post_t0` breaks it (CR-017's worst case) and must race.
- **Not used: M3's `CopyOnceContract`.** Each promotion is one allocation request.
- **Provided: BitFaithful** (to M1, M5): `NoLostRequiredBit`, `NoRaceBitmap`, `IM13`, `TV5`,
  `AllocMapExact`. Holds in every scenario since CR-002's fix (2026-09-30: unswept-block cells
  finalized under `promo_mu_`); mutant `finalize_outside_lock` breaks `NoRaceBitmap`.
- **Provided: ReleaseContract** (to M7): `ReleasedSafe`. It is ABA-blind by construction: once a
  released block is re-issued (`reuse_released`) it is live again and `ReleasedSafe` no longer sees
  a stale chunk or stash cell in it; the re-issue rows check `NoDoubleAlloc` instead (AUDIT.md,
  2026-09-29). Holds at the defaults since register-fixes Phases 1-2 (2026-09-30: CR-018 closed
  CR-001's S1 half, CR-016, CR-014); the pre-fix shapes are the mutants `idle_uncounted_release`,
  `flip_in_parallel_*` and `tail_immediate*`.

## 7. The A1–A9 table

| Rule | M4 |
|---|---|
| A1 Atomicity | §2: one label = one atomic step. Plain byte RMWs are a load step and a store step; every `gc_phase_` read outside the lock is its own step; a failed claim is its own step; a lock hold's internal steps are visible only where a lock-free thread can observe them. Recorded merges (§3): the setBit load with the scan that found the cell; `W_StBit`'s two relaxed atomics; the in-lock pop, its phase read and its atomics (all under the lock) |
| A2 Granularity | bytes for bits; words for `nextFreeCell` / `nextSetBit`; chunks are whole words (CR-022) |
| A3 Footprint | §4. Two holes in 06 P§3.11: `live_bytes` has no row, and M6's rule for `gc_phase_` is broken by the unlocked readers; M5's "distinct blocks" rule is out of date |
| A4 Weak memory | the model is SC with a C++ race detector. Relies on: **W3** (relaxed `fetch_or` vs `fetch_or`; the plain `setBit` and word scans on a post-t0 word; CR-002's pattern): W3b and W3e PASS, and W3c/W3d reported the races of CR-002 and CR-001 (GenMC RC11, `test/genmc/AUDIT.md`, 2026-09-28); since the fixes (2026-09-30) W3c/W3d are `pass` rows and the pre-fix shapes are the mutants `W3_CR002_UNLOCKED_FINALIZE` / `W3_CR001_PLAIN_PHASE` (not run here: `genmc` missing); **W3f** (`minorwork::SpinMutex` gives acquire on `exchange`, release on the unlocking store, `MW:89`, `:109`): PASS; **W4b** (a chunk of a freshly published shared block is fully visible: `publishShared`'s release store `OGS:1212` → `claimChunkW`'s acquire `:1174`/CAS `:1184`): PASS, and `W4_RELAXED_SHARED`, `W4_RELAXED_CLAIM_FAIL` are flagged. The L3 claim CAS is relaxed (`OGT:245-249`) and is modelled with no synchronisation |
| A5 Trace validation | §8: `TracePromoBitmap.tla` on `gc-heap-trace promo` (`test/gc-heap-tsan/promo_sweep.cpp`), every `m4.*` event one model step or a state check, in the merged order (`TraceInOrder`). `traces.txt`: 5 accept rows (3 active threads in four, `mut` alone in the jitter row; 236–460 events) and 7 `mutate=` rows (`drop`, `set` ×5, `swap`), 12/12 as expected on five runs. `TraceRace.cfg` adds the race detector and the safety invariants: before CR-002's fix every multi-threaded log (16 of 16 over four runs) violated `NoRaceBitmap`, CR-002's pair; since the fix (2026-09-30) it is a `traces.txt` accept row. The TSan stress (`gc-heap-tsan promo`) reports CR-001, CR-002 and CR-016 (AUDIT.md, trace wave) |
| A6 Negative controls | every invariant covered by a mutant (AUDIT.md). Since register-fixes Phase 2 (2026-09-30) the fix candidates are the defaults and the pre-fix code is a mutant each: `tail_immediate{,_release,_live,_reuse}` (CR-014), `phase_plain` (CR-001), `finalize_outside_lock` (CR-002), with Phase 1's `idle_uncounted_release`, `flip_in_parallel_{stash,chunk}`; the controls left are `flip_one_worker`; the re-issue's own control `sweep_tail_nda` (pass) |
| A7 Traceability | §5 |
| A8 Scope | 2 workers (deep: 3), 2 promotions each (deep: 3; the re-issue rows: 4 and 3), a merge; a marker; a mutator and 1 or 2 collector members; 7 blocks, 19 cells (21 in `epoch_l3`), 9 or 10 bytes. No counter wraps. The vector clocks grow only at lock releases and CASes, and every process terminates, so the state space is finite |
| A9 Canary | not built yet (later wave); the lines M4 needs are listed in AUDIT.md "Left for the next wave", and the hooks' files in AUDIT.md (trace wave) |

## 8. Trace validation (A5)

**Harness.** `gc-heap-trace promo <seed> [workers [trees [jitter_us]]]` (`promo_sweep.cpp`,
`promoTraceMain`; trace builds only). About two blocks of Tuple2 leaves (24 B, the modelled
class, 170 cells in a 4 KiB block) are promoted; in the fullest block M alternate cells die, in
the others one cell in ten; `demote_live_fraction = 0.5` makes M mixed; a STW major leaves a lazy
sweep pending; `trees` young trees of 15 Tuple2s age by one minor; the next minor is recorded. The
roots point at the trees' roots only (worker 0 copies what the roots point at before the gang
starts), so the gang's workers steal subtrees and promote in parallel. Sweep slices are 144 bytes
(3 gap-sweep iterations). `::Elm::tla_m4` switches the hooks on for that minor only.

**Header → constants** (`TracePromoBitmapData.tla`; the log's first line, written by
`snapshotHeader` just before the minor): cells are `block * 10000 + first mark bit`, blocks
`"b<id>"`, bytes `"y<block>.<bit / 8>"`, words by 8 bytes. `blocks` gives each class block's cells,
set bits, `live_bytes`, `fully_swept`, mixed or not, and chunk units (64 cells); `items` the
sweep's remaining iterations `[g, l, e, rs, rb]` (the harness replays `pushSpanOnFreeLists`'s
packer to find the gap cells); `free` the class's free list; `partial` the refill queue;
`shared` the shared word; `prealloc` the cells already handed out. Blocks published later by the
virgin rung (`m4.pub` of a block not in the header) are added from the log (`TP_Virgin`, bound to
`VirginQ`, and their cells to `Cells`). `NAllocs[w]` is each worker's number of class-A
promotions in the log. The model's scenario knobs: `ClaimK = {1, 2, 4, 8, 16, 32}` (a claim's
units, as `chunk_units` doubles), `BatchMax = 17` (the batch pop's 1 + 16), `Breadth = FALSE`,
`TwoClasses = FALSE` (other classes' events are filtered by `cb`).

**Events** (hooks in `OGS`, compiled out unless `ECO_TLA_TRACE`, lines of 2026-09-29):

| Event | Hook (function, line) | Fields (beyond `t`, `ts`) | Model step (`Matched`) |
|---|---|---|---|
| `m4.begin` | `beginParallelPromotion` `:1452` | `cb`, `blk`, `u`; `rmw` the shared word | state check: `shared` is the header's |
| `m4.cur` | `cursorAllocateW` fast path `:1178`, scan `:1184` | `cb`, `blk`, `c`, `fast` | `W_Loop` / `W_R1` → `W_R1Set` with `cell` = the cell; `fast` ⇔ the cell is `pos` |
| `m4.set` | `finalizeBitmapCellW` `:1152` (after `setBit`) | `cb`, `blk`, `c` | `W_R1Set` on that cell |
| `m4.rph` | `finalizeBitmapCellW` `:1159` (the colour) | `black`; `rd` `phase`, `val` | `W_R1Ph`; `val` = `phase` |
| `m4.exh` | `cursorAllocateW` `:1189` (before `flushCursorW`) | `blk`, `flush` (cells) | `W_Loop` / `W_R1` → `W_Claim`; `chunkLive` = `flush` |
| `m4.claim` | `claimChunkW` `:1222` (the successful CAS) | `blk`, `u`, `units`, `lo`, `hi`; `rmw` `sh<cls>` | `W_Claim` → `W_R1`; `shared.u` + `units` |
| `m4.nclaim` | `claimChunkW` `:1207`, `:1216` (both `return false`) | `rd` `sh<cls>`, `val` | `W_Claim` → `W_Stash` / `W_Locked` |
| `m4.lock` | `allocatePromotion` `:1661` (large: `:1608`) | `cb`, `large`; `clk` `promo`, `tick` | `W_Stash` → `W_Locked` |
| `m4.unlock` | `allocatePromotion` `:1701` (large: `:1618`) | `clk` `promo`, `tick` | state check (the model released in the step before), or `W_StUnlock` after an in-lock finalize (CR-002) |
| `m4.pub` | `publishShared` `:1256` (after the release store) | `blk`; `rmw` `sh<cls>` | `W_Locked` (refill) or `W_Virgin` → `W_Claim`; `shared.b` |
| `m4.retire` | `advanceSharedW` `:1273` (after the relaxed store 0) | `blk`; `rmw` `sh<cls>` | state check: `W_Locked`, `shared.b` = `blk`, no claim possible |
| `m4.batch` | `allocatePromotion` (rung 2's batch pop, logged BEFORE an in-lock finalize) | `cnt` (1 + stashed), `blk`, `c` (the first), `inlock` (CR-002: finalized before the unlock) | `W_Locked` → `W_Fin`; `fin` = the cell; the list shrinks by `cnt`; the lock is still held iff `inlock` |
| `m4.ladder` | `ladderFrom2W` `:1384` | `pend`; `rd` `phase`, `val` | `W_Locked` → `W_Sweep` (`pend`) or `W_Virgin` |
| `m4.sw` | `lazySweep` `:5473` (an iteration), `:5542` (the trailing run at a block boundary) | `blk`, `rs`, `rb`, `l` (−1: none), `end` | `W_Sweep`: `Head(sweepQ)` has that `l`, `rs`, `rb`, end flag |
| `m4.clr` | `lazySweep` `:5476` (`clearBit`) | `blk`, `l` | `W_SweepClr` on that cell |
| `m4.swend` | `lazySweep`: path 2 `:5353` (in-loop completion), 1 `:5579` (early exit), 0 `:5589` (budget), 3 `:5595` (tail) | `path`, `par`; paths 2, 3: `rmw` `phase` | 2 and 3 (CR-014 fixed): `W_SweepEnd` → `Idle`, deferred; 0, 1: state check |
| `m4.npop` | `sweepOnDemandAllocate` `:2215`, `:2231`; `panicSweepAndRetryAllocation` `:2253` | `cb` | state check (a failed pop) |
| `m4.pop` | `finalizePoppedCell` `:2100` | `blk`, `c`, `black`; `rd` `phase`, `val` | `W_PopAfterSweep`: the list's head; colour = `phase` |
| `m4.fin` | `finalizePoppedCellW` `:1091`, `:1108` (the colour) | `blk`, `c`, `black`, `cnt` (the Idle `live_bytes` add ran: CR-018); `rd` `phase`, `val` | `W_Stash` / `W_Fin` on a stashed cell; not black: `cnt` = `IdleCounts` and `liveBytes` of its block rises by `cnt` |
| `m4.finb` | `finalizePoppedCellW` `:1103` (after `fetch_or` + `fetch_add`) | `blk`, `c` | `W_StBit` |
| `m4.merge` | `endParallelPromotion` `:1474` | `deferred` | `G_Join` |
| `m4.shreset` | `endParallelPromotion` `:1526` | `cb` | state check |
| `m4.split`, `m4.large`, `m4.rel`, `m4.shrink` | `ladderFrom2W` `:1381`, `tryAllocateFromFreeLists` `:2122`; `allocatePromotion` `:1617` (`flip` from `allocateFromEmptyRegularBlocks` `:2780`); `releaseBlockToAllocator` `:6129`; `onSweepComplete` `:5633` | | **not matched yet**: a log with one is rejected (no registered log has one) |

**Ordering** (the merger, `test/tla/trace/merge_trace.py`): `promo_mu_`'s ticks (`clk` `promo`,
incremented only under the lock); the shared word's modification order (`rmw` on `sh<cls>`:
`begin`, `claim`, `pub`, `retire`) and the reads of it (`rd`: `nclaim`); `gc_phase_`'s writes
(`rmw` `phase`: the completions) and reads (`rd`: `rph`, `fin`, `pop`, `ladder`). Write hooks log
after their stores, so a write's timestamp follows every reader that saw the old value. The
gang's `gang.*` events order the threads and are dropped after the merge.

**Hidden steps** (no event): `W_Loop` → `Done`; `W_Loop` with no cursor → `W_Claim`;
`W_Locked` when a claim is possible again (another worker published); `W_SweepEnd` when it is not
a completion; `W_PopAfterSweep` → `W_Virgin` (no cell of the class); `G_Shrink` when nothing was
deferred.

**`TraceRace.cfg`** (not a `traces.txt` row: its verdict depends on the schedule, and the runner
knows only accept and reject): `TracePromoBitmap.cfg` plus `NoRaceBitmap`, `NoRacePhase`,
`NoRaceLive`, `NoDoubleAlloc`, `ClaimsInRange`, `FreeBehindCursor`, `DetachNotCurrent`,
`ReleasedSafe` before `TLUnmatched`. "`TLUnmatched` is violated" means the whole log matched with
no race; another invariant violated means the real run did that.

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/MinorWork.hpp` | `-` |
| file | `runtime/src/allocator/BitmapScan.hpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| file | `test/gc-heap-tsan/promo_sweep.cpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.testAndSetMark` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.resolveMinorThreads` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.initObjectHeaderWithSize` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizeBitmapCell` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.resetAllocCursors` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.detachFromAllocation` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.flushCursorW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizePoppedCellW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizeBitmapCellW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.cursorAllocateW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.claimChunkW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.publishShared` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.advanceSharedW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.startVirginBlockShared` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.ladderFrom2W` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.sweepCompleteInPromotion` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.beginParallelPromotion` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.endParallelPromotion` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocatePromotion` |
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
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.markBitHelpers` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.kChunkUnitCells` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.tenureChunkCells` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.hasPendingSweepWork` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantTenure` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantAllocate` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantAllocateShared` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.returnTenureGrant` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.minorGC` |
| census | `runtime/src/allocator/AllocatorCommon.hpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.cpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.hpp` | `-` |
| census | `runtime/src/allocator/OldGenTenure.cpp` | `-` |
| grep | `-` | `H1` |
| grep | `-` | `H1b` |
| grep | `-` | `H2` |
| grep | `-` | `H9` |
| grep | `-` | `P6.M5` |
| grep | `-` | `P6.M6` |
| grep | `-` | `P6.M7` |
| grep | `-` | `P6.M9` |
| grep | `-` | `T5` |
| grep | `-` | `P6.M16` |
| grep | `-` | `F.gc_phase` |
| grep | `-` | `F.bitscan` |
| grep | `-` | `F.allocTenure` |
| grep | `-` | `F.parPromoActive` |
| grep | `-` | `F.promoMu` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.majorGCAndShrink` |
<!-- canary-pins end -->
