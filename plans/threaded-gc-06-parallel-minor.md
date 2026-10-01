# Threaded GC 06 — Parallel stop-the-world minor GC

**Status:** DONE (2026-09-27), **DEFAULT-ON: `gc_minor_threads` = 0 (auto), cap 8**. The
retention gate (E7) failed (+8.8 % gf-sweep median peak, P§10.9) and was **overridden after
review** (P§10.13). Default self-compile: wall 162.6 → 123.3 s, minor GC 46.8 → 12.3 s, minor p99
111.9 → 25.4 ms. Written against `keep-TG5c`; as-built record in P§10; snapshot `keep-TG6`,
`bin/eco-opt-prev` = `eco-optTG6d`.

**Parent:** `plans/threaded-gc-master-plan.md`, phase 6.

**Depends on:**
- phase 2: bitmap allocation, the per-class `AllocCursor` that becomes the per-worker promotion
  buffer, and HEAP_054;
- phase 3: GC_DET_001 and the TSan harness;
- phase 5b: `GCMarkGang`, the `MarkWork.hpp` loop, deques and termination, all reused here;
- phase 5c: the allocate-black atomics (H1), IM13, and the background gang running during
  minor pauses.

**Background:**
- `design_docs/parallel-gc.md`:
  - §7.2 (parallel STW copying) and §7.3 (en-masse prefix promotion);
  - §2.4 (forwarding may live in the header while only GC threads race);
  - §3.4 (memory model) and §10 (measuring a parallel collector);
- the handbook sections cited there: HB 14.4, 4.6 and 12.12 (parallel copying); HB 13.4
  (atomic forwarding); HB 13.6 (termination).

§n points into `design_docs/parallel-gc.md`, P§n into this plan, M§n into the master plan, and
5b-P§n / 5c-P§n into those plans.

---

## 0. What this phase delivers, and why

**Where 5c left the pauses.** Self-compile, triple medians; see TG5c in
`benchmarks/gc-opt-loop.md`.

| quantity | value |
|---|---|
| worst pause | ~190 ms, a plain minor GC (the "minor floor") |
| all-pause p99 | 116.3 ms; minor-only p99 ~115 ms |
| minor GC per run | ≈ 45 s (TG4b measured 44.7 to 45.0 s; 5a to 5c did not touch the minor path; Step 0 re-measures) |
| wall | 162.6 s |
| cores | 24; 5c's background gang uses at most 4, and only while a cycle runs |

- Since 5b the minor GC holds both the worst pause and the largest block of GC time. Marking
  has left the pauses, so this phase now serves both goals of M§1: pause first, wall second.
- The minor GC runs on one thread. During a minor pause every other core is idle, except for
  up to 4 background markers when a cycle is running.

**This phase runs the copy phase of a minor GC on N workers.**
- The paused mutator is worker 0. N − 1 `GCMarkGang` threads are workers 1 … N−1.
- Workers share work through 5b's deques and termination protocol (the `runMarkerLoop` of
  `MarkWork.hpp`, reused unchanged).
- A worker copies a from-space object only after winning a CAS that **claims** its header. It
  then copies, and **publishes** the forwarding word with a release store.
- Young survivors go into per-worker **to-space LABs**. The tails of those LABs become
  **filler objects**.
- Promoted objects go into **per-worker promotion cursors** (phase 2's `AllocCursor`, one per
  worker per size class). Every other rung of the allocation ladder runs under one **promotion
  mutex**.
- The root phase stays serial on worker 0. The Cheney/promoted/YLOS drains become one parallel
  drain.
- `gc_minor_threads = 1` keeps today's serial code path. It is the exact reference.

**Two properties make this more than "add threads":**
1. **Object-byte accounting.** LAB tails leave fillers in the survivor prefix. If the next minor
   GC's trigger, the nursery growth rule and the minor counters used prefix bytes, every minor
   after the first parallel one would depend on scheduling. They are switched to **object bytes**
   (prefix bytes minus filler bytes). This is a no-op at N = 1 and makes every nursery counter
   identical at every N (P§1 rule 2, P§3.5).
2. **An honest determinism contract (P§1 rule 3, P§3.15).** Which old-gen cell a promoted object
   receives depends on which worker promotes it. That breaks GC_DET_001's "which block an
   allocation receives is a function of mutator allocation" at N > 1.
   - Everything that depends only on objects stays exact at every N: minors, survived and
     promoted counts and bytes per tag, nursery growth, and objects allocated.
   - Decisions that read old-gen *placement* (committed bytes, per-block live fractions) become
     schedule-dependent. They are judged by distribution (gf sweep, triples), as TG2 judged the
     chaotic trigger.
   - GC_DET_001 is amended to say so. The alternative, bit-identical majors at every N, was
     considered and rejected (P§3.15).

**Expected result** [E; the report's §7.2 table rescaled to a ≈ 45 s minor. Step 0 replaces
the base numbers]:

| minor workers | minor pause p50 / worst | minor GC per run | wall |
|---|---|---|---|
| 1 (today) | ~25 ms / ~190 ms | ~45 s | 162.6 s |
| 4 | ~9 ms / ~70 ms | ~16–18 s | −25 to −28 s |
| 8 | ~6 ms / ~45 ms | ~10–12 s | −30 to −34 s |

The serial floor that remains: the stack walk (≤ 0.3 ms), the root phase (CellStore up to
8.6 ms), the pre-drain sweep slice (P§3.8; up to 63 ms at TG2), and the epilogue.

| # | Deliverable |
|---|---|
| D0 | Re-verified facts (P§2), a same-session baseline against `eco-optTG5c` including a fresh minor anatomy, the shared-state audit (P§3.11), the ladder-rung census during minors, and the prefix-liveness figure for §7.3. Snapshot `try-TG6-pre` |
| D1 | Pure refactor, counters bit-identical: `minorGC` split into prologue / serial core / epilogue; `getObjectSizeFromHeader`; object-byte accounting (`filler_bytes_`) in the trigger, growth, `bytesAllocated` users and stats; every survivor-prefix walker skips `Tag_Free` fillers |
| D2 | Configuration (`gc_minor_threads`, cap, LAB bytes, parallel threshold, child prefetch), `ECO_GC_MINOR_THREADS`, `resolveMinorThreads`, gang sizing, `ParMinorStats`, banner, event-log columns. Counters bit-identical |
| D3 | `MinorWork.hpp` (std-only): the forward/claim word protocol, the LAB allocator with fillers, and the TSan harness `minor_harness.cpp` running the real protocol and the reused `runMarkerLoop` on a synthetic heap |
| D4 | Promotion buffers in `OldGenSpace`: `PromoCtx`, per-worker cursors, the promotion mutex around rungs 2–8, per-worker accumulators, the minor-end return protocol, the IM13 check for worker cursors. Exercised serially through a test switch, counters bit-identical |
| D5 | The heap environment: `evacuateP`, `scanEntryP` for every tag, list-spine runs with a count-based heads pass, chunked arrays, deferred large-body operations, YLOS under `ylos_mu_`. Runs as a one-worker "parallel engine" behind a test switch; object counters identical |
| D6 | The parallel minor: per-minor worker choice, serial roots plus distribution, the gang run, the pre-drain sweep slice, LAB tails to fillers, merge, cursor return |
| D7 | Validators PM1–PM6, three negative controls, the validate tree at N ∈ {1, 4, 8} |
| D7b | Conditional (E2 decides): batched free-list pops into a per-worker stash |
| D8 | `gc-heap-tsan`: the real allocator runs parallel minors under TSan, with a background episode |
| D9 | Experiments E0–E9, gates, the default flip |
| D10 | Docs, invariants, tracking |

**Out of scope:**
- concurrent tenuring and survivor regions (phases 7b/7c);
- parallelising the root phase, the stack walk or the pre-drain sweep slice. Record them if they
  become the worst pause (phase 8 has the sweep item);
- building the §7.3 en-masse prefix variant. Step 0 measures its premise (prefix liveness) and
  records a go/no-go for a separate plan (P§3.16);
- the legacy STW `ThreadLocalHeap::majorGC` path (nursery traversal by `nursery_visited_`),
  which is unchanged;
- deterministic old-gen placement at N > 1 (P§3.15, rejected).

---

## 1. Ground rules

1. **`gc_minor_threads = 1` is the reference, and it runs today's serial code.**
   - After D1–D4, every counter and the whole minor and major event logs (non-timing columns)
     equal `eco-optTG5c`. `out.mlir` is byte-identical.
   - The serial core (`minorGCSerial`: roots, the alternating drain, the three copiers) is not
     edited beyond the D1 extraction.
2. **Object counters are identical at every N.** The following must be identical across
   `gc_minor_threads` ∈ {1, 2, 4, 8, auto} and with `ECO_GC_HELPER_JITTER_US`:
   - every per-minor row of the minor event log, in its object columns: survived, promoted,
     survived bytes, promoted bytes;
   - the run totals: minors, objects allocated, survived/promoted counts and bytes per tag,
     Custom-by-arity buckets, nursery grow events, final nursery size, t0 survivor count and
     object bytes.

   This holds because nothing a minor GC decides depends on a major GC's timing (P§3.15). A
   difference is a bug (a lost or double copy, or a filler counted as an object), never noise.
3. **Old-gen placement may differ at N > 1, and nothing else may.**
   - The layout-class counters (P§3.15 table) and the major sequence may differ between N = 1
     and N > 1, and between two N > 1 runs.
   - They are judged by E7's distribution rules.
   - No decision may read worker progress: timings, steal counts, who finished first, or LAB
     occupancy. The per-minor worker choice (P§3.2) reads only object bytes and configuration.
4. **Nothing outside the minor changes.**
   - The mark cycle, the triggers, the schedule and the mutator's allocation paths are 5c's.
   - Workers run only inside the owner's minor pause and are joined before the epilogue.
5. **Workers write only:**
   - the from-space headers they claim, by CAS;
   - their own LAB interiors, their own promotion-cursor blocks and bitmaps, and fillers in
     their own LAB tails;
   - the slots of copies they scan;
   - the to-space top, atomically;
   - their own deque, stack, counters, accumulators and logs.

   Anything else goes under `promo_mu_` or `ylos_mu_`, or is deferred to worker 0 after the join
   (P§3.11). Anything missing from P§3.11 that a worker writes is a bug.
6. **Assert what you rely on** (M§2):
   - every premise gets a validator (PM1–PM6) that the validate tree runs on unit, E2E and
     stress at N ∈ {1, 4, 8};
   - the protocol is TSan-tested on a synthetic heap (D3) and on the real allocator (D8).
7. **Standing gates** (M§2): E2E, elm-tests, `full`, stress under GC pressure, the validate
   tree, the stats-off build, `out.mlir` byte-identical, and the bootstrap fixed point.

---

## 2. Verified facts

Verified 2026-09-27 against `keep-TG5c`. Paths are under `runtime/src/allocator/`, and line
numbers are approximate. **Re-verify before editing (Step 0). Trust the name, re-locate the
line** ([[gc-plan-premises-need-rederiving]]).

