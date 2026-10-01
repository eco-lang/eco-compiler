# Threaded GC 07 — Survivor regions (7b) and concurrent tenuring (7c)

**Status:** DONE (2026-09-28): 7b and 7c built and gated. The phase closed with the default left
at `nursery_regions = 0` (P§10.17: E4 fails at one collector, E6 at four, E7 on its per-point
rule); **the user then made mode 2 with one collector the default** (TG7d, P§10.17 addendum:
`nursery_regions = 2` = auto, `tenure_mode = 2`, `tenure_collector_threads = 1`). Previously
PLANNED (2026-09-27). Written against the `keep-TG5c` tree **plus the phase 6 plan as
designed** (`plans/threaded-gc-06-parallel-minor.md`, PLANNED, not yet implemented). Nothing here
is implemented. Step 0 re-derives every premise against the tree phase 6 actually leaves
(`keep-TG6`).

**Parent:** `plans/threaded-gc-master-plan.md`, phases 7b and 7c. (7a, the frozen published heap,
is phase 4.)

**Depends on:**
- phase 2: bitmap allocation, `AllocCursor`, `partial_[cls]`, IM13, HEAP_054;
- phase 3: GC_DET_001, `GCHelperPool`, the atfork discipline, the TSan harnesses;
- phase 4: P1 (HEAP_SNAPSHOT_001), the P1 census, FORBID_HEAP_005;
- phase 4b: young large objects (YLOS, HEAP_062);
- phase 5a–5c: the snapshot cycle (HEAP_063), allocate-black, `isT0Block`, the MarkView,
  `GCBackgroundGang`, the stop/relaunch pattern (5c-P§3.3–3.5);
- phase 6: the parallel minor engine (`NurseryParallel.cpp`, `MinorWork.hpp`, `evacuateP`,
  `scanEntryP`, `spineRun`, LABs and `Tag_Free` fillers, object-byte accounting HEAP_068,
  `PromoCtx`/`promo_mu_`, `chooseMinorWorkers`, `gc_minor_threads`, the GC_DET_001 amendment).
  **Region mode is built on the phase 6 engine only** (P§1 rule 1). If phase 6 closed without
  that engine, stop and revise this plan.

**Background:**
- `design_docs/parallel-gc.md`: §7.4.2 (design C), §7.4.3 (P1), §7.4.4 (hazards H-hdr, H-body,
  H-valid, H-major, H-id, H-L3), §2.4 (forwarding may not live in a header the mutator reads),
  §7.3 (en-masse), §11 (invariant impact), §12.1 (RC-1 is compatible with C only for
  never-survived objects);
- the handbook summaries in `design_docs/gc_handbook/`: HB 9.4 (remembered sets record source
  slots), HB 9.5 and 4.4 (eden + survivor spaces; en-masse promotion), HB 4.5 (survivor overflow),
  HB 9.6 and 9.11 (multiple generations; nepotism), HB 8.2 (constant-time reclamation of an
  unreferenced region), HB 17.1/17.5/17.7/17.9 (concurrent copying hazards, self-healing,
  young generation usually STW, copy-then-forward), HB 19.2/19.4 (work-based scheduling;
  Henriksson's GC ratio and deferred copying).

§n points into `design_docs/parallel-gc.md`, P§n into this plan, M§n into the master plan,
6-P§n / 5c-P§n / 5a-P§n into those plans, and HB n into the handbook summaries.

---

## 0. What this phase delivers, and why

**Where phase 6 leaves the pauses** [E; 6-P§0 predictions. Step 0 replaces them with measured
figures]:

| quantity | after phase 6 (N = 4, predicted) |
|---|---|
| worst pause | ~70 ms, a minor GC |
| minor pause p50 | ~9 ms |
| minor GC per run | ~16–18 s |
| share of a minor that is promotion | ≈ 60–70 % (phase 0: 67 % at N = 1) |

After phase 6 the minor GC is still the worst pause and the largest block of GC time, and most of
it is promotion: finding each aged survivor, allocating its old-gen cell, copying it and
re-scanning it.

**This phase moves promotion out of the minor pause.**
- **7b — survivor regions, promotion still in the pause.** The nursery becomes an **eden** plus
  **three survivor extents** that rotate through the roles *fill → fresh → hand-over → tenuring →
  retire → free*. A minor GC copies eden survivors into the fill extent (as phase 6 copies into
  to-space) and **records**, without loading any header, every reference into the extent filled
  at the previous minor. That extent is then **tenured** by a *tenure job*: its live objects are
  promoted into the old gen, with forwarding kept **off-header** in a per-extent **shadow table**.
  References into it are **resolved and healed at the next minor**, and the extent is retired.
  In 7b the tenure job runs inside the pause (`tenure_mode = 1`, sync). 7b is the exact
  reference for 7c and the place where every validator, the retention bound and the object-count
  oracle against the legacy nursery are established.
- **7c — the tenure job on a collector thread.** The same job, unchanged, runs on a per-heap
  background thread (`tenure_mode = 2`) during the mutator epoch that follows the minor. The next
  minor waits for it, or stops it and finishes it in the pause if it is late. The minor pause
  shrinks to: the heal, the roots, and the eden → fill copy.

**Three properties make this more than "move the promotion loop to a thread":**
1. **The collector writes nothing the mutator can read.** It reads the tenuring extent and the
   recorded slots (both immutable under P1). It writes only its shadow table, its own copies in
   old-gen blocks granted to it in the pause, and its private job state. **The heal is done by
   the next pause, not by the collector.** This keeps HEAP_006, HEAP_030, HEAP_SNAPSHOT_001 and
   the P1 census literally true and makes TSan's job easy (P§3.22 records why the concurrent heal
   of the report was rejected).
2. **The collector never touches shared allocator state.** Its old-gen allocation is a
   **promotion grant**: uniform blocks, sized in the pause from the extent's per-class object
   counts, owned by the job from grant to merge (P§3.12). The mutator's own old-gen allocation
   during the epoch (bodies, YLOS cells) never contends with it.
3. **Exactness.** With one minor worker and a single-threaded tenure job, mode 2 reproduces mode
   1 **bit for bit**: every counter, every old-gen placement and every major decision, under
   jitter and under forced stops. At any worker count, every object counter equals the legacy
   nursery's (tenured counts compared with a one-minor shift, P§3.18). The legacy nursery is
   the oracle for 7b; 7b is the oracle for 7c.

**Expected result** [E; the report's §7.4.2 net estimate rescaled onto the phase 6 prediction.
Step 0 replaces the base numbers]:

| configuration (self-compile) | minor pause p50 / worst | minor GC per run | wall vs phase 6 |
|---|---|---|---|
| phase 6, N = 4 (base) | ~9 ms / ~70 ms | ~16–18 s | — |
| 7b, region sync, N = 4 | ~10 ms / ~75 ms | ~17–19 s | +0 to +2 s (heal + shadow overhead) |
| 7c, region concurrent, N = 4 | ~4 ms / ~35 ms | ~6–8 s in pauses | −6 to −10 s (−1 to −3 s L3 interference) |
| 7c at N = 1 (no parallel minor) | ~8 ms / ~70 ms | ~15 s | the report's −20 to −28 s vs legacy N = 1 |

The pause that remains: stack walk, heal, roots (CellStore up to 8.6 ms), eden → fill copy, eden
zeroing, and the epilogue. That is M§5's "roots + first copy".

| # | Deliverable |
|---|---|
| D0 | Re-verified facts (P§2) against `keep-TG6`; a same-session baseline against `eco-optTG6`; the censuses of P§4 Step 0 (heal-list size, collector utilization, builders, object sizes, heap slots, block-selection audit, YLOS); snapshot `try-TG7-pre` |
| D1 | Configuration (`nursery_regions` and the tenure fields), the region slice set (`NurserySliceSet`, n extents per slot at a power-of-two stride), geometry and commit. Inert when off: counters identical to `eco-optTG6` |
| D2 | `RegionRing`: extent states and transitions, `roleOf`, `contains`, the validate-build stale-pointer detector, poisoning and eden flip. Unit-tested without a GC |
| D3 | `TenureWork.hpp` (std-only): the shadow entry, claim / publish / resolve, the resumable serial tenure engine over a template Env; a synthetic-heap harness |
| D4 | The promotion grant in `OldGenSpace` (`kAllocTenure`, `grantTenure`, `returnTenureGrant`), and the skip rule on every block-selection path |
| D5 | The region minor, sync mode, exact engine: record / resolve / heal / builders / eden allotment / growth / zeroing / retirement; tenure launch and join in `ThreadLocalHeap`; large bodies and YLOS by generation; stats; E2E in region mode |
| D6 | Mark-cycle integration (the t0 young walk, the STW major rule, handoff), the P1 census in region form, validators TV1–TV11, negative controls, the validate tree with eden flip |
| D7 | The parallel tenure engine for the pause (sync with n > 1, and help with n > 1) |
| D8 | 7b measurement (E0, E1, E3-sync, E7, E10) and 7b close-out |
| D9 | `TenureCollector` (a per-heap `GCBackgroundGang`), launch / join / stop / help, fork and exit |
| D10 | TSan: `tenure_harness.cpp` (synthetic) and `gc-heap-tsan` (real allocator, region mode 2, with a 5c cycle running) |
| D11 | Determinism (E2) and the validate tree in mode 2 |
| D12 | 7c measurement (E3–E9, E11) and the default decision |
| D13 | Docs, invariants, tracking |

**Out of scope:**
- **tenure age k > 1** (in-place ageing across more survivor extents). It is a separate lever,
  specified in P§12 and not part of this phase's done;
- more than one collector thread per heap (P§9, lever L3);
- a concurrent heal (P§3.22, P§9 lever L2);
- promoting in address order, or en-masse without a trace (P§9, levers L4/L5);
- old-gen compaction in region mode (it has no production caller; region mode refuses it, P§3.16);
- changing the legacy nursery. `nursery_regions = 0` runs phase 6's code unchanged.

---

## 1. Ground rules

1. **`nursery_regions = 0` is phase 6, unchanged.**
   - After D1–D4 every counter and both event logs (non-timing columns) equal `eco-optTG6` at
     every `gc_minor_threads`. `out.mlir` is byte-identical.
   - Region mode runs **only** on phase 6's parallel engine (`NurseryParallel.cpp`), at any
     n ≥ 1. It never runs `minorGCSerial`. The legacy serial path stays the reference for the
     legacy nursery.
2. **The legacy nursery is region mode's object oracle** (E1). With region mode on, every object
   counter equals the legacy run's at the same `gc_minor_threads`:
   - minors, objects allocated, survived counts and bytes per tag, nursery growth events and
     final size, `alloc_end_capped` = 0;
   - tenured counts and bytes per tag equal legacy's promoted counts, **shifted by one minor**:
     region row m+1 `tenured` = legacy row m `promoted` (P§3.18);
   - young large objects promoted in place and freed equal legacy's, with the same shift.

   A difference is a bug (a lost or double promotion, a wrong liveness decision, a filler counted
   as an object), never noise.
