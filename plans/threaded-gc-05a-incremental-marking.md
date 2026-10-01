# Threaded GC 05a — Incremental marking on the mutator thread (the snapshot protocol)

**Status:** DONE (2026-09-26), **default-on with T = 32**. Written against the `keep-TG4b` tree
(`bin/eco-opt-prev` = `eco-optTG4b`); as-built record in P§10.

**Parent:** `plans/threaded-gc-master-plan.md`, phase 5a.

**Scope of "phase 5".** Phase 5 has three sub-phases: 5a (this plan), 5b (parallel marking) and
5c (concurrent marking on collector threads). The master plan's rule is that each phase's work
plan is written when that phase is about to be implemented, against the tree as it is then. This
plan therefore covers **5a only**, to implementation level. It also fixes the contract 5a leaves
for 5b and 5c (P§9), because the master plan's phase-5 rule ("write every marker as if the world
were running") binds 5a's design choices now.

**Background:**
- `design_docs/parallel-gc.md` §2.1 (the snapshot-closure lemma), §2.2 (the mutation surface
  M1–M7), §4 (incremental marking), §5.1–5.5 (snapshot point, the nursery at t0, allocate-black,
  what must change, handoff), §11.2 (HEAP_SNAPSHOT_002);
- TG2 (bitmap allocation: a uniform block's mark bitmap *is* its allocation map, HEAP_054);
- TG4 (P1 holds and is enforced in validate builds, HEAP_SNAPSHOT_001);
- TG4b (the young generation is the nursery plus the YLOS, HEAP_005 strict, HEAP_062).

§n points into `design_docs/parallel-gc.md`, P§n into this plan, M§n into the master plan.

---

## 0. What this phase delivers, and why

**Today.** A major GC marks the whole old gen inside one pause. `ThreadLocalHeap::majorGC` pushes
the roots, and `OldGenSpace::finishMarkAndSweep` loops `incrementalMark(1000)` until the mark
stack is empty, then runs the post-mark tail (finalize, demote, reclaim, shrink, classify, first
sweep slice). The marker traces *through* nursery objects (deduplicated by the
`nursery_visited_` hash set) because the mutator is stopped and nothing moves. The last major of
the self-compile is a ~5.2 s pause (TG3 triple median). It is the worst pause in the system by a
factor of ~30.

**This phase** spreads the mark over the minor-GC pauses that follow the trigger:

1. **t0 — the snapshot.** At the end of the minor GC that fires the major trigger, the mutator
   is stopped with exact roots and an empty from-space apart from the survivor prefix. In that
   pause the collector:
   - greys the old-gen targets of every root: stack-map slots, root ranges, single roots, the
     long-lived `RootSet` roots, JIT roots, and every external root scanner (CellStore cells and
     trail, MVar, scheduler, platform);
   - walks **every young object** (the nursery's contiguous survivor prefix and every YLOS
     object) once and greys its old-gen children;
   - marks every YLOS cell itself.

   After t0 the marker never looks at a young object again, and never re-reads a root.
2. **Slices.** At the end of each of the next T minor GCs, the mutator runs a bounded amount of
   mark work (a slice) on the old gen. Old-gen objects allocated during the cycle (promotions,
   large objects, bodies, permanent objects) are **allocated black**. The T-th slice is the
   *closing slice*: it drains whatever is left.
3. **Handoff.** At the minor after the closing slice, the mutator runs today's post-mark tail
   unchanged. Releases, frees and reuse of pre-t0 memory happen only here.

Nothing needs a write barrier or a remark: P1 (HEAP_SNAPSHOT_001) plus the lemma (§2.1) mean
every object reachable at any instant after t0 is either reachable at t0 (and therefore marked
by the marker) or allocated after t0 (and therefore black). P§3.3 gives the argument case by
case.

**Why it is worth building even though it cannot reduce wall time** (§4):
- It turns the ~5 s major pause into one t0 pause (a root scan plus a young-generation walk,
  estimated ≲ 30 ms) plus T slices of roughly `mark_time / T` each, plus a handoff tail.
- It exercises, single-threaded and deterministically, every invariant concurrent marking (5c)
  needs: the t0 snapshot, allocate-black, deferred frees, cycles spanning many minors, metadata
  growth mid-cycle, the handoff. Every bug reproduces exactly.

| # | Deliverable |
|---|---|
| D0 | Re-verified facts (P§2) and a baseline: `eco-optTG4b` counters, pause distribution and old-gen peak, same session |
| D1 | Pure refactor, counters bit-identical: `ThreadLocalHeap::forEachMajorRoot` (one root enumeration shared by `majorGC` and the cycle start) and `OldGenSpace::runPostMarkTail` (one post-mark tail replacing the four copies in the `finishMarkAndSweep` overloads) |
| D2 | Configuration: `incremental_mark` (default **off**) and three tuning knobs, with JSON keys and `validate` rules (P§3.11) |
| D3 | The t0 snapshot: snapshot mode in `pushMarkRoot`, `NurserySpace::forEachSurvivor`, the YLOS loop, `OldGenSpace::beginMarkCycle` (P§3.2) |
| D4 | The cycle: state machine, fixed schedule, paced slices, closing slice, handoff, trigger suppression (P§3.1, P§3.5, P§3.6, P§3.8) |
| D5 | Allocation during a cycle: allocate-black on every old-gen entry point; no reuse of pre-t0 uniform-block free cells (P§3.4) |
| D6 | Deferred frees (M5): nursery-owned bodies and YLOS objects that die during a cycle are freed at the handoff (P§3.7) |
| D7 | Joins and emergency finishes: any `majorGC()` call during a cycle finishes it first; old-gen pressure finishes it early (P§3.8) |
| D8 | Validators IM1–IM9 in the validate tree (P§3.13), with negative controls |
| D9 | Stats: cycle counters, pause kinds 3/4/5, an event-log `cycle` row, banner lines, the summary script (P§3.12) |
| D10 | Tests, experiments E0–E3, gates, invariants, docs, tracking row; flag flipped default-on or the phase closed (P§4–P§8) |

**Out of scope:**
- threads of any kind (5b, 5c);
- heap-relative pacing of the *trigger* (starting the cycle earlier so it finishes by today's
  trigger point): 5c. 5a keeps today's trigger and measures the retention cost (E1);
- making the handoff tail itself incremental (classify, reclaim, shrink): measured in E1, a
  later item if it becomes the worst pause;
- compaction under a cycle: compaction has no production caller; it is asserted idle;
- the legacy allocator (`old_gen_bitmap_alloc = false`): `incremental_mark` requires bitmap
  allocation, and `validate` rejects the combination;
- large-array chunking of mark work: 5b.

---

## 1. Ground rules

1. **Flag-off is bit-identical.** With `incremental_mark = false` every GC counter, the major
   event log (except timing columns) and `out.mlir` are identical to `eco-optTG4b`. D1 is a
   pure refactor judged by the same rule.
2. **`incremental_mark_slices = 0` is the equivalence arm.** With the flag on and T = 0, the
   whole cycle (snapshot, drain, handoff) runs inside the t0 pause. Every GC **decision**
   counter (minors, majors, promoted and copied objects and bytes, allocated, live bytes per
   major, old-gen peak, releases) must equal flag-off. The only expected differences are the
   mark-unit counts (the snapshot does not push nursery objects onto the mark stack), the
   mark-stack peak, and the pause-kind split. E0 checks this; any other difference is a bug in
   the snapshot.
3. **T ≥ 1 is a deliberate policy change** (M§2 counter discipline): reclamation happens T + 1
   minors later than today, and allocate-black retains in-cycle promotions until the next
   cycle. Re-baseline the counters, and **gate on the old-gen peak before reading wall time**
   (M§2 retention gate).
4. **Deterministic by construction.** Every decision (when a cycle starts, how much each slice
   does, when it closes, when the handoff runs, when an emergency finish fires) is a function
   of mutator allocation and of state observed at a minor-GC end. None depends on time. This is
   GC_DET_001, and it is what lets 5b and 5c reproduce 5a's counters exactly (P§9).
5. **Write the marker as if the world were running** (M§3 phase-5 rule). After t0 the marker
   reads only the old-gen objects reachable from the snapshot, the page index, `BlockInfo` of
   blocks that existed at t0, and its own state. It never reads a root, a young object, a free
   list, a cursor, a queue, `unassigned_blocks_`, or the large-body index. P§3.10 lists every
   structure it touches. A slice that relied on anything else would have to be rewritten for
   5c.
6. **Nothing that existed at t0 is released, freed, reused or re-parsed until the handoff**,
   except free cells that were already free at t0 (the mixed-block free lists and
   `free_large_blocks_` built by the previous cycle's sweep, which is drained at t0).
7. **Assert what you rely on** (M§2): validators IM1–IM9 re-derive every premise in the
   validate tree (unit tests, E2E, GC-pressure stress; never the self-compile).
8. Standing gates (M§2): E2E, elm-tests, `full`, stress under GC pressure, the validate tree
   with the P1 tripwire, stats-off build, `out.mlir` byte-identical, bootstrap fixed point.

---

## 2. Verified facts

Verified 2026-09-26 against `keep-TG4b`. Paths are under `runtime/src/allocator/` unless given.
Line numbers are approximate. **Re-verify each one before editing (Step 0).**

| # | Fact | Where |
|---|---|---|
| F1 | `ThreadLocalHeap::minorGC` collects stack roots, runs `nursery_.minorGC`, then calls `old_gen_.evaluateMajorGCTrigger()` and, if a reason is live, `majorGC(reason)`. **This is the only production place a trigger-driven major starts at a minor end**, i.e. the only place a cycle may start. | `ThreadLocalHeap.cpp:~680-717` |
| F2 | Other `majorGC` callers: `allocateYoungLarge` and `allocateLargePinned` on old-gen allocation failure (then retry once and assert), `collectAtSafepoint` (reachable only via `__eco_safepoint_poll`, which compiled code does not emit), `Allocator::majorGC` → `eco_major_gc` (tests, 60 references under `test/`). | `ThreadLocalHeap.cpp:~459,478,617`, `Allocator.cpp:450`, `RuntimeExports.cpp:4287` |
| F3 | `majorGC` re-walks the stack, gathers the roots (`collectRoots()` = `RootSet::getRoots()`, `getJitRoots()`), calls `p1::verifyOldGen("major-start")`, `startMark(roots, jit_roots, …)` (which marks the long-lived and JIT roots), then marks stack-map slots, stack root ranges (`stackRangeSlotIsRoot`), single roots and every external root scanner, then `finishMarkAndSweep`. | `ThreadLocalHeap.cpp:719-960`, `OldGenSpace.cpp:1952-2064` |
| F4 | `startMark` returns early if `marking_active`; drains any pending lazy sweep; `mark_.clearForMark(blocks_)` (**clears every mark bit, including the uniform blocks' allocation maps**); `resetAllocCursors()` in bitmap mode (flushes cursor `pending_live`, empties every cursor and `partial_` queue, sets every block's `alloc_state` to None); sets `marking_active = true`; clears `mark_stack` and `nursery_visited_`; `resetBufferMetaForMark()` (every block: `live_bytes = 0`, `garbage_bytes = 0`, `fully_swept = false`). `gc_phase_` stays `Idle` during today's STW mark. | `OldGenSpace.cpp:1956-2064, 2400-2420` |
| F5 | `incrementalMark(work_units)` pops through a `MARK_FIFO_DEPTH` prefetch ring and **always drains the ring before returning**; it returns `!mark_stack.empty()`. Units = old-gen or nursery objects processed by `markOneObject`. It is already slice-safe. | `OldGenSpace.cpp:2067-2121` |
| F6 | `pushMarkRoot`: a nursery target goes to `nursery_visited_` and the mark stack (block id NO_BLOCK_ID); an old-gen target is `testAndSetMarkBitInBlock`ed and pushed with its block id. `markOneObject` on a nursery object calls `markChildren` and attributes nothing; on an old-gen object it adds the walk step to `mark_live_` (HEAP_051) and calls `markChildren`. `markHPointer` filters `ptr_ind`, null and `!isInHeap`. | `OldGenSpace.cpp:2269-2398` |
| F7 | `markChildren` is the per-tag child walk the marker uses (`HeapChildWalk.hpp`'s `visitHeapChildren` mirrors it for PermanentSpace and a TG4b validator). Closures are scanned to `n_values`; `ListBacking` from `hd`. | `OldGenSpace.cpp:2123-2267`, `HeapChildWalk.hpp` |
| F8 | The four `finishMarkAndSweep` overloads (stats/no-stats × profile/no-profile) each repeat the same tail: `finalizeMetaAfterMark` → (stats: `gatherFreeListSnapshotInto`) → `demoteMostlyDeadUniformBlocks` → `transitionToSweeping` → `reclaimAllDeadBlocksFromMeta` → `adjustCapacityAfterMajorGC` → (stats: `gatherResidencySnapshotFrom`) → bitmap mode: `classifyBlocksAfterMark` + `committed_at_major_` → `recomputeSweepPendingBlocks` → `lazySweep(initial_sweep_budget)` → validator → `marking_active = false`. | `OldGenSpace.cpp:2559-2770` |
| F9 | `finalizeMetaAfterMark` merges `mark_live_` into `BufferMetadata::live_bytes` first (HEAP_051), calls `p1::onMarkEnd` (keeps census entries whose bit is set), `++major_epoch_`, recomputes totals, and sets `allocated_bytes = post_sweep_live_bytes_ = major_live_ = total_live` (and `prev_major_live_`). | `OldGenSpace.cpp:2422-2470` |
| F10 | **Allocate-black already exists** for "mid-cycle" allocations, gated on `marking_active \|\| gc_phase_ != Idle`: `initObjectHeaderWithSize` sets the mark bit and adds `cell_bytes` to `meta.live_bytes`; `finalizeBitmapCell` sets the cell bit unconditionally (it is the allocation record) and accumulates `pending_live`; `allocateLargeBlock` materializes mid-cycle large blocks `fully_swept`; `allocateFromBagPage` materializes mid-cycle bag pages `fully_swept`. It is dead code today because nothing allocates during a STW mark. | `OldGenSpace.cpp:425-452, 681-700, 1652, 1924` |
| F11 | Old-gen allocation entry points that reach a header init: `finalizeBitmapCell` (uniform cursor), `finalizePoppedCell` (mixed free-list pop), `tryAllocateBySplittingLarger` (`:1528`), `allocateFromBagPage` (`:1681`), `allocateFromFreeLargeBlocks` (`:1838`), `allocateFromEmptyRegularBlocks` (`:1883`), `allocateLargeBlock` (`:1943`). `allocateLargeBody`, `allocateYoungLarge`, `ThreadLocalHeap::allocatePermanent` and `allocateLargePinned` all go through `OldGenSpace::allocate`. Promotions (`evacuate`, `evacuateJitPtr`, `evacuateListSpine`) call `oldgen.allocate(size)` and then **overwrite the header color with White** (color is not load-bearing; the bit is). | `OldGenSpace.cpp` as listed; `NurserySpace.cpp:1357,1531,2142` |
| F12 | Bitmap-mode allocation ladder: (1) class cursor over `partial_` queue blocks, (2) mixed free-list pop, (3) budgeted virgin block, (4) split a larger mixed cell, (5) sweep-on-demand (only if `gc_phase_ == Sweeping`), (6) virgin block, (7) bag page, (8) panic sweep (only with pending sweep work). With the queues emptied by `startMark`, rung (1) only ever serves **virgin blocks created after t0**. | `OldGenSpace.cpp:780-819, 659-679` |
| F13 | `allocateFromEmptyRegularBlocks` repurposes only blocks with `fully_swept && live_bytes == 0`; `resetBufferMetaForMark` clears `fully_swept` for every block at t0, so **no block that existed at t0 can be repurposed during a cycle**. | `OldGenSpace.cpp:1844-1887` |
| F14 | `sweepNurseryLargeBodies(minor_color)` runs at the end of every minor (`NurserySpace.cpp:~1112`). It frees (via `freeLargeBodyCell`) every nursery-owned body whose header was not seen, and every unreached YLOS object. It already defers when `compact_phase_ != Idle`. **It does not defer while marking** (the comment claiming otherwise at `NurserySpace.cpp` near the call is stale, §5.4 item 1). | `OldGenSpace.cpp:5070-5159` |
| F15 | `freeLargeBodyCell` in bitmap mode asserts `gc_phase_ != Marking`, clears the bit (uniform: `freeUniformCell`, which also queues the block), pushes mixed cells on a free list, and debits `live_bytes`, `allocated_bytes` and `frag_stats_`. The `GCPhase::Marking` switch arm in the legacy branch is marked unreachable "kept for 5a". | `OldGenSpace.cpp:5161-5345` |
| F16 | `retireDeadLargeBodies` (first action of `classifyBlocksAfterMark`) erases every index entry whose body is in a non-large block and unmarked; V12 then asserts every remaining entry is marked. | `OldGenSpace.cpp:852-940` |
| F17 | Block releases happen only in `maybeShrinkCapacity` (post-mark shrink and the light pass in `onSweepComplete`) and `reclaimAllDeadBlocksFromMeta` — i.e. in the post-mark tail and at lazy-sweep completion. `scheduleCompaction` has **no production caller** (test access only). | `OldGenSpace.cpp:3389-3405, 3571-3765, 4097, 4278` |
| F18 | `evaluateMajorGCTrigger` (const): Occupancy (`allocated/committed ≥ major_gc_initiating_occupancy`), GlobalPressure (`old-gen committed / cap ≥ major_gc_global_pressure_fraction`), GarbageFraction, LiveBudget (`alloc since major ≥ k · min(major_live_, r · prev_major_live_)`). Callers: `minorGC`, `collectAtSafepoint`, `shouldCollectAtSafepoint`. | `OldGenSpace.cpp:3407-3506` |
| F19 | The nursery after a minor: roles are swapped, `bump_.ptr = copy_ptr_`, so from-space is `[fromBase(), bump_.ptr)` = **exactly the survivors**, contiguous and parsable by `getObjectSize` (the Cheney loop walked it). Builders are in it. | `NurserySpace.cpp:~1045-1060` |
| F20 | YLOS objects are kind-1 entries of the HEAP_026 body index; `forEachYoungLarge(f)`, `isYoungLarge(p)`, `mayBeYoungLarge(p)` exist. At a minor end every remaining YLOS object was reached by that minor (unreached ones were just freed). | `OldGenSpace.hpp:781-800` |
| F21 | Pauses: `GCPauseScope` brackets the outermost `minorGC`/`majorGC`; `recordPause(start, dur, kind)` with kind 0 = minor only, 1 = minor + major, 2 = major only; `GCPhaseTotals::addPause` counts `pause_count_by_kind[kind]` for `kind < 3`. `PauseEndHook` calls `Allocator::onGCPauseEnd(heap, had_major)` at the outermost pause end; `had_major` advances `major_epoch_`, the clock of the deferred decommit (HEAP_059). | `ThreadLocalHeap.cpp:~622-676`, `GCStats.cpp:2053` |
| F22 | `validateOldGenMetadata`'s V8 (uniform `live_bytes == popcount × cell`) is skipped while `marking_active`. `validateEveryNthMinor` runs at every minor end in validate builds. The minor GC's validate walk of old-gen blocks visits uniform cells only at set bits. | `OldGenSpace.cpp:~5497-5530`, `NurserySpace.cpp:~905` |
| F23 | `HeapConfig::mark_work_ratio` is parsed and read by nothing (W0 item 13). Leave it alone; this plan does not reuse it. | `AllocatorCommon.hpp:625`, `HeapConfigJson.cpp:345` |
| F24 | Unit tests build their own `HeapConfig`; the old gen ignores `ECO_HEAP_CONFIG` there (initAllocator reset). Tests must set `incremental_mark` in the config they pass. | memory note, `test/allocator/TestHelpers.cpp` |

---

## 3. Design

### 3.1 The cycle: states and schedule

New state in `OldGenSpace` (it owns the mark state; `ThreadLocalHeap` drives it because it owns
the roots):

```cpp
enum class CycleState : uint8_t { Idle, Marking, HandoffDue };

struct MarkCycle {
    CycleState state = CycleState::Idle;
    uint32_t   slices_planned = 0;     // T, fixed at t0
    uint32_t   minors_since_t0 = 0;    // k
    uint64_t   predicted_units = 0;    // fixed at t0 (P§3.5)
    uint64_t   units_done = 0;         // old-gen objects marked so far
    uint64_t   prev_cycle_units = 0;   // carried across cycles
    size_t     black_bytes = 0;        // bytes allocated black this cycle (stats)
    GCStats::MajorReason reason{};     // the trigger that started it
    // stats-only fields: t0_ns, slice_ns_max, slice_ns_total, closing_units, ...
};
MarkCycle cycle_;
bool cycleActive() const { return cycle_.state != CycleState::Idle; }
```

While a cycle is active: `marking_active == true` and `gc_phase_ == GCPhase::Marking` (today's
STW mark leaves `gc_phase_` Idle; the incremental path sets Marking so every existing mid-cycle
branch, F10, applies). IM9 asserts the three agree.

**Schedule** (k counts minor-GC ends after the t0 minor; T = `incremental_mark_slices`):

| minor end | T = 0 | T ≥ 1 |
|---|---|---|
| t0 (k = 0) | snapshot, drain, handoff in one pause | snapshot only; state Marking |
| 1 ≤ k < T | — | slice with budget `b_k` (P§3.5) |
| k = T | — | **closing slice**: drain the mark stack completely; state HandoffDue |
| k = T + 1 | — | **handoff** (P§3.6); state Idle |

**The schedule is fixed at t0.** If the mark stack empties before slice T, later slices do no
work, but the handoff still happens at k = T + 1. This costs a little retention when the
predictor overestimates, and it buys the property that the handoff minor is `t0 + T + 1`
regardless of how fast marking went. That is what lets 5b (parallel slices) and 5c (collector
threads, with the mutator waiting or assisting at k = T) reproduce 5a's counters exactly
(GC_DET_001, P§9).

Two things break the schedule, both deterministic:
- **Emergency finish** at any minor end with state Marking: if old-gen committed / cap ≥
  `incremental_mark_finish_fraction` (P§3.8), drain and hand off in that pause.
- **Join**: any `majorGC()` call during a cycle (P§3.8).

After a pause that ran a handoff, `minorGC` does **not** evaluate the major trigger again in the
same pause. The trigger's baselines were just reset, so it would not fire anyway; skipping it
keeps a t0 snapshot from ever sharing a pause with a handoff.

### 3.2 t0: the snapshot

`ThreadLocalHeap::minorGC`, after `nursery_.minorGC`, when a trigger reason is live, the flag is
on and no cycle is active, calls `startMarkCycle(reason)` instead of `majorGC(reason)`:

```cpp
void ThreadLocalHeap::startMarkCycle(GCStats::MajorReason reason) {
    // 1. Fresh stack roots (0.1 ms; the minor's walk is reused only if F19's
    //    "no allocation since" check holds — simpler to re-walk, as majorGC does).
    collectStackRootsFromStackMap();
    p1::verifyOldGen(old_gen_, "cycle-start");
    // 2. Start the mark without pushing roots: drain lazy sweep, clearForMark,
    //    resetAllocCursors, resetBufferMetaForMark, marking_active, gc_phase_=Marking.
    old_gen_.beginMarkCycle(*parent_, reason, config_->incremental_mark_slices);
    // 3. Snapshot mode: young targets are dropped (they are walked in step 5).
    old_gen_.setSnapshotMode(true);
    forEachMajorRoot([&](HPointer& hp) { old_gen_.markHPointer(hp); },
                     [&](uint64_t raw) { old_gen_.markJitRootRaw(raw); });
    // 4. Every YLOS object: mark its cell, then scan its children.
    old_gen_.snapshotYoungLarge();
    // 5. Every nursery survivor: scan its children.
    nursery_.forEachSurvivor([&](void* obj) { old_gen_.markChildren(obj); });
    old_gen_.setSnapshotMode(false);
    // 6. T == 0: drain and hand off now (the equivalence arm).
    if (config_->incremental_mark_slices == 0) finishMarkCycleNow(FinishReason::Schedule);
}
```

**Snapshot mode in `pushMarkRoot`.** A new member `bool snapshot_mode_`. When set:
- a **nursery** target returns immediately: it is a survivor, walked in step 5;
- a target inside `mayBeYoungLarge` that `isYoungLarge` returns immediately: step 4 marks it;
- an old-gen target takes the normal path (test-and-set, push).

When not set and a cycle is active (slices), a nursery or YLOS target is a bug: **IM3** aborts in
validate builds. In release builds the nursery branch keeps its current behaviour (it cannot be
reached if HEAP_005 holds).

**`OldGenSpace::snapshotYoungLarge()`**: for each kind-1 entry, `testAndSetMarkBitInBlock` the
cell (or the large-mark byte); if it was clear, add the walk step to `mark_live_` exactly as
`markOneObject` does; then `markChildren(obj)` under snapshot mode. This makes a YLOS object
that dies later in the cycle marked (floating garbage, freed by the handoff through the deferred
free, P§3.7), and one that is promoted in place during the cycle already marked.

**`NurserySpace::forEachSurvivor(F)`**: walks `[fromBase(), bump_.ptr)` by `getObjectSize`.
Precondition, asserted in every build (cheap): `bump_.ptr == survivor_end_`, a new member set to
`copy_ptr_` at the role swap and never written elsewhere. If the mutator had allocated since the
minor, the prefix would include unscanned young objects that are not survivors; the assertion
proves it has not (**IM7**). Validate builds also assert each header's tag is in range and the
walk ends exactly at `bump_.ptr`.

**Roots.** `forEachMajorRoot` (D1) is today's `majorGC` enumeration, unchanged, moved into one
function: long-lived roots (`RootSet::getRoots`), JIT roots (raw words: constants skipped,
`isInHeap` checked, as `startMark` does today), stack-map slots, stack root ranges (masked),
single roots, external root scanners. Every one is read **once**, at t0. That is
HEAP_SNAPSHOT_002 for 5a: off-heap stores are read only at t0, never lazily.

**What the snapshot costs.** Root scan (CellStore up to 8.6 ms per pause, TG0) + one pass over
the survivor prefix (the minor just copied it, so it is cache-warm) + the YLOS objects + any
pending lazy sweep (bitmap mode sweeps only mixed blocks; worst 63 ms in one pause, TG2). E1
measures it.

### 3.3 Why the snapshot is sound

Let H be the t0 handshake. R_H = every root slot and off-heap store at H, plus every young
object at H. S_H = Reach(R_H). N_H = objects allocated after H.

**Claim 1: at the closing slice, every old-gen object in S_H is marked.** The marker starts from
the old-gen targets of R_H (steps 3–5 grey exactly those; step 4 also marks the YLOS cells) and
follows old-gen fields. A path from R_H to an old object O in S_H is either:
- a path of old objects after its first old object: every edge on it is a field of an old
  object that existed at H, and by P1 (HEAP_SNAPSHOT_001, enforced in validate builds) old
  objects are never written, so the edge the marker reads is the edge that existed at H; or
- a path through young objects first: every young object at H was scanned at H, so the first
  old object on the path was greyed at H.

HEAP_005 (strict since TG4b) says an old object never points to a young one, so no path leaves
the old gen and comes back. The marker never needs a young object after t0.

**Claim 2: every object reachable at the handoff is in S_H ∪ N_H.** This is the lemma (§2.1). Its
premise P0 ("no object existing at H is written after H") is weaker in practice:
- **Old objects:** P1 forbids writes (validate builds abort, TG4).
- **Young objects existing at H, non-builder:** P1 forbids writes once they have survived a GC,
  and every young object at t0 has (t0 is a minor end).
- **Builders** (HEAP_BUILDER_001: young only): they are written after H by design (M1). A value
  written into a builder is a value the mutator held at the time, so by the induction in the
  lemma it is in S_H ∪ N_H. An *overwrite* could delete an edge, but every builder existing at H
  was scanned at H (it is young), so the targets it held at H were greyed at H. Nothing is lost.
  This retires TG4's note ("builder objects need a builder-root path"): the young walk *is* that
  path.
- **Off-heap stores** (CellStore, MVar, scheduler): read once at H. An overwrite later cannot
  lose a t0 target; a new value is held by the mutator, so it is in S_H ∪ N_H.

**Claim 3: every object in N_H that is in the old gen is marked.** Allocate-black (P§3.4). The
children of an N_H object need no tracing: by the lemma they are in S_H ∪ N_H, and both sets
are marked.

**Therefore** at the handoff, marked ⊇ (S_H ∩ old) ∪ (N_H ∩ old) ⊇ everything old that is
reachable. The sweep may free every unmarked old object. The garbage it misses (objects that
died after H) is floating garbage, collected by the next cycle.

IM1 checks Claim 1 and IM2 checks the conclusion, both directly (P§3.13).

**Worked example (§5.2's hazard).** Young survivor X is the only path to old object O at t0. At
the next minor X is promoted (its copy is black, so its children are never traced). O is still
marked, because X was walked at t0 and O greyed then. Test `testIncrOldReachableOnlyFromSurvivor`
with its negative control (remove step 5) pins this.

### 3.4 Allocation during a cycle

**Allocate-black.** Every old-gen allocation made while a cycle is active sets the object's mark
bit (or large-mark byte) and attributes its bytes to `BufferMetadata::live_bytes` (not to the
marker's accumulator, HEAP_051). F10 already does this for every entry point in F11, because
`gc_phase_ == Marking` during a cycle. This plan adds no new mechanism, only proof that the
mechanism covers every path:

| entry point | bit set by | bytes attributed by |
|---|---|---|
| `finalizeBitmapCell` (uniform cursor) | `bitscan::setBit` (always) | cursor `pending_live` → `flushCursor` |
| `finalizePoppedCell` (mixed free-list pop) | `initObjectHeaderWithSize` | same, `cell_bytes` |
| `tryAllocateBySplittingLarger` | `initObjectHeaderWithSize` | same |
| `allocateFromBagPage` | `initObjectHeaderWithSize` | same |
| `allocateFromFreeLargeBlocks` | `initObjectHeader` → `setMarkBitInBlock` (large byte) | `meta.live_bytes = size` |
| `allocateFromEmptyRegularBlocks` | same | same (only post-t0 blocks qualify, F13) |
| `allocateLargeBlock` (fresh block) | same | `materializeBlock(bi, {size, …})` |
| promotions, `allocateLargeBody`, `allocateYoungLarge`, `allocatePermanent`, `allocateLargePinned` | via `allocate()` → one of the above | via one of the above |

**IM4** (validate builds) proves it for every allocation, in two halves:
- **"was clear"**: each of the seven header-init sites in F11 calls
  `assertCellWasWhite(block_id, obj)` immediately *before* it sets the bit. A set bit there
  means the allocator handed out a cell the marker had already marked, i.e. a live object:
  catastrophic. (The target is not known before `allocate()` dispatches, so this half cannot
  live in `allocate()` itself.)
- **"is set now"**: `allocate()`'s single return point calls
  `noteCycleAllocation(void* obj)`, which asserts the bit (or large-mark byte) is set and
  appends the address to a validate-only vector. The handoff re-checks every logged address
  before the tail runs.

Note that promotions overwrite the header color with White (F11). The color is not load-bearing;
leave it. IM4 checks the bit.

**No reuse of pre-t0 uniform free cells.** `clearForMark` at t0 erases the uniform blocks'
allocation maps (a clear bit no longer means "free" until the mark is complete), and
`resetAllocCursors` empties the queues. So during a cycle the cursor serves only virgin blocks
created after t0 (F12), whose bitmaps are exact. Free cells of pre-t0 uniform blocks become
reusable again at the handoff, when `classifyBlocksAfterMark` re-queues them. Mixed free lists,
splits and `free_large_blocks_` are still used during the cycle: their cells were already free at
t0 (rule 6).

**Retention cost.** Every promotion during the cycle lands in fresh memory instead of a partially
free uniform block, and it stays live until the next cycle even if it dies at once (allocate-black).
At TG4b rates (19.8 GB promoted over 1,924 minors ≈ 10.3 MB per minor) a cycle of T + 1 minors
promotes about `10.3 MB × (T + 1)`: ~340 MB at T = 32, ~1.3 GB at T = 128, against a max RSS of
9.8 GB. E1 measures the real old-gen peak.

**Plan B, only if E1's old-gen peak fails the retention gate at every useful T:** an
*allocation shadow* for the uniform blocks that `partial_` held at t0. Before `clearForMark`, copy
those blocks' bitmap slots into a side arena (at most the queued blocks, not the whole heap);
during the cycle the cursor allocates from a cell only if its shadow bit is clear (free at t0,
hence not in S_H), setting both the shadow and the mark bit. The shadow is dropped at the
handoff. This is the "double-buffered bitmap" of M§3 phase 8, restricted to the blocks that have
free space. Do not build it unless E1 requires it.

### 3.5 Slices and pacing

Work is counted in **units**: one old-gen object processed by `markOneObject` (today's
`units_done`). Nursery objects are never units in a cycle.

At t0:
```
predicted = (prev_cycle_units > 0)
          ? ceil(prev_cycle_units * incremental_mark_predict_growth)
          : allocated_bytes_at_t0 / 48                       // first cycle; 48 B ≈ mean object
```
At slice k (1 ≤ k < T):
```
remaining = predicted > units_done ? predicted - units_done : 0
b_k       = max(incremental_mark_min_slice_units, ceil(remaining / (T - k + 1)))
units_done += incrementalMark(b_k)       // returns units actually done (see below)
```
At k = T: `while (incrementalMark(1000)) {}` (the closing slice). At the end of the cycle,
`prev_cycle_units = units_done`.

`incrementalMark` currently returns "more work remains". Add an out-parameter (or a second
function `markSlice(budget) → units`) that returns the units done; the stats overload already
computes `units_done`. The FIFO-ring overshoot (at most `MARK_FIFO_DEPTH − 1` objects) is
accepted.

The catch-up form spreads a misprediction over the remaining slices instead of dumping it on the
closing slice. `closing_units` (units done by the closing slice) is recorded per cycle: a large
value means the predictor is low, and E1 reports it.

All inputs are deterministic (rule 4).

### 3.6 The handoff

`OldGenSpace::handoffMarkCycle(GCStats*, MajorGCPhaseProfile*)`, at k = T + 1 (or in the
emergency/join pause, after a drain):

1. Assert the mark stack is empty (IM9).
2. `resetAllocCursors()`: fold every cursor's `pending_live` into `meta.live_bytes`, and empty the
   cursors and queues. **This must precede step 4**: during the cycle the cursors own post-t0
   virgin blocks, and the post-mark tail assumes no block is Current (F8's classify re-queues).
3. `cycle_.traced_live = mark_live_.sum()` (a new `LiveBytesAccumulator::sum()`, validate/stats
   cost only at the handoff: one pass over the committed ids). `cycle_.black_bytes` = Σ
   `meta.live_bytes` before the merge.
4. **Validate builds:** IM1, IM2, IM4-final, IM6 equality, IM8 (P§3.13), before anything is
   freed or cleared.
5. `gc_phase_ = GCPhase::Idle` and `cycle_.state = CycleState::Idle`. From here on the heap is
   in exactly the state today's STW major has after its mark loop (`marking_active` still true,
   stack empty, `gc_phase_` Idle), so the tail's own asserts hold and IM5's `!cycleActive()`
   asserts in the free and release sites do not fire on the tail's legitimate frees.
6. `runPostMarkTail(stats, profile)` (D1), with one insertion right after
   `finalizeMetaAfterMark`: `processDeferredFrees()` (P§3.7). The tail ends with
   `marking_active = false`.
7. `prev_cycle_units = units_done`.
8. `ThreadLocalHeap` sets `pause_had_major_ = true` for this pause (so the deferred-decommit clock
   counts one major per cycle, as today), and closes the major event (P§3.12).

**LiveBudget reference = traced live.** `finalizeMetaAfterMark` sets `major_live_ = total_live`.
In a cycle, total live includes black bytes, which measure allocation during the cycle, not the
live set. Change it to use `traced_live` for `major_live_` / `prev_major_live_` when the cycle
path is running, and keep `allocated_bytes = post_sweep_live_bytes_ = total_live` (occupancy).
In STW and T = 0 there are no black bytes, so traced = total and flag-off stays bit-identical.
(Rationale: HEAP_057 bounds allocation by the live *set*; feeding it `live + in-cycle promotions`
would grow every next cycle's budget by the previous cycle's promotion volume.)

### 3.7 Deferred frees (M5)

During a cycle, an old-gen cell that existed at t0 may be marked or greyed; freeing it could let
the allocator reuse it under the marker. Two paths free old-gen cells between majors:
- `sweepNurseryLargeBodies` at every minor end (nursery-owned bodies whose header died,
  unreached YLOS objects);
- nothing else (F17: releases happen only in the tail; compaction has no caller).

Change `sweepNurseryLargeBodies`: while `cycleActive()`, for each entry it would free,
- copy the `LargeBodyMeta` into a new `std::vector<LargeBodyMeta> deferred_frees_`;
- `large_body_index_.erase(m.body_base)`, clear `m.body_base`, recycle the id and drop it from
  `nursery_owned_bodies_` exactly as the immediate path does. The index no longer names the
  cell, so a later `reachYoungLarge` or `markLargeBodySeen` cannot find it (nothing references
  it: it is dead);
- count `incr_deferred_frees` and bytes.

`processDeferredFrees()` (handoff step 6, after `finalizeMetaAfterMark`, before demotion, so its
bytes count as garbage for reclaim and demotion): `freeLargeBodyCell(copy)` for each entry, then
clear the vector. `freeLargeBodyCell` re-erases the index key (a no-op) and does the accounting
against the just-merged `live_bytes`. The cell may be marked (it was live at t0 or allocated
black); `freeLargeBodyCell` clears the bit, so the tail sees it as garbage.

Also update the stale comments: `NurserySpace.cpp` near the `sweepNurseryLargeBodies` call, and
the `GCPhase::Marking` arm in `freeLargeBodyCell` (still unreachable: frees are deferred to a
point where `gc_phase_` is Idle).

`OldGenSpace::reset` clears `deferred_frees_` and `cycle_`.

### 3.8 Triggers, joins and emergency finishes

**Trigger suppression.** `evaluateMajorGCTrigger()` returns `None` while `cycleActive()`. This
covers `minorGC`, `collectAtSafepoint` and `shouldCollectAtSafepoint` at one site.

**Cycle step** — new `ThreadLocalHeap::stepMarkCycle()`, called from `minorGC` after
`nursery_.minorGC` when `old_gen_.cycleActive()` (instead of the trigger evaluation):
```
++k
if state == HandoffDue:                     handoff                        (kind 5 pause)
elif committed/cap >= finish_fraction:      closing slice + handoff        (Pressure)
elif k < T:                                 slice b_k                      (kind 4 pause)
else /* k == T */:                          closing slice; state HandoffDue (kind 4 pause)
```
`committed` and `cap` are `allocator_->getOldGenCommittedBytes()` and `getOldGenMaxBytes()`, the
GlobalPressure inputs. `incremental_mark_finish_fraction` (default 0.95) must exceed
`major_gc_global_pressure_fraction` (default 0.85), or a cycle started by GlobalPressure would
finish at its first slice; `validate` enforces it.

**Joins.** At the top of `ThreadLocalHeap::majorGC(reason)`:
```cpp
if (old_gen_.cycleActive()) {
    finishMarkCycleNow(FinishReason::Join);   // drain + handoff, counted as a major
    // then fall through: run the requested STW major as today.
}
```
Rationale: the joined cycle frees only garbage that was dead at t0. An allocation failure needs
everything dead now, and `eco_major_gc` callers (tests) expect a full collection. A join is an
emergency path and costs two majors. `startMark`'s early return on `marking_active` (§5.4 item 3)
can then never fire; replace it with `assert(!marking_active)`.

A join can happen **inside** a minor-end pause (`allocateYoungLarge` is not called from the
minor, but assume nothing): `finishMarkCycleNow` is re-entrant-safe only if no slice is on the
stack. Assert `!in_slice_` (a bool set around the slice call) in `finishMarkCycleNow`.

### 3.9 Policy consequences (all deliberate, T ≥ 1 only)

- Reclamation is delayed by T + 1 minors (plus the closing-slice pause for the drain).
- In-cycle promotions are retained until the next cycle (floating garbage).
- Pre-t0 uniform free cells are not reused during the cycle (P§3.4).
- `major_live_` excludes black bytes (P§3.6).
- One cycle counts as one major (`major_gc_count`, `major_epoch_`), at the handoff.
- The next trigger baseline (`post_sweep_live_bytes_`) is set at the handoff, as today at the
  major.

### 3.10 What the marker touches (the 5b/5c contract)

After t0, a slice (`incrementalMark` → `markOneObject` → `markChildren` → `markHPointer` →
`pushMarkRoot`) reads and writes only:

| structure | access | owned by | 5b/5c note |
|---|---|---|---|
| old-gen objects in S_H | read fields, header | frozen (P1) | safe to read concurrently |
| `page_index_` (via `blockIdFor`) | read slots of t0 blocks | mutator adds slots for new blocks | ReservedArray, never moves (HEAP_049); t0 blocks are never released mid-cycle |
| `BlockInfo` of t0 blocks: `start`, `size_class`, `is_large` | read | mutator writes `alloc_state` only (different field); `size_class` is not changed mid-cycle (demotion is in the tail; `allocateFromEmptyRegularBlocks` cannot pick a t0 block, F13) | IM5 asserts `size_class`/`is_large` of t0 blocks are unchanged at the handoff (record a checksum at t0 in validate builds) |
| mark bits (`mark_.slot`, large-mark byte) | test-and-set | **shared**: allocate-black sets bits too | 5b: `fetch_or` (HEAP_050); 5c: the allocation log or `fetch_or` (§5.3) |
| `mark_live_` | add | marker only (deferred frees never `take` mid-cycle) | 5b: one accumulator per marker (HEAP_051) |
| `mark_stack` | push/pop | marker only | 5b: per-worker deques |
| `allocator_ref_->isInHeap` | read | immutable reservation | safe |

Everything else is off-limits to a slice. In particular a slice never calls `isYoungLarge` (the
index is mutator-owned); IM3 proves no young pointer reaches `pushMarkRoot` outside snapshot mode.

### 3.11 Configuration

`HeapConfig` fields, each with a compiled default in `AllocatorCommon.hpp`, a JSON key in
`HeapConfigJson.cpp` (known-key list + parse block), a line in `HeapConfigJson.hpp`'s key
comment, and a `validate` rule:

| field | type | default | parse | `validate` |
|---|---|---|---|---|
| `incremental_mark` | `bool` | `INCREMENTAL_MARK = false` | `parseBool` | if true, `old_gen_bitmap_alloc` must be true |
| `incremental_mark_slices` | `uint32_t` | `INCREMENTAL_MARK_SLICES = 32` (provisional; E1 sets it) | `parseU32` | ≤ 4096 |
| `incremental_mark_min_slice_units` | `size_t` | `INCREMENTAL_MARK_MIN_SLICE_UNITS = 16384` (≈ 0.7 ms at 41 ns/object) | `parseByteSize` (a count; accepts `"16K"`) | ≥ 1 |
| `incremental_mark_predict_growth` | `double` | `1.25` | `parseFraction`-style, range [1, 4] | in [1, 4] |
| `incremental_mark_finish_fraction` | `double` | `0.95` | fraction | in (major_gc_global_pressure_fraction, 1] |

No environment variable: arms are compiled defaults or `ECO_HEAP_CONFIG` JSON, as in the GC
loop.

### 3.12 Stats, pauses and the event log

**Counters** (`GCStats`, major section; merged like the other major counters):
`incr_cycles`, `incr_slices`, `incr_slice_units`, `incr_closing_units`, `incr_finish_schedule`,
`incr_finish_pressure`, `incr_finish_join`, `incr_black_bytes`, `incr_traced_live_bytes`,
`incr_deferred_frees`, `incr_deferred_free_bytes`, `incr_t0_survivors`, `incr_t0_survivor_bytes`,
`incr_t0_ylos`. Timing (stats builds): `incr_t0_ns_max/total`, `incr_slice_ns_max/total`,
`incr_handoff_ns_max/total`.

**Major event.** `beginMajorGCEvent` at t0 (the reason and occupancy at t0); `recordMajorGCEvent`
at the handoff with `total_ns` = the in-pause sum (t0 + slices + handoff), `mark_ns` = t0 +
slices, `sweep_ns` = the tail. Add columns `span_minors` (T + 1 or less), `span_ns` (wall t0 →
handoff), `slices`, `closing_units`, `black_bytes`, `finish` (schedule/pressure/join). STW majors
write `span_minors = 0`.

**Pause kinds** (`ThreadLocalHeap::recordPause`): add 3 = minor + t0 snapshot, 4 = minor + mark
slice (closing included), 5 = minor + handoff. A pause that contains a join or a pressure finish
is kind 1 (minor + major), as today. Grow `pause_count_by_kind` to 6 and extend
`GCPhaseTotals::addPause`'s bound. `GCPauseScope` gains `pause_saw_t0_/slice_/handoff_` flags set
by the cycle code.

**Banner.** One line per kind: count, max, p99; plus a line `incremental: cycles N, slices N,
closing units max N, black MB, deferred frees N/MB, finishes schedule/pressure/join`. The MMU
curve is unchanged: it already covers every pause.

**Event log.** `gcEventLogPause` carries the new kinds; add a `cycle` row at the handoff with the
event columns above. Teach `benchmarks/gc-event-log-summary.py` the new kinds and the `cycle`
row (per-kind max/p99, slices per cycle, closing-unit distribution).

### 3.13 Validators (validate builds; the M§2 "assert what you rely on" set)

| # | Checks | Where | How |
|---|---|---|---|
| IM1 | S_H ∩ old ⊆ marked at the handoff | t0 (record), handoff (check) | At t0, before the snapshot mutates anything, run an **independent** trace from the same roots with its own `std::unordered_set<void*>` visited set, following every young and old edge (use `visitHeapChildren` so the checker does not share `markChildren`'s code), and record every old-gen object reached. At the handoff, before any free, assert each recorded object's bit is set. Cap: skip (with a counted note) above 5 M objects, so E2E/stress never skip and nothing huge runs under the validator. |
| IM2 | reachable-at-handoff ∩ old ⊆ marked | handoff | The same independent trace, from the roots and young objects **at the handoff**. |
| IM3 | no young pointer outside snapshot mode | `pushMarkRoot` | `assert(snapshot_mode_ \|\| !cycleActive() \|\| (!nursery_->contains(obj) && !isYoungLarge(obj)))` |
| IM4 | allocate-black on every entry point | 7 header-init sites + `allocate()` tail + handoff | P§3.4 |
| IM5 | nothing pre-t0 changes identity | handoff; release/free sites | `releaseBlockToAllocator`, `releaseUnassignedBlockToAllocator` and `freeLargeBodyCell` assert `!cycleActive()`; `scheduleCompaction` and `incrementalCompactionSlice` assert `!cycleActive()`; at t0 record (validate) a hash of every t0 block's `(start, size_class, is_large)` and re-check it at the handoff. Amended 2026-09-30 (CR-036, plans/threaded-gc-register-fixes.md §3.5): the key includes the id's BlockTable generation, so a same-id, same-start re-issue is caught (`t0BlocksChangedWhy`; `isT0Block` fails at once on a generation mismatch) |
| IM6 | uniform live bytes consistent mid-cycle | every `validateEveryNthMinor` during a cycle; equality at the handoff | For each uniform block: `popcount × cell ≥ meta.live_bytes + pending + mark_live_.peek(id)` (grey objects have bits but no attribution yet); at the handoff, after the closing drain, equality. The existing V8 stays skipped while `marking_active`. |
| IM7 | the survivor prefix is exact at t0 | `forEachSurvivor` | P§3.2 (`bump_.ptr == survivor_end_`; tags in range; walk ends at `bump_.ptr`) |
| IM8 | no deferred free is lost or doubled | handoff | every `deferred_frees_` entry's cell is still allocated (bit set or large byte set) before `processDeferredFrees`; no address appears twice |
| IM9 | state consistency | every cycle step, handoff | `cycleActive() ⇔ marking_active ⇔ gc_phase_ == Marking` (except inside the handoff); `mark_stack` empty at HandoffDue; `nursery_visited_` empty throughout a cycle; `!in_slice_` at join |

IM1/IM2 double as the E2E-scale proof of Claims 1 and 3. Both run on every handoff in the
validate tree (unit tests, E2E, stress). **Negative controls** (Step 7): with step 5 of the
snapshot removed, `testIncrOldReachableOnlyFromSurvivor` fails and IM1 fires; with step 3's
external scanners skipped, `testIncrExternalStoreOverwrittenAfterT0` fails; with
`initObjectHeaderWithSize`'s bit set removed, IM4 fires on the first mixed pop.

---

## 4. Steps

Every step ends with `cmake --build build --target check` green. Steps 3–8 also build the
validate tree's `test` target and run the new tests there.

**Before you start:** `benchmarks/lss-loop-snap.sh verify keep-TG4b`; snapshot `try-TG5a-pre`.

### Step 0 — facts and baseline (no code change)

1. Re-verify F1–F24 against the tree; fix the line numbers here.
2. Record the same-session baseline with `eco-optTG4b` (a triple, stats build; one phase-timer
   run with `ECO_GC_EVENT_LOG`): wall, GC, minors, majors, promoted, copied, max RSS, old-gen
   peak, pause max/p99 by kind, MMU at 10/50/100/200/500 ms and 1/2/5 s, and per-major
   `mark_units_done`. This is the control for E0 and E1.
3. Check the stress config is not vacuous for this phase: run `build/test/test` stress with
   `benchmarks/heap-config-gc-pressure.json` and count **majors** (not only minors). If it runs
   fewer than ~20 majors, add `benchmarks/heap-config-gc-pressure-incremental.json` (same, plus
   a lower `major_gc_live_budget` and a small `initial_old_gen_size` so majors are frequent,
   and `incremental_mark_slices = 4`) and use it for every stress gate from Step 4 on.

### Step 1 — D1: pure refactor

1. `ThreadLocalHeap::forEachMajorRoot(HpFn&& on_hp, RawFn&& on_raw)`: the root enumeration of
   F3, in the same order. `majorGC` calls it (the long-lived and JIT roots move out of
   `startMark`: `startMark` keeps only its preparation; add `markJitRootRaw(uint64_t)` holding
   the JIT-root body). The per-kind push counters for `[gc-profile]` keep working (count in the
   lambdas).
2. `OldGenSpace::runPostMarkTail(GCStats* stats, MajorGCPhaseProfile* profile)`: the F8 tail
   once, with the stats/profile work guarded by the pointers. The four `finishMarkAndSweep`
   overloads become "mark loop + `runPostMarkTail`". Keep `#if ENABLE_GC_STATS` exactly where
   stats types are needed.
3. Gate: counters, major event log (non-timing columns) and `out.mlir` identical to
   `eco-optTG4b`; the mark-loop alignment trap applies (`-falign-loops=64` stays on
   `OldGenSpace.cpp`; if mark time moves with identical instructions, check the loop address
   first — memory `gc-mark-loop-alignment-trap`).

### Step 2 — D2 + D9 skeleton: config, state, stats

1. The five `HeapConfig` fields (P§3.11) with defaults, JSON, `validate`.
2. `CycleState`, `MarkCycle cycle_`, `cycleActive()`, `deferred_frees_` (empty), reset in
   `OldGenSpace::reset`.
3. The counters, pause kinds 3–5 (unused yet), banner lines (print zeros), summary-script
   support.
4. Tests: `testIncrConfigJson` (every key round-trips; `incremental_mark` with
   `old_gen_bitmap_alloc = false` is rejected; `finish_fraction ≤ global_pressure_fraction` is
   rejected); `testPauseKindsCounted` (`addPause` with kinds 0–5).
5. Gate: flag off, counters identical.

### Step 3 — D3: the t0 snapshot, T = 0 only

1. `snapshot_mode_` in `pushMarkRoot` (P§3.2).
2. `NurserySpace::survivor_end_` (set at the swap) and `forEachSurvivor` with IM7.
3. `OldGenSpace::snapshotYoungLarge()`.
4. `OldGenSpace::beginMarkCycle(alloc, reason, T)`: `startMark`'s preparation (sweep drain,
   `clearForMark`, `resetAllocCursors`, `resetBufferMetaForMark`, `marking_active`,
   `current_epoch++`, stack clear, `allocator_ref_`), plus `gc_phase_ = Marking`, `cycle_`
   initialised, `predicted_units` computed (P§3.5).
5. `ThreadLocalHeap::startMarkCycle` (P§3.2) and `finishMarkCycleNow(reason)` = closing drain +
   `handoffMarkCycle` (P§3.6, without deferred frees yet: with T = 0 no minor runs inside the
   cycle).
6. `handoffMarkCycle`, including the LiveBudget change (`major_live_` from `traced_live` when the
   cycle path runs).
7. `minorGC`: with the flag on and no cycle active, a live trigger calls `startMarkCycle`.
8. Tests (all with `incremental_mark = true`, `incremental_mark_slices = 0`, versus the same
   scenario flag-off):
   - `testIncrT0MatchesStwLiveSet`: a heap of old objects, nursery survivors pointing into old,
     YLOS objects with old and young children, a large string header in the nursery; the set
     of marked old objects and per-block `live_bytes` after the major are identical in both
     arms;
   - `testIncrT0YlosCellMarked`: a YLOS object reachable only through a nursery object stays
     live, and its old children survive;
   - `testIncrT0BuilderChildrenSurvive`: an array builder in the nursery holding the only
     reference to an old object.
9. **E0** (P§5): the self-compile with T = 0 vs flag-off. Must pass before Step 4.

### Step 4 — D4 + D5: the multi-minor cycle

1. `stepMarkCycle` (P§3.8) with the slice budget (P§3.5) and the closing slice; `markSlice`
   returning units; `in_slice_`.
2. `minorGC`: `if (old_gen_.cycleActive()) stepMarkCycle(); else <trigger → startMarkCycle>`;
   skip the trigger in a pause that ran a handoff.
3. Trigger suppression in `evaluateMajorGCTrigger`.
4. IM4 hooks (`assertCellWasWhite` at the seven sites, `noteCycleAllocation` in `allocate()`).
5. Pause-kind flags set at t0, slice, handoff.
6. Tests (T = 4 unless stated; drive minors explicitly and allocate between them):
   - `testIncrScheduleFixed`: a cycle hands off at exactly the 5th minor end after t0; slices
     1–3 do `b_k` units, the 4th closes; with `predicted` forced tiny, slices 1–3 do
     `min_slice_units` and the closing slice does the rest; with the stack emptied at slice 2,
     slices 3–4 do 0 units and the handoff is still at minor 5;
   - `testIncrOldReachableOnlyFromSurvivor` (P§3.3's worked example);
   - `testIncrRootOverwrittenAfterT0`: a root holds the only reference to old object O at t0;
     after t0 the test stores O into a fresh young object N, roots N, and overwrites the
     original root; N is promoted during the cycle; O survives the handoff and is still
     readable after two more cycles as long as N is rooted, and is freed by the second cycle
     after N is unrooted;
   - `testIncrExternalStoreOverwrittenAfterT0`: the same through a test external root scanner
     over an off-heap `std::vector<uint64_t>` (the CellStore pattern);
   - `testIncrAllocateBlackEveryEntryPoint`: during a cycle, create one object through each row
     of the P§3.4 table (promotion into a virgin uniform block, mixed free-list pop, split, bag
     page, `free_large_blocks_` reuse, fresh large block, large string body, YLOS object,
     `allocatePermanent`), root each one; each bit is set immediately after allocation; all
     survive the handoff; `black_bytes` equals their cell bytes;
   - `testIncrNoPreT0UniformReuse`: a uniform block with free cells at t0 receives no
     allocation during the cycle, and is queued again after the handoff;
   - `testIncrTriggersSuppressed`: while a cycle runs, a heap state that would fire every
     trigger reason starts nothing; the reason is evaluated again after the handoff;
   - `testIncrLiveBudgetUsesTracedLive`: after a cycle with black bytes B, `major_live_` equals
     the traced live, and `post_sweep_live_bytes_` includes B;
   - `testIncrBuilderFilledDuringCycle`: a nursery builder existing at t0 is filled during the
     cycle with references to old objects whose other references are dropped after t0; after
     `clear_builder` and promotion, every element is intact after the handoff and one more
     cycle.

### Step 5 — D6: deferred frees

1. `deferred_frees_` in `sweepNurseryLargeBodies`, `processDeferredFrees` in the handoff (P§3.7).
2. IM5's assertions in the release and free sites; IM8.
3. Tests:
   - `testIncrDeferredBodyFree`: a large string whose nursery header dies at slice 2: the body
     cell is not reused before the handoff (allocate same-class objects in between and assert
     none lands on it); after the handoff `incr_deferred_frees == 1`, the cell is free, IM6
     equality holds;
   - `testIncrDeferredYlosFree`: a YLOS object existing at t0 that becomes unreachable during
     the cycle: same checks;
   - `testIncrYlosPromotedInPlaceDuringCycle`: a YLOS object existing at t0 promotes in place at
     slice 1; it and its children survive the handoff; no deferred free;
   - `testIncrNoReleaseDuringCycle`: an all-dead block at t0 is still committed and in
     `blocks_` at every slice, and is released at the handoff.

### Step 6 — D7: joins and emergency finishes

1. `majorGC`'s join prologue (P§3.8), `startMark`'s early return → assert.
2. Pressure finish in `stepMarkCycle`.
3. Tests:
   - `testIncrJoinOnExplicitMajor`: `eco_major_gc()` at slice 2 finishes the cycle
     (`incr_finish_join == 1`) and then runs a STW major; an object that died after t0 is freed
     by the STW major, not by the joined cycle;
   - `testIncrJoinOnYlosAllocFailure`: a small-cap heap where `allocateYoungLarge` fails
     mid-cycle; the join plus STW major make room and the retry succeeds;
   - `testIncrPressureFinish`: a small cap where promotions during the cycle push committed past
     `finish_fraction` at slice 2: the cycle finishes in that pause (`incr_finish_pressure ==
     1`);
   - `testIncrResetMidCycle`: `Allocator` reset during a cycle leaves `cycle_` Idle and
     `deferred_frees_` empty, and the next cycle is correct.

### Step 7 — D8: validators and negative controls

1. IM1, IM2 (independent tracer over `visitHeapChildren`), IM3, IM6, IM9 as specified.
2. The three negative controls (P§3.13), each as a test behind a validate-only test hook
   (`OldGenSpaceTestAccess::setSnapshotSkipYoungWalk(true)`, `…SkipExternalScanners`,
   `…SkipAllocateBlack`) that runs the scenario and expects the validator abort in an
   `IsolatedTestRunner` child (the pattern the P1 census tests use).
3. Run the validate tree: unit, E2E, stress (Step 0's config). Zero `[heap-validate]` lines.

### Step 8 — D9: reporting

Banner, event-log `cycle` row, summary script (P§3.12). A unit test for the summary script's
parsing of kinds 3–5 if the script has tests; otherwise a checked-in sample log under
`benchmarks/` and its expected summary.

### Step 9 — measurement and the default

E1–E3 (P§5). If the decision rule picks a T, set `INCREMENTAL_MARK_SLICES` to it and flip
`INCREMENTAL_MARK = true`, then rerun every gate (P§6) in the default-on configuration, plus the
bootstrap fixed point. If no T passes the retention gate, try Plan B (P§3.4) once; if it still
fails, leave the flag off, record why, and hand the pacing problem to 5c.

### Step 10 — docs, invariants, tracking

P§8; THEORY.md (the "Mark" item and the state machine `Idle → Marking → Sweeping`: add the cycle,
the snapshot, allocate-black, the fixed schedule, the handoff); the master plan's tracking row and
§5 pause table; a loop entry `TG5a` in `benchmarks/gc-opt-loop.md`; snapshot `keep-TG5a`,
`bin/eco-opt-prev` = `eco-optTG5a`.

---

## 5. Measurement and experiments

All self-compile arms follow the GC-loop rules: one lowered binary per arm with the arm's values
as **compiled defaults** (env-free), a same-session control (`eco-optTG4b`), counters compared
only same-session, and the output artifact verified (`out_md5`), never the exit code.

**E0 — equivalence (after Step 3).** Flag on, T = 0, vs flag off, a pair of runs each:
- identical: minors, majors, objects allocated/promoted/copied, per-major live bytes and
  old-gen occupancy (major event log), max RSS within ±0.5 %, `out.mlir`;
- allowed to differ: `mark_units_done` (lower: nursery objects are no longer units), mark-stack
  peak, pause kinds (majors become kind 3);
- report the t0 snapshot's cost split: root scan, survivor walk (objects, bytes, ns), YLOS, the
  drained sweep.

If any decision counter differs, stop: the snapshot marks a different set from the STW trace.
Find the object with a **diff trace**, not a validator self-compile: add a CMake option
`-DECO_INCR_DIFF=ON` (off by default, stats builds only) under which the first major runs both
the STW trace (today's code, into a scratch copy of the mark bits) and the snapshot trace, and
prints the first 20 old-gen objects marked by one and not the other, with tag, size and block.
Delete the option once E0 passes.

**E1 — choosing T (after Step 8).** Arms T ∈ {0, 8, 16, 32, 64, 128}, one run each at first, a
triple for the two finalists. Record per arm:
- **old-gen peak** and max RSS (read first: M§2 retention gate);
- worst pause, and max/p99 per kind (0, 3, 4, 5, and 1 if any join/pressure finish happened);
- MMU at 10/50/100/200/500 ms and 1/2/5 s;
- majors (cycles), `incr_finish_*`, `closing_units` max and median, `black_bytes` per cycle,
  deferred frees;
- wall, GC time (minor, cycle in-pause total, handoff tails).

**Decision rule:**
1. Discard arms whose median old-gen peak exceeds the control's by more than **5 %** or whose
   max RSS exceeds **15 GB**.
2. Discard arms with any pressure finish or join on the self-compile.
3. Among the rest choose the arm with the **lowest worst pause**; break ties (within 10 %) by
   the larger T only if its MMU at 100 ms is better, else the smaller T (less retention).
4. Wall must be within +2 % of control (incremental marking does the same work plus overhead;
   a larger loss means a slice cost is out of line — investigate before accepting).

**E2 — trigger chaos check (after E1).** The TG2 rule: judge a trigger or retention change on a
`major_gc_garbage_fraction` sweep, never one run. Chosen T vs control at gf ∈ {0.65, 0.70, 0.75}:
majors and old-gen peak must move consistently with E1 (no arm where the chosen T adds more than
one major or +5 % peak over control).

**E3 — small heap (after E1).** The ~4 GB budget for normal programs (M§1 item 3): run E2E and
the stress suite with a 4 GB old-gen cap config at the chosen T. No pressure finishes in E2E; in
stress, pressure finishes are allowed but every run must pass. Record cycles, finishes and the
worst pause.

**What to watch.**
- A large **closing slice** means the predictor is low (live set growing faster than
  `predict_growth`); it makes the kind-4 max pause look like a small STW major.
- The **handoff tail** (kind 5) is today's sweep column; if it becomes the worst pause, record
  it as the next item (incremental classify/reclaim), not a 5a defect.
- The **t0 pause** (kind 3) includes any pending lazy sweep; if that dominates, record it.

---

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` | all pass, flag off and flag on (a second run with the flag-on test config) |
| G2 | elm-tests | the reference set |
| G3 | `--target full` | all pass, flag off and (Step 9) default-on |
| G4 | stress under GC pressure (Step 0's config) | 101/101, ≥ 20 cycles with ≥ 2 slices each (non-vacuous) |
| G5 | validate tree (P1 tripwire on; IM1–IM9; V1–V12) | zero `[heap-validate]` / P1 lines on unit, E2E, stress |
| G6 | stats-off `ecoc` | builds; `incremental_mark` works (the cycle code must not depend on stats types) |
| G7 | flag-off counters + `out.mlir` vs `eco-optTG4b` | identical (rule 1) |
| G8 | E0 | rule 2 |
| G9 | E1–E3 | the decision rule; recorded in P§10 |
| G10 | bootstrap fixed point | default-on build reproduces itself |
| G11 | static | `grep -n "GCPhase::Marking" runtime/src/allocator` shows only the cycle code and the (still unreachable) legacy `freeLargeBodyCell` arm; `startMark` has no `marking_active` early return |

---

## 7. Traps

1. **The bitmap is not the allocation map during a cycle.** Any code that treats a clear
   uniform bit as "free" while `cycleActive()` corrupts the heap. Today that is only the
   cursor, and it only sees post-t0 virgin blocks because the queues are empty. A future change
   that queues a block mid-cycle (e.g. `freeUniformCell` from an un-deferred free) reintroduces
   the bug. IM4's "was clear" check is the tripwire.
2. **`resetAllocCursors` must run before `finalizeMetaAfterMark` at the handoff**, or the
   cursors' `pending_live` is missing from the totals and a block full of in-cycle allocations
   can look all-dead and be released (the historical all-dead release bug, §3.5).
3. **The survivor prefix is exact only until the mutator allocates.** Take the snapshot in the
   same pause as the minor, before returning to the mutator. IM7 checks it.
4. **Never trace through a young object in a slice.** The nursery moves at every minor and
   from-space is poisoned; a YLOS object can die and be deferred. IM3.
5. **Promotions overwrite the header color with White.** Harmless (the bit is load-bearing),
   but it means no check may use `color` to decide black; use the bit.
6. **`mark_units_done` changes meaning** in the cycle path (old-gen objects only). Never compare
   it across the flag.
7. **The stress config may run no majors** (the vacuous-pass trap of the nursery zeroing loop).
   Count cycles and slices in G4.
8. **Counters are a program input** (TG3): compare only same-session, same-environment runs;
   same-source relowerings differ by a few copies (TG4b).
9. **A join must not run inside a slice**: `in_slice_` assert. A future caller that allocates
   old-gen memory from inside `markChildren` (none today) would hit it.
10. **Deferred frees keep memory until the handoff.** A program that churns large strings in a
    long cycle holds all of them; `incr_deferred_free_bytes` shows it. The pressure finish bounds
    it.
11. **The mark-loop alignment trap**: `incrementalMark` is now called with small budgets from a
    new call site; if slice cost per unit is out of line with STW mark, check that the loop stayed
    64-byte aligned before profiling.
12. **The P1 census O detector** keeps entries whose bit is set at `onMarkEnd`: with floating
    garbage it keeps more. That is correct; do not "fix" it.

---

## 8. Invariants (land in Step 10)

- **HEAP_063 IncrementalMarkCycle (new):** "WITH incremental_mark A MAJOR GC IS A MARK CYCLE
  SPANNING T + 1 MINOR GCS (plans/threaded-gc-05a-incremental-marking.md). The cycle starts at
  the end of the minor GC that fires a major trigger (t0): the old-gen targets of every root and
  off-heap store, and of every young object (the nursery's survivor prefix and every YLOS object),
  are greyed in that pause, and every YLOS cell is marked; after t0 the marker never reads a root
  or a young object. Slices of paced mark work run at the next T - 1 minor ends, the T-th drains
  the mark stack, and the post-mark tail (the handoff) runs at the (T + 1)-th: the schedule is
  fixed at t0 and depends on no mark progress (GC_DET_001), except an emergency finish when
  old-gen committed / cap >= incremental_mark_finish_fraction, or a join when majorGC() is called
  (which finishes the cycle, then runs the requested stop-the-world major). While a cycle is
  active: gc_phase_ == Marking; every old-gen allocation is allocated black (mark bit set, bytes
  in BufferMetadata::live_bytes); the uniform-block cursor serves only blocks created after t0;
  no block is released, no body or YLOS cell is freed (frees are deferred to the handoff), no
  compaction runs, and the major triggers are suppressed. Soundness rests on HEAP_005,
  HEAP_SNAPSHOT_001 and HEAP_SNAPSHOT_002; validators IM1-IM9."
- **HEAP_SNAPSHOT_002 (new, from §11.2):** "Every location that can be overwritten while Elm
  code runs is a stack or root slot or an off-heap store registered as an external root scanner.
  A marker reads such locations only at a handshake (the t0 snapshot of HEAP_063), never lazily."
- **HEAP_026:** add "while a mark cycle is active (HEAP_063), bodies whose header dies are
  unlinked at minor end but their cells are freed at the handoff".
- **HEAP_050:** `clearForMark` runs at t0 of a cycle as at a STW major.
- **HEAP_051:** allocate-black during a cycle writes only `BufferMetadata::live_bytes`; the
  accumulator's sum is the cycle's traced live.
- **HEAP_054:** "a uniform block's mark bitmap is its allocation map **outside a mark cycle**;
  during a cycle (HEAP_063) the bitmaps of blocks that existed at t0 are mark bits only, and no
  allocation is served from those blocks until the handoff re-queues them."
- **HEAP_056:** retirement runs at the handoff; deferred frees (HEAP_026 amendment) run just
  before it.
- **HEAP_057:** "with incremental_mark, L_i is the bytes traced by the cycle (allocate-black
  bytes excluded); triggers are not evaluated while a cycle is active."
- **GC_DET_001:** add "the mark-cycle schedule (HEAP_063) is fixed at t0".
- The master plan's 5a notes and M§5 pause table: fill in the measured row.

---

## 9. Forward contract for 5b and 5c

What 5a guarantees, and what each later phase must change:

| item | 5a | 5b (parallel slices) | 5c (collector threads) |
|---|---|---|---|
| handoff minor | t0 + T + 1, fixed | same | same: the mutator waits or assists at k = T if the collector is late |
| slice budget `b_k` | units on the mutator | the same units split across workers | becomes the collector's *assist* budget; the collector marks between minors |
| mark bits | plain RMW, one thread | `fetch_or` on `mark_.slot(id)` | `fetch_or`, or the SPSC allocation log so the collector is the only writer (§5.3 B) |
| `mark_live_` | one accumulator | one per marker, merged at the handoff | same |
| roots, off-heap stores, young objects | read at t0 only | same | same (the t0 snapshot stays on the mutator) |
| frees and releases | deferred to the handoff | same | same |
| blocks created mid-cycle | mutator-only metadata; the marker never needs them | same | the collector must not read `BlockInfo` fields the mutator writes (`alloc_state`); only t0 blocks' `start/size_class/is_large` |
| counters | the reference | bit-identical to 5a at `gc_threads = 1` and at `gc_threads = N` | identical to 5a in modes 0/1/2 and 2+jitter (the TG3 recipe) |

---

## 10. As-built deviations

Implemented 2026-09-26. Every step landed; the flag is **default-on, T = 32**.

### 10.1 Design deviations

1. **Pacing (P§3.5) was wrong as planned and was replaced after E1 round 1.**
   - The planned predictor (previous units × 1.25) under-shoots a growing heap: the major-GC
     mark units grow 2–3× per cycle early in the self-compile.
   - The planned budget spread the prediction over all T slices, so every under-prediction
     landed on the closing slice. Round 1 closing slices were 28–54 M units, i.e. 1–2 s, and
     they were the worst pause of every arm.
   - **As built:**
     - the prediction is previous units × max(1.25, occupancy at t0 / occupancy at the
       previous t0);
     - it is **front-loaded**: spread over the first ⌈T/2⌉ slices, leaving the second half as
       a buffer;
     - on an overrun (predicted units done, stack not empty) the prediction **doubles** and
       the rest is spread over the slices left before the closing one.
   - All of it is still a deterministic function of units done (GC_DET_001).
   - Round 2 closing slices: at most 2.9 M units at T = 32, and 0 in two of three E2 arms.
2. **The trigger baseline also excludes allocate-black bytes (P§3.6 only planned it for
   `major_live_`).**
   - Round 1 ran 5–6 majors against the control's 7, because each cycle's black bytes (up to
     8.5 GB in total at T = 128) raised `post_sweep_live_bytes_`, and so delayed the next
     trigger by that much.
   - `baseline_black_bytes_` now keeps the last cycle's black bytes counted as "allocated
     since the major" in `finalizeMetaAfterMark` and in `computeFragmentationStats`, as a STW
     major at t0 would have counted them. It is zero for a STW major, so flag-off stays
     bit-identical.
   - Round 2: 7 majors in every arm at gf 0.70.
3. **`forEachMajorRoot` covers stack-map slots, root ranges, single roots and external
   scanners.**
   - The long-lived and JIT roots stay in `startMark`, because the unit tests call it with
     explicit root sets.
   - `startMarkCycle` pushes those two kinds itself. `startMark`'s preparation became
     `prepareMark`, which `beginMarkCycle` shares.
4. **IM5** re-checks the list of t0 blocks (id, generation, start, size_class, is_large) at the handoff (the generation: CR-036, 2026-09-30, so a same-id, same-start re-issue is caught)
   instead of a hash.
5. **IM1/IM2** trace with `visitHeapChildren`. Tags it declines are not followed, which gives
   false negatives only.
6. **IM9** is a set of asserts: stack empty at the handoff, `!in_slice_` at a join, and
   `startMark` asserting no cycle is active. There is no per-step equality validator.
7. **Stats.**
   - `IncrMarkStats` lives in the old gen's `alloc_stats_` and is carried through
     `ElmE2ETestBase`'s POD for forked E2E/stress children.
   - The cycle columns are in a new event-log `cycle` row; the `MajorGCEvent` struct was not
     extended.
   - The t0 time is split into prepare (sweep drain + bitmap clear) and snapshot.
   - A `[gc-profile] cycle handoff …` line prints under `ECO_GC_PHASE_PROFILE`.
8. **Test hooks.**
   - `ThreadLocalHeap::test_force_major_trigger_`: the next minor end behaves as if a trigger
     fired.
   - `test_snapshot_skip_young_walk_` and `test_snapshot_skip_external_`.
   - `OldGenSpace::test_skip_allocate_black_`, honoured in both the cursor and the header-init
     path.
9. **`testIncrJoinOnYlosAllocFailure`** calls `majorGC(AllocFailure)` directly: the exact call
   the failure paths make. It does not engineer a real allocation failure.
10. **The negative controls** fork a child. In a validate build the child must abort; the
    intended validator was checked with `ECO_TEST_CHILD_STDERR=1`: IM1, IM1 and IM4. In other
    builds the child must observe the hole (the object is left unmarked).
11. **`OldGenBitmapAllocTest`'s legacy arm now sets `incremental_mark = false`.** `validate`
    rejects incremental marking without bitmap allocation, and the flag is now on by default.

### 10.2 Pre-existing issues found (not caused by this phase)

- The `ecor` target fails to link: `PermanentSpace::instance` is not in its source list.
- The unit property test "Roots remain marked Black after incremental mark steps" aborts on
  HEAP_044 (a generated 0-field Custom) under `ECO_HEAP_CONFIG` on some seeds. The untouched
  pre-5a tree aborts in 2 of 6 runs. The unit tests are not meant to run under that
  variable (they ignore it in the old gen).
- `[survivor-write-census] mismatched=1` (Array, YLOS) in validate unit runs is the same with
  the flag off: it comes from a deliberate-write census test.

### 10.3 E0 — equivalence (T = 0 vs flag-off, same binary)

Identical in both arms:
- minors 1924, majors 7;
- allocated 254,179,007;
- promoted 675,771,383;
- copied 744,250,343;
- old-gen peak 8,797.7 MB;
- every major-event column except mark units: before, after, garbage, recovered, minors,
  promoted.

Mark units are 1–10 % lower, as predicted: nursery objects are no longer units. The worst pause
went from 5,020 ms to 4,828 ms. The t0 snapshot cost at most 21 ms (188 MB of survivors over 7
cycles); the handoff tail at most 108 ms.

### 10.4 E1 — choosing T (self-compile, phase-timer build, gf 0.70)

Round 2 (as-built pacing and baseline):

| arm | wall (s) | max RSS (GB) | old-gen peak (MB) | majors | max pause (ms) | slice p99 / max (ms) | t0 max | handoff max | MMU 500 ms / 1 s / 2 s |
|---|---|---|---|---|---|---|---|---|---|
| control ×3 (median) | 171.0 | 9.78 | 8,797.7 | 7 | 4,832 | — | — | — | 0 / 0 / 0 |
| T = 16 | 169.9 | 10.97 | 10,023.8 | 7 | 583 | 551 / 583 | 134 | 156 | 0 / 3.7 / 6.1 % |
| **T = 32 ×3 (median)** | **170.2** | **9.84** | **8,935.7 (+1.6 %)** | **7** | **336** | **306 / 336** | **136** | **154** | **6.9 / 8.5 / 10.4 %** |
| T = 64 | 171.8 | 14.08 | 13,008.3 | 7 | 592 | 364 / 592 | 136 | 172 | 0 / 7.7 / 15.6 % |
| T = 128 | 169.8 | 13.04 | 12,010.8 | 7 | 264 | 147 / 264 | 133 | 155 | 16.3 / 19.3 / 23.6 % |

- The T = 32 triple's counters are identical across runs (deterministic); `out.mlir` is
  identical in every run.
- **Decision:** T = 32 is the only arm within the +5 % peak gate. It has no pressure finishes
  or joins, and its wall is flat.
- Round 1 (the planned pacing) had max pauses of 977–4,588 ms and peaks up to 14.4 GB, driven
  by the closing slices and the trigger-baseline effect (P§10.1 items 1–2).

### 10.5 E2 — trigger chaos check

| gf | control: majors / peak / max RSS / max pause | T = 32: majors / peak / max RSS / max pause |
|---|---|---|
| 0.65 | 8 / 9,841 MB / 10.88 GB / 2,742 ms | 7 / 13,248 MB / 14.31 GB / 392 ms |
| 0.70 | 7 / 8,798 MB / 9.78 GB / 4,832 ms | 7 / 8,936 MB / 9.84 GB / 336 ms |
| 0.75 | 5 / 13,317 MB / 14.47 GB / 2,708 ms | 6 / 9,676 MB / 10.61 GB / 234 ms |

**The plan's per-point E2 criterion fails at gf 0.65** (+35 % peak), and the opposite happens
at gf 0.75 (−27 %). This is the documented chaotic trigger (TG2: 8.8–16.2 GB across gf
0.65–0.75 in legacy mode), not a systematic cost:
- over the sweep, the median peak is 9.84 GB (control) vs 9.68 GB (T = 32), and the highest
  max RSS is 14.47 vs 14.31 GB, both under the 15 GB budget;
- majors stay within ±1 at every point;
- the worst pause is 234–392 ms at every point, against 2.7–4.8 s for the control.

The default was flipped on this sweep-level evidence. Record for 5c: heap-relative pacing
of the trigger is where the retention variance should be attacked.

### 10.6 E3 — 4 GB cap (pressure config, max_heap_size 4G, T = 32)

- E2E: 940/940, with 4 cycles and 0 pressure finishes.
- Stress: 101/101, 21 cycles, 0 pressure finishes.
- Unit + E2E together: 1830/1830. The unit tests' forced joins and pressure finishes are
  deliberate test scenarios.

### 10.7 Gates

| gate | result |
|---|---|
| G1 | `build/test/test` 1830/1830 flag-off, 1830/1830 flag-on (pressure-incremental config), 1830/1830 default-on |
| G2 | elm-tests 13,565 passed / 12 failed: the reference set, unchanged from TG4b |
| G3 | `full` 1830/1830 (default-on) |
| G4 | stress 101/101 default-on (the default pressure config runs 21 cycles × 32 slices: non-vacuous) and 101/101 with `heap-config-gc-pressure-incremental.json` (22 cycles × 4 slices) |
| G5 | validate tree: unit + E2E 1831/1831 default-on with zero `[heap-validate]` lines; stress 101/101 on both configs with zero lines; the 25 phase tests, including the three negative controls, abort on the intended validator |
| G6 | stats-off `ecoc` builds |
| G7 | flag-off vs `eco-optTG4b`, same session: every counter and the major event log's non-timing columns identical; `out.mlir` identical |
| G8 | E0 as above |
| G9 | E1–E3 as above; the E2 caveat is recorded |
| G10 | fixed point: `eco-optTG5a` (default-on, compiled defaults: 7 cycles, 224 slices, wall 167.5 s, max RSS 9.84 GB) builds itself to `out.mlir` md5 933c3ff0d288; that output lowered to `eco-optTG5aB` reproduces it byte-for-byte |
| G11 | `startMark`'s early return is guarded by `assert(!cycleActive())`; `GCPhase::Marking` is written only by `beginMarkCycle` |

## 11. Done means

- The flag and its knobs exist; flag-off is bit-identical to `eco-optTG4b`; T = 0 reproduces
  every decision counter.
- The chosen T (or Plan B, or a recorded closure) passes the retention gate, and the worst pause
  on the self-compile is recorded against TG3's ~5.2 s.
- IM1–IM9 run green on unit, E2E and stress; the three negative controls fire.
- HEAP_063 and HEAP_SNAPSHOT_002 are in `invariants.csv`, the amendments are made, THEORY.md
  describes the cycle, the master plan's row and pause table are filled in, and `keep-TG5a` is
  snapshotted.