| # | Fact | Where |
|---|---|---|
| F1 | `NurserySpace::minorGC` has four parts. (a) Prologue: set `minor_gc_running_` / `setInMinorGC`, flip `minor_color_`, clear `young_large_scan_`, validate pre-walk, P1 census check, stats capture. (b) Roots 1a/1b/1c/1e/1e'/1d, in that order: long-lived, stackmap, JIT, stack ranges, single stack roots, external scanners (timed per scanner). (c) An alternating drain that runs to a fixed point: to-space Cheney (`scan_ptr_` → `copy_ptr_`, `in_phase3_ = false`), then `promoted_buf_` (`in_phase3_ = true`), then `young_large_scan_`. (d) Epilogue: `checkAndGrow`, `clearToSpaceFreeRegion`, the validate to-space and old-gen walks, `poisonOldFromSpaceUsedRegion`, the space flip, `bump_.ptr = copy_ptr_`, `survivor_end_ = bump_.ptr`, census record, stats, `sweepNurseryLargeBodies(minor_color_)`, `validateYoungLarge`, clearing the flags, `validateEveryNthMinor`. | `NurserySpace.cpp:427-1175` |
| F2 | Three copiers each install the forwarding by three **bitfield stores** (`tag`, `forward_ptr`, `unused`), which **preserve `color`**. Their header fixups differ. `evacuate`: promoted → `age = 0`, `color = White`; to-space → `age++` unless builder, `color = White`. `evacuateJitPtr`: promoted → `age = 0`; to-space → `age++` unless builder; color untouched. `evacuateListSpine`: the same as JIT. | `NurserySpace.cpp:1177-1475`, `1480-1575`, `2069-2190` |
| F3 | Header: `tag:5 color:2 pin:1 age:2 unboxed:6 refcount:15 builder:1` (low 32 bits), then `size:32`. Forward: `tag:5 color:2 forward_ptr:40 unused:17`; `encodeForwardPtr(p) = p >> 3`. So a forward word is `Tag_Forward \| color << 5 \| (addr >> 3) << 7`. Address 0 is never an object. | `Heap.hpp:164-176`, `387-392`, `698-706` |
| F4 | To-space is one bump extent: `copyToSpace` bumps `copy_ptr_` up to `copy_end_`, and overflow is "impossible" because both sides have one capacity. `checkAndGrow` measures occupancy as `copy_ptr_ - toBase()`. `computeAllocEnd` caps `bump_.end` at `base + threshold_total_bytes_` (capacity × `nursery_gc_threshold`), except that it gives the full extent when `bump_.ptr - base ≥ threshold` (fail-soft). `bytesAllocated()` = `bump_.ptr - fromBase()`, used by `isNurseryNearFull` and the `bytes_freed` stat. | `NurserySpace.cpp:284-425`; `ThreadLocalHeap.cpp:984-994` |
| F5 | Geometry: per-side capacity at most `nursery_max_block_count / 2 × alloc_buffer_size` = 256 × 512 KiB = **128 MiB**; `nursery_gc_threshold` 0.95; `promotion_age` 1, so every promoted object is an age-1 object of the survivor prefix; the largest nursery object is min(⅛ nursery, 128 KiB). | `AllocatorCommon.hpp:91, 103, 140, 143, 152, 767` |
| F6 | Survivor-prefix walkers: `forEachSurvivor` (the t0 young walk, `ThreadLocalHeap.cpp:~1074`; its `bytes_out` feeds `im.t0_survivor_bytes`); the P1 census `censusRecord` / `censusCheck`; `preEvacuationFromSpaceWalk`; the validate to-space walk in the epilogue; `poisonOldFromSpaceUsedRegion`; `isInToSpaceAllocatedRegion` (reads `copy_ptr_`); `debugAssertValidNurseryPointer`. All walk by `getObjectSize`. `getObjectSize(Tag_Free)` = `header.size` bytes. | `NurserySpace.hpp:~150-175`; `NurserySpace.cpp:2312-2420, 2550-2700` |
| F7 | `scanObject` per tag: Tuple2/3 and Cons by `tupleFieldKind`; Custom (≤ 24 fields) and Record (≤ 32) by `fieldKind`; DynRecord (`fieldgroup` plus `size` values); Closure (`n_values`, not `size`); ConsChunk (`backing`, `next`); ListBacking `[hd, size)` when boxed; Task (value when boxed, callback, kill, task); Process (root, stack, mailbox); Array (`length`, not capacity); StringSlice / Utf8View / ByteBufferSlice (`base`); StringRope (`left`, `right`); Large{String,Byte}Header → `markLargeBodySeen(body, minor_color_)`. Everything else has no children. | `NurserySpace.cpp:1752-2067` |
| F8 | Hybrid DFS: the Cons arm evacuates the head, then, if the tail is in from-space, `evacuateListSpine` copies the whole spine (claiming nothing: single-threaded), and `evacuateListHeads` walks the copies until the next cell is "not in to-space and not in old gen". Under the serial design every spine cell is scanned twice (heads pass, then Cheney or the promoted drain). | `NurserySpace.cpp:1950-1985, 2069-2250` |
| F9 | `OldGenSpace::allocate` (a promotion when `in_minor_gc_`): IM16 `DecisionScope`; the size histogram; **a lazy-sweep slice per promotion when `gc_phase_ == Sweeping`** (`sweep_work_budget / minor_sweep_divisor`, targeted at the object's class); then large (≥ `alloc_buffer_size`, never from the nursery), class (`allocateFromSizeClass` → the bitmap ladder), or bag-page paths; IM4 `noteCycleAllocation`. | `OldGenSpace.cpp:1114-1260` |
| F10 | The bitmap ladder `allocateFromSizeClassBitmap`: (1) `cursorAllocate` over `partial_[cls]` blocks, (2) free-list pop of a mixed cell, (3) bag-first virgin block (small classes, budgeted), (4) split of a larger mixed cell, (5) sweep-on-demand, (6) virgin block, (7) a bag page as one cell, (8) panic sweep. `finalizeBitmapCell` sets the cell bit with a plain `setBit`, writes a zero header, colours it Black mid-cycle, adds to `pending_live` / `pending_allocs`, and adds the cell to **`allocated_bytes`** and **`old_alloc_total_`**. `setCursor` carries IM13. The other rungs also add to `allocated_bytes` (`:1315` cell size, `:1631` split size, `:1785` **requested** size for a bag page). | `OldGenSpace.cpp:690-908, 1300-1320, 1620-1640, 1780-1790`; `OldGenSpace.hpp:540-600` |
| F11 | `NUM_SIZE_CLASSES` = 40 (32 small + 8 medium); blocks are `alloc_buffer_size` = 512 KiB. One mark-bitmap byte covers 64 B, and a block's bitmap is its own arena slot (HEAP_050), so **two blocks never share a bitmap byte**. | `AllocatorCommon.hpp:91, 337-349`; HEAP_050 |
| F12 | Large bodies. `markLargeBodySeen` (`find`, write `color`) and `promoteLargeHeader` (`find`, swap-remove from `nursery_owned_bodies_`, `erase`, push the id free) both touch `large_body_index_`, an `unordered_map`. The YLOS reach (`reachYoungLarge` → `youngLargeMeta` `find`, `promoteYoungLarge` `erase`) touches the same map. `mayBeYoungLarge`'s bounding box does not change during a minor (it is recomputed at minor end). `sweepNurseryLargeBodies` runs in the epilogue. | `OldGenSpace.cpp:6354-6450`; `OldGenSpace.hpp:990-1010`; `NurserySpace.cpp:1678-1712` |
| F13 | Stats. `recordSurvival` / `recordPromotion` update `objects_*`, `*_count_by_tag`, `*_bytes_by_tag` and the Custom arity buckets in the nursery's `GCStats stats`. `MinorGCRecord` holds the phase timers; `gcEventLogMinor` writes one row per minor. | `GCStats.hpp:96-127, 1052-1072, 1299-1303` |
| F14 | `GCMarkGang`: `configure(members, jitter)` is first-call-wins (tests reconfigure through `shutdownForTesting`); `run(fn, ctx, n)` runs member 0 on the caller, n ≤ members, and serialises concurrent callers. `runMarkers` (re)configures it with `mark_threads_` at three sites. | `GCHelperPool.hpp:164-212`; `OldGenSpace.cpp:~2784, ~3791, ~3837` |
| F15 | `MarkWork.hpp`: `runMarkerLoop(env, self, c)` is generic over an Env (`counters`, `takeOwn`, `stealFrom`, `anyWork`, `prefetch`, `scan`, `publishAll`, `kParallel`); a 16-deep FIFO ring with `prefetch` on entry; tickets from `c.budget`; `kDrainBudget = INT64_MAX / 4`; stealing; one-CAS termination. Entries are `objEntry(p, field)` / `chunkEntry(arr, chunk)`. `OldGenSpace::ParallelEnv` and `publishHalf` / `publishAll` / `pushGrey` are the pattern: a private owner stack, the oldest half published when the deque is empty, the private size in a relaxed atomic for `anyWork`. | `MarkWork.hpp:1-487`; `OldGenSpace.hpp:731-805`; `OldGenSpace.cpp:2700-2760` |
| F16 | **Background markers steal from every mark slot** (`SliceControl::n` = `mark_slots_`, background included). A deque in `markers_[]` is therefore visible to a running 5c episode. | `OldGenSpace.cpp:~2792`; 5c-P§3.3 |
| F17 | `ThreadLocalHeap::minorGC`: stack walk → `nursery_.minorGC` → `notePacingMinorEnd` → cycle step (`stepMarkCycle`) or trigger evaluation. Foreground mark work (slices, t0, handoff) runs **after** the nursery minor returns, so `GCMarkGang` is idle during the drain. A 5c background episode may be running during the whole pause. | `ThreadLocalHeap.cpp:699-760` |
| F18 | 5c H1: on the non-cursor paths mid-cycle, allocate-black on a t0 block uses `setMarkBitAtomic`. H1b: the cursor path keeps a plain `setBit` because cursors own only post-t0 blocks (IM13, asserted in `setCursor`). | 5c-P§3.6-3.7; `OldGenSpace.cpp:716-741` |
| F19 | GC_DET_001 as it stands says: "which block or extent an allocation receives … are functions of mutator allocation …" and "every decision counter … identical at conc_mark 0/1/2, every B". | `design_docs/invariants.csv:701` |
| F20 | Decisions that read placement: `evaluateMajorGCTrigger` reads `getOldGenCommittedBytes()` (GlobalPressure, Headroom) and `committed` (the garbage-fraction denominator). LiveBudget and GF read `allocated_bytes`, which is path-dependent (F10: a bag-page cell counts its requested size). `major_live_` / `post_sweep_live_bytes_` come from per-block `live_bytes` (uniform: popcount × cell; mixed: object sizes). P̂ reads `old_alloc_total_`. At gf 0.70 the default run's majors are a mix of garbage-fraction and LiveBudget (5c E8). | `OldGenSpace.cpp:4780-4885, 3050-3093` |
| F21 | `availableCpus()` (affinity mask plus cgroup `cpu.max`); `gc_mark_threads` / `_cap` / `conc_mark_threads` fields, their validation and the `ECO_GC_MARK_THREADS` parse are the templates for the new fields. | `GCHelperPool.cpp:692-720`; `AllocatorCommon.hpp:636-642, 800-815`; `HeapConfigJson.cpp:202-206, 323-330, 464-476` |
| F22 | TSan harnesses: `test/gc-helper-tsan` (g++; `harness.cpp`, `mark_harness.cpp`, std-only headers only) and `test/gc-heap-tsan` (the real allocator; `heap_driver.cpp`, `stub_unwind.cpp`). | `test/gc-helper-tsan/`, `test/gc-heap-tsan/` |
| F23 | Unit tests live in `test/allocator/` (`NurserySpaceTest`, `GCPressureTest`, `NurseryContiguityTest`, `ConcurrentMarkTest`, …). **`ECO_GC_*` env is applied only at the first `Allocator::initialize`** in the unit binary; tests must pin through the config ([[unit-tests-ignore-heap-config-env]]). | `test/allocator/` |
| F24 | `g_scan_parent`, `g_scan_tag` and `g_scan_size` (validate diagnostics) are file-scope statics in `NurserySpace.cpp`. | `NurserySpace.cpp` (grep `g_scan_parent`) |
| F25 | `lazySweep(target_class, budget)` advances the sweep cursor over pending mixed blocks and flips `gc_phase_` to Idle when it passes the last block. Besides the promotion path it is called with `NUM_SIZE_CLASSES` at `:2077`, `:3238` and `:4346`. | `OldGenSpace.cpp:4475-4600` |
| F26 | The machine: 24 cores, no SMT, 16 MiB shared L3, 15 GB RAM. | report §3.1 |

---

## 3. Design

### 3.1 A parallel minor, end to end

`NurserySpace::minorGC(oldgen, roots, rec)` becomes:

```
prologue(oldgen, rec)                         // F1 (a), unchanged
n = chooseMinorWorkers()                       // P§3.2
if (n == 1 && !test_force_parallel_engine_)
    minorGCSerial(oldgen, roots, rec)          // F1 (b)+(c), today's code verbatim
else
    minorGCParallel(oldgen, roots, rec, n)     // P§3.1 below
epilogue(oldgen, rec)                          // F1 (d), with the P§3.5 object-byte changes
```

`minorGCParallel`, all on the mutator thread unless marked [gang]:

1. **Set up.**
   - `tospace_top_.store(toBase())`, `copy_end_ = toBase() + slice_.capacity`.
   - Reset the `minor_workers_[0..n-1]` state (P§3.6).
   - `oldgen.beginParallelPromotion(n, promo_ctx_)` (P§3.8): worker 0 adopts `cursor_[]`, and
     workers 1..n−1 start with empty cursors.
2. **Pre-drain sweep slice** (P§3.8.5), only when `oldgen.gc_phase_ == Sweeping`.
3. **Roots, serial, on worker 0.** The same phases in the same order as F1 (b), but every copier
   call is `evacuateP(w0, slot, /*parent_old=*/false)`. Copies go on worker 0's private stack.
   Phase-timer laps as today.
4. **Distribute.** Move worker 0's private stack round-robin into the deques of workers 0..n−1
   (`deque.push` from this thread is legal: no member runs yet, and the gang start is a mutex
   release/acquire, F14).
5. **[gang] Drain.** `GCMarkGang::run(minorWorkerEntry, &args, n)`. Each member runs
   `markwork::runMarkerLoop(MinorEnv{…}, i, c)` with `SliceControl c(kDrainBudget, n, jitter)`
   (P§3.6). Termination means every stack and deque is empty, so every copy has been scanned.
6. **Close the LABs** (P§3.4). Trim the LAB that ends at the top; turn every other LAB tail into
   a filler; set `copy_ptr_ = tospace_top_`; sum `filler_bytes_to_`.
7. **Merge** in worker index order (P§3.12):
   - nursery stats;
   - `oldgen.endParallelPromotion(promo_ctx_)`: accumulators, cursor return, and the deferred
     large-body operations (P§3.9);
   - validate and census logs → `promoted_buf_`.
8. **Validators** PM1–PM6 (validate builds, P§3.13), then V2 on `promoted_buf_`.
9. Return to the epilogue. The epilogue flips the spaces and sets `bump_.ptr = copy_ptr_`,
   `survivor_end_`, and `filler_bytes_ = filler_bytes_to_` (P§3.5).

### 3.2 When a minor runs parallel (`chooseMinorWorkers`)

The choice may read only configuration and object bytes (rule 3):

```
n = minor_threads_                              // resolved: 1 … 64 (P§3.14)
if (n == 1) return 1
S = objectBytesAllocated()                      // (bump_.ptr - fromBase()) - filler_bytes_
if (S < config_->minor_parallel_min_bytes) { ++pm.serial_small; return 1 }
if (S + S / 32 + n * lab_bytes_ > slice_.capacity) { ++pm.serial_space; return 1 }
return n
```

- **Why the space test is sufficient.**
  - The survivors are at most S bytes (every survivor is a from-space object).
  - LAB waste is bounded by P§3.4: at most `lab/64` per retired LAB. That is ≤ S/63 over the
    minor (S/32 in the test, for margin), plus at most one LAB tail per worker at the end.
  - So `S + S/32 + n·lab ≤ capacity` guarantees that the to-space top never passes
    `copy_end_`.
  - `tospaceClaim` still checks and aborts in every build (P§3.4). If it ever fires, the bound
    is wrong.
- **At the 0.95 trigger** S ≤ 0.95 × 128 MiB, and 0.95 × (1 + 1/32) + 16 × 32 KiB / 128 MiB =
  0.984 < 1. The space test fails only in the fail-soft state (survivors already above the
  threshold, F4). Those minors run serially.
- A serial minor produces no fillers: `filler_bytes_` becomes 0 at its end.

### 3.3 Forwarding: claim, copy, publish (`MinorWork.hpp`)

The header word `hw` of a from-space object, read with `std::atomic_ref<uint64_t>(*(uint64_t*)obj)`:

| state | word |
|---|---|
| live, unclaimed | its header (low 5 bits ≠ `Tag_Forward`) |
| claimed, being copied | `kBusy` = `Tag_Forward` (color 0, `forward_ptr` 0) |
| forwarded | `fwd(dst, color)` = `Tag_Forward \| color << 5 \| (dst >> 3) << 7` |

`evacuateP(w, HPointer& slot, bool parent_old)`, for an HPointer in a slot that only this worker
reads or writes:

```
if slot.ptr_ind != 0 or slot.ptr == 0: return             // constant / null
obj = fromPointerRaw(slot)
if obj outside [heap_base_, heap_base_ + heap_reserved_): return   // permanent space
if !isInFromSpace(obj):
    if oldgen.mayBeYoungLarge(obj): reachYoungLargeP(w, obj, parent_old)   // P§3.9
    return
h = load(hw, acquire)
loop:
  if tag(h) == Tag_Forward:
      if h == kBusy: waitPublished(hw, w)  -> h ; continue  // spin → yield → sleep (MarkWork backoff)
      slot = toPointerRaw(decode(h)); return
  if !cas(hw, h, kBusy, acq_rel, acquire): continue          // h now holds the observed word
  break
// we own obj; h is its original header word
size   = getObjectSizeFromHeader(h)                          // P§3.3.2
Header hd = bits(h)
if shouldPromote(hd):                                        // age >= promotion_age_, !pin, !builder
    dst = promoAllocate(w, size)                             // P§3.8
    hd.age = 0;  hd.color = White
    if hd.tag is LargeStringHeader or LargeByteHeader: w.lb_promoted.push_back(body of obj)   // P§3.9
    ++w.stats promoted(hd.tag, size, hd.size); log(w.promoted, dst) [validate/census]
else:
    if parent_old: validate abort "promoted parent has a young child" (P§3.13 PM5)
    dst = labAllocate(w, size)                               // P§3.4
    if !hd.builder: hd.age++
    hd.color = White
    ++w.stats survived(hd.tag, size, hd.size)
memcpy(dst + 8, obj + 8, size - 8); store header word of dst = hd (plain)
store(hw, fwd(dst, color(h)), release)
slot = toPointerRaw(dst)
if tagMayHaveChildren(hd.tag): w.pushGrey(objEntry(dst, 0))
```

`evacuateJitP(w, uint64_t& raw)` and `evacuateValueSlotP` are thin adaptors onto the same body:
a raw pointer instead of an HPointer, and constants decided by `isConstantBits`.

#### 3.3.1 Why this protocol

- **Claim-then-copy, not copy-then-CAS.**
  - Copy-then-CAS makes the loser undo an allocation. A to-space LAB bump can be rolled back
    only if nothing was allocated after it.
  - Undoing an old-gen cell means clearing its bit, rewinding the cursor, and debiting
    `allocated_bytes` and `pending_live`, or, on a mutex rung, putting a popped free cell back.
    Every undo path is a place to lose accounting.
  - Claim-first never allocates for a loser. The cost is one extra plain store on a line the
    winner already owns.
- **Waiters spin only while a copy is in flight.** A copy is ≤ 128 KiB of memcpy, plus a
  promotion allocation that may wait for `promo_mu_`.
  - The holder of `promo_mu_` never waits on a claim: the ladder does not evacuate. So there is
    no cycle.
  - The waiter uses `markwork::backoff` (spin, then yield, then sleep).
- **The `color` bits of `h` are carried into the forward word.** Serial copiers preserve them
  (F2). W2 item 23 was refuted for silently zeroing them. Step 0 checks whether anything reads a
  forwarded object's color; preserving it costs nothing.
- **All copies get `color = White`.** This unifies F2's three fixups. The JIT and spine copiers
  leave the source color on the copy, while `evacuate` writes White. Nursery objects are White
  when copied (Step 0 verifies: grep `->color =` writers on nursery objects). If that holds, the
  unified fixup produces the same bits.
- **Only the header word is atomic.** The body is read after winning the claim. By P1
  (HEAP_SNAPSHOT_001) and the stopped mutator, nobody writes it. The destination is private
  until the release store publishes the forward word, and readers of a forward word only write
  the address into their own slots.

#### 3.3.2 `getObjectSizeFromHeader`

The serial copiers call `getObjectSize(obj)`. Once the object is claimed, its header is `kBusy`.
Refactor `getObjectSize(void*)` in `AllocatorCommon.hpp:364` into
`getObjectSizeFromHeader(const Header&)` (the same switch) plus a wrapper
`getObjectSize(obj) = getObjectSizeFromHeader(*getHeader(obj))`. This is a D1 refactor; the
compiler inlines both.

#### 3.3.3 Layout pinning

`MinorWork.hpp` is std-only (for the TSan harness), so it defines `kTagForward`, `kTagShift = 0`,
`kColorShift = 5` and `kFwdShift = 7` itself. `NurseryParallel.cpp` adds:
- `static_assert(minorwork::kTagForward == Tag_Forward)`;
- a runtime check, in the unit test `testForwardWordMatchesBitfields`, that a `Forward` built by
  bitfield stores for a set of addresses and colors equals `minorwork::fwd(addr, color)`, and
  that `kBusy` decodes as `tag == Tag_Forward, forward_ptr == 0`. This is the same method as
  `HPointerLayoutTest`: bitfield layout is implementation-defined.

### 3.4 To-space LABs and fillers

Per worker: `char* lab_ptr, *lab_end`. Shared: `std::atomic<char*> tospace_top_`. Constants:
`lab_bytes_` = `minor_lab_bytes` (default 32 KiB, E3), `retire_max = lab_bytes_ / 64`,
`direct_min = lab_bytes_ / 4`.

```
labAllocate(w, size):
  if size >= direct_min: return tospaceClaim(size)            // exact, no LAB
  if lab_ptr + size <= lab_end: p = lab_ptr; lab_ptr += size; return p
  rem = lab_end - lab_ptr
  if rem > retire_max: return tospaceClaim(size)             // keep the LAB, place this one directly
  if rem > 0: writeFiller(lab_ptr, rem); w.filler_bytes += rem   // retire
  (lab_ptr, lab_end) = tospaceClaimLab()                       // min(lab_bytes_, copy_end_ - top)
  ... then bump as above (the new LAB is ≥ size, or tospaceClaim(size) if it is the short last one)

tospaceClaim(size):  CAS loop on tospace_top_: new = top + size; abort if new > copy_end_
```

- **A filler** is a header `{tag = Tag_Free, size = bytes, everything else 0}`. The bytes after
  it are not written.
  - Gaps are multiples of 8 and at least 8. An 8-byte filler is a bare header, which
    `getObjectSize(Tag_Free)` = `header.size` walks correctly (F6).
  - Tag_Free's old-gen `age` meaning (free-list sentinel) does not apply in the nursery. Write
    age 0.
- **At the end (P§3.1 step 6):**
  - The LAB whose `lab_end == tospace_top_` is trimmed: `tospace_top_ = lab_ptr`, no filler.
  - Every other non-empty tail `[lab_ptr, lab_end)` becomes a filler.
  - `filler_bytes_to_` = the sum of every worker's `filler_bytes` plus the tail fillers.
- **Why fillers and not compaction.** Objects are already placed and referenced, and a prefix
  walker needs a parsable prefix (F6). Fillers are the standard answer (HotSpot PLABs, GHC
  blocks).

### 3.5 Object-byte accounting

New field: `size_t filler_bytes_ = 0` on `NurserySpace`, the filler bytes inside the from-space
survivor prefix `[fromBase(), survivor_end_)`. It is set by the epilogue from
`filler_bytes_to_`, or to 0 by a serial minor.

| user | today (F4) | after D1 |
|---|---|---|
| `computeAllocEnd` | `already = bump_.ptr - base`; fail-soft if `already ≥ threshold`; else `base + threshold` | `obj = already - filler_bytes_`; fail-soft if `obj ≥ threshold`; else `end = base + threshold + filler_bytes_`, capped at the extent end. If it is capped (not fail-soft), `++pm.alloc_end_capped` |
| `checkAndGrow` occupancy | `copy_ptr_ - toBase()` | `(copy_ptr_ - toBase()) - filler_bytes_to_` |
| `objectBytesAllocated()` (new) | — | `bytesAllocated() - filler_bytes_` |
| `isNurseryNearFull` | `bytesAllocated()` | `objectBytesAllocated()` |
| minor `bytes_freed` stat and `nursery_pause` bookkeeping | from `bytesAllocated()` / `bump_.ptr - fromBase()` | object bytes on both sides |
| `forEachSurvivor(f, bytes_out)` | calls f on every object; `bytes_out` = prefix bytes | skips `Tag_Free` (no call, not counted); `bytes_out` = object bytes |
| P1 `censusRecord` / `censusCheck` | every prefix object | skip `Tag_Free` |
| validate to-space walk, `preEvacuationFromSpaceWalk`, `poisonOldFromSpaceUsedRegion` | walk by size | unchanged (Tag_Free is ≤ Tag_Forward and walks by size); the to-space walk also sums the filler bytes for PM3 |
| `isInToSpaceAllocatedRegion` | `< copy_ptr_` | `< tospace_top_` during a parallel drain (validate only) |

- **`alloc_end_capped`** can be non-zero only when the prefix's object bytes plus the fillers
  pass the extent end before the threshold. P§3.2 keeps the fillers under 3.2 % + n·lab of S,
  and the threshold leaves 5 %. The counter must be 0 on every gate run. A non-zero value means
  that run's nursery counters are not comparable across N; the entry reports it.
- **HEAP_041 `ensureHeadroom` is unaffected.** It compares against `bump_.end`, and D1 only
  changes how `bump_.end` is computed.
- **At N = 1, `filler_bytes_` is always 0**, so every row is the old formula. This is D1's
  bit-identity gate.

### 3.6 Workers, grey entries and the loop

```cpp
struct MinorWorker {                        // NurserySpace::minor_workers_[kMaxMinorWorkers] (unique_ptr)
    std::vector<uint64_t> stack;            // private, owner-only
    std::atomic<uint64_t> priv{0};          // stack.size() for anyWork()
    uint64_t pops = 0;
    markwork::WorkStealingDeque deque;
    markwork::MarkerCounters ctr;
    char* lab_ptr = nullptr; char* lab_end = nullptr;
    uint64_t filler_bytes = 0;
    MinorWorkerStats st;                    // P§3.12
    std::vector<HPointer> lb_seen, lb_promoted;   // P§3.9 deferred large-body ops
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    std::vector<void*> promoted_log;
#endif
};
```

- **These are not `OldGenSpace::markers_`** (F16): a running background episode steals from every
  mark slot and would take minor entries. `kMaxMinorWorkers = 64`.
- **Entries.** `objEntry(copy, field)` with field 0 for a normal copy, or 1 for a YLOS object
  that stays young and is scanned in place. `chunkEntry(arr, k)` for chunk k ≥ 1 of a boxed
  `Tag_Array` / `Tag_ListBacking` over `MINOR_CHUNK_ELEMS` = 1,024 slots. Chunk 0 is scanned
  when the object is scanned, and chunks 1.. are pushed then.
- **`pushGrey` / `takeOwn` / `publishHalf` / `publishAll`** copy 5b's policy (F15): a private
  stack, `priv` updated on push and pop, the oldest half published every 32 pushes or 64 pops
  when the deque is empty (`kPublishMin` 64), and `publishAll` on every loop exit.
- **`MinorEnv`** for `runMarkerLoop`:
  - `kParallel = true`;
  - `counters(i)`, `takeOwn(i)`, `stealFrom(v) = minor_workers_[v]->deque.steal()`;
  - `anyWork()` over the n minor workers only;
  - `prefetch(e)`, see below;
  - `scan(self, e) = scanEntryP(*minor_workers_[self], e)`;
  - `publishAll(self)`.
- **Budget:** `SliceControl c(kDrainBudget, n, jitter, n)`. Tickets exist but never run out
  (256 per CAS on the pool: negligible). Termination is the one-CAS protocol, unchanged.
- **`prefetch(e)`.** The entry is a copy we just wrote, so it is hot. The cold loads are its
  children's from-space headers.
  - With `minor_prefetch_children` false (the default until E3), `prefetch` does nothing.
  - With it true, `prefetch(e)` reads the copy's boxed slots (tag switch, at most the first 8
    slots) and issues `__builtin_prefetch(child, 1, 3)` for each child inside from-space. The
    16-deep ring then gives the look-ahead that won 12 % in the old-gen mark (W13c, item 54).
  - E3 measures it at N = 1 (the parallel engine) and at the chosen N.