3. **Mode 1 is mode 2's exact oracle** (E2). With `gc_minor_threads = 1` and the exact tenure
   engine (P§3.11), `tenure_mode` 1 and 2 are bit-identical in **every** counter class, including
   old-gen placement and the major sequence, at `ECO_GC_HELPER_JITTER_US` 0 and 50 and with the
   forced-stop test hook. At n > 1 the object class stays identical; placement is
   schedule-dependent (phase 6's amended GC_DET_001).
4. **The collector writes only** (P§3.17):
   - shadow entries of the extent it is tenuring (claim CAS, release publish);
   - cells, bitmap bytes and cursor state of blocks granted to its job;
   - its job-private state (stack, logs, counters, YLOS reached flags).

   It **never writes** a young object, an old object other than its own fresh copies, a root, a
   header of any published object, or any shared allocator structure. Anything else it writes is
   a bug, and `gc-heap-tsan` is the mechanical check.
5. **No decision reads collector progress** (GC_DET_001). Progress may decide only pause-internal
   work: whether to wait or help, and with how many workers. The promoted set, the grant, the heal,
   the triggers and the schedule are functions of objects and configuration.
6. **Every premise gets a validator** (TV1–TV11, P§3.19) that the validate tree runs on unit,
   E2E and stress, in modes 1 and 2, at n ∈ {1, 4}.
7. **Standing gates** (M§2): E2E, elm-tests, `full`, stress under GC pressure, the validate tree,
   the stats-off build, `out.mlir` byte-identical, the bootstrap fixed point.

---

## 2. Verified facts

Verified 2026-09-27 against `keep-TG5c`; phase 6 facts are its plan, not yet code. Paths are under
`runtime/src/allocator/`; line numbers are approximate. **Re-verify every row against `keep-TG6`
in Step 0. Trust the name, re-locate the line** ([[gc-plan-premises-need-rederiving]]).

| # | Fact | Where |
|---|---|---|
| F1 | **Nursery geometry (HEAP_042/043).** The nursery region is the top `nurseryRegionBytes()` of the reservation (default 4 GiB of 24 GiB). It is split into a low and a high half; each half is carved into `nursery_slice_bytes_` slots (= `nursery_max_block_count / 2 × alloc_buffer_size` = 128 MiB, clamped to the half). A heap owns the low and high slice at one slot: 16 slots by default. `NurserySlicePair {low_base, high_base, capacity, slot}`; retained commit per side per slot (Issue #40 respawn). | `Allocator.cpp:505-640`; `Allocator.hpp:330-356`; `AllocatorCommon.hpp:500-520, 730-760` |
| F2 | **The legacy minor** (as phase 6 leaves it): prologue / serial core or parallel engine / epilogue. The epilogue runs `checkAndGrow`, `clearToSpaceFreeRegion` (zeroes `[copy_ptr_, to-space end)`; 5.6 % of self-compile CPU is this memset), the validate walks, `poisonOldFromSpaceUsedRegion` (0xDD over the evacuated prefix), the flip, `bump_.ptr = copy_ptr_`, census record, stats, `sweepNurseryLargeBodies(minor_color_)`, `validateYoungLarge`. | `NurserySpace.cpp:427-1140, 2253-2320`; 6-P§3.1 |
| F3 | **Survivor semantics today.** `promotion_age` = 1: an object surviving its first minor is copied to to-space with age 1 and promoted at the next minor if live there. Survivors (and builders) form the prefix of the new from-space and eden allocation continues after them, so `computeAllocEnd` gives eden `threshold − survivor object bytes` (6-P§3.5). | `NurserySpace.cpp:307-321`; `AllocatorCommon.hpp:148-152`; F5 of 6-P§2 |
| F4 | **Builders.** `shouldPromote` = `age >= promotion_age && !pin && !builder`. A builder keeps age 0 and is copied at every minor (HEAP_BUILDER_001/002). HEAP_BUILDER_003: the kernel clears the bit before the object is reachable from user code, so between minors a builder is reachable only from kernel roots and other builders. A promoted parent with a builder child aborts in validate builds. | `NurserySpace.hpp:403-405`; `NurserySpace.cpp:1398-1431`; `invariants.csv` HEAP_BUILDER_001–003 |
| F5 | **Pin.** Only old-gen objects carry `pin = 1` (large bodies, `allocateLargePinned`, YLOS cells). No nursery object is pinned. | `ThreadLocalHeap.cpp:500`; `OldGenSpace.cpp:6317, 6337` |
| F6 | **Large bodies (HEAP_026).** `LargeBodyMeta {body_base, cell_size, is_large, color, kind}`; `registerLargeBody`, `markLargeBodySeen` (index `find`, write `color`), `promoteLargeHeader` (swap-remove from `nursery_owned_bodies_`, index `erase`), `sweepNurseryLargeBodies(color)` frees nursery-owned entries whose color ≠ this minor's (deferred during a cycle). `large_body_index_` is an `unordered_map`. | `OldGenSpace.hpp:974-1010`; `OldGenSpace.cpp:6385-6540` |
| F7 | **YLOS (HEAP_062).** `allocateYoungLarge` (pinned old-gen cell, kind-1 index entry, bounding box `ylo_lo_/hi_`), `reachYoungLarge` (color once per minor; promote in place when `!builder && age >= promotion_age`, else `age++` and scan in place), `promoteYoungLarge` (index erase), `recomputeYoungLargeBounds` at minor end. | `OldGenSpace.cpp:6325-6385`; `NurserySpace.cpp:1678-1711` |
| F8 | **Size classes.** 32 small classes (8 … 256 B, step 8) and up to 8 medium classes (512 B << k, so at most 64 KiB); `num_size_classes_` may be configured lower. `sizeClass(size)` returns `NUM_SIZE_CLASSES` above the largest class, and `allocate` then takes the bag-page path (Path 4) below `alloc_buffer_size`. | `AllocatorCommon.hpp:337-349`; `OldGenSpace.hpp:1090-1144`; `OldGenSpace.cpp:1219-1232` |
| F9 | **Nursery placement cap for large pointer objects:** `min(capacity / large_ptr_nursery_divisor (8), large_ptr_nursery_max_size (128 KiB))`, else YLOS. 128 KiB is above the largest size class. | `ThreadLocalHeap.hpp:205-221`; `AllocatorCommon.hpp:100-103` |
| F10 | **Old-gen block lifecycle.** `alloc_state` ∈ {`kAllocNone`, `kAllocQueued`, `kAllocCurrent`}; `setCursor` carries IM13 (`isT0Block`); `refillCursor` pops `partial_[cls]`; `startVirginBlock`; `resetAllocCursors` at `startMark` (so mid-cycle `partial_` holds only post-t0 blocks); `detachFromAllocation`; `flushCursor` / `syncCursorLiveBytes`. | `OldGenSpace.hpp:540-600`; `OldGenSpace.cpp:662-880, 3582` |
| F11 | **Release reachable from the mutator.** `maybeShrinkCapacity` selects blocks with `fully_swept && live_bytes == 0` and releases them. Its light pass runs from `onSweepComplete`, which `lazySweep` reaches from the mutator's own `OldGenSpace::allocate` (Path 1 sweep slice when `gc_phase_ == Sweeping`), i.e. **outside any pause**. | `OldGenSpace.cpp:1165-1190, 4740-4755, 4950-5125` |
| F12 | **ThreadLocalHeap::minorGC order:** stack walk → `nursery_.minorGC` → `recordMinorPhases` → `notePacingMinorEnd` → `if (cycleActive) { stepMarkCycle(); return; }` → forced trigger → `evaluateMajorGCTrigger` → `startMarkCycle` or `majorGC`. There are three return paths. | `ThreadLocalHeap.cpp:699-758` |
| F13 | **t0 snapshot:** `startMarkCycle` greys old targets of every root (snapshot mode drops young targets), `snapshotYoungLarge`, then `forEachSurvivor(markChildren)` over the survivor prefix (IM7 asserts `bump_.ptr == survivor_end_`). | `ThreadLocalHeap.cpp:1039-1100`; `NurserySpace.hpp:152-177` |
| F14 | **STW major:** `majorGC` joins a running cycle (`finishMarkCycleNow(Join)`), marks roots through `markHPointer`; young objects are traversed through `nursery_visited_` (serial path, `nursery_->contains`). Parallel markers abort on any target inside the MarkView nursery reservation. | `ThreadLocalHeap.cpp:760-980`; `OldGenSpace.cpp:2318-2380` |
| F15 | **`GCBackgroundGang`**: per-`OldGenSpace`, `launch(fn, ctx, stop)`, `running`, `finishedApprox` (a hint), `join`, `stopAndJoin`, priority applied once per thread, atfork `stopAllForFork`, `stopAllAtExit`; launch/join are mutex release/acquire pairs. | `GCHelperPool.hpp:219-305`; 5c-P§3.4 |
| F16 | **P1 census:** detector N hashes nursery survivors at minor end and re-hashes at the next minor start (`censusRecord` / `censusCheck`); O samples promoted objects after the drain (`p1::recordPromoted`); W checks write sites. HEAP_SNAPSHOT_001 excludes "the GC's own writes … during a collection". | `P1Census.hpp`; `NurserySpace.cpp:457-463, 1069-1074`; `invariants.csv:705` |
| F17 | **Compaction** (`scheduleCompaction`, `incrementalCompactionSlice`) has no production caller; only tests call it. | `OldGenSpace.cpp:5663, 5736`; test grep |
| F18 | **`ReservedArray<T>`**: reserve VA, `ensureCommitted(n)`, `discard(range)` (zero + return pages), never moves. | `ReservedArray.hpp` |
| F19 | **HPointer word = raw absolute address** (low 3 bits zero for a pointer), below `HPOINTER_ADDRESS_LIMIT` = 2^43. `toPointerRaw(addr)` is the word. | `Allocator.hpp:511-530`; `Heap.hpp:65-75` |
| F20 | **Validators that say "nothing points into from-space":** `debugAssertValidNurseryPointer` (from-space allocated prefix; mid-GC also to-space), `isInFromSpaceAllocatedRegion` / `isInToSpaceAllocatedRegion`, `Allocator::validateInNurserySafe` (kernels, `validateNurseryHPtr`), the `Allocator::resolve` tripwire, the EcoBoxedStoreVerify barrier (`RuntimeExports.h:741`), the epilogue's STALE CHILD and OLD-GEN→NURSERY walks, and `poisonOldFromSpaceUsedRegion`. | `NurserySpace.cpp:726-1050, 2385-2440`; `Allocator.cpp:470-490, 995-1010` |
| F21 | **`visitHeapChildren`** mirrors `markChildren` but declines some tags (returns false); the nursery scan arms are `scanObject`'s (6-P§2 F7). | `HeapChildWalk.hpp`; `NurserySpace.cpp:1752-2067` |
| F22 | **Phase 6 (plan):** `evacuateP` claims from-space headers (kBusy, then publish), LABs into to-space from an atomic top, `Tag_Free` fillers, object-byte accounting (`filler_bytes_`, `objectBytesAllocated`), `chooseMinorWorkers` (space test `S + S/32 + n·lab ≤ capacity`), the per-worker `MinorWorker` with private stack and deque, `runMarkerLoop` with `MinorEnv`, `spineRun` (runs of 512 cells, count-based heads pass), YLOS under `ylos_mu_`, deferred large-body lists, PM1–PM6, HEAP_067/068. | 6-P§3.1–3.13 |
| F23 | **Machine:** 24 cores, no SMT, 16 MiB shared L3, 15 GB RAM. Phase 0: a memory-heavy co-runner made the mutator ~8 % faster, a spin-only one 2.4 % slower. | report §3.1; TG00 row of M§4 |

---

## 3. Design

### 3.1 Vocabulary

- **Minor m** is the m-th minor GC of a heap. **Epoch m** is the mutator interval after minor m.
- **Eden (E)** is the extent the mutator bump-allocates in. Every minor evacuates it completely.
- **Survivor extents (X0, X1, X2)** each hold, at any time, at most one **generation** `G_j`:
  the objects copied out of eden at minor j.
- **Roles during a minor m** (P§3.3):

  | role | holds | what minor m does with references into it |
  |---|---|---|
  | **Fill** | nothing yet; receives `G_m` | copies land here |
  | **Hand** | `G_{m-1}` (copied at m−1) | **records** them (no header load); after the minor the extent is handed to the tenure job |
  | **Retire** | `G_{m-2}` (tenured during epoch m−1) | **resolves** them through its shadow; the extent is retired at the end of the minor |

- **Extent states between minors:** `Free`, `Fresh` (holds `G_m` during epoch m), `Tenuring`
  (holds `G_{m-1}`; the tenure job runs on it during epoch m). At minor m+1: Free → Fill,
  Fresh → Hand, Tenuring → Retire, and at its end Fill → Fresh, Hand → Tenuring, Retire → Free.
- **Tenure job m** promotes the live objects of the Tenuring extent (`G_{m-1}`) during epoch m.
  It is built at the end of minor m, runs inside minor m's pause (mode 1) or on the collector
  during epoch m (mode 2), and is **joined and merged** at the start of minor m+1 (P§3.15).
- **Start set S_m**: the Hand targets found at minor m in roots and builder slots.
  **Heal list H_m**: the addresses of heap slots, found at minor m in Fill copies and in young
  non-builder YLOS objects, that point into Hand (P§3.6).
- **Shadow `Sh[x]`**: per survivor extent x, one 64-bit word per 8-byte granule: the off-header
  forwarding of that extent's objects (P§3.10).
- **Grant**: the uniform old-gen blocks owned by one tenure job (P§3.12).

### 3.2 Layout and geometry

- Region mode replaces the two-half slot table with a **slice set**: a heap owns `n` extents,
  laid out contiguously in one **slot block** `[slot_base, slot_base + n·X)`, extent k at
  `slot_base + k·X`.
  - `X` = the next power of two ≥ `nursery_slice_bytes_` (128 MiB by default, already a power of
    two). The shift `log2(X)` makes `roleOf` a subtraction, a compare, a shift and a table load
    (P§3.4).
  - `n` = 4 in production: `E, X0, X1, X2`.
  - `n` = 5 with **eden flip** (default in validate builds, P§3.19): `E0, E1, X0, X1, X2`. Eden
    alternates between `E0` and `E1`, so the evacuated eden stays poisoned for a whole epoch, as
    the legacy from-space does today.
  - `slots = nurseryRegionBytes() / (n·X)`: 8 heaps by default in production (legacy: 16), 6 with
    eden flip. Step 0 item 7 counts concurrent heaps in the test suites. If any suite needs more
    than 8, region mode's default `nurseryRegionBytes()` doubles when `max_heap_size / 2` allows
    it, and the rule is recorded in HEAP_069.
- **Capacity.** One `capacity` for every extent (as HEAP_042 has one for both sides). Growth
  extends all n extents in place, or none. `capacity ≤ X`.
- **`NurserySliceSet {char* slot_base; size_t stride_log2; unsigned n; size_t capacity; size_t
  slot;}`** replaces `NurserySlicePair` in region mode. `Allocator::acquireNurserySliceSet`,
  `growNurserySliceSet` and `releaseNurserySliceSet` follow the pair functions exactly (retained
  commit is tracked per extent: `retained[k]`). The pair functions and the two-half table stay
  for legacy mode; `rebuildNurserySliceTable` builds whichever layout the config selects
  (first-init-wins for the region reservation, as today).
- **Why all extents have eden's capacity.** A fill extent must hold everything that survives
  eden plus the builders it carries over. Sizing every survivor extent at eden's capacity makes
  **overflow impossible by construction** (P§3.8 gives the bound), exactly as equal semi-spaces
  do today. That is the answer to HB 4.5's overflow question without an in-pause promotion path.
  The cost is address space, not memory: a survivor extent is only touched up to its survivors'
  high-water mark (RSS in P§3.20 and E7).
- **Shadows.** Each survivor extent owns a `ReservedArray<uint64_t> shadow` of `X / 8` entries
  (granule 8 B; P§3.10), reserved at slice-set acquisition, committed as capacity grows. Eden has
  no shadow.

### 3.3 The region ring

```cpp
enum class XState : uint8_t { Free, Fresh, Tenuring };
struct Extent {
    char*    base;             // slot_base + k·X
    XState   state;
    char*    surv_top;         // survivors [base, surv_top): objects and Tag_Free fillers
    char*    bld_lo;           // builders [bld_lo, base + capacity), bump-down; == base+capacity when none
    uint32_t gen;              // shadow generation, bumped at each hand-over (P§3.10)
    uint64_t gen_minor;        // the minor that filled it (G_j: j)
    size_t   obj_bytes;        // object bytes in [base, surv_top) (fillers excluded)
    size_t   bld_bytes;        // bytes in [bld_lo, end)
    uint32_t class_count[NUM_SIZE_CLASSES];   // survivor objects per size class (the grant input, P§3.12)
    std::vector<HPointer> lb_bodies;          // bodies whose header was copied into this extent (P§3.14)
    std::vector<void*>    ylos_gen;           // YLOS objects first reached at gen_minor (P§3.14)
};
struct RegionRing {
    Extent   x[3];              // survivor extents
    char*    eden_base[2];      // [1] only with eden flip
    char*    eden_dirty_hw[2];  // highest byte the mutator dirtied since that eden was last cleared
    unsigned eden_cur = 0;
    int      fill = -1, hand = -1, retire = -1;   // indices into x[], valid inside a minor
    uint8_t  role_of_k[8];      // extent index k in the slot block -> Role (P§3.4), rebuilt at each transition
};
```

- **`beginMinor()`** (minor start, after the tenure join):
  - `hand` = the Fresh extent, `retire` = the Tenuring extent, `fill` = the Free extent. A
    survivor extent is never zeroed: copies overwrite it from the base (P§3.8).
  - First minors: before minor 1 all three are Free; at minor 1 there is no Hand or Retire; at
    minor 2 there is no Retire. `beginMinor` handles the missing roles as `-1`.
  - Assert (every build): exactly one Free extent exists when there is a Hand and a Retire.
- **`endMinor()`** (after the epilogue's retirement):
  - Fill → Fresh (`gen_minor = m`), Hand → Tenuring, Retire → Free. A retired extent is unused
    for one whole epoch in every build (it becomes the fill at the next minor), so validate
    builds poison it (0xDD) and any stale pointer into it lands on poison, as a stale pointer
    into today's evacuated from-space does.
  - Eden: without flip, E is zeroed and reused; with flip, `eden_cur ^= 1`, the evacuated eden is
    poisoned for the epoch (the eden quarantine) and the other one is cleared (P§3.8).
  - `role_of_k` rebuilt.

### 3.4 Classifying a pointer (`roleOf`)

```cpp
enum class Role : uint8_t { NotMine, Eden, Hand, HandBuilders, Retire, Fill, Stale };
inline Role roleOf(const void* p) const {
    const uintptr_t d = uintptr_t(p) - uintptr_t(slot_base_);
    if (d >= n_extents_ << stride_log2_) return Role::NotMine;   // old gen, permanent, other heaps' nurseries
    const unsigned k = unsigned(d >> stride_log2_);
    const size_t off = d & stride_mask_;
    if (off >= capacity_) return Role::Stale;
    Role r = Role(role_of_k[k]);
    if (r == Role::Hand && off >= hand_bld_off_) return Role::HandBuilders;
    return r;                                  // Free survivor extents and the quarantined eden map to Stale
}
```

- Between minors, `role_of_k` is rebuilt for mutator-time validators: Eden, Fresh, Tenuring are
  legal (within their allocated parts), everything else is Stale (P§3.19 TV7).
- `contains(p)` = `roleOf(p) != NotMine` (region mode). `isInFromSpace` is not used by region
  code.
- **Cost.** `NotMine` (most children of a copy point at old or permanent objects) costs a
  subtraction and one compare, the same as today's `isInFromSpace` early-out. The rest is one
  shift, one mask and one L1 table load.

**The rule table** (P§3.5 uses it for roots, for copies' slots and for YLOS scans):

| target role | root slot | slot of a Fill survivor copy | slot of a builder copy or builder YLOS | slot of a young non-builder YLOS (scanned in place) |
|---|---|---|---|---|
| Eden, HandBuilders | evacuate (P§3.5) | evacuate | evacuate | evacuate |
| Hand | `S.push(target)` | `H.push(&slot)` | `S.push(target)` | `H.push(&slot)` |
| Retire | `slot = resolve(target)` | `slot = resolve(target)` | `slot = resolve(target)` | `slot = resolve(target)` |
| Fill | impossible: abort (validate) | already a copy: nothing | nothing | nothing |
| NotMine | YLOS reach if in the bounding box (P§3.14), else nothing | same | same | same |
| Stale | abort in every build ("stale nursery pointer", P§3.19 TV7) | same | same | same |

- **Why roots and builder slots go to S and not H.** Roots are rescanned at every minor, and a
  live builder is copied (and so rescanned) at every minor (F4). Their Hand targets are resolved
  when they are rescanned at minor m+1, when Hand has become Retire. The collector needs only the
  targets. Heap slots in survivor copies and in non-builder YLOS are **not** rescanned by the
  pause at m+1, so they must be healed from H.
- **`resolve(target)`** = the shadow lookup of P§3.10. It aborts in every build if the target was
  not promoted (TV1): such a target would dangle after retirement. Checking costs one compare on
  a word already loaded.

### 3.5 A region minor, end to end

`ThreadLocalHeap::minorGC` in region mode:

```
stack walk                                           // unchanged
nursery_.tenureJoin(old_gen_)                        // P§3.15: wait or help, then MERGE (below)
nursery_.minorGC(old_gen_, roots, rec)               // -> minorGCRegion
recordMinorPhases; notePacingMinorEnd                // unchanged
cycle step | forced trigger | trigger evaluation    // unchanged (startMarkCycle uses forEachYoung, P§3.16)
nursery_.tenureLaunch(old_gen_)                      // P§3.11/3.15: build job m, run (mode 1) or launch (mode 2)
```

- `tenureLaunch` must run on **every** return path of F12 (trap 2). Implement it as a scope-exit
  object constructed right after `nursery_.minorGC` returns, whose destructor calls
  `tenureLaunch`. That places the launch after any `startMarkCycle`, `stepMarkCycle` or handoff
  in the same pause.
- **The merge** (inside `tenureJoin`, before anything else touches the heap) applies job m−1's
  outputs (job m−1 tenured `G_{m-2}`, the extent that becomes Retire at this minor):
  1. P1 census check of the Fresh and Tenuring extents (region form of detector N, P§3.19). It
     must run **before** step 5, which writes Fresh objects.
  2. Old gen: `returnTenureGrant` (P§3.12): flush pending live bytes, return blocks, add the
     job's `allocated_bytes` / `old_alloc_total` deltas and allocation-histogram shares; IM4 log
     (validate); `p1::recordPromoted` with the job's promoted log (census builds).
  3. Large bodies: `promoteLargeHeader(b)` for every `b` in `job.lb_promoted`, in log order.
  4. YLOS of generation m−2: for each entry of the job's snapshot with `reached` set:
     `promoteYoungLarge(y)`, then scan `y` as a promoted parent: every child in the tenured extent
     is resolved through its shadow (TV1); validate asserts no young child remains (TV6).
  5. **Heal:** for every `s` in `H_{m-1}` (slots in `G_{m-1}` copies and in generation-(m−1)
     YLOS objects that point into `G_{m-2}`): `*s = resolve(*s)`. With n > 1 minor workers and
     `|H| > heal_parallel_min` the list is split into n contiguous ranges on `GCMarkGang`.
  6. Nursery stats: tenured counts and bytes per tag, YLOS promoted in place, collector busy time,
     into this minor's `MinorGCRecord` (the `tenured` columns, P§3.20).
  7. The job's state becomes `Merged`. The shadow of the tenured extent stays valid until its
     retirement at the end of this minor.
- **`minorGCRegion(oldgen, roots, rec)`**, with the phase 6 engine:
  1. Prologue (shared with legacy: flags, `minor_color_` flip, `young_large_scan_` cleared,
     validate pre-walk of the eden prefix). `ring_.beginMinor()`.
  2. **Set up the fill.** The fill extent's LAB top (phase 6's `tospace_top_`) = `x[fill].base`,
     `copy_end_` = `base + capacity`; the builder bump `bld_bottom_` = `base + capacity` (an
     atomic, decremented by `fetch_sub`). Reset `minor_workers_[0..n-1]`, including their new
     `H_w`, `S_w` and `class_count_w` vectors.
  3. **Roots**, serial on worker 0, in the legacy root order (6-P§2 F1 (b)): each slot is classified by the P§3.4 table.
     *Evacuate* is `evacuateR(w, slot)` (below). YLOS reaches go to `reachYoungLargeR` (P§3.14).
  4. **Hand-over preparation** for the Hand extent (`G_{m-1}`):
     - `oldgen.markLargeBodySeen(b, minor_color_)` for every `b` in `x[hand].lb_bodies`, so this
       minor's sweep keeps the bodies of headers the job may still promote (P§3.14);
     - recolor every object in `x[hand].ylos_gen` with `minor_color_` (same reason).
  5. **Distribute and drain** on n workers (6-P§3.1 steps 4–5). `scanEntryP` classifies every
     child slot by the P§3.4 table; the parent kind (survivor copy, builder copy, young YLOS,
     builder YLOS) selects the column. Spine runs (6-P§3.7) claim Eden and HandBuilders cells
     only; a tail in Hand, Retire or NotMine ends the run and is classified.
  6. **Close.** LAB tails become fillers (6-P§3.4). Merge worker state in worker-index order:
     `H_m`, `S_m` and `class_count` for the fill extent, stats, logs. `x[fill].surv_top` =
     `tospace_top_`, `bld_lo` = `bld_bottom_`, `obj_bytes`, `bld_bytes`.
  7. **Epilogue:**
     - `S_m = x[fill].obj_bytes + x[fill].bld_bytes`, the survived object bytes;
     - growth (P§3.8), then the eden allotment (P§3.8);
     - retire `x[retire]`: clear `lb_bodies` and `ylos_gen`; validate builds poison
       `[base, surv_top)` and `[bld_lo, base + capacity)` with 0xDD (the extent stays unused for
       the whole epoch in every build);
     - zero or flip eden (P§3.8);
     - `ring_.endMinor()`; bump reset; census record of Fresh and Tenuring (P§3.19); stats;
       `sweepNurseryLargeBodies(minor_color_)`; `validateYoungLarge`; TV2 on the new Tenuring
       extent (validate).
- **`evacuateR(w, slot)`**: phase 6's `evacuateP` with three changes:
  - the source is Eden or HandBuilders (both claimable: the mutator is stopped);
  - it **never promotes**: every Eden object has age 0, and so does every HandBuilders object
    (F4, P§3.9);
  - the destination is chosen by the header saved at the claim: `builder` → `bld_bottom_.fetch_sub(size)`
    (builder area, age stays 0); otherwise `labAllocate` in the fill (age becomes 1, color
    White). The copy's size class is added to `w.class_count[sizeClass(size)]`. A copy whose size
    has no class aborts (P§3.13). A `Large*Header` copy appends its body to `x[fill].lb_bodies`
    (per-worker list, merged) and calls `markLargeBodySeen` through phase 6's deferred `lb_seen`
    list.
- **Why the pause never promotes.** Every promotion now happens in a tenure job, and the only
  in-place promotion is YLOS at the merge. So region mode does not need phase 6's `PromoCtx` in
  the pause, except for the parallel tenure engine (P§3.11).

### 3.6 What is recorded: the start set and the heal list

| list | contents | produced by | consumed by |
|---|---|---|---|
| `S_m` | Hand targets from root slots, builder copies and builder YLOS slots; Hand targets of generation-(m−1) YLOS reached by the pause (P§3.14) | minor m (roots, drain) | job m (start entries) |
| `H_m` | addresses of slots, in Fill survivor copies and in young non-builder YLOS scanned in place at minor m, whose target is in Hand | minor m (drain, YLOS scans) | job m reads `*s` as start entries (read-only; P1 keeps `*s` stable); the merge at minor m+1 heals `*s` |

- Recording is a range test on the slot's value, with **no header load**: the report's §7.4.2
  step 2.
- **Completeness of the start set.** An object of `G_{m-1}` that the mutator can reach during
  epoch m was reachable at minor m. Paths into Hand at minor m start from roots, builders, Fill
  copies, YLOS objects or Hand itself, all of which the table covers. Old objects never point into
  the nursery (HEAP_005), and `G_{m-2}` pointers were resolved or healed. So "live at minor m" =
  "reachable from `S_m ∪ *H_m` through Hand", and job m promotes exactly that set. It is legacy's
  promoted set at minor m (P§1 rule 2).
- **No nepotism** (HB 9.11). Every source in S and H is live at minor m: a root, or a slot of an
  object copied or reached in this minor. That is why k = 1 needs no liveness mark and k > 1 does
  (P§12).
- **Sizes.** Step 0 item 3 measures `|H|` and `|S|` per minor on the legacy nursery (the slots of
  age-0 copies whose target is an age-1 object, and the root slots with such a target). They set
  the heal cost (E10) and the parallel-heal threshold.

### 3.7 Why three survivor extents suffice (the retention argument)

At the end of minor m, nothing points into Retire (`G_{m-2}`):
- **roots** into it were resolved in step 3;
- **Fill copies' slots** into it were resolved in step 5;
- **`G_{m-1}` objects' slots** into it were in `H_{m-1}` and healed at the merge;
- **YLOS slots** into it were either healed (in `H_{m-1}`), resolved when scanned this minor, or
  resolved at the merge's in-place promotion;
- **builders** were copied this minor and their slots resolved;
- **old objects** never point into the nursery (HEAP_005). Job m−1's copies point only at copies,
  old objects and generation-(m−2) YLOS, and those YLOS were promoted in place at the merge;
- **eden** is empty after evacuation.

So Retire is unreferenced and is reclaimed in constant time (HB 8.2). The live young objects are
in Fresh, Tenuring and YLOS: three survivor extents plus eden, the report's bound. TV10 asserts at
every minor that the fill extent was Free, and E7 confirms the peak.

### 3.8 Eden allotment, growth and zeroing (object bytes)

Region mode reproduces legacy's trigger and growth **exactly**, because legacy's to-space
occupancy after minor m is the same quantity as region mode's `S_m`: the object bytes survived at
minor m, builders included and fillers excluded.

| user | legacy (after phase 6) | region mode |
|---|---|---|
| eden start | `bump_.ptr = survivor_end` (survivors form the prefix) | `bump_.ptr = eden base` (survivors are in the fill; builders in its top area) |
| `computeAllocEnd` | `base + threshold + filler_bytes_`, fail-soft when `obj ≥ threshold` | `eden_base + (threshold − S_m)`; fail-soft when `S_m ≥ threshold`: `eden_base + (capacity − S_m)` |
| `failSoftUnclamp` | `fromBase() + capacity` | `eden_base + (capacity − S_m)` |
| `objectBytesAllocated()` | `bytesAllocated() − filler_bytes_` | `S_m + (bump_.ptr − eden_base)` |
| `checkAndGrow` occupancy | `(copy_ptr_ − toBase() − filler_bytes_to_) / capacity` | `S_m / capacity` |
| `isNurseryNearFull` | `objectBytesAllocated()` | `objectBytesAllocated()` |

- **No overflow.** At minor m+1 the fill receives the live part of eden (at most
  `threshold − S_m` bytes, or `capacity − S_m` fail-soft) plus the live builders carried over
  (at most `bld_bytes ≤ S_m`). The total is at most `capacity`. The phase 6 space test
  (`S + S/32 + n·lab ≤ capacity`) still decides the worker count, with S = eden object bytes +
  HandBuilders bytes.
- **Growth** extends every extent (eden, the three survivor extents, the second eden with flip)
  by the same delta through `growNurserySliceSet`, then `ensureCommitted` on each shadow, then
  `updateBounds`/`refreshCapacityCaches` as today. Occupied extents grow in place; nothing moves.
- **Zeroing.** Eden must be zero before the mutator allocates, as today's
  `clearToSpaceFreeRegion` guarantees for the new from-space.
  - Without flip: after evacuation, `memset(eden_base, 0 | 0xD8, old_bump − eden_base)` (0xD8 under
    `ECO_NURSERY_POISON=1`). This clears at most today's byte count: legacy clears
    `capacity − survivors`, and region mode clears only what the mutator dirtied, which is at
    most `threshold − S_m`.
  - With flip: the old eden is poisoned 0xDD (validate) or left alone, and the new eden (poisoned
    during the last epoch) is cleared over its `eden_dirty_hw` range.
  - Survivor extents are never zeroed: copies overwrite them from the base, fillers mark gaps, and
    nothing parses above `surv_top` or below `bld_lo`.
  - **Do not add a second full-eden memset** anywhere (trap 20). It is already 5.6 % of CPU.

### 3.9 Builders

- A builder surviving minor m is copied into the fill extent's **builder area**, bump-down from
  the extent end (`bld_bottom_.fetch_sub`), and keeps age 0 (HEAP_BUILDER_002).
- At minor m+1 that extent is Hand, and its builder area is **HandBuilders**: every pointer into
  it is evacuated like an eden pointer. A still-set builder is copied into the new fill's builder
  area. A cleared builder (the kernel finished it during epoch m) is copied into the new fill's
  survivor part with age 1, exactly what legacy does with a cleared builder in the survivor
  prefix.
- The tenure job's range is `[base, surv_top)`. It never reads the builder area.
- A survivor object with a slot into a builder area violates HEAP_BUILDER_003. The pause meets
  that only through a copy's slot (the rule table evacuates it). The tenure job aborts in every
  build when a promoted object's child is in any builder area (TV6), exactly as today's
  `in_phase3_` check does in validate builds.
- Builders never enter a Tenuring extent's survivor part, which is what lets the collector read
  that part without racing the kernels that write builders (§7.4.3).

### 3.10 The shadow forwarding table

- **Entry** (64 bits): `addr | state | (gen << 43)`:
  - bits 0–2 `state`: 0 = unvisited, 1 = BUSY (claimed, copy in flight), 2 = FWD;
  - bits 3–42: the destination's absolute address (F19; 0 when not FWD);
  - bits 43–63: `gen` (21 bits), the extent's generation at its hand-over.
- **Index:** `(obj − x.base) >> 3`. Every object start in `[base, surv_top)` has a distinct index.
  Step 0 item 9 checks whether every nursery object is ≥ 16 B; if so, `shadow_granule_log2 = 4`
  halves the shadow (lever L6, E12).
- **Generations instead of clearing.** An entry is meaningful only when its `gen` equals the
  extent's current `gen`; anything else reads as unvisited. `gen` is bumped at each hand-over, so
  retired entries never need clearing. When `gen` wraps (every 2^21 hand-overs of one extent),
  the hand-over first calls `shadow.discard` over the extent's capacity. That is a counted, rare
  pause cost.
- **Claim, copy, publish** (the phase 6 protocol on a side word, not on the header):
  ```
  tenure(obj):                                        // obj in [base, surv_top) of the tenuring extent
    e = load(Sh[i], acquire)
    loop:
      if gen(e) == g:
        if state(e) == FWD:  return addr(e)
        if state(e) == BUSY: e = waitPublished(Sh[i]); continue      // parallel engine only
      if !cas(Sh[i], e, BUSY|g<<43, acq_rel, acquire): continue
      break
    h = *getHeader(obj)                                // plain read: obj is immutable (P1)
    size = getObjectSize(obj)                          // from the object; nobody writes its header
    dst = grantAllocate(cls(size))                     // exact engine (P§3.12); or promoAllocate (parallel engine)
    memcpy(dst, obj, size); copy header: age = 0, color = White (the same fixup as today's promotion)
    if tag is Large{String,Byte}Header: job.lb_promoted.push(body)
    store(Sh[i], dst | FWD | g<<43, release)
    push(dst)                                          // scan later
    return dst
  ```
- **Readers:**
  - the job itself (acquire load; BUSY is possible only in the parallel engine);
  - the pause at minor m+1, after the join (`resolve`: a plain load is enough after the join's
    acquire; the load uses the same atomic_ref helper for TSan cleanliness);
  - the STW major rule (P§3.16).
- **The mutator never reads a shadow.** Headers of tenuring objects are never written (HEAP_006 is
  literally true; HEAP_030's inline forward check never sees a region forward: FORBID_HEAP_004).

### 3.11 The tenure job

**Inputs** (built by `tenureLaunch` at the end of minor m, owned by the job until the merge at
minor m+1):

```cpp
struct TenureJob {
    enum class State : uint8_t { None, Built, Running, Done, Merged };
    State state = State::None;
    int x = -1;                                 // the Tenuring extent (G_{m-1})
    char* base; char* surv_top; uint32_t gen;   // the object range and shadow generation
    uint64_t* shadow;                           // x's shadow data pointer (never moves)
    std::vector<void*>    starts;               // S_m (moved in)
    std::vector<HPointer*> heal;                // H_m (moved in; read-only here, healed at the merge)
    YlosSnapshot ylos;                          // generation-(m-1) YLOS: sorted {obj, end}, reached[] (P§3.14)
    TenureGrant grant;                          // P§3.12 (exact engine only)
    // resumable engine state (exact engine)
    size_t next_start = 0, next_heal = 0;
    std::vector<void*> stack;                   // copies to scan (LIFO)
    // outputs
    std::vector<HPointer> lb_promoted;
    TenureStats st;                             // tenured count/bytes per tag, Custom arity buckets, ylos reached, busy_ns
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    std::vector<void*> promoted_log;
    std::vector<void*> cycle_alloc_log;         // IM4
#endif
    std::atomic<bool> stop{false};
};
```

**The exact engine** (`tenureDrainSerial(job, env)` in `TenureWork.hpp`, template on an Env).
It is used by the collector (mode 2), by mode 1 when `tenure_sync_threads == 1`, and by help
when `tenure_help_threads == 1`.

```
while true:
  if stop.load(relaxed): return Stopped             // only at an item boundary
  if !stack.empty():   scanCopy(stack.pop()); continue
  if next_start < starts.size():  tenure(starts[next_start++]); continue
  if next_heal < heal.size():     v = *heal[next_heal++]; tenure(target of v); continue
  if ylos.pending():   scanYlos(ylos.popPending()); continue
  return Done

scanCopy(c):   for each child slot s of c (the scanObject arms, P§2 F21):
    t = *s; classify t (job-private copies of the ranges; no mutator state is read):
      in [base, surv_top)            -> *s = tenure(t)                    // spine runs: see below
      in the ylos snapshot           -> if !reached[t]: reached[t] = 1; ylos.pushPending(t)
      anything else in this heap's nursery block
                                     -> abort "tenure: promoted object has a young child" (every build; TV6)
      otherwise (old, permanent, constant, a YLOS object outside the snapshot)
                                     -> nothing; a young YLOS outside the snapshot is caught by TV6 at the merge (validate)
scanYlos(y):   read-only: for each child slot of y: t in [base, surv_top) -> tenure(t) (the slot is NOT written); t a snapshot member -> as above
```

- **Order is deterministic and resumable.** All state lives in the job. `stop` is honoured only
  between items, and a restart continues with the same item sequence. So a job stopped at any
  point and finished on another thread produces the same copies at the same addresses as an
  uninterrupted run. That is what makes mode 2 exactly equal to mode 1 (P§3.18), tested by
  `testTenureStopResumeSameLayout`.
- **Spines.** When a copy is a Cons whose tail is an unvisited tenuring Cons, the tail spine is
  tenured in a run: claim, copy, publish cell by cell, then one heads pass over the run's copies
  counting cells (phase 6's `spineRun`, parameterised on the claim-word locator). This preserves
  the hybrid-DFS contiguity of promoted lists (worth 8.1 s, F8 of 6-P§2).
- **The child walk** is the nursery's per-tag arm set, factored out of phase 6's `scanEntryP`
  into `NurseryChildWalk.hpp` as `forEachChildSlot(obj, f)`. The pause drain, the tenure engine
  and TV2 share it. Legacy `scanObject` is not touched.
- **What the engine reads:** tenuring objects, `*heal[i]` (slots of Fresh objects and generation
  YLOS objects), YLOS objects in the snapshot, its own copies. All are immutable or private.
- **What it writes:** shadow entries, its copies, its grant's cells and bitmap bytes and cursor
  state, its job-private state. Nothing else (rule 4).

**The parallel engine** (`TenureEnv` for `markwork::runMarkerLoop`; pause only). It is used by
mode 1 with `tenure_sync_threads > 1` and by help with `tenure_help_threads > 1`.
- Entries: `objEntry(copy, 0)` for a copy to scan; `objEntry(target, 2)` for a start or heal
  target to tenure; `objEntry(y, 3)` for a YLOS scan.
- `tenure` uses the full claim protocol (BUSY waits via `waitPublished`, 6-P§3.3).
- Allocation: `beginParallelPromotion(n)` / `allocatePromotion` / `endParallelPromotion` (phase
  6's `PromoCtx` and `promo_mu_` ladder), legal because the mutator is stopped. Any unused grant
  is returned first (`returnTenureGrant`), and any copies the exact engine already made stay
  where they are.
- The job's remaining serial state (stack, `next_start`, `next_heal`, YLOS pending) is
  distributed round-robin into the n workers' deques before the gang starts.
- Placement is schedule-dependent (layout class). The promoted set is not.
- Its old-gen byte accounting lands at `endParallelPromotion`, in the pause that runs it, not at
  the next merge. That is a decision-class difference, allowed at n > 1 (P§3.18). The job-level
  outputs (bodies, YLOS, heal, tenured stats) still merge at the next `tenureJoin`.

### 3.12 The promotion grant (`OldGenSpace`)

The collector allocates without touching anything the mutator's old-gen allocation touches.

- **New block state** `kAllocTenure = 3`: owned by one tenure job, from grant to merge.
- **`TenureGrant`**:
  ```cpp
  struct TenureCursor { BlockId block; char* base; uint8_t* bits; uint32_t next_cell, num_cells,
                        cell_bytes, stride_bits; uint64_t pending_live, pending_allocs; };
  struct TenureGrant {
      std::vector<BlockId> blocks[NUM_SIZE_CLASSES];   // in grant order
      uint32_t next[NUM_SIZE_CLASSES];                 // index of the block the cursor holds
      TenureCursor cur[NUM_SIZE_CLASSES];
      uint64_t allocated_bytes = 0, old_alloc_total = 0;   // deltas, merged at the merge
      BitmapAllocStats bm; uint64_t hist[...];            // shares, merged
  };
  ```
- **`grantTenure(const uint32_t count[NUM_SIZE_CLASSES], TenureGrant& g)`**, in the pause, under
  IM16's `DecisionScope`. For each class c with `count[c] > 0`, in class order, collect blocks
  until their free cells are at least `count[c]`:
  1. blocks popped from the **front** of `partial_[c]` (skipping non-Queued entries, as
     `refillCursor` does); free cells = `cellsIn(b) − popcount(bitmap)`;
  2. then **virgin blocks**, created exactly as `startVirginBlock` creates them but without
     `setCursor` (a factored `materializeVirginBlock(c)`).

  Every granted block gets `alloc_state = kAllocTenure`. A `TenureCursor` caches `start`, cell
  size, `mark_.slot(id)` and cell count, so the collector never reads `blocks_` or the page
  index.
  - **W6 is kept:** reuse before virgin, and nothing above the reuse rung.
  - **IM13 is kept:** mid-cycle, `partial_` holds only post-t0 blocks (F10) and virgin blocks are
    post-t0. The grant is built after the cycle decision (P§3.5), so a grant made at a t0 pause
    already follows the mid-cycle rule. `grantTenure` asserts `!isT0Block(id)` for every block
    while a cycle is active (the IM13 extension, TV5).
  - **Sufficiency:** `count[c]` counts every survivor object of class c in the extent, live or
    not, so the exact engine can never run out. Running out aborts in every build (it means the
    histogram is wrong).
- **`grantAllocate(g, cls)`**: phase 2's `cursorAllocate` body on `g.cur[cls]` (next clear bit,
  set it with a plain store, zero header; mid-cycle the set bit is the mark, allocate-black),
  `pending_live += cell`, `g.allocated_bytes += cell`, `g.old_alloc_total += cell`. On exhaustion,
  `g.cur[cls]` takes `g.blocks[cls][++g.next[cls]]`.
- **`returnTenureGrant(g)`** at the merge, in class then grant order:
  - flush each used cursor's `pending_live` into `meta.live_bytes`, and its stats into
    `alloc_stats_.bm`;
  - each block with a free cell goes back to the **front** of `partial_[c]` (phase 6's
    `requeueFront`, in reverse grant order, so the first-granted block is served first) with
    state Queued; full blocks become None;
  - `allocated_bytes += g.allocated_bytes`, `old_alloc_total_ += g.old_alloc_total`, histogram
    shares;
  - TV5: no `kAllocTenure` block remains.
- **The skip rule** (trap 4). A granted block has `live_bytes == 0` in `meta` until the merge,
  because the collector's pending counts are private. Every path that selects blocks by
  `live_bytes`, `fully_swept` or `alloc_state` for release, reclaim, demotion, the large flip,
  compaction or cursor refill must **skip** `kAllocTenure` blocks. Detaching them is not enough:
  the collector would keep writing.
  - F11's `maybeShrinkCapacity` light pass runs outside pauses, so without the rule it would
    release a block while the collector fills it.
  - Step 0 item 8 lists every such path. D4 adds the skip and a test for each.
  - `detachFromAllocation` aborts in every build on a `kAllocTenure` block.
- **Accounting timing.** The job's bytes enter `allocated_bytes` and `old_alloc_total_` at the
  merge (minor m+1), whereas legacy adds its promotions at minor m. P̂ and the triggers therefore
  see promotion one minor later in region mode, in modes 1 and 2 alike. Legacy vs region is
  decision class (judged by E7); mode 1 vs mode 2 stays exact.

### 3.13 Size classes: the region-mode nursery cap

The grant covers only size classes. So in region mode **no nursery object may lack a size class**:
- `placeLargeFor`'s nursery cap becomes `min(capacity / divisor, max_size,
  classToSize(num_size_classes_ − 1))`: 64 KiB by default. Pointer-bearing objects above it go
  to YLOS (F9). Pointer-free large objects are split-header or born old already.
- Step 0 item 6 audits every nursery allocation path that can exceed the largest class without
  going through `placeLargeFor` (kernel direct allocations, closure-group regions whose members
  are small, `allocArrayBuilder`, JSON chunking). Each is either proven below the cap or routed
  through `placeLargeFor`.
- `evacuateR` aborts in every build on a copy whose size has no class, naming the tag and size.
  The cap makes this unreachable.
- **Cost.** 4b's E1 found YLOS losing to the nursery below ~800 KB. Objects between 64 and
  128 KiB move to YLOS. The self-compile makes no large pointer allocations (TG4b); E8 checks the
  stress suite.

### 3.14 Large bodies and young large objects by generation

**Split-header bodies (HEAP_026, H-body).**
- When a `Large*Header` is copied into the fill at minor m, its body goes into
  `x[fill].lb_bodies` and is marked seen (as today).
- At minor m+1 that extent is Hand. Its headers are not scanned by the pause, so step 4 of
  P§3.5 **re-marks** every body in `x[hand].lb_bodies` with this minor's color. The minor-(m+1)
  sweep therefore keeps them.
- Job m+1 promotes the live headers and logs their bodies in `job.lb_promoted`.
- The merge at minor m+2 calls `promoteLargeHeader` for each, **before** that minor's sweep.
- Bodies of dead headers in the retired extent are not re-marked at m+2, so the m+2 sweep frees
  them.
- A body shared by several headers stays alive while any owner re-marks it: the same rule as
  today's color, per owner.

**Young large objects (HEAP_062)** keep legacy's decision, "promote in place at the first minor
that reaches it with age 1", with the decision's execution delayed by one minor:
- **First reach** at minor m (age 0): `reachYoungLargeR` colors it, sets age 1, scans it in place
  (the P§3.4 YLOS column), and appends it to `x[fill].ylos_gen`. It is now a **generation-m
  member**.
- **Hand-over** at minor m+1: every generation-m member is recolored (P§3.5 step 4). The job gets
  a sorted snapshot `{obj, end}` of them and a `reached[]` byte per entry.
  - If the pause reaches a generation-m member at minor m+1 (from roots, builders, copies or
    another YLOS), `reachYoungLargeR` sets `reached` and scans it **read-only**: Hand targets go
    to S, and its Retire targets were already healed at the merge. It is not promoted yet.
  - The job reaches members through tenuring objects (bounding box, then binary search in the
    snapshot), sets `reached` and scans them read-only (P§3.11).
- **Merge** at minor m+2: every reached member is promoted in place and scanned; its children in
  the tenured extent are resolved (P§3.5 merge step 4). Unreached members are not recolored and
  the m+2 sweep frees them (deferred during a cycle, as today).
- **Equivalence.** Legacy promotes at minor m+1 exactly the members that are live at m+1. Region
  mode's reached set is "reached by the pause at m+1, or through `G_m` from `S_{m+1} ∪ *H_{m+1}`",
  which is the same set. Stats attribute the promotion to the hand-over minor (P§3.20).
- **Builder YLOS** are scanned in place at every reach (builder column), never enter a generation,
  and join one at the first reach after the kernel clears the bit.
- **The job never touches `large_body_index_`** (an `unordered_map` the mutator mutates during the
  epoch): it uses only its private snapshot.

### 3.15 Tenure modes: sync (7b) and concurrent (7c)

**`tenureLaunch(oldgen)`** (end of minor m, P§3.5):
1. If there is no Tenuring extent (minor 1), return.
2. Build job m: `x`, range, `gen = ++x.gen` (discard on wrap), `starts = move(S_m)`,
   `heal = H_m` (the list is kept for the merge), the YLOS snapshot, the stats reset.
3. **Mode 1:**
   - `tenure_sync_threads == 1`: build the grant from `x.class_count`, run `tenureDrainSerial` to
     `Done` on the mutator, state Done;
   - `tenure_sync_threads > 1`: no grant; run the parallel engine on `GCMarkGang` (P§3.11),
     state Done.
4. **Mode 2:** build the grant, state Running, `collector_->launch(tenureEntry, &job, &job.stop)`.
   The gang's launch mutex publishes every pause write the job reads (the extent's contents, the
   shadow gen, the lists, the grant).

In **both** modes the job's outputs are merged only at the next `tenureJoin`. Mode 1 must not
merge early, or its accumulators would reach readers during the epoch that mode 2's do not
(trap 3).

**`tenureJoin(oldgen)`** (start of minor m+1, start of a STW major, heap teardown):
1. State None or Merged: return.
2. State Running:
   - `tenure_help == 0` (wait): `collector_->join()`; wait time into `tenure_wait_ns`.
   - `tenure_help == 1`: if `collector_->finishedApprox()`, `join()`. Otherwise
     `collector_->stopAndJoin()` (the job returns at its next item boundary: one object copy or
     one spine run), then finish in the pause:
     - `tenure_help_threads == 1`: `tenureDrainSerial` on the mutator with the job's own grant
       (exact);
     - `> 1`: return the grant, then run the parallel engine on `GCMarkGang`.

     Help time goes into `tenure_help_ns`, the worker count into `tenure_help_workers`.
   - A job that the fork hook stopped, or that a child process inherited, is finished the same
     way (it is not Done).
3. The merge (P§3.5). State Merged.

**`TenureCollector`** = one `GCBackgroundGang` per heap (`Options{members = 1, priority =
tenure_priority, jitter_us = ECO_GC_HELPER_JITTER_US}`), created at the first mode-2 launch,
owned by `NurserySpace`. Thread name `eco-tenure-%u`.
- Separate from 5c's marker gang, because tenure jobs run every epoch and must not queue behind a
  mark episode.
- **Priority 0 by default.** 5c's trap: under co-runners a low-priority background thread turned a
  bounded wait into a 1–9 s pause.
- **Fork:** `stopAllForFork` stops the job at an item boundary. The parent's next minor finishes
  it (help). The child has no threads, and its next minor finishes the inherited job the same way
  (state Running with no gang → treat as stopped).
- **Exit:** `stopAllAtExit` (5c) covers the thread. Before the exit stats banner is printed, and
  in `~NurserySpace`, the last job is stopped or joined, finished on the calling thread if it is
  not Done, and given a **stats-only merge** (tenured counts and the grant's return, no heal), so
  run totals include it (P§3.18).

**Why not "the mutator helps as an extra member of a running collector".** 5c's joinable episode
needs deques on the collector side and a mixed termination; stop-and-continue needs neither and
keeps the exact engine exact. Help is rare by construction when the GC ratio holds (E4). If E4
shows frequent help, lever L3 (P§9) revisits this.

### 3.16 Interaction with mark cycles and STW majors

| concern | answer |
|---|---|
| promotions during a cycle must be allocate-black | job m is built after the cycle decision (P§3.5). Mid-cycle its grant holds only post-t0 blocks, and `grantAllocate`'s bit set is the mark. The parallel engine uses phase 6's allocate-black paths |
| the t0 snapshot must cover everything reachable at t0 | `startMarkCycle` replaces `forEachSurvivor` with **`forEachYoung(f)`**: every object (fillers skipped) in the Fresh extent's survivor part and builder area and in the Tenuring extent's survivor part, then YLOS as today. The Tenuring objects are young at t0 and are promoted after t0 (black), and their old children are greyed here. Dead Tenuring objects' children are greyed too: one generation of floating garbage, conservative and safe. **Correction (2026-09-30, CR-017, plans/threaded-gc-register-fixes.md §5.2): NOT safe when a STW major ran since the dead object's last minor: the major traces young objects from roots only, so it frees a dead object's old child, and the walk then greys a freed cell (floating garbage, IM4/IM6 aborts, a marker scanning a reallocated YLOS: S1). Fixed by HEAP_074: a region-mode STW major zaps every Young extent's survivor it did not reach.** IM7 becomes "eden is empty" (`bump_.ptr == eden_base`) |
| the Retire extent at t0 | resolved and retired in the same minor, before the cycle step. No marker ever sees it |
| a background marker (5c) reaching a young object | impossible: pre-t0 old objects never point young (HEAP_005); job copies are old and point only to old objects and copies (generation YLOS are promoted at the merge); mid-cycle copies are black and never scanned. TV8 adds a validate-only check that a background `testAndSetMark` never lands in a `kAllocTenure` block |
| the handoff and tail at minor m | job m−1 was joined and merged at this minor's start, so no job runs during the tail. The next grant is built after the tail |
| a STW major between minors m and m+1 | `majorGC` calls `tenureJoin` first (the job completes and merges, including the heal). The legacy STW mark traverses young objects through `nursery_visited_`; **in region mode, `greyObject` of a Tenuring object whose job is Merged greys the copy its shadow names instead** (the copy is the object the heap will hold after the next minor's resolution). A Tenuring object reached without FWD while its job is Merged aborts (TV1). Roots still hold originals until the next minor resolves them, which is correct |
| a STW major inside minor m (a trigger with incremental marking off) | it runs after the nursery minor and before the scope-exit launch, so the Tenuring extent's job is not built yet: its objects are traversed as young, like today's survivor prefix. The launch follows the major |
| `finishMarkCycleNow(Join)` inside `majorGC` | runs after `tenureJoin` |
| compaction | refused in region mode: `scheduleCompaction` returns without effect (it has no production caller, F17), and TV9 asserts `compact_phase_ == Idle` at every hand-over |
| `sweepNurseryLargeBodies` during a cycle | defers frees as today; the re-marking of P§3.14 is unchanged |

### 3.17 The collector's footprint (shared-state audit)

This extends the template of 6-P§3.11 and 5c-P§3.6. Step 0 re-derives every row with its grep.
**Anything the collector touches that is not in this table is a bug.**

| # | location | who else touches it during the epoch | rule |
|---|---|---|---|
| T1 | tenuring objects `[base, surv_top)` | the mutator reads (P1: nobody writes) | collector reads only |
| T2 | slots `*heal[i]` in Fresh objects and generation YLOS | the mutator reads | collector reads only; the heal writes them at the next merge |
| T3 | generation-YLOS objects | the mutator reads; the pause recolors at the minor only | collector reads only; `reached[]` is the job's private array |
| T4 | the tenuring extent's shadow | nobody (the pause reads it after the join) | claim CAS / release store (acquire load) |
| T5 | granted blocks: cells, bitmap bytes, `TenureCursor` | nobody: `kAllocTenure` is skipped by every selection path; background markers never touch post-t0 blocks | owner-only; distinct blocks never share a bitmap word (F11 of 6-P§2: each block's bitmap is its own 64-byte-aligned arena slot), and with L3 the members' 64-cell-multiple chunks own whole 64-bit words, the unit the scans read (CR-022) |
| T6 | `blocks_`, page index, `partial_`, free lists, `unassigned_blocks_`, sweep state, `large_body_index_`, `alloc_stats_`, `allocated_bytes`, `old_alloc_total_` | the mutator (allocation, lazy sweep, shrink) | **never touched by the collector**; the grant caches what it needs; deltas merge at the join |
| T7 | job-private state (stack, lists, stats, logs) | nobody | owner-only; published by the join |
| T8 | eden, the Fresh extent's builder area, roots, off-heap stores | the mutator writes | never touched by the collector |
| T9 | `Allocator` / heap globals (`g_heap_base`, config) | read-only after init | read-only |
| T10 | helper-pool jobs (decommit / populate) | helpers | unchanged; they never target a granted block (released blocks only) |
| T11 | 5c background markers | markers | disjoint (P§3.16) |

### 3.18 Determinism contract

| class | examples | legacy vs region (any n) | mode 1 vs mode 2 at (n = 1, exact engine) | mode 1 vs mode 2 at n > 1 |
|---|---|---|---|---|
| object | minors; objects allocated; survived and tenured counts and bytes per tag (tenured shifted one minor); YLOS promoted in place and freed (shifted); Custom arity buckets; growth events; final capacity; `alloc_end_capped` = 0 | **identical** | identical | identical |
| region | `|S|`, `|H|`, grant blocks and cells per class, t0 young-walk objects and bytes, shadow wraps, heal slots, resolved references | n/a | identical | identical |
| layout | old-gen committed, blocks, virgin blocks, refills, placement, per-block live, `allocated_bytes`, P̂, peak, RSS | differs (judged by E7) | **identical** | differs (E7) |
| decision | majors, their reasons and the minor at which each fires, per-cycle units | differs (tenured bytes enter P̂ one minor later; E7) | **identical** | differs (E7) |
| progress | wait / help / stop counts, busy and wait ns, utilization | n/a | not compared, never a decision input | same |

- **Why the object class matches legacy.** A minor's work depends only on the mutator's
  allocation sequence, reachability, ages, and the object-byte trigger and growth rule (P§3.8).
  Region mode's promoted set at hand-over m is legacy's promoted set at minor m (P§3.6). Majors
  neither move, age nor free young objects. The t0 walk only reads.
- **Why mode 2 equals mode 1 exactly at n = 1.** Job m's inputs are fixed in the pause. The
  exact engine's item order is a function of those inputs and is preserved across stops
  (P§3.11). The grant is fixed in the pause and its blocks are invisible to the mutator. The
  outputs merge at the same point in both modes. The mutator's own old-gen allocation during the
  epoch does not depend on the job, because it uses disjoint blocks and reads no job state.
- **The one-minor shift.** Legacy counts a promotion in the minor that performs it. Region mode
  performs it in the epoch after the hand-over minor and records it in the next minor's row (the
  merge). `benchmarks/tg7-compare.py` aligns region row m+1 `tenured*` with legacy row m
  `promoted*`, and totals after the exit merge.
- **GC_DET_001 amendment:** see P§8.

### 3.19 Validators and negative controls

| id | check | where | build |
|---|---|---|---|
| TV1 | every `resolve` (heal, roots, drain, YLOS promotion, STW major rule) finds FWD with the current gen | at each lookup | **every build** (a miss is a use-after-free in waiting) |
| TV2 | hand-over closure: every child of every object in the new Tenuring extent's survivor part is in that part, old, permanent, a constant, or a YLOS of generation ≤ m−1 | epilogue, after `endMinor` | validate |
| TV3 | no BUSY left, and FWD count = the job's tenured count (exactly once) | merge | validate |
| TV4 | tenured bytes = Σ sizes of FWD entries' objects; the promoted log's sizes match | merge | validate |
| TV5 | grant discipline: every `kAllocTenure` block is in the live grant; none after the merge; no t0 block granted mid-cycle; `detachFromAllocation` never sees one | grant, merge, detach | every build (detach), validate (the rest) |
| TV6 | a promoted object (job copy or in-place YLOS) never has a young child after the merge (legacy V2 extended) | engine (every build) and merge (validate) | every build / validate |
| TV7 | stale pointers: `debugAssertValidNurseryPointer` in region form. Mutator phase: legal = eden `[base, bump)`, Fresh `[base, surv_top)` ∪ `[bld_lo, end)`, Tenuring `[base, surv_top)`. In a minor also Hand, Retire and Fill's written parts. Fillers are never a legal target. Poison 0xDD on retired survivor extents (Free for one epoch) and on the flipped-out eden | resolve / kernels / barrier | validate |
| TV8 | a background marker never marks inside a `kAllocTenure` block; the collector never writes outside T4/T5/T7 (checked by address range in `grantAllocate` and the claim helpers) | marker, engine | validate |
| TV9 | `compact_phase_ == Idle` at every hand-over; `promotion_age == 1`; no nursery copy without a size class | hand-over, config, copy | every build |
| TV10 | ring: the fill extent was Free; at most three survivor extents are non-Free; eden's `bump_.ptr == eden_base` after a minor (IM7) | `beginMinor`/`endMinor` | every build (cheap) |
| TV11 | P1 in region form: detector N records every object of Fresh and Tenuring at minor end and re-hashes both at the next `tenureJoin`, **before the heal**; detector O records the job's promoted log at the merge | census builds, validate | census / validate |

The legacy validators run unchanged in legacy mode. In region mode, the epilogue's STALE CHILD
walk covers the Fill extent, and the OLD-GEN→NURSERY walk treats the Tenuring extent as nursery
(both from `roleOf`).

**Negative controls** (test hooks, written only while no minor or job runs):
- `test_tenure_skip_start_every_`: the engine skips every k-th start entry. TV1 must fire at the
  next merge or minor.
- `test_heal_skip_one_`: the merge skips one heal slot. TV7 or TV1 must fire when the slot is read
  after retirement (the poisoned Free extent in validate builds).
- `test_no_body_remark_`: step 4 skips the body re-mark. The merge must abort when a
  `lb_promoted` body is no longer in the index (a check added for this).
- `test_grant_t0_block_`: the grant takes a t0 block mid-cycle. TV5 must fire.
- `test_shrink_ignores_tenure_`: the skip rule is disabled for one shrink pass. TV5 (detach) or
  TV8 must fire.
- `test_tenure_force_stop_after_`: the collector stops after k items (a determinism probe; not a
  failure). E2 and `testTenureStopResumeSameLayout` use it.

### 3.20 Stats, event log and reports

- **`MinorGCRecord`**, new fields (zero in legacy mode): `region`, `merge_ns`, `heal_slots`,
  `heal_ns`, `tenure_wait_ns`, `tenure_help_ns`, `tenure_help_workers`, `tenure_late`,
  `tenured`, `tenured_bytes`, `tenure_busy_ns` (the merged job's on-thread time),
  `ylos_gen_promoted`, `ylos_gen_freed`, `lb_promoted`, `starts`, `heal_recorded`,
  `resolved_refs`, `grant_blocks`, `grant_cells`, `grant_used_cells`, `fill_obj_bytes`,
  `bld_bytes`, `eden_clear_ns`, `epoch_ns` (mutator time since the previous minor's end).
- **Event log:** append these columns to the minor row, and extend
  `benchmarks/gc-event-log-summary.py`. `benchmarks/tg7-compare.py` does the E1 and E2
  comparisons (P§3.18) from two event logs and banners.
- **`RegionStats`** banner block "Region nursery / tenuring" (printed when region mode ran):
  totals of the above; collector CPU (the gang's `member_cpu_ns`); **utilization** = Σ
  `tenure_busy_ns` / Σ `epoch_ns`, and its per-minor p50/p99/max; late minors; stops; shadow
  wraps; nursery RSS estimate = eden capacity + Σ survivor high-water + Σ shadow committed.
- **Pauses, MMU and interference** come from the existing machinery (5c-P§3.13). The collector's
  CPU is excluded from mutator CPU as 5c's markers are.

### 3.21 Configuration

| field / env | default | meaning |
|---|---|---|
| `nursery_regions` / `ECO_NURSERY_REGIONS` (0/1) | **0** until Step 12 decides | 1 = region nursery (requires `old_gen_bitmap_alloc`, `promotion_age == 1`, the phase 6 engine) |
| `nursery_region_eden_flip` / `ECO_NURSERY_EDEN_FLIP` (−1/0/1) | −1 = on in validate builds, off otherwise | two alternating edens (n = 5), P§3.2 |
| `tenure_mode` / `ECO_TENURE_MODE` (1/2) | **1** until Step 12 decides | 1 = sync (7b), 2 = concurrent (7c) |
| `tenure_sync_threads` (0/1/…) | 1 | mode 1: 1 = exact engine; 0 = the minor's worker count (parallel engine) |
| `tenure_help` (0/1) | 1 | on a late job: 0 = wait; 1 = stop and finish in the pause |
| `tenure_help_threads` (0/1/…) | 0 (the minor's worker count) until E4 | 1 = exact continuation |
| `tenure_priority` | 0 | the collector thread's priority (0 inherit, 1..19 nice, 20 SCHED_IDLE) |
| `heal_parallel_min` | 65,536 slots (E10) | heal on the gang above this many slots |
| `shadow_granule_log2` (3/4) | 3 (Step 0 item 9, E12) | shadow index granule |

- Every field goes into `HeapConfig`, `HeapConfig::validate`, `HeapConfigJson` (keys, parse,
  validate), with env parsing copied from `ECO_GC_MINOR_THREADS` (6-P§3.14). Env wins over JSON.
- `validate()`: region mode with `promotion_age != 1`, with bitmap allocation off, or with
  `nurseryRegionBytes() < n·X` is an error with an actionable message. `promotion_age > 1` points
  at lever P§12.
- The effective large-pointer nursery cap in region mode is clamped to the largest class
  (P§3.13), and the banner prints it.

### 3.22 Rejected alternatives

| alternative | why rejected |
|---|---|
| **The collector heals the recorded slots** (the report's 7c wording) | The heal writes Fresh objects while the mutator reads them: a data race in C++ terms, invisible to the kernels' plain loads and to compiled code except on x86 TSO; it trips detector N, and it needs release/acquire pairs the compiled code does not emit (ARM, the `mac-build` preset). The pause heal costs one load and one store per recorded slot. Step 0 sizes `|H|` and E10 measures it; if it dominates the pause, lever L2 (P§9) revisits it with atomic_ref stores and an ordering argument |
| **Forwarding in the header of a tenuring object** | FORBID_HEAP_004 / §2.4: readers check the tag and then re-read `size`/`unboxed` (the `String.length` lowering, kernels after `resolveFast`); a concurrent forward is a TOCTOU |
| **A GC-private pre-header word per survivor** (§2.4 table) | Cheaper in RSS (+8 B per object vs one word per 8 B granule), but it changes survivor layout, so the LAB/filler code, the t0 walk, the census, TV2 and every prefix walker would need a second object format. The shadow keeps survivor extents walkable exactly like today's to-space. Revisit if E7 shows shadow RSS over budget (lever L6 halves it first) |
| **Small survivor extents with in-pause promotion on overflow** (HB 4.5) | A directly promoted parent would point into the fill extent: an old → young edge that needs a remembered set, which Eco has none of (HEAP_005). Equal-capacity extents make overflow impossible for address space only |
| **Conservative YLOS promotion** (promote every generation member at the next minor) | Simpler, but it breaks the object oracle against legacy (E1) on every YLOS-heavy test. The snapshot scheme is exact and keeps the job off the index |
| **Conservative promotion of objects without a size class** | Same oracle loss; the region cap (P§3.13) removes such objects instead |
| **The collector allocates through `promo_mu_`** (6-P§9 forward note) | The mutator allocates in the old gen during the epoch (bodies, YLOS cells, lazy sweep, shrink). Sharing the mutex would put a lock on the mutator's paths and still leave the shrink race of F11. The grant touches nothing shared |
| **Rotating eden through the survivor extents** | It gives eden-flip poisoning for free, but every extent then becomes eden periodically and is touched up to the threshold: RSS 4 × capacity (512 MiB) vs legacy's 2 × capacity |
| **Merging a sync job immediately** | Mode 1's accumulators would reach epoch-time readers (safepoint trigger checks) that mode 2's do not; mode 1 would stop being mode 2's oracle |
| **One collector thread that also joins mark episodes** | A tenure job every epoch would queue behind seconds-long mark episodes; two gangs are cheap |

---

## 4. Steps

Every step ends with `cmake --build build --target check` green (C++-only steps), or `full` where
the step says so. Steps 1–11 also build the validate tree's `test` target and run the phase's
tests there. Run tests once, tee to `/tmp/test_output.txt`, grep the file (CLAUDE.md).

**Before you start:** `benchmarks/lss-loop-snap.sh verify keep-TG6`; snapshot `try-TG7-pre`.

### Part A — 7b: survivor regions, sync tenuring

#### Step 0 — facts, baseline, censuses, audits (no code change except temporary counters)

1. Re-verify F1–F23 against `keep-TG6` and fix P§2. In particular, record phase 6's as-built
   names and whether its engine runs with n = 1 (`test_force_parallel_engine_`), and its default
   `gc_minor_threads`.
2. **Same-session baseline** with `eco-optTG6`, strictly serial on an idle machine:
   - a stats-build triple at phase 6's default N and one at N = 1: wall, GC, minor total, majors,
     peak, RSS, out.mlir md5;
   - a phase-timer run with `ECO_GC_EVENT_LOG` at each N: the minor anatomy (stack walk, roots
     per scanner, copy drain, promoted drain, promotion allocation, sweep slice, epilogue,
     `clearToSpaceFreeRegion`), per-minor survived and promoted bytes (p50/p99/max), epoch
     lengths (time between minors), and the top-10 minors with their parts.
3. **Heal and start-set census** (temporary counters in the legacy minor, removed after):
   - `h_slots`: in the to-space copy scan, slots whose target (before evacuation) is a from-space
     object with age ≥ 1 (the future H);
   - `s_roots`: root slots with such a target (the future S);
   - `y_slots`: the same from young YLOS scans.

   Per-minor p50/p99/max. These give E10's heal budget and `heal_parallel_min`.
4. **GC ratio (HB 19.4):** per minor, `promotion_ns / epoch_ns`, with promotion_ns = the promoted
   drain plus promotion allocation plus the per-promotion sweep. Record p50/p99/max at N = 1.
   This is the collector utilization the single collector must sustain.
5. **Builder census:** builder objects and bytes surviving each minor; the maximum; the share
   cleared within one epoch.
6. **Size audit** (P§3.13): list every nursery allocation site whose size can exceed
   `classToSize(num_size_classes_ − 1)`, and a census of nursery object sizes per tag above
   32 KiB on the self-compile, E2E and stress.
7. **Heap-slot census:** the maximum number of live `ThreadLocalHeap`s in unit, E2E and stress
   runs (a temporary counter in `acquireNurserySlicePair`). Apply P§3.2's rule.
8. **Block-selection audit** (P§3.12 skip rule): every reader of `live_bytes`, `fully_swept` or
   `alloc_state` that selects blocks (release, reclaim-all-dead, demotion, large flip,
   compaction, refill, shrink, the tail), and whether it can run outside a pause. Record them in
   P§10.1 with the grep. Expected: F11's shrink path is reachable from the mutator.
9. **Minimum object size** per tag (layout audit plus a census of copy sizes). If every nursery
   object is ≥ 16 B, lever L6 is available.
10. **Child walk audit:** tags that `visitHeapChildren` declines (F21), their `scanObject` arms,
    and P1 census coverage of them. The factored `forEachChildSlot` follows `scanObject`.
11. **YLOS census** on stress and the unit suite: first reaches, promotions in place and frees
    per minor.
12. **Shared-state audit:** re-derive P§3.17 T1–T11 with greps.
13. Record everything in P§10.1. **Stop and revise the plan if:**
    - item 4's p99 utilization exceeds 0.8 at N = 1 (one collector cannot keep up; lever L3 moves
      into this phase), or
    - item 3's `h_slots` p99 exceeds 30 % of survivor slots (the pause heal may cancel the gain;
      consider lever L2 before 7c), or
    - item 6 finds a nursery allocation path that cannot be routed through `placeLargeFor`.

#### Step 1 — D1: configuration and slice sets (inert when off)

1. P§3.21 fields, validation, JSON, env; `nursery_regions` is cached at initialize/reset.
2. `NurserySliceSet`, `Allocator::rebuildNurserySliceTable` in region form (n extents at a
   power-of-two stride; slot count; retained commit per extent),
   `acquire/grow/releaseNurserySliceSet`, and `dumpHeapState` lines. Legacy functions are
   untouched.
3. Shadow reservation per survivor extent (`ReservedArray<uint64_t>`), committed with capacity.
4. Tests (`test/allocator/NurseryRegionLayoutTest.cpp`):
   - `testRegionGeometry`: n = 4 and 5; bases at `slot_base + k·X`; slots = region / (n·X);
     acquisition and release reuse retained commit (Issue #40 shape);
   - `testRegionGrowAllOrNone`: a refused commit on extent 3 leaves every capacity unchanged;
   - `testRegionConfigValidation`: `promotion_age 2`, bitmap off and a region too small are
     rejected with the documented messages; the effective YLOS cap is clamped (P§3.13);
   - `testLegacyGeometryUnchanged`: with regions off, the slot table equals the pre-change table
     byte for byte.
5. **Gate:** unit, E2E, and a stats self-compile with regions off: every counter and both event
   logs identical to `eco-optTG6`.

#### Step 2 — D2: `RegionRing` and classification (no GC yet)

1. `NurseryRegions.hpp/.cpp`: `Extent`, `RegionRing`, `beginMinor`, `endMinor`, `roleOf`,
   `contains`, the between-minor role table, the eden allotment helpers (P§3.8), and the region
   form of `debugAssertValidNurseryPointer` / `isIn*AllocatedRegion` (TV7). Validate-build
   poisoning of retired survivor extents, and the eden flip. TV10.
2. `NurserySpace` holds a `RegionRing` when region mode is on. The legacy members stay and are
   used only in legacy mode.
3. Tests (`test/allocator/RegionRingTest.cpp`, driving the ring directly):
   - `testRingRotation`: 10 simulated minors; at each, the roles match P§3.3's table, including
     minors 1 and 2 (no Hand, no Retire);
   - `testRoleOfTable`: addresses at each extent's base, `surv_top − 8`, `surv_top` (Stale), the
     builder area (HandBuilders when Hand), past capacity (Stale), outside the block (NotMine);
   - `testEdenFlipQuarantine`: with n = 5, the evacuated eden is quarantined for exactly one
     epoch; at every n the retired survivor extent is Free (and poisoned in validate builds) for
     exactly one epoch; a pointer into either is Stale;
   - `testAllotmentMatchesLegacy`: the P§3.8 formulas against the legacy formulas for a table of
     `S`, threshold and capacity values, fail-soft included.

#### Step 3 — D3: `TenureWork.hpp`, the exact engine, the synthetic harness

1. `runtime/src/allocator/TenureWork.hpp`, std-only, namespace `Elm::tenurework`:
   - the entry format (`kStateBusy`, `kStateFwd`, `kGenShift = 43`, `make`, `addr`, `state`,
     `gen`);
   - `claim(atomic_ref<uint64_t>, uint64_t& observed, uint32_t gen) → bool`;
     `publish(ref, dst, gen)` (release); `waitPublished`; `lookup(ref, gen) → dst or null`;
   - `tenureDrainSerial<Env>(JobState&, Env&) → {Done, Stopped}` (P§3.11), with the Env
     supplying `inTenuring(p)`, `ylosIndex(p)`, `forEachChildSlot(obj, f)`, `sizeOf(obj)`,
     `sizeClass(size)`, `allocate(cls)`, `copyFixup(dst)`, `onPromoted(dst, size, tag)`, and
     `abortYoungChild(parent, child)`.
2. `test/gc-helper-tsan/tenure_harness.cpp`, added to that CMake project:
   - **Synthetic heap:** a "tenuring" arena of objects `{header; slot[k]}` using the real header
     layout, k = 0–8, with Cons-like chains (10,000 long), shared subgraphs and cycles; a
     synthetic old arena with per-class bump blocks as the grant; a synthetic YLOS set;
   - **Runs:** start sets from random roots plus a random heal list over a "fresh" arena; the
     exact engine, then checks: (a) the promoted set = reachable set; (b) each object copied
     exactly once; (c) every copy's slots point at copies, old or constant objects, never at the
     arena; (d) no BUSY entry; (e) payload checksums preserved; (f) with stops injected after
     every 1, 7 and 1,000 items and resumed on another thread, the copies' addresses are
     **identical** to an uninterrupted run;
   - **Concurrency:** a reader thread walks the tenuring arena and the heal slots read-only while
     the engine runs; the "pause" joins, heals and verifies. Under TSan: no report.
3. **Pass:** the harness exits 0 with no "WARNING: ThreadSanitizer", three runs, one under
   `taskset -c 0,1`.

#### Step 4 — D4: the promotion grant

1. `kAllocTenure`, `TenureGrant`, `TenureCursor`, `materializeVirginBlock` (factored out of
   `startVirginBlock`, which then calls it and `setCursor`), `grantTenure`, `grantAllocate`,
   `returnTenureGrant`, TV5, the `detachFromAllocation` abort, and the **skip rule** at every
   path Step 0 item 8 listed.
2. Tests (`test/allocator/TenureGrantTest.cpp`):
   - `testGrantCoversCounts`: random class histograms; granted free cells ≥ counts; W6 order
     (partial front first, then virgin);
   - `testGrantReturnToFront`: after a partial use, the blocks sit at the front of `partial_[c]`
     in grant order and the next `cursorAllocate` takes the first-granted one;
   - `testGrantMidCycleNoT0`: in a cycle, no t0 block is granted; the negative control
     `test_grant_t0_block_` fires TV5 (death test);
   - `testShrinkSkipsGranted`: a granted empty virgin block during a lazy-sweep completion that
     runs a light shrink is not released; the negative control fires;
   - `testGrantAccountingMerge`: `allocated_bytes` and `old_alloc_total_` after the return equal
     a run that allocated the same cells through `cursorAllocate`.
3. **Gate:** unit; regions still off in E2E (nothing calls the grant): counters identical.

#### Step 5 — D5: the region minor, sync mode, exact engine

1. `NurseryTenure.cpp`: `TenureJob`, `tenureLaunch`, `tenureJoin` (mode 1 only in this step:
   join is a no-op), the merge, the heap Env for `tenureDrainSerial`, `resolve`, the heal.
2. `minorGCRegion` (P§3.5) on the phase 6 engine: `evacuateR`, the classification in
   `scanEntryP`'s child loop, `reachYoungLargeR`, the builder area, H/S/class-count recording,
   hand-over preparation, the epilogue (allotment, growth, zeroing, retirement, `endMinor`).
3. `ThreadLocalHeap`: `tenureJoin` at the top of `minorGC` and `majorGC`; the launch scope-exit
   in `minorGC`; teardown `stopAndJoin` + stats merge. `placeLargeFor`'s region cap.
4. Large bodies and YLOS by generation (P§3.14), including the merge's in-place promotion.
5. Stats and event-log columns (P§3.20); `tg7-compare.py`.
6. Tests (`test/allocator/RegionMinorTest.cpp`, config-pinned `nursery_regions = 1`,
   `tenure_mode = 1`):
   - `testRegionEveryTagTenured`: one object of every tag with children, reachable only from a
     root, over 4 minors: survive (Fresh), hand over (Tenuring), tenured (old after the merge),
     old. Contents checked through the mutator API after each minor;
   - `testRegionHealFromFresh`: an object allocated in epoch m pointing at a `G_{m-1}` object;
     after minor m+1 its copy's slot points at the old copy (the heal), and TV1 never fires;
   - `testRegionRootResolve`: a root holding a `G_{m-1}` object across two minors ends up
     pointing at the old copy;
   - `testRegionLongListTenured`: 100,000-element lists (boxed and unboxed heads) tenured in spine
     runs; contiguity: consecutive cells' copies are adjacent in 95 % of pairs;
   - `testRegionBuilderStaysInArea`: a builder chunk chain survives 5 minors in builder areas,
     never tenured, age 0; after clear, survive then tenure;
   - `testRegionLargeBodies`: a live header tenured (body transferred at the merge), a dead one in
     a tenuring extent (body freed at the next minor), a body shared by a dead and a live header;
   - `testRegionYlosGenerations`: a YLOS array reachable (a) from a root, (b) only through a
     tenuring object, (c) not at all at hand-over; promoted in place at the merge for (a) and
     (b), freed for (c); its children in the tenuring extent are resolved;
   - `testRegionRetentionBound`: 200 minors of a random-graph script (`HeapGenerators`); TV10
     never fires; non-Free survivor extents ≤ 3 at every minor end;
   - `testRegionObjectsMatchLegacy`: the same script with regions off and on; every object-class
     counter equal, with the one-minor shift (P§3.18);
   - `testRegionStwMajorBetweenMinors`: a forced STW major right after a minor; the copies of the
     tenuring extent's live objects survive the sweep; the next minor resolves roots to them.
7. **Gate:**
   - unit;
   - `full` E2E with `ECO_NURSERY_REGIONS=1` (stats build);
   - stress (default and pressure configs) with regions on;
   - a stats self-compile with regions on at N = 1: `out.mlir` identical; **E1's object class
     identical to legacy at N = 1** (`tg7-compare.py`).

#### Step 6 — D6: mark cycles, P1 census, validators, the validate tree

1. `forEachYoung` and its use in `startMarkCycle` (P§3.16); IM7 in region form; the STW major
   rule in `greyObject` (serial path, region mode only).
2. P1 census in region form (TV11), with the check moved into `tenureJoin` before the heal.
3. TV1–TV10 wiring (every-build parts in Step 5 already), the negative controls and a death test
   for each.
4. Tests (`RegionMinorTest.cpp` / `ConcurrentMarkTest.cpp`):
   - `testRegionCycleAllocateBlack`: a 5c cycle (B = 2) across 60 region minors; IM1/IM2/IM4/IM13
     quiet; the handoff frees the same marked object count as a legacy run of the same script
     (compare marked counts, a layout-independent figure);
   - `testRegionT0CoversTenuring`: t0 at a minor whose Tenuring extent holds the only reference to
     an old object; the object is marked at the handoff (the negative control
     `test_snapshot_skip_young_walk_` makes IM1 fire).
5. **The validate tree:** unit, E2E and stress (default and pressure), regions on, mode 1, at
   `gc_minor_threads` ∈ {1, 4}, eden flip on (the validate default). Zero `[heap-validate]`
   lines. `ECO_NURSERY_POISON=1` stress quiet. The census build (`-DECO_P1_CENSUS=ON`) on a
   region-mode self-compile: 0 violations.

#### Step 7 — D7: the parallel tenure engine (pause only)

1. `TenureEnv` for `runMarkerLoop`; the entry kinds; distribution of the serial state; phase 6
   promotion buffers around it; used by `tenure_sync_threads > 1` and (Step 9) by help with
   n > 1.
2. Tests: every Step 5 test at `tenure_sync_threads` 4 and `gc_minor_threads` 4;
   `testParallelTenureObjectsEqualExact` (same script, exact vs parallel: object class equal,
   placement free).
3. **Gate:** as Step 5 at `tenure_sync_threads=0` and `gc_minor_threads=4`.

#### Step 8 — D8: 7b measurement and close-out

1. E0, E1, E3 (sync arms), E7 (region sync vs legacy), E10 (P§5).
2. Record in P§10. **7b's default stays `nursery_regions = 0`.** 7b ships as the tested reference
   for 7c. If 7c is abandoned later, E3's sync arm decides whether region sync alone is worth
   enabling (it is expected to be neutral-to-slightly-slower, P§0).
3. Snapshot `keep-TG7b`. Master-plan row 7b.

### Part B — 7c: concurrent tenuring

#### Step 9 — D9: `TenureCollector` and mode 2

1. The per-heap gang (P§3.15), `tenureEntry`, `tenureJoin` with wait / help (stop-and-finish,
   exact or parallel), the fork and exit behaviour, and `tenure_priority`.
2. Tests (`test/allocator/ConcurrentTenureTest.cpp`, config-pinned `tenure_mode = 2`):
   - `testTenureStopResumeSameLayout`: with `test_tenure_force_stop_after_` k ∈ {1, 13, 5,000}
     and help at n = 1, the old-gen placement (block ids and cell indices of every copy) equals
     mode 1's;
   - `testTenureModesAgreeOnCounters`: the random-graph script in modes 1 and 2 (n = 1, exact),
     with jitter 0 and 50 µs: every counter identical, both event logs identical in non-timing
     columns;
   - `testTenureLateHelpParallel`: a collector slowed by a test hook (sleep per item) and
     `tenure_help_threads = 4`: help runs, object counters equal mode 1's;
   - `testTenureForkChild`: fork while a job runs; the parent's and the child's next minors each
     finish it; both continue for 20 minors with TV1 quiet;
   - `testTenureExitWhileRunning`: process exit with a running job (a child process runs the
     script and exits); no crash, stats include the last job;
   - `testTenureDuringCycle`: mode 2 with a 5c cycle (B = 2) for 60 minors; IM1/IM2/IM4/IM13/TV8
     quiet.
3. **Gate:** unit; `full` E2E with `ECO_TENURE_MODE=2` and regions on; stress at mode 2.

#### Step 10 — D10: TSan

1. `tenure_harness.cpp` already runs the engine concurrently (Step 3). Add the real
   `GCBackgroundGang` launch/stop/join around it, and a storm: 10,000 jobs with random stops.
2. `test/gc-heap-tsan/heap_driver.cpp`: a mutator script of 300 region minors in mode 2, with a
   5c cycle (B = 2) across 80 of them, `gc_minor_threads` 4, under g++ TSan.
3. **Pass:** no reports, three runs, one under `taskset -c 0,1`.

#### Step 11 — D11: determinism and the validate tree in mode 2

1. E2 (P§5).
2. The validate tree in mode 2 at `gc_minor_threads` ∈ {1, 4}, plus 4 with
   `ECO_GC_HELPER_JITTER_US=50`, eden flip on: unit, E2E, stress, poison stress. Zero
   `[heap-validate]` lines.

#### Step 12 — D12: measurement and the default

E3–E9, E11, E12 (P§5). If the decision rules pass: `NURSERY_REGIONS = 1`, `TENURE_MODE = 2`, the
chosen `tenure_help_threads` and `heal_parallel_min`. Then rerun every gate default-on, and the
bootstrap fixed point.

#### Step 13 — D13: docs, invariants, tracking

- P§8's rows land in `design_docs/invariants.csv`.
- `THEORY.md` and the matching `design_docs/theory/` child: the nursery item describes eden,
  survivor extents, the ring, records and heals, the shadow and the tenure job.
- `design_docs/parallel-gc.md` §7.4: an as-built note (pause heal instead of collector heal; the
  grant; YLOS generations; the region cap).
- The master plan: rows 7b and 7c, and the §5 pause table.
- Loop entries `TG7b` and `TG7c` in `benchmarks/gc-opt-loop.md`.
- Snapshot `keep-TG7c`, `bin/eco-opt-prev` = `eco-optTG7c`.

---

## 5. Measurement and experiments

All self-compile arms follow the 5b/5c/6 method:
- one phase-timer binary, arms selected by env or `ECO_HEAP_CONFIG`;
- env values and config paths of **equal length** across arms (counters are a program input,
  TG3);
- strictly serial runs on an idle machine;
- artifacts verified by md5, never by exit code.

The default 5c configuration (background marking on) and phase 6's default `gc_minor_threads` run
throughout unless an arm says otherwise.

**E0 — inert (after Step 4).** `nursery_regions = 0` vs `eco-optTG6`: every counter and both event
logs identical (rule 1).

**E1 — the legacy oracle (after Step 6).** Regions on, mode 1, exact engine, at
`gc_minor_threads` 1 and 4, vs regions off at the same N. `tg7-compare.py`: the object class
identical with the one-minor shift; `alloc_end_capped` = 0; layout and decision deltas printed and
recorded. **Any object-class difference stops the phase.**

**E2 — determinism (after Step 11).** At `gc_minor_threads = 1`, exact engine: mode 1 vs mode 2
vs mode 2 + jitter 50 µs vs mode 2 + `test_tenure_force_stop_after_` 1,000 (a stats build that
compiles the hook): **every counter class identical**. At `gc_minor_threads = 4`: the object
and region classes identical across the same arms.

**E3 — pauses and wall.** Arms: legacy (phase 6), region mode 1, region mode 2, at N = 1 and at
phase 6's default N; one run each, a triple for the finalists. Per arm:
- minor pause p50/p99/max, all-pause p99/max, MMU at 10/20/50/100/200 ms;
- the pause anatomy: stack walk, merge (heal, YLOS, bodies), roots, drain, eden clear, epilogue,
  wait, help;
- wall, GC time, mutator CPU outside pauses, collector CPU (tenure gang and 5c gang separately).

M§'s exit criterion for 7c: the minor pause measured against phase 0's root-scan figure. Print
`roots_ns / pause_ns` per minor.

**E4 — keep-up (the GC ratio).** Mode 2 at the chosen N:
- utilization p50/p99/max, late minors (%), help time share of pause time;
- the same with a spinning co-runner on every other core, and with a memory-streaming co-runner
  (phase 0's shapes);
- `tenure_help_threads` ∈ {1, N}.

**Decision rule:** late minors ≤ 1 % idle and ≤ 10 % under co-runners, with no pause above E3's
mode-1 max. Otherwise lever L3.

**E5 — oversubscription.** `taskset -c 0,1`, mode 2 vs mode 1 at N = 2: mode 2 not more than
20 % slower in wall or minor max. A hang or collapse fails the phase.

**E6 — interference (H-L3).** Mutator CPU outside pauses, mode 2 vs mode 1 (triples). Gate: within
phase 0's co-runner estimate (+2.4 % worst, spin; −8 % memory). Record the L3 effect.

**E7 — retention and RSS.** A gf sweep (0.65 / 0.70 / 0.75) for legacy and region mode 2 (and
mode 1 once), then triples at 0.70:
- **gate on old-gen peak first** (M§2): the sweep-median peak within +3 % of legacy's, and no
  point above legacy's sweep max;
- majors within ±1 at every point;
- max RSS within +3 %; the nursery RSS estimate vs legacy's 2 × capacity (record; the shadow is
  the known cost);
- the retention bound: `RegionStats` max non-Free survivor extents = 3.

**E8 — small heap and stress.** The 4 GB-cap pressure config with regions and mode 2: E2E, stress
101/101 with ≥ 1,000 minors, the 5c E10 tight-cap self-compile (`max_heap_size 15G`). Peak as a
% of cap within +2 points of legacy.

**E9 — mutator locality.** Mutator CPU outside pauses, region mode 2 vs legacy (triples). The
collector promotes in DFS-with-spine-runs order from the start and heal lists, not in legacy's
Cheney order. More than +1 % is recorded and opens lever L4 (address order); it is not a blocker
if wall wins.

**E10 — heal and resolve cost (7b, and again in 7c).** Per minor: `heal_slots`, `heal_ns`,
`merge_ns`, `resolved_refs`; `heal_ns / pause_ns`. Choose `heal_parallel_min` (the smallest list
at which the gang heal beats serial). If the heal exceeds 20 % of the mode-2 pause at p50,
record lever L2 as the next candidate.

**E11 — robustness.** Fork-heavy and spawn-heavy runs (the multi-heap driver and the Issue-#40
respawn test) in mode 2, 100 iterations: no failure, no leak of gang threads.

**E12 — shadow granule** (only if Step 0 item 9 allows): `shadow_granule_log2` 3 vs 4, mode 2:
RSS and pause. Choose 4 if RSS drops and nothing else moves.

**What to watch:**
- **The serial remainder.** The merge (heal), the roots and the eden clear are serial or
  memory-bound. E3 prints them separately.
- **Hot shared targets.** Many start entries naming one object make the exact engine's first
  `tenure` hit and the rest cheap lookups. Nothing to fix, but it shows in `starts` vs
  `tenured`.
- **Grant waste.** `grant_cells − grant_used_cells` per minor: the dead fraction plus block
  rounding. Blocks are returned at the merge, so this is transient, but it is visible as
  committed old gen at trigger evaluation (decision class).

---

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` | all pass with regions off, and with regions on at modes 1 and 2 (config-pinned) |
| G2 | elm-tests | the reference set (13,565 / 12) |
| G3 | `--target full` | all pass at the default, with `ECO_NURSERY_REGIONS=1 ECO_TENURE_MODE=1`, and with `ECO_NURSERY_REGIONS=1 ECO_TENURE_MODE=2` |
| G4 | stress (default and pressure) | 101/101 in each region mode at N ∈ {1, 4}; ≥ 1,000 minors on pressure |
| G5 | validate tree | zero `[heap-validate]` lines on unit, E2E and stress in both modes at N ∈ {1, 4} and 4 + jitter, eden flip on; every negative control fires; poison stress quiet; P1 census 0 violations |
| G6 | stats-off `ecoc` | builds; region mode 2 works without stats |
| G7 | E0 | rule 1 |
| G8 | E1 | rule 2 (object class vs legacy, shifted) |
| G9 | E2 | rule 3 (mode 1 = mode 2 bit for bit at (1, exact); object class at n > 1) |
| G10 | TSan | `tenure_harness` and `gc-heap-tsan` exit 0 with no warnings, including under `taskset -c 0,1` |
| G11 | E3–E12 | decision rules recorded in P§10; E4's keep-up rule and E7's retention rules pass |
| G12 | bootstrap fixed point | the default-on compiler reproduces itself; `out.mlir` byte-identical across modes and N |
| G13 | static and structural | `grep -n "hardware_concurrency" runtime/src/allocator` empty; `evacuateR`'s claim asserts, in every build, that the source role is Eden or HandBuilders (no forward is ever written into a survivor part); the collector's code (`TenureWork.hpp`, `tenureEntry`, the heap Env) reaches `OldGenSpace` only through `TenureGrant` (reviewed by grep, recorded in P§10) |

**7b is done** at G1–G8 and G12 in mode 1 (Step 8). **7c is done** at all gates with the
default decided.

---

## 7. Traps

1. **The heal is pause work.** Never "optimise" it onto the collector without lever L2's
   ordering argument. A collector store into a Fresh object is a data race with every kernel
   load, trips P1's detector N, and is unordered on ARM.
2. **`tenureLaunch` on every return path of `ThreadLocalHeap::minorGC`** (F12 has three). A
   missed launch leaves a Tenuring extent unpromoted, and TV1 fires at the next minor. Use the
   scope-exit object; never add a bare `return` before it.
3. **Mode 1 merges at the next minor, not in its own pause.** An early merge makes the epoch's
   safepoint trigger checks see bytes mode 2 hides, and E2 fails for reasons unrelated to
   concurrency.
4. **A granted block looks empty.** `live_bytes == 0` until the merge. Every block-selection path
   skips `kAllocTenure` (Step 0 item 8, Step 4). The light shrink runs **outside pauses** (F11).
   Detaching is not skipping.
5. **The collector reads no shared allocator table.** Cache block start, cell size, bitmap slot
   and cell count in `TenureCursor` at grant time. A "harmless" `blocks_.info(id)` read races the
   mutator's `blocks_.add` in TSan terms, even though phase 1 made the storage stable.
6. **Launch after the cycle decision.** A job launched before `startMarkCycle` in the same pause
   allocates white copies that the t0 snapshot cannot see (their originals are young and dropped)
   and the tail frees live objects. The scope-exit launch guarantees the order.
7. **The t0 walk covers Tenuring as well as Fresh.** Tenuring objects are young at t0 and promoted
   after it, so their old children are greyed only by the walk.
8. **H holds heap slots of objects the pause will not rescan; S holds root and builder targets.**
   Putting a root in H makes the heal write a stack slot the mutator has since reused. Leaving a
   non-builder YLOS slot out of H leaves it pointing into a retired extent.
9. **P1 census before the heal.** The heal is a legal GC write; checking after it reports every
   healed slot as a kernel write.
10. **Resolve before retiring.** The merge, the roots, the drain and the YLOS promotions all read
    Retire's shadow. Retirement (poison, `gen` bookkeeping, list clearing) is the last epilogue
    step before `endMinor`.
11. **The shadow gen is part of every read.** A stale FWD from the extent's previous use looks
    valid without it. The claim CAS compares against the observed stale word, not against zero.
12. **The fill extent is the Free one**, never the extent being retired in the same minor (whose
    shadow is still being read). With three survivor extents there is exactly one Free extent at
    minor start (TV10).
13. **Builders go to the builder area and nowhere else**, and a still-set builder is copied at
    every minor. A builder in a survivor part is read by the collector while a kernel writes it.
14. **Recolor the Hand extent's bodies and YLOS members at hand-over.** Otherwise this minor's
    sweep frees bodies and objects the job is about to promote (H-body). The negative control
    exists for this.
15. **`promoteLargeHeader` at the merge, before the sweep.** After the sweep, a transferred body
    has already been freed.
16. **The job never touches `large_body_index_`.** It is an `unordered_map` the mutator mutates
    during the epoch. Use the YLOS snapshot.
17. **The one-minor shift in tenured counts.** Compare with `tg7-compare.py`, never by eye. The
    last job merges at exit (stats only).
18. **Counters are a program input** (TG3): equal-length env values across arms (`1` vs `2`, never
    unset vs set). Unit tests ignore `ECO_GC_*` after the first init: pin configs (F23 of 6-P§2).
19. **Stop only at an item boundary** in the exact engine, and keep all state in the job. A stop
    inside a spine run must finish the run (its heads pass included) first, or the resumed order
    differs and E2 fails.
20. **One eden clear per minor.** It is already 5.6 % of CPU. The survivor extents are never
    zeroed.
21. **Region mode halves the heap slots** (8 by default). The FATAL message names both knobs;
    Step 0 item 7 decides the default region size.
22. **Never write `Tag_Forward` into a survivor extent.** HEAP_030's inline check would then see a
    mutator-visible forward that no invariant allows.
23. **`promotion_age` is 1 in region mode.** Config validation rejects anything else; ageing is
    lever P§12, not a config value.
24. **The alignment trap.** `cursorAllocate` is factored for `grantAllocate`. If allocation time
    moves with identical instructions, check the loop address first
    ([[gc-mark-loop-alignment-trap]]).
25. **Fork and exit.** A stopped or orphaned job is Running without a live gang. `tenureJoin` must
    treat "Running and `!collector_->running()`" as stopped and finish it; never wait on a gang
    that does not exist.

---

## 8. Invariants (land in Step 13)

- **HEAP_069 RegionNursery (new):** "WITH nursery_regions = 1 THE NURSERY IS AN EDEN AND THREE
  SURVIVOR EXTENTS (plans/threaded-gc-07-concurrent-tenuring.md). A heap owns n extents (4, or 5
  with eden flip) of one capacity, contiguous at a power-of-two stride in its slot block. Minor m
  evacuates eden completely: non-builders into the Free survivor extent (which becomes Fresh,
  holding G_m, age 1), builders into that extent's top-down builder area (age 0). References into
  the Fresh extent of the previous minor (now Hand, G_{m-1}) are recorded without a header load:
  root and builder targets in the start set S_m, slots of survivor copies and of young non-builder
  YLOS objects in the heal list H_m. References into the Tenuring extent of the previous minor
  (now Retire, G_{m-2}, whose live objects the tenure job promoted) are resolved through that
  extent's shadow, and H_{m-1} is healed at the minor's start; Retire is then unreferenced and
  becomes Free. At most three survivor extents are non-Free. Eden's allotment is threshold minus
  the object bytes survived at the previous minor (fail-soft capacity minus them), which makes
  every trigger, growth decision and object counter equal the legacy nursery's; a fill cannot
  overflow. Every nursery object has a size class (the region cap on large pointer objects).
  promotion_age must be 1. nursery_regions = 0 is the legacy nursery unchanged."
- **HEAP_070 TenureJob (new):** "THE LIVE OBJECTS OF THE TENURING EXTENT ARE PROMOTED BY A TENURE
  JOB (plans/threaded-gc-07-concurrent-tenuring.md), built at the end of the hand-over minor
  after the cycle decision and merged at the start of the next minor (or of a STW major). It
  promotes exactly the objects reachable from S_m ∪ *H_m through the extent, recording forwarding
  in the extent's shadow (addr | state | gen, claim by CAS, publish with release), and allocates
  only from a promotion grant: uniform blocks in state kAllocTenure, sized in the pause from the
  extent's per-class object counts, which no allocator path may select, detach or release until
  the merge returns them to the front of partial_. tenure_mode 1 runs it inside the pause;
  tenure_mode 2 on the heap's tenure collector (a GCBackgroundGang), which writes only the
  shadow, its grant's blocks and its private state. A late job is waited for or stopped and
  finished in the pause; the single-threaded engine is resumable with an order that does not
  depend on where it stopped. Large-header body transfers and in-place YLOS promotions of the
  generation are applied at the merge."
- **FORBID_HEAP_004 NoConcurrentWriteToPublished (new; report §11.2, broadened):** "NO COLLECTOR
  THREAD WRITES AN OBJECT HEADER OR FIELD THAT THE MUTATOR CAN READ. Concurrent forwarding lives
  off-header (the survivor-extent shadow, HEAP_070); healing of recorded slots happens in a pause.
  A collector thread writes only memory no mutator path can reach until a later pause publishes
  it."
- **HEAP_005 (amended):** "… the young generation is the nursery (eden and the survivor extents
  in region mode) plus YLOS. A tenure job's copies may point at YLOS objects of the tenured
  generation until the merge promotes them in place; no mutator can reach those copies before the
  merge."
- **HEAP_006 (amended):** "… in region mode forwarding for survivor extents lives in the shadow
  and header forwards exist only on eden and builder-area objects inside the minor pause; HEAP_030
  remains an exception for stop-the-world forwarding only."
- **HEAP_007 (amended):** "… threaded-gc-07 (HEAP_070): the per-heap tenure collector runs outside
  pauses and writes only its tenuring extent's shadow, its promotion grant's blocks and its job
  state."
- **HEAP_026 (amended):** "… in region mode a body's owner is the survivor extent holding its
  header; the bodies of the Hand extent are re-marked at hand-over, transfers happen at the merge,
  and bodies of dead headers are freed at the minor that retires their extent."
- **HEAP_042 (amended):** "… region mode: n extents per slot (HEAP_069); one capacity for all."
- **HEAP_054 (amended):** "… kAllocTenure blocks are owned by one tenure job from grant to merge
  (HEAP_070)."
- **HEAP_062 (amended):** "… in region mode a YLOS object first reached at minor m joins
  generation m; at hand-over it is recolored and snapshotted for the job; it is promoted in place
  at the merge if the pause reached it at the hand-over minor or the job reached it through the
  generation, and freed otherwise. The job never reads the body index."
- **HEAP_063 (amended):** "… in region mode the t0 young walk covers the Fresh extent (survivors
  and builders) and the Tenuring extent, then YLOS; the tenure job is built after the cycle
  decision, so its copies are allocate-black mid-cycle; a STW major joins the tenure job first and
  greys the copy of every forwarded Tenuring object it reaches."
- **HEAP_068 (amended):** "… in region mode eden's allotment and growth count the object bytes
  survived at the previous minor (survivor copies plus builders)."
- **HEAP_SNAPSHOT_001 (amended):** "… the heal of recorded slots and the recoloring at hand-over
  are GC writes during a collection; the tenure collector writes no published object (FORBID_HEAP_004)."
- **HEAP_BUILDER_001 (amended):** "… in region mode builders live in builder areas and are copied
  at every minor; a survivor object never points into a builder area (HEAP_BUILDER_003)."
- **GC_DET_001 (amended):** "threaded-gc-07 (HEAP_069/070): the tenure job's inputs (start set,
  heal list, grant, YLOS snapshot) are fixed in the hand-over pause and its outputs merge at the
  next pause in both tenure modes. Collector progress (finishedApprox) may decide only whether the
  pause waits or helps and with how many workers. With gc_minor_threads = 1 and the exact engine,
  tenure_mode 1 and 2 are bit-identical in every counter, placement and decision, under
  ECO_GC_HELPER_JITTER_US and forced stops. Against the legacy nursery every object counter is
  identical (tenured counts one minor later); old-gen placement and the major sequence may differ
  and are judged by distribution."

---

## 9. Forward notes and other levers

- **Lever L2 — concurrent heal.** If E10 shows the heal above 20 % of the mode-2 pause, move it to
  the collector with `std::atomic_ref<uint64_t>` release stores. That requires: an argument that
  every mutator read of a Fresh slot is either a plain 64-bit aligned load (x86/ARM single-copy
  atomic) followed by a dependent load (address dependency orders it on ARM); detector N
  excluding healed slots; TSan suppressions limited to that store; and a new FORBID_HEAP_004
  exception. Not before E10's data.
- **Lever L3 — more than one collector thread** (B > 1). The parallel engine exists (P§3.11) but is
  pause-only because it uses `promo_mu_`. For B > 1 outside a pause, split the grant per member
  with slack of (B − 1) blocks per class, give each member a deque, and use 5c's
  Member/stop/relaunch roles. Placement becomes layout class. Triggered by E4 failing.
- **Lever L4 — promotion in address order** (HB 4.9, the handbook discussion). Two passes in the
  job: mark live through the shadow (state MARKED), then copy in address order, preserving the
  eden → fill order (itself DFS with spine runs). Triggered by E9 > +1 %.
- **Lever L5 — en-masse tenuring** (§7.3): copy the whole survivor part without a trace. It trades
  about 9 % tenured garbage for no start set and no claims. Phase 6's P§3.16 records the premise;
  it breaks rule 2's oracle and needs its own retention gate.
- **Lever L6 — 16-byte shadow granule** (E12).
- **RC-1 in-place reuse** (§12.1) stays compatible only for objects that have never survived a
  GC. In region mode that is exactly eden. Record this in `plans/opt-tier3-rc-runtime.md` when
  either track moves.
- **Phase 8:** the merge heal, the root phase (CellStore) and the eden clear are the serial
  remainder after 7c. A helper-thread eden clear (zero the next eden during the epoch, with eden
  flip in production at the cost of one extent of RSS) is the obvious item if E3 shows the clear
  in the worst pauses.

---

## 10. As-built deviations

Implemented 2026-09-27 against `keep-TG6` (snapshot `try-TG7-pre` before any change; work in
progress `try-TG7-wip1`, `try-TG7-wip2`). New sources: `NurseryRegions.hpp`,
`NurseryRegion.cpp` (the ring, the region minor, TV2/TV7), `NurseryTenure.cpp` (the job, the
merge, the collector, the parallel engines), `TenureWork.hpp` (std-only shadow protocol and the
exact engine), `NurseryChildWalk.hpp`, `OldGenTenure.cpp` (the grant). Tests:
`RegionMinorTest.cpp`, `ConcurrentTenureTest.cpp`, `TenureGrantTest.cpp`,
`test/gc-helper-tsan/tenure_harness.cpp`, region scenarios in `test/gc-heap-tsan/heap_driver.cpp`.
Measurement tools: `benchmarks/tg7-compare.py` (E1/E2), `benchmarks/tg7-summary.py` (one row per
run).

**Measurement binaries.** Lowering the self-compile MLIR takes ~15 minutes, so most arms use one
object file (`eco-boot-native --emit=obj ecoTG6base.mlir`) relinked against each runtime build
in ~1 s. **A relinked binary's object counters differ slightly from an exe-lowered binary's**
(E0 below): 77 more objects allocated, first difference at minor 7. The lowering, not the runtime,
is the difference; comparisons are therefore always between arms of ONE binary, and E0 uses an
exe-lowered binary against the exe-lowered `eco-optTG6PT`.

### 10.1 Step 0 facts, censuses and audits

- **F1–F23 re-verified** against `keep-TG6` while building (names as in P§2; line numbers moved).
  Phase 6's engine runs at n = 1 (`test_force_parallel_engine_`); its default is auto, cap 8.
- **Item 3 (heal and start sets), measured in region mode** rather than with temporary legacy
  counters (the region minor records exactly these lists): heal list p50 47, p99 24,958, max
  67,277 slots per minor; start set p50 0, p99 45,851, max 63,204; heal list / survivors p50 1.7 %,
  **p99 25 %** (the 30 % stop rule holds); pause heal p50 1.8 µs, p99 240 µs, max 0.83 ms.
- **Item 4 (GC ratio): the stop rule fired.** Collector busy time / epoch per job: p50 0.036, p99
  0.69–0.98, max 0.99 (mode 2, N = 8). Jobs are bimodal: most tenure ~14 K objects, ~16 % tenure
  ~2 M objects (p50 45 ms of collector time) against a ~46 ms epoch. Per the rule, **lever L3 (B
  > 1 collector threads) moved into this phase** (`tenure_collector_threads`, P§10.20).
- **Item 5 (builders):** at most 1,464 builder bytes survive a self-compile minor (p50 0).
- **Item 6 (size audit):** the default `large_object_threshold` (8 KiB) gives 37 size classes, so
  the largest class is **8 KiB, not 64 KiB** (P§3.13 assumed 40 classes). Every nursery path was
  audited: `ThreadLocalHeap::allocate` / `allocateSlow` place objects ≥ LOT (the region cap now
  clamps to the largest class); `allocateSlowRaw` and `ensureNursery` are bounded far below;
  closure-group regions hold small objects; `allocateFast` callers include
  `eco_alloc_string_fast` with an unbounded length (no codegen caller), so `allocateFast` refuses
  requests above the region cap in region mode (their slow paths place them). `validate()`
  requires `large_object_threshold` ≤ the largest class + 8 in region mode.
- **Item 7 (heap slots):** 8 region slots at the default 4 GiB region (5 × 128 MiB with eden flip
  = 6). No unit, E2E or stress suite needed more (E2E and stress fork one heap per child); the
  default region size is unchanged. The E11 spawn storm exposed that a destroyed heap's old-gen
  blocks are never returned to the allocator (pre-existing), not a slot shortage.
- **Item 8 (block-selection audit)** — readers that select blocks by `live_bytes`, `fully_swept`
  or `alloc_state`, all now skip `kAllocTenure`: `maybeShrinkCapacity` passes 1 and 2 (the light
  pass runs outside pauses via `lazySweep` → `onSweepComplete`), `allocateFromEmptyRegularBlocks`
  (reachable from the mutator through `allocateLargeBlock`), `reclaimAllDeadBlocksFromMeta`,
  `classifyBlocksAfterMark` (queueing), `selectEvacuationSet`. `detachFromAllocation`,
  `freeUniformCell` and `resetAllocCursors` abort on one in every build; validate builds abort
  when the mutator cursor, a mid-cycle allocation (`initObjectHeaderWithSize`) or a marker
  (`testAndSetMark`, TV8) touches one. **A second hazard the audit did not predict:**
  `classifyBlocksAfterMark` queues any uniform block with free cells that is not Queued — including
  the mutator's own Current cursor block. The grant took it, and the collector and the mutator
  then allocated in one block (found by the E2 unit test as a flaky placement difference). The
  grant now skips the mutator's cursor block.
- **Item 9 (minimum object size):** 0 survivor copies under 16 B on the self-compile (a counter in
  the region banner), so a 16-byte shadow granule (L6) is admissible there; a 16-byte granule
  aborts in every build on a smaller survivor.
- **Items 10, 12:** `forEachChildSlot` (`NurseryChildWalk.hpp`) follows phase 6's `scanEntryP`
  arms; T1–T11 hold as written, plus the L3 members' worker slots and grant cursors (T7).

### 10.2 E0 — inert

`nursery_regions = 0` against `eco-optTG6PT`, both exe-lowered, N = 1: **every counter and all
1,924 per-minor rows identical, decisions included** (`tg6-compare.py --all`: MATCH). The
relinked binary differs from both by lowering only (see above).

### 10.3 E1 — the legacy oracle

Same binary, N = 1, legacy vs region mode 1: **run totals (objects allocated, survived,
promoted, minors, growth, maximum nursery size, bytes) and all 1,924 per-minor rows identical**,
promoted compared with the one-minor shift (`tg7-compare.py e1`: MATCH). The decision class
happened to match too (8 majors, same triggers). At N = 4: see below.

### 10.5 E2 — determinism

N = 1, exact engine, mode 1 vs mode 2 vs mode 2 + jitter 50 µs vs mode 2 + a forced stop after
1,000 items: **every counter class identical** — objects, region columns, grant blocks and cells
per minor, the major sequence, the banner's retention sections (`tg7-compare.py e2 --exact` and
`tg6-compare.py --all`: MATCH). The mode 2 arms had 313–321 late jobs finished by the exact
continuation in the next pause.

