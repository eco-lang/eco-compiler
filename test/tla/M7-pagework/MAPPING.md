# M7 — PageWork and the lock order: model ↔ code

Two modules:
- `PageWork.tla` (M7a): deferred decommit and commit-ahead, one caller under `thread_mutex_`, pool
  workers running job bodies;
- `LockOrder.tla` (M7b): the lock chain `promo_mu_` → `thread_mutex_` → pool wait, and the
  teardown's join of the 7c collector under `thread_mutex_`.

Both are PlusCal with their committed translation. Every constant is a `.cfg` literal, so there
is no `MC.tla`. The plan is `plans/threaded-gc-tla-M7-pagework.md`. **This file cites code, never
plan text** (parent plan §12, trap 1).

Line numbers are for the tree of 2026-09-28 (post-7c); `PageWork.cpp`'s are after its trace hooks (2026-09-29). Functions are named too, because lines
drift. `PW` = `runtime/src/allocator/PageWork.cpp`, `AL` = `Allocator.cpp`, `OGS` =
`OldGenSpace.cpp`, `HP` = `GCHelperPool.cpp`, `NT` = `NurseryTenure.cpp`.

## 1. Variables

### M7a (`PageWork.tla`)

| Variable | Meaning | Code counterpart |
|---|---|---|
| `owner[x]` | `heap` (owned by a heap), `free` (released), `fresh` (above the bump) | the heap's blocks and bag pages (`blocks_`, `unassigned_blocks_`); `old_gen_free_blocks_`; `[heap_base + old_gen_committed, nursery_offset)` |
| `freeList` | the released extents, in list order | `Allocator::old_gen_free_blocks_` (`AL:929` append, `AL:784-786` swap-remove) |
| `gFree` | ghost: the same list, kept by the same operations without reading PageWork state | — (GC_DET_001's job-blind allocator) |
| `pw[x]` | `none` / `Pending` / `Posted` | `PageWork::pending_` / `posted_discard_` membership |
| `postedIn[x]` | the slot of a Posted extent (0 otherwise) | `Posted::slot` (`PageWork.hpp:146`) |
| `sstate[s]` | `Idle` / `Posted` / `Running` / `Done` | `HelperJob::state` of `slots_[s]` (`GCHelperPool.hpp:49`) |
| `skind[s]`, `sext[s]` | job kind; its extents (Discard) or the window's extents (Populate) | `PageJob::kind`, `extents`, `lo`/`hi` (`PageWork.hpp:135-143`) |
| `takenSlot` | `takeSlot`'s result, reset when dead | the `PageJob&` returned by `takeSlot` |
| `stale` | ghost, only written under `MUTANT = "age_stale_entry"`: extents whose `pending_order_` entry went stale at a cancel | a stale `pending_order_` entry (`PW:186`, skipped at `PW:280-283`) |
| caller locals `n`, `ext`, `rs`, `rsel`, `batch`, `win` | operation count; the extent being released or reused; the overlapping populates still to wait for; the one being waited for; the aged batch; the window | locals of `onRelease`, `acquireOldGenBlock`, `syncPoint` |
| procedure locals `as`, `ts` | `awaitSlot`'s slot; `takeSlot`'s chosen busy slot | `awaitSlot(s)`, `oldest` in `takeSlot` |
| worker locals `cur`, `todo` | the job being run; the extents it has still to `madvise` | `runJob`'s `s` and its loop over `s->extents` (`PW:65-81`) |

### M7b (`LockOrder.tla`)

| Variable | Meaning | Code counterpart |
|---|---|---|
| `promo` | holder of `promo_mu_` | `OldGenSpace::promo_mu_` (`minorwork::SpinMutex`, `OldGenSpace.hpp:765`) |
| `tmOwner`, `tmDepth` | owner and recursion depth of `thread_mutex_` | `Allocator::thread_mutex_` (`std::recursive_mutex`, `Allocator.hpp:407`) |
| `job` | the posted job the chain meets: `Posted` / `Running` / `Done` | the `HelperJob::state` of a Discard (onReuse) or Populate (onRelease) slot |
| `reused` | the job's extent has been handed out (once) | first-fit picking that extent |
| `waiting` | threads blocked in `cv_done_.wait` | `GCHelperPool::wait` (`HP:243-246`) |
| `pc["coll"]` | the 7c collector has exited | the background gang's `running()` falling, joined by `stopAndJoin` |

The pool's `m_` is not a variable: it is a leaf lock, never held across a wait (`cv_done_.wait`
releases it), so it cannot close a cycle.

