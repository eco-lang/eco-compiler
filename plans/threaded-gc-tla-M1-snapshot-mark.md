# Threaded GC — TLA+ model M1: the snapshot marking cycle

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). **Adversarial review on 2026-09-28 against the
current tree** (§11): the sketch was corrected (pressure order, handoff frees unmarked YLOS cells,
region mode's dead hand-over objects, a meaningful `lazy_external`, the two "to add" mutants), the
§4.7 invariant was strengthened, and a suspected code defect was found (§2.5, §10 Q4). The
corrected sketch passes the translator and SANY (tla2tools 1.8.0); TLC has not run. Every
"expected" result below is a prediction for the implementer to confirm.

**Parents:** `plans/threaded-gc-tla-verification.md` (§2 rules A1–A9, §5.1 index) and
`plans/threaded-gc-tla-primer.md`. Read the primer first if TLA+ or the GC terms are new. Its
glossary defines *mutator*, *nursery*, *promotion*, *mark bit*, *grey set*, *snapshot / t0*,
*allocate-black*, *handoff*, *builder*, *young large object (YLOS)* and *frozen published heap
(P1)*.

**Sibling models:**
- M1 assumes M2's **Drain** contract (the marker loop empties the grey set exactly once, and a
  stop leaves every unscanned entry in a deque), M6's **LaunchJoin** contract, and, for region
  mode, M5's **TenureDisjoint** contract (M5's `HealYoungOnly` and `MarkerDisjoint`, §2.5).
- M1 provides the **SnapshotCycle** contract that M4 and M5 use (parent plan §5.0). It is
  discharged by `IM2` at `H_Free` (every reachable old-gen cell is marked), `NoReleaseInCycle`
  (IM5) and `MarkerFootprint` (markers touch only t0-old cells, the premise of every plain
  `setBit` on a post-t0 block). In region mode `MarkerFootprint` fails today (§10 Q4), so that
  last part holds for legacy mode only until the fix.
- Byte-level mark races and cursor ownership (IM13) belong to M4. The 7c tenure job belongs to M5.

**Why M1 matters most:** phases 5a (incremental), 5b (parallel) and 5c (concurrent) marking, and
7c (concurrent tenuring), all rest on one argument: the snapshot-closure lemma
(`design_docs/parallel-gc.md` §2.1). Today that argument is a proof sketch in a design report.
If it is wrong, or the code breaks one of its premises, the marker silently misses a live object,
and the sweep frees it. M1 makes the argument machine-checked, at small scale for the running code
and without a size bound for the lemma itself (§4.7).

---

## 1. What the model checks, in one paragraph

A major collection has to find every live old-gen object, so that the sweep frees only garbage.
Eco's collector finds them while the program keeps running (5c), or spread over several short
pauses (5a). It does this without the write barrier that concurrent collectors normally need. It
photographs every root once, at **t0**, and then relies on three facts:
1. objects that existed at t0 never change (P1);
2. everything allocated in the old gen after t0 is born marked (allocate-black);
3. nothing that existed at t0 is freed before the cycle ends (IM5).

M1 is a small heap (five objects, two roots and one off-heap store) under a mutator that loads,
drops, stores, allocates and fills builders, interleaved with minor GCs, background marking, fork
stops, paced assists, pressure finishes and emergency majors. It checks that no reachable object
is ever freed. For each premise, a broken variant shows the exact interleaving that loses an
object when the premise fails.

## 2. The protocol in plain words

### 2.1 The pieces

- **Young and old objects.** New objects are young (in the nursery, or in the young large-object
  space if they are big). A minor GC keeps the reachable young objects. One that has already
  survived a minor is **promoted** to the old gen (`promotion_age = 1`). Old objects are only
  reclaimed by a major collection's **sweep**, which frees every old object whose mark bit is
  clear.
- **HEAP_005: no old → young pointer.** An Elm object can only point at objects that existed
  before it, and objects are promoted in age order. So an old object never points at a young one.
  The minor GC therefore never needs to scan the old gen, and the marker never needs to look at the
  nursery.
- **Mark bits and the grey set.**
  - Greying an old object sets its mark bit (`testAndSetMark`, `OldGenSpace.cpp:3039`) and puts it
    on the grey set.
  - Scanning a grey object (`scanObject`, `OldGenSpace.cpp:3367`) greys its old children.
  - When the grey set is empty, every old object reachable from the initial greys is marked.
- **The t0 snapshot** (`ThreadLocalHeap::startMarkCycle`, `ThreadLocalHeap.cpp:1065`). It runs
  at the end of the minor GC whose trigger fires, while the mutator is stopped. It greys:
  - the old target of every root: stack slots, RootSet roots, JIT roots, root ranges
    (`ThreadLocalHeap.cpp:1090-1095`);
  - the old target of every **off-heap mutable store** registered as an external root scanner,
    i.e. CellStore cells and trail, MVar, scheduler queues (the `kind == 2` branch at `:1093`;
    HEAP_SNAPSHOT_002);
  - every young large object's own cell, plus its old children (`snapshotYoungLarge`,
    `OldGenSpace.cpp:4173`, called at `ThreadLocalHeap.cpp:1096`);
  - the old children of **every** young object (`nursery_.forEachYoung(... markChildren ...)`,
    `ThreadLocalHeap.cpp:1102`; `NurserySpace::forEachYoung`, `NurserySpace.hpp:800`).

  Before any of this, `beginMarkCycle` (`OldGenSpace.cpp:4084`) clears every mark bit
  (`prepareMark` → `clearForMark`, `:4091`). **After t0 no root is ever read again.**
- **Allocate-black.** While a cycle is active, every old-gen allocation sets the new cell's mark
  bit at once:
  - `initObjectHeaderWithSize`, `OldGenSpace.cpp:487` (the branch at `:497`);
  - the bitmap cursor's `finalizeBitmapCell`, `:802`;
  - the parallel-minor promotion paths `finalizeBitmapCellW`/`finalizePoppedCellW`;
  - the 7c grant's `grantAllocate` (`OldGenTenure.cpp:153`).

  That covers promotions and young large objects (`allocateYoungLarge` goes through the same
  allocator, `OldGenSpace.cpp:7077`), and the direct old-gen allocations (pointer-free large
  objects, split-header bodies, permanent literals). The cursor paths (`finalizeBitmapCell`,
  `finalizeBitmapCellW`, `grantAllocate`) set the bit with a **plain** `setBit`: they rely on
  their block being post-t0, where no marker ever writes (IM13). `MarkerFootprint` is the model
  form of that premise.
- **Steps, the closing join, the handoff.** The cycle lasts `T + 1` minor GCs (HEAP_063):
  - at each of the next T minor ends, `stepMarkCycle` (`ThreadLocalHeap.cpp:1143`) increments `k`
    (`:1144`), checks the pressure finish **first** (`:1149`, below), and otherwise runs one step
    (`runCycleStepConcurrent`, `OldGenSpace.cpp:4660`): it reaps or relaunches the background
    episode (`:4688-4699`), and while the episode is `Running` may run a paced **assist**
    (`:4707-4744`);
  - at step T the **closing join** (`closingFinish`, `:4569`) drains whatever is left and ends
    with `bg_ep_ = None` (`:4635`);
  - at the following minor the **handoff** (`completeMarkCycle`, `ThreadLocalHeap.cpp:1191` →
    `handoffMarkCycle`, `OldGenSpace.cpp:4258`) ends the cycle, and the tail sweeps everything
    still unmarked.
- **Background episode (5c).** Background threads mark while the mutator runs Elm code *and while
  it runs minor GCs*. `launchBackground` (`:4431`) starts them at the end of the t0 pause.
  `reapBackground` (`:4505`) joins them when they finish. A **fork hook** can stop them
  (`stopAllForFork`, `GCHelperPool.cpp:650`). The stop does not touch `bg_ep_`: it stays `Running`
  until the mutator's next reap sees `done == false` and sets `None` (`:4524`); the step then
  relaunches with the unscanned work still in the deques (`:4689-4692`).
- **Pressure finish and emergency join.**
  - If the old gen gets too full mid-cycle, `cyclePressureFinishDue` (`:4246`) makes the pause
    drain everything and hand off at once. It is checked before the step (no reap or relaunch
    first), at any `k` including `k = T`.
  - A STW major (an allocation failure or an explicit major) **joins** a running cycle first:
    `ThreadLocalHeap::majorGC` calls `finishMarkCycleNow(Join)` (`ThreadLocalHeap.cpp:797`), and
    only then runs its own full mark and sweep.
- **Deferred frees (IM5, IM8).** When a young large object dies at a minor during a cycle, its
  old-gen cell is not freed. `sweepNurseryLargeBodies` (`OldGenSpace.cpp:7210`) pushes it onto
  `deferred_frees_` (`:7288`), and the handoff frees it (`processDeferredFrees`, `:4754`, called
  from `runPostMarkTail` `:3953`). The same deferral covers split-header large bodies (large
  strings and byte buffers, kind 0), which hold no pointers. Every release path asserts
  `!cycleActive()` (plain `assert`s: on in the `build` and `dev` presets, off in `Release`, where
  `ECO_ASSERTS_ON` defaults to OFF):
  - `freeLargeBodyCell`, `:7313` (assert `:7316`);
  - `releaseBlockToAllocator`, `:5996`;
  - `:6136`, `:6416`, `:6490`.
- **The tail sweep also frees unmarked young large objects.** `runPostMarkTail` →
  `classifyBlocksAfterMark` (`:3988`) → `retireDeadLargeBodies` (`:1657`) retires every indexed
  body or YLOS cell whose mark bit is clear. So a live YLOS must be marked at the handoff (marked
  at t0 by `snapshotYoungLarge`, or allocated black), exactly like a live old object. The model's
  `Handoff`, `J_STW` and `IM2` therefore range over **old-gen cells** (`CellObjs`: old objects
  plus young large objects).

### 2.2 One cycle, step by step (T = 2)

```
minor m    (t0)    minor GC; trigger fires; snapshot: grey roots' old targets, off-heap
                   stores' old targets, YLOS cells + old children, old children of every
                   young object. Launch background markers.
  ... mutator runs: loads, stores, allocations; markers scan the grey set ...
minor m+1  (k=1)   minor GC (promotions are allocated black); reap / relaunch; maybe an assist
  ... mutator runs; markers scan ...
minor m+2  (k=2=T) minor GC; closing join: drain the grey set to empty; state = HandoffDue
  ... mutator runs (nothing left to mark) ...
minor m+3          minor GC; handoff: free every old object whose mark bit is clear,
                   and every deferred free; state = Idle
```

### 2.3 Why it is correct: the argument M1 checks

Let **S_H** be everything reachable at t0 (young and old) and **N_H** everything allocated after
t0.
- **The snapshot-closure lemma:** at every later moment every reachable object is in S_H ∪ N_H.
  - The mutator gets pointers only by allocating (N_H), by reading a root, or by reading a field of
    an object it holds.
  - Every store (into a root, an off-heap store, a new object, a builder, or even, illegally, a
    survived object) writes a value the mutator already held.
  - So the lemma needs only "no hidden roots" (HEAP_SNAPSHOT_002 and the rooting discipline), not
    P1. The model shows this: `SnapshotClosure` is inductive on its own, and only `hidden_root`
    breaks it (§4.7). `parallel-gc.md` §2.1 states the lemma under P0, which is stronger than it
    needs. **P1 is needed in step 1 below**: the marker traces the *current* heap, and only P1
    makes that the t0 graph.
- Now split the reachable **old** objects at handoff into three groups:
  1. **Old at t0 and in S_H.** They are reachable at t0 through a path from a root, an off-heap
     store or a young object. The snapshot greyed the first old object on every such path. P1
     means every old field is still what it was at t0, so tracing the *current* heap from those
     greys walks exactly the t0 graph. When the grey set is empty they are all marked. This is
     IM1.
  2. **Young at t0 (in S_H), promoted since.** Their promotion was an old-gen allocation during
     the cycle, so they are marked (allocate-black). Their old children at t0 were greyed by the
     young walk.
  3. **In N_H and old.** Allocated, or promoted, after t0: allocate-black.
- Nothing else can be reachable (the lemma), so every reachable old object is marked (IM2), and
  the sweep frees only garbage.