### 10.13 E10 — heal cost

See 10.1 item 3: the heal is at most 0.83 ms (p99 0.24 ms). `heal_parallel_min` stays 65,536:
only a heal list of that length pays for waking the gang, and the self-compile's largest is
67,277.

### 10.14 E11 — robustness

`testTenureRespawnAndForkStorm`: 100 heaps spawned on fresh threads (mode 2, two collector
threads, each exiting with a job in flight) and 100 forks with a running job: no failure, no
leaked threads. It found that the grant could fail near the old-gen cap (the spawned heaps' old
gens are never returned to the allocator, so 100 of them fill the reservation): **the grant now
falls back** — the job is run in that pause on the parallel engine, whose promotion ladder is the
legacy one (`grant_fallbacks` in the banner). At the cap itself the legacy ladder's rung-7
assertion (found, not fixed, in phase 6) is reached, as it is in legacy mode.

E1 and E2 at N = 4 (same binary, object and region classes): legacy vs mode 1 MATCH on every
per-minor row (shifted) and on the run totals, the decision class happened to match too (8
majors); mode 1 vs mode 2, + jitter 50, + forced stop 1,000: object and region classes identical.

### 10.4 7b measurement (region sync) and the 7b close-out

All arms below: one phase-timer binary relinked from one object (`eco-optTG7PT2`), N = 8
(phase 6's default), gf 0.70 through `ECO_HEAP_CONFIG` in every arm, equal-length environment
values, strictly serial, output md5 933c3ff0d288 in every run (the fixed point). Triple medians:

| arm | wall s | pause p99 / max ms | minor-only max ms | pauses total s | mutator CPU outside pauses s | old-gen peak MB | max RSS GB |
|---|---|---|---|---|---|---|---|
| legacy (phase 6 default) | 123.2 | 34.4 / 137.2 | 109.0 | 12.9 | 109.8 | 11,432 | 12.43 |
| region, mode 1 (7b) | 135.9 | 113.9 / 143.6 | 141.1 | 36.7 | 98.7 | 11,837 | 13.27 |
| region, mode 2, B = 1 (7c) | **112.8** | 30.1 / **87.5** | 67.2 | 11.1 | 101.1 | 11,931 | 13.37 |
| region, mode 2, B = 4 (L3) | 120.3 | 21.6 / 123.7 | 71.6 | 9.7 | 110.0 | 12,028 | 13.47 |

7b as predicted costs pause time (the job runs in the hand-over pause: +24 s of pauses, p99
114 ms) and is not a candidate default by itself. Two results were not predicted:

- **The region nursery makes the mutator faster:** mutator CPU outside pauses 98.7 s vs 109.8 s
  (−10 %; at N = 1 97.7 vs 112.1 s, −13 %). Eden is one extent reused at the same addresses
  every minor, and survivors live in their own extents instead of forming the prefix the mutator
  allocates behind. This is most of 7c's wall gain.
- **Old-gen retention follows promotion order again** (phase 6's E7 finding): at N = 1 the region
  peak is 11,578 MB vs legacy's 9,251 MB; at N = 8 both are depth-first and differ by +3.5 % at gf
  0.70. Breadth-first tenure order (`tenure_fifo_order`) does not help: 11,902 vs 11,931 MB at N = 8,
  11,549 vs 11,578 at N = 1, and it is 3–5 % slower. It stays off.

7b's default stays `nursery_regions = 0` (P§4 Step 8). Snapshot `keep-TG7b` is the tree as
finally gated (7b and 7c ship together; there was no separate 7b tree).

### 10.6 E3 — pauses and wall

See the table in 10.4 (N = 8) and, at N = 1 (single runs): legacy 160.4 s (pause p99 113.4,
max 182.9 ms), mode 2 136.3 s (126.9 / 157.6 ms). At N = 8 mode 2 cuts wall by 8.4 %, the
worst pause by 36 % (137 → 88 ms), the minor-only worst by 38 %, total pause time by 14 %. The
remaining pause: the merge (p50 42 µs, p99 9.5 ms: the heal is ≤ 0.83 ms, the rest is help of late
jobs), the roots and the eden → fill copy. Pause anatomy of mode 2 (N = 8, `gc-event-log-summary.py`
section (a), 9.9 s of minor pauses): eden → fill drain 68 %, the merge including help of late
jobs 19 % (merge p50 0.04 ms, p99 9.8 ms), roots 8.4 % (`roots_ns / pause_ns` per minor is in the
event logs, `tg7runs/e3-*.events.tsv`), stack walk 1.8 %, pre-drain sweep 2.3 %.

### 10.7 E4 — keep-up (the GC ratio): FAILED at B = 1

| arm | late minors (of 1,924) |
|---|---|
| mode 2, B = 1, idle | 312–342 (16–18 %) |
| mode 2, B = 1, 12 spinning co-runners | 348 (18 %) |
| mode 2, B = 1, one memory-streaming co-runner | 331 (17 %) |
| mode 2, B = 4, idle / spin / memory | 1–2 / 1 / 2 (≤ 0.1 %) |

Jobs are bimodal: ~16 % tenure ~2 M objects in ~45 ms against a ~46 ms epoch, so one collector
cannot keep up at those minors whatever its priority. The exact engine is memory-latency bound
(81 % of `tenure()` is one shadow-word miss); software prefetch, a 2 MiB-granule shadow and a
16-byte granule did not move it. A late job is stopped and finished by the minor's gang in the
next pause (p50 6 ms); `tenure_help_threads = 1` instead raises the pause p99 from 30 to 75 ms,
so help stays on the minor's worker count. **B = 4 passes E4** (lever L3, built in this phase).
Four 576 MB memory co-runners oversubscribed the 15 GB machine (multi-second pauses in every
arm, legacy included); the table uses one co-runner, as phase 0 did.

### 10.8 E5 — oversubscription (`taskset -c 0,1`, N = 2)

Mode 1 150.3 s (minor max 155 ms), mode 2 130.7 s (123 ms), mode 2 B = 4 139.5 s (129 ms): no
collapse, mode 2 faster than mode 1. Pass.

### 10.9 E6 — interference: B = 1 passes, B = 4 fails

Mutator CPU outside pauses vs mode 1 (98.7 s, triples): mode 2 B = 1 101.1 s (+2.4 %, at the
limit), B = 4 110.0 s (+11.4 %, fail). Four collectors burn 47 s of CPU (B = 1: 20 s) and the
mutator pays for the memory traffic; the parallel engine's per-object cost is ~2× the exact
engine's (a CAS per claim, stealing, and shared shadow lines).

### 10.10 E7 — retention: FAILED on the per-point rule

gf sweep, N = 8, one run per point (old-gen peak MB, majors):

| gf | legacy | mode 2, B = 1 |
|---|---|---|
| 0.65 | 10,193 (8) | 9,529 (8) |
| 0.70 | 11,450 (8) | 11,882 (8) |
| 0.75 | 9,471 (7) | 9,544 (7) |

Sweep median −6.4 % (limit +3 %: pass); majors identical at every point (pass); max RSS sweep
median −2.8 % (pass). **The gf 0.70 point is 3.8 % above legacy's sweep maximum** (triples:
11,931 vs 11,432 MB, +4.4 %), which the rule forbids. At 0.70 max RSS is +7.6 % (13.37 vs 12.43
GB): the nursery's own footprint is ~520 MB larger (eden 128 MB + survivor high-water 263 MB +
shadow ~260 MB touched, vs 256 MB legacy). The retention bound held in every run: at most two
survivor extents in use between minors.