### 3.7 Scanning an entry (`scanEntryP`)

`scanEntryP(w, e)`:
- `obj = entryAddr(e)`;
- `parent_old = !nursery_contains(obj) && entryField(e) == 0` (a promoted copy, or a YLOS object
  promoted in place; field 1 = a young YLOS object);
- a chunk entry scans its element range and returns;
- otherwise switch on the tag, exactly F7's arms, with `evacuateP(w, slot, parent_old)` in place
  of `evacuate`, and with these differences:

| arm | parallel behaviour |
|---|---|
| Array / ListBacking with a boxed kind and more than 1,024 slots | push `chunkEntry(obj, k)` for k = 1 … ceil(len/1024) − 1 (++`st.chunks`), then scan chunk 0 |
| Large{String,Byte}Header | `w.lb_seen.push_back(h->body)` (deferred, P§3.9) |
| Cons | see below (`use_hybrid_dfs_`; if false, head then tail by `evacuateP`) |

**The Cons arm, in runs.**

```
evacuateUnboxableP(w, c->head, head_boxed, parent_old)
spineRun(w, c, parent_old)

spineRun(w, prev, parent_old):          // prev: a copy we own whose tail may point into from-space
  first = null; k = 0; needs_heads = false
  loop:
    t = prev->tail
    if t.ptr_ind != 0: break                                         // Nil / constant
    obj = decode(t)
    if !isInFromSpace(obj): evacuateP(w, prev->tail, parent_old_of(prev)); break   // old or YLOS
    h = load(hw(obj), acquire)
    if tag(h) == Tag_Forward: prev->tail = forwarded(waitIfBusy(h)); break
    if tag(h) != Tag_Cons:    evacuateP(w, prev->tail, parent_old_of(prev)); break
    if k == kSpineRun: w.pushGrey(objEntry(prev, 0)); ++st.spine_splits; truncated = true; break
    if !cas(hw, h, kBusy): continue                                   // re-read and re-decide
    copy the cell exactly as evacuateP does (promote or LAB), publish, stats
    if boxed head and non-constant: needs_heads = true
    prev->tail = toPointerRaw(copy); if k == 0: first = copy
    prev = copy; ++k
  if needs_heads and k > 0:
     heads over the first (truncated ? k - 1 : k) copies, walking our own tail links from first:
        evacuateUnboxableP(w, cell->head, boxed(cell), parent_old_of(cell))
```

- `kSpineRun` = 512 cells. It bounds the serial part of one list: another worker can pick up the
  pushed continuation.
- **The heads pass counts cells** (§7.2, F8). It never tests "still in to-space": the next cell
  may have been copied by another worker and still lie in to-space.
- **Every copy is scanned exactly once.**
  - A spine cell is scanned by the heads pass.
  - When a run is truncated, its last cell is not in the heads pass: it is pushed, and its scan
    handles its head and continues the spine.
  - A cell that needs no heads pass (unboxed or constant head) has no other children than its
    tail, which the run handles.
  - The serial design scans spine cells twice (F8). The object counters do not see the
    difference; traversal counters do (P§3.15).
- `parent_old_of(cell)` = `!nursery_contains(cell)`: a promoted spine cell is an old parent.
  PM5 then checks its head and tail.
- A spine cell's copy follows the same promote-or-LAB rule as every other object. `shouldPromote`
  reads the cell's own age.

### 3.8 Promotion buffers (`OldGenSpace`)

#### 3.8.1 `PromoCtx`