- The marker never needs a write barrier: overwriting a root or an off-heap store after t0 cannot
  hide an object, because its old value was captured at t0.

### 2.4 How it breaks: worked timelines

All timelines start from the model's initial heap (§6): old objects `1 → 2` and `4`, a young
object `3 → 4`, roots `r1 → 1` and `r2 → 3`, an empty off-heap cell `c1`.

**(a) A kernel overwrites a field of a survived object (P1 violation).** This is the classic
"deleted edge" problem that barrier-based collectors solve with a Yuasa deletion barrier.

| # | Mutator | Marker | Grey set | Marked |
|---|---|---|---|---|
| 1 | minor + t0 snapshot: `r1 → 1` greys 1 | | {1, 4} | {1, 4} |
| 2 | `r2 := 1.f` (the mutator now holds 2 in a root the snapshot has already read) | | | |
| 3 | kernel writes `1.f := nil` (**P1 broken**) | | | |
| 4 | | scans 1: its only field is nil | {4} → {} | {1, 4} |
| 5 | … closing, then handoff: 2 is old, unmarked, reachable from `r2` | | | |
| 6 | **the sweep frees 2 while `r2` points at it** | | | |

2 was reachable at t0, but only through 1's field. The field was erased before the marker read it,
and the root that holds 2 now was photographed before it held 2. HEAP_SNAPSHOT_001 forbids step 3.
Phase 4's census found zero violations at full scale, and a code search on 2026-09-28 (runtime
helpers, `RuntimeExports.cpp`, every kernel, the 7c merge) found no violating write either. Validate
builds **detect** a violation; they do not prevent it:
- detector O re-hashes a sample (1 in `ECO_P1_CENSUS_SAMPLE`, default 16) of promoted objects;
- detector N re-hashes nursery and YLOS survivors at the next minor;
- detector W covers only the four helpers that call `p1::noteWrite` (`arrayPush`,
  `arrayPushKind`, `closureCapture`, `listChainFill`).

`p1::verifyOldGen` at cycle start (`ThreadLocalHeap.cpp:1076`) checks writes made *before* t0. A
write during a cycle is seen at the next verify (every 64 minors, a major start, the next cycle
start, exit), which may be after the handoff has freed the object.

**(b) No allocate-black.** 3 is young at t0 (it survives the t0 minor, age 1). At minor m+1 it is
promoted: it becomes an old object that nobody greys (the marker only greys objects reachable from
old greys, and nothing old points at 3). If the promotion does not set its mark bit, the handoff
frees 3 while `r2` still points at it.

**(c) A release during the cycle (IM5).** After t0: `r2 := 1.f` (holds 2), then drop `r1` (1 is now
garbage), then some runtime path frees 1 before the marker scans it. The marker skips the freed
entry (`scanObject` returns early on `Tag_Free`, `OldGenSpace.cpp:3374`). 2 was reachable at t0
only through 1 and is never greyed, so it is freed at handoff. **This is why nothing that existed
at t0 may be freed until the handoff, even after it has become garbage:** a dead pre-t0 object can
still be the marker's only path to a live one.

**(d) The t0 pause skips the young walk.** 4 is reachable at t0 only through the young object 3. The
roots' old targets never lead to 4. 3 is promoted black at minor m+1, and black objects are never
scanned (their children were supposed to be greyed at t0). So 4 is never marked. This is the
`test_snapshot_skip_young_walk_` negative control (`ThreadLocalHeap.cpp:1099`,
`testIncrNegativeSkipYoungWalk`, `test/allocator/IncrementalMarkTest.cpp:875`).

**(e) An off-heap store read lazily instead of at t0.**
1. Before t0: `c1 := 1`, drop `r1`. Now 1 is reachable only from the CellStore.
2. The snapshot does not read `c1`.
3. After t0: `r1 := c1`, `c1 := nil` (in the model, `c1 := r2`: any value that is not an old
   object).
4. A marker that reads `c1` now sees nil.

1 is held by a root photographed before it held 1, and the store that held 1 at t0 was never read
in time. HEAP_SNAPSHOT_002 requires every overwritable location to be a root or a registered
external scanner **read at t0**. See `test_snapshot_skip_external_` (`ThreadLocalHeap.cpp:1093`,
`testIncrNegativeSkipExternal`, `IncrementalMarkTest.cpp:893`).

### 2.5 Region mode (7b/7c): only what M1 needs

With `nursery_regions` on (the default since TG7d), "young" also covers two things:
- the survivor extents (**Fresh** and ageing extents);
- the **Tenuring** extent, whose objects a background tenure job promotes during the epoch after
  the minor that handed it over.