### 10.11 E8 — tight cap (`max_heap_size` 15G)

Legacy peak 9,647 MB (85.6 % of the cap, 9 majors), mode 2 9,446 MB (83.9 %, 8 majors): −1.7
points (limit +2). Stress 101/101 with 8,604 region minors on the pressure config and 1,090 on the
pressure-parallel config, in both modes (P§10.16). Pass.

### 10.12 E9 — mutator locality

Mode 2's mutator CPU outside pauses is 8 % below legacy's (101.1 vs 109.8 s): the collector's
depth-first promotion order does not hurt the mutator; the region nursery helps it (10.4).

### 10.15 E12 — shadow granule

0 survivors under 16 B on the self-compile, so `shadow_granule_log2 = 4` is admissible: max RSS
−80 MB (13.24 vs 13.32 GB, one run each), collector time unchanged. It stays 3 (the 16-byte
granule aborts on an 8-byte survivor, which other programs may have); it is the first lever for
region mode's RSS.

### 10.16 Gates

| # | Gate | Result |
|---|---|---|
| G1 | unit | default tree 1,931/1,931 (regions off, region tests config-pinned in modes 1 and 2, B = 1/2/4, FIFO) |
| G2 | elm-tests | P§10.18 |
| G3 | `full` / E2E | E2E 942/942 with `ECO_NURSERY_REGIONS=1` in modes 1 and 2, default and GC-pressure configs; `full` in P§10.18 |
| G4 | stress | 101/101 in both modes at N = 1 and 4 on the pressure (8,604 region minors) and pressure-parallel (1,090) configs |
| G5 | validate tree | unit 1,932/1,932; E2E 942/942 and stress 101/101 on every arm (modes 1/2, N = 1/4, jitter 50, B = 4, FIFO, poison); the only `[heap-validate]` lines are phase 6's three negative controls and the skipped-heal control (TV2), all required to fire; P1 census build on a region self-compile: 1.49 billion survivor checks, 0 violations (N, O and W) |
| G6 | stats-off | `eco-optTG7NS` self-compiles in region mode 2, output identical |
| G7 | E0 | MATCH, every class (exe-lowered binaries) |
| G8 | E1 | MATCH at N = 1 and N = 4 (object class; decisions matched too) |
| G9 | E2 | MATCH, every class at N = 1 (mode 1 / 2 / jitter / forced stop); object + region classes at N = 4 |
| G10 | TSan | `gc-tenure-tsan` (stop/resume identity, a concurrent reader, a 10,000-job storm on the real gang) and `gc-heap-tsan` (region mode 2 with B = 1 and B = 4, 5c cycles, 4 minor workers): PASS, 0 warnings across 6 heap runs (1 on 2 CPUs) and 3 tenure runs after two validate-only fixes, P§10.18 item 10 |
| G11 | E3–E12 | recorded above: **E4 fails at B = 1, E6 fails at B = 4, E7 fails its per-point rule** |
| G12 | fixed point | every run reproduced `out.mlir` 933c3ff0d288 |
| G13 | static | no `hardware_concurrency` in the allocator; `evacuateR` copies only Eden / HandBuilders objects (every other role records, resolves or aborts); the collector reaches `OldGenSpace` only through `grantAllocate` / `grantAllocateShared` (the pause-only engine uses `allocatePromotion`) |