```cpp
struct PromoWorker {                                   // one per minor worker
    AllocCursor cur[NUM_SIZE_CLASSES];
    uint64_t allocated_bytes = 0, old_alloc_total = 0; // deltas, merged after the join
    BitmapAllocStats bm;                               // this worker's share
    uint64_t hist[...];                                // GC_STATS_OLDGEN_RECORD_ALLOC share
    uint64_t mutex_acquires = 0, mutex_wait_ns = 0;    // wait timed only when try_lock failed
#if ECO_HEAP_VALIDATE
    std::vector<void*> cycle_alloc_log;                // IM4, merged into cycle_alloc_log_
#endif
};
struct PromoCtx { unsigned n; PromoWorker w[kMaxMinorWorkers]; };   // owned by OldGenSpace
std::mutex promo_mu_;                                                // rungs 2–8
```

#### 3.8.2 `promoAllocate(w, size)` → `oldgen.allocatePromotion(pw, size)`

```
size = align8(size); assert(size < alloc_buffer_size)   // F5: never a large block
cls = sizeClass(size)
if cls < num_size_classes_ and bitmapMode():
    if p = cursorAllocateW(pw.cur[cls], cls, size, pw): return p          // rung 1, no lock
    lock promo_mu_ (timed on contention)
      if refillCursorW(pw.cur[cls], cls): p = cursorAllocateW(...)         // rung 1 refill from partial_[cls]
      else p = ladderFrom2(cls, size, pw)                                  // rungs 2–8, P§3.8.3
    unlock; return p
lock promo_mu_; p = allocateFromBagPage(size) (class-less sizes, rung 7 path); unlock; return p
```

- `cursorAllocateW` / `finalizeBitmapCellW` are `cursorAllocate` / `finalizeBitmapCell` with two
  changes:
  - the cursor is passed in;
  - `allocated_bytes` / `old_alloc_total_` / the stats go to `pw`'s fields.

  Refactor the existing pair to take `(AllocCursor&, Acc*)`, where `Acc = nullptr` means "write
  the shared fields", so the serial path compiles to the same code. Check the mark-loop
  alignment trap (1 in [[gc-mark-loop-alignment-trap]]) if promotion time moves with identical
  instructions.
- **`setCursorW(AllocCursor&, cls, id)`** shares `setCursor`'s body, including the **IM13**
  check. 5c's premise then covers every worker cursor: during a cycle a worker cursor owns only
  post-t0 blocks, so its plain `setBit` never races a background marker (F18).
- The header colour logic in `finalizeBitmapCellW` reads `marking_active` / `gc_phase_`, which
  nobody writes during the pause.

#### 3.8.3 Rungs 2–8 under the mutex

`ladderFrom2(cls, size, pw)` is `allocateFromSizeClassBitmap` from rung (2) on, with:
- rungs (3) and (6) calling `startVirginBlockW(pw.cur[cls], cls)`, which sets the *worker's*
  cursor;
- every `allocated_bytes += x` / `old_alloc_total_ += x` inside these rungs writing the shared
  fields directly. That is legal: under the mutex they are the only writers, since worker fast
  paths write `pw` only;
- IM16's `DecisionScope` taken inside the lock. `in_decision_` is a plain counter, and the lock
  serialises it;
- IM4 `noteCycleAllocation` writing `pw.cycle_alloc_log` (validate).

**The W6 rule** (the whole ladder keeps its order): a worker's cursor is rung 1, as the single
cursor was. The refill pops `partial_[cls]` before any other rung. Nothing is inserted above a
reuse rung.

#### 3.8.4 Begin and end

- **`beginParallelPromotion(n, ctx)`:**
  - `ctx.w[0].cur[cls] = cursor_[cls]` for every class (a move; the block stays
    `kAllocCurrent`), and `cursor_[cls] = AllocCursor{}`;
  - `ctx.w[1..n-1].cur[*] = {}`;
  - all accumulators zeroed.
- **`endParallelPromotion(ctx)`**, after the join, in worker order:
  1. For every worker and class, flush `pending_live` into `blocks_.meta(block).live_bytes` and
     `bm` into `alloc_stats_.bm` (as `flushCursor`).
  2. `cursor_[cls] = ctx.w[0].cur[cls]`.
  3. For w ≥ 1, if the cursor holds a block:
     - `nextFreeCell` from 0 finds a free cell → `requeueFront(cls, id)`: `alloc_state =
       kAllocQueued`; the id goes to `partial_[cls][--partial_head_[cls]]` when the head is > 0,
       else to `insert(begin)`;
     - no free cell → `alloc_state = kAllocNone`.

     Front, so the next minor's or the mutator's allocation reuses it before any virgin block
     (W6).
  4. `allocated_bytes += Σ pw.allocated_bytes`; `old_alloc_total_ += Σ pw.old_alloc_total`;
     `alloc_stats_` histogram += Σ.
  5. Validate: append the `cycle_alloc_log`s; **PM4** (no block outside `cursor_[]` is
     `kAllocCurrent`).
- **Invariant (HEAP_054 amended):** worker cursors exist only between begin and end. Outside that
  window at most one cursor per class exists, as today, so `startMark`'s `resetAllocCursors`,
  `detachFromAllocation` and `freeUniformCell` need no change.
- **Step 0 proves** that no rung-2..8 path calls `detachFromAllocation`, `freeUniformCell` or
  `syncCursorLiveBytes`, or reads `meta.live_bytes` of a `kAllocCurrent` block.
  - If one does, it would see a worker's unflushed `pending_live`, or miss a worker's cursor.
  - If Step 0 finds such a path, stop and redesign that rung. Do not patch around it.
  - In every build, `detachFromAllocation` aborts during a parallel minor when the block is
    `kAllocCurrent` and not `cursor_[cls].block`.

#### 3.8.5 The in-pause sweep slice

- Serial promotions run `lazySweep(cls, budget)` per promotion while `gc_phase_ == Sweeping`
  (F9). Workers cannot sweep without the mutex, and one sweep call per promotion under the
  mutex would serialise the drain.
- The parallel minor therefore runs **one slice before the drain**, on worker 0:
  `lazySweep(NUM_SIZE_CLASSES, prev_minor_promoted × per_alloc_budget)`, where
  `per_alloc_budget = sweep_work_budget / minor_sweep_divisor` (0 if the divisor is 0), and
  `prev_minor_promoted` is the previous minor's promoted count (an object counter, identical at
  every N).
- Swept cells land on the free lists before any promotion, so rung (2) can reuse them in this
  minor.
- This slice is where a large in-pause sweep would sit serially (TG2: worst 63 ms in one pause).
  It is timed (`rec->par_sweep_ns`) and reported in E2. Step 0 re-measures the in-minor sweep
  bytes on today's tree.
- Sweep completion (`gc_phase_ → Idle`) may happen at a different minor than at N = 1. That is a
  layout-class difference (P§3.15).

### 3.9 Large bodies and YLOS

- **Deferred large-body operations.** `lb_seen` (a to-space or promoted header was scanned) and
  `lb_promoted` (a header was promoted) are recorded per worker. After the join, worker 0 applies
  them in worker order: first every `promoteLargeHeader(body)`, then every
  `markLargeBodySeen(body, minor_color_)`.
  - This is the serial end state. Serial promotes first and then, on scanning the promoted copy,
    `markLargeBodySeen` finds nothing, which is a no-op.
  - Nothing reads the index during the drain, and `sweepNurseryLargeBodies` runs in the
    epilogue.
  - No lock is needed.
- **YLOS reach** (`reachYoungLargeP`) must decide at once: age it, or promote in place and scan.
  It runs under `ylos_mu_`, taken only after `mayBeYoungLarge(obj)` is true:
  - `youngLargeMeta`, then the colour test-and-set (reached this minor → return);
  - `promoteYoungLarge` or `age++`;
  - `ylos_*` stats go to the worker's `st`.

  Outside the lock, push `objEntry(obj, promoted ? 0 : 1)`.
  - A young YLOS object reached from an old parent is a PM5 violation, as in the serial
    `in_phase3_` branch.
  - The self-compile makes no large pointer allocations (TG4b), so contention is nil. The
    stress suite exercises it.

### 3.10 Interaction with a running mark cycle (5a–5c)

| concern | answer |
|---|---|
| promotions during a cycle must be allocate-black | worker cursors: `finalizeBitmapCellW` sets the bit (plain; own post-t0 block, IM13). Mutex rungs: the existing H1 atomic path. Same as serial |
| a background marker (5c) races the promotion writes | the same writes as serial promotion, now from several threads: cursor blocks are post-t0 (never read by a marker); mutex-rung writes to t0 blocks use `setMarkBitAtomic`; page-index, region and `BlockInfo` publication are the 5c H3–H5 atomics, and the mutex serialises the writers among themselves |
| minor workers vs background markers on cores | separate thread sets (5c trap 1): `GCMarkGang` for workers, `GCBackgroundGang` for markers. On a small box, `availableCpus()` counts both; E5 covers oversubscription |
| minor workers vs foreground mark slices | the slice runs after the nursery minor returns (F17); `GCMarkGang::run` is never nested |
| the t0 young walk | runs after the minor, serially, through `forEachSurvivor`, which skips fillers (P§3.5) |
| IM13 | `setCursorW` shares the check; PM4 adds "no stray Current block" |
| the validate-only YLOS reads (5b trap 7) | under `ylos_mu_` in the parallel path |

### 3.11 Shared-state audit (the template of 5c-P§3.6, for the copy path)

Every location a worker touches while others run. Step 0 re-derives it with the greps listed and
records any new site. The "rule" column is the whole of D4–D6.

| # | location | who writes during the drain | rule | grep |
|---|---|---|---|---|
| M1 | from-space header words | every worker | CAS claim, release publish, acquire load (P§3.3) | `hdr->tag == Tag_Forward\|Forward \*fwd` in `NurserySpace.cpp` |
| M2 | from-space object bodies | nobody (P1, mutator stopped) | read after winning the claim | — |
| M3 | slots of copies; root slots | the worker that scans the entry; roots only by worker 0 before the gang starts | owner-only | — |
| M4 | `tospace_top_` | every worker | atomic CAS; LAB interiors owner-only | `copy_ptr_\|copyToSpace` |
| M5 | worker cursor blocks: cells, bitmap words, `pending_*` | the owning worker; with N > 1 (chunked cursors, as built P§10.1) several workers share one block per class, each owning the chunks it claimed | owner-only per chunk: a chunk is a multiple of 64 cells, so it owns whole 64-bit bitmap words, the unit the scans read (`bitscan::loadWord` in `nextFreeCell`/`nextSetBit`; whole bytes would not do, CR-022); distinct blocks never share a word (F11: each bitmap is its own 64-byte-aligned arena slot) | `cursor_\[` |
| M6 | rungs 2–8 state: `free_lists_`, `partial_`/`partial_head_`, `unassigned_blocks_`, `blocks_.add`, page index, region bounds, sweep cursor and `gc_phase_`, `alloc_stats_`, shared `allocated_bytes`/`old_alloc_total_`, `in_decision_`, `cycle_alloc_log_` | the mutex holder | `promo_mu_`, **except `gc_phase_`**: it is written only under `promo_mu_` (a sweep that completes in a mutex rung sets `Idle`), but every worker reads it WITHOUT the lock for its allocate-black decision (`finalizeBitmapCellW`, and `finalizePoppedCellW` → `initObjectHeaderWithSize` after the unlock): a data race, and the decision can move from the pop to the finalize (CR-001) | `allocateFromSizeClassBitmap` callees; `gc_phase_` |
| M7 | `allocated_bytes`, `old_alloc_total_` on the fast path | — | per-worker deltas in `PromoWorker`, merged after the join | `allocated_bytes +=` |
| M8 | nursery `stats` (`GCStats`) | — | per-worker `MinorWorkerStats`, merged after the join | `recordSurvival\|recordPromotion\|stats\.` in `NurserySpace.cpp` |
| M9 | `large_body_index_`, `large_bodies_`, `nursery_owned_bodies_`, `free_large_body_ids_` | YLOS reach only | YLOS under `ylos_mu_`; header ops deferred (P§3.9) | `large_body_index_` |
| M10 | `young_large_scan_`, `promoted_buf_` | — | not used by the parallel path (greys / per-worker logs) | — |
| M11 | nursery bounds, `from_is_low_`, `heap_base_`, `promotion_age_`, `use_hybrid_dfs_`, `minor_color_`, `ylo_lo_/hi_` | nobody during the drain | read-only (growth and the recompute are in the epilogue) | `updateBounds\|recomputeYoungLargeBounds` |
| M12 | `in_phase3_`, `g_scan_parent/tag/size` (validate) | — | not used by the parallel path; `g_scan_*` become `thread_local` (diagnostic only; HEAP_053 concerns GC state, not diagnostics) | `g_scan_` |
| M13 | `promo_instr_` sampling (phase timers) | — | not sampled in the parallel path; the lock-wait timer replaces it | `promo_instr_` |
| M14 | GC helper pool jobs | helpers (decommit/populate) | unchanged: they touch no HPointer (HEAP_059/060) | — |
| M15 | 5c background markers | markers | unchanged (P§3.10) | — |
| M16 | `BufferMetadata::live_bytes` of the blocks promoted into (added 2026-09-29, CR-027) | every worker adds with a relaxed `atomic_ref` `fetch_add`: OUTSIDE `promo_mu_` in `flushCursorW` (chunked blocks are flushed by several workers) and `finalizePoppedCellW` (stashed cells), under it in allocate-black (`initObjectHeaderWithSize`); the mutex holder reads and writes it plainly (the empty-block flip `allocateFromEmptyRegularBlocks`, the shrink's `computeFragmentationStats`/`maybeShrinkCapacity` via a sweep completing in a mutex rung) | adds are atomic and commute; a plain reader must not run during the drain, so the shrink is deferred to the merge (`endParallelPromotion`). `promo_mu_` alone does not protect it: the lazySweep tail path that runs `onSweepComplete` inside the drain races the workers' adds (CR-014), and the flip races a worker's unflushed chunk (CR-016; CR-018 is the serial root) | `live_bytes` |
| M17 | the minor drain's `MinorWorker` slots (deque, private stack, `priv`) and its `SliceControl` (tickets, state word) (added 2026-09-29 from the M2 model) | every worker (own slot; others' deque `top` via `steal`); the control by RMWs | the 5b marker-loop protocol (`MarkWork.hpp`, `runMarkerLoop`): owner-only slot state, Chase–Lev steal, RMW-only state word; checked by TLA+ M2 (Drain) and GenMC W1/W2 | `MinorWorker\|minor_ctl_\|MinorRunArgs` |

**Anything not in this table that a worker reaches is a bug.** D8's `gc-heap-tsan` run is the
mechanical check.