For M1 this changes three things:
- **The young walk.** `forEachYoung` walks every Young extent and the Tenuring extent
  (`NurserySpace.hpp:800-830`), skipping only `Tag_Free` fillers. With the default tenure age
  k = 1 the Tenuring extent is the one filled at the previous minor. Its objects that died during
  the last epoch are **not** zapped: only ageing extents are (`mergeJob`,
  `NurseryTenure.cpp:816-825`, whose comment names the hazard: "no walker (t0 young walk, …) reads
  its possibly dangling slots"). So the walk greys the old children of dead objects too. The
  07 plan (P§3.16) calls this "conservative and safe". **It is not safe after a STW major in that
  epoch:** a STW major marks from roots only (`startMark`, `OldGenSpace.cpp:2867-2900`), so it
  frees an old object whose only referrer is such a dead object. The t0 walk then greys a freed
  cell (§10 Q4, a suspected defect). The model reproduces this with `RegionMode = TRUE`: the minor
  keeps the dead age-1 objects as `zombie`s until the next minor, and P_T0 walks them.
  `MarkerFootprint` (`grey ⊆ t0Old`) then fails in the `quick_region` configuration.
- **Allocate-black.** The tenure job's copies are allocated from a grant whose `grantAllocate` sets
  the bit, which is the mark mid-cycle (`OldGenTenure.cpp:153-195`).
- **The STW-major join.** It joins and merges the tenure job before joining the cycle
  (`ThreadLocalHeap.cpp:791`, then `:797`). Its legacy mark greys a Tenuring object's copy
  instead of the object (`majorRedirect`, `OldGenSpace.cpp:3126`).

In M1 a "promotion" is one atomic step of the minor. That is sound for region mode **only if** the
tenure job's footprint is disjoint from the markers' (07 plan §3.16: "a background marker reaching a
young object: impossible"). **M5 checks that disjointness. M1 assumes it** and records the
assumption in MAPPING.md. The assumption is M5's **TenureDisjoint** contract (provided by M5,
used by M1; proposed for the parent plan's §5.0 in M5's 2026-09-28 review). M5 discharges it with
two invariants:
- `HealYoungOnly`: the merge's heal writes only slots of young objects, or of young YLOS
  (`evacuateR` records a heal slot only for fill copies or young YLOS, `NurseryRegion.cpp:470`);
- `MarkerDisjoint`: during a cycle the markers' closure holds no young cell, no grant cell and no
  black copy, and every copy a job makes mid-cycle is black.

`CollectorPrivate` (FORBID_HEAP_004) and `OldPointsOld` (HEAP_005 as amended) back them up. The
merge's writes into a YLOS it has just promoted in place (below) rely on M5's YLOS extension (M5
§8.2). None of these yet requires the t0 greys to be *allocated* cells, which is what §10 Q4
breaks.

Region mode also promotes one minor later than M1 does (the job copies an object during the epoch
after its hand-over, and the merge publishes it). For M1 that only shifts the minor at which `gen`
flips; the copy is black either way.

The merge also writes old objects in one place: `promoteYoungLarge(y)` and then the heal of `y`'s
child slots (`NurseryTenure.cpp:731-743`). `y` was young at t0, so it was marked by
`snapshotYoungLarge` or allocated black, and no marker ever scans it. This is one of the GC's own
identity-preserving fixups that HEAP_SNAPSHOT_001 excludes. In M1 it is part of the atomic
promotion.

## 3. The code the model covers

Line numbers are for the tree of 2026-09-28, after the 7c pull.

| Code | Where | Model element |
|---|---|---|
| minor pause: tenure join, minor GC, cycle step or trigger, tenure launch | `ThreadLocalHeap::minorGC`, `ThreadLocalHeap.cpp:706` (step at `:761`) | procedure `MinorPause` |
| the t0 snapshot | `ThreadLocalHeap::startMarkCycle`, `:1065-1140` | step `P_T0` |
| clear marks, cycle state, MarkView | `OldGenSpace::beginMarkCycle`, `OldGenSpace.cpp:4084` (`prepareMark` `:4091`, `gc_phase_ = Marking` `:4140`) | `mark := ...` in `P_T0`; `cycle := "marking"` |
| YLOS cells at t0 | `snapshotYoungLarge`, `:4173` | `ylos`, `ylosOld` in `P_T0` |
| the young walk | `NurserySpace::forEachYoung`, `NurserySpace.hpp:800` (region: Young extents + Tenuring, dead objects included) | `youngOld` in `P_T0` (region: `zombie` too) |
| region mode: dead ageing objects zapped, dead hand-over objects not | `mergeJob` zap, `NurseryTenure.cpp:816-825`; hand-over at `NurseryRegion.cpp:1075-1085` | `zombie` in `P_Minor` (`RegionMode`) |
| off-heap stores at t0 | `forEachMajorRoot` `kind == 2`, `ThreadLocalHeap.cpp:1028`, `:1092-1095` | `cellOld` in `P_T0` |
| launch the background episode | `afterSnapshot` `:4649` → `launchBackground` `:4431` | `episode := "running"` |
| background marking | `bgEntry` `:4404` → `runMarkerLoop` (M2) → `scanEntry`/`scanObject` `:3448`/`:3367` | process `Marker`, macro `ScanOne` |
| young objects never reach a marker | `greyObject` abort on `young_in_view`, `:3094`; IM3 | invariant `MarkerFootprint` |
| a freed entry is skipped | `scanObject`'s `Tag_Free` check, `:3374` | `ScanOne`'s `o \notin alloc` branch |
| step: reap, relaunch, assist, closing | `runCycleStepConcurrent`, `:4660-4752` (reap/relaunch `:4688-4699`, closing `:4700-4706`, assist `:4707-4744`); `assistEpisode` `:4534`; `closingFinish` `:4569` (ends `bg_ep_ = None`, `:4635`) | `P_Marking`, `P_Decide`, procedures `Assist`, `DrainAll` |
| fork stop | `GCBackgroundGang::stopAllForFork` (`GCHelperPool.cpp:650`: `stopAndJoin`, `bg_ep_` untouched) → the next `reapBackground` (`done == false` → None, `OldGenSpace.cpp:4524`) | process `Forker` (both in one step); relaunch in `P_Marking` |
| pressure finish | `stepMarkCycle` `:1149`, checked before `cycleStep` at any `k` → `finishMarkCycleNow(Pressure)` `:1178` → `drainCycleMark` `OldGenSpace.cpp:4195` | the `either` in `P_Marking`, `P_Pressure` |
| handoff | `completeMarkCycle` `:1191` (IM1 `:1194`, IM2 `:1199`) → `handoffMarkCycle` `OldGenSpace.cpp:4258` → `runPostMarkTail` `:4305` | procedure `Handoff`, invariants `IM1`, `IM2`, `IM9` |
| emergency / explicit major joins | `ThreadLocalHeap::majorGC`, `:783` (join `:797`) | procedure `MajorPause` |
| allocate-black | `initObjectHeaderWithSize` `OldGenSpace.cpp:487/497`; `finalizeBitmapCell` `:802`; `finalizeBitmapCellW` `:1121`; `finalizePoppedCellW` `:1069`; `grantAllocate` `OldGenTenure.cpp:153` | `mark` set on promotion in `P_Minor` and on YLOS allocation |
| deferred frees | `sweepNurseryLargeBodies` `:7210` (defer `:7288`); `processDeferredFrees` `:4754` (from `runPostMarkTail` `:3953`) | `deferred` in `P_Minor`, freed in `H_Free` |
| the tail frees unmarked YLOS cells | `classifyBlocksAfterMark` `:3988` → `retireDeadLargeBodies` `:1657` | `CellObjs` in `H_Free`, `J_STW`, `IM2` |
| IM5 asserts | `freeLargeBodyCell` `:7313`; `releaseBlockToAllocator` `:5996`; `:6136`, `:6416`, `:6490` | invariant `NoReleaseInCycle` |
| IM1/IM2 validators | `traceOldReachableForValidation` `ThreadLocalHeap.cpp:1291`; `assertAllMarked` `OldGenSpace.cpp:4792` | invariants `IM1`, `IM2` |

**Deliberately outside M1:**
- how the markers share work and terminate (M2's Drain contract);
- mark bytes shared by 8 slots, cursor ownership IM13, allocate-black racing a marker on one byte
  (M4);
- the tenure job (M5);
- gang launch and join publication (M6);
- live-byte accounting (IM6), pacing and triggers (policy; GC_DET_001 is IM16's job).

## 4. The model

### 4.1 Abstractions, and why each is sound

| Real thing | Model | Why it is sound |
|---|---|---|
| Heap objects with tags, sizes, unboxed fields | Ids `Obj` with one or two pointer `Fields` | Only the pointer graph matters for reachability |
| Minor-GC copying (new addresses) | The same id; `gen` changes on promotion | Identity is preserved (parallel-gc.md §2.1: "minor GC relocates objects but preserves identity") |
| The minor GC, which runs *while background markers run* | **One atomic step** (`P_Minor`) | At the object level its footprint (young objects, roots, promotions into post-t0 cells, the YLOS index, `deferred_frees_`) is disjoint from the markers' (t0-old objects and their mark bits; markers read only the t0 `MarkView`, never the live YLOS index or nursery bounds). The model **checks** that part instead of assuming it: `MarkerFootprint` requires every grey object to be a t0-old object whose children are old. The **metadata** both sides touch is delegated, not checked here: mark bytes shared by a promotion's allocate-black and a marker's test-and-set (M4, W3); blocks and page-index entries published by promotion growth and read by `blockIdFor` (W4); `live_bytes` (atomic `fetch_add`, markers use their own accumulators). |
| B background markers, F foreground assist or closing members | One `Marker` process plus the mutator's in-pause `DrainAll`/`Assist`, each scanning **one grey object per step** | Two arguments, and only the first is M2's. **(1) M2's Drain contract**, discharged in M2 as `ScanOnce ∧ TerminationSafe ∧ Drain`: the loop scans each grey entry once and terminates only when no entry is left anywhere. **(2) M1's own argument that one atomic scan per step is enough.** M2 greys a scan's children one `fetch_or` per step, so a real scan is not atomic to the mutator. It looks atomic to everything M1 checks because: the scanned object's fields do not change during the cycle (P1, `FieldsFrozen` in §4.7); mark bits only go from 0 to 1 until the handoff; the per-child test-and-set is an atomic RMW, so two markers racing on one child grey it once (M2's `ScanOnce`; byte sharing is M4/W3); and no mutator step M1 models reads a t0 block's mark bit or a grey entry (pacing reads counters, which is policy), so the mutator cannot observe a half-done scan. Then every interleaving of partial scans reaches the same marked set as some sequence of whole scans. Under `p1_violation` a field write can land between two child steps of one real scan. M1's atomic scan still admits both orders (write before scan, write after scan), which is all timeline (a) needs. |
| `bg_ep_` and the gang's `running()` | one variable `episode` | The fork hook's `stopAndJoin` and the mutator's next reap (`done == false` → `None`) are one `Forker` step. Between the two, the code's `bg_ep_` is still `Running` with no member running: the only mutator decision that reads it there is the assist gate, and an assist joined to a stopped control scans nothing, while the model's `Assist` may scan. That over-approximates marking progress, and the closing drain empties the grey set either way |
| 5b in-pause slices (`conc_mark = 0`, `runCycleSlice`) | not a separate mode | A slice is `Assist` with no background episode. Every slices-mode behaviour is a concurrent-mode behaviour in which the `Marker` never steps (safety checking explores those) |
| Scanning an object (children read, then test-and-set per child) | One step | Under P1 the scanned object's fields do not change, so reading them together is equivalent. Per-byte races are M4's. With the `p1_violation` mutant the write still interleaves with the whole scan, which is what (a) needs. |
| Mark bits in bytes shared by 8 slots | One Boolean per object | Byte sharing and plain-vs-atomic RMW are M4's (§3 of M4). M1 needs "marked or not". |
| Blocks, cursors, the page index | Not modelled | IM13 (a cursor never owns a t0 block) and block publication are M4/W4. M1's allocate-black is "the promoted object's bit is set in its promotion step". |
| Roots of all kinds (stack maps, RootSet, JIT, ranges, single roots) | `RootSlots` | They are all read in the same t0 pause, and none are read after it |
| External root scanners (CellStore cells and trail, MVar, scheduler queues) | `CellSlots` | Off-heap, overwritable at any time, read at t0 (HEAP_SNAPSHOT_002) |
| `promotion_age = 1`, builders keep age 0 | `age ∈ 0..1`; a builder is never aged or promoted | HEAP_BUILDER_001/002 |
| Region mode (`nursery_regions = 1`, tenure age k = 1): the hand-over extent keeps its dead objects until the next minor retires it, and the t0 walk reads them | `RegionMode`: `P_Minor` keeps dead age-1 objects as `zombie`s for one minor; `P_T0` walks them | Exactly the code's window (§2.5). Live hand-over objects are promoted in `P_Minor` (one minor early, black if a cycle runs), so only the dead ones need the extra state. `RegionMode = FALSE` leaves `zombie` empty, so `quick` is unchanged |
| Pacing: when to assist, pressure | Nondeterministic choices in `P_Marking` (pressure) and `P_Decide` (assist) | Every real schedule is a model schedule. The fixed schedule (handoff at minor t0 + T + 1) is kept exactly, because it is a decision rule (GC_DET_001) |
| Old garbage collected before the cycle | Only by `MajorPause`'s STW step (it also frees unreachable young large objects, as the code's tail does) | Keeps the state space small. Pre-cycle collection adds nothing to the snapshot argument, except in region mode, where it is what leaves a zombie's field dangling |
| A freed id reused by a later allocation | Allowed (`Obj \ alloc`) | `NoLostObject` is checked in every state, so a wrongful free is caught in the state right after it, before any reuse |

### 4.2 Constants

| Constant | Meaning | Code value | Model values (quick / deep) |
|---|---|---|---|
| `Obj` | object ids | the heap | `{1..5}` / `{1..6}` |
| `Nil` | the null / constant slot value | `ptr_ind` constants | a model value |
| `RootSlots` | stack and RootSet slots | many | `{"r1","r2"}` |
| `CellSlots` | off-heap mutable stores | CellStore, MVar, queues | `{"c1"}` |
| `Fields` | pointer fields per object | 1–32 | `{1}` / `{1,2}` |
| `YlosIds` | ids that are young large objects while young | size ≥ threshold | `{5}` |
| `InitAlloc`… `InitCell` | the starting heap (§6) | | `MC.tla` |
| `T` | `incremental_mark_slices` | 32 | 2 |
| `MaxMinors`, `MaxMajors`, `MaxOps` | exploration bounds | | 4, 1, 2 / 6, 2, 3 |
| `AssistMax` | entries per assist | the paced `b_k` | 1 |
| `MaxStops` | fork-hook stops | | 1 / 2 |
| `SyncMark` | `conc_mark = 1` (mark all at t0) | 2 (default) | FALSE; `quick_sync` TRUE |
| `RegionMode` | `nursery_regions = 1`, k = 1: dead hand-over objects stay until the next minor | 2 = auto → 1 (default since TG7d) | FALSE; `quick_region` TRUE |
| `MUTANT` | negative control | | §5 |

### 4.3 Variables

| Variable | Meaning | Code counterpart |
|---|---|---|
| `alloc` | allocated objects | live cells and nursery objects |
| `gen[o]` | `"young"` or `"old"` | nursery / YLOS vs old gen |
| `age[o]` | minors survived while young (0..1) | `Header.age` |
| `builder[o]` | under construction by a kernel | `Header.builder` |
| `fld[o][i]` | pointer fields | `HPointer` fields |
| `root[r]`, `cell[c]` | roots, off-heap stores | stack slots, RootSet; CellStore, MVar |
| `mark[o]` | mark bit of an old-gen cell (an old object or a young large object) | `mark_.slot(id)` byte / `largeMark` |
| `grey` | every marker's grey entries (stacks, deques, rings) | `MarkWorker::stack`, deques, rings |
| `cycle` | `idle` / `marking` / `handoffDue` | `cycle_state_` (`CycleState`) |
| `k` | minor ends since t0 | `cycle_k_` |
| `episode` | `none` / `running` / `finished` | `bg_ep_` (`BgEpisode::None/Running/Finished`, `OldGenSpace.hpp:1026`), with the gang's `running()` folded in (§4.1) |
| `deferred` | dead young large objects awaiting handoff | `deferred_frees_` |
| `zombie` | region mode: dead objects of the extent handed over at the last minor, still walked at t0 | the Tenuring extent's unzapped dead objects |
| `minors`, `majors`, `ops` | exploration counters | — |
| ghosts `t0Old`, `t0Ylos`, `t0Reach`, `tSH`, `tNH` | the t0 old set, YLOS cells, old reachable set (IM1's record), S_H, N_H | `cycle_t0_reach_` (validate), `cycle_t0_blocks_` |

### 4.4 Steps: model labels to code

| Label | Code | Why one step |
|---|---|---|
| `M_Choose` (each `or` branch) | an Elm/kernel operation between statepoints | One mutator operation. Loads read a field of an object, which is immutable or owned. The P1-violating write is one store. |
| `P_Minor` | `NurserySpace::minorGC` / `minorGCRegion` (+ `sweepNurseryLargeBodies`) | §4.1: the footprint is disjoint from the markers', checked by `MarkerFootprint` |
| `P_Handoff` | `stepMarkCycle` → `completeMarkCycle` (`ThreadLocalHeap.cpp:1145-1147`) | call |
| `P_Marking` | `noteCycleMinorEnd` (`ThreadLocalHeap.cpp:1144`), `cyclePressureFinishDue` (`:1149`), then `runCycleStepConcurrent`'s `reapBackground` / relaunch (`OldGenSpace.cpp:4688-4699`) | mutator-only state plus one read of the episode (the reap's `finishedApprox` acquire load); the pressure decision has no shared reads (IM16) |
| `P_Decide` | the `k ≥ T` branch (`:4700`), paced assist (`:4707-4744`) | a decision with no shared reads (IM16) |
| `P_Closing`, `P_Closing2` | `closingFinish` → `cycle_state_ = HandoffDue` (`:4702`) | drain loop, then one assignment |
| `P_Pressure*` | `finishMarkCycleNow(Pressure)` → `drainCycleMark` (`closingFinish` if `bg_ep_ != None`, else `runMarkers`) → `completeMarkCycle` | |
| `P_Trigger` | `evaluateMajorGCTrigger` (`ThreadLocalHeap.cpp:770`) | a decision |
| `P_T0` | `startMarkCycle` `:1065-1125` | the mutator is stopped and no marker runs yet (IM14: `assertSlotsQuiescent("launch")`) |
| `P_Sync` | `afterSnapshot` with `conc_mark = 1` (`OldGenSpace.cpp:4649-4658`) | drain loop |
| `D_Loop`, `A_Loop` | `closingEntry` / `assistEntry` members scanning (M2); `runMarkers` for a stopped episode or a 5b slice | one scan per step |
| `D_Done` | the end of `closingFinish`: `bg_ep_ = None` (`OldGenSpace.cpp:4635`) | mutator-only |
| `H_Free` | `handoffMarkCycle`'s tail + `processDeferredFrees` | no marker runs (IM14; invariant `IM9`) |
| `J_Join`, `J_Handoff`, `J_STW` | `majorGC`: `finishMarkCycleNow(Join)`, then the STW mark and sweep | the STW part runs with everything stopped |
| `K_Loop` | a background member's scan, or its termination (the done-CAS, with the reap's `Finished`); under `lazy_external`, the late store read | one scan per step (Drain contract) |
| `F_Loop` | `stopAllForFork` → `stopAndJoin`, with the mutator's next reap to `None` | one store of `stop`, as M2 sees it; the reap is folded in (§4.1) |

### 4.5 The PlusCal sketch

File: `test/tla/M1-snapshot-mark/SnapshotMark.tla`. This is the text that passed the translator and
SANY (re-checked after the 2026-09-28 review's corrections: `pcal -nocfg`, then `sany`, no errors).
The generated translation is omitted.

```tla
---------------------------- MODULE SnapshotMark ----------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Obj,            \* object ids; an id not in alloc is a free cell
    Nil,            \* model value: a null / constant slot
    RootSlots,      \* stack slots and RootSet roots (read at t0 only)
    CellSlots,      \* off-heap mutable stores: CellStore, MVar (external roots)
    Fields,         \* pointer fields per object, e.g. {1}
    YlosIds,        \* ids that are young LARGE objects while young (old-gen cell)
    InitAlloc, InitGen, InitAge, InitFld, InitRoot, InitCell,
    T,              \* incremental_mark_slices
    MaxMinors,      \* minor GCs explored
    MaxMajors,      \* emergency / explicit STW majors explored
    MaxOps,         \* mutator operations between two minors
    AssistMax,      \* entries one assist may scan in the pause
    MaxStops,       \* fork-hook stops of the background episode
    SyncMark,       \* conc_mark = 1: the whole mark inside the t0 pause
    RegionMode,     \* nursery_regions = 1: dead hand-over objects live on until the next minor
    MUTANT

MutId == "mut"
MkId  == "mk"
FkId  == "fk"

(* --algorithm SnapshotMark
variables
    alloc    = InitAlloc,                 \* allocated objects
    gen      = InitGen,                   \* [Obj -> {"young", "old"}]
    age      = InitAge,                   \* [Obj -> 0..1]: minors survived (young)
    builder  = [o \in Obj |-> FALSE],     \* Header.builder
    fld      = InitFld,                   \* [Obj -> [Fields -> Obj \cup {Nil}]]
    root     = InitRoot,                  \* [RootSlots -> Obj \cup {Nil}]
    cell     = InitCell,                  \* [CellSlots -> Obj \cup {Nil}]
    mark     = [o \in Obj |-> FALSE],     \* mark bit of an old-gen cell (old object or YLOS)
    grey     = {},                        \* the grey set (all slots' stacks + deques)
    cycle    = "idle",                    \* "idle" | "marking" | "handoffDue"
    k        = 0,                         \* cycle_k_: minor ends since t0
    episode  = "none",                    \* bg_ep_ with the gang's running(): "none" | "running" | "finished"
    deferred = {},                        \* deferred_frees_ (dead young large objects)
    zombie   = {},                        \* region mode: dead objects of the extent handed over at the last minor
    minors   = 0,
    majors   = 0,
    ops      = 0,
    \* ghosts, recorded in the t0 pause
    t0Old    = {},                        \* old objects that existed at t0
    t0Ylos   = {},                        \* young large objects (old-gen cells) at t0
    t0Reach  = {},                        \* IM1: old-gen cells reachable at t0
    tSH      = {},                        \* S_H: everything reachable at t0
    tNH      = {};                        \* N_H: allocated after t0

define
    Succ(S)  == {fld[o][i] : o \in S, i \in Fields} \ {Nil}
    Reach(S) == LET R[n \in 0..Cardinality(Obj)] ==
                      IF n = 0 THEN S ELSE R[n - 1] \cup Succ(R[n - 1])
                IN R[Cardinality(Obj)]
    Held     == ({root[r] : r \in RootSlots} \cup {cell[c] : c \in CellSlots}) \ {Nil}
    Live     == Reach(Held)
    OldObjs  == {o \in alloc : gen[o] = "old"}
    YoungObjs == {o \in alloc : gen[o] = "young"} \ (deferred \cup zombie)
    \* Old-gen cells: old objects and young large objects. The tail sweep frees
    \* every unmarked one (retireDeadLargeBodies retires an unmarked YLOS).
    CellObjs == OldObjs \cup {o \in alloc : gen[o] = "young" /\ o \in YlosIds}
    Marked   == {o \in Obj : mark[o]}
    Survived(o) == gen[o] = "old" \/ age[o] >= 1
    CycleOn  == cycle # "idle"
    OldKids(S) == {c \in Succ(S) : gen[c] = "old"}
    \* MUTANT lazy_external: a marker that runs out of work reads the off-heap
    \* stores then, instead of at t0.
    LazyGreys == IF MUTANT = "lazy_external"
                 THEN {v \in {cell[c] : c \in CellSlots} \ {Nil} : gen[v] = "old" /\ ~mark[v]}
                 ELSE {}

    \* MODEL_M1_1: no reachable object is ever freed.
    NoLostObject == Live \subseteq alloc
    \* IM3 (and the footprint argument of the one-step minor GC): markers only
    \* ever hold objects that were old at t0, and never reach a young object.
    MarkerFootprint == CycleOn => /\ grey \subseteq t0Old
                                  /\ \A o \in grey \cap alloc :
                                        \A i \in Fields : fld[o][i] = Nil \/ gen[fld[o][i]] = "old"
    \* IM5: nothing that existed at t0 is freed or reused during the cycle.
    NoReleaseInCycle == CycleOn => (t0Old \cup t0Ylos) \subseteq alloc
    \* HEAP_005: no old -> young pointer.
    NoOldToYoung == \A o \in OldObjs : \A i \in Fields :
                        fld[o][i] = Nil \/ fld[o][i] \notin alloc \/ gen[fld[o][i]] = "old"
    \* The snapshot-closure lemma (parallel-gc.md 2.1): every reference held
    \* anywhere points into S_H \cup N_H.
    SnapshotClosure == CycleOn => Live \subseteq (tSH \cup tNH)
    \* IM8 (model form): deferred frees are still allocated and really dead.
    DeferredOK == deferred \subseteq alloc /\ deferred \cap Live = {}
end define;

\* One grey entry scanned: its old children are test-and-set marked and greyed.
\* A freed object's entry is skipped (scanObject's Tag_Free check).
macro ScanOne(o) begin
    if o \in alloc then
        grey := (grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]};
        mark := [x \in Obj |-> mark[x] \/ x \in OldKids({o})];
    else
        grey := grey \ {o};
    end if;
end macro;

\* The closing join / pressure finish / join drain (closingFinish, drainCycleMark):
\* the pause scans until the grey set is empty, racing the background markers.
procedure DrainAll()
begin
  D_Loop:
    while grey # {} \/ LazyGreys # {} do
        if grey # {} then
            with o \in grey do ScanOne(o); end with;
        else                                   \* MUTANT lazy_external only
            grey := LazyGreys;
            mark := [x \in Obj |-> mark[x] \/ x \in grey];
        end if;
    end while;
  D_Done:
    episode := "none";                         \* closingFinish ends with bg_ep_ = None
    return;
end procedure;

\* A paced assist (assistEpisode) or a 5b slice: a bounded number of scans in the pause.
procedure Assist()
variables n = 0;
begin
  A_Loop:
    while n < AssistMax /\ grey # {} do
        with o \in grey do ScanOne(o); end with;
        n := n + 1;
    end while;
  A_Done:
    return;
end procedure;

\* completeMarkCycle + handoffMarkCycle: the checks (IM1, IM2, IM9, IM14) are
\* invariants on the state at H_Free; then every unmarked old-gen cell is freed
\* together with the deferred frees.
procedure Handoff()
begin
  H_Free:
    alloc := alloc \ ({o \in CellObjs : ~mark[o]} \cup deferred);
    deferred := {};
    cycle := "idle";
    episode := "none";
    k := 0;
    t0Old := {}; t0Ylos := {}; t0Reach := {}; tSH := {}; tNH := {};
    return;
end procedure;

\* One minor-GC pause (ThreadLocalHeap::minorGC + stepMarkCycle / trigger).
procedure MinorPause()
begin
  P_Minor:                                 \* the minor GC itself: ONE step (see M1 plan 4.1)
    with ly = Live \cap YoungObjs,
         dead = YoungObjs \ Live,
         hand = IF RegionMode THEN {o \in YoungObjs \ Live : age[o] = 1 /\ o \notin YlosIds}
                ELSE {},
         promote = {o \in Live \cap YoungObjs :
                        age[o] = 1 /\ (~builder[o] \/ MUTANT = "promote_ignores_builder")} do
        \* region mode: the extent handed over now keeps its dead objects until the
        \* next minor retires it (the previous one's zombies are freed here)
        if CycleOn /\ MUTANT # "free_ylos_in_cycle" then
            alloc := alloc \ (((dead \ hand) \ YlosIds) \cup zombie);
            deferred := deferred \cup (dead \cap YlosIds);   \* sweepNurseryLargeBodies defers
        else
            alloc := alloc \ ((dead \ hand) \cup zombie);
        end if;
        zombie := hand;
        gen := [o \in Obj |-> IF o \in promote THEN "old" ELSE gen[o]];
        age := [o \in Obj |-> IF o \in ly /\ (~builder[o] \/ MUTANT = "promote_ignores_builder")
                              THEN 1 ELSE age[o]];
        \* allocate-black: a promotion during a cycle gets its mark bit at once
        \* (young large objects are promoted in place and were marked already)
        mark := [o \in Obj |-> IF o \in promote /\ o \notin YlosIds /\ CycleOn
                                  /\ MUTANT # "no_alloc_black"
                               THEN TRUE ELSE mark[o]];
    end with;
    minors := minors + 1;
    ops := 0;
    if cycle = "handoffDue" then goto P_Handoff;
    elsif cycle = "marking" then goto P_Marking;
    else goto P_Trigger;
    end if;
  P_Handoff:                               \* stepMarkCycle: HandoffDue -> completeMarkCycle
    call Handoff();
    return;
  P_Marking:                               \* stepMarkCycle: k++, pressure check, then the step's reap / relaunch
    k := k + 1;
    either
        goto P_Pressure;                   \* cyclePressureFinishDue: before the step, at any k
    or
        if ~SyncMark then                  \* runCycleStepConcurrent: reapBackground, relaunch
            if episode = "none" /\ grey # {} then episode := "running";
            elsif episode = "none" then episode := "finished";
            end if;
        end if;
    end either;
  P_Decide:
    if k >= T then
        goto P_Closing;
    else
        either
            return;                        \* on schedule: a plain minor pause
        or
            call Assist();                 \* behind schedule: a paced assist (or a 5b slice)
            return;
        end either;
    end if;
  P_Closing:                               \* k == T: closingFinish, then HandoffDue
    if MUTANT # "handoff_skips_drain" then
        call DrainAll();
    end if;
  P_Closing2:
    cycle := "handoffDue";
    return;
  P_Pressure:                              \* finishMarkCycleNow(Pressure)
    call DrainAll();
  P_Pressure2:
    call Handoff();
    return;
  P_Trigger:                               \* evaluateMajorGCTrigger
    either
        return;
    or
        goto P_T0;
    end either;
  P_T0:                                    \* startMarkCycle: the snapshot, ONE step
    with rootOld = {v \in {root[r] : r \in RootSlots} \ {Nil} : gen[v] = "old"},
         cellOld = IF MUTANT \in {"skip_external", "lazy_external"} THEN {}
                   ELSE {v \in {cell[c] : c \in CellSlots} \ {Nil} : gen[v] = "old"},
         ylos    = IF MUTANT = "skip_ylos" THEN {} ELSE YoungObjs \cap YlosIds,
         ylosOld = OldKids(IF MUTANT = "skip_ylos" THEN {} ELSE YoungObjs \cap YlosIds),
         youngOld = IF MUTANT = "skip_young_walk" THEN {}
                    ELSE OldKids((YoungObjs \cup zombie) \ YlosIds) do
        mark := [o \in Obj |-> o \in (rootOld \cup cellOld \cup ylos \cup ylosOld \cup youngOld)];
        grey := rootOld \cup cellOld \cup ylosOld \cup youngOld;
        t0Old := OldObjs;
        t0Ylos := ylos;
        t0Reach := Live \cap CellObjs;
        tSH := Live;
        tNH := {};
    end with;
    cycle := "marking";
    k := 0;
    if SyncMark then goto P_Sync;
    else
        episode := "running";              \* afterSnapshot -> launchBackground
        return;
    end if;
  P_Sync:                                  \* conc_mark = 1: everything now
    call DrainAll();
    return;
end procedure;

\* An emergency or explicit STW major (ThreadLocalHeap::majorGC): it JOINS a
\* running cycle (drain + handoff) and then runs its own full mark and sweep.
procedure MajorPause()
begin
  J_Join:
    if CycleOn /\ MUTANT # "major_no_join" then
        call DrainAll();
    end if;
  J_Handoff:
    if CycleOn /\ MUTANT # "major_no_join" then
        call Handoff();
    end if;
  J_STW:                                   \* frees every unreachable old-gen cell (YLOS too)
    alloc := alloc \ (CellObjs \ Live);
    mark := [o \in Obj |-> o \in (Live \cap CellObjs)];
    majors := majors + 1;
    return;
end procedure;

\* The mutator: Elm code and C++ kernels, interleaved with pauses.
process Mutator = MutId
begin
  M_Loop:
    while minors < MaxMinors do
      M_Choose:
        either
            await ops < MaxOps;
            ops := ops + 1;
            either      \* load a field of a held object into a root
                with r \in RootSlots, r2 \in RootSlots, i \in Fields do
                    await root[r2] # Nil;
                    root[r] := fld[root[r2]][i];
                end with;
            or          \* drop a root
                with r \in RootSlots do root[r] := Nil; end with;
            or          \* CellStore / MVar write (off-heap, may be overwritten any time)
                with c \in CellSlots, r \in RootSlots do cell[c] := root[r]; end with;
            or          \* CellStore / MVar read
                with r \in RootSlots, c \in CellSlots do root[r] := cell[c]; end with;
            or          \* allocate a young object whose fields are values the mutator holds
                with o \in Obj \ alloc, r \in RootSlots,
                     v \in [Fields -> ({root[x] : x \in RootSlots} \ {b \in Obj : builder[b]}) \cup {Nil}] do
                    alloc := alloc \cup {o};
                    gen := [gen EXCEPT ![o] = "young"];
                    age := [age EXCEPT ![o] = 0];
                    builder := [builder EXCEPT ![o] = FALSE];
                    fld := [fld EXCEPT ![o] = v];
                    root := [root EXCEPT ![r] = o];
                    \* a young LARGE object lives in an old-gen cell: allocate-black
                    mark := [mark EXCEPT ![o] = o \in YlosIds /\ CycleOn
                                                /\ MUTANT # "no_alloc_black"];
                    tNH := IF CycleOn THEN tNH \cup {o} ELSE tNH;
                end with;
            or          \* a kernel allocates a builder (fields filled later)
                with o \in (Obj \ alloc) \ YlosIds, r \in RootSlots do
                    alloc := alloc \cup {o};
                    gen := [gen EXCEPT ![o] = "young"];
                    age := [age EXCEPT ![o] = 0];
                    builder := [builder EXCEPT ![o] = TRUE];
                    fld := [fld EXCEPT ![o] = [i \in Fields |-> Nil]];
                    root := [root EXCEPT ![r] = o];
                    mark := [mark EXCEPT ![o] = FALSE];
                    tNH := IF CycleOn THEN tNH \cup {o} ELSE tNH;
                end with;
            or          \* a kernel writes a builder (HEAP_BUILDER_*: allowed)
                with r \in RootSlots, r2 \in RootSlots, i \in Fields do
                    await root[r] # Nil /\ builder[root[r]];
                    await root[r2] = Nil \/ ~builder[root[r2]];
                    fld := [fld EXCEPT ![root[r]][i] = root[r2]];
                end with;
            or          \* clear_builder: the object becomes an ordinary young object
                with r \in RootSlots do
                    await root[r] # Nil /\ builder[root[r]];
                    builder := [builder EXCEPT ![root[r]] = FALSE];
                end with;
            or          \* P1 VIOLATION: a kernel overwrites a field of a survived object
                await MUTANT = "p1_violation";
                with r \in RootSlots, i \in Fields,
                     v \in {Nil} \cup {x \in Held : gen[x] = "old"} do
                    await root[r] # Nil /\ Survived(root[r]) /\ ~builder[root[r]];
                    fld := [fld EXCEPT ![root[r]][i] = v];
                end with;
            or          \* a runtime free of a now-unreachable OLD object during a cycle
                await MUTANT = "release_during_cycle" /\ CycleOn;
                with o \in OldObjs \ Live do
                    alloc := alloc \ {o};
                end with;
            or          \* a ROOTING BUG: a C++ local the GC does not know about
                        \* resurfaces a pointer to an object that is not reachable
                await MUTANT = "hidden_root";
                with r \in RootSlots, o \in alloc \ Live do
                    root := [root EXCEPT ![r] = o];
                end with;
            end either;
        or
            call MinorPause();
        or
            await majors < MaxMajors;
            call MajorPause();
        end either;
    end while;
end process;

\* The background markers (GCBackgroundGang members running 5b's loop). Under
\* M2's Drain contract they behave as one consumer of the shared grey set.
fair process Marker = MkId
begin
  K_Loop:
    while TRUE do
        await episode = "running";
        if grey # {} then
            with o \in grey do ScanOne(o); end with;
        elsif LazyGreys # {} then                \* MUTANT lazy_external: the stores, read late
            grey := LazyGreys;
            mark := [x \in Obj |-> mark[x] \/ x \in grey];
        else
            episode := "finished";              \* termination (the done-CAS), then the reap
        end if;
    end while;
end process;

\* A fork hook on another thread: stopAllForFork() stops the running episode.
process Forker = FkId
variables stops = 0;
begin
  F_Loop:
    while stops < MaxStops do
        await episode = "running";
        episode := "none";                      \* stopped: the work stays in the grey set
        stops := stops + 1;
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
\* END TRANSLATION

-----------------------------------------------------------------------------
\* Handoff-time checks (the state in which H_Free is about to run).
AtHandoff == pc[MutId] = "H_Free"
\* IM1: every old-gen cell reachable at t0 is marked.
IM1 == AtHandoff => t0Reach \subseteq Marked
\* IM2: every old-gen cell reachable now is marked.
IM2 == AtHandoff => (Live \cap CellObjs) \subseteq Marked
\* IM9 / IM14: the mark stack is empty and no background episode runs.
IM9 == AtHandoff => (grey = {} /\ episode # "running")
=============================================================================
```

**Notes for the implementer:**
- `Reach` is a bounded fixpoint (at most `|Obj|` rounds), written as a recursive *function*
  instead of a `RECURSIVE` operator, so it works inside the `define` block. It is for TLC only:
  **Apalache 0.62.2 rejects recursive functions** ("Apalache does not support recursive
  functions", `NonrecursiveLanguagePred` in `apalache.jar`). `SnapshotLemma.tla` uses a fold
  instead (§4.7).
- The handoff checks are invariants **on the state where `pc[MutId] = "H_Free"`**, i.e. just before
  the frees. That is where the code's IM1/IM2 validators run (`ThreadLocalHeap.cpp:1194-1199`).
- `IM1`/`IM2` range over old-gen cells, young large objects included, as the code's validator
  does (`traceOldReachableForValidation` returns every reached old-gen cell).
- The pressure choice sits in `P_Marking`, before the reap, because `stepMarkCycle` checks it
  before `cycleStep` (`ThreadLocalHeap.cpp:1149`). It is therefore possible at `k = T` too.
- `D_Done` sets `episode := "none"` as `closingFinish` does. The trace projection (§8) needs this.
- `LazyGreys` is `{}` unless `MUTANT = "lazy_external"`; `zombie` stays `{}` unless `RegionMode`.

### 4.6 The properties, explained

| Property | Kind | Invariant id | What it says | A violation looks like |
|---|---|---|---|---|
| `NoLostObject` | invariant | MODEL_M1_1 | every object reachable from a root or an off-heap store is allocated | the state right after `H_Free`, `J_STW` or a mutant's free, with a root reaching a freed id |
| `IM1` | invariant at `H_Free` | IM1 | every old-gen cell (old object or YLOS) reachable at t0 is marked | timelines (a), (c), (d), (e): something reachable at t0 through an erased edge, a freed object or an unread root is unmarked |
| `IM2` | invariant at `H_Free` | IM2 | every old-gen cell reachable *now* is marked (the tail frees an unmarked YLOS cell too) | timeline (b): a promotion, or a YLOS allocation, that was not allocated black |
| `IM9` | invariant at `H_Free` | IM9, IM14 | the grey set is empty and no background episode runs | a handoff before the closing drain |
| `MarkerFootprint` | invariant | IM3 (+ the one-step-minor argument) | every grey object was old at t0 and points only at old objects | a marker holding a promoted or young object; the premise of §4.1's minor abstraction is broken; in region mode (`quick_region`), a t0 walk of a dead hand-over object greying an old cell a STW major has freed (§2.5) |
| `NoReleaseInCycle` | invariant | IM5 | no object or YLOS cell that existed at t0 is freed before the handoff | a free during the cycle |
| `NoOldToYoung` | invariant | HEAP_005 | no old object points at a young one | a promotion out of age order (a modelling error, or a builder mutant) |
| `SnapshotClosure` | invariant | the lemma | during a cycle every reachable object is in S_H ∪ N_H | a pointer resurfacing from nowhere (the `hidden_root` rooting bug) |
| `DeferredOK` | invariant | IM8 (model form) | deferred frees are still allocated and unreachable | a live object on the deferred list |

M1 is a safety model. A liveness property ("every cycle ends") would need a fair mutator, and adds
little: the cycle's schedule is fixed by minor count. It is optional and deep-tier:
`CycleEnds == (CycleOn /\ minors + T + 1 <= MaxMinors) ~> ~CycleOn` under `WF_vars(Mutator)`.
The guard matters: the plain `cycle = "marking" ~> cycle = "idle"` fails spuriously whenever t0
falls within `T` minors of `MaxMinors`, because the bounded mutator stops before the handoff.

### 4.7 The unbounded obligation: the snapshot-closure lemma and the tri-colour invariant

TLC checks M1 for heaps of five or six objects. The lemma itself should hold for any heap, so it
gets an inductive proof. **Inductive** means: if the invariant holds in some state, it holds after
any single step, and it holds initially. That proves it for every reachable state, whatever the
size.

The invariant, in TLA+ (for `SnapshotLemma.tla`, a plain-TLA+ restatement of M1's actions, without
PlusCal, with Apalache type annotations). These definitions passed SANY in the review, in a module
that extends the §4.5 translation and Apalache's standard module, with the ghost variable `fld0`
declared and `TypeOK` stubbed (`SnapshotLemma.tla` defines both):

```tla
\* Reachability from S through objects of A only, as a fold: Apalache rejects
\* recursive functions and operators ("Apalache does not support recursive functions").
ReachWithin(S, A) ==
    ApaFoldSeqLeft(LAMBDA R, j: R \cup {c \in Succ(R) : c \in A}, S,
                   MkSeq(Cardinality(Obj), LAMBDA j: j))
YoungSet       == {o \in alloc : gen[o] = "young"}
OldSH          == tSH \cap t0Old                       \* the t0 old graph the marker must cover
White          == OldSH \ Marked
BuilderYoung   == \A o \in alloc : builder[o] => (gen[o] = "young" /\ age[o] = 0)
AgeOrder       == \A o \in YoungSet \ deferred, i \in Fields :          \* promotion keeps HEAP_005
                      fld[o][i] \in YoungSet => (~builder[fld[o][i]] /\ age[fld[o][i]] >= age[o])
OldClosed      == \A o \in OldObjs, i \in Fields : fld[o][i] \in OldObjs \cup {Nil}  \* HEAP_005, no dangling
FieldsFrozen   == CycleOn => \A o \in t0Old : fld[o] = fld0[o]    \* P1 on the old gen (ghost fld0, set at t0)
T0OldStays     == CycleOn => (t0Old \cup t0Ylos \subseteq alloc /\ t0Old \subseteq OldObjs
                              /\ tNH \cap t0Old = {})                   \* IM5; t0 ids are never reused
OldSHClosed    == CycleOn => \A o \in OldSH, i \in Fields : fld[o][i] \in OldSH \cup {Nil}
GreyInSH       == CycleOn => grey \subseteq OldSH
GreysMarked    == grey \subseteq Marked
HandoffEmpty   == cycle = "handoffDue" => grey = {}
NewOldBlack    == CycleOn => (OldObjs \ t0Old) \subseteq Marked         \* allocate-black
YlosBlack      == CycleOn => (YoungObjs \cap YlosIds) \subseteq Marked   \* t0 snapshot + allocate-black
KidsCovered    == CycleOn => \A o \in (alloc \ deferred) \cap (Marked \cup YoungSet), i \in Fields :
                                fld[o][i] \in Marked \cup OldSH \cup YoungSet \cup {Nil}
\* The classic tri-colour invariant: every WHITE old object of S_H is reachable from
\* some grey object through white objects of S_H, so the marker will still find it.
WhiteReachable == CycleOn => \A o \in White : \E g \in grey : o \in ReachWithin({g}, White)
LemmaInv == /\ TypeOK /\ NoLostObject /\ SnapshotClosure /\ DeferredOK /\ BuilderYoung
            /\ AgeOrder /\ OldClosed /\ FieldsFrozen /\ T0OldStays /\ OldSHClosed
            /\ GreyInSH /\ GreysMarked /\ HandoffEmpty /\ NewOldBlack /\ YlosBlack
            /\ KidsCovered /\ WhiteReachable
\* The consequence checked at the handoff (grey = {} makes White empty):
LemmaImpliesIM2 == (LemmaInv /\ CycleOn /\ grey = {}) => (Live \cap CellObjs) \subseteq Marked
```

**Why it is stronger than the first draft.** The draft (`FieldsFrozen /\ GreysMarked /\
NewOldBlack /\ WhiteReachable /\ NoOldToYoung /\ SnapshotClosure`) was not inductive, and the
length-1 Apalache check would have reported spurious counterexamples:
- `WhiteReachable` was guarded by `cycle = "marking"`, so it said nothing at `handoffDue`, and
  `LemmaImpliesIM2` did not follow. It is now guarded by `CycleOn`.
- `FieldsFrozen` also froze the young objects of S_H. A builder of S_H is legally written after t0,
  and a young S_H object that dies is freed and its id reused. So it was not even an invariant. P1
  is only needed on `t0Old`.
- The scan step keeps `WhiteReachable` only if the scanned object is allocated (else `ScanOne`
  skips it) and its children are in S_H's old part: `T0OldStays`, `GreyInSH`, `OldSHClosed`.
- A promoted young large object keeps its mark rather than getting a new one: `YlosBlack`.
- `NoOldToYoung` alone is not inductive: from a state where an age-1 object points at an age-0
  one, the minor promotes the parent only. `AgeOrder` states the age order that the code relies
  on (PM5), and `BuilderYoung` is HEAP_BUILDER_001/002. `NoOldToYoung` also allowed a dangling
  field, which a later allocation could turn into an old → young edge. `OldClosed` forbids it, and
  `KidsCovered` (every child of a marked or young object is marked, white-in-S_H or young) is what
  keeps it true across the handoff's frees.
- `SnapshotClosure` needs none of this: every store writes a held value, so it is inductive with
  `TypeOK` alone (§2.3). Only `hidden_root` breaks it.

`ReachWithin(S, A)`: every object reachable from `S` by a path, of length 0 or more, whose nodes
after the first are all in `A`. `Reach` in `SnapshotLemma.tla` is `ReachWithin(S, Obj)`. The
`MkSeq` bound `Cardinality(Obj)` is enough: a simple path has at most `|Obj| - 1` edges.

**How to restate the actions.** `SnapshotLemma.tla` has no `pc`, so every guard that the PlusCal
control flow gives for free must be written out:
- the t0 snapshot is **one action with the minor** (legacy mode), so every young object it walks is
  live. A separate t0 action enabled in any idle state would walk dead young objects whose old
  children a STW major may have freed, and fail `GreyInSH` (that is the region-mode defect of
  §2.5, which this lemma deliberately does not cover);
- the closing and the handoff are guarded by `grey = {}` (the code asserts `markStackEmpty()` in
  `handoffMarkCycle`, `OldGenSpace.cpp:4260`);
- the mutator's pointer stores (load, cell ops, allocation, builder write) read only `Held`.

**Plan:**
1. **Apalache, bounded heap, unbounded time.** Check inductiveness for `|Obj| ≤ 6` (then 8):
   - `apalache-mc check --init=IndInit --next=Next --inv=LemmaInv --length=1 SnapshotLemma.tla`,
     where `IndInit == TypeOK /\ LemmaInv` (any state satisfying the invariant, not just the
     initial one);
   - plus `--init=Init --inv=LemmaInv --length=0` for the initial states;
   - plus `LemmaImpliesIM2` as a state invariant (length 0 from `IndInit`).

   A counterexample of length 1 is either a real hole in the argument, or an invariant that is still
   too weak (then strengthen it). Record which in AUDIT.md. The conjuncts above are the reviewer's
   prediction of an inductive set, not a checked result.
2. **TLAPS, any heap size** (image built with `INSTALL_TLAPS=1`). Prove
   `THEOREM LemmaInv /\ [Next]_vars => LemmaInv'` per action. The non-trivial cases are:
   - the minor's promotion (`NewOldBlack`, `YlosBlack`, `AgeOrder` → `OldClosed`);
   - the marker's scan (`WhiteReachable`: the scanned object's white children become grey, and
     paths through it now start at those children);
   - the t0 action (`WhiteReachable` holds from scratch: on any path from a root, the first old
     object is greyed, and old objects point only at old ones);
   - the handoff (`OldClosed` after the frees, from `KidsCovered` and an empty `White`).

   Budget: this is the one proof in the plan. If it stalls, the Apalache result at 8 objects is
   the fallback, and the gap is recorded.
3. **What P1's mutant shows here.** With the `p1_violation` action enabled, `FieldsFrozen` is
   false, and the inductive step for `WhiteReachable` fails on exactly timeline (a). This is the
   "necessity of P1" result, stated formally. `SnapshotClosure` stays inductive: P1 is a premise of
   the marker's completeness, not of the lemma.

## 5. Negative controls (mutants)

**Convention:** each mutant configuration lists **only its target invariant**, so the runner's
"violated invariant name" check is unambiguous (several invariants can be violated in the same
state; TLC reports the first it checks).

| `MUTANT` | Code change it represents | Target invariant | Story | Existing test / control |
|---|---|---|---|---|
| `p1_violation` | a kernel writes a field of a survived non-builder object | `IM1` | §2.4 (a) | the `ECO_P1_CENSUS` tripwire; HEAP_SNAPSHOT_001 |
| `no_alloc_black` | promotions and YLOS allocations mid-cycle do not set the bit | `IM2` | §2.4 (b) | `test_skip_allocate_black_` (`OldGenSpace.cpp:517`, `:819`, `:1083`, `:1130`); `testIncrNegativeSkipAllocateBlack` (`IncrementalMarkTest.cpp:914`) |
| `release_during_cycle` | a pre-t0 old object freed mid-cycle (block release, body free, compaction) | `IM1` (the loss that IM5 prevents) | §2.4 (c) | `testIncrNoReleaseDuringCycle` (`IncrementalMarkTest.cpp:747`), the IM5 asserts |
| `skip_young_walk` | t0 does not walk young objects | `IM1` | §2.4 (d) | `test_snapshot_skip_young_walk_`, `testIncrNegativeSkipYoungWalk` (`:875`) |
| `skip_external` | t0 does not read off-heap stores | `IM1` | §2.4 (e) without the lazy read | `test_snapshot_skip_external_`, `testIncrNegativeSkipExternal` (`:893`) |
| `lazy_external` | a marker reads the off-heap stores when it runs out of work (the `Marker`'s termination branch and `DrainAll`), instead of at t0 (the report's §2.2 M4 hazard) | `IM1` | §2.4 (e): the violation needs the store overwritten after t0 and before the late read | — (the design HEAP_SNAPSHOT_002 forbids) |
| `skip_ylos` | t0 does not mark young large objects or grey their children | `IM1` | a YLOS object is the only path to 1 at t0; the YLOS cell itself is unmarked too (the tail would free it) | — |
| `major_no_join` | a STW major during a cycle skips `finishMarkCycleNow(Join)` | `NoReleaseInCycle` | the major frees now-dead pre-t0 objects the cycle still holds; the real code aborts at `startMark`'s `!cycleActive()` assert (`OldGenSpace.cpp:2877`) | `testIncrJoinOnExplicitMajor` (`:774`), `testIncrJoinOnYlosAllocFailure` (`:794`) |
| `free_ylos_in_cycle` | a dead young large object's cell freed at a minor during the cycle instead of deferred | `NoReleaseInCycle` | the cell existed at t0 and is reused under the running cycle (its consequences at the cell level are M4's) | `testIncrDeferredYlosFree` (`:710`), `testIncrDeferredBodyFree` (`:688`) |
| `hidden_root` | a rooting bug: a C++ local the GC does not scan resurfaces a pointer | `SnapshotClosure` | a pointer to an object outside S_H ∪ N_H appears; the snapshot cannot protect it | the rooting audits (`plans/runtime-cpp-gc-rooting-audit.md`) |
| `promote_ignores_builder` | promotion does not check `builder` (and ages builders) | `NoOldToYoung` | a promoted builder points at a younger object | PM5 (`NurseryParallel.cpp:276-286`) |
| `handoff_skips_drain` | `P_Closing` sets `handoffDue` without `DrainAll` | `IM9` | a handoff with grey entries left | the `markStackEmpty` asserts in `handoffMarkCycle` (`OldGenSpace.cpp:4260`) |

Each story is reachable within the quick bounds (§6). The shortest behaviours, hand-traced in the
review from the §6 heap (old `1 → 2` and `4`, young `3 → 4`, `r1 → 1`, `r2 → 3`, empty `c1`, free
id 5 = a YLOS id). "t0" is always at minor 1, so the handoff is at minor 4 = `MaxMinors`:

| Target | Shortest violating behaviour | Minors | Ops in one epoch | Majors |
|---|---|---|---|---|
| `p1_violation` | minor 1 + t0 (greys 1, 4); `r2 := 1.f`; `1.f := Nil`; the marker scans 1 after the write; minors 2, 3 (closing); minor 4 at `H_Free`: 2 unmarked | 4 | 2 | 0 |
| `no_alloc_black` | minor 1 ages 3, t0; minor 2 promotes 3 unmarked; minors 3, 4 at `H_Free`: 3 live, old, unmarked (`IM2`) | 4 | 0 | 0 |
| `release_during_cycle` | minor 1 + t0; `r1 := 1.f` (1 unreachable, `r1` holds 2); free 1 before it is scanned; the drain skips it; `H_Free`: 2 unmarked | 4 | 2 | 0 |
| `skip_young_walk` | minor 1 + t0 without the walk (4 not greyed); minor 2 promotes 3 black; `H_Free`: 4 unmarked | 4 | 0 | 0 |
| `skip_external` | `c1 := r1`; drop `r1`; minor 1 + t0 (`c1` not read); `H_Free`: 1, 2 unmarked | 4 | 2 | 0 |
| `lazy_external` | as `skip_external`, then after t0: `r1 := c1`; `c1 := r2` (3, young); the late read finds no old target; `H_Free`: 1, 2 unmarked | 4 | 2 | 0 |
| `skip_ylos` | allocate 5 with `5.f = 1` into `r1`; minor 1 + t0 (5 not marked, 1 not greyed); `H_Free`: 5, 1, 2 unmarked | 4 | 1 | 0 |
| `major_no_join` | minor 1 + t0; drop `r1`; the STW major, without the join, frees 1 and 2 (both in `t0Old`) | 1 | 1 | 1 |
| `free_ylos_in_cycle` | allocate 5 into `r1`; minor 1 + t0 (`t0Ylos = {5}`); drop `r1`; minor 2 frees 5 | 2 | 1 | 0 |
| `hidden_root` | drop `r1`; minor 1 + t0 (`tSH = {3, 4}`); a hidden root to 1 | 1 | 1 | 0 |
| `promote_ignores_builder` | drop `r2`; minor 1 frees 3; builder 3 into `r2`; minor 2 ages it; allocate 5 into `r1`; `3.f := 5`; minor 3 promotes 3 while 5 is young | 3 | 2 | 0 |
| `handoff_skips_drain` | minor 1 + t0 (grey `{1, 4}`), the marker idle; minor 3 skips the drain; minor 4 at `H_Free` with grey non-empty | 4 | 0 | 0 |
| (`quick_region`) | minor 1 ages 3; drop `r2`; the STW major frees 4; minor 2 keeps 3 as a zombie, and t0 greys the freed 4 (`MarkerFootprint`) | 2 | 1 | 1 |

None needs a fork stop. With `CHECK_DEADLOCK FALSE` and no `Assert` in the sketch, nothing else
can stop TLC first. No step applies a function outside its domain: `fld`, `gen` and `mark` are
total on `Obj`, and every `root[·]` dereference is guarded by `# Nil`.

## 6. Configurations

`MC.tla` holds the starting heap:

```tla
MC_Obj    == {1, 2, 3, 4, 5}
MC_Ylos   == {5}                                   \* 5 is free; allocated, it is a YLOS
MC_Alloc  == {1, 2, 3, 4}
MC_Gen    == [o \in MC_Obj |-> IF o \in {1, 2, 4} THEN "old" ELSE "young"]
MC_Age    == [o \in MC_Obj |-> 0]
MC_Fld    == [o \in MC_Obj |-> [i \in {1} |-> CASE o = 1 -> 2 [] o = 3 -> 4 [] OTHER -> Nil]]
MC_Root   == [r \in {"r1", "r2"} |-> IF r = "r1" THEN 1 ELSE 3]
MC_Cell   == [c \in {"c1"} |-> Nil]
```

This heap is chosen so every timeline of §2.4 is a few steps away:
- `1 → 2` gives the deleted-edge and release stories;
- the young `3 → 4` gives the young-walk and allocate-black stories;
- the free id 5 gives the YLOS stories;
- the empty cell gives the external-root stories.

The only free id at the start is 5, a YLOS id. So an ordinary young object or a builder can be
allocated only after something is freed (drop `r2`, then a minor frees 3). The builder stories
therefore start at minor 2 at the earliest; `promote_ignores_builder` still fits (§5).

| Config | Key constants | Tier | Expected |
|---|---|---|---|
| `quick` | as above; `T=2`, `MaxMinors=4`, `MaxMajors=1`, `MaxOps=2`, `AssistMax=1`, `MaxStops=1`, `SyncMark=FALSE`, `RegionMode=FALSE` | quick | pass all nine invariants |
| `quick_sync` | `quick` + `SyncMark=TRUE` (the `conc_mark = 1` reference) | quick | pass |
| `quick_region` | `quick` + `RegionMode=TRUE` (the default nursery since TG7d), only `MarkerFootprint` | quick | **expected: violates `MarkerFootprint`** (the suspected defect of §10 Q4). Flips to "pass all nine" in the change that fixes it |
| `quick_region_nomajor` | `quick_region` with `MaxMajors=0`, all nine invariants | quick | pass. Without a STW major nothing frees a zombie's old child: a handoff frees only unmarked cells, and every old child of an object alive during the cycle is marked (IM1 / allocate-black), while the t0 walk marks the children of the zombies it sees. This keeps the default nursery mode under every other invariant until §10 Q4 is fixed (added by the orchestrator's review of the M1 review) |
| `mutant_<name>` | `quick` + `MUTANT="<name>"`, only the target invariant | quick | fail with the target (§5) |
| `deep` | `Obj={1..6}`, `Fields={1,2}`, `MaxMinors=6`, `MaxOps=3`, `MaxStops=2`, `MaxMajors=2`, `T=3` | deep | pass |
| `deep_liveness` | `deep` + a fair mutator + `PROPERTY CycleEnds` | deep, optional | pass |

Every configuration sets `Nil = Nil` (a model value), `defaultInitValue = defaultInitValue` (primer
§2 rule 3) and `CHECK_DEADLOCK FALSE`. The `Marker` process waits forever once the mutator has
finished its bounded run, which TLC would otherwise report as a deadlock.

**State-space size is unknown** (TLC has not run). If `quick` takes more than about two minutes,
reduce in this order, since each keeps every §2.4 story reachable:
1. `MaxStops = 0` in `quick` (keep it in `deep`);
2. `MaxMajors = 0` except in `major_no_join` and `quick_region`, which need one major;
3. drop the builder branches into a separate `quick_builders` configuration, and run
   `promote_ignores_builder` on it.

## 7. Accuracy notes (parent plan rules A1–A9)

| Rule | M1 |
|---|---|
| A1 | Mutator operations and the t0 snapshot are single steps (the mutator is one thread; t0 runs with no marker, IM14). Each marker scan is one step (Drain contract; per-child test-and-set is M2/M4). **The minor GC is one step only because its footprint is disjoint from the markers'**, and `MarkerFootprint` checks that premise in every state. The handoff is one step (no marker runs: `IM9`). `P_Marking` merges `k++`, the pressure decision and the reap into one step: only the reap reads shared state (one acquire load of the gang's finished count). The `Forker` step merges the fork hook's stop with the mutator's later reap to `None` (§4.1). |
| A2 | One mark bit per object. Byte sharing is M4's, and this is written in MAPPING.md so nobody assumes M1 covers it. |
| A3 | 05c audit rows: H1 (mark bytes of t0 blocks → `mark`), H1b (post-t0 blocks → "promotions are black and never grey"), H6/H8 (MarkView, YLOS at t0 → `gen`, `t0Ylos`), H7 (`cycle_state_` → `cycle`), H9/H5 (block identity, region bounds → abstracted by IM5 / `NoReleaseInCycle`), H10/H13 (slots → the Drain contract), H14 (S_H fields → `fld` frozen unless `p1_violation`). Plus `deferred_frees_` → `deferred`; every root kind and external scanner → `root`, `cell` (HEAP_SNAPSHOT_002); builders; `bg_ep_` → `episode`. Also: the tail's `retireDeadLargeBodies` (unmarked YLOS cells are freed → `CellObjs`), and region mode's unzapped dead hand-over objects (→ `zombie`). |
| A4 | W3 (allocate-black `fetch_or` against a marker's `fetch_or` on one byte) and W4 (publication of new blocks and page-index entries to markers). The t0-to-marker handoff of the grey set and the join back are M6's LaunchJoin contract (mutex release/acquire). |
| A5 | Two traces (§8): the **cycle projection** from `gc-heap-tsan` (real allocator), and a **tiny-graph** driver for heap content. |
| A6 | §5: twelve mutants, all in the sketch, plus the expected-fail `quick_region` configuration (a suspected defect, §10 Q4). Five of them mirror existing C++ negative controls (`test_snapshot_skip_young_walk_`, `test_snapshot_skip_external_`, `test_skip_allocate_black_`, the release and join tests). |
| A7 | `IM1`, `IM2`, `IM9` (+IM14), `MarkerFootprint` = IM3, `NoReleaseInCycle` = IM5, `DeferredOK` = IM8, `NoOldToYoung` = HEAP_005, `NoLostObject` = MODEL_M1_1, `SnapshotClosure` = the parallel-gc.md §2.1 lemma. Related rows: HEAP_063, HEAP_065, HEAP_SNAPSHOT_001/002, HEAP_BUILDER_001/002, HEAP_062. |
| A8 | 5 ids, 1 field, 2 roots, 1 store, T = 2, 4 minors, 2 operations per epoch, 1 stop, 1 major (deep: 6 ids, 2 fields, 6 minors). No counters wrap. The lemma is unbounded via §4.7 (Apalache, then TLAPS). |
| A9 | `region` markers: `ThreadLocalHeap::startMarkCycle`, `stepMarkCycle`, `finishMarkCycleNow`, `completeMarkCycle`, the join lines of `majorGC`; `OldGenSpace::beginMarkCycle`, `snapshotYoungLarge`, `afterSnapshot`, `launchBackground`, `reapBackground`, `runCycleStepConcurrent`, `closingFinish`, `drainCycleMark`, `handoffMarkCycle`, the cycle branch of `initObjectHeaderWithSize`, `finalizeBitmapCell`, `finalizeBitmapCellW`, `finalizePoppedCellW`, `sweepNurseryLargeBodies` (the deferral), `freeLargeBodyCell`, the four release-path IM5 asserts, `greyObject` (young abort), `scanObject` (`Tag_Free` skip); `NurserySpace::forEachYoung`/`forEachSurvivor`; `OldGenSpace::grantAllocate`/`grantAllocateShared` (black copies). `census`: `OldGenSpace.cpp`, `ThreadLocalHeap.cpp`, `OldGenTenure.cpp`. `grep`: `deferred_frees_`, `cycle_state_ =`, `bg_ep_ =`, `addExternalRootScanner` (every new off-heap store must be a t0 root). Added in the review: `OldGenSpace::retireDeadLargeBodies` and `classifyBlocksAfterMark` (the tail frees unmarked YLOS cells), `NurserySpace::mergeJob`'s zap and YLOS-promotion blocks (`NurseryTenure.cpp:731-743`, `:816-825`), the hand-over transition in `minorGCRegion` (`NurseryRegion.cpp:1075-1085`), and the order of the pressure check and `cycleStep` in `stepMarkCycle`. `grep`: `writeFiller(z.p` (which extents are zapped), `vnodeRegistry` (a latent unregistered store, §10 Q2). |

## 8. Trace validation

M1's trace validation has two parts, because the real heap is too large to replay object by
object.

**(a) Cycle projection (real allocator, `test/gc-heap-tsan/heap_driver.cpp`).** Log only
cycle-level events on the mutator thread, and the episode's launch and exit on the background
gang:

| Event | Hook | Fields |
|---|---|---|
| `minor` | `ThreadLocalHeap::minorGC` entry (`:706`) | `n` |
| `t0` | end of `startMarkCycle`, before `afterSnapshot` (`:1125`) | `greys` (count) |
| `launch` / `relaunch` | `launchBackground` (`OldGenSpace.cpp:4431`), relaunch branch (`:4690`) | — |
| `reap` | `reapBackground` after the join (`:4505-4525`) | `done` |
| `stop` | `stopAllForFork` (`GCHelperPool.cpp:650`) | — |
| `assist` / `closing` / `pressure` / `join` | `assistEpisode`, `closingFinish`, `finishMarkCycleNow(why)` | `units` |
| `handoff` | `handoffMarkCycle` entry (`:4258`) | `k` |

The trace spec projects M1 onto `cycle`, `k`, `episode` and the pause kind (heap variables
hidden). It accepts the log iff the code's cycle schedule is one the model allows. That catches,
for example, a handoff that is not at minor `t0 + T + 1`, a relaunch while `Running`, or an assist
after the closing step. All of these events are on the mutator thread, except `stop` and `reap`'s
view of the episode, so the order is the thread's order. Two mapping rules:
- `stop` maps to the `Forker` step. The following `reap` with `done = false` is part of that same
  model step, so it maps to a stutter at `P_Marking` (§4.1).
- A `pressure` event comes before any `reap`/`relaunch` of its pause (`stepMarkCycle` checks it
  first), and after `closing`, `pressure` or `join` the projected episode is `none`
  (`closingFinish` ends with `bg_ep_ = None`).

**(b) Heap content (a new tiny-graph driver).** A 30–50-line addition beside `heap_driver.cpp`:
- it builds at most 8 objects through the real allocator with a small nursery, and keeps a side
  table `address → id` updated at every copy (the driver owns all roots);
- it logs its own mutator operations (`load`, `drop`, `store`, `alloc`) and the collector's `scan`
  (`scanEntry`, `OldGenSpace.cpp:3448`), `grey` (`testAndSetMark` newly set, `:3039`),
  `promoteBlack` (the allocate-black branches) and `free` (the handoff's frees, through a
  validate-build hook in `runPostMarkTail`);
- the trace spec replays the log against M1's `Next`, with `pc` and the ghosts hidden.

Rejected traces are code bugs or model errors (parent plan §6.3).

**Ordering in (b).** Collector events on background threads are ordered against mutator events
only through the mark bytes they read and write:
- a `grey` event logs the byte value its `fetch_or` returned;
- a `promoteBlack` on the atomic paths (`initObjectHeaderWithSize`, `finalizePoppedCellW`) logs the
  value before its `fetch_or`. The cursor and grant paths (`finalizeBitmapCell`,
  `finalizeBitmapCellW`, `grantAllocate`) use a plain `setBit` on a post-t0 block that no marker
  touches (IM13), so they need no ordering against `grey` events. A `grey` event on such a block
  is itself a violation (TV8 / `MarkerFootprint`);
- two events on one byte are ordered by those values (a `fetch_or` chain).

Other cross-thread pairs are left unordered, and the trace spec allows either order.

## 9. Implementation steps

1. Create `test/tla/M1-snapshot-mark/` with `SnapshotMark.tla` (§4.5), `MC.tla` (§6), the
   configurations of §6, one configuration per mutant (`MUTANT` + target invariant only),
   MAPPING.md (§4.4 + A3 rows + the region-mode assumption of §2.5, recorded as the
   **TenureDisjoint** contract with M5's `HealYoungOnly` and `MarkerDisjoint` as its discharging
   invariants and M5 §8.2 for the merge's YLOS writes + the "one mark bit per object" caveat) and
   AUDIT.md.
2. `pcal` + `sany`. **SANY exits with status 0 even when it reports semantic errors**: the first
   draft of this sketch had 37 of them (a missing `EXTENDS Sequences`, which the translation needs
   for procedure call stacks) and still exited 0. The runner must scan SANY's output for
   `Semantic errors` / `*** Errors`, not trust its exit status.
3. TLC on `quick`, `quick_sync` and `quick_region` (expected: violates `MarkerFootprint`; record
   the counterexample in AUDIT.md and against the register entry proposed for §10 Q4). If too slow,
   apply §6's reduction order.
4. Each mutant: confirm it fails with its target. Save the shortest counterexample of `p1_violation`,
   `no_alloc_black`, `release_during_cycle` and `skip_young_walk` into AUDIT.md: they are the
   §2.4 timelines, now machine-produced.
5. (Done in the review: `promote_ignores_builder` and `handoff_skips_drain` are in the sketch.)
6. `deep` in `tla-check-deep`.
7. §4.7: write `SnapshotLemma.tla` (plain TLA+, Apalache type annotations, `EXTENDS Apalache`
   for the folds, no recursive definitions), run the inductiveness check at `|Obj| = 6` and then
   8, and record the result. TLAPS only if the image has it.
8. Trace validation (a) on `gc-heap-tsan` (hooks in the listed functions, under `ECO_TLA_TRACE`),
   then (b) with the tiny-graph driver.
9. Canary lines (A9) in `test/tla/manifest.txt`; `models.txt` rows; the parent plan's §11 row.

## 10. Open questions for the implementer

1. **Young large objects promoted in place keep their t0 mark.** The model assumes
   `promoteYoungLarge` (`OldGenSpace.cpp:7107`) leaves the mark bit alone. The code does: it
   touches only the index and `Header.age`. Keep a canary region on it: a future change that
   cleared the bit would break IM2 in exactly the `no_alloc_black` way.
2. **New off-heap stores.** HEAP_SNAPSHOT_002 is only as good as the list of registered external
   scanners. The `grep` canary on `addExternalRootScanner` makes every new registration a model
   re-audit. Is there any overwritable location that is *not* registered (e.g. a static in a
   kernel)? That would be `skip_external` in real life (an unregistered store is never read, not
   read late). **Review answer (2026-09-28):** one latent case.
   `elm-kernel-cpp/src/virtual-dom/VirtualDom.cpp:390` `static std::vector<VNodePtr> vnodeRegistry`
   is not scanned, and a `VNode` can hold `std::vector<HPointer> refs` (`VirtualDom.hpp:87`),
   JSON facts and tagger closures. Today nothing stores a heap pointer there: the exports that
   would (`Elm_Kernel_VirtualDom_on`, `map`, `lazy*`, `VirtualDomExports.cpp:95-126`) are
   `assert(false)` stubs. It becomes a HEAP_SNAPSHOT_002 hole (and an ordinary rooting bug for STW
   majors) the day they are implemented; the `vnodeRegistry` grep canary (A9) flags that. Every
   other pointer-holding store found is registered (`PlatformRuntime`, `PortRuntime`, `Scheduler`,
   `HttpExports`, `TimeEffectManager`, the list scratch, `CellStore`, `MVar`, `eco/Runtime`; CAF
   slots and globals as JIT roots), and permanent-space objects point only at permanent objects or
   constants.
3. **The one-step minor under region mode.** Region mode's minor also resolves references into the
   Retire extent and heals slots at the merge (M5). M1's one-step minor is valid if those writes
   touch only young objects and roots. **Review answer:** the heal list holds slots of Fresh
   survivor copies, generation-m YLOS and marked ageing objects (`NurseryRegion.cpp:470`,
   `TenureWork.hpp:363`), all young. The one old-object write is the fixup of a YLOS promoted in
   place in the same merge (`NurseryTenure.cpp:731-743`), which is black and never scanned (§2.5).
   This is discharged by M5's **TenureDisjoint** contract: `HealYoungOnly` for the heal list and
   `MarkerDisjoint` for the markers, with the merge's YLOS writes covered by M5's YLOS extension
   (M5 §8.2).
4. **Region mode: the t0 walk reads dead hand-over objects (suspected defect).** With k = 1 the
   Tenuring extent's dead objects are not zapped before t0 (§2.5). If a STW major (allocation
   failure or explicit) ran in the epoch before the t0 minor, it freed the old objects that only
   those dead objects referenced. `forEachYoung` → `markChildren` then greys a freed cell:
   - its mark bit is set on a free cell, and a marker scans its stale image (floating garbage);
   - validate builds can abort spuriously: IM4 (`assertCellWasWhite`) when a mixed block's free
     cell is reallocated mid-cycle, or IM6 at the handoff if the cell has a `Tag_Free` header;
   - if the freed cell's block was released and its range later rematerialised as a post-t0
     block (a promotion cursor or a tenure grant), a background marker scanning the stale image
     can test-and-set a bit in that block while its owner sets bits with a plain `setBit`
     (IM13's premise broken): a lost allocate-black bit, and a live copy freed at the handoff
     (S1, a long precondition chain, not reproduced).

   `quick_region` reproduces the first link (`MarkerFootprint`). Candidate fixes: zap, at the
   STW major, the dead objects of the Young and Tenuring extents (the STW mark knows which nursery
   objects it reached, and the 07b merge zap is the model); or have the hand-over minor mark its
   extent transitively and zap what it did not reach before the t0 walk (more pause work). Either
   makes `quick_region` pass.

## 11. Adversarial review (2026-09-28)

Against the current tree. Tools run: `pcal -nocfg` and `sany` on the corrected sketch (clean), and
`sany` on the §4.7 definitions (clean). TLC and Apalache were not run: every "expected" result is a
hand-traced prediction (§5 table).

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | Region mode (default): with k = 1 the Tenuring extent's dead objects are not zapped before t0, and `forEachYoung` greys their old children. After a STW major in the preceding epoch those cells can be freed, so markers hold freed cells (`NurserySpace.hpp:800-830`, `NurseryTenure.cpp:816-825`, `OldGenSpace.cpp:2867-2900`). The plan called this "conservative"; the model could not see it, because `P_Minor` freed every dead young object. Suspected code defect | `RegionMode` + `zombie`; `quick_region` expected to violate `MarkerFootprint`; §2.5, §10 Q4 |
| R2 | Major | The tail sweep frees unmarked YLOS cells too (`retireDeadLargeBodies`, `OldGenSpace.cpp:1657`; STW majors likewise). The model freed only unmarked old objects, and `IM1`/`IM2` covered only old objects, so an unmarked live YLOS was not a loss | `CellObjs` in `H_Free`, `J_STW`, `t0Reach`, `IM2` |
| R3 | Major | `stepMarkCycle` checks the pressure finish before `cycleStep`, at any `k` including `T`, with no reap or relaunch (`ThreadLocalHeap.cpp:1149`). The model put it after the relaunch and only for `k < T`: a real schedule (handoff at minor t0 + T) was missing, and trace (a) would reject real logs | pressure choice moved into `P_Marking`, before the reap |
| R4 | Major | §4.7's `LemmaInv` was not inductive (`WhiteReachable` silent at `handoffDue`; `FieldsFrozen` false for S_H builders and reused ids; no IM5, grey-in-S_H, closure, YLOS-black, age-order or no-dangling conjuncts), so the length-1 check would report spurious counterexamples | invariant rewritten with the reasons; `ReachWithin` defined; action restatement rules (t0 fused with the minor, `grey = {}` guards) |
| R5 | Major | Apalache 0.62.2 rejects recursive functions ("Apalache does not support recursive functions"); the plan said the recursive-function `Reach` works in Apalache | `ReachWithin` as an `ApaFoldSeqLeft` fold; note in §4.5 |
| R6 | Minor | `closingFinish` ends with `bg_ep_ = None` (`:4635`); `D_Done` left `finished`, a trace-projection mismatch | `D_Done` sets `none` |
| R7 | Minor | `lazy_external`'s shortest counterexample was `skip_external`'s: the lazy read never had to happen | the late read happens when a marker runs dry (`Marker`, `DrainAll`); the violation now needs the post-t0 overwrite |
| R8 | Minor | Premise drift: "validate builds enforce P1". Detection is sampled (O: 1 in 16), W covers four helpers, and a write during a cycle is seen only at the next verify. The lemma itself does not need P1; the marker's completeness does | §2.3, §2.4 (a), §4.7 item 3 |
| R9 | Minor | The fork stop never writes `bg_ep_` (it stays `Running` until the next reap); the assist gate reads it. The model's `Forker` merges stop and reap; its `Assist` is unconditional | documented in §4.1 (over-approximation of progress; sound) |
| R10 | Minor | The one-step minor's "disjoint footprint" holds at object level only; mark bytes, block publication and `live_bytes` are shared metadata | §4.1 row names what is checked here and what is delegated (M4, W3, W4) |
| R11 | Minor | The two "to add" mutants were not in the sketch; every mutant's reachability was unproven | both added; shortest behaviours hand-traced in §5 (all within 4 minors, 2 ops, 1 major, 0 stops) |
| R12 | Minor | §6's reduction order would have dropped what `quick_region` and `promote_ignores_builder` need; the only free id at the start is a YLOS id | reduction order and a heap note fixed |
| R13 | Minor | Trace (b) said every allocate-black is a `fetch_or`; the cursor and grant paths use a plain `setBit` on post-t0 blocks | §8 ordering note |
| R14 | Minor | Line drift and missing citations: assist `:4707-4744`, reap/relaunch `:4688-4699`, pressure `:1149`, fork stop `GCHelperPool.cpp:650`, `processDeferredFrees` caller `:3953`, IM5 assert in `freeLargeBodyCell` `:7316`; the IM5 asserts are debug-only | §2.1, §3, §4.4 |
| R16 | Major | (Orchestrator, reviewing R1.) With `quick_region` checking only `MarkerFootprint` until the fix, the default nursery mode would get no other invariant checked. R1 needs a STW major, and nothing else frees a zombie's old child | new config `quick_region_nomajor` (`RegionMode=TRUE`, `MaxMajors=0`, all nine invariants, expected pass), §6 |
| R17 | Minor | (From the M2 review.) The abstraction table credited M2's Drain contract with "several markers are observationally one consumer". M2 does not discharge that: its scans grey children one `fetch_or` per step | §4.1 row now separates M2's part (`ScanOnce ∧ TerminationSafe ∧ Drain`) from M1's own argument for the atomic scan (P1, monotone marks, atomic RMW, no modelled mutator step reads mark state) |
| R15 | — | Checked and right: the k/T arithmetic (handoff at minor t0 + T + 1); the STW major's join order (tenure join, cycle join, STW mark); the P1 census of runtime and kernel writes (no violation; the merge's fixup of a YLOS promoted in place is a GC fixup on a black object); HEAP_SNAPSHOT_002 registrations (one latent unregistered store, `vnodeRegistry`, §10 Q2); M5 provides the disjointness M1 assumes as the **TenureDisjoint** contract (`HealYoungOnly`, `MarkerDisjoint`; §2.5, §10 Q3); 5b slices (`conc_mark = 0`) are covered as "the `Marker` never steps"; the §3 citations not listed in R14 | — |