### 10.17 The default: `nursery_regions = 0` (decision rules not met)

No configuration passes every decision rule: B = 1 fails E4 (16–18 % late jobs; the rule is 1 %
idle, 10 % under co-runners) and E7's per-point rule; B = 4 passes E4 but fails E6 (+11 %
mutator CPU) and E7. Per P§11 the phase closes with the default left at
`nursery_regions = 0`, `tenure_mode = 1`, `tenure_collector_threads = 1`. The measured best
configuration for an override is **`nursery_regions = 1`, `tenure_mode = 2`,
`tenure_collector_threads = 1`**: wall −8.4 % (123.2 → 112.8 s), worst pause −36 % (137 → 88
ms), pause p99 34 → 30 ms, total pause −14 %; costs: old-gen peak +4.4 % and max RSS +7.6 % at gf
0.70 (sweep medians −6.4 % / −2.8 %), 20 s of collector CPU, and 17 % of minors helping a late
job. `ECO_NURSERY_REGIONS=1 ECO_TENURE_MODE=2` enables it.

**Addendum (2026-09-28, TG7d): the user made that configuration the default**, overriding E4's
keep-up rule as phase 6 overrode its retention gate. The flip needed three changes:
- **`nursery_regions = 2` (auto), the new default.** It resolves when the Allocator adopts a config
  (`HeapConfig::resolveNurseryRegions`, before `validate`): regions when the config meets the
  region requirements (`regionIncompatibility()`: `promotion_age = 1`, bitmap allocation, a size
  class for every nursery object, room for one heap slot), the legacy nursery otherwise. An
  explicit `1` still throws on an incompatible config, and `ECO_NURSERY_REGIONS` accepts `2`.
  Without auto, every config with `promotion_age > 1`, bitmap allocation off or a small heap
  (17 unit tests) failed validation.