### 3.12 Stats and measurement

- **`MinorWorkerStats`**: the `recordSurvival` / `recordPromotion` fields (F13), `ylos_*`,
  `lab_claims`, `direct_claims`, `claim_races` (CAS failures), `busy_waits`, `spine_splits`,
  `chunks`, `busy_ns` (phase-timer builds: loop entry to exit minus idle).
  - Merged in index order into `stats` and `ParMinorStats`.
  - Integer sums, so the order is immaterial, but keep it (5b trap 5).
- **`ParMinorStats`** (per heap; banner block "Parallel minor GC", printed when any minor ran
  parallel):
  - `minors_parallel`, `serial_small`, `serial_space`;
  - `workers_sum`, `filler_bytes_total`, `filler_bytes_max`, `alloc_end_capped`;
  - `lab_claims`, `direct_claims`, `claim_races`, `busy_waits`, `spine_splits`, `chunks`;
  - `steals`, `steal_aborts`, idle spins/yields/sleeps (from `ctr`);
  - `promo_mutex_acquires`, `promo_mutex_wait_ns`;
  - `imbalance_ns_sum` (Σ over minors of max − min `busy_ns`);
  - collector CPU (`GCMarkGang` `member_cpu_ns` delta over minors).
- **`MinorGCRecord`**, new fields: `workers`, `par_sweep_ns`, `par_roots_ns` (the serial root
  phase, which also keeps the per-scanner fields), `par_drain_ns`, `par_close_ns` (LAB close +
  merge), `filler_bytes`, `mutex_wait_ns`, `imbalance_ns`. `drain_tospace_ns` /
  `drain_promoted_ns` stay 0 on parallel minors.
- **Event log:** append the new columns to the minor row, and update
  `benchmarks/gc-event-log-summary.py` to print them. The object columns (survived, promoted,
  bytes) are rule 2's comparison surface.
- **Pauses, MMU, collector CPU and interference** come from the existing pause machinery; no
  change.

### 3.13 Validators (validate builds) and negative controls

| id | check | where |
|---|---|---|
| PM1 | **exactly once:** the to-space prefix walk (skipping fillers) counts objects and bytes equal to the merged survived count and bytes; `Σ promoted_log sizes` equals the merged promoted count | after the merge |
| PM2 | **no claim left:** no header word in `[fromBase(), bump_.ptr)` equals `kBusy` | after the merge (O(from-space), the pre-walk's cost class) |
| PM3 | **filler accounting:** the fillers found by PM1's walk sum to `filler_bytes_to_`, and every filler has `size ≥ 8`, `size % 8 == 0` | after the merge |
| PM4 | **cursor discipline:** after `endParallelPromotion`, every `kAllocCurrent` block is some `cursor_[cls].block` | `endParallelPromotion` |
| PM5 | **old parent, young child** (the serial `in_phase3_` assertion): in `evacuateP` / `reachYoungLargeP`, `parent_old` and the child stays young → abort, naming parent and child | during the drain |
| PM6 | **allocator accounting:** `allocated_bytes` after the merge minus before equals `Σ pw.allocated_bytes` + the mutex-rung charges, which the rungs add to a validate-only counter | after the merge |
| PM7 | **no shrink inside a promotion** (CR-014, `plans/threaded-gc-register-fixes.md` §4.1, 2026-09-30; **every build**, not only validate): `onSweepComplete` aborts with `[gc] FATAL: onSweepComplete inside a parallel promotion (CR-014)` if `par_promo_active_`; every sweep completion inside a promotion goes through `sweepCompleteInPromotion` | `onSweepComplete`, first statement |
| PM8 | **stashed cells are swept** (CR-002, register-fixes §4.3, 2026-09-30): a cell taken from a worker's stash lies in a `fully_swept` block, else abort `[heap-validate] CR-002: stashed cell of an unswept block` | `allocatePromotion`'s stash branch |

The existing validators run unchanged on parallel minors: V1, V2 (on the concatenated log), the
epilogue walks, IM4, IM13, and `validateEveryNthMinor`.

**Negative controls** (test hooks, written only while no minor runs):
- `test_minor_double_copy_every_`: every k-th claim-winner copies again into a fresh LAB slot
  and counts it. PM1 must fire.
- `test_minor_skip_filler_`: one retired LAB tail is left unformatted. PM3 or IM7 must fire.
- `test_minor_keep_worker_cursor_`: `endParallelPromotion` skips worker 1's return. PM4 must
  fire.

### 3.14 Configuration

| field / env | default | meaning |
|---|---|---|
| `gc_minor_threads` / `ECO_GC_MINOR_THREADS` (decimal 0..64; env wins over JSON) | **1** until Step 9 flips it (to 0 = auto if E2 passes) | 1 = serial reference; 0 = min(`gc_minor_threads_cap`, `availableCpus()`) |
| `gc_minor_threads_cap` | 8 (E2 decides) | cap for auto |
| `minor_lab_bytes` | 32768 (E3) | LAB size; must be a multiple of 8 in [4096, 1 MiB] |
| `minor_parallel_min_bytes` | 4 MiB (E4) | below this many from-space object bytes a minor runs serially |
| `minor_prefetch_children` | false (E3) | P§3.6 prefetch |

- `resolveMinorThreads(cfg)` copies `resolveMarkThreads` (F21). Parallel minors need
  `old_gen_bitmap_alloc` (the per-worker cursor is a bitmap cursor); otherwise 1.
- `GCMarkGang` is configured with `max(mark_threads_, minor_threads_)` members. Change the three
  reconfigure sites (F14) and add the minor site to use that maximum, through one helper
  `ensureGang(members, jitter)`.
- Add every field to `HeapConfigJson` (keys, parse, validate) and to `HeapConfig::validate`.

### 3.15 The determinism contract (GC_DET_001 amendment), and the rejected alternative

**Counter classes** (the E1 comparison uses this table; Step 0 completes it from the banner and
the event logs):

| class | examples | across N |
|---|---|---|
| object | minors; objects allocated; survived/promoted counts and bytes per tag; Custom arity buckets; per-minor event-log object columns; nursery grow events and size; t0 survivors and survivor object bytes; `alloc_end_capped` = 0 | **identical** (rule 2) |
| traversal | `ylos_reach_calls`, drain rounds, chunk counts, spine splits, steals | differ between the serial and parallel engines; not compared |
| layout | old-gen committed, blocks, virgin blocks, cursor refills, list pops, splits, sweep-on-demand hits, gap-sweep counters, `allocated_bytes`, per-block live, `major_live_`, old-gen peak, RSS, demotions, releases, compactions, P̂ | may differ at N > 1; E7 |
| decision (major sequence) | majors, their reasons and the minor at which each fires; per-cycle units | identical at N = 1 vs TG5c; at N > 1 a function of layout, judged by E7 |

**Why object counters cannot depend on majors.** A minor GC's work is fixed by:
- the mutator's allocation sequence (the same program);
- reachability from roots;
- ages;
- the object-byte trigger and growth rule (P§3.5).

A major GC does not move, age or free young objects. The t0 walk only reads them. YLOS
placement and chunk-chain bounds depend on nursery capacity, which is object-based. So a
different major sequence leaves every per-minor object record unchanged. Rule 2 relies on this
argument. E1 checks it end to end.

**Amendment text:** see P§8.

**Rejected: bit-identical majors at every N.** Two ways were considered:
- *Canonical decision inputs:* replace committed bytes and per-block live bytes in the triggers
  with layout-independent totals (Σ class-cell bytes of objects).
  - The committed-based triggers (GlobalPressure, Headroom, the GF denominator) are about real
    memory; a canonical proxy changes their meaning at the 4 GB budget.
  - It re-baselines the trigger that TG2 and 5c spent two phases taming.
- *Deterministic placement:* a nursery mark-compact (mark, per-chunk prefix sums, copy, fix-up)
  gives an address-ordered, schedule-free layout.
  - It costs an extra random-access pass per object: about 1.5–2× the serial pause at N = 1.
  - It drops hybrid-DFS spine contiguity.
  - It is a research project, not a phase.

The chaotic-trigger lesson ([[gc-trigger-is-chaotic]]) already says to judge majors on sweeps,
never on one run. **If the user wants bit-identical majors anyway, this section is the place to
reopen.**

### 3.16 §7.3 en-masse prefix promotion: measured, not built

- The premise is that ~91 % of the survivor prefix is live at the next minor. Step 0 recomputes
  it on today's tree from the minor event log: Σ promoted bytes(k+1) / Σ survived bytes(k) over
  consecutive minors.
- Record the figure and a go/no-go for a follow-up plan in P§10:
  - **go** if ≥ 85 % *and* E2 shows the promoted part of the drain scaling worse than the
    to-space part;
  - otherwise closed.
- The variant is not built in this phase. Its selling point, promotion without CAS, is smaller
  once claims are cheap and parallel. It also tenures ~2 GB/run of garbage, which the retention
  gate would have to absorb.

---

## 4. Steps

Every step ends with `cmake --build build --target check` green (C++-only steps), or `full` where
the step says so. Steps 1–8 also build the validate tree's `test` target and run the phase's tests
there. Run tests once, tee to `/tmp/test_output.txt`, and grep the file (CLAUDE.md).

**Before you start:** `benchmarks/lss-loop-snap.sh verify keep-TG5c`; snapshot `try-TG6-pre`.

### Step 0 — facts, baseline, audits (no code change except temporary counters)

1. Re-verify F1–F26 and fix the line numbers in P§2.
2. **Same-session baseline** with `eco-optTG5c`, strictly serial on an idle machine:
   - a stats-build triple: wall, GC, minor, majors, peak, RSS, out.mlir md5;
   - one phase-timer run with `ECO_GC_EVENT_LOG`: record the minor anatomy (the TG00 §4 table
     re-measured: stack walk, roots per scanner, `drain_tospace_ns`, `drain_promoted_ns`,
     `lazy_sweep_bytes`/`est_ns`, `promo_alloc_est_ns`, minflt), the pause distribution, and the
     top-10 minors by pause with their survived/promoted bytes.
3. **Ladder census during minors** (temporary counters in `allocateFromSizeClassBitmap`, removed
   after): promotions served per rung (1–8); promotions made while `gc_phase_ == Sweeping`, with
   their sweep bytes; promotions whose size has no class (bag path). This prices `promo_mu_`: if
   rungs 2–8 serve > 2 % of promotions, D7b is likely needed.
4. **Large-body census:** `markLargeBodySeen` and `promoteLargeHeader` calls per minor (the
   deferred lists' size).
5. **Audit greps:**
   - P§3.11 M1–M15: record every hit;
   - callers of `detachFromAllocation`, `freeUniformCell`, `syncCursorLiveBytes` and
     `meta(...).live_bytes` reachable from rungs 2–8 (P§3.8.4; expected: none);
   - `->color` readers of forwarded or young objects (P§3.3.1);
   - writers of `->color` on nursery objects (expect: none but the copiers).
6. **Prefix liveness** from the event log (P§3.16).
7. **Counter classes:** list every banner and event-log counter under the four classes of P§3.15.
   The list becomes E1's comparison script (`benchmarks/tg6-compare.py`: object-class columns must
   match exactly; it prints the layout-class and decision-class deltas).
8. Record everything in P§10.1. **Stop and revise the plan** if item 5 finds a rung that reads a
   Current block's live bytes, or if item 3 shows rung 2 serving > 20 % of promotions (the mutex
   would serialise the drain; D7b becomes mandatory and moves before Step 6).

### Step 1 — D1: the serial minor, refactored for fillers (counters bit-identical)

1. `getObjectSizeFromHeader(const Header&)`; `getObjectSize` wraps it (P§3.3.2).
2. Split `NurserySpace::minorGC` into `minorPrologue`, `minorGCSerial` and `minorEpilogue`. It is
   a move, with no statement changes: locals shared across the parts (`from_space_used`,
   `gc_start`, the timer lambda state, `surv0`/`prom0`, `promo0`, `flt_*`, `t_loop_exit`) go
   into one `MinorFrame` struct passed by reference.
3. `filler_bytes_`, `filler_bytes_to_` (0 in the serial path), `objectBytesAllocated()`, and
   every row of P§3.5's table. `pm.alloc_end_capped` lives in a new `ParMinorStats` (zeroed; the
   banner block is not printed yet).
4. `forEachSurvivor`, `censusRecord` and `censusCheck` skip `Tag_Free`. `bytes_out` = object
   bytes.
5. Tests (`test/allocator/NurseryFillerTest.cpp`):
   - `testFillerSkippedBySurvivorWalk`: after a minor, a test hook
     (`test_append_filler_after_minor_`, bytes k) moves `bump_.ptr` and `survivor_end_` by k and
     writes a Tag_Free filler at the old end, adding k to `filler_bytes_`. Then
     `forEachSurvivor` visits the same objects and object bytes as without the hook.
   - `testTriggerCountsObjectBytes`: the same allocation script with and without a 64 KiB
     filler. The next minor GC fires after the same number of allocated bytes (compare
     `minor_gc_count` after each allocation).
   - `testGrowthCountsObjectBytes`: the same survivor volume with and without fillers grows the
     nursery at the same minor.
   - `testFailSoftUsesObjectBytes`: survivors at 96 % of capacity plus a filler. Fail-soft
     engages exactly as without it.
   - `testAllocEndCappedCounted`: a filler so large that `threshold + filler` passes the extent.
     `alloc_end_capped` increments and the end is the extent end.
6. **Gate:** unit, E2E (`full`), and a stats self-compile. Every counter and both event logs'
   non-timing columns identical to `eco-optTG5c`; `out.mlir` identical. If minor time moves with
   identical instructions in the drain, check the alignment trap first.

### Step 2 — D2: configuration and reporting (counters bit-identical)

1. P§3.14: fields, validation, JSON keys, `ECO_GC_MINOR_THREADS` (a copy of the
   `ECO_GC_MARK_THREADS` parser), `resolveMinorThreads`, `minor_threads_` cached at
   initialize/reset, and `ensureGang(max(mark, minor))` at the four sites.
2. `ParMinorStats` in full, the banner block, the `MinorGCRecord` fields, the event-log columns,
   and `gc-event-log-summary.py`.
3. Tests: `testMinorThreadsConfigParse` (JSON and env, env wins, 0 = auto honours the cap, bitmap
   off → 1); `testGangSizedForMinorAndMark` (mark 2, minor 6 → gang members 6).
4. **Gate:** as Step 1 (every field is still inert at the default of 1).

### Step 3 — D3: `MinorWork.hpp` and the TSan harness

