# M1 — the snapshot mark cycle: model ↔ code

The model is `SnapshotMark.tla` (PlusCal plus its committed translation). `MC.tla` holds the
starting heap. The plan is `plans/threaded-gc-tla-M1-snapshot-mark.md`, and its §2 explains the
protocol. **This file cites code, never plan text** (parent plan §12, trap 1).

Line numbers are for the tree of 2026-09-28 (post-7c). Functions are named too, because lines
drift. `OGS` = `runtime/src/allocator/OldGenSpace.cpp`; `TLH` = `ThreadLocalHeap.cpp`.

## 1. Variables

| Variable | Meaning | Code counterpart |
|---|---|---|
| `alloc` | allocated objects (an id outside it is a free cell) | live old-gen cells, nursery objects, YLOS cells |
| `gen[o]` | `"young"` / `"old"`. **Kept after a free**: a freed old cell is still an old-gen address | nursery or YLOS vs old gen |
| `age[o]` | minors survived while young (0..1; `promotion_age = 1`) | `Header.age` |
| `builder[o]` | under construction by a kernel | `Header.builder` |
| `fld[o][i]` | pointer fields | `HPointer` fields |
| `root[r]` | stack slots, RootSet, JIT roots, root ranges | `TLH::startMarkCycle` `:1090-1095` |
| `cell[c]` | off-heap mutable stores (CellStore cells and trail, MVar, scheduler queues) | external root scanners, `forEachMajorRoot` `kind == 2` (`TLH:1028`) |
| `mark[o]` | mark bit of an old-gen cell (old object or YLOS). All FALSE outside a cycle | `mark_.slot(id)` byte / `largeMark` |
| `grey` | every marker's grey entries (private stacks, deques, rings). Empty outside a cycle | `MarkWorker::stack`, the deques, the rings |
| `cycle` | `idle` / `marking` / `handoffDue` | `cycle_state_` (`CycleState`) |
| `k` | minor ends since t0 | `cycle_k_` (`noteCycleMinorEnd`) |
| `episode` | `none` / `running` / `finished` | `bg_ep_` (`BgEpisode`, `OldGenSpace.hpp:1026`) with the gang's `running()` folded in |
| `deferred` | dead young large objects waiting for the handoff | `deferred_frees_` (`OGS:7288`) |
| `zombie` | region mode: the dead objects of the extent handed over at the last minor | the Tenuring extent's unzapped dead objects |
| `minors`, `majors`, `ops`, `opsTotal`, `stops` | exploration bounds | — |
| ghosts `t0Old`, `t0Ylos`, `t0Reach`, `tSH`, `tNH` | the old set, YLOS cells, reachable old-gen cells (IM1's record) at t0; S_H; N_H | `cycle_t0_reach_` (validate builds); `cycle_t0_blocks_` |

## 2. Steps (A1: one label = one atomic step of the code)

| Label | Code | Why one step |
|---|---|---|
| `M_Choose` (each branch) | one Elm or kernel operation between statepoints | one mutator operation; a load reads a field of an immutable or owned object; the P1-violating write (mutant) is one store |
| `P_Minor` | `NurserySpace::minorGC` / `minorGCRegion`, with `sweepNurseryLargeBodies` (`OGS:7210`) | object-level footprint disjoint from the markers', checked in every state by `MarkerFootprint`; shared metadata delegated (§4) |
| `P_Handoff`, `H_Free` | `TLH::stepMarkCycle` `:1145-1147` → `completeMarkCycle` `:1191` (IM1 `:1194`, IM2 `:1199`) → `OGS::handoffMarkCycle` `:4258` → `runPostMarkTail` (called `:4305`) with `classifyBlocksAfterMark` (called `:3988`; `retireDeadLargeBodies` `:1657`) and `processDeferredFrees` (called `:3953`) | no marker runs at the handoff (`IM9`); the checks are invariants on the state where `pc = "H_Free"` |
| `P_Marking` | `noteCycleMinorEnd` (`TLH:1144`), `cyclePressureFinishDue` (`:1149`, before the step, any `k`), then `OGS::runCycleStepConcurrent` `:4660`: `reapBackground` / relaunch `:4688-4699` | mutator-only state plus the reap's acquire load of the episode |
| `P_Decide` | the `k >= T` branch (`:4700-4706`), the paced assist (`:4707-4744`) | a decision with no shared reads (IM16) |
| `P_Closing`, `P_Closing2` | `closingFinish` `:4569` (ends `bg_ep_ = None`, `:4635`) → `cycle_state_ = HandoffDue` | a drain loop, then one assignment |
| `P_Pressure`, `P_Pressure2` | `TLH::finishMarkCycleNow(Pressure)` `:1178` → `drainCycleMark` `OGS:4195` → `completeMarkCycle` | |
| `P_Trigger` | `evaluateMajorGCTrigger` (called from `TLH::minorGC`) | a decision |
| `P_T0` | `TLH::startMarkCycle` `:1065`: `beginMarkCycle` (`OGS:4084`, clears marks `:4091`), roots and stores, `snapshotYoungLarge` (`OGS:4173`), the young walk `nursery_.forEachYoung(... markChildren ...)` (`TLH:1102`; `NurserySpace.hpp:800`) | the mutator is stopped and no marker runs yet (IM14, `assertSlotsQuiescent("launch")`) |
| `P_Sync` | `afterSnapshot` `OGS:4649` with `conc_mark = 1` | drain loop |
| `D_Loop`, `A_Loop` | `closingEntry` / `assistEntry` members scanning (M2); `runMarkers` for a stopped episode or a 5b slice. `A_Loop` may stop early with grey entries left: an Assist leaves when it finds no work it can take (`runMarkerLoop`, `MarkWork.hpp:461-462`, "never idles: leave"), or scans nothing when it joins a stopped control (trace validation, AUDIT.md 2026-09-29) | one scan per step |
| `D_Done` | the end of `closingFinish`: `bg_ep_ = None` | mutator-only |
| `J_Join`, `J_Handoff`, `J_STW` | `TLH::majorGC` `:783`: tenure join (`:791`), `finishMarkCycleNow(Join)` (`:797`), then the STW mark (`OGS::startMark` `:2867`, marks nursery objects from roots only) and sweep, then in region mode (CR-017, HEAP_074, 2026-09-30) `NurserySpace::zapDeadAfterMajor` (region `NR.zapDeadAfterMajor`): every survivor of a Young extent the mark did not reach (`nursery_visited_`) becomes a `Tag_Free` filler = `J_STW`'s `zap` (`YoungObjs \ Live`, age 1, not a YLOS: freed and scrubbed; mutant `no_cr017_fix`) | the STW part runs with everything stopped |
| `K_Loop` | a background member (`bgEntry` `OGS:4404` → `runMarkerLoop` → `scanEntry` / `scanObject` `:3448` / `:3367`, which skips `Tag_Free` at `:3374`), or its termination (the done-CAS, with the reap's `Finished`) | one scan per step (§3) |
| `F_Loop` | `GCBackgroundGang::stopAllForFork` (`GCHelperPool.cpp:650`) → `stopAndJoin`, plus the mutator's next reap to `None` (`OGS:4524`); since register-fixes Phase 5 also a launch REFUSED under a fork's hold (`launchBackground` leaves `bg_ep_ = None`: an episode stopped at once) | one store of `stop`, as M2 sees it; the reap is folded in (§3) |

Allocate-black sites: `initObjectHeaderWithSize` `OGS:487` (the cycle branch `:497`),
`finalizeBitmapCell` `:802`, `finalizePoppedCellW` `:1069`, `finalizeBitmapCellW` `:1121`,
`grantAllocate` `OldGenTenure.cpp:153`; in the model, the promotion's mark in `P_Minor` and the YLOS
allocation's mark in `M_Choose`. Young large objects are allocated through the same allocator
(`allocateYoungLarge`, `OGS:7077`) and promoted in place, keeping their t0 mark
(`promoteYoungLarge`, `OGS:7107`, which touches only the index and `Header.age`).

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| objects with tags, sizes, unboxed fields | ids with one pointer field (`Fields = {1}`; deep: `{1, 2}`) | only the pointer graph matters for reachability |
| minor-GC copying | the same id; `gen` changes on promotion | a minor preserves identity (parallel-gc.md §2.1) |
| the minor GC, running while background markers run | one step (`P_Minor`) | its **object-level** footprint (young objects, roots, promotions into post-t0 cells, the YLOS index, `deferred_frees_`) is disjoint from the markers' (t0-old objects and their mark bits). `MarkerFootprint` checks that in every state. The **metadata** both touch is delegated: mark bytes shared by allocate-black and a marker's test-and-set (M4, W3), block and page-index publication (W4), `live_bytes` |
| B background and F foreground markers | one `Marker` process plus the pause's `DrainAll`/`Assist`, each scanning one grey object per step | (1) **M2's Drain contract** (`ScanOnce ∧ TerminationSafe ∧ Drain`): each grey entry is scanned once, and a run ends only when no entry is left anywhere. (2) **M1's own argument for the atomic scan**: a scanned t0-old object's fields do not change during the cycle (P1); marks only go from 0 to 1 until the handoff; the per-child test-and-set is an atomic RMW; and no modelled mutator step reads a t0 block's mark bit or a grey entry. So every interleaving of partial scans reaches the marked set of some sequence of whole scans. Under `p1_violation` the write still lands before or after a whole scan, which is all timeline (a) needs |
| mark bits in bytes shared by 8 slots | **one Boolean per object** | byte sharing, plain vs atomic RMW, and cursor ownership (IM13) are **M4's** (its BitFaithful contract). Nothing in M1 covers them |
| blocks, cursors, the page index | not modelled | IM13 and block publication are M4 / W4; M1's allocate-black is "the promoted object's bit is set in its promotion step" |
| every root kind | `RootSlots` | all are read in the same t0 pause and never after |
| external root scanners | `CellSlots` | off-heap, overwritable at any time, read at t0 (HEAP_SNAPSHOT_002) |
| `promotion_age = 1`; builders never aged or promoted | `age ∈ 0..1` | HEAP_BUILDER_001/002; PM5 |
| pacing (assist, pressure) | nondeterministic choices | every real schedule is a model schedule; the fixed schedule (handoff at minor t0 + T + 1) is kept exactly |
| old garbage collected before the cycle | only by `MajorPause`'s STW step (which also frees unreachable YLOS cells) | adds nothing to the snapshot argument, except in region mode, where it is what leaves a zombie's field dangling (CR-017) |
| a freed id reused | allowed | `NoLostObject` is checked in every state, so a wrongful free is caught before any reuse |
| a freed **old-gen cell** reused by a different object at the same address (ABA audit, 2026-09-29) | a configuration with the old id 4 in `YlosIds` (`MC_quick_reuse`, `MC_quick_region_reuse*`): the mutator's `alloc` may then give 4 to a young large object, the one mutator allocation that lands in an old-gen cell | the code hands a freed cell out again through the mixed free lists at any time, during a cycle too: `allocateFromSizeClassBitmap` rungs 2 and 4 (`tryPopFromFreeList`, `tryAllocateBySplittingLarger`, `OGS:973-994`), `allocateFromBagPage` step 1 (`OGS:2581`); `prepareMark` does not clear the free lists at t0. With 4 outside `YlosIds` the model still reuses 4, as a nursery object (not faithful to addresses, harmless to `NoLostObject`). A promotion into a freed cell (a copy of a *different* object) is not expressible: a promotion keeps its id. The structures that remember an id across a free (`deferred`, `t0Ylos`, `grey`, `zombie`) are exactly the code's `deferred_frees_`, `mark_view_.ylos_t0`, the grey entries and the unzapped hand-over extent |
| `bg_ep_` and the gang's `running()` | one variable `episode` | the fork hook's `stopAndJoin` and the next reap (`done == false` → `None`) are one `Forker` step. In between, the code's `bg_ep_` is still `Running` with no member running, and the code's assist scans nothing; the model's `Assist` may scan there or stop at once. Scanning over-approximates marking progress, and the closing drain empties the grey set either way |
| 5b in-pause slices (`conc_mark = 0`) | not a separate mode | a slice is `Assist` with no background episode: every slices-mode behaviour is a concurrent-mode behaviour in which `Marker` never steps |
| region mode (`nursery_regions = 1`, k = 1) | `RegionMode`: `P_Minor` keeps dead age-1 objects as `zombie`s for one minor; `P_T0` walks them | exactly the code's window: the Tenuring extent's dead objects are not zapped before t0 (only 07b's ageing extents are, `mergeJob` `NurseryTenure.cpp:816-825`), and `forEachYoung` skips only `Tag_Free`. Since CR-017's fix (HEAP_074) a STW major zaps the dead age-1 objects (`J_STW`), so a zombie's old child was never freed by a major: zombies are the objects dead at the hand-over minor, whose children the major after it cannot free before that minor's t0. Live hand-over objects are promoted in `P_Minor`, one minor early and black; a 7c copy is black too (`grantAllocate`). **The tenure job itself is assumed disjoint from the markers: M5's TenureDisjoint contract** (`HealYoungOnly`, `MarkerDisjoint`, `YoungWalkValid`) |
| dead state | every free resets the freed id's fields, age, builder flag and mark; `mark` and `grey` are cleared outside a cycle | primer §4.2: nothing on a correct path reads them. `gen` is kept (see above) |

## 4. Footprint rows (A3)

| Row (05c P§3.6 unless noted) | Model |
|---|---|
| H1 mark bytes of t0 blocks | `mark` (one bit per object; bytes are M4's) |
| H1b post-t0 blocks | promotions and YLOS allocations are black and never grey (`MarkerFootprint`) |
| H2 mark bytes read by mutator validators | not modelled: validators are checks, not protocol steps. Their mid-cycle reads are `isMarkedInBlockRelaxed` (relaxed `atomic_ref` loads, so no data race), and IM6 mid-cycle runs only when no episode runs (05c P§3.9) |
| H3 `PageOwners.primary/secondary`, H4 `ReservedArray::committed_` | not modelled (blocks and the page index are abstracted away, §3): publishing a new block and its page-index entry to a marker's `blockIdFor` is W4 (`w4_publication`, `w4_commit`: PASS) |
| H5 region bounds, H9 block identity | abstracted by IM5 (`NoReleaseInCycle`); publication is W4 |
| H15 `config_`, `allocator_ref_`, `heap_base`/`heap_reserved`, `index_base_` | constants of the model (read-only after init; the canary's `grep` pin `H15` fires on a new `index_base_ =`) |
| H6/H8 MarkView, YLOS at t0 | `gen`, `t0Ylos` |
| H7 `cycle_state_` | `cycle` |
| H10/H13 slots | the Drain contract (M2) |
| H11 `alloc_stats_`, H12 test hooks | not modelled: statistics merged only after a join, and test hooks written only while no episode runs (M2 covers both as footprint rows) |
| H14 S_H fields | `fld`, frozen on t0-old objects unless `p1_violation` |
| `deferred_frees_` | `deferred` |
| every root kind, every external scanner | `root`, `cell` |
| `Header.builder` | `builder` |
| `bg_ep_` | `episode` |
| 07 P§3.17 T-rows (region mode) | `zombie` for the walk; the rest is M5's (TenureDisjoint) |

## 5. Invariants (A7)

| Invariant | Id | Where the code checks it |
|---|---|---|
| `NoLostObject` | MODEL_M1_1 | — (the loss itself) |
| `IM1` (at `H_Free`) | IM1 | `traceOldReachableForValidation`, `TLH:1291`, at `completeMarkCycle` `:1194` |
| `IM2` (at `H_Free`) | IM2 | `assertAllMarked`, `OGS:4792`, at `:1199` |
| `IM9` (at `H_Free`) | IM9, IM14 | `markStackEmpty` asserts in `handoffMarkCycle` (`OGS:4260`) |
| `MarkerFootprint` | IM3 (+ the one-step-minor premise) | `greyObject`'s young abort, `OGS:3094` |
| `MarkerNoYoungKid` | MODEL_M1_2 (`MarkerFootprint`'s second conjunct, named on its own, 2026-09-29) | the every-build aborts of a parallel marker that reaches or scans a young object: `greyObject<ParallelMark>` `OGS:3310-3313`, `scanObject<ParallelMark>` `OGS:3615-3617` (tree of 2026-09-29) |
| `NoReleaseInCycle` | IM5 | the `!cycleActive()` asserts: `freeLargeBodyCell` `OGS:7316`, `releaseBlockToAllocator` `:5995`, `:6136`, `:6416`, `:6490`; the validate re-check `checkT0BlocksUnchanged` / `t0BlocksChangedWhy` keys on (id, BlockTable generation, start, class, is_large) since 2026-09-30 (CR-036), so a release and same-id re-issue inside a cycle is caught too (the model's `NoReleaseInCycle` already forbids the release itself: no state change) |
| `NoOldToYoung` | HEAP_005 | PM5 (`NurseryParallel.cpp:276-286`) |
| `SnapshotClosure` | the parallel-gc.md §2.1 lemma | — |
| `DeferredOK` | IM8 (model form) | — |

## 6. Contracts assumed (parent plan §5.0)

- **Drain** (M2) and M1's own atomic-scan argument (§3).
- **LaunchJoin** (M6): launch and join publish the pause's and members' writes; `running()` is
  exact on the mutator.
- **TenureDisjoint** (M5), for region mode.
- **BitFaithful** (M4): one bit per object is faithful to the code's bytes.

M1 provides **SnapshotCycle**: `IM2` at `H_Free`, `NoReleaseInCycle` and `MarkerFootprint`. In
region mode `MarkerFootprint` failed until CR-017 was fixed (2026-09-30, HEAP_074: `MC_quick_region.cfg` and
`MC_quick_region_reuse.cfg` now pass every invariant; the pre-fix code is `mutants/no_cr017_fix{,_reuse}`).

## 7. Weak memory (A4)

The model is sequentially consistent. It relies on W3 (allocate-black's `fetch_or` against a
marker's `fetch_or` on one byte) and W4 (publication of new blocks and page-index entries to the
markers); the t0-to-marker handoff of the grey set and the join back are LaunchJoin (mutex
release/acquire).

| What M1 assumes under SC | Code | Companion | Status (2026-09-28, `test/genmc/AUDIT.md`) |
|---|---|---|---|
| allocate-black's `fetch_or` and a marker's test-and-set on one mark byte both land | `setMarkBitAtomic`, `testAndSetMark`'s parallel branch | W3a | PASS |
| a promotion cursor never sets a plain bit in a byte a marker owns (IM13) | `finalizeBitmapCell`, the cursor paths | W3b (`CURSOR_ON_T0_BYTE` is flagged) | PASS |
| chunks own whole 64-bit bitmap words, which the word-reading scans need | `tenureChunkCells`, `kChunkUnitCells` | W3e (`SMALL_CHUNK`, `BYTE_CHUNK` are flagged) | PASS |
| a new block and its page-index entry are published to a marker's `blockIdFor` by the owner word's release store | `materializeBlock`, `assignPageIndexForBlock`, `blockIdFor`, `storeOwner`/`loadOwner` | W4, W4b | PASS. IM5 (no release during a cycle) and HEAP_049 (commit before use) are premises W4 takes, not checks |
| the grey set handed to the markers at t0, and the join back | the gang's launch/join | M6 LaunchJoin (a mutex); `w_running_chain` for the orphan test | M6 |

## 8. Differences from the plan's sketch (all recorded in AUDIT.md)

- `IsBuilder(v)`: the builder-write guard `root[r2] = Nil \/ ~builder[root[r2]]` made TLC apply
  `builder` to `Nil`. TLC evaluates both disjuncts of an action to enumerate successors.
- Dead-state hygiene: frees scrub the freed id; marks and greys are cleared outside a cycle.
- `MaxTotalOps` and `Ops` (the explored operation kinds): the state-space levers. Every quick
  configuration enables every kind with two operations per run. Each mutant enables only what its
  story needs, which is sound for a negative control.
- `ReachIn`: an early-stopping `RECURSIVE` fixpoint (TLC only) instead of the `|Obj|`-round
  recursive function. It computes the same sets, about four times faster.
- Two mutants added so that every invariant has one (A6): `p1_violation_live` (`NoLostObject`) and
  `defer_live_ylos` (`DeferredOK`).
- `A_Loop` may stop early (2026-09-29, found by trace validation): the sketch's assist had to scan
  while any grey entry was left, which the code's assist does not.
- ABA audit (2026-09-29, AUDIT.md): the invariant `MarkerNoYoungKid`; the mutant `defer_released`
  (`P_Minor` releases a deferred cell at once but keeps it on the deferred list, so `H_Free` frees
  whatever occupies the id by then; the code keeps it allocated until `processDeferredFrees`,
  `OGS:5077`); the configurations `MC_quick_reuse`, `MC_quick_region_reuse` and
  `MC_quick_region_reuse_live` (old id 4 in `YlosIds`, §3).

## 9. SnapshotLemma.tla (the unbounded lemma) ↔ SnapshotMark.tla

`SnapshotLemma.tla` restates the model's heap actions without `pc`, for Apalache. Its actions
cover every heap-changing step of the model, in legacy mode, without mutants:

| Lemma action | Model steps |
|---|---|
| `Load`, `Drop`, `CellW`, `CellR`, `Alloc`, `BAlloc`, `BWrite`, `BClear` | the `M_Choose` branches |
| `MinorIdle` | `P_Minor` with the cycle idle, then `P_Trigger` returning |
| `MinorT0` | `P_Minor`, then `P_T0`: one action, as the code runs t0 at the end of its minor |
| `MinorCycle` | `P_Minor` during a cycle; the step's decisions (`P_Marking`, `P_Decide`) change no heap state |
| `Scan` | every scan: `K_Loop`, `D_Loop`, `A_Loop` |
| `Closing` | `P_Closing2` after the drain |
| `Handoff` | `H_Free`, from `P_Handoff`, `P_Pressure2` or `J_Handoff` |
| `MajorIdle` | `J_STW` with the cycle idle (a major during a cycle joins: `Handoff`, then `MajorIdle`) |

Left out:
- `episode`, the fork stop and `k`: they decide who scans and when the handoff comes. In the lemma,
  any scan and any handoff with an empty grey set are enabled at any time;
- `SyncMark`: the whole mark inside the pause is a special schedule of `Scan`;
- region mode: CR-017 broke it (fixed by HEAP_074; the lemma has not been extended to region mode);
- the mutants, except `P1Write` (the lemma's negative control, outside `Next`).

The lemma's `Next` therefore allows more interleavings than the model: the mutator may act between
a pause's inner steps. That is sound for an inductive invariant.

The invariant `LemmaInv` (plan §4.7) holds the model's `NoLostObject`, `SnapshotClosure` and
`DeferredOK`, plus the strengthening that makes it inductive: `IdleClean`, `BuilderYoung`,
`YlosShapes`, `AgeOrder` (live objects only), `OldClosed`, `FieldsFrozen` (P1), `T0OldStays`
(IM5), `OldSHClosed`, `GreyInSH`, `GreysMarked`, `HandoffEmpty`, `NewOldBlack` (allocate-black),
`YlosBlack`, `KidsCovered` and `WhiteReachable` (the tri-colour invariant). `LemmaImpliesIM2`
derives IM2 from it.

## 10. Trace validation (A5)

Two traces, both from the real allocator (`test/gc-heap-tsan`, trace build `gc-heap-trace`; rows in
`test/tla/traces.txt`; how it works: `test/tla/README.md`, "Trace validation"). Results and
findings: AUDIT.md, 2026-09-29.

**Hooks** (`ECO_TLA_TRACE`, compiled out unless `-DECO_TLA_TRACE=1`; tree of 2026-09-29).
`TLH` = `ThreadLocalHeap.cpp`, `OGS` = `OldGenSpace.cpp`, `GHP` = `GCHelperPool.cpp`.

| Event | Hook (function, line) | Fields | (a) `TraceCycle` | (b) `TraceHeap` |
|---|---|---|---|---|
| `minor` | `TLH::minorGC` entry `:714` | `cyc` | `P_Minor` | `P_Minor` |
| `major` | `TLH::majorGC` entry `:790` | `cyc` | `J_Join` (`cyc = CycleOn`) | same |
| `t0` | `TLH::startMarkCycle`, after `beginMarkCycle` `:1085` | `T` | `P_T0` (`T` checked) | same; the snapshot's `grey`s follow |
| `t0end` | `TLH::startMarkCycle`, before `afterSnapshot` `:1129` | `greys` (mark stack size; no marker runs, IM14) | check: marking, `k = 0` | check: `Cardinality(grey) = greys` |
| `launch` | `OGS::launchBackground`, before `bg_->launch` `:4483` | `gang` | check: after t0 `episode = "running"`, in a step `"none"` and the step follows; records the marking gang | same |
| `relaunch` | `OGS::runCycleStepConcurrent`, relaunch branch `:4711` | — | check: at `P_Marking`, `episode = "none"` | same |
| `reap` | `OGS::reapBackground`, after the join `:4530` | `done`, `wait` | check: `done` ⇒ `"finished"`, else `"none"`; at `P_Marking` only before `step`/`relaunch` (never before a pressure finish) | same |
| `step` | `OGS::runCycleStepConcurrent`, after the reap/relaunch block `:4722` | `k`, `ep` | `P_Marking` (reap branch), `k' = k`, `episode' = ep` | same |
| `pressure` / `join` / `finish` | `TLH::finishMarkCycleNow` entry `:1186` | `marking` | `pressure`: `P_Marking` (pressure branch); `join`: check (a cycle runs) | same |
| `assist` | `OGS::assistEpisode`, end `:4580` | `units` | `A_Done` | same |
| `closing` | `OGS::closingFinish`, end, after `bg_ep_ = None` `:4655` | `units`, `work` | `D_Done` while marking (a join after the closing drains nothing: `D_Done` hidden) | same |
| `handoff` | `TLH::completeMarkCycle`, after `handoffMarkCycle` `:1230` | `k`, `why` | `H_Free`; `schedule`: `k = T + 1` (the handoff minor's `k++`), else `k` | same |
| `stop` | `GCBackgroundGang::stopAllForFork`, after `stopAndJoin` (`GHP:673`); and (register-fixes Phase 5) right after a refused t0 launch (`afterSnapshot`) or after the `step` of a refused relaunch (whose `ep` is then logged `running`, field `refused`) | `gang` | the marking gang with `episode = "running"`: `F_Loop`; otherwise (another gang, or an episode that already finished) a no-op | same |
| `grey` | `OGS::greyObject`, a newly set bit during a cycle `:3150` (key: cycle serial bound in `beginMarkCycle` `:4153`) | `obj`, `put` | — | check: a marked old object |
| `scan` | `OGS::scanEntry`, during a cycle `:3466` | `obj`, `get` | — | background member: `K_Loop`; `mut` or a foreground member: `A_Loop` / `D_Loop`; the object must be grey |
| probe `tail` → `marks` | `OGS::runPostMarkTail` entry `:3960` (a harness callback) | `where`, `marked` | — | `handoff`: at `H_Free`, the marked old objects = the model's; `stw`: at `J_STW`, = `Live ∩ CellObjs` |
| `gang.*` | `GHP`: `GCMarkGang::run`, its member loop, `GCBackgroundGang::launch`, its member loop, `joinLocked` | `gang`, `gen`, `put`/`get` | (not recorded) | ordering only, dropped after the merge |

The driver logs `load`, `drop`, `cellw`, `cellr`, `alloc` (each one `M_Choose` branch, with the
result checked) and, after every collection, `heap` (the allocated old and young ids, checked at
`M_Loop`).

**(a) The projection.** M1's own `Next` runs on MC.tla's four objects with `Ops = {}`. The trace
constrains the pause kinds and their order, `k`, `T`, the episode after every step and before
every reap, and the two mapping rules (stop + reap = one `F_Loop`; pressure before any reap or
relaunch of its pause). The scans, the background termination and how much an assist scans are
hidden, so the data-dependent choices (relaunch or finished after a stop, early done) are free:
the model's t0 grey set is never empty, and hidden scans may empty it or not. One thread, matched
in log order (`TraceInOrder`).

**(b) The tiny graph.** At most 8 objects (Tuple2: one pointer field, the id unboxed), two roots,
one external root scanner as `c1`. Every event is a matched model step or a check on the model's
state; hidden are the mutator's control steps, logged decisions, loop exits, `J_STW` and the
background termination. Matched in any order the log's happens-before allows (`TraceAnyOrder`):
the gang events and the grey → scan keys order the members' threads against the mutator.

**Not traced:** allocate-black itself (its effect is checked: a promotion not marked would be
freed at the handoff, and `marks`/`heap` would differ from the model); mark-byte ordering (a
`grey` logs no byte value: M1's steps on different objects commute, and bytes are M4's); region
mode and YLOS objects in (b) (region mode is in (a) only, `region-b2`; CR-017 is M1's
`quick_region`); builders; the pressure finish in (b).

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/ReservedArray.hpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| file | `test/gc-heap-tsan/tiny_graph.cpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.beginMarkCycle` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.snapshotYoungLarge` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.afterSnapshot` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.launchBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.reapBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.runCycleStepConcurrent` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.assistEpisode` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.closingFinish` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.drainCycleMark` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.handoffMarkCycle` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.greyObject` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.scanObject` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.scanEntry` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.testAndSetMark` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.retireDeadLargeBodies` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.classifyBlocksAfterMark` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.sweepNurseryLargeBodies` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.freeLargeBodyCell` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.promoteYoungLarge` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.initObjectHeaderWithSize` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizeBitmapCell` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizePoppedCellW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.finalizeBitmapCellW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.releaseBlockToAllocator` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.releaseUnassignedBlockToAllocator` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.regionAndOwnerAccessors` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.markBitHelpers` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantAllocate` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantAllocateShared` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.minorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.majorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.majorGCAndShrink` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.startMarkCycle` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.stepMarkCycle` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.finishMarkCycleNow` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.completeMarkCycle` |
| region | `runtime/src/allocator/NurserySpace.hpp` | `NSH.forEachYoung` |
| region | `runtime/src/allocator/NurserySpace.hpp` | `NSH.forEachSurvivor` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.minorGCRegion` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.mergeJob` |
| census | `runtime/src/allocator/OldGenSpace.cpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.hpp` | `-` |
| census | `runtime/src/allocator/OldGenTenure.cpp` | `-` |
| census | `runtime/src/allocator/P1Census.cpp` | `-` |
| census | `runtime/src/allocator/PermanentSpace.cpp` | `-` |
| census | `runtime/src/allocator/PermanentSpace.hpp` | `-` |
| census | `runtime/src/allocator/RootSet.hpp` | `-` |
| census | `runtime/src/allocator/RuntimeExports.cpp` | `-` |
| grep | `-` | `H1` |
| grep | `-` | `H1b` |
| grep | `-` | `H2` |
| grep | `-` | `H3` |
| grep | `-` | `H4` |
| grep | `-` | `H5` |
| grep | `-` | `H6` |
| grep | `-` | `H7` |
| grep | `-` | `H8` |
| grep | `-` | `H9` |
| grep | `-` | `H10` |
| grep | `-` | `H13` |
| grep | `-` | `H15` |
| grep | `-` | `F.deferredFrees` |
| grep | `-` | `F.cycleState` |
| grep | `-` | `F.bgEp` |
| grep | `-` | `F.externalRoots` |
| grep | `-` | `F.zapFiller` |
| grep | `-` | `F.vnodeRegistry` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.zapDeadAfterMajor` |
<!-- canary-pins end -->