- **`tenure_mode = 2`** (one collector is already the default).
- **Unit tests pin the legacy nursery.** 58 tests assert legacy timing (promotion at the first
  minor, semi-space shapes), so `initAllocator` sets `nursery_regions = 0`; the region tests use
  `initRegionAllocator`, which takes their config as given. E2E, stress and the self-compile run
  the new default. `gc-heap-tsan`'s legacy scenarios pin `0` for the same reason.
The loop entry is TG7d in `benchmarks/gc-opt-loop.md`.

### 10.18 Design deviations

1. **Lever L3 was built in this phase** (`tenure_collector_threads`), as the Step 0 rule required:
   B members run 5b's marker loop over their own worker slots and allocate from the grant by
   claiming chunks with a CAS on a per-class word (block index << 32 | chunk). Chunks own ≥ 1,024
   bitmap bits: 64-cell chunks of small classes put up to eight members' chunks in one bitmap cache
   line, and the bit-set traffic made the allocator 77 % stalled on one load (fixed; B = 4 went
   from 23 % to 0.1 % late). Every chunk is a multiple of 64 cells, so it owns whole 64-bit
   bitmap words, and that (not whole bytes) is what keeps members apart: the scans
   (`bitscan::nextFreeCell`, `nextSetBit`) read a whole word with a plain load
   (`bitscan::loadWord`), so a chunk of 8 cells would race (CR-022). A stop leaves the unscanned work in the deques (5c's semantics) and
   help drains it in the next pause on the minor's gang; the grant carries one chunk of slack per
   participant. B = 1 remains the exact engine.
2. **The exact engine publishes without a claim**: it is the only writer while it runs (help
   starts after a join), so it skips the CAS.
3. **The grant skips the mutator's cursor block** (10.1 item 8) and **falls back** to the in-pause
   parallel engine when the old gen cannot supply virgin blocks (10.14).
4. **A merge at a STW major is final**: the next minor's join finds the job Merged and does not
   merge again, and the P1 census check runs at whichever join merges. `majorRedirect` greys a
   copy only while the merged job's extent is still Tenuring (a STW major inside the hand-over
   minor, before the launch, traverses that extent as young).