1. `runtime/src/allocator/MinorWork.hpp`, std-only, namespace `Elm::minorwork`:
   - word helpers: `kTagForward`, `kBusy`, `fwd(addr, color)`, `isForward(w)`, `fwdAddr(w)`,
     `colorOf(w)`;
   - `claim(std::atomic_ref<uint64_t>, uint64_t& h) → bool` (CAS h → kBusy, acq_rel/acquire;
     updates h on failure);
   - `publish(ref, dst, color)` (release store);
   - `waitPublished(ref, counters) → uint64_t` (acquire loads with `markwork::backoff`);
   - `Lab { char* ptr; char* end; }` and `labAllocate` / `tospaceClaim` / `tospaceClaimLab` /
     `closeLab` (P§3.4), with a filler writer passed as a template functor (the harness writes
     its own synthetic filler, the heap writes Tag_Free).
2. `test/gc-helper-tsan/minor_harness.cpp`, and add it to that CMake project:
   - **Synthetic heap:** a from-space arena of objects `{uint64_t header; uint64_t slot[k]}`. The
     header uses the real bit layout: tag, size in words, an age bit. `k` is 0–8, with 3 % of
     objects at 2,000 slots (chunked at 1,024). Slots point to other objects, a synthetic "old"
     region, or constants. There are shared subgraphs, long chains (Cons-like, 10,000 long),
     and cycles.
   - **Copier:** `evacuate` on the real claim/publish/LAB code; objects with the age bit go to a
     synthetic "old" bump arena through a mutex-guarded allocator, the rest to to-space LABs;
     chains copied in runs of 512 with a count-based heads pass. It runs through the real
     `markwork::runMarkerLoop` with a harness Env.
   - **Checks, after each run:**
     - (a) every object reachable from the roots was copied exactly once (a from→to map
       built from the forward words; the copy count equals the reachable count);
     - (b) every slot of every copy and every root points to a copy or to old/constant, never
       to from-space;
     - (c) no word equals `kBusy`;
     - (d) the to-space prefix parses (objects and fillers) up to the top, and the fillers sum
       to the reported waste;
     - (e) the copied multiset of objects (payload checksums) equals the reachable multiset;
     - (f) no TSan report.
   - **Runs:** n = 1, 2, 4, 8, 16, with jitter 0 and 50 µs, 200 heaps each (random seeds), and
     LAB sizes 4 KiB and 32 KiB. Then all again under `taskset -c 0,1`.
3. **Pass:** the harness exits 0 with no "WARNING: ThreadSanitizer", three runs.

### Step 4 — D4: promotion buffers in `OldGenSpace`, exercised serially

1. `PromoWorker`, `PromoCtx`, `promo_mu_`; `cursorAllocate` / `finalizeBitmapCell` refactored to
   take `(AllocCursor&, Acc*)`; `setCursorW` (IM13), `refillCursorW`, `startVirginBlockW`,
   `ladderFrom2`, `allocatePromotion`, `requeueFront`, `beginParallelPromotion`,
   `endParallelPromotion` (P§3.8); PM4 and PM6; the `detachFromAllocation` guard.
2. A test switch `test_serial_promo_via_ctx_`: the **serial** minor wraps its drain in
   `begin/endParallelPromotion(1, ctx)`, and its three copiers call `allocatePromotion(ctx.w[0],
   size)` instead of `allocate(size)`.
   - At n = 1, worker 0 owns `cursor_[]`, and the ladder order is unchanged.
   - `allocatePromotion` with n = 1 also runs F9's per-promotion lazy-sweep slice, to keep
     identity in this step only.
   - The layout is then identical to serial, and so is every counter.
3. Tests (`test/allocator/PromoBufferTest.cpp`):
   - `testPromoViaCtxMatchesSerial`: the same heap script with the switch off and on; every
     counter, old-gen block list and bitmap identical;
   - `testWorkerCursorReturnedToFront`: two worker contexts each take a block of class c; after
     `endParallelPromotion` both partial blocks sit at the front of `partial_[c]`, ahead of the
     previous queue, and the next `cursorAllocate` takes worker 1's block;
   - `testWorkerCursorIm13`: in a cycle, a worker cursor offered a t0 block aborts in validate
     (death test);
   - `testLadderUnderMutexAccounting`: a worker context forced through rungs 2, 4, 5 and 7;
     `allocated_bytes` after the merge equals the serial run's (PM6).
4. **Gate:** unit, E2E, and a stats self-compile with the switch set through a test-only env
   `ECO_TEST_PROMO_VIA_CTX=1` (compiled only in stats builds). Every counter identical to
   `eco-optTG5c`.

### Step 5 — D5: the parallel engine on one worker

1. `NurseryParallel.cpp`:
   - `MinorWorker`, `MinorEnv`, `evacuateP` / `evacuateJitP` / `evacuateValueSlotP`,
     `scanEntryP`, `spineRun`, `reachYoungLargeP`;
   - the deferred large-body lists;
   - `minorGCParallel` with the gang call replaced by a direct `runMarkerLoop` on worker 0 when
     n = 1;
   - `thread_local` for `g_scan_*`; PM1–PM3 and PM5.
2. A test switch `test_force_parallel_engine_` (and stats-build env
   `ECO_TEST_MINOR_ENGINE=P`) runs `minorGCParallel` with n = 1. That means:
   - LABs, fillers (only the final tail, trimmed at the top, so none), and claims (uncontended);
   - DFS order and spine runs;
   - the pre-drain sweep slice instead of per-promotion sweeping.
3. Tests (`test/allocator/ParallelMinorTest.cpp`, engine at n = 1):
   - `testEngineEveryTagSurvives`: one object of every tag with children, each reachable only
     from a root, over 3 minors (survive, promote, then old). Contents are checked through the
     mutator API after each minor;
   - `testEngineLongListRuns`: a 100,000-element list of boxed Ints and one of unboxed Ints;
     after 2 minors every element is intact; `spine_splits` = ceil(100000/512) − 1 on the first
     minor;
   - `testEngineSharedTailList`: two lists sharing a tail of 1,000 cells; the tail is copied
     once (PM1) and both heads reach it;
   - `testEngineChunkedArray`: a 16,000-element boxed array; `chunks` = 15; every element
     forwarded;
   - `testEngineLargeBodies`: a young LargeStringHeader surviving, and another promoted; bodies
     alive, the index as after a serial minor;
   - `testEngineYlos`: a YLOS array (above the nursery cap) holding young objects, aged then
     promoted in place;
   - `testEngineBuilderStaysYoung`: a builder chunk chain survives 3 minors, never promoted, with
     age 0;
   - `testEngineMatchesSerialObjectCounters`: a random-graph mutator script (the
     `HeapGenerators`) run twice, serial and engine. Every per-minor object counter (P§3.15
     object class) is identical.
4. **Gate:** unit; E2E with `ECO_TEST_MINOR_ENGINE=P` (stats build, `full`); the validate tree
   (unit + E2E + stress) with the engine forced. Object counters on a self-compile identical to
   `eco-optTG5c` (layout class free).

### Step 6 — D6: go parallel

1. `chooseMinorWorkers` (P§3.2); root distribution; `GCMarkGang::run(minorWorkerEntry, …)`; LAB
   close and trim; merge; `endParallelPromotion`; the `rec` fields.
2. The pre-drain sweep slice (P§3.8.5). `allocatePromotion` no longer sweeps per promotion at
   n > 1.
3. Tests (`ParallelMinorTest.cpp`; config pins `gc_minor_threads` and
   `minor_parallel_min_bytes = 0`; gang reconfigured through `shutdownForTesting` in the test
   helper):
   - every Step 5 test again at n = 2, 4 and 8;
   - `testParMinorObjectCountersAcrossN`: the random-graph script at n = 1 (serial), 2, 4, 8
     and 4 + jitter 50 µs, 20 minors each; per-minor object counters identical;
   - `testParMinorStealing`: one root holding a 50,000-element boxed array of fresh tuples, n =
     4; `steals > 0` and every worker's copy count > 0;
   - `testParMinorFallbackSpace`: survivors at 97 % of capacity; the minor runs serially
     (`serial_space` + 1), with no fillers;
   - `testParMinorFallbackSmall`: `minor_parallel_min_bytes` = 1 MiB, a 100 KiB nursery; serial;
   - `testParMinorFillersParse`: after a parallel minor with LAB 4 KiB, `forEachSurvivor` visits
     exactly `survived` objects and `filler_bytes_ > 0`;
   - `testParMinorDuringCycle`: a 5c cycle running with B = 2 background markers and a 4-worker
     minor at each step; IM1/IM4/IM13 are quiet and the handoff reclaims the same bytes as at
     n = 1 on the same script (live bytes are a layout-class figure; compare **marked object
     counts**);
   - `testParMinorForkChild`: fork after a parallel minor; in the child, a parallel minor works.
4. **Gate:** unit at n ∈ {1, 4}; `full` E2E at `ECO_GC_MINOR_THREADS=4` (stats build);
   stress (default and pressure configs) at 4. Zero `[heap-validate]` lines in the validate tree
   at 4.

### Step 7 — D7: validators, negative controls, the validate tree

1. PM6 wiring, the three negative controls (P§3.13), and death tests that each control fires.
2. The validate tree: unit, E2E and stress (default and pressure configs), each at
   `ECO_GC_MINOR_THREADS` ∈ {1, 4, 8}, plus 8 with `ECO_GC_HELPER_JITTER_US=50`. Zero
   `[heap-validate]` lines.
3. `ECO_NURSERY_POISON=1` validate stress at 8: the zeroing tripwire must stay quiet. Fillers
   are unreachable, so poisoned tails are never read.

### Step 7b — D7b (conditional): batched free-list pops