## 2. Steps (A1: one label = one atomic step of the code)

Every PageWork call runs with `thread_mutex_` held by its caller (`AL:753`, `AL:892`, `AL:1253`),
and workers read only their own job's fields. So each call is one step, split only where it
**waits**: a wait is the one place a worker step can come between two caller steps.

### M7a

| Label | Code | Step |
|---|---|---|
| `M_Choose` (release) | `AL:891-901` `releaseOldGenBlock` up to `onRelease`; `PW:151-157` `awaitPopulateOverlapping`'s slot test | pick an owned extent; compute the in-flight populates that overlap it |
| `M_RelWait` | `PW:155` → `awaitSlot` | wait for one overlapping populate, reap it; loop |
| `M_RelPend` | `PW:162-173` (Pending, `pending_order_`), `AL:929` (free-list append) | Pending; appended to the free list and the ghost |
| `M_Choose` (reuse) | `AL:775-786` first-fit and swap-remove | the first extent; the ghost does the same |
| `M_Reuse` | `PW:177-201` `onReuse` (`AL:792`) | cancel a Pending extent, or wait for a Posted one's job |
| `M_Touch` | `AL:793-827` (V1 `AL:794-799`, V4 `AL:808`, `MADV_WILLNEED` `AL:820`) | V1 holds here; the heap owns the extent |
| `M_Choose` (fresh) | `AL:837-885` bump path, `PW:203-220` `onFreshBump` | a fresh extent becomes the heap's; never waits |
| `M_Choose` (sync) | `AL:1253-1258` `onGCPauseEnd`; `PW:273` `reapDone`, `PW:277-298` aging | reap some subset of the Done slots (`ReapChoices`, below), then choose the aged batch (`AgeChoices`: any subset of Pending) |
| `M_Take`, `M_Post` | `PW:301` → `PW:222-242` `postDiscardBatch` (→ `takeSlot`) | take a slot; post the Discard job |
| `M_Window`, `M_TakeP`, `M_PostP` | `PW:303` → `PW:244-268` `topUpWindow` | choose the window (any subset of the fresh extents); take a slot; post the Populate job |
| `AS_Wait` | `PW:126-135` `awaitSlot`: `isIdle`, `pool.wait` (`HP:236-252`), `reap` (`PW:94-113`) | return when Idle or Done; reap if Done |
| `TS_ReapDone`, `TS_Oldest`, `TS_Wait`, `TS_Got` | `PW:137-149` `takeSlot` | reapDone (a subset of the Done slots), the lowest Idle slot; else wait for a busy one |
| `W_Take` | `HP:203-215` `workerLoop`'s dequeue under `m_` | take any Posted job, `Running` |
| `W_Body` | `HP:216` → `PW:65-81` `runJob` (one `ops.discard` per extent, `PW:71-74`, in batch order); then `HP:217-221` Done under `m_` | one discard `madvise` per step, any remaining extent; when none is left (a populate has none), the `Done` store (release) |

The plan's `M_Next`, `M_SyncDone`, `W_Loop` and `W_Done` labels are gone: each was a step with no
code counterpart (`n := n + 1` moved into `M_Choose`; `batch` and `win` are cleared in `M_Window`
and `M_PostP`; the worker's loop is `goto W_Take`, and its Done store is `W_Body`'s last step).

### M7b

