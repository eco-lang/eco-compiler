# Threaded GC 05c — Concurrent marking on background threads, and heap-relative trigger pacing

**Status:** DONE (2026-09-27). **Part A default-on:** `conc_mark = 2`, auto background markers
(cap 4), priority 0, assist lag 8. **Part B:** the `Headroom` trigger is default-on (margin 1.5);
the paced LiveBudget and the garbage-fraction backstop ship default-off. T stays 32. Written
against the `keep-TG5b` tree (`bin/eco-opt-prev` = `eco-optTG5b`); as-built record in P§10.

**Parent:** `plans/threaded-gc-master-plan.md`, phase 5c (formerly 5b).

**Depends on:**
- phase 3: the helper-thread discipline, GC_DET_001, the TSan harness and the atfork hooks;
- phase 5a: the snapshot cycle, allocate-black, deferred frees, the fixed schedule. Its forward
  contract is `plans/threaded-gc-05a-incremental-marking.md` §9, and this plan implements the
  5c column;
- phase 5b: exact tickets, the Chase–Lev deques, private stacks, termination, chunking, one
  accumulator per marker. Its forward notes are `plans/threaded-gc-05b-parallel-marking.md` §9
  and trap 7.

**Background:**
- `design_docs/parallel-gc.md`:
  - §2.1 (the snapshot-closure lemma);
  - §3.4 (memory model), §3.5 (metadata a second thread races on);
  - §5.3 (allocate-black options A–D), §5.5 (termination), §5.6 (pacing);
  - §10 (measuring a concurrent collector);
  - §11 (invariants);
- handbook: HB 16.7 (allocation-based pacing), HB 19.6 (tax-and-spend, i.e. mark assist), and
  the Go pacer [L] cited in §5.6.

§n points into `design_docs/parallel-gc.md`, P§n into this plan, 5a-P§n / 5b-P§n into the
earlier phase plans, and M§n into the master plan.

---

## 0. What this phase delivers, and why

**Where 5b left the pauses** (self-compile, T = 32, auto markers = 16; TG5b loop entry and
5b-P§10.4, 10.9):

| pause kind | what runs in the pause | max / p99 |
|---|---|---|
| 0 minor only | the minor GC | 189 ms max |
| 3 minor + t0 | the minor, then the snapshot (prepare + roots + young walk) | t0 part ≤ 24 ms |
| 4 minor + slice | the minor, then a 16-marker slice | p99 141 ms; slice mark max 30 ms |
| 5 minor + handoff | the minor, then the post-mark tail | tail ≤ 102 ms |

Other 5b numbers:
- in-pause slice mark total: 1.30 s per self-compile;
- collector CPU: 18.8 s;
- wall 163.9 s; old-gen peak 8,936 MB; max RSS 9.85 GB.

**What is still wrong, measured against the master plan's goals (M§1):**
1. **Goal 2: pauses must not grow with the old gen.**
   - A 5b slice is `predicted_units / (H · N)` objects of in-pause work, i.e. heap-size ÷ (T/2 ·
     markers).
   - At the self-compile's 9 GB that is 30 ms. At 1 TB of live data it would be seconds.
   - Only marking **outside** pauses removes the dependence.
2. **The retention variance.**
   - The trigger is chaotic: the gf sweep swings the old-gen peak by ±30 % in both the STW and
     the cycle arms (5a-P§10.5).
   - 5b's E3 saw T = 8/16 raise the peak by 12 % (5b-P§10.5).
   - The master plan assigns heap-relative trigger pacing to this phase (M§3 phase 5c).
3. **The small-heap budget (M§1 item 3, ~4 GB).**
   - Nothing starts a cycle early enough to finish before the cap.
   - Only the 0.95 pressure finish stops an overrun, and it turns the cycle into an in-pause
     drain.

**This phase has two parts, shipped separately.**

**Part A: concurrent marking (a mechanism change; every decision counter identical to TG5b).**
- **Launch.** At the end of the t0 pause, the grey set is handed to **B background markers**.
  They are low-priority threads owned by the heap, and they mark while the mutator runs Elm code
  *and* while it runs minor GCs.