Build only if E2 (Step 9) shows `promo_mutex_wait_ns` > 5 % of `par_drain_ns` at the chosen N,
or Step 0 item 3 showed rung 2 > 2 % of promotions. Then:
- Under `promo_mu_`, rung 2 pops up to 32 cells of class c into `pw.stash[c]` (a small array).
  Allocation checks the stash right after the cursor (still rung 2's position in the ladder).
- `endParallelPromotion` pushes unused stash cells back with the free-list push used by
  `lazySweep` (`pushCoalescedFreeCell` with the owning block and id), in stash order.
- Test `testStashReturnsCells`: a forced rung-2 minor; after the merge, every stashed but unused
  cell is back on its class list with a valid back-link (HEAP_052 validator).
- Re-run E2's finalist arm.

### Step 8 — D8: `gc-heap-tsan`

Extend `test/gc-heap-tsan/heap_driver.cpp`: a mutator script that runs 200 minors at
`gc_minor_threads` 4, with a 5c cycle (B = 2) running across 60 of them, under g++ TSan. Pass:
no reports, three runs, one under `taskset -c 0,1`.

### Step 9 — measurement and the default

E0–E9 (P§5). If the decision rules pick a cap, a LAB size, a threshold and the prefetch setting:
- set `GC_MINOR_THREADS = 0` (auto), `GC_MINOR_THREADS_CAP`, `MINOR_LAB_BYTES`,
  `MINOR_PARALLEL_MIN_BYTES`, `MINOR_PREFETCH_CHILDREN`;
- rerun every gate default-on, and the bootstrap fixed point.

### Step 10 — docs, invariants, tracking

- P§8's invariant rows land.
- THEORY.md (and the matching `design_docs/theory/` child): the minor-GC item gets N workers,
  claims, LABs and fillers, and object-byte accounting.
- `design_docs/parallel-gc.md` §7.2: an as-built note.
- The master plan: the phase 6 row and the §5 pause table.
- Loop entry `TG6` in `benchmarks/gc-opt-loop.md`.
- Snapshot `keep-TG6`, `bin/eco-opt-prev` = `eco-optTG6`.
- Memory: update the index entry.

---

## 5. Measurement and experiments

All self-compile arms follow the 5b/5c method:
- one phase-timer binary, with arms selected by `ECO_GC_MINOR_THREADS` / `ECO_HEAP_CONFIG`;
- env values and config paths of **equal length** across arms ("counters are a program input",
  TG3);
- runs strictly serial on an idle machine;
- the artifact verified by md5, never by the exit code.

The default 5c configuration runs throughout (background marking on).

**E0 — reference (after Step 4).** `gc_minor_threads = 1` vs `eco-optTG5c`, a stats-build pair:
every counter and both event logs identical (rule 1).

**E1 — determinism (after Step 7).** One run each at `ECO_GC_MINOR_THREADS` ∈ {1, 2, 4, 8, 0}
and 8 + `ECO_GC_HELPER_JITTER_US=50`. `benchmarks/tg6-compare.py`:
- the **object class is identical**, per minor and in total. Any difference stops the phase;
- `alloc_end_capped` = 0 in every arm;
- it prints the layout- and decision-class deltas, which are recorded, not gated.

**E2 — scaling (after E1).** N ∈ {1, 2, 3, 4, 6, 8, 12, 16}, one run each; a triple for the
finalists. Per arm:
- minor pause p50/p99/max, all-pause p99/max, MMU at 10/20/50/100/200 ms;
- minor GC total, `par_drain_ns` total, `par_roots_ns`, `par_sweep_ns`, `par_close_ns`;
- wall, GC time, mutator CPU outside pauses (5c's figure);
- collector CPU; idle share; steals; `claim_races`; `busy_waits`; imbalance;
- `promo_mutex_wait_ns`; filler bytes; old-gen peak; RSS; majors.

**Decision rule for the cap:** the smallest N whose median minor GC total is within 10 % of the
best N's *and* whose worst pause is within 10 % of the best N's. An arm whose collector-CPU per
second of pause saved is over 3× the N = 4 value is disqualified.

**E3 — LAB size and child prefetch (after E2, at the chosen N and at N = 1 with the engine).**
LAB ∈ {8, 32, 128} KiB × prefetch ∈ {off, on}, one run each and a triple for the winner. Pick
the fastest minor total whose filler total is ≤ 1 % of survived bytes. Prefetch ships only if it
wins at both N (the mark-loop lesson: the ring gives look-ahead only if the loads are the
misses).

**E4 — the serial threshold.** `minor_parallel_min_bytes` ∈ {0, 1, 4, 16} MiB on the pressure
config (many small minors) and one self-compile. Pick the smallest value at which the small
minors' p50 is not worse than serial.

**E5 — oversubscription.** `taskset -c 0,1` with N = 8 vs N = 2 (background markers on). The
8-thread run must not be > 20 % slower in wall or in minor max than the 2-thread run. A hang or
collapse fails the phase.

**E6 — interference with background marking.** At the chosen N: `conc_mark` 2 vs 0 (equal-length
env). Minor pause p99 inside cycles vs outside, and mutator CPU. Informational: record whether
background markers slow parallel minors.

**E7 — retention and the major sequence (the rule-3 gate).** A gf sweep (0.65 / 0.70 / 0.75) at
N = 1 and at the chosen N, one run per point, then triples at 0.70:
- **gate on old-gen peak first** (M§2 retention rule): the sweep-median peak at N must be within
  +3 % of N = 1's, and no single point above N = 1's sweep max;
- majors within ±1 at every point;
- max RSS within +3 %;
- record every point's deltas. The trigger is chaotic: judge sweep medians, never one point.

**E8 — small heap and stress.** The 4 GB-cap pressure config at the chosen N: E2E, stress 101/101
with ≥ 1,000 minors, and the E10 tight-cap run of 5c (a `max_heap_size` 15G self-compile). Peak as
a % of cap within +2 points of N = 1.

**E9 — mutator locality.** Mutator CPU outside pauses at the chosen N vs N = 1, from the E2
triples. DFS copy order plus spine runs replaces Cheney BFS plus whole-spine DFS. More than +1 %
mutator CPU is recorded as a finding and becomes a follow-up (for example LIFO vs FIFO grey order
or a larger `kSpineRun`); it is not a blocker if wall still wins.

**What to watch:**
- **The serial remainder.** At N = 8 the drain may shrink below the root phase plus the sweep
  slice plus the epilogue. E2 prints them separately, and the worst pauses should be read with
  their parts.
- **Claim races on hot shared objects.** Many parents point at a few objects (interned
  constants, shared type terms). `busy_waits` counts them. A high rate with rising N is the
  signal.
- **Promotion-mutex convoying** at refills: `promo_mutex_wait_ns`.

---

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` | all pass at `gc_minor_threads` ∈ {1, 4} (config-pinned) |
| G2 | elm-tests | the reference set (13,565 / 12) |
| G3 | `--target full` | all pass, default configuration and at `ECO_GC_MINOR_THREADS=8` |
| G4 | stress (default and pressure configs) | 101/101 at 1, 4 and 8; ≥ 1,000 minors on the pressure config |
| G5 | validate tree | zero `[heap-validate]` lines on unit, E2E and stress at 1, 4, 8 and 8 + jitter; the three negative controls fire; poison stress quiet |
| G6 | stats-off `ecoc` | builds; parallel minors work without stats |
| G7 | E0 | rule 1 |
| G8 | E1 | rule 2: the object class identical across N and jitter; `alloc_end_capped` = 0 |
| G9 | TSan | `minor_harness` and `gc-heap-tsan` exit 0 with no TSan warnings, including under `taskset -c 0,1` |
| G10 | E2–E9 | decision rules recorded in P§10; E7's retention rules pass |
| G11 | bootstrap fixed point | the default-on compiler reproduces itself; `out.mlir` byte-identical across N |
| G12 | static | `grep -n "hardware_concurrency" runtime/src/allocator` empty; `minorGCSerial` differs from the `keep-TG5c` drain only by the D1 extraction (`diff` of the function bodies recorded in P§10) |

---

## 7. Traps

1. **Never give minor workers `markers_[]` deques.** A 5c episode steals from every mark slot
   (F16) and would scan a to-space copy as an old-gen object.
2. **Claim first, copy second, publish last.**
   - Copying before the CAS forces an allocation undo (P§3.3.1).
   - Today no worker reads *through* a forward word during the drain: readers only store the
     address. So publishing early would not break this phase. It would break the first reader
     that does read through one (a validator, or 7c). Keep the order, and keep the release store.
3. **Compute the size from the saved header.** After the claim, `getObjectSize(obj)` reads
   `kBusy` and returns 8 (Tag_Forward's size). Every size in the parallel copiers comes from
   `getObjectSizeFromHeader(h)`.
4. **Carry the colour bits into the forward word** (W2 item 23). Compose from `h`, never from
   zero.
5. **The heads pass counts cells.** "Stop when the next cell is not in to-space" wanders into
   another worker's copies (§7.2). It would not crash: it would double-scan or skip heads.
6. **A truncated run pushes its last cell and leaves it out of the heads pass**, or that head is
   scanned twice. Twice is harmless for correctness, but PM1-style scan counting and the
   traversal counters then lie.
7. **Fillers are objects to a walker and bytes to nobody.** Every prefix walker skips them for
   object purposes (P§3.5 table). A new walker added later must too: IM7 and PM3 catch the miss.
8. **The trigger must use object bytes, or rule 2 fails from the second parallel minor on.** A
   single mismatched user (for example a stat reading `bytesAllocated()`) shows up as a
   per-minor diff in E1. Grep `bytesAllocated\|bump_.ptr - fromBase` in Step 1.
9. **Mutex-rung writes of `allocated_bytes` are fine; fast-path writes are not.** The rule is
   "fast path → `pw`, under the lock → shared". Moving a rung out of the lock without moving
   its accounting is a data race that TSan finds and a counter diff does not (layout class).
10. **Return worker cursors to the front of `partial_`, not the back.** At the back, the mutator
    and the next minor would start virgin blocks first: the W6 inversion (+77 s once).
11. **The per-promotion sweep does not exist at N > 1.** Do not re-add it under the mutex "for
    identity": it serialises the drain. Its total budget moves to the pre-drain slice.
12. **Deferred large-body order is promote-all, then mark-seen.** Reversed, a promoted header's
    body would be recoloured and then erased: harmless today, but it would read a freed id slot
    after `free_large_body_ids_` reuse.
13. **Counters are a program input** (TG3): compare arms with equal-length env values (`1` vs
    `4`, never unset vs set). Unit tests ignore `ECO_GC_*` after the first init: pin in configs
    (F23).
14. **The gang serves marking too.** `GCMarkGang::configure` is first-call-wins. Size it for
    `max(mark, minor)` everywhere (P§3.14), or the first minor with more workers than markers
    aborts in `run`.
15. **Fork** only happens outside pauses, so a child never inherits a running minor (5b trap 12).
    `minor_workers_` state is re-initialised at each minor, and deque arrays are retired only
    after the join.
16. **The alignment trap.** `cursorAllocate` / `finalizeBitmapCell` gain a parameter in Step 4.
    If promotion time moves with identical instructions, check the loop address first
    ([[gc-mark-loop-alignment-trap]]).

---

## 8. Invariants (land in Step 10)

- **HEAP_067 ParallelMinor (new):** "WITH gc_minor_threads > 1 THE COPY PHASE OF A MINOR GC RUNS
  ON N WORKERS (plans/threaded-gc-06-parallel-minor.md): the paused mutator as worker 0 and N−1
  GCMarkGang threads, started and joined inside the minor pause; the root phase stays serial on
  worker 0. A from-space object is copied exactly once: a worker CASes its header word from the
  observed header to BUSY (Tag_Forward with forward_ptr 0), copies the body, writes the copy's
  header from the saved word, then publishes the forward word (Tag_Forward, the original colour,
  the address) with a release store. Readers load headers with acquire and wait out BUSY. Young
  survivors go to per-worker to-space LABs claimed from an atomic top; promoted objects to
  per-worker AllocCursors (HEAP_054) or, below rung 1, under the promotion mutex. Grey entries
  are markwork entries in per-worker private stacks and Chase–Lev deques driven by
  markwork::runMarkerLoop with kDrainBudget; list spines are copied in runs of kSpineRun with a
  count-based heads pass; boxed arrays over MINOR_CHUNK_ELEMS are chunked. Large-body index
  updates are deferred to worker 0 after the join; YLOS reaches run under a mutex. gc_minor_threads
  = 1 runs the serial Cheney path unchanged. Validators PM1–PM6."
- **HEAP_068 NurseryObjectBytes (new):** "THE NURSERY SURVIVOR PREFIX MAY CONTAIN FILLERS, AND
  NURSERY POLICY COUNTS OBJECT BYTES. A parallel minor turns LAB tails into Tag_Free fillers
  (header.size = bytes) inside the to-space prefix; filler_bytes_ records them. The minor-GC
  trigger (computeAllocEnd), the fail-soft test, nursery growth (checkAndGrow),
  isNurseryNearFull and the minor stats use object bytes = prefix bytes − filler bytes. Every
  survivor-prefix walker skips Tag_Free (forEachSurvivor, the P1 census). A parallel minor runs
  only when S + S/32 + N·lab ≤ capacity (S = from-space object bytes), so to-space cannot
  overflow."
- **HEAP_006:** "… a BUSY word (Tag_Forward, forward_ptr 0) marks an object being copied by a
  parallel minor worker (HEAP_067); like forwarding words it exists only inside a minor pause."
- **HEAP_007:** "… GCMarkGang members may, inside the owner's minor pause and joined before it
  ends, claim and copy from-space objects, write to-space LABs and their own promotion-cursor
  blocks, and take the promotion mutex for the rest of the ladder (HEAP_067)."
- **HEAP_042:** "… during a parallel minor the to-space top is an atomic claimed by LABs; the
  survivor prefix is then objects and Tag_Free fillers (HEAP_068)."
- **HEAP_054:** "… inside a parallel minor each worker owns one cursor per class; worker cursors
  exist only between beginParallelPromotion and endParallelPromotion, obey IM13, and are
  returned to the FRONT of partial_[class] (or retired when full); outside that window at most
  one cursor per class exists."
- **HEAP_064:** "GCMarkGang also runs parallel minor workers (HEAP_067); it is sized for the
  larger of gc_mark_threads and gc_minor_threads."
- **GC_DET_001 (amended):** "threaded-gc-06 (HEAP_067): with gc_minor_threads > 1, WHICH
  old-gen cell or to-space address a copy receives depends on the copy schedule. Object-level
  quantities — every minor's survived/promoted counts and bytes, per-tag totals, the object-byte
  trigger and nursery growth (HEAP_068), objects allocated — are identical at every
  gc_minor_threads and under ECO_GC_HELPER_JITTER_US. Decisions that read old-gen placement
  (committed bytes in GlobalPressure/Headroom/the garbage-fraction denominator, per-block live
  fractions for demotion, release and compaction, allocated_bytes via path-dependent charges)
  are schedule-dependent at N > 1 and are judged by distribution (plan E7), not identity. No
  decision reads worker progress. gc_minor_threads = 1 is the exact reference."

---

## 9. Forward notes

- **Phase 7b/7c (concurrent tenuring)** adds a collector thread that promotes a survivor region
  while the mutator runs.
  - The promotion buffers (`PromoCtx`, the mutex ladder, front requeue) are its old-gen
    allocator as they are. The collector is one more `PromoWorker`, outside a pause, so it needs
    5c's H-rows for its cursor blocks (IM13 holds for it too).
  - The claim protocol does **not** carry over: the mutator runs during 7c, so forwarding moves
    off-header (FORBID_HEAP_004, H-hdr).
  - The object-byte accounting (HEAP_068) carries over directly: survivor regions are prefixes
    with gaps.
  - The P§3.11 table is the template the 7c audit extends.
- **Phase 8:**
  - the pre-drain sweep slice and the root phase are the serial remainder. A block-claim
    parallel sweep (report §6.2 / HB 14.3) and a CellStore dirty-chunk scan are the items that
    would shrink it;
  - if E1's prefix-liveness go/no-go was "go", the §7.3 variant becomes a phase-8 plan.
- **Deterministic placement** (P§3.15) stays recorded as the route to bit-identical majors,
  should that become a requirement.

## 10. As-built deviations

Implemented 2026-09-27 against `keep-TG5c` (snapshot `try-TG6-pre` before any change, `try-TG6`
after). Candidate binaries are `ecoTG6base.mlir` (md5 933c3ff0d288…, the MLIR `eco-optTG5c` builds
itself to) lowered against the phase-6 runtime.

### 10.1 Step 0 facts, audits, and design deviations

**Facts that differed from P§2:**
1. **`eco-optTG5c` predates 5c's paced-LiveBudget default flip.** Its self-compile has 7 majors and
   an 8,936 MB peak (the 5c "C" arm). A binary built from the `keep-TG5c` sources has 8 majors and
   9,251 MB (the "P" arm). With `major_gc_live_budget_paced` pinned off in both arms by the same
   JSON file, the Step 1+2 candidate matched `eco-optTG5c` on **every** counter, decisions
   included (`tg6-compare.py --all`). E0 comparisons therefore pin paced off in both arms.
2. **F5 is wrong for small `alloc_buffer_size`.** A nursery object can be larger than a block
   when `alloc_buffer_size` is below the nursery's large-pointer cap (32 KiB blocks in the test
   geometries; never at the 512 KiB default). The serial path promotes it through
   `allocateLargeBlock`. `allocatePromotion` now does the same under the lock, and
   `allocateFromEmptyRegularBlocks` skips worker-owned (Current) blocks during a parallel minor.
3. **A lazy sweep can finish inside a promotion.** `lazySweep` → `onSweepComplete` → shrink reads
   `live_bytes` and may release blocks. With worker cursors holding unflushed `pending_live`, the
   shrink could release a live cursor block. As built: at N = 1 the worker's accounting and
   cursors are handed back and `onSweepComplete` runs in place (this keeps the Step 4 identity
   exact); at N > 1 it is deferred to `endParallelPromotion`, after the flush.
4. **Audit (P§3.11).** No rung-2..8 path calls `detachFromAllocation`, `freeUniformCell` or
   `syncCursorLiveBytes`, except the large-block path of fact 2 (guarded). `detachFromAllocation`
   now aborts in every build if it meets a Current block during a parallel minor.
5. **Colour.** No reader depends on a copy's or a forward word's colour. Nursery objects are
   White; the unified "copies are White" fixup is bit-identical in effect.
6. **Ladder census (Step 0 item 3, from the banner).** Of ~676 M promotions, cursors serve all but
   ~0.12 %: 728 k free-list pops, 82 k splits, 37 k virgin blocks, 12 k refills, 0 sweep-on-demand
   hits.
7. **Large bodies.** The self-compile makes one pointer-free large allocation and no YLOS object.

**Design deviations:**
1. **`minorGC` is not split into three functions.** The serial roots-and-drain core is wrapped in
   `if (par_n != 0) minorGCParallel(...) else { … }` without re-indenting, so the serial code is
   textually unchanged. The prologue and epilogue stay inline.
2. **The Chase–Lev element store/load became release/acquire** (`MarkWork.hpp`). A parallel
   minor worker scans a copy the pushing worker just wrote. The paper's release fence already
   orders that, but TSan does not model stand-alone fences and reported it. On x86 both are
   plain moves; the fences stay; the 5b mark harness still passes.
3. **Idle workers wake only for stealable work** (`MinorEnv::anyWork` ignores private stacks).
   5b's `anyWork` counts private stacks. Here that made every idle worker wake, fail to steal and
   re-idle in a tight loop while one worker walked a long chain. That bounced the busy worker's
   `priv` line and the ticket/state words: 5–40× slower than serial on such minors (seq
   1836–1845), growing with N (N = 16: 1.36 s against a 38 ms serial). Termination is unaffected:
   an owner publishes everything before it goes idle.
4. **The promotion lock is a spin lock** (`minorwork::SpinMutex`: pause, then yield, then 10 µs
   sleeps). Critical sections are sub-microsecond; as a futex-backed `std::mutex` every contended
   acquisition slept and convoys formed.
5. **Step 7b was built** (batched rung-2 pops, 16 per acquisition, finalized outside the lock).
   `initObjectHeaderWithSize`'s mid-cycle `live_bytes` add became an atomic add, because a
   worker finalizes stashed cells of the same mixed blocks outside the lock.
6. **The space bound is exact** instead of `S/32`:
   `S + (S / (lab − lab/64) + N) · lab/64 + N · lab ≤ capacity`. At the pressure configs' 128 KiB
   side and 95 % trigger no bound fits once N · lab exceeds the 5 % slack, so those minors run
   serially by design. The parallel stress configs (`benchmarks/heap-config-gc-pressure[-
   incremental]-parallel.json`) use a 1 MiB side at an 85 % trigger with 4 KiB LABs.
7. **PM2** is "no to-space copy still points into from-space". A leftover BUSY word cannot be
   found by walking from-space after the copy, because forwarded objects no longer parse.
8. **Imbalance** is recorded in entries (`imbalance_units`), not ns.
9. **The one-worker identity switch** (`ECO_TEST_PROMO_VIA_CTX`) and the forced engine
   (`ECO_TEST_MINOR_ENGINE=P`) are stats-build test switches. `ECO_TEST_MINOR_THREADS=<n>` runs
   the whole unit suite with n workers (configs that set `minor_lab_bytes` keep their own).
10. **E2E coverage.** In-process E2E heaps take the allocator's config at its first initialize, so
    environment settings do not reliably reach them (the 5c caveat). Parallel minors are covered
    by the unit suite under `ECO_TEST_MINOR_THREADS`, the stress suite (standalone Elm programs,
    1,090 parallel minors per run), both TSan harnesses and the self-compile.
11. **Shared chunked blocks replace per-worker blocks for N > 1** (N = 1 keeps P§3.8's
    per-worker cursor, so the identity checks stay exact). With one block per worker per class,
    each minor left up to N × (classes in use) × 512 KiB of partly filled blocks. That inflated
    committed bytes, the garbage-fraction trigger's denominator. Early in the run, when the old gen
    is ~100 MB, the first major moved from minor 91 (serial) to 165 (N = 8) and 240 (N = 16). The
    chaotic trigger then carried the change through the run (6 majors, peak +20 %). As built:
    - one shared current block per class; workers claim chunks by CAS on a cache-line-padded word
      (block id + 1) << 32 | next unit, where a unit is 64 cells (whole bitmap bytes);
    - a worker's claim for a class starts at 1 unit in each minor and doubles up to 16 (1,024
      cells);
    - refills and virgin blocks advance the shared block under the lock;
    - at the merge the shared block becomes the mutator's cursor, and blocks retired with cells
      left in a worker's last chunk are re-queued at the front;
    - flushes of pending live bytes are atomic adds (several workers per block).

    Fixed 256-cell chunks restored the first major but cost +9 % minor time. Fixed 1,024-cell
    chunks recovered the time but moved the first major to minor 145. Adaptive claims give both:
    the first two majors are identical to serial at N = 4, 8 and 16, with the best minor times.
12. **Found, not fixed (pre-existing):** the bitmap ladder's rung 7 passes a size-classed
    request to `allocateFromBagPage`, which asserts in `-UNDEBUG` builds. It is reached only at
    the old-gen cap (seen in a test whose first-initialize reservation was 64 MB).

### 10.2 E0 — the serial reference

- `gc_minor_threads = 1` against `eco-optTG5c` (same session, `major_gc_live_budget_paced`
  pinned off in both arms by one JSON file; see 10.1 fact 1): **every counter matches**,
  decisions included (`tg6-compare.py --all`: RESULT MATCH). `out.mlir` is byte-identical
  (933c3ff0d288…) in every run of the phase.
- The Step 4 identity switch (serial minor promoting through a one-worker context) reproduces
  `allocate()` exactly: `testPromoViaCtxMatchesSerial`, 3 seeds, layout hash + every counter.

### 10.3 E1 — determinism (phase-timer candidate, one run per arm)

`ECO_GC_MINOR_THREADS` ∈ {01, 02, 04, 08, 00 (auto = 8 then)} and 08 + `ECO_GC_HELPER_JITTER_US=50`:
**all 1,924 per-minor rows identical in their object columns**, and the run totals are identical
(`tg6-compare.py`, object class). The decision class differs, as the amended GC_DET_001 allows
(8/7/7/6 majors before the chunked blocks, 8 at every N after).

### 10.4 E2 — scaling

Final design without prefetch (`eco-optTG6c9PT`), triples, medians:

| N | wall (s) | minor GC (s) | minor p50 / p99 / max (ms) | old-gen peak (MB) | max RSS (GB) | member CPU (s) |
|---|---|---|---|---|---|---|
| 1 | 160.9 | 46.75 | 4.82 / 111.9 / 177.5 | 9,250 | 10.18 | — |
| 8 | 124.1 | 12.83 | 2.07 / 25.4 / 116.5 | 11,423 | 12.41 | 67.5 |
| 12 | 120.8 | 10.39 | 1.82 / 21.1 / 106.2 | 11,430 | 12.42 | 77.4 |
| 16 | 121.9 | 9.47 | 1.81 / 20.2 / 74.2 | 11,842 | 12.85 | 89.5 |

Single runs: N = 2: 34.0 s minor; N = 3: 24.1; N = 4: 19.9; N = 6: 15.3.

**Decision rule:** N = 16 is the only N within 10 % of the best on both minor GC and worst
pause. Its collector CPU per second of pause saved is 2.40, 1.26× N = 4's (< 3×). **Cap = 16.**
Wall −39 s (−24 %), minor GC −80 %, p99 −82 %, worst minor −58 %.

How the design got there (each row one N = 8 / N = 16 run):

| design step | N = 8 minor / max | N = 16 minor / max | majors (N = 8) |
|---|---|---|---|
| first build (priv counted as work, std::mutex, per-worker blocks) | 16.5 s / 649 ms | 23.4 s / 1,358 ms | 6 |
| idle workers wake only for stealable work | 13.2 / 203 | 10.3 / 213 | 6 |
| spin lock | 12.7 / 110 | 9.9 / 141 | 6 |
| batched rung-2 pops (Step 7b) | 12.7 / 79 | 9.5 / 110 | 6 |
| chunked shared blocks, 256 cells | 13.9 / 110 | 9.9 / 122 | 8 |
| adaptive chunks (1 → 16 units) | 13.0 / 139 | 9.45 / 75 | 8 |

### 10.5 E3 — LAB size and child prefetch (N = 16, one run each)

| LAB | prefetch | minor GC (s) | fillers (MB, % of survived bytes) |
|---|---|---|---|
| 8 KiB | off / on | 9.48 / 9.25 | 109 (0.5 %) |
| 32 KiB | off / on | 9.45 / 9.24 | 314 (1.4 %) |
| 128 KiB | off / on | 9.45 / 9.11 | 1,274 (5.8 %) |

32 KiB and 128 KiB fail the ≤ 1 % filler rule. Prefetch gains ~2 % at N = 16. At N = 1 the serial
path runs, so the "wins at both N" clause has nothing to compare. **Defaults: 8 KiB LABs,
prefetch on.**

### 10.6 E4 — the serial threshold (stress suite, parallel config, N = 16)

Minors of ~0.85 MB: minor GC 2.22 s in parallel vs 1.21 s serial (the gang wake and
termination dominate). Any threshold ≥ 1 MiB routes them serially. Minors between 1 and 4 MiB
were not measured; every self-compile minor is ~120 MB. **The default stays 4 MiB.**

### 10.7 E5 — oversubscription (`taskset -c 0,1`)

N = 8: wall 148.5 s, minor max 158 ms; N = 2: 151.0 s, 150 ms. It passes: no collapse, and
8 is not slower.

### 10.8 E6 — background marking

At N = 16: `conc_mark` 0 → 9.45 s minor, 2 → 9.56 s (+1 %). Background markers barely slow
parallel minors.

### 10.9 E7 — retention (the rule-3 gate): FAILED

Old-gen peak in MB (majors), N = 16 vs N = 1, gf sweep, one run per point:

| gf | N = 1 | N = 16 |
|---|---|---|
| 0.65 | 8,696 (9) | 10,066 (8) |
| 0.70 | 9,250 (8) | 11,850 (8) |
| 0.75 | 9,290 (7) | 9,476 (7) |

Sweep median +8.8 % (limit +3 %); gf 0.70 is above N = 1's sweep max; max RSS median +8.6 %.

**Root cause (isolated):**
- **It is not concurrency.** The parallel engine forced to one worker (no chunking, no stash, a
  single cursor as in serial) peaks at 11,070 MB. Restoring per-promotion sweep slices in it
  changes nothing (11,037 MB).
- **It is promotion order.** Per class the engine fills exactly the same cells as serial each
  minor; only the object → cell mapping differs. The first five majors are identical in timing
  and size. At major 5 the engine recovers ~27–36 MB less (fewer all-dead blocks). Committed
  memory, the garbage-fraction denominator, stays higher, and major 6 fires 54–56 minors later
  at a program point with ~2.5× the live data. The chaotic trigger carries that to the peak.
  Serial Cheney promotes breadth-first, which in this workload clusters objects that die
  together into the same blocks better than the engine's depth-first order.
- **FIFO grey order** (`minor_fifo_order`) brings the one-worker engine to 9,790 MB (+6 %), but
  at N = 16 it peaks at 11,427 MB (stealing scrambles the order) and costs 25 % minor time.

**Per the gates, `GC_MINOR_THREADS` stays 1.** Every other setting is the measured one for when
it is enabled.

### 10.10 E8 — tight cap (`max_heap_size` 15G, an 11 GB old-gen cap)

N = 1: 9,236 MB (82.0 % of the cap), 8 majors. N = 16: 9,652 MB (85.7 %), 9 majors. +3.7 points
against a +2 limit: the same retention effect as E7. Stress 101/101 at 1, 4, 8, 8 + jitter and 16.

### 10.11 E9 — mutator locality

Mutator CPU outside pauses (E2 medians): N = 1 113.4 s; N = 8 110.2 s; N = 16 111.4 s. The
depth-first copy order does not hurt the mutator; it is slightly faster.

### 10.12 Final build and gates

The final build is `eco-optTG6`, `eco-optTG6PT` and `eco-optTG6NS`, with default LAB 8 KiB and
child prefetch on. At N = 16, triple medians: wall 120.7 s, minor GC 9.34 s, minor p50 / p99 / max
1.70 / 20.2 / 75.2 ms, 8 majors, peak 11,837 MB, max RSS 12.84 GB. N = 1: 160.9 s, 46.25 s,
110.9 / 174.7 ms.

| # | Gate | Result |
|---|---|---|
| G1 | unit | 1,907/1,907 at default, `ECO_TEST_MINOR_THREADS` 8 and 16 |
| G2 | elm-tests | 13,565 pass / 12 fail: the pre-existing reference set |
| G3 | `full` | 1,907/1,907 (default); E2E subset at 8 under the pressure-parallel config 942/942 |
| G4 | stress | 101/101 at 1, 4, 8, 8 + jitter and 16 on both parallel pressure configs (1,090 parallel minors); original pressure config 101/101 (serial by the space bound) |
| G5 | validate tree | unit 1,908/1,908 at 1, 4 and 8; stress 101/101 on every arm above. The only `[heap-validate]` lines are the three negative controls (PM2 for the double copy, PM3 for the missing filler, PM4 for the kept block), which must fire |
| G6 | stats-off | `eco-optTG6NS` self-compiles at N = 16, output identical |
| G7 | E0 | MATCH on every counter against `eco-optTG5c` (paced pinned off) |
| G8 | E1 | object class identical at 1/2/4/8/16/16 + jitter (final build) |
| G9 | TSan | `gc-minor-tsan` 2,200 runs (and 220 on 2 cores), `gc-mark-tsan`, `gc-heap-tsan` (and on 2 cores): 0 warnings |
| G10 | E2–E9 | rules applied (P§10.4–10.11); **E7 and E8 (retention) failed** |
| G11 | fixed point | every run in the phase reproduced `out.mlir` md5 933c3ff0d288…, the MLIR its compiler was lowered from |
| G12 | static | no `hardware_concurrency` in the allocator; `minorGCSerial`'s statements are unchanged (the serial core is wrapped, not edited) |

### 10.13 The default (after review, 2026-09-27)

The gates left `gc_minor_threads` at 1. On review the default was flipped to **auto with a cap
of 8** (`GC_MINOR_THREADS = 0`, `GC_MINOR_THREADS_CAP = 8`), overriding E7/E8 as 5c's paced
LiveBudget was overridden:
- 8 workers give most of the gain (E2: wall 124 s vs 122 s at 16, minor p99 25 vs 20 ms) for
  ~25 % less collector CPU (67.5 vs 89.5 s);
- the retention cost does not shrink with fewer workers (peak +19–28 % at every N ≥ 4), because
  its cause is promotion order.

The default was re-measured with the stats build and no GC environment (`eco-optTG6d`, triple):
- wall 2:03.44 / 2:02.43 / 2:03.30 (median 123.30 s; TG5c 162.60 s);
- minor GC 12.25 s, 1,924 minors, 8 majors, all 1,924 minors parallel on 8 workers;
- old-gen peak 11,437 MB, max RSS 12,426,732 kB;
- output identical (933c3ff0d288…).

The gates re-run default-on are recorded in P§10.14. `ECO_GC_MINOR_THREADS=1` restores the
serial path.

### 10.14 Gates re-run default-on (auto, cap 8, no GC environment)

- `full`: 1,907/1,907.
- stress: 101/101 at the default config; 101/101 on the pressure-parallel config (all 1,090
  minors parallel on 8 workers).
- validate unit: 1,908/1,908; the only `[heap-validate]` lines are the three negative controls.
- validate stress: 101/101 on both parallel pressure configs, zero `[heap-validate]` lines.
- The benchmark triple of P§10.13 reproduced `out.mlir` (fixed point).

## 11. Done means

- Every gate G1–G12 passes with the default flipped, or the phase is closed with the reason
  recorded and the default left at 1.
- E1's object class is identical across N and jitter, and E7's retention rules hold.
- The master-plan row, the §5 pause table, the invariants, THEORY.md and the loop entry `TG6` are
  written.
- `keep-TG6` and `bin/eco-opt-prev` = `eco-optTG6` exist.