| Label | Code | Step |
|---|---|---|
| `P_Promo` | `OGS:1587-1596` `allocatePromotion`'s `promo_mu_` (`SpinMutex::lock`, `MinorWork.hpp:91-107`); also the first section `OGS:1547` | acquire `promo_mu_` (spinning is an `await`) |
| `P_Tm` | `AL:753` `acquireOldGenBlock` (via `ladderFrom2W` `OGS:1306` → `startVirginBlockShared` `OGS:1249` → `ensureBagPageAvailable` `OGS:866-871`, or `allocateFromBagPage` `OGS:2430`, or `allocateLargeBlock` `OGS:2743`); or `AL:892` `releaseOldGenBlock` (CR-014's route, §4) | acquire `thread_mutex_` (recursive) |
| `P_Pick`, `P_Reuse` | `AL:775-792` first-fit → `onReuse` → `awaitSlot` (`PW:191`); or `onRelease` → `awaitPopulateOverlapping` (`PW:155`) | meet the posted job once; wait if it is not Done |
| `PW_Lock`, `PW_Blocked` | `HP:236-252` `GCHelperPool::wait`: the acquire fast path (`:238`), then `cv_done_.wait` under `m_` (`:243-246`) | check under `m_`, else block; re-check on wake |
| `P_Release`, `P_Unpromo` | the `lock_guard` and `unique_lock` destructors | release `thread_mutex_`, then `promo_mu_` |
| `T_Tm`, `T_Join`, `T_Rel` | `AL:359` / `AL:384` (`cleanupThread`, `finishTenureForExit`) → `NT:900-904` `tenureTeardown` → `collector->stopAndJoin()` | the mutator holds `thread_mutex_` and joins the 7c collector |
| `W_Take`, `W_Body`, `W_Done`, `W_Notify` | `HP:203-222` `workerLoop` | dequeue; the body (no allocator lock); Done under `m_`; `notify_all` after unlocking |
| `C_Work` | the collector's job (`NT:985` `grantAllocateShared`: grant-only allocation) | no allocator lock |

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| extents of varied sizes; first-fit by size | one size; first fit = index 1; the exact swap-remove | page requests are all `alloc_buffer_size`. The size test, the page-request skips (`AL:778-779`) and a larger extent handed to a smaller request read no PageWork state; `onReuse` keys on the extent's base and covers it whole |
| `pending_` / `posted_discard_` keyed by the extent's **start address** | an extent **id**; a re-release of the same extent is the same id (ABA at the same key: `pw_aba`, and the mutants `reuse_keeps_pending`, `reuse_no_wait`, `age_stale_entry`) | sound because the free list never splits or coalesces: an acquire takes a whole entry (`AL:780-793`), a release appends one (`AL:938`), and entries come from releases of disjoint owned blocks, so a start names one extent for its whole free-list life. An extent reacquired with a **different** start overlapping a tracked one is therefore not a code behaviour, and the model cannot express it; a change to first-fit or to the append (canary pins `AL.acquireOldGenBlock`, `AL.releaseOldGenBlock`) would need the extents to become ranges. The ABA audit (AUDIT.md, 2026-09-29) found the one oddity of the no-split rule: a larger extent's tail is lost to the free list (not a PageWork hazard) |
| `pending_order_`'s `seq` stamp; `reap`'s `Posted::slot` check (`PW:100`) | `pw[x] = "Pending"` itself (non-mutant aging picks among live records); `postedIn[x] = s` in `Reap` / `ReapSomeDone` | the `seq` stamp is the identity guard that makes a stale order entry (cancelled, then re-released at the same start) invisible: modelled exactly, and `age_stale_entry` removes it. The slot check is redundant: with it removed (probe `reap_any_slot`, AUDIT.md 2026-09-29) the reachable state spaces of `pw_aba` and `pw_basic` are identical, because a reuse always reaps the old job before the extent can be posted again |
| 8 job slots; "wait for the oldest" by `seq` | 2 slots (deep: 3; trace: 8); wait for any busy slot | a superset of the code's choice |
| `reapDone`'s loop of per-slot acquire loads (`PW:115-124`) | one step reaping any subset of the slots Done at that instant (`ReapChoices`) | not atomic: a slot that turns Done after the loop passed it stays unreaped. Every outcome is a subset of the slots Done at the loop's end, so one step there covers it (primer §3.3). Found while mapping the trace (AUDIT.md, 2026-09-29) |
| a discard's extents, `madvise`d in batch (release) order | one step per extent, in any order | the batch order is not modelled (the batch is a set) |
| 1..64 FIFO pool workers | 1 or 2 workers that take **any** Posted job | M6's PoolJob contract promises no order, so this over-approximates FIFO. Where a mutant's counterexample needs a non-FIFO order, AUDIT.md says so and gives the FIFO-feasible one |
| `thread_mutex_` around every PageWork call, from the mutator or a gang thread | implicit: one caller process makes every call | the mutex is held across the whole call, **waits included** (`lock_guard` at function entry), so the calls form one sequence whatever thread makes them. That also holds across heaps: the model's one caller stands for every heap's calls, and `owner = "heap"` means "owned by some heap". So HEAP_059, HEAP_060, V1, V2 and `PostIdle` hold for any number of heaps. `DetChoice` does not transfer: GC_DET_001 is per heap (CR-012) |
| aging: `delay_majors` (default 1), `delay_syncs` (default never), `pending_cap` (default 0), a prefix of `pending_order_` | at a sync point, any subset of the Pending extents | the rule reads only mutator state; no M7 invariant depends on when a discard is posted; the free choice covers every setting, including the H2/H3 harness's syncs-plus-cap |
| the batch's `pending_` entries are erased before `takeSlot` waits (`PW:295-296` then `PW:224`) | the batch stays `Pending` until `M_Post` | the caller holds `thread_mutex_` throughout, and workers never read `pending_`, so nothing can observe the difference; the model is the more tracked of the two, and `TrackedInFree` holds either way |
| the window `[max(window_end_, bump), roundUp(bump + ahead, 2 MiB))` | at a sync point, any subset of the fresh extents (possibly empty) | only the release wait depends on it; any subset over-approximates the real range, including an extent in two windows (a large block across a boundary). The code never repeats a window (`PW:248-249`); a mutant whose counterexample needs a repeat is given a configuration without windows (AUDIT.md, trap 11) |
| the populate's one `madvise` over `[lo, hi)` | folded into its Done step (`todo = {}`) | content-neutral; only `sstate` (Posted / Running, i.e. in flight) matters to `HEAP_060` |
| page contents | not modelled | the only way a discard zeroes heap data is a discard under an owner, which `HEAP_059` checks on `owner` |
| the pool | PoolJob (M6): `Posted → Running → Done`, run once, weakly fair workers | checked in M6 |
| `pool.wait`'s fast path + locked check (M7b) | one step `PW_Lock` | both read `job`; the only writer (`W_Done`) holds `m_`, so merging them changes no outcome under SC. The fast path's acquire is A4 (W `w_pool_done`) |
| the SpinMutex's spin / yield / sleep | `await promo = "none"` | the backoff changes only timing |
| CR-014's release route | the same `P_Tm` → `P_Reuse` chain on a generic job | the route waits on a populate instead of a discard: the same lock pattern (plan §10 Q2) |

Outside the model (a subset of the modelled behaviours, or another model's):
- `decommit_on_oldgen_release = false`, mode 1 (`post` runs the job inline, `HP:162-167`), a
  failed window commit, populate unsupported;
- `reset()`, `~Allocator`, `drainHelperWork` (`drainAll`, V5), the double-release abort
  (`PW:165-167`);
- which blocks the old gen releases and when, and the ReleaseContract (M4; V2b at runtime);
- partial overlaps of a bump request with the window's end (`onFreshBump` only splits the commit
  and never waits);
- several heaps for determinism, `validatePageWork`'s reads of other heaps, and
  `acquireOldGenRegion` re-mapping a window (CR-012).

## 4. Every route into M7b's chain (census of `promo_mu_`, `thread_mutex_`, the pool's `m_`)

Checked against the tree on 2026-09-28.

| Route | Under `promo_mu_` | Reaches |
|---|---|---|
| `ladderFrom2W` (`OGS:1306`) → `startVirginBlockShared` (`OGS:1249`) → `ensureBagPageAvailable` (`OGS:866-871`) | `OGS:1587` | `acquireOldGenBlock` → `onReuse` |
| `ladderFrom2W` → `startVirginBlockW` (`OGS:1279-1281`), non-chunked, so one worker only | `OGS:1587` | the same; no other member exists to stall |
| `ladderFrom2W` / `allocatePromotion` (`OGS:1345`, `1628`) → `allocateFromBagPage` (`OGS:2430`) | `OGS:1587` | the same |
| `allocatePromotion`'s block-sized branch → `allocateLargeBlock` (`OGS:2743`) | `OGS:1547` (test geometries) | the same |
| `sweepOnDemandAllocate` (`OGS:2147`), `panicSweepAndRetryAllocation` (`OGS:2169`), `allocateFromBagPage` (`OGS:2410`) → `lazySweep` tail (`OGS:5467-5476`) → `onSweepComplete` → `maybeShrinkCapacity` (`OGS:5502`) → `releaseBlockToAllocator` (`OGS:6101`) / `releaseUnassignedBlockToAllocator` (`OGS:6153`) | `OGS:1587` | `releaseOldGenBlock` → `onRelease` → a populate wait (CR-014) |
| callers: the parallel minor's gang; 7c's pause tenure engine `runJobParallel` (`NT:1168`, `allocatePromotion` at `NT:984`) | | |
| `allocatePromotion`'s `per_alloc_sweep` slice (`OGS:1559-1563`) | **no** (one-worker identity) | `lazySweep` outside `promo_mu_`: not in the chain |

Under `thread_mutex_` a thread may also block on a **background-gang join**: `tenureTeardown` →
`collector->stopAndJoin()` (`NT:904`) from `cleanupThread` (`AL:359-366`), `finishTenureForExit`
(`AL:384-385`) and `reset` → `~ThreadLocalHeap`. The collector allocates only from its grant
(`NT:985`); nothing in `OldGenTenure.cpp`, `NurseryTenure.cpp` or `TenureWork.hpp` calls
`acquireOldGenBlock`, `releaseOldGenBlock` or takes `thread_mutex_`. `tenureTeardown` runs the
remaining work with one thread (`tenureConcFinish(..., on_this_thread = true)`, `NT:1249`), so no
gang of more than one member runs under `thread_mutex_`.

The lock graph is `promo_mu_` → `thread_mutex_` → {pool `m_` (a leaf), a background-gang join}.
It is acyclic; `lock_order` checks it and three mutants show what would close a cycle.

## 5. Footprint rows (A3)

| Row | Model |
|---|---|
| plan 03 P§3.6: `pending_`, `pending_order_`, `posted_discard_`, the slot ring | `pw`, `postedIn`, `stale` (mutant only), `sstate`/`skind`/`sext` |
| plan 03 P§3.7: the commit-ahead window (`window_end_` in the code) | the free window choice |
| `old_gen_free_blocks_` | `freeList` (and `gFree`) |
| `old_gen_committed` (the bump) | `owner = "fresh"` |
| `HelperJob::state` (acquire loads in `isIdle`/`isDone`, the post CAS, the worker's stores under `m_`) | `sstate` (M7a), `job` (M7b) |
| `PageJob` fields a worker reads (`kind`, `extents`, `lo`, `hi`, `ops`), written before `post` | `skind`, `sext`; `PostIdle` checks they are written only into an Idle slot |
| `PageJob::failures`, timestamps, `bytes` (written by the runner, read after Done) | not modelled: stats, published by the Done release/acquire (A4) |
| 07 plan P§3.17 T10: helper jobs never target a granted block | released extents only: `HEAP_059` (a discard's extents are free) |
| HEAP_058: workers take no allocator lock | M7b's deadlock check (mutant `worker_takes_tm`) |
| `promo_mu_`, `thread_mutex_`, pool `m_`, the collector join | M7b's `promo`, `tmOwner`/`tmDepth`, (leaf, argued), `T_Join` |
| `sync_epoch_`, `major_epoch_` (`Allocator.hpp:381-382`) | not modelled: aging is a free choice |
| `old_gen_in_use_bytes_` | not modelled: stats and triggers; its unlocked readers are CR-012 |

## 6. Invariants and properties (A7)

| Name | Module | Id | Where the code checks it |
|---|---|---|---|
| `HEAP_059` | M7a | HEAP_059 | H2's fake discard ("the extent is free before and after a yield"); H3's page patterns |
| `HEAP_060` | M7a | HEAP_060 (its purpose: no discard runs over a populate in flight) | H2's fake populate ("populate over a released extent") checks the stronger release-side form |
| `V1` | M7a | V1 | `AL:794-799` (validate builds) |
| `TrackedInFree` | M7a | V2a | `validatePageWork` `AL:1292-1301` |
| `NoOwnedPosted` | M7a | V2b | `validatePageWork` `AL:1302-1306` |
| `DetChoice` | M7a | GC_DET_001 (the extent choice) | `testDecommitModesAgreeOnCounters`, gate G8 |
| `PostIdle` | M7a | the post CAS (`HP:153-156`, `poolAbort("post: job is not Idle")`) | every build |
| `MutatorFinishes` | M7a | liveness: every wait returns | — |
| deadlock (TLC) | M7b | HEAP_058 ("the mutator may wait for a worker while holding it") | — |
| `AllFinish` | M7b | liveness: every thread finishes | — |
| `MODEL_M7_StallWitness` | M7b | witness: CR-007's stall is reachable | — |

V3 (populate bounds, addresses), V4 (poison on resident reuse), V5 (drained at reset) and V6
(mode 0 inert) are runtime-only and outside the model.

## 7. Contracts assumed (parent plan §5.0)

- **PoolJob** (M6: `PoolRunOnce`, `WaitSeesDone`, `ParentJobsFinish`): a posted job runs exactly
  once, in any order; `wait` returns only when it is Done. M7a's workers are this contract; the
  mutant `job_never_done` shows `MutatorFinishes` depends on it.
- **ReleaseContract** (M4: `ReleasedSafe`): the old gen releases an extent only when no heap
  structure still refers to it. M7a's release takes an owned extent and makes it `free` in one
  step, so a release of an extent still in use is outside what M7 can see (CR-014, CR-016 are M4's).

## 8. Weak memory (A4)

The models are sequentially consistent. They rely on:

| Where | Order | Companion | Status |
|---|---|---|---|
| `workerLoop` stores `Done` with release inside `m_` (`HP:219`); `wait`'s fast path (`HP:238`), `isIdle` / `isDone` (`GCHelperPool.hpp:56-57`) and `resetForReuse` (`HP:59`) load it with acquire **outside** `m_`. The job's outputs (the `madvise` itself, `failures`, timestamps) reach `reap` through this pair alone | release / acquire on `HelperJob::state` | W `w_pool_done` | PASS (GenMC RC11, 2026-09-28); `POOL_RELAXED_DONE`, `POOL_RELAXED_DONE_REAP`, `POOL_RELAXED_FASTPATH` and the header mutant `POOL_RELAXED_ISDONE` are flagged (a race on the job's payload) |
| `post`'s CAS `Idle → Posted` (acq_rel, `HP:154`) publishing the fields the caller wrote before it to the worker, which dequeues under `m_` | acq_rel + `m_` | W `w_pool_done` (the post half) | PASS. The publication to the worker is `m_` (it dequeues under the mutex): `w_pool_done_relaxed_cas` passes with the CAS relaxed, so the CAS's order is not needed for it |
| `SpinMutex`: `exchange(acquire)` / `store(release)` (`MinorWork.hpp:87-110`) | acquire / release | none needed: a textbook test-and-test-and-set lock | — |

## 9. Accuracy rules (A1–A9)

| Rule | M7 |
|---|---|
| A1 | §2: one step per PageWork call, split only at its waits; one `madvise` per worker step; the dequeue and the Done store one step each (both under `m_`). The reuse is split between the choice and `onReuse` so V2a's exception is stated honestly |
| A2 | extents are the unit of both `madvise` and the free list; no sub-extent sharing |
| A3 | §5 |
| A4 | §8: the Done release/acquire outside `m_` and the post CAS → W `w_pool_done`: PASS (2026-09-28). `promo_mu_` as a lock: W3f PASS |
| A5 | `TracePageWork.tla` on `gc-helper-trace` (H2 and H3 scripts), 8 accepted rows and 7 negative controls in `traces.txt` (§10) |
| A6 | AUDIT.md: every invariant and property has a mutant; the witness is its own row |
| A7 | §6 |
| A8 | 3–4 extents, 1–3 slots, 1–2 workers, 4–7 caller operations (`pw_aba`: 10, with no window, for reuse cycles at one key); 2–3 gang members. No counter wraps: the epochs are gone (aging is a free choice) and `seq` is only an order |
| A9 | not built yet (the canary is Step 1's). AUDIT.md lists the lines this model needs |

## 10. Trace validation (A5): `TracePageWork.tla`

**Harness.** `test/gc-helper-tsan/harness.cpp`'s H2 (fake page ops, which themselves check "the
extent is free before and after the discard" and "no populate over a released extent") and H3
(real `mmap`/`madvise`, per-page patterns) script, built without TSan as `gc-helper-trace`
(`test/gc-helper-tsan/CMakeLists.txt`, `-DECO_TLA_TRACE=ON`). `gc-helper-trace pagework
<fake|real> <threads> <jitter us> <steps> <extents> <window extents> <seed> [<delay> [<reuse %>]]`
runs one script in Concurrent mode between `tlatrace::begin` and `end` (after `pool.drain()`, so
the workers are quiescent), with a lock standing in for `thread_mutex_`. The extent count, the
decommit delay and the reuse percentage are the only knobs (defaults: the script's own).

**Events** (`PageWork.cpp`'s `PW_TRACE` hooks; `nameThread("eco-gc", i)` in
`GCHelperPool::workerLoop`). Every event carries a stamp from one process-wide seq_cst counter
(`clk "pw"`), taken where its model step sits, so the merged log is one total order and is matched
in order (`TraceInOrder`).

| Event | Hook | Model step |
|---|---|---|
| `rel x` | `onRelease` entry | `M_Choose` (release), `ext = x` |
| `pend x` | `onRelease` end | `M_RelPend` |
| `acq x st slot` | `onReuse` entry; `st` = `pending_` / `posted_discard_` membership, `slot` its job's | `M_Choose` (reuse): `ext = x` (first fit), and `pw[x]`, `postedIn[x]` must be the code's |
| `reused x r` | `onReuse`'s returns | `M_Touch` |
| `fresh x` | `onFreshBump` entry | `M_Choose` (fresh), `owner[x]`: fresh → heap |
| `reaped mask` | `reapDone`'s end (the slots it reaped) | in `syncPoint`: recorded, reaped by the `sync` step; in `takeSlot`: `TS_ReapDone` |
| `age x` | the aging loop, per aged extent | recorded (`x` must be Pending) |
| `sync size` | after the aging loop | `M_Choose` (sync): the recorded reaps and batch |
| `window lo hi` | `topUpWindow`, after the commit | `M_Window`, `win = lo..hi-1` |
| `await slot` | `awaitSlot`, after `pool.wait` and `reap` | `AS_Wait` |
| `post slot seq kind` | `postDiscardBatch`, `topUpWindow`, before `pool.post` | `M_Post` / `M_PostP` |
| `start seq kind` | `runJob` entry (worker) | `W_Take` |
| `body seq x` | after each discard `madvise` | `W_Body` (one extent) |
| `jobdone seq` | `runJob`'s end (the pool's Done store follows under `m_`) | `W_Body` (Done) |

Extents are logged by their 1-based index (the harness's `setObjId`); code slot k is model slot
k + 1; a job is known by its post sequence number. **Hidden:** `M_RelWait`'s call and exit,
`M_Reuse`, the `takeSlot` calls, `TS_Oldest` (the `await` then names the slot), a sync point
without a window, and the loop's exit. **Checked on every matched step:** the model's
invariants (`HEAP_059`, `HEAP_060`, `V1`, V2a/b, `DetChoice`, `PostIdle`), at the trace's scale
(up to 64 extents, 8 slots, 4 workers). The configuration narrows the model's three free choices
(`ReapChoices`, `AgeChoices`, `WindowChoices`) to the logged value, intersected with the model's
own set, so TLC does not enumerate `SUBSET` of 64 fresh extents.

**Stamp placement** (why the total order is the model's): each stamp is taken in program order at
its step, and every cross-thread dependency runs through a synchronisation after one stamp and
before the other (post: stamp, then the post CAS and the enqueue under `m_`, then the worker's
dequeue and its `start` stamp; `jobdone`: stamp, then the Done store under `m_`, then the waiter's
acquire and its `await` stamp). A `jobdone` stamp can precede a `reapDone` that still saw the
slot not Done; the model allows that (a reap of any subset of the Done slots). The `body` stamp
follows its `madvise`, so a reuse that overlapped the `madvise` would come before it and break
`HEAP_059`.

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/GCHelperPool.hpp` | `-` |
| file | `runtime/src/allocator/GCHelperPool.cpp` | `-` |
| file | `runtime/src/allocator/PageWork.hpp` | `-` |
| file | `runtime/src/allocator/PageWork.cpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| file | `test/gc-helper-tsan/harness.cpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.startVirginBlockShared` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.startVirginBlockW` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.ladderFrom2W` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocatePromotion` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.sweepOnDemandAllocate` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.panicSweepAndRetryAllocation` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocateFromBagPage` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.lazySweep` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.ensureBagPageAvailable` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.allocateLargeBlock` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.releaseBlockToAllocator` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.releaseUnassignedBlockToAllocator` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureTeardown` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.TenureParEnv` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.runJobParallel` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.acquireOldGenBlock` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.releaseOldGenBlock` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.acquireOldGenRegion` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.onGCPauseEnd` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.rebuildPageWork` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.cleanupThread` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.finishTenureForExit` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.callerInPause` |
| census | `runtime/src/allocator/Allocator.cpp` | `-` |
| census | `runtime/src/allocator/Allocator.hpp` | `-` |
| census | `runtime/src/allocator/GCHelperPool.cpp` | `-` |
| census | `runtime/src/allocator/GCHelperPool.hpp` | `-` |
| census | `runtime/src/allocator/GCStats.cpp` | `-` |
| census | `runtime/src/allocator/GCStats.hpp` | `-` |
| census | `runtime/src/allocator/NurseryTenure.cpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.cpp` | `-` |
| census | `runtime/src/allocator/PageWork.cpp` | `-` |
| grep | `-` | `F.promoMu` |
| grep | `-` | `F.threadMutex` |
| grep | `-` | `F.pageWorkCalls` |
| grep | `-` | `F.stopAndJoin` |
| grep | `-` | `F.oldGenFreeBlocks` |
| grep | `-` | `F.setThreadHeap` |
<!-- canary-pins end -->