5. **One pause engine for help and sync with n > 1** uses phase 6's `PromoCtx`; the concurrent L3
   engine uses the grant. Both share `TenureParEnv`.
6. **Stats:** `promoted` columns of region rows carry the tenured counts of the job merged at that
   minor (the one-minor shift), and run totals include the last job via a stats-only merge before
   the exit banner (`Allocator::finishTenureForExit`, and in `cleanupThread`).
7. **Region tests are config-pinned** (as phase 6); in-process E2E heaps take the environment at
   their first initialize, and E2E / stress run in forked children, so `ECO_NURSERY_REGIONS=1`
   reaches them.
8. **The collector threads are named `eco-tenure-N`** (a `GCBackgroundGang` name option).
9. **Test infrastructure fix:** `allocateHeapGraphInOldGen` built 0-field Customs, which the
   validate mark rejects (HEAP_044); seed-dependent, pre-existing. Padded as the nursery generator
   already did.
10. **Heap TSan found two validate-only defects** (fixed 2026-09-28; the release binary is
    unaffected, since both are under `ECO_HEAP_VALIDATE`):
    - *A race this phase introduced:* `validateOldGenMetadata` V8 (called from
      `maybeShrinkCapacity`) and `validateCycleUniformLive` IM6 read the bitmaps of `kAllocTenure`
      blocks while the collector's `grantAllocate` set bits. That reported a false
      `popcount != live_bytes` failure (1 run in 3). Both validators now skip granted blocks: their
      bits belong to the collector until the merge folds in the live bytes (HEAP_070).
    - *A SEGV that predates this phase* (keep-TG6's driver fails 1 run in 4): the legacy
      post-minor old-gen→nursery walk parsed MIXED blocks by header. With bitmap allocation,
      the cursor fills a gap and leaves the gap's tail headerless (HEAP_056), so the walk entered a
      dead 10 KB string's payload and decoded a 1.7 GB size. The walk now visits only set start
      bits in mixed blocks too, stepping 8 bytes otherwise; HEAP_024 is amended.
    After the fixes: `gc-heap-tsan` 5 runs plus 1 under `taskset -c 0,1`, all rc 0 with 0
    warnings; `gc-tenure-tsan` 3 runs (one on 2 CPUs) with 0 warnings; validate unit 1939/1939;
    validate stress 101/101 in the legacy, mode 2 and mode 2 B = 4 arms.

---

## 11. Done means

- **7b:** Steps 0–8 complete; G1–G8 and G12 pass with regions on in mode 1; E1's object class is
  identical to legacy; `keep-TG7b` exists; the 7b master-plan row is written.
- **7c:** every gate G1–G13 passes with the default decided, or the phase is closed with the reason
  recorded and the default left at `nursery_regions = 0`; E2 is exact; E4's keep-up rule and E7's
  retention rules hold; P§8's invariants, `THEORY.md`, the master-plan rows and the §5 pause table,
  and loop entries `TG7b`/`TG7c` are written; `keep-TG7c` and `bin/eco-opt-prev` = `eco-optTG7c`
  exist.
- Lever L1 (P§12) is **not** part of done.

---

## 12. Separate lever L1: tenure age k > 1 (in-place ageing)

**Not part of this phase.** Build it only after 7c is default-on and the go/no-go below passes.
**Built 2026-09-28 in `plans/threaded-gc-07b-tenure-ageing.md`** (with two design changes: the
mark derives the heal list from live holders, so no per-target H lists are kept across minors, and
the merge zaps dead ageing objects so no walker reads a dangling slot).

### 12.1 What it would do

With k = 1 an object is tenured if it is live at its second minor. With age k it would be tenured
if live at its (k+1)-th minor, having **aged in place**: it stays in the survivor extent it was
copied into and is never copied again. That keeps HB 9.5's benefit of ageing (fewer short-lived
objects tenured) without the in-pause re-copy that made legacy's `promotion_age = 2` lose
(2026-09-22: age 2 → 1 halved survivor copies, −17.7 s).