- **Steps k = 1 … T − 1** (the minor ends that ran 5b slices):
  - normally nothing happens;
  - if the background is **late** against a deterministic schedule, the paused mutator and the
    foreground gang (5b's markers) **join the running episode** for a bounded assist.
- **The closing step k = T:**
  - if the background has finished, nothing happens;
  - otherwise the foreground joins and helps until marking terminates.
- **The handoff at k = T + 1** is 5a's, unchanged.
- **Unchanged from 5a/5b:**
  - the schedule, the snapshot, allocate-black and the deferred frees;
  - which objects get marked (the marked set at the handoff);
  - the units per cycle;
  - every GC decision.

  Only *when* and *on which thread* each entry is scanned changes.

**Part B: heap-relative trigger pacing (a policy change; counters re-baselined on purpose).**
- **A deterministic promotion-rate estimate `P̂`** (old-gen bytes per minor).
- **A `Headroom` trigger:** start a cycle early enough that `(T + 1) · P̂` more bytes still fit
  under the finish fraction of the cap.
- **A cycle-aware `LiveBudget`:** the budget is reached at the *handoff*, not at t0.
- **An optional garbage-fraction backstop arm.**

Each is behind its own knob and judged on sweeps, never on one run (the TG2 rule).

**Expected result** [E]:
- **Part A.**
  - Kind-4 pauses on the self-compile drop from 224 per run to about 0 on an idle machine.
  - The in-pause cycle work per cycle becomes t0 + handoff tail, and neither depends on marking
    speed.
  - The worst pause stays the minor floor (189 ms): phase 6 is what lowers it.
  - Wall: flat to −1 s. The 1.3 s of in-pause mark leaves the critical path; interference is
    added back.
  - Collector CPU: about 5b's CPU at the same marker count.
- **Part B.** The peak spread across the gf sweep falls from ±30 % toward ±10 %, and a 4 GB-cap
  run gets no pressure finishes. Treat both as hypotheses: Part B starts with a diagnostic
  census (E8) and may ship only the `Headroom` trigger.

**Be honest about what 5c does not change on the self-compile:** the max pause. 5b already
brought it to the minor-GC floor. 5c's wins are:
- the goal-2 property (demonstrated by E7 on a synthetic heap at two sizes);
- p99 and MMU during cycles;
- the retention variance;
- 4 GB safety.

| # | Deliverable |
|---|---|
| D0 | Re-verified facts (P§2); same-session baseline with `eco-optTG5b`; the shared-state audit table filled in (P§3.6); the feasibility verdict for a heap-level TSan build (P§4 Step 0); snapshot `try-TG5c-pre` |
| D1 | Refactor, counters bit-identical to TG5b: marker **slots** (F foreground + B background, B = 0 for now); `publishAll` at every run exit; the t0 `MarkView`; `ParallelMark` paths read no mutator-owned state (P§3.2, P§3.6 rows H6–H8) |
| D2 | Shared-state hardening, counters bit-identical: atomic allocate-black on the non-cursor path; release/acquire page-index publication; atomic `ReservedArray` committed counts; atomic region bounds; validators IM13–IM15 (P§3.6, P§3.7, P§3.9) |
| D3 | `MarkWork.hpp` loop: participant roles (Member / Assist), mid-run join and leave, stop requests; TSan synthetic harness extended with an *episode storm* (P§3.3, P§4 Step 3) |
| D4 | `GCBackgroundGang`: per-heap, low-priority, launch / join / stop; atfork and exit hooks; unit tests and a TSan gang storm (P§3.4) |
| D5 | Configuration: `conc_mark` (0 off / 1 sync / 2 concurrent), `conc_mark_threads`, `conc_mark_threads_cap`, `conc_mark_priority`, `conc_mark_assist_lag`; environment `ECO_GC_CONC_MARK`, `ECO_GC_CONC_MARK_THREADS` (P§3.12) |
| D6 | The cycle driver in modes 1 and 2: launch at t0, per-step merge and relaunch, paced assists, the closing join, pressure finish and join paths, reset, exit and fork; pause-kind rules (P§3.5, P§3.8) |
| D7 | Validators in concurrent mode; negative controls (P§3.9) |
| D8 | `ConcMarkStats`, banner, event-log columns, summary script; the collector-CPU / mutator-CPU / stall / interference split (P§3.13) |
| D9 | `gc-heap-tsan`: the real allocator under g++ `-fsanitize=thread` with a synthetic mutator, time-boxed (P§4 Step 8) |
| D10 | Part A experiments E0–E7; the default flip to mode 2 (or a recorded closure) |
| D11 | Part B mechanism, every knob default-off (counters identical): `P̂`, the `Headroom` reason, paced `LiveBudget`, gf backstop, census columns (P§3.11) |
| D12 | Part B experiments E8–E12; the pacing decision; T re-chosen under the final pacing |
| D13 | Invariants, THEORY.md, master-plan row and §5 table, loop entry `TG5c`, snapshot `keep-TG5c` |

**Out of scope:**
- **Parallel or concurrent minor GC** (phase 6), and anything that moves the minor pause.
- **Making the t0 prepare incremental.** `clearForMark` is O(heap / 64) and the lazy-sweep drain
  is O(mixed blocks). Both are heap-size dependent. Measure and record them (E7). They belong to
  phase 8's "concurrent mark-bitmap clearing" item.
- **Making the handoff tail incremental** (classify, reclaim, shrink): measure and record (E7),
  as 5a and 5b did.
- **The STW `ThreadLocalHeap::majorGC` path** (explicit majors and allocation failures after a
  join). It stays serial, as in 5b.
- **Routing marking through the phase 3 FIFO pool.** The master plan's phase-5c text says "on
  the phase 3 pool". This plan deliberately uses a dedicated per-heap background gang instead:
  - a mark episode lasts seconds and would block decommit and populate jobs queued behind it in
    the FIFO;
  - pool threads run at normal priority, and priority cannot be lowered and raised again (F20).

  Record the deviation in the master plan at Step 12.
- **Raising thread priority.** An unprivileged process cannot raise a thread's priority (F20).
  The design never needs to.

---

## 1. Ground rules

1. **Part A is decision-neutral.** With `conc_mark` ∈ {0, 1, 2}, any B, and with
   `ECO_GC_HELPER_JITTER_US` set, the following are identical to `eco-optTG5b`:
   - every **decision counter** (P§3.10: minors, majors, allocated, promoted, copied, per-major
     before/after/garbage/recovered, old-gen peak, releases, deferred frees);
   - **the total mark units of every cycle**;
   - the major event log's non-timing columns.

   Per-slice units, closing units, assist counts and the pause-kind split may differ (they are
   progress counters, P§3.10). A difference in a decision counter is a bug: stop and find it.
2. **Mode 0 is TG5b.** With `conc_mark = 0`, *every* counter equals `eco-optTG5b`: per-slice
   units, the pause-kind split, and the per-run ParMark stats that are deterministic (units,
   chunks). This is checked after D1, D2 and D6.
3. **Part B is a deliberate policy change** (M§2 counter discipline):
   - every Part B knob ships default-off first, with counters identical;
   - each flip re-baselines the counters and is judged on sweeps, **retention gate first**
     (M§2);
   - modes 0/1/2 must still agree with each other under every Part B setting (decisions never
     read collector progress).
4. **Collector progress is never a decision input** (GC_DET_001). The following may be read only
   to decide *pause-internal work* (whether to assist, and how much), never a GC decision:
   - the background's consumed units;
   - whether it has finished;
   - `markStackEmpty()` while an episode runs;
   - `cycle_predicted_`'s doubling.

   P§3.10 lists every such read.
5. **Write the marker as if the world were running** (M§3 phase-5 rule), for real this time.
   - A marker reads only:
     - objects in S_H (frozen by P1);
     - the t0 `MarkView` (immutable during the cycle);
     - page-index slots and `BlockInfo` of blocks published by release (P§3.6);
     - mark bytes (atomics);
     - its own slot, and other slots' deques only through `steal`.
   - It writes only mark bytes (atomics), its own slot, and other deques' `top`.
   - The audit table (P§3.6) lists every other location it could reach and why it does not.
6. **The mutator touches a slot's owner-only state only while no thread runs on that slot**
   (IM14): the t0 distribution, counter merges, deque resets and array retirement. The
   background gang's launch and join are the publication points.
7. **Assert what you rely on** (M§2). IM1–IM12 stay; IM13–IM16 are new (P§3.9). The TSan
   harnesses cover the loop, the gangs and (if D9 builds) the heap. The validate tree runs at
   `conc_mark` 0 and 2.
8. **Standing gates** (M§2): E2E, elm-tests, `full`, stress under GC pressure, the validate tree
   with the P1 tripwire, stats-off build, `out.mlir` byte-identical, bootstrap fixed point.
   **No validator self-compile** (it takes hours).
9. **Verify the artifact, never the exit code.** A background-thread crash can surface as a
   hang or as a clean-looking exit. Every self-compile arm gets a timeout (2× its expected wall)
   and an `out_md5` check. A timeout is a failure.

---

## 2. Verified facts

Verified 2026-09-26 against `keep-TG5b`. Paths are under `runtime/src/allocator/` unless given.
Line numbers are approximate. **Re-verify every row before editing (Step 0).**

| # | Fact | Where |
|---|---|---|
| F1 | **The cycle is driven from `ThreadLocalHeap`.** `minorGC` calls `stepMarkCycle()` and returns when `old_gen_.cycleActive()`. Otherwise it evaluates the trigger and calls `startMarkCycle` or `majorGC`. `startMarkCycle` does, in order: stack roots, `p1::verifyOldGen`, `beginMarkCycle(*parent_, slices)`, snapshot mode on, long-lived + JIT roots, `forEachMajorRoot`, `snapshotYoungLarge`, `forEachSurvivor` → `markChildren`, snapshot mode off, IM1 record half (validate), and, for T = 0, `finishMarkCycleNow(Schedule)`. `stepMarkCycle`: `noteCycleMinorEnd`; HandoffDue → `completeMarkCycle`; pressure → `finishMarkCycleNow(Pressure)`; else `runCycleSlice` + IM6. `finishMarkCycleNow` asserts `!in_slice_`, drains, and completes. `majorGC` joins a running cycle first. | `ThreadLocalHeap.cpp:724-745, 747-760, 1026-1095, 1097-1123, 1125-1136` |
| F2 | **The `OldGenSpace` cycle functions.** `beginMarkCycle` runs `prepareMark`, sets `mark_parallel_ = mark_threads_ > 1`, resets IM10/IM11, sets `gc_phase_ = Marking` and `cycle_state_ = Marking`, and computes `cycle_predicted_` (previous units × max(1.25, occupancy growth), or occupancy / 48). `runCycleSlice`: closing drain at k = T (state HandoffDue); otherwise front-loaded pacing over H = ⌈T/2⌉ with doubling when `!markStackEmpty() && cycle_units_ >= cycle_predicted_`. `drainCycleMark` = `runMarkers(kDrainBudget)`. `handoffMarkCycle` asserts `markStackEmpty()` and `!in_slice_`, then `resetAllocCursors`, `markLiveSum`, IM4/IM6/IM5/IM8/IM11, `gc_phase_ = Idle`, `runPostMarkTail`, and a deque `reset()` for `i < mark_threads_`. | `OldGenSpace.cpp:3196-3252, 3275-3278, 3280-3320, 3332-3390` |
| F3 | **`runMarkers(budget)`:** serial on worker 0, or `GCMarkGang::run` over `mark_threads_` members. After the join it calls `retireOldArrays()` on every marker's deque, sums the counters, asserts units == consumed tickets, and adds units to `cycle_units_` when a cycle is active. | `OldGenSpace.cpp:2642-2720` |
| F4 | **`MarkWork.hpp`.** `SliceControl` = `budget` + one 64-bit `state` word (active count, reactivation epoch, done bit), plus `n` and the jitter. `claimTicket` always draws from `c.budget` (batches of 256); `kDrainBudget = INT64_MAX / 4`. `runMarkerLoop` exits a parallel run **only** through termination (`idleUntilWorkOrDone` → done). There is no stop request, no per-participant ticket pool, and no join into a running control (`reactivate()` exists but is used only by idle members). | `MarkWork.hpp:170-420` |
| F5 | **Private stacks (5b-P§10.1 item 1).** `pushGrey` pushes onto the owner's `std::vector` stack and publishes its size in `priv`; `publishHalf` moves the oldest half to the deque when the deque is empty and the stack holds ≥ 64 entries, checked every 32 pushes and every 64 pops. **A run that ends because its budget is exhausted can leave entries on a private stack** (only the owner can take them). `anyWork()` counts `priv`. | `OldGenSpace.hpp:734-750`, `OldGenSpace.cpp:2600-2635` |
| F6 | **`GCMarkGang`** is a process singleton. `run()` = the caller as member 0 plus n − 1 parked threads, serialised by `run_m_`. `atforkPrepare` takes `run_m_` and `m_`, assuming runs happen only inside pauses. | `GCHelperPool.hpp:150-215`, `GCHelperPool.cpp:320-480` |
| F7 | **Mark-byte writers.** Markers: `testAndSetMark<ParallelMark>` (relaxed load, then `fetch_or`; large blocks: `exchange`). Mutator, while `marking_active \|\| gc_phase_ != Idle`: `initObjectHeaderWithSize` → `setMarkBitInBlock`, a **plain RMW**, on every non-cursor old-gen allocation; `finalizeBitmapCell` → `bitscan::setBit`, **plain**, on the cursor's block; `snapshotYoungLarge` (t0, plain). Clears: `freeUniformCell` (never inside a cycle: frees are deferred), the sweep (never inside a cycle), the large-mark reset on free-large-block reuse. | `OldGenSpace.cpp:2197-2220, 456-485, 716-740, 3254-3273, 870, 3990, 1879, 1924` |
| F8 | **During a cycle the uniform cursor serves only blocks created after t0.** `resetAllocCursors` at t0 empties every cursor and `partial_` queue. Blocks are re-queued only by `classifyBlocksAfterMark` (in the tail) and by `freeUniformCell` (deferred inside a cycle). This is argued in 5a-P§3.4, but **nothing asserts it**. | `OldGenSpace.cpp:625-635, 681-700` |
| F9 | **Mutator-side mark-byte reads reachable during a cycle:** the minor GC's validate walk over every old block (`isMarkedInBlock` on uniform cells, validate builds, every minor); `assertCellWasWhite` and `noteCycleAllocation` (validate); `validateCycleUniformLive` at each step (validate; it also reads **every accumulator**); `cursorAllocate` (its own post-t0 block). `P1CensusAccess::markedNow` runs only at mark end; `retireDeadLargeBodies` runs only in the tail. | `NurserySpace.cpp:895-915`, `OldGenSpace.cpp:3395-3440`, `P1Census.cpp:30`, `OldGenSpace.cpp:895-910` |
| F10 | **`blockIdFor` reads mutator-written state:** `region_base_` / `region_end_` (plain `char*`, 15 write sites in `OldGenSpace.cpp`, e.g. `:780-782`, `:1660-1662`, `:1748`, when a new block extends the region); `page_index_.committed()`; the `PageOwners{primary, secondary}` words (plain `uint32_t`, written in `assignPageIndexForBlock`); `BlockInfo::start/end`. | `OldGenSpace.cpp:1032-1051`, `OldGenSpace.hpp:373-376, 403-408`, `OldGenSpace.cpp:~545-565` |
| F11 | **`materializeBlock`** writes in this order: `blocks_.add` (the BlockInfo), `mark_.assign`, `commitThrough` for `i < mark_threads_`, and **last** `assignPageIndexForBlock`. The order is right for publication, but every store is plain. | `OldGenSpace.cpp:607-615` |
| F12 | **`ReservedArray::committed_`** is a plain `size_t`, written by `ensureCommitted` and read by `committed()` and by the `operator[]` asserts. `LiveBytesAccumulator::add` is `bytes_[id.v] += n` (it asserts in debug builds). | `ReservedArray.hpp:109-183`, `BlockTable.hpp:385-392` |
| F13 | **In-place writes to a published `BlockInfo`:** only `:1913-1914` (`allocateFromEmptyRegularBlocks` flips an empty block to large, which mid-cycle can only be a post-t0 block, 5a F13) and `:3030` (demotion, in the tail). Every other site fills a local `bi` before `materializeBlock`. `BlockInfo` has **no bitfields** (40 B `static_assert`), so different fields are different memory locations. | `OldGenSpace.cpp:802-806, 1690-1694, 1780-1784, 1913-1914, 1962-1966, 3030, 5238-5242`, `BlockTable.hpp:45-67` |
| F14 | **`ParallelMark` paths that read mutator-owned state:** `greyObject` reads `cycle_state_` and `snapshot_mode_` (`:2235-2250`), `nursery_->contains` (bounds rewritten by `updateBounds` on nursery growth, *inside a minor GC*, `NurserySpace.cpp:389`) and, in validate builds, `isYoungLarge` (an `unordered_map`) (`:2244`); `scanObject`'s HEAP_BUILDER_001 assert calls `isYoungLarge` (`:2544`); `scanChildren` reads `snapshot_mode_` to decide chunking (`:2341`, `:2417`); `im10NoteScan` reads `cycle_state_`. | `OldGenSpace.cpp` as listed |
| F15 | `Allocator::isInHeap` reads `heap_base` / `heap_reserved`, immutable after init. The nursery is the reservation suffix `[heap_base + nursery_offset, heap_base + heap_reserved)`; `nursery_offset` is first-init-wins. | `Allocator.hpp:28-29, 232-235, 257-280` |
| F16 | `mark_threads_` is used 24 times in `OldGenSpace.cpp` and 4 times in `OldGenSpace.hpp`: accumulator reserve / commit / peek / take / sum / merge, `markStackEmpty` / `markStackSize`, `runMarkers`, `ensureMarkers`, and the handoff's deque reset. | `grep -n mark_threads_` |
| F17 | **The trigger.** `evaluateMajorGCTrigger` returns `None` while a cycle runs. Otherwise, in order: Occupancy (0.95), GlobalPressure (0.85 of the cap), GarbageFraction (gf 0.70, denominator cap 0 = uncapped), LiveBudget (k = 4.5, r = 1.5, `alloc_since_major ≥ k · min(major_live_, r · prev_major_live_)`). There is **no promotion-rate estimate and no monotone old-gen allocation counter**. `allocated_bytes +=` appears at 7 sites, and sweeps and frees lower it. | `OldGenSpace.cpp:4136-4235`, `AllocatorCommon.hpp:162-255` |
| F18 | Pressure finish: `cyclePressureFinishDue()` = old-gen committed / cap ≥ `incremental_mark_finish_fraction` (0.95). | `OldGenSpace.cpp:~3322-3330` |
| F19 | **Forks.** Only tests fork (`ElmE2ETestBase.hpp`, `IsolatedTestRunner.hpp`, `mlir_equivalence_main.cpp`, `aot_e2e_main.cpp`, `ParallelMarkTest.cpp`, `IncrementalMarkTest.cpp`, `GCHelperTest.cpp`); the runtime never forks. The atfork hooks are registered by `GCHelperPool` and `GCMarkGang`. | `grep -rln "fork("` |
| F20 | **Priority is one-way here.** RLIMIT_NICE is 0 (cur and max). A thread can set itself to nice 19 or to `SCHED_IDLE`. Setting nice 19 → 0 fails with EACCES, and `SCHED_IDLE` → `SCHED_OTHER` fails with EPERM (probe run 2026-09-26, `prio.cpp` in the session scratchpad; re-run it in Step 0). | — |
| F21 | **Pause kinds** 0–5 (`pause_count_by_kind[6]`); `notePauseCycleWork(0/1/2)` sets the t0 / slice / handoff flags. `IncrMarkStats im` and `ParMarkStats pm` live in the old gen's `alloc_stats_` and are carried through `ElmE2ETestBase`'s POD. | `GCStats.hpp:214, 248, 345`, `ThreadLocalHeap.cpp:1016` |
| F22 | **Environment:** `applyGcThreadEnv` parses `ECO_GC_THREAD`, `ECO_GC_HELPER_JITTER_US` and `ECO_GC_MARK_THREADS` (the environment wins over JSON); called at `Allocator.cpp:246`. | `HeapConfigJson.cpp:407-456` |
| F23 | **TSan.** `test/gc-helper-tsan` builds `gc-helper-tsan` and `gc-mark-tsan` with g++ 12.2; clang 14.0.6 here ships no TSan runtime. The allocator `.cpp` files include only allocator headers and the vendored nlohmann json. Whether the allocator links standalone (stack unwinding, `RuntimeExports.cpp`) is **unknown**: Step 0 decides. | `test/gc-helper-tsan/CMakeLists.txt` |
| F24 | `Allocator::onGCPauseEnd` is phase 3's sync point (it advances `sync_epoch_` / `major_epoch_` and syncs page work). | `Allocator.cpp:1134-1153` |
| F25 | Large bodies are written only between `allocateLargeBody` and the store of the body pointer into its young header, both in one mutator call with no GC in between. A body reachable at t0 is therefore complete at t0. | `ThreadLocalHeap.cpp:520-575`, `OldGenSpace.cpp:5647-5675` |

---

## 3. Design

### 3.1 A cycle in mode 2, end to end

T = `incremental_mark_slices`, F = foreground markers (5b's `gc_mark_threads`, resolved; slot
0 is the mutator), B = background markers.

| when | mutator | background |
|---|---|---|
| t0 (the trigger's minor end) | snapshot as in 5a/5b; `publishAll(slot 0)`; **distribute** the t0 greys round-robin into the B background deques; **launch** the episode | parked, then marking once launched |
| between minors | Elm code, including direct old-gen allocations (allocate-black) | marking |
| minor GC k (k = 1 … T) | the minor GC (promotions are allocate-black), then **step k** (P§3.5) | still marking, concurrently with the minor GC |
| step k < T | if the episode finished: join, merge, record `done_k`; else if late: **assist** (the foreground joins for a budget, then leaves) | marking |
| step k = T (closing) | if the episode finished: join and merge; else the foreground **joins until termination**, then join and merge; state HandoffDue | finishes, exits |
| k = T + 1 | the handoff (5a's tail), unchanged | idle |

`conc_mark = 1` (**sync**) runs the whole mark at t0 with the foreground gang (a 5b drain in the
t0 pause) and does nothing at the steps. It is the determinism reference; it is never a product
mode. `conc_mark = 0` is TG5b.

A T = 0 cycle (`incremental_mark = false` with parallel markers, or the E0-style equivalence
arm) never launches a background episode: it runs as in 5b in every mode.

### 3.2 Marker slots and the t0 `MarkView`

**Slots.**
- `mark_slots_ = F + B`: slots 0 … F − 1 are foreground (slot 0 = the mutator), slots F … F + B − 1
  are background.
- B = 0 unless `conc_mark == 2` and `incremental_mark_slices > 0`. `ensureMarkers()` creates
  `mark_slots_` workers.
- F + B ≤ `kMaxMarkers` (64): the resolver clamps B.
- Every loop over accumulators and deques that today runs to `mark_threads_` (F16) runs to
  `mark_slots_`:
  - `markLivePeek/Take/Sum/MergeAll` (merged in index order, trap 5 of 5b);
  - `markStackEmpty/Size`, the handoff deque reset, `commitThrough` in `materializeBlock`, the
    reserve in `reserveMetadata`.
- Loops that start a gang keep using F: `runMarkers`, the gang's member count.

**`SliceControl.n`** becomes the **victim range**: every slot a thief may steal from, `mark_slots_`.
The participants of a run are a subset (P§3.3). `anyWork()` scans all `mark_slots_` slots.

**`publishAll(w)`** (owner only): push the whole private stack into the deque and set
`priv = 0`. It runs at **every exit** of a parallel run, in every role and every mode. After any
run, therefore, all remaining work sits in deques, and any thread can steal it (IM15). In mode 0
this changes which marker takes an entry in the next slice, never the count: units are exact
tickets, so rule 2 holds.

**`MarkView`**, filled in `beginMarkCycle` and immutable until the handoff:

```cpp
struct MarkView {
    const char* index_base;        // page index origin (old gen)
    size_t      page_size;         // config_->alloc_buffer_size
    const char* nursery_lo;        // heap_base + nursery_offset: the RESERVATION, immutable (F15)
    const char* nursery_hi;        // heap_base + heap_reserved
#if ECO_HEAP_VALIDATE
    std::vector<const void*> ylos_t0;   // sorted YLOS addresses at t0 (IM3, HEAP_BUILDER_001)
#endif
};
MarkView mark_view_;
```

`ParallelMark` code reads the view instead of the live structures (P§3.6 rows H6–H8):
- **Young check.** `obj ∈ [nursery_lo, nursery_hi)`, which is stricter than `nursery_->contains`
  and race-free. It aborts in every build, as in 5b.
- **Validate builds.** IM3 and the HEAP_BUILDER_001 assert search `ylos_t0` with
  `std::binary_search`.
  - A YLOS object born after t0 cannot be reached by a marker: by HEAP_005 no old object points
    to it, and it is not in S_H.
  - A t0 YLOS object that dies and is deferred stays in `ylos_t0`, which is correct.
- **No reads of `cycle_state_` or `snapshot_mode_`.** A `ParallelMark` instantiation always runs
  in a cycle and never in snapshot mode: the t0 snapshot uses `SerialMark` bit operations
  (5b-P§10.1 item 5). The branches become `if constexpr (!P::kParallel)`.
- **IM10.** `im10NoteScan` checks an `im10_armed_` flag, set before the first run of the cycle
  and cleared after the last join.

### 3.3 The marker loop: roles, join, leave, stop (`MarkWork.hpp`)

Three additions to `runMarkerLoop`. The loop body, the ring, tickets and stealing are unchanged.

```cpp
enum class Role : uint8_t {
    Member,   // 5b semantics: idles until the control terminates (bg members, slice members, closing joiners)
    Assist,   // joins a running control for a bounded budget; never idles; leaves when its pool is empty
};
struct Participant {
    unsigned self;
    Role role;
    std::atomic<int64_t>* pool;   // ticket source: &c.budget for Member, &assist.budget for Assist
    bool joined;                  // entered via c.reactivate() (was not counted in the initial active)
};
struct SliceControl {
    std::atomic<int64_t>  budget;       // unchanged
    std::atomic<uint64_t> state;        // unchanged: active | epoch | done
    std::atomic<bool>     stop{false};  // NEW: a stop request (bg episodes only)
    uint32_t n;                         // NEW MEANING: victim range (slots), not participants
    unsigned jitter_us;
    bool steal_without_ticket;
};
```

**Tickets.** `claimTicket(w, *p.pool)` replaces `claimTicket(w, c)`, and `returnTickets` returns
to the same pool. Member participants all draw from `c.budget`, so the termination argument of
5b-P§3.3 carries over unchanged for them.

**Join (`p.joined`).** The first action is `if (!c.reactivate()) return;`:
- `reactivate` bumps the active count and the epoch, and fails once `done` is set;
- a joiner either becomes an active participant before termination, or sees that the control
  has terminated and leaves without touching anything.

**Assist exit rule.** An Assist participant exits (it never enters `idleUntilWorkOrDone`) when
either:
- its pool has no ticket left; or
- its own grey set and one steal pass over every victim found nothing.

Exit sequence, in this order: scan every entry left in its ring (they hold tickets), then
`publishAll`, `returnTickets`, `c.goIdle()`.

**Why a leaving Assist cannot end the episode early.**
- The episode terminates only through a Member's CAS in `idleUntilWorkOrDone`, from a state
  word with active == 0 in which it re-checked `budget > 0 && anyWork()` and found no work.
- The assistant publishes all its work *before* its `goIdle` (an acq_rel RMW on `state`).
- So any Member that reads the post-`goIdle` word also sees the published entries, and
  reactivates instead of deciding.
- An assistant that leaves with work therefore leaves that work to the Members. Termination
  still means "no work anywhere". The TSan storm checks exactly this interleaving.

**Stop.**
- Every participant loads `c.stop` (relaxed):
  - at the top of each ring-fill;
  - at each round of `idleUntilWorkOrDone`.
- On a stop request it stops claiming, scans its ring, then `publishAll`, `returnTickets`,
  `goIdle`, and exits **without** setting done.
- A stopped episode leaves every unscanned entry in a deque (IM15). Relaunching it (a fresh
  `SliceControl`) resumes marking.
- **Stop latency:** at most one ring (≤ 16 entries, at most one 1,024-slot chunk each) plus one
  backoff sleep (50 µs) per member, *provided the member gets CPU* (trap 2).

**The loop's other exit** is the 5b one: termination. Termination sets done, and every Member
then exits. Its private stack is empty (a Member idles only with an empty stack), so the
exit-time `publishAll` is a no-op for Members that exit through termination. IM15 checks it.

**The Env contract** gains `publishAll(self)` and `participant(self)`. `SerialEnv` implements
neither role nor stop (a serial run is always one Member with budget semantics). `OldGenSpace`
and the TSan harness instantiate the same template, as in 5b.

### 3.4 The background gang (`GCBackgroundGang`)

A new std-only class in `GCHelperPool.hpp/.cpp`, so that it compiles into the TSan harness.
**One instance per `OldGenSpace`**, created lazily at the first launch and owned through a
`unique_ptr`. It is not a singleton, because the process-wide `GCMarkGang` serialises runs, and a
background episode lasting seconds would block another heap's in-pause slice (F6).

```cpp
class GCBackgroundGang {
public:
    using Fn = void (*)(void* ctx, unsigned member);   // member in [0, members)
    struct Options { unsigned members; int priority; unsigned jitter_us; };
    explicit GCBackgroundGang(const Options&);          // registers in the process registry
    ~GCBackgroundGang();                                // stopAndJoin(); joins threads; unregisters
    // Precondition: !running(). Members run fn(ctx, j), j < members, on parked threads
    // (started lazily, priority applied once at thread start). Returns immediately.
    // `stop` is the episode's SliceControl::stop; the gang sets it in stopAndJoin().
    void launch(Fn fn, void* ctx, std::atomic<bool>* stop);
    bool running() const;           // launched and not yet joined; mutator-owned, exact
    bool finishedApprox() const;    // every member returned (acquire); a HINT (rule 4)
    void join();                    // blocks until every member returned; no-op if !running()
    void stopAndJoin();             // *stop = true (release), then join()
    struct Stats { std::atomic<uint64_t> launches, member_cpu_ns, join_wait_ns_total,
                                         join_wait_ns_max, stop_wait_ns_max; };
    const Stats& stats() const;
    static void stopAllForFork();   // atfork prepare: stopAndJoin every registered instance
    static void stopAllAtExit();    // std::atexit, registered at the first launch
private:
    std::mutex m_; std::condition_variable cv_start_, cv_done_;
    uint64_t generation_ = 0; unsigned finished_ = 0;  // guarded by m_
    std::atomic<unsigned> finished_pub_{0};             // finishedApprox
    bool running_ = false;                              // mutator-owned
    Fn fn_ = nullptr; void* ctx_ = nullptr; std::atomic<bool>* stop_ = nullptr;
    std::vector<std::thread>* threads_ = new std::vector<std::thread>();  // leaked in a fork child
};
```

- **Member thread loop.**
  - Wait on `cv_start_` for a new generation, and copy `fn_`/`ctx_`.
  - Optionally sleep a random 0 … `jitter_us` (the determinism probe, F22).
  - Run `fn`, then add the thread's CPU delta.
  - Under `m_`: `++finished_`, `finished_pub_.store(finished_, release)`, and notify `cv_done_`.
- **`launch`.** Under `m_`: set `fn_`, `ctx_`, `stop_`, `finished_ = 0`,
  `finished_pub_ = 0`, `++generation_`, then notify all; then `running_ = true`. The mutex
  release publishes everything the mutator wrote to the slots before the launch.
- **`join`.** Wait on `cv_done_` for `finished_ == members`, then `running_ = false`. The mutex
  acquire publishes everything the members wrote. The wait time is added to the stats.
- **Priority** is applied by each thread to itself at thread start, once (F20: it is one-way):

  | `priority` | effect |
  |---|---|
  | 0 | inherit |
  | 1 … 19 | `setpriority(PRIO_PROCESS, gettid(), p)` |
  | 20 | `sched_setscheduler(0, SCHED_IDLE, …)` |

  Other platforms: priority 0 only (macOS/Windows get a TODO and a warning in the banner).
- **Threads** are named `eco-cmark-%u` and created at the first launch, never per cycle.
- **Fork.** `atforkPrepare` (a new registration next to the pool's and the mark gang's) calls
  `stopAllForFork()`: under the registry mutex, `stopAndJoin()` on every running instance.
  - The parent continues with a stopped episode. The owner relaunches it at its next step
    (P§3.5).
  - The child forgets its threads (the vector is leaked, as the pool does), sets
    `running_ = false`, and restarts threads lazily at its next launch.
  - Because `stop` was honoured, the child's slots hold every unscanned entry in their deques,
    so its cycle completes too (tested).
- **Exit.** `stopAllAtExit()` is registered with `std::atexit` at the first launch.
  - Static objects constructed before that registration (the `Allocator`, the heaps) are
    destroyed after the handler runs. So no background thread can read a heap that is being
    torn down.
  - `~GCBackgroundGang` also stops and joins, for heaps destroyed explicitly (tests, the
    multi-heap driver).

### 3.5 The step logic in mode 2

New state on `OldGenSpace` (mutator-owned):

```cpp
enum class BgEpisode : uint8_t { None, Running, Finished };
BgEpisode bg_ep_ = BgEpisode::None;
std::unique_ptr<markwork::SliceControl> bg_ctl_;    // the running episode's control
uint32_t bg_done_k_ = 0;                            // stats: first step that saw it finished
```

**Launch (end of `startMarkCycle`, T ≥ 1, mode 2).** Place it **after** the IM1 record half and
after every other t0 action, so that nothing the mutator does in the t0 pause races with a
marker.
1. `publishAll(slot 0)` (the snapshot's greys went onto slot 0's private stack and deque).
2. **Distribute.** Take every entry off slot 0's deque (as owner), and push entry j onto
   background slot `F + (j mod B)`'s deque. Those deques are quiescent, so the mutator acting
   as their owner is legal; the launch's mutex publishes the transfer (IM14 asserts that the
   gang is not running).
3. `bg_ctl_ = make_unique<SliceControl>(kDrainBudget, n = mark_slots_, jitter)` with
   `state.active = B`.
4. `bg_->launch(&OldGenSpace::bgEntry, this, &bg_ctl_->stop)`. `bg_ep_ = Running`.

`bgEntry(ctx, j)` runs `runMarkerLoop` as participant {self = F + j, Member, pool =
&bg_ctl_->budget, joined = false}.

**`reapBg()`** (mutator; used at every step and every finish path):

```
if bg_ep_ == Running && bg_->finishedApprox():
    bg_->join()                                    // exact publication
    merge: every bg slot's counters -> cycle_units_, pm stats; retire every slot's old arrays (P§3.6 H10)
    bg_ep_ = bg_ctl_->done() ? Finished : None     // None = it was stopped (fork): relaunch below
    if bg_ep_ == Finished and bg_done_k_ == 0: bg_done_k_ = cycle_k_   (stats only)
if bg_ep_ == None && work remains (markStackEmpty() is exact here: nothing runs):
    relaunch (a fresh bg_ctl_, no redistribution: the work is already in deques)
if bg_ep_ == None && no work: bg_ep_ = Finished
```

**Step k (`runCycleStepConcurrent`, called by `stepMarkCycle` instead of `runCycleSlice` in
mode 2).**

```
reapBg()
if k == T:                                   // closing
    closingFinish()                          // below; state HandoffDue
    return
if bg_ep_ == Finished: return                // pause kind 0: nothing in the pause
// paced assist (pause-only decision, rule 4)
U = cycle_units_ + bgConsumedApprox()        // kDrainBudget - bg_ctl_->budget (over-counts
                                             // by at most 256 * B claimed-but-unscanned tickets)
if !markStackEmptyApprox() && U >= cycle_predicted_:
    cycle_predicted_ = max(cycle_predicted_, U) * 2           // 5b's doubling, reused
H = ceil(T / 2);  L = conc_mark_assist_lag
expected = (k <= L) ? 0 : cycle_predicted_ * min(1, (k - L) / H)
deficit  = expected > U ? expected - U : 0
if deficit >= incremental_mark_min_slice_units:
    a = min(deficit, b_k)                    // b_k = 5b's slice budget at k (runCycleSlice's formula)
    assist(a)                                // pause kind 4
```

**`assist(a)`.** `GCMarkGang::run(assistEntry, ctx, F)`:
- each foreground member i < F runs `runMarkerLoop` as participant {self = i, Assist, pool =
  &assist_budget (initialised to a), joined = true};
- after the run, `cycle_units_ += a − assist_budget` (exact: foreground counters are joined);
- `in_slice_` is set around the call (5a's IM9 still holds).
- **Do not retire any deque's old arrays after an assist** while `bg_ep_ == Running`: a
  background thief may still hold a pointer into a foreground deque's retired array (trap 6).

**`closingFinish()`** (k = T; the pressure finish and the join reuse it):

```
reapBg()
if bg_ep_ == Running:
    GCMarkGang::run(closingEntry, ctx, F)    // each fg member: {i, Member, &bg_ctl_->budget, joined = true}
                                             // members idle until done (they wait for bg members too)
    bg_->join(); merge (as reapBg); bg_ep_ = Finished
elif !markStackEmpty():                      // no episode running (stopped by a fork): 5b drain
    runMarkers(kDrainBudget)
assert(markStackEmpty())                     // exact: nothing runs
retire every slot's old arrays; bg_ep_ = None; bg_done_k_ recorded
```

**Pressure finish and join.** `finishMarkCycleNow` calls `closingFinish()` instead of
`drainCycleMark()` when `bg_ep_ != None`, then `completeMarkCycle` as today.

**`OldGenSpace::reset` and destruction.** If an episode is running: `bg_->stopAndJoin()`, merge,
then the existing reset (which drops the cycle).

**Pause kinds.**
- A step that ran an assist or a closing with work sets the slice flag (kind 4).
- A step that only reaped sets nothing (kind 0).
- t0 is kind 3 and the handoff kind 5, as before.

**Mode 1 (sync).** At the launch point, instead of launching: `runMarkers(kDrainBudget)`, the 5b
parallel drain inside the t0 pause. `bg_ep_ = Finished`. The steps do nothing, and the closing
step asserts `markStackEmpty()`.

**The handoff** asserts `bg_ep_ != Running` (IM14) and runs unchanged.

### 3.6 The shared-state audit (the §3.5 table of the report, for this code)

Every location a background marker reads, or that the mutator writes while an episode runs. Step
0 re-derives this table with greps (listed per row) and records any new site. The column "fix"
is the whole of D1/D2.

| # | location | mutator writes during an episode | marker access | fix | grep to re-derive |
|---|---|---|---|---|---|
| H1 | mark bytes of **t0** blocks | `initObjectHeaderWithSize` → `setMarkBitInBlock` (plain RMW) for mixed free-list pops, splits, bag pages, free-large reuse (F7) | `fetch_or` / `exchange` | in the `marking_active \|\| gc_phase_ != Idle` branch, use `setMarkBitAtomic`: `atomic_ref<uint8_t>::fetch_or(mask, relaxed)` (large: `store(1, relaxed)`). This is §5.3 option A, restricted to the slow path | `setMarkBitInBlock\|bitscan::setBit\|largeMark(` |
| H1b | mark bytes of **post-t0** blocks | `finalizeBitmapCell` plain `setBit` (the hot promotion path) | never (no S_H object lives in a post-t0 block) | none; **IM13** asserts that the cursor never owns a t0 block during a cycle (F8) | `setCursor\|refillCursor` |
| H2 | mark bytes read by mutator validators | — | writes them | `isMarkedInBlockRelaxed` (atomic_ref loads) in the minor validate walk, `assertCellWasWhite`, `noteCycleAllocation`; IM6 mid-cycle runs only when no episode runs (P§3.9) | F9 list |
| H3 | `PageOwners.primary/secondary` | `assignPageIndexForBlock` for new blocks (a slot may be shared with a t0 block) | read in `blockIdFor` | stores via `atomic_ref<uint32_t>::store(release)`; reads in `blockIdFor` via `load(acquire)` (both variants: a plain `mov` on x86) | `\.primary\|\.secondary` |
| H4 | `ReservedArray::committed_` (page index, BlockInfo table, mark arena `len_`/`bytes_`, every accumulator) | `ensureCommitted` on new blocks | `committed()` in `blockIdFor`, asserts in `operator[]` | `std::atomic<size_t>`: `store(release)` after the commit syscall, `load(acquire)` in `committed()` and in the asserts. `committed_bytes_` stays mutator-only | `committed_` in `ReservedArray.hpp` |
| H5 | `region_base_` / `region_end_` | 15 write sites (F10) | the `blockIdFor` range check | one helper `setRegionBounds(base, end)` with `atomic_ref<char*>::store(relaxed)` at every write site; `blockIdFor` loads with `atomic_ref<char*>::load(relaxed)`. **Why relaxed is enough:** during a cycle the region only grows (releases are deferred, IM5), so a stale value still covers every t0 block | `region_end_ =\|region_base_ =` |
| H6 | nursery bounds `low/high_base/end_` | `updateBounds` on nursery growth inside a minor GC | `nursery_->contains` in `greyObject<ParallelMark>` | `MarkView` reservation bounds (P§3.2) | `nursery_->contains` in the mark templates |
| H7 | `cycle_state_`, `snapshot_mode_` | the step logic, t0 | `greyObject`, `scanChildren`, `im10NoteScan` | compile-time for `ParallelMark`; `im10_armed_` (P§3.2) | `cycle_state_\|snapshot_mode_` inside templates |
| H8 | the YLOS index (`large_body_index_`, `unordered_map`) | the minor GC (registration, deferral, in-place promotion) | validate-only `isYoungLarge` in IM3 and HEAP_BUILDER_001 | `MarkView::ylos_t0` (P§3.2); release builds never read it | `isYoungLarge\|mayBeYoungLarge` inside templates |
| H9 | `BlockInfo` of any block reachable from a page slot | `blocks_.add` for new blocks (before the H3 release store); `:1913-1914` (flip of a post-t0 block); `:3030` (tail) | `start`, `end`, `is_large`, `size_class` | **no change.** `start`/`end` never change while a block is referenced from a page slot (F13); the marker reads `is_large`/`size_class` only of the block that contains an S_H object, i.e. a t0 block, which IM5 proves unchanged; there are no bitfields. Validate builds: `:1913` asserts `!cycleActive() \|\| !isT0Block(id)` | the F13 list |
| H10 | slot deques, private stacks, counters, accumulators | t0 distribution, merges, deque `reset`, `retireOldArrays` | own slot; others' `top` via `steal` | mutator touches a slot's owner-only state only while no gang runs on it (IM14). `retireOldArrays` and `reset` run only when `bg_ep_ != Running` and no foreground run is active (trap 6) | `retireOldArrays\|deque.reset\|\.ctr\.` |
| H11 | `alloc_stats_` (pm, cm) | the mutator | never (markers write their own counters) | merges only after a join | `alloc_stats_.pm` |
| H12 | test hooks read by markers (`test_plain_bits_parallel_`, …) | tests | read | written only when no episode runs (asserted in the setters) | `test_.*_` in `OldGenSpace.hpp` |
| H13 | `markers_[]` `unique_ptr`s, `mark_slots_`, `mark_parallel_` | `ensureMarkers` at initialize/reset; `beginMarkCycle` | read | reset stops the episode first; `beginMarkCycle` runs with none | `ensureMarkers` |
| H14 | S_H object fields and headers | none (P1, HEAP_SNAPSHOT_001, enforced in validate) | read | none; bodies are complete at t0 (F25) | — |
| H15 | `config_`, `allocator_ref_`, `heap_base`/`heap_reserved`, `index_base_` | none after init | read | none; Step 0 confirms `index_base_` is set once | `index_base_ =` |

**Anything not in this table that a marker reaches is a bug.** D9's heap-level TSan build is
the mechanical check. Without D9, the check is Step 0's grep audit plus the concurrent-mode
validate tree.

### 3.7 Allocate-black under a running episode

5a's Claim 3 (every in-cycle old-gen allocation is black) must survive concurrent marking. Two
things change:
- **The bit set itself must not lose a marker's bit** (H1). A plain RMW on a byte whose other
  bits a marker is `fetch_or`-ing can erase the marker's bit. The marker has already pushed the
  object, so it will be scanned, but its bit is gone. The sweep then frees a live object.
  `setMarkBitAtomic` closes it.
- **The cost stays off the hot path.** Promotions into uniform classes go through the cursor,
  which during a cycle owns only post-t0 blocks (F8). No marker touches those bytes, so
  `finalizeBitmapCell` keeps its plain `setBit`. **IM13** makes this premise an assertion:
  `setCursor` and `refillCursor` abort in validate builds when `cycleActive()` and the block is
  in `cycle_t0_blocks_`. Step 0 counts the mid-cycle non-cursor allocations on the
  self-compile (a temporary counter) to price the atomic path. The expectation is well under
  1 % of promotions.

The bytes attributed by allocate-black (`BufferMetadata::live_bytes += cell`) stay
mutator-only: markers write only their accumulators (HEAP_051). Nothing changes there.

### 3.8 Validate builds, forks and the exit path under a running episode

- **Validators that run at a minor end during a cycle:**
  - IM3 and IM4 need no change: IM3 is H8; IM4's reads are H2.
  - IM6 reads every accumulator, which a running member writes. In mode 2 it runs only
    at steps where `bg_ep_ != Running` after `reapBg()`, plus the exact check at the handoff.
  - The minor GC's validate walk uses relaxed loads (H2).
  - The P1 census hooks at a minor end read only nursery objects and objects promoted in that
    minor (N_H). Step 0 confirms it by reading `P1Census.cpp`.
- **IM1/IM2/IM11/IM12** run at the handoff, where nothing runs.
- **Forks happen only in tests** (F19), and `GCBackgroundGang::stopAllForFork` makes them safe
  (P§3.4). `GCMarkGang::atforkPrepare` keeps its "no run in progress" assumption: foreground
  runs happen only inside pauses, and tests fork outside pauses.
- **Exit:** `stopAllAtExit` (P§3.4).

### 3.9 Validators and negative controls (new)

| # | Checks | Where | How |
|---|---|---|---|
| IM13 | the cursor never owns a t0 block during a cycle | `setCursor`, `refillCursor` (validate) | `cycle_t0_blocks_` (exists since 5a IM5) as a sorted id vector; `binary_search` |
| IM14 | the mutator touches a slot's owner-only state only while no gang runs | distribution, merge, `retireOldArrays`, `deque.reset`, the handoff | `assert(!bg_ || !bg_->running())` plus a `fg_run_active_` flag around `GCMarkGang::run`; every build (two loads) |
| IM15 | no private work after any run | after every `GCMarkGang::run` and every `bg_->join()` | every slot's `priv == 0` and `stack.empty()`; every build (cheap: ≤ 64 slots) |
| IM16 | background progress never decides | the decision paths | a validate-only `decision_reads_progress_` guard: `bgConsumedApprox()` and `finishedApprox()` assert that they are not called under `evaluateMajorGCTrigger`, `cyclePressureFinishDue`, or any allocation-ladder function (a scoped flag set by those functions) |

IM1–IM12 are unchanged and stay on. **IM11/IM12 are the strong end-to-end check of Part A.** At
every handoff, in every mode, the scanned objects equal the closure of the t0 greys, and the
entries scanned equal the tickets consumed. Concurrency changes neither.

**Negative controls** (each in a forked child, validate build, as in 5a/5b):
- `test_skip_bg_merge_`: `reapBg` skips merging background slot F's counters. IM12 fires at the
  handoff (after first asserting that slot F scanned something).
- `test_leave_private_on_exit_`: `publishAll` is skipped at run exit. IM15 fires after the
  first run in which a private stack was non-empty.
- `test_cursor_takes_t0_block_`: at the first step, push a t0 uniform block with free cells onto
  `partial_`. IM13 fires on the next refill.
- `test_plain_allocate_black_`: H1 reverted to the plain RMW. The race is not guaranteed to fire.
  Run it 200 times on a heap built for collisions: mixed blocks with interleaved live t0
  objects and free cells, promotions forced into those cells, and jitter on. Pass if IM1 or
  IM4 fires at least once; record the rate. If it never fires, record that, and rely on D9 for
  H1.

### 3.10 Determinism: decision counters vs progress counters

**Decision counters** must be identical across modes, across B and under jitter (rule 1):
- minors, majors (cycles), allocated, promoted, copied (objects and bytes);
- old-gen peak, max committed, releases, deferred frees and their bytes;
- per-major before/after/garbage/recovered (event log), trigger reasons, finish reasons
  (schedule/pressure/join);
- **total units per cycle** and `prev_cycle_units_`;
- black bytes, traced live;
- P1 census counts.

**Progress counters** may differ across modes (they are timing-like):
- per-slice units, `closing_units`, assist count and units, background units;
- pause-kind counts (kind 4 vs 0);
- steals and idle stats, `done_k`, stop and join waits.

**Every read of collector progress, and what it may influence:**

| read | used for | may influence |
|---|---|---|
| `bg_->finishedApprox()` | `reapBg` | when counters are merged; whether to relaunch |
| `bgConsumedApprox()` | the assist deficit | the assist budget |
| `markStackEmptyApprox()` | the doubling of `cycle_predicted_` | the assist budget |
| `bg_ctl_->done()` after the join | `bg_ep_` | whether the closing step must drain |

None of these reaches a trigger, the schedule, the allocator or the tail: IM16 checks that.
`cycle_predicted_` at t0 depends only on `prev_cycle_units_` (a decision counter) and occupancy.

**Where the "the mark set is the same" argument comes from.** Marking is monotone and complete
from the t0 grey set over a frozen S_H (5b-P§3.3). The final mark set is the closure plus
allocate-black, whatever the interleaving. Everything the tail decides is a function of that
set and of mutator allocation.

### 3.11 Part B: heap-relative trigger pacing

All of Part B is mutator-side and deterministic. Nothing reads collector progress.

**The promotion-rate estimate `P̂`.**
- `old_alloc_total_` (new, `uint64_t`, monotone) is incremented next to every
  `allocated_bytes +=` (the 7 sites of F17), by the same amount. Sweeps and frees never lower it.
- At every minor end, in `ThreadLocalHeap::minorGC` right after `nursery_.minorGC` (before the
  cycle step or the trigger):

  ```
  s = old_alloc_total_ - old_alloc_at_prev_minor_
  old_alloc_at_prev_minor_ = old_alloc_total_
  P̂ = P̂ + (s - P̂) / 8          // int64 arithmetic: deterministic on every platform
  ```
- `P̂` covers promotions and direct old-gen allocations (large objects, bodies, permanent
  objects): everything that consumes old-gen capacity between minors.

**The horizon.** `H_c = T + 1` minors (T = `incremental_mark_slices`; 1 for T = 0 cycles). This
is the fixed schedule: GC_DET_001 makes the cycle's length in minors a known constant, so no
mark-time prediction in seconds is needed. **This is what "promotion rate × predicted mark time"
means here.**

**The `Headroom` trigger** (new `MajorGCTriggerReason::Headroom`, evaluated after
GlobalPressure):

```
margin = major_gc_headroom_margin              // 0 = off
if margin > 0 && cap > 0 &&
   global_committed + margin * H_c * P̂ >= incremental_mark_finish_fraction * cap:
       return Headroom
```

It starts the cycle when the bytes that will be allocated black during it would otherwise
carry the heap into the pressure finish. At the 15 GB self-compile it should rarely fire. At a
4 GB cap it replaces pressure finishes.

**The paced `LiveBudget`** (`major_gc_live_budget_paced`, bool):

```
alloc_since_major + (paced ? H_c * P̂ : 0) >= k * live_ref
```

The budget is reached at the handoff instead of at t0, so the old-gen peak lands on the goal
(`live_ref · (1 + k)`, the Go pacer's heap goal) whatever T is. It removes the T-dependence of
the peak by construction.

**The garbage-fraction backstop** (`major_gc_garbage_backstop`, float, 0 = off). When it is
> 0 and `major_gc_live_budget > 0`, the GarbageFraction trigger uses
`max(major_gc_garbage_fraction, backstop)`. LiveBudget, which is growth-bounded, then does the
routine scheduling, and gf remains an anti-runaway backstop.
- **Hypothesis:** the ±30 % peak chaos is gf sizing the heap on a transient live peak
  (TG2 memory).
- E8 tests the hypothesis before E9 relies on it.

**Event-log columns (stats builds, all modes):** `reason`, `p_hat`, `h_c`, `live_ref`,
`alloc_since_major`, `headroom_bytes`. E8 is built from them.

### 3.12 Configuration

`HeapConfig` fields, each with a compiled default in `AllocatorCommon.hpp`, a JSON key in
`HeapConfigJson.cpp` (the known-key list and a parse block), a line in `HeapConfigJson.hpp`'s key
comment, and a `validate` rule:

| field | type | default (until the E flips) | parse | `validate` |
|---|---|---|---|---|
| `conc_mark` | `uint32_t` | `CONC_MARK = 0` | `parseU32` | ≤ 2 |
| `conc_mark_threads` | `uint32_t` | `CONC_MARK_THREADS = 0` (auto) | `parseU32` | ≤ 63 |
| `conc_mark_threads_cap` | `uint32_t` | `CONC_MARK_THREADS_CAP = 4` (provisional; E2 sets it) | `parseU32` | [1, 63] |
| `conc_mark_priority` | `int32_t` | `CONC_MARK_PRIORITY = 10` (provisional; E4 sets it) | `parseI32` | [0, 20] |
| `conc_mark_assist_lag` | `uint32_t` | `CONC_MARK_ASSIST_LAG = 4` (provisional; E2 sets it) | `parseU32` | ≤ 4096 |
| `major_gc_headroom_margin` | `double` | `0.0` (off) | double | [0, 8] |
| `major_gc_live_budget_paced` | `bool` | `false` | `parseBool` | — |
| `major_gc_garbage_backstop` | `float` | `0.0` (off) | fraction | 0, or in (`major_gc_garbage_fraction`, 1) |

**Resolution** (`OldGenSpace::resolveConcMarkThreads(cfg, F)`):
- B = 0 when `conc_mark != 2`, `!incremental_mark` or `!old_gen_bitmap_alloc`;
- otherwise `conc_mark_threads`, or for auto `min(cap, max(1, availableCpus() − 1))`;
- then clamp to 64 − F.

The mutator's core is excluded from auto: the background shares the machine with it.

**Environment** (the environment wins over JSON, parsed next to `applyMarkThreadsEnv`, F22):
- `ECO_GC_CONC_MARK`: exactly one character, `0`, `1` or `2` (the TG3 one-character rule);
- `ECO_GC_CONC_MARK_THREADS`: decimal 0 … 63.

`ECO_GC_HELPER_JITTER_US` also drives the background gang's jitter. Part B knobs have no
environment variable: the GC loop varies them through `ECO_HEAP_CONFIG` JSON with paths of
equal length.

### 3.13 Stats, pauses and measurement

**`ConcMarkStats cm`** in `GCStats` (old gen `alloc_stats_`; `combine` sums and maxes; carried
through `ElmE2ETestBase`'s POD like `im` and `pm`):
- **episodes:** `episodes_launched`, `episodes_relaunched`, `episodes_stopped`, `bg_units`;
- **assists:** `assists`, `assist_units`, `assist_ns_total/max`;
- **closing:** `closings_with_work`, `closing_units`, `closing_ns_total/max`;
- **finish time:** `done_k_hist[5]`: cycles whose background finished by k ≤ T/4, ≤ T/2,
  ≤ 3T/4, ≤ T, or not before the closing step;
- **background threads:** `bg_cpu_ns` (from the gang), `bg_wall_ns_total` (launch to first
  finished reap), `stop_wait_ns_max`, `join_wait_ns_max`;
- **mutator CPU:** `mutator_cpu_ns` (`CLOCK_THREAD_CPUTIME_ID` of the mutator at process
  exit) and `mutator_pause_cpu_ns` (thread CPU accumulated inside `GCPauseScope`).

**Report the decomposition** (§10, M§2 from phase 3 on):
- wall;
- mutator CPU outside pauses (`mutator_cpu_ns − mutator_pause_cpu_ns`);
- **interference** = that value in mode 2 minus that value in mode 0, same session;
- collector CPU (background + foreground gangs);
- **stall** = assists + closing work;
- pause max, p99 and MMU.

**Banner:** a "Concurrent Mark (threaded-gc-05c)" block with the fields above.

**Event log:** the `cycle` row gains `bg_units`, `assists`, `assist_units`, `closing_units`,
`done_k`, `bg_wall_ms`. Teach `benchmarks/gc-event-log-summary.py` these columns, the `done_k`
distribution and the Part B columns.

---

## 4. Steps

Every step ends with `cmake --build build --target check` green. Steps 1–7 also build the
validate tree's `test` target and run the phase's tests there.

**Before you start:** run `benchmarks/lss-loop-snap.sh verify keep-TG5b`, then take snapshot
`try-TG5c-pre`.

### Step 0 — facts, baseline, audit, feasibility (no code change)

1. **Re-verify F1–F25** and fix the line numbers. Re-run the priority probe (F20):

   ```bash
   g++ -O1 -pthread prio.cpp -o prio && ./prio
   ```

   The program is 25 lines: it sets a thread to SCHED_IDLE, then tries IDLE→OTHER and nice
   19→0 on it from another thread. Write it into the scratchpad and record the output.
2. **Same-session baseline with `eco-optTG5b`:**
   - a triple in the stats build;
   - one phase-timer run with `ECO_GC_EVENT_LOG`;
   - record: wall, GC time, minors, majors, per-cycle units, per-kind pause max/p99, MMU at
     50/100/200/500 ms and 1/2 s, slice mark total, t0 prepare vs snapshot split, handoff tail
     split (`[gc-profile] cycle handoff` lines with `ECO_GC_PHASE_PROFILE=1`), collector CPU,
     old-gen peak, max RSS.
3. **Fill in the audit (P§3.6).** Run every grep in the table and list each hit with a verdict.
   Add rows for anything new. Record the table in P§10 before writing code.
4. **Price H1.** Add a temporary counter of `initObjectHeaderWithSize` calls with
   `cycleActive()` (and, separately, `finalizeBitmapCell` calls with `cycleActive()`). Run it on
   the self-compile and record the ratio. Remove it afterwards.
5. **D9 feasibility (time-box: half a day).** Try to build a standalone executable with g++
   12, `-fsanitize=thread -O1 -g -DECO_HEAP_VALIDATE=1`, from the allocator sources the unit
   tests' allocator suites link, plus a 50-line `main` that initialises an `Allocator` and
   allocates.
   - **Record:** which sources it needs, and whether stack unwinding (`StackUnwind.cpp`) or
     `RuntimeExports.cpp` pull in kernel or LLVM symbols.
   - **Verdict:** feasible (Step 8 builds it) or not (Step 8 is skipped and recorded, and H1–H15
     rest on the audit plus the validate tree).
6. Check that `index_base_`, `heap_base`, `heap_reserved` and `nursery_offset` are written only
   at initialisation (H15).

### Step 1 — D1: slots, `publishAll`, `MarkView` (refactor; counters identical)

1. `mark_slots_` (P§3.2). B is still 0, so slots = F: change every F16 loop that is about
   *slots* (accumulators, deques, `markStackEmpty/Size`, `commitThrough`, reserve, handoff
   reset) to `mark_slots_`, and keep `runMarkers`' gang size at F.
2. `SliceControl::n` becomes the victim range. `stealAny` and `anyWork` iterate `n` slots;
   the participant count is no longer implied by `n`, and the initial active count is set
   explicitly by the caller.
3. `publishAll(w)`; call it at every exit of `runMarkerLoop` in parallel mode (through the Env).
4. `MarkView` filled in `beginMarkCycle`. `ParallelMark` reads the view (H6, H8), and the
   `cycle_state_`/`snapshot_mode_` reads become `if constexpr` (H7). Add `im10_armed_`.
5. IM15 (every build).
6. **Gate:**
   - every counter, **per-slice units included**, identical to `eco-optTG5b` at
     `ECO_GC_MARK_THREADS` 01 and 16 (stats build, one run each, same session);
   - `out.mlir` identical;
   - `ParallelMarkTest` and `IncrementalMarkTest` pass at 1 and 4 markers.

   If the mark time moves with identical instructions, check the loop alignment first (5b
   trap 10).

### Step 2 — D2: shared-state hardening (counters identical)

1. **H1:** `setMarkBitAtomic` in `initObjectHeaderWithSize`'s cycle branch (large blocks:
   atomic store).
2. **H3:** `assignPageIndexForBlock` stores owners with `atomic_ref<uint32_t>::store(release)`;
   `blockIdFor` loads them with `load(acquire)`. The code that clears slots at release (in the
   tail) also uses atomic stores.
3. **H4:** `ReservedArray::committed_` → `std::atomic<size_t>` (release store, acquire loads).
   Fix every reader.
4. **H5:** `setRegionBounds` helper at all 15 write sites; relaxed atomic loads in
   `blockIdFor` and `contains`.
5. **H2:** `isMarkedInBlockRelaxed`, used by the minor validate walk, `assertCellWasWhite` and
   `noteCycleAllocation`.
6. **H9:** the validate assert at `:1913`. **H12:** the test-hook setters assert that no episode
   is running.
7. IM13 and IM14.
8. **Gate:**
   - counters identical to Step 1's binary;
   - `out.mlir` identical;
   - validate tree: unit + E2E + stress at 1 and 16 markers, zero `[heap-validate]` lines;
   - mark and minor time within noise of Step 1 (the new atomics are plain moves on x86;
     check the alignment trap if not).

### Step 3 — D3: loop roles, join, leave, stop; TSan episode storm

1. `Role`, `Participant`, pool-parameterised tickets, the join entry, the Assist exit rule, and
   `SliceControl::stop` (P§3.3). `runMarkers` passes {i, Member, &c.budget, joined = false} for
   5b runs, so its behaviour is unchanged.
2. **TSan harness** (`test/gc-helper-tsan/mark_harness.cpp`): add an **episode storm** on the
   existing synthetic graph (private stacks, chunk-like wide nodes):
   - B = 2 … 8 "background" threads run a Member episode with a drain budget;
   - a "mutator" thread repeatedly, at random intervals:
     - (a) runs Assist joins with 1–3 extra threads and random budgets;
     - (b) sets bits with `fetch_or` in bytes shared with graph nodes (allocate-black analogue:
       reserved phantom nodes that are never reachable, interleaved with real ones);
     - (c) requests a stop, joins, and relaunches a fresh control;
     - (d) at a random point, runs a closing join with Members and waits for termination.
   - **Checks:**
     - the marked set of real nodes equals the reachable set;
     - every phantom bit set by the mutator is still set at the end (no lost update);
     - the total units equal the closure size exactly;
     - no private work remains after each exit;
     - no TSan report.
   - Run with n = 1 … 16 slots, with jitter 0 and 50 µs, normally and under `taskset -c 0,1`.
3. **A regression check for the Assist exit rule:** a variant that calls `goIdle` *before*
   `publishAll` must fail the reachable-set check (build it once with a harness `-D` flag,
   confirm that it fails, and record it; do not keep it in CI).
4. **Pass:** the harness exits 0 with no "WARNING: ThreadSanitizer", three runs each, including
   the oversubscribed ones.

### Step 4 — D4: `GCBackgroundGang`

1. The class (P§3.4), including the registry, the atfork prepare/child hooks and `atexit`.
2. Unit tests (`test/allocator/GCBackgroundGangTest.cpp`, normal tree):
   - `testBgGangLaunchJoinEveryMemberOnce`: members 1 … 8, 1,000 launches; every index exactly
     once per launch; `join` returns only after all have returned;
   - `testBgGangStopAndJoinBounded`: members spin until they see stop; `stopAndJoin` returns
     within 100 ms;
   - `testBgGangPriorityApplied`: with priority 10, `getpriority(PRIO_PROCESS, tid)` of each
     member is 10; with 20 the policy is `SCHED_IDLE` (Linux only);
   - `testBgGangForkWhileRunning`: fork while members spin. In the parent, the episode is
     stopped and a relaunch works. In the child, `running()` is false and a launch starts fresh
     threads;
   - `testBgGangDestructorStops`: destroying a gang with a running episode stops and joins it.
3. TSan harness: a **bg-gang storm**: 50,000 launch/join cycles and 5,000 stop/join cycles
   with random member counts, plus 20 forks while running (the child launches once and exits).
   Clean under TSan.

### Step 5 — D5: configuration

1. The fields, defaults, JSON, `validate` rules and environment variables of P§3.12.
2. `resolveConcMarkThreads`, and `mark_slots_ = F + B` at `initialize`/`reset`.
3. Tests:
   - `testConcMarkConfigJson`: every key round-trips, and invalid values are rejected;
   - `testConcMarkEnvOverrides`: the environment wins; `ECO_GC_CONC_MARK=3` is rejected;
   - `testConcMarkThreadsResolution`: auto under a 3-CPU affinity mask gives 2; clamped at
     64 − F; B = 0 when `incremental_mark` is off.
4. **Gate:** `conc_mark = 0`, counters identical.

### Step 6 — D6: the cycle driver in modes 1 and 2

1. `bg_`, `bg_ep_`, `bg_ctl_`; launch at the end of `startMarkCycle` (after the IM1 record
   half) with distribution; `reapBg`; `runCycleStepConcurrent`; `assist`; `closingFinish`; the
   pressure and join paths; reset and destruction; mode 1's inline drain (P§3.5).
2. The pause-kind rules (P§3.5) and `ConcMarkStats` counting (the banner comes in Step 7).
3. Tests (`test/allocator/ConcurrentMarkTest.cpp`, each at `conc_mark = 2` unless stated;
   helpers from `IncrementalMarkTest`; configs set explicitly because unit tests ignore
   `ECO_HEAP_CONFIG` in the old gen):
   - `testConcMarkMatchesPauseMark`: the same heap (about 200 k old objects, random graph)
     built twice; a T = 8 cycle at mode 0 and at mode 2 (B = 4). At HandoffDue the mark bitmaps
     of every t0 block, the per-block traced bytes and the cycle's total units are identical;
   - `testConcMarkRunsDuringMinorGCs`: while the episode runs (jitter 200 µs to keep it alive),
     drive minors that promote into **mixed** free cells interleaved with live t0 objects, plus
     large-string bodies and YLOS objects. Every rooted object survives the handoff, and IM1,
     IM2 and IM4 are clean (validate);
   - `testConcMarkUnitsExactAcrossB`: B ∈ {1, 2, 4, 8} and 4 + jitter; three consecutive
     cycles; every decision counter and every cycle's total units identical;
   - `testConcMarkAssistWhenLate`: a test hook `test_bg_hold_` makes background members wait
     on a latch before marking. Assists run at steps k > L, and the handoff is still at k = T + 1.
     Release the latch at k = T − 1: the closing step joins the running episode, and the total
     units are exact;
   - `testConcMarkClosingJoinsRunningEpisode`: the latch is held until after the closing step
     starts, released from a helper thread 20 ms later; the closing waits and completes;
     `closings_with_work == 1`;
   - `testConcMarkNoAssistWhenOnTime`: an idle machine, a small heap, T = 16: zero assists and
     `done_k_hist[0 or 1] == 1`;
   - `testConcMarkStoppedEpisodeRelaunches`: a test API stops the episode at step 2; the next
     step relaunches; `episodes_relaunched == 1`; units exact;
   - `testConcMarkJoinOnExplicitMajor`: `eco_major_gc()` while the episode runs: the join
     finishes the cycle through `closingFinish`, then the STW major runs;
   - `testConcMarkPressureFinish`: a small cap; promotions during the cycle cross the finish
     fraction at step 2; the cycle finishes in that pause;
   - `testConcMarkResetMidEpisode`: an `Allocator` reset while members run: the gang stops,
     and the next cycle is correct;
   - `testConcMarkForkDuringEpisode`: fork (through `IsolatedTestRunner`) while the episode runs.
     The child drives minors to the handoff and verifies survivors, then exits 0. The parent
     does the same;
   - `testConcMarkSyncModeMarksAtT0`: mode 1: `markStackEmpty()` right after t0; no background
     threads are created; the decision counters equal mode 2's on the same scenario;
   - `testConcMarkT0DistributesToBackground`: after the launch, slot 0's deque is empty and the
     background deques hold the t0 greys (inspected through test access after a
     `test_bg_hold_` launch);
   - `testConcMarkIncrementalOffNoBackground`: `incremental_mark = false` with 4 markers runs
     T = 0 cycles, and no background thread is ever created.
4. Rerun all of `IncrementalMarkTest` and `ParallelMarkTest` with `conc_mark = 2` (a second
   registration through a config switch in their config helpers).

### Step 7 — D7/D8: validators, negative controls, reporting

1. IM16. The four negative controls (P§3.9). Mid-cycle IM6 gated on `bg_ep_ != Running`.
2. Banner, event-log columns, summary script, `ElmE2ETestBase` plumbing (P§3.13).
3. The validate tree: unit, E2E and stress (default and pressure-incremental configs), each at
   `ECO_GC_CONC_MARK=0` and `=2` (with `ECO_GC_MARK_THREADS=04`). Zero `[heap-validate]`
   lines. Every negative control fires within its bound (record the plain-allocate-black rate).

### Step 8 — D9: `gc-heap-tsan` (only if Step 0 said feasible)

1. A CMake project `test/gc-heap-tsan` (g++, TSan) that compiles the allocator sources Step 0
   listed, plus `heap_driver.cpp`.
2. **The driver.**
   - Initialise an `Allocator` with explicit roots (`RootSet`, no stack maps).
   - Build a random old graph of about 300 k objects.
   - Loop, for 20 cycles: allocate young objects, some kept (rooted in a ring buffer) and some
     dropped; allocate large strings and YLOS arrays; force minors; force a trigger every
     ~50 minors.
   - Run with `conc_mark = 2`, B ∈ {2, 4}, jitter 0/50, T ∈ {4, 16}.
3. **Pass:** no TSan report; validators silent; the survivors' checksum is stable.
4. **Suppressions:** none, except one for `GCHelperPool` if phase 3's harness already needed it
   (check `README.md`).

### Step 9 — D10: Part A measurement and the default

1. Run E0–E7 (P§5).
2. If the decision rules pick B, a priority and a lag:
   - set `CONC_MARK = 2`, `CONC_MARK_THREADS_CAP`, `CONC_MARK_PRIORITY`,
     `CONC_MARK_ASSIST_LAG`;
   - rerun every gate default-on, plus the bootstrap fixed point;
   - take snapshot `try-TG5cA`.
3. If mode 2 fails a rule, leave `CONC_MARK = 0`, record why in P§10, and still ship Part B
   (it does not depend on the mode).

### Step 10 — D11: Part B mechanism (every knob off; counters identical)

1. `old_alloc_total_` at the 7 sites; `P̂` at every minor end; `Headroom` reason (enum, stats
   name, event log); the paced `LiveBudget`; gf backstop; config (P§3.12); census columns
   (P§3.11).
2. Tests (`test/allocator/TriggerPacingTest.cpp`):
   - `testPromoRateEwmaDeterministic`: a scripted promotion sequence gives the exact integer
     `P̂` expected;
   - `testOldAllocTotalMonotone`: sweeps and frees never lower it;
   - `testHeadroomFiresBeforePressure`: a 256 MB cap and a high promotion rate. With the margin
     off, the cycle gets a pressure finish; with margin 1.5, the `Headroom` reason fires earlier
     and the cycle finishes on schedule;
   - `testPacedLiveBudgetFiresEarlierByHorizon`: the same heap and allocation script; the paced
     trigger fires at `alloc_since_major` lower by `H_c · P̂` (± one minor's allocation);
   - `testGarbageBackstop`: with the backstop at 0.85 and LiveBudget on, gf does not fire at
     0.70 but does fire at 0.85;
   - `testPacingIgnoresMarkProgress`: mode 0 vs mode 2 with B = 1 and heavy jitter under the
     paced settings: identical trigger reasons and minors-at-trigger.
3. **Gate:** all knobs off; counters identical to Step 9's binary.

### Step 11 — D12: Part B measurement, decision, T

Run E8–E12 (P§5). Set the chosen defaults, then rerun every gate plus the fixed point.

### Step 12 — D13: docs, invariants, tracking

1. P§8 invariants.
2. THEORY.md: the Mark item (background episodes, assists, the closing join), and the trigger
   paragraph (P̂, Headroom, pacing).
3. The master plan:
   - the tracking row, the §5 pause table, and the 5c text;
   - the deviation "background gang, not the FIFO pool";
   - the out-of-scope items handed to phase 8: incremental t0 prepare (`clearForMark`) and an
     incremental handoff tail.
4. Loop entry `TG5c`; snapshot `keep-TG5c`; `bin/eco-opt-prev` = `eco-optTG5c`.

---

## 5. Measurement and experiments

**Method for every self-compile arm** (the 5a/5b method):
- one phase-timer binary, arms selected by `ECO_GC_CONC_MARK`, `ECO_GC_CONC_MARK_THREADS` or
  `ECO_HEAP_CONFIG`;
- env values and config paths of equal length across arms;
- runs strictly serial, with **no other load** (except E4/E5);
- a timeout of 2× the expected wall;
- `out_md5` verified;
- a run that did a package-registry POST (+157 allocated) is discarded and rerun (TG5b memory).

### Part A

**E0 — mode 0 reference (after Steps 2, 6 and 7).** `ECO_GC_CONC_MARK=0` vs `eco-optTG5b`, a
pair each, same session. Rule 2: every counter identical, per-slice units included.

**E1 — determinism (after Step 7).** One run each:
- `ECO_GC_CONC_MARK` ∈ {0, 1, 2};
- B ∈ {1, 2, 4, 8} at mode 2;
- mode 2 + `ECO_GC_HELPER_JITTER_US=50`.

Every decision counter (P§3.10), every cycle's total units, and the major event log's non-timing
columns are identical (hash the columns). **Any difference stops the phase.**

**E2 — B and the assist lag (after E1).** T = 32, mode 2.
- B ∈ {1, 2, 4, 8} at L = 4; then L ∈ {2, 4, 8} at the chosen B. One run each; a triple for the
  finalists.
- Record per arm:
  - assists (count, units, ns), closings with work, and the `done_k` histogram;
  - per-kind pause max/p99, MMU;
  - wall, `bg_cpu_ns`, mutator CPU outside pauses;
  - minor-only p50/p99/max.
- **Decision rule for B:** the smallest B with **zero assists and zero closings with work** over
  a triple, and every cycle's `done_k ≤ 3T/4`. Ties go to the lower collector CPU.
- **Decision rule for L:** the largest L that keeps assists at zero on the triple. A larger L
  means fewer false assists on a busy machine.

**E3 — interference and the minor pause (after E2).** A triple of mode 2 at the chosen B vs a
triple of mode 0, same session.
- Record: wall; mutator CPU outside pauses (**interference** = mode 2 − mode 0); collector CPU;
  minor-only p50/p99/max; MMU at 50/100/200/500 ms and 1/2 s.
- **Pass:**
  - median wall ≤ mode 0 + 1 %;
  - minor-only p99 ≤ mode 0 + 10 %;
  - worst pause ≤ mode 0's;
  - kind-4 pauses ≤ 7 per run (at most one closing per cycle; the target is 0).

**E4 — priority under co-runners (after E3).** The mutator must win over the background, and a
starved background must not stall the closing step (trap 2).
- Arms: `conc_mark_priority` ∈ {0, 10, 19, 20}.
- Each arm runs under two co-runner loads, same session:
  - `benchmarks/l3-corunner.sh` in its memory mode;
  - a CPU-saturating load of 24 spinners (`l3-corunner` spin mode, or `stress-ng --cpu 24` if
    available; record which).
- Record: wall, worst pause, closings with work, `closing_ns_max`, `stop_wait_ns_max`,
  assists.
- **Decision rule:** the lowest priority (the highest nice value) whose closing max stays
  ≤ 50 ms and whose worst pause stays within 10 % of priority 0's under the CPU-saturating load.
  If none passes, use 0 and record it.

**E5 — oversubscription.** `taskset -c 0,1`, mode 2 at the chosen B and at B = 8, vs mode 0 on
the same mask.
- No hang.
- Wall ≤ +20 % of mode 0.
- Every run completes with a verified artifact.

**E6 — small heap.** The 4 GB-cap pressure config at mode 2 (chosen B, T = 32):
- E2E all pass;
- stress 101/101 with ≥ 20 cycles;
- record pressure finishes, assists and closings with work.

**E7 — heap-size independence (goal 2).** A synthetic benchmark `ConcMarkScaleBench`
(`test/allocator/`, disabled unless `ECO_CONC_SCALE_BENCH=1`) runs at a live old gen of 1 GB and
of 4 GB.
- **The benchmark.**
  - It builds a random old graph with explicit roots.
  - It then runs a mutator loop: 90 % short-lived young allocations, 10 % survivors replacing
    random roots, with forced triggers every 200 minors.
  - It records, per cycle: t0 prepare, t0 snapshot, in-pause mark (slices / assists /
    closing), handoff tail, and the minor-only max.
- **Pass:**
  - mode 2's in-pause mark per cycle at 4 GB is ≤ 1.5× its value at 1 GB;
  - mode 0's is ≈ 4× (the control that shows the benchmark can see the difference).
- **Record, as the remaining heap-size-dependent pause:** t0 prepare (`clearForMark`, sweep
  drain) and the handoff tail at both sizes. These are the phase-8 items, not a 5c defect.

### Part B

**E8 — trigger census (diagnostic; Part A default, Part B off).** Collect the event-log columns
of P§3.11 on the gf sweep {0.65, 0.70, 0.75}, one run each. Per cycle, tabulate: reason, P̂,
`live_ref`, `alloc_since_major`, black bytes, and the peak reached before the next handoff.
**Question answered:** which reason fires the cycles that produce the high peaks. If it is not
GarbageFraction, drop the backstop arm from E9 and record why.

**E9 — pacing arms (after E8).**

| arm | knobs |
|---|---|
| C | control (Part B off) |
| P | paced LiveBudget |
| PH | P + `major_gc_headroom_margin = 1.5` |
| PHB | PH + backstop 0.85 (only if E8 supports it) |

- Each arm runs on the gf sweep {0.65, 0.70, 0.75}.
- Arms with a backstop, whose gf is inert below it, instead sweep k ∈ {4.0, 4.5, 5.0}.
- One run per point.
- **Retention gate first:** discard an arm whose median peak exceeds C's median by > 5 %, or
  whose max RSS exceeds 15 GB at any point.
- **Then:** majors within +1 of C at every point; no pressure finish or join; median wall within
  +2 % of C.
- **Choose:** the arm with the smallest **peak spread** (max − min over its sweep, as a % of its
  median).
- **Ship P or PHB only if** its spread is at least 10 percentage points below C's. Otherwise ship
  only the headroom margin (PH's knob), provided E10 and E12 show that it removes pressure
  finishes and costs nothing on E9's gf 0.70 point.

**E10 — tight cap.** A self-compile with the old-gen cap at 11 GB (`max_heap_size` set so that
the cap is 11 GB; peak ≈ 9–10 GB): C vs the chosen arm.
- Record: pressure finishes, joins, cycles, worst pause, peak.
- **Pass:** the chosen arm has 0 pressure finishes and 0 joins.

**E11 — T under the final pacing.** T ∈ {8, 16, 32} at the chosen arm and B, a triple each. Gate
on the old-gen peak first (M§2).
- Choose the smallest T whose median peak is ≤ T = 32's, with zero assists on the triple.
- Otherwise keep 32. (5b's E3 rejected smaller T on peak; under paced triggers the peak should no
  longer depend on T, and this checks it.)

**E12 — 4 GB with the final policy.** E6 repeated with the final defaults.
- Pressure finishes ≤ E6's; E2E all pass; stress 101/101.
- Also run `testHeadroomFiresBeforePressure` at the default margin.

**What to watch:**
- **A starved background** (trap 2). `closing_ns_max` grows under load while `bg_cpu_ns`
  does not.
- **Steal contention at launch.** B thieves start on B deques, each holding 1/B of the t0
  greys. If the first seconds show high `steal_aborts`, check the distribution.
- **Interference on the minor pause.** The background shares the L3 and DRAM with the minor
  GC. Phase 0 found memory co-runners harmless, but a background marker has the same access
  pattern as the minor's own reads.
- **Collector CPU per cycle vs 5b.** Fewer markers (B < 16) should cost less CPU per unit
  (5b's imbalance and steal overhead grew with N).

---

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` | all pass at `ECO_GC_CONC_MARK` ∈ {0, 2} (and at the final default) |
| G2 | elm-tests | the reference set (13,565 passed / 12 failed at TG5b) |
| G3 | `--target full` | all pass, default configuration |
| G4 | stress under GC pressure (default and pressure-incremental configs) | 101/101 at modes 0 and 2, cycles ≥ 20 |
| G5 | validate tree (IM1–IM16, P1 tripwire, V-checks) | zero `[heap-validate]` lines on unit, E2E and stress at modes 0 and 2; negative controls fire (the plain-allocate-black rate recorded) |
| G6 | stats-off `ecoc` | builds; mode 2 works without stats |
| G7 | E0 | rule 2 (mode 0 = TG5b, every counter) |
| G8 | E1 | rule 1 (decisions and cycle units identical across modes, B and jitter) |
| G9 | TSan harnesses | the mark harness (with the episode storm) and the gang harness (with the bg-gang storm): exit 0 and no report, normal and under `taskset -c 0,1`; phase 3's harness still passes; `gc-heap-tsan` clean if built |
| G10 | E2–E12 | decision rules recorded in P§10 |
| G11 | bootstrap fixed point | the default compiler reproduces itself |
| G12 | static | no `nursery_->contains`, `isYoungLarge`, `cycle_state_` or `snapshot_mode_` read inside a `ParallelMark` instantiation (grep the template bodies for `kParallel` guards); no `hardware_concurrency`; every `region_end_ =` / `region_base_ =` goes through `setRegionBounds` |
| G13 | hang check | every self-compile, E2E and stress run finished within its timeout |

---

## 7. Traps

1. **Priority is one-way (F20).** A thread cannot get its priority back unprivileged. Never
   design a "boost the background when late" path. Background and foreground are separate
   thread sets for this reason.
2. **A starved background member blocks termination.**
   - It holds up to 16 claimed ring entries (and, for Members that did not reach an exit, its
     private stack); no one else can scan them.
   - The closing join then waits for it.
   - The mutator's blocking wait frees its own core, which usually lets the member run. Under a
     saturating co-runner at nice 0, a nice-19 or SCHED_IDLE member can still wait for tens of
     milliseconds.
   - E4 measures it and picks the priority. Do not "fix" it by letting others steal from
     private stacks: that is what made 5b v1 slow.
3. **Never let a decision read progress** (rule 4, IM16). The tempting mistakes:
   - handing off at k < T + 1 when the background finished early;
   - starting the next cycle's trigger when the background finished;
   - skipping the closing step's drain decision based on `finishedApprox` without joining.

   The schedule is fixed at t0.
4. **The cursor premise (H1b, IM13).** The hot path may use plain bit sets only because
   mid-cycle cursors own post-t0 blocks. Any future change that queues a t0 uniform block during
   a cycle (an un-deferred free, or a "reuse partially free blocks during marking" optimisation)
   also has to make `finalizeBitmapCell` atomic. IM13 is the tripwire.
5. **Publish before `goIdle`.** An Assist that decrements `active` before its work is visible
   can let a Member decide "done" with work left (the Step 3 regression variant). The order is
   ring → `publishAll` → `returnTickets` → `goIdle`.
6. **Retiring deque arrays.** 5b retired every marker's old arrays after each gang join. In 5c,
   a background thief may hold a pointer into any slot's retired array, including a foreground
   slot's after an assist. Retire only when `bg_ep_ != Running` and no foreground run is
   active: in `reapBg` after a join, and in `closingFinish`.
7. **Validators that read accumulators or mark bytes mid-episode** are data races (H2, IM6).
   Every new validator must either use relaxed atomic loads or run only when `bg_ep_ !=
   Running`.
8. **Fork and exit.** A fork with members running must go through `stopAllForFork`. Process exit
   must go through `stopAllAtExit`, before static destructors unmap the heap.
   `testConcMarkForkDuringEpisode` and `testBgGangDestructorStops` pin both.
9. **Mode 2 in the test suite.** E2E and stress fork many children, each with B background
   threads during its cycles. Watch the suite's wall time in G3/G4. If it regresses by more
   than 10 %, it is oversubscription: record it and consider a lower auto cap for short-lived
   processes. That is a follow-up; do not special-case tests.
10. **Counters are a program input** (TG3). Unset vs `ECO_GC_CONC_MARK=2` are different
    environments. Compare arms with values of equal length.
11. **The alignment trap** (5b trap 10). The atomic loads in `blockIdFor` and the new loop
    exits can move the mark loop. If mark time moves with identical instructions, check the loop
    address first.
12. **`markStackEmpty()` is exact only when nothing runs.** While an episode runs it is a hint
    (`emptyApprox`, `priv`). The two exact uses (the closing assert and the handoff assert)
    come after a join.
13. **YLOS arrays and chunks at t0** (5b-P§10.1 item 2). The t0 snapshot still never chunks a
    young array. The distribution step moves entries, not objects: a chunk entry of an old
    array is fine on any slot.
14. **Bodies and P1.** The marker reads large-string bodies of S_H. They are complete at t0
    (F25), and P1 forbids later writes. A future "string builder writes into its body" change
    would break this silently: it must be a builder (young) object, never an old body.

---

## 8. Invariants (land in Step 12)

- **HEAP_065 ConcurrentMark (new):** "WITH conc_mark = 2 THE OLD-GEN MARK WORK OF AN INCREMENTAL
  CYCLE (HEAP_063, T >= 1) RUNS ON B BACKGROUND MARKERS OUTSIDE GC PAUSES
  (plans/threaded-gc-05c-concurrent-marking.md): per-heap GCBackgroundGang threads at
  conc_mark_priority, launched at the end of the t0 pause with the t0 grey set distributed over
  their deques, marking while the mutator runs Elm code and minor GCs. They read only S_H objects
  (frozen by HEAP_SNAPSHOT_001), the t0 MarkView, page-index slots and BlockInfo published by
  release/acquire, and mark bytes (atomic); they write only mark bytes (atomic) and their own
  slot. The mutator touches a slot's owner-only state only while no thread runs on it. At minor
  ends 1..T-1 the paused mutator and the foreground gang may JOIN the running episode for an
  assist (budget from a deterministic lagged schedule; pause-only); at k = T they join until
  termination; the handoff at k = T + 1 is unchanged. The schedule, the marked set, the units
  per cycle and every GC decision are identical to conc_mark = 0 (GC_DET_001). Mode 1 (sync)
  marks everything at t0. Validators IM13 (cursor owns no t0 block), IM14 (slot quiescence),
  IM15 (no private work between runs), IM16 (progress reads never decide)."
- **HEAP_050:** "during a cycle, mutator allocate-black on a block that existed at t0 is an
  atomic fetch_or (HEAP_065); the cursor's plain bit set is legal because it owns only post-t0
  blocks (IM13)."
- **HEAP_049:** "page-index owner words are stored with release and loaded with acquire;
  ReservedArray committed counts are atomics (release/acquire), because background markers
  read them while the mutator commits (HEAP_065)."
- **HEAP_064:** "markers occupy slots 0..F-1 (foreground) and F..F+B-1 (background); every run
  exit publishes its private stack (no private work between runs); deque arrays are retired
  only when no run and no episode is active; participants are Members (idle until
  termination) or Assists (bounded, leave after publishing)."
- **HEAP_063:** "with conc_mark = 2, slices are assists (HEAP_065); kind-4 pauses occur only
  when an assist or a closing with work ran."
- **HEAP_007:** "… and GCBackgroundGang members may, outside the owner's pauses, read S_H
  objects and published metadata and set mark bytes (HEAP_065)."
- **HEAP_058:** "GCBackgroundGang episodes are launched at a pause end and joined at a later
  pause; they are not posted jobs."
- **GC_DET_001:** "background marking progress (finished, consumed units) may decide only
  pause-internal work (assists, merges, relaunches), never a trigger, the schedule, allocation
  or the tail; decision counters are identical at every conc_mark, B and jitter."
- **HEAP_057 / HEAP_066 PacedMajorTrigger (new, only if Part B ships a knob):** P̂ (the
  integer EWMA of old-gen bytes per minor, from the monotone old_alloc_total_), H_c = T + 1,
  the Headroom reason and/or the paced LiveBudget and/or the backstop, as shipped.
- **HEAP_SNAPSHOT_002:** add "this holds while background markers run: they never read a
  root, an off-heap store or a young object after t0."
- **HEAP_026:** confirm that 5a's deferred-free amendment covers concurrent marking. Frees are
  still deferred to the handoff, so there is no change beyond a reference to HEAP_065.

---

## 9. Forward notes

- **Phase 6 (parallel STW minor GC)** will run promotions on several threads while a background
  episode marks.
  - Every promotion thread's allocate-black then needs H1's atomic on the non-cursor path. The
    per-thread cursors must also own only post-t0 blocks during a cycle, which IM13 generalises
    to.
  - Phase 6's copy threads must not be the background gang's threads: separate sets, for the
    priority reason (trap 1).
- **Phase 7c (concurrent tenuring)** adds a third concurrent actor. The audit table (P§3.6) is
  the template it must extend, row by row.
- **Phase 8.**
  - The t0 prepare (`clearForMark`, O(heap/64)) and the handoff tail are the remaining
    heap-size-dependent pause components; E7 measures both.
  - Double-buffered bitmaps would move `clearForMark` into the background as the first action
    of an episode, on a second bitmap.
  - An incremental tail would move classify and reclaim into steps after the handoff.

## 10. As-built deviations

Implemented 2026-09-26/27. Every step landed. Snapshot `keep-TG5c`; the lowered default compiler
is `eco-optTG5c` (phase-timer twin `eco-optTG5cPT`, used for every experiment with arms set by
environment and `ECO_HEAP_CONFIG` JSON of equal length).

### 10.1 Design deviations and findings

1. **The share epoch (not planned; needed).** Background Members keep most of their work on
   private stacks, which joiners cannot steal. The first default-on stress run showed assists that
   marked 0 units and closings that only waited. As built, `SliceControl::share_epoch` is bumped
   by every joiner (assist, closing). Each running participant compares it at every ring refill
   (one relaxed load) and calls `publishAll` when it changed. An assist is also skipped when
   `markWorkApprox()` (atomics only) sees no work at all.
2. **Trap 5 is not load-bearing for safety.** The Step 3.3 regression variant (`goIdle` before
   `publishAll`) passes the episode storm. Each marker publishes its private-stack size in
   `priv`, and `anyWork()` reads it, so a Member cannot decide "done" while a leaving assistant
   still holds unpublished work. The publish-then-idle order is kept for liveness (the work
   becomes stealable at once). The variant was built once with a harness `-D` flag and then
   removed.
3. **A race found in review: `markStackEmpty()` reads private `std::vector`s.** It was used by
   the assist's doubling check while background members run. It is replaced there by
   `markWorkApprox()` (deque indices and `priv` only). `markStackEmpty()` is exact only after a
   join (trap 12).
4. **Closing accounting.** The first build counted the background units merged during the
   closing join as "closing units" and returned them as in-pause work, and it dropped the
   foreground members' chunk counts. Both were fixed. Closing units and the pause-kind decision now
   count foreground work only. A concurrent step is a kind-4 pause only when an assist or a
   closing join ran (`lastStepHadPauseWork`).
5. **IM6 mid-cycle runs only when no episode runs** (it reads every accumulator). IM16 is a
   validate-only decision scope (`DecisionScope` in `allocate`, `evaluateMajorGCTrigger`,
   `cyclePressureFinishDue`). `bgConsumedApprox`, `reapBackground` and `markWorkApprox` abort
   inside one.
6. **Negative controls made deterministic.**
   - IM15 uses budgeted 05b runs (mode 0, 5-ticket runs), which always end with private work;
     an assist does not always do so.
   - The IM13 hook queues a t0 block *and refills*, which is exactly what the next allocation of
     that class would do; waiting for such an allocation was luck.
   - The plain-allocate-black control fired **0 of 20** times (recorded, as P§3.9 allowed). H1
     rests on the audit plus `gc-heap-tsan`.
7. **Unit tests and the environment.** `Allocator::initialize` applies the `ECO_GC_*` overrides
   only on the first initialisation, and later `initAllocator` calls go through `reset`. So a
   whole-suite run with `ECO_GC_CONC_MARK=2` only exercised mode 2 in unit tests once it became
   the compiled default.
   - The 05b tests that drive `runMarkers` directly now pin `conc_mark = 0` (`parConfig`).
   - `ECO_TEST_CONC_MARK` overrides both 05a and 05b test configs; the 05a tests run in mode 2 by
     default and pass on the in-pause path with `ECO_TEST_CONC_MARK=0`.
8. **`gc-heap-tsan` is feasible and clean** (Step 0 verdict). Only `StackUnwind` needed a stub
   (no frames: every value is a RootSet root). Under TSan the low heap reservation (< 8 TB) fell in
   TSan's shadow range, so `reserveAddressSpaceBelow` first probes [64 GB, 512 GB) when built with
   `__SANITIZE_THREAD__`.
9. **The audit (P§3.6) held with one addition:** H1–H15 as designed, plus the
   `markStackEmpty` race of item 3. No other site was found by the greps, by `gc-heap-tsan` or by
   the validate tree.
10. **The E1 jitter arm allocated 1 object more.** It differs at minor GC #1 (16 survivor bytes),
    before any mark cycle or background thread exists: the environment value is a program input
    (TG3). Every GC decision and every cycle's units are identical.

### 10.2 E0 — mode 0 vs `eco-optTG5bPT3` (same session)

Identical in every counter: allocated 254,179,031, minors 1,924, majors 7, promoted 675,771,383,
copied 744,250,299, old-gen peak 8,937.7 MB, slice units 269,868,331, closing units 2,797,622, and
the major table's non-timing columns (hash `99dee12e3f`). `out.mlir` md5 933c3ff0d288 everywhere.

### 10.3 E1 — determinism

Modes 0 / 1 / 2 at B = 1, 2, 4, 8, and B = 4 + `ECO_GC_HELPER_JITTER_US=50` (twice): minors,
majors, promoted, copied, old-gen peak and every cycle's units (major table hash `99dee12e3f`)
are identical. The jitter arm's +1 allocated object is item 10 above.

### 10.4 E2 — B and the assist lag (T = 32)

| B | assists (units, max ms) | closings with work | background done by k ≤ T/4 / T/2 / 3T/4 / T | background CPU (s) |
|---|---|---|---|---|
| 1 | 29 (63.8 M, 65.6) | 0 | 3 / 3 / 0 / 1 | 8.3 |
| 2 | 5–8 (20–21 M; one pause 271 ms) | 0 | 5 / 1 / 1 / 0 | 11.0–11.2 |
| **4 (triple)** | **0** | **0** | **6 / 1 / 0 / 0** | **12.4–12.7** |
| 8 | 0 | 0 | 7 / 0 / 0 / 0 | 13.7 |

**B cap = 4**, the smallest B with zero assists and closings across a triple. Assist lag L = 2,
4 and 8 all gave zero assists, so the rule picks **L = 8**.

### 10.5 E3 — interference (triples, medians, same session)

| | mode 0 (05b) | mode 2, B = 4 |
|---|---|---|
| wall | 163.6 s | **162.6 s** |
| worst pause | 191.0 ms | 190.0 ms (the minor floor) |
| all-pause p99 | 127.5 ms | **116.3 ms** |
| minor-only p99 | 115.4 ms | 115.1 ms |
| kind-4 pauses (slice p99) | 224 (~138 ms) | **0** |
| MMU 1 s | 22.0 % | 23.3 % |
| mutator CPU outside pauses | 112.56 s | 112.67 s (interference +0.1 %) |
| mutator CPU in pauses | 50.4 s | 49.2 s |
| collector CPU | 19.7 s (gang) | **12.6 s** (background) |
| t0 max / handoff max | 136–140 / 157–164 ms | 137–139 / 160–163 ms |

Every E3 pass criterion holds.

### 10.6 E4 — priority under co-runners (mode 2, B = 4)

24 `l3-corunner --spin 1` processes saturating every core:

| priority | wall | worst pause | assists | closing max | background CPU |
|---|---|---|---|---|---|
| **0 (inherit)** | 154.4 s | **223.7 ms** | 0 | — | 11.2 s |
| nice 10 | 154.6 s | 227.2 ms | 51 | 133 ms | 6.6 s |
| nice 19 | 158.7 s | 1,048 ms | 130 | 1,041 ms | 1.6 s |
| SCHED_IDLE | 183.5 s | **9,509 ms** | 154 | 9,503 ms | 0.9 s |
| mode 0 (05b) | 160.1 s | 261.7 ms | — | — | — |

With a memory co-runner (`--duty 1.0`), priority 0 and 10 were both clean (worst 181/179 ms).
**Trap 2 is real:** a starved low-priority member holds claimed work that the closing join must
wait for. Only priority 0 satisfies the rule (closing ≤ 50 ms, worst within 10 % of
priority 0), so **the default is 0**. Under saturation, mode 2 at priority 0 beats mode 0 (223.7
vs 261.7 ms worst, 117 vs 149 ms p99).

### 10.7 E5 — oversubscription (`taskset -c 0,1`)

| arm | wall | worst pause | all p99 | assists |
|---|---|---|---|---|
| mode 0 | 169.2 s | 227.9 ms | 161.5 ms | — |
| mode 2, auto (B = 1) | 165.2 s | 352.1 ms | 117.6 ms | 15 |
| mode 2, B = 8 | 164.7 s | 396.7 ms | 121.4 ms | 17 |

No hang, identical decisions, and wall at or below mode 0 (pass). The worst pause is an assist
that competes for the 2 CPUs with the background members: recorded, not a gate.

### 10.8 E6 / E12 — 4 GB cap (the pressure config at `max_heap_size` 4G, final defaults)

Suite 1,884 / 1,884. Stress 101 / 101: 21 cycles, finishes schedule 21 / pressure 0 / join 0.

### 10.9 E7 — heap-size independence (`ConcMarkScaleBench`, 3 forced cycles per arm)

| live old gen | minor every | mode 0 in-pause mark / cycle | mode 2 in-pause mark / cycle | t0 max (prepare) | handoff max (mode 0 / 2) |
|---|---|---|---|---|---|
| 1 GB | 20 ms | 699 ms | **0** | 8 (2.7) ms | 3.5 / 5.2 ms |
| 4 GB | 20 ms | 1,746 ms | 702 ms (52 assists, 1 closing) | 15 (11–16) ms | 13 / 53 ms |
| 1 GB | 150 ms | 558 ms | **0** | 8 (2.7) ms | 3.4 / 5.2 ms |
| 4 GB | 150 ms | 2,625 ms | **0** | 15 (10–15) ms | 13 / 55 ms |

- **Independence holds while B markers × the cycle's mutator time covers the mark work.** At a
  20 ms minor period, 4 markers cannot mark 307 M units in 33 minors, and assists take over
  (still 2.5× less in-pause work than mode 0). At the self-compile's ~86 ms period, and in the
  150 ms arm, the in-pause mark is zero at every size.
- **What still grows with the heap:** the t0 prepare (`clearForMark`, the sweep drain) and the
  handoff tail. These are the phase-8 items. The larger mode-2 handoff here is cold caches after
  mutator sleep; on the self-compile the handoff is equal in both modes (E3).

### 10.10 E8 / E9 — trigger census and pacing arms (mode 2, gf sweep)

Old-gen peak in MB (majors in parentheses):

| arm | gf 0.65 | gf 0.70 | gf 0.75 | spread | median |
|---|---|---|---|---|---|
| C control | 13,248 (7) | 8,938 (7) | 9,676 (6) | 44.5 % | 9,676 |
| P paced LiveBudget | 8,696 (9) | 9,251 (8) | 9,290 (7) | **6.4 %** | 9,251 |
| PH P + headroom 1.5 | = P (headroom never fires at the 20 GB cap) | | | 6.4 % | 9,251 |
| PHB PH + backstop 0.85, k = 4.0 / 4.5 / 5.0 | 13,304 (6) | 10,778 (6) | 9,775 (6) | 36 %, non-monotone | 10,778 |

- **E8:** at gf 0.65, 6 of 7 cycles are garbage-fraction triggered (the 13.2 GB peak); at gf
  0.75, 5 of 6 are LiveBudget. P̂ is bursty (up to 54 MB per minor).
- **Decision (the plan's rule):**
  - P has the smallest spread and a lower median peak, with wall flat, but +2 majors at gf 0.65
    breaks "majors within +1 of C at every point". **P is not a default.** It is kept as a knob
    and is the obvious follow-up decision.
  - PHB is rejected: suppressing the garbage fraction moves the chaos into LiveBudget.
  - The headroom margin ships (E10).

### 10.11 E10 — tight cap (`max_heap_size` 15G, i.e. an 11 GB old-gen cap)

| gf | control peak (% of cap) | headroom 1.5 peak (% of cap) | majors | pressure / join |
|---|---|---|---|---|
| 0.65 | 10,630 MB (94.4 %, one GlobalPressure cycle) | **9,176 MB (81.5 %, one Headroom cycle)** | 8 / 8 | 0 / 0 |
| 0.70 | 8,938 MB (79.3 %) | 8,938 MB (identical: Headroom never fired) | 7 / 7 | 0 / 0 |

Headroom costs nothing where it does not fire, and it keeps the late cycle 13 points of cap away
from the finish line where it does. **`MAJOR_GC_HEADROOM_MARGIN = 1.5` default-on.**

### 10.12 E11 — T under the final pacing (triples)

| T | old-gen peak | max RSS | worst pause | assists |
|---|---|---|---|---|
| 8 | 10,042 MB | 11.0 GB | 162–176 ms | 0 |
| 16 | 10,023 MB | 11.0 GB | 162–166 ms | 0 |
| **32** | **8,938 MB** | **9.85 GB** | 186–190 ms | 0 |

No smaller T has a peak at or below T = 32's (+12 %, as in 05b E3: with the paced LiveBudget
off, the peak still depends on where the trigger lands). **T stays 32.**

### 10.13 Gates

| gate | result |
|---|---|
| G1 | `build/test/test` 1,884 / 1,884 default-on (mode 2 in every unit test that uses defaults); 1,883 / 1,883 before the flip at `ECO_GC_CONC_MARK` 0, 1, 2 and 2 + jitter; 05a tests 25 / 25 at `ECO_TEST_CONC_MARK=0` |
| G2 | elm-tests 13,565 passed / 12 failed: the reference set, unchanged |
| G3 | `full` 1,884 / 1,884 (default-on) |
| G4 | stress 101 / 101 on the pressure config (21 cycles × 32 slices, 21 episodes) and the pressure-incremental config (22 cycles), modes 0 and 2, and at 4 GB |
| G5 | validate tree: unit + E2E 1,885 / 1,885 default-on, zero `[heap-validate]` lines; validate stress 101 / 101 on both configs at modes 0 and 2, zero lines; the IM13, IM15, skip-merge and plain-bit controls fire; plain allocate-black fired 0 / 20 (recorded) |
| G6 | stats-off `ecoc` builds, and a stats-off lowering of the compiler (`eco-optTG5cNS`, mode 2 by default) builds itself to md5 933c3ff0d288 in 155.5 s. The stats-off *test* target does not compile (pre-existing: other test files call `getCombinedStats`) |
| G7 / G8 | E0 / E1 (P§10.2, P§10.3) |
| G9 | `gc-mark-tsan` (with the episode and bg-gang storms): clean normally and twice under `taskset -c 0,1`; `gc-helper-tsan` passes; `gc-heap-tsan` clean at jitter 0 and 50 (3 scenarios: B 2/4/3, T 4/16/8, with assists and early finishes) |
| G10 | E2–E12 as recorded |
| G11 | fixed point: `eco-optTG5c` (default-on, no GC environment) builds itself to `out.mlir` md5 933c3ff0d288, byte-identical to the MLIR it was lowered from (7 background episodes, 0 assists, peak 8,937.7 MB) |
| G12 | no `nursery_->contains`, `isYoungLarge`, `cycle_state_` or `snapshot_mode_` read in a `ParallelMark` branch (checked by hand); `hardware_concurrency` only in a comment; every region-bound write goes through `setRegionBase`/`setRegionEnd` |
| G13 | every self-compile, suite and stress run finished within its timeout |


## 11. Done means

- `conc_mark` 0/1/2 exist. Mode 0 reproduces `eco-optTG5b` bit for bit (E0). Every mode, B and
  jitter reproduces its decision counters and per-cycle units (E1).
- The TSan harnesses are clean, including the episode storm, the bg-gang storm and the
  oversubscribed runs. `gc-heap-tsan` is clean or its infeasibility is recorded.
- IM13–IM16 and IM1–IM12 are green on unit, E2E and stress at modes 0 and 2. The negative
  controls fire.
- E2–E7 are recorded, and mode 2 is default-on with a chosen B, priority and lag, or closed
  with the reason recorded.
- E7 shows the in-pause mark no longer scales with the old gen (and records what still does).
- E8–E12 are recorded: the pacing arm shipped (or only the headroom margin, or nothing, with
  the reason), and T re-chosen.
- HEAP_065 (and HEAP_066 if applicable) and the amendments are in `invariants.csv`. THEORY.md,
  the master-plan row, §5 table and deviation note, the loop entry `TG5c` and `keep-TG5c` are
  done.