### 12.2 Design delta from P§3

- **Extents.** During a minor the live survivor extents are the fill, k − 1 ageing extents, the
  Hand extent and the Retire extent: **k + 2 survivor extents**, so n = k + 3 (k + 4 with eden flip).
  k = 2 → 4 survivor extents; k = 3 → 5. `n·X` per heap slot, so heap slots fall to
  `region / ((k+3)·X)`.
- **Recording.** A reference into *any* non-fill live extent is recorded, keyed by target
  extent: `H[j]` and `S[j]` for each ageing extent j. The rule table gains a column per ageing
  role, still with no header load: one `roleOf`, as now.
- **Liveness needs a mark (nepotism, HB 9.11).** At the hand-over of extent `G_j` (minor j + k),
  the slots in `H[j]` were recorded over k minors, and many of their holders (objects of
  `G_{j+1} … G_{j+k-1}`) are dead by then. Treating them as roots would tenure young garbage.
  The job therefore first **marks** from this minor's roots and root-like slots through the
  ageing extents (read-only; they are immutable) into `G_j`, using a side mark bitmap per
  extent, and only then promotes the marked objects of `G_j`. Each object is traced about k times
  over its life, off the mutator.
- **Heal.** The slots in `H[j]` whose holders are live are healed at the next merge. Dead holders'
  slots are skipped (the mark says which).
- **Builders** are unchanged: always copied, never ageing. A survivor object pointing into a builder
  area is still a violation.
- **YLOS generations** gain the same k-step lifetime: first reach at minor j, promotion in place at
  the merge after the hand-over of generation j.
- **Headers.** `age` stays 1 on every survivor copy; the extent is the age. The pause may write
  the age at hand-over only if a validator needs it (a GC write during a collection).
- **Legacy oracle.** With legacy `promotion_age = k`, region mode k must match legacy's tenured
  counts shifted by one minor. Its **survived** counts are *lower* by design (no re-copies), so
  the oracle compares tenured counts, allocated counts and minors only.

### 12.3 Costs

- **RSS:** one more survivor extent's high-water and shadow per extra year of age, plus a mark
  bitmap per ageing extent (1 bit per 8 B granule).
- **Collector work:** the ageing-extent mark, k times per object. The GC ratio (E4) must still
  hold with it.
- **Pause:** k recorded lists and a wider rule table; the heal skips dead holders.
- **Complexity:** a second job phase (mark, then promote) and per-target-extent lists. This is the
  "multiple generations … more complex to implement … increases the number of inter-generational
  pointers" of HB 9.6, avoided only in its pause-time cost.

### 12.4 Go / no-go (runnable today, before any code)

1. **A same-session A/B on the legacy nursery**: `promotion_age` 1 vs 2 (equal-length env), gf
   sweep 0.65 / 0.70 / 0.75 plus triples at 0.70. Record promoted bytes, old-gen peak, majors, RSS
   and wall.
2. The benefit of in-place ageing is legacy's age-2 **promotion** saving without legacy's age-2
   **copy** cost. So estimate: region-k=2 wall ≈ legacy age-1 wall − (age-2's major-GC and
   retention savings), and region-k=2 peak ≈ legacy age-2 peak.
3. **Go** if the age-2 arm cuts promoted bytes by ≥ 5 % *and* the sweep-median old-gen peak by
   ≥ 3 %, and E4's utilization at k = 1 leaves room for a k-fold mark (p99 ≤ 0.5). **Otherwise
   closed**, with the A/B recorded in the master plan. The 91 % prefix liveness of report §7.3
   says the saving is bounded: at most about 9 % of promotions, less whatever dies later anyway.

### 12.5 If go: the outline of its own plan

1. Generalise `RegionRing` to `k` ageing roles and `n = k + 3`; `roleOf`'s table grows; config
   `tenure_age` (1 default).
2. Per-target-extent H/S lists; the hand-over of `G_j` at minor j + k.
3. The job's mark phase: a per-extent side bitmap, marking from the hand-over minor's root-like
   sources through all ageing extents; a TSan harness extension.
4. The heal of live holders only; YLOS generations with k-step lifetimes.
5. Validators: TV2 over every ageing extent, a TV1 variant per extent, and the legacy oracle
   against `promotion_age = k` (tenured counts).
6. Measurement: the §12.4 arms against region k = 1, plus E4 with the mark phase.
