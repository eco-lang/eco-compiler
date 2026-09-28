# Threaded GC — TLA+ model M7: PageWork (deferred decommit, commit-ahead) and the lock order

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). Adversarial review on 2026-09-28 against the
current tree (§11): the sketches in §4.6 were revised and the revised text passes the PlusCal
translator and SANY (tla2tools 1.8.0). **TLC has not run on them.** Expected results in §5 and §6
are predictions from reading the code.

**Parents:** `plans/threaded-gc-tla-verification.md` (rules A1–A9, §5.0 contracts) and
`plans/threaded-gc-tla-primer.md`. The layout follows `plans/threaded-gc-tla-M2-slice-control.md`.
M7 assumes M6's **pool contract** (M6a's pool half, not LaunchJoin): a posted job is eventually
run exactly once, in any order, and `wait` returns only when the job is Done. M6a checks it
(`ParentJobsFinish`; the queue is dequeued under `m_`). M7 does not use LaunchJoin: its gang
members need no launch or join publication, only their locks.

**Register entries:** CR-007 (a `promo_mu_` holder blocking on a helper job), CR-006 (coverage),
CR-014 (its tail path is a second route into the CR-007 chain, §2.4). **CR-012 is outside M7**
(§10 Q1): M7 models one heap.

---

## 1. Why this model, and what it checks

`PageWork` (`runtime/src/allocator/PageWork.cpp`) moves two kinds of page housekeeping off the
mutator onto the helper pool (threaded-gc-03, HEAP_059/HEAP_060):

- **Deferred decommit (U1).** When the old gen releases an extent (a range of pages), the pages are
  not given back to the OS at once (`MADV_DONTNEED`). The extent sits in the free list as
  **Pending**. If it is still unused after one major GC, a helper job **discards** it. If the
  allocator reuses it before then, the discard is cancelled and the pages are still resident, which
  saves a refault.
- **Commit-ahead (U2).** At each pause end, the range just above the old gen's allocation frontier
  (the "bump") is mapped, and a helper job **pre-faults** it (`MADV_POPULATE_WRITE`). Fresh blocks
  then arrive already backed by memory.

Because the helper runs later, on another thread, three things can go wrong, and M7 checks each at
small scale:

1. **A reused extent is discarded under its new owner.** The heap writes an object, the helper's
   `MADV_DONTNEED` then zeroes the pages, and the object reads back as zeros. That is silent heap
   corruption. HEAP_059 forbids it.
2. **A discard races a populate on the same pages.** Not corruption, but it leaves discarded pages
   resident again. HEAP_060 makes a release wait for any overlapping in-flight populate.
3. **Allocation choices depend on helper progress.** Which extent an allocation gets must depend
   only on mutator state, never on how far a helper got, or runs stop being reproducible
   (GC_DET_001).

A second small module checks the **lock chain** of a parallel minor that needs a fresh page:
- `promo_mu_` → `Allocator::thread_mutex_` → the pool's `m_` inside `wait`;
- no deadlock, and every waiter gets through (CR-007).

## 2. The protocol in plain words

### 2.1 An extent's life

| State | In the free list? | Meaning | Leaves by |
|---|---|---|---|
| owned by the heap | no | in use | `releaseOldGenBlock` → Pending |
| **Pending** | yes | released, still resident, discard not posted yet | reuse → **cancel** (resident); aged at a sync point → Posted |
| **Posted** | **yes** (so choices never depend on the job) | a Discard job for it is queued or running | reuse → **wait** for the job, then reap; job Done → reaped at a later sync point / slot take |
| free, not tracked | yes | discarded (or decommit off) | reuse (reads as zero-fill) |

Every PageWork call runs **under `Allocator::thread_mutex_`** (HEAP_058). The caller is usually the
mutator, but in a parallel minor (and in 7c's pause tenure engine, `runJobParallel`,
`NurseryTenure.cpp:1168`) a **gang thread** reaches `acquireOldGenBlock` → `onReuse` through
promotion (§2.4, CR-007), and CR-014's route reaches `releaseOldGenBlock` → `onRelease` the same way.
`thread_mutex_` serialises all of them, so PageWork itself is single-threaded. The only concurrency
is between those calls and the helper workers running job bodies.

**Aging** (`syncPoint`, `PageWork.cpp:234-266`):
- At each pause end, the mutator bumps `sync_epoch_`, and `major_epoch_` if the pause contained a
  major (`Allocator::onGCPauseEnd`, `Allocator.cpp:1243-1262`).
- `syncPoint` first reaps every Done slot (`reapDone`, 237).
- A Pending extent is aged when `major_epoch − pending.major_epoch > decommit_delay_majors`
  (default 1), or `epoch − pending.epoch > decommit_delay_syncs` (default never), or while pending
  bytes exceed `decommit_pending_max_bytes` (default 0 = no cap). The loop walks `pending_order_`
  (release order) and stops at the first entry not due; entries of cancelled extents are stale and
  skipped by `seq` (244-247).
- All aged extents go into one Discard job, which is posted into one of 8 job slots (`takeSlot`
  reaps finished slots and, if all 8 are busy, waits for the oldest).
- The model does not reproduce this rule: at a sync point it ages **any subset** of the Pending
  extents (§4.2). No safety property depends on when a discard is posted, and the free choice
  covers every setting, including the syncs-plus-cap setting of the H2/H3 harness (§8).

### 2.2 The rule "never discard under a new owner", as a timeline

Mutator M, helper worker W; extent X released long ago, now aged.

| # | M | W | X |
|---|---|---|---|
| 1 | sync point: X aged → Discard job J{X} posted; X stays in the free list | | Posted |
| 2 | promotion needs a page: `acquireOldGenBlock` first-fit picks X (swap-remove) | | chosen |
| 3 | `onReuse(X)`: X is Posted → `awaitSlot(J)` → **`pool.wait(J)` blocks** | takes J, runs `MADV_DONTNEED(X)` | discarded |
| 4 | | J Done, notify | |
| 5 | wakes; reaps J (X untracked); `MADV_WILLNEED`; returns X | | |
| 6 | the heap writes objects into X | | owned, data |

If step 3 did not wait (mutant `reuse_no_wait`), step 6 could come first, and W's discard would then
zero the heap's objects. The model's invariant `HEAP_059` requires every extent that a running
Discard job has still to `madvise` to be free, so TLC finds that order at once.

Why the *choice* in step 2 does not look at X's state: a Posted extent stays in the free list and
first-fit may pick it. The price is a possible wait. The benefit is that the choice is the same
whether the helper has run or not, which is GC_DET_001. The model keeps a **ghost copy** of the free
list (`gFree`), updated by the same mutator operations but never reading PageWork state, and checks
`freeList = gFree` in every state (`DetChoice`). The mutant `skip_posted_extents` ("skip extents
whose discard is still posted", an optimisation someone might plausibly add) breaks it.

### 2.3 Commit-ahead and the release wait

- `topUpWindow` (`PageWork.cpp:210-232`) commits `[max(window_end, bump), target)` on the mutator
  and posts a Populate job over it.
- A fresh bump allocation inside the window **does not wait** for the populate (`onFreshBump`,
  171-187). Populate never changes a page's contents, so the mutator may write while it runs
  (HEAP_060; plan 03 P§3.7).
- The one ordering prevented: an extent acquired from the window, used, and **released** while its
  populate is still running. Its later discard could race the populate and leave the pages
  resident. So `onRelease` first waits for any in-flight populate that overlaps it
  (`awaitPopulateOverlapping`, 127-133).

With the default single pool worker, jobs run in FIFO order, so a populate posted earlier always
finishes before a later discard starts, and the wait is belt-and-braces. With
`gc_helper_threads > 1` the two can run at once. The model's workers take **any** Posted job (M6's
contract promises no order), so the race is reachable with one worker too; `pw_two_workers` adds
truly concurrent bodies.

**Which commit-ahead races exist** (all checked against the code, 2026-09-28):

| Race on the window range | Outcome | Why |
|---|---|---|
| a fresh bump acquire inside the window, the heap writing while the populate runs | harmless by construction | `MADV_POPULATE_WRITE` faults pages writable without writing them (HEAP_060) |
| the bump passes the window end | harmless by construction | `onFreshBump` commits only `[window_end_, end)` (`Allocator.cpp:852-856`); it never re-maps the window |
| `topUpWindow`'s own commit | harmless by construction | it maps `[max(window_end_, bump), target)` (214-216): above every earlier window and every released extent |
| a release of a window extent, then its discard | **prevented by the release wait** | `awaitPopulateOverlapping` (127-133); the model's `HEAP_060` and mutant `release_no_await_populate` |
| a populate failure (`EINVAL`, `ENOMEM`) | harmless | `failures` counter only, read after Done |
| `acquireOldGenRegion` (`Allocator.cpp:989-1019`, called by `OldGenSpace::initialize`) maps `[bump, bump + initial_old_gen_size)` with `MAP_FIXED` **without** `onFreshBump` | content-neutral, but re-maps populated pages, which HEAP_060 says never happens | reachable only when a heap is created after an earlier heap's pause end (several or successive mutators); CR-012 territory, §10 Q1 |

### 2.4 The lock chain (CR-007), as a timeline

A parallel minor. G1 is a gang thread, G0 the mutator (also a gang member), W a pool worker.

| # | G1 | G0 | W |
|---|---|---|---|
| 1 | `allocatePromotion` → lock `promo_mu_` (`OldGenSpace.cpp:1587`) | | |
| 2 | ladder (`ladderFrom2W`, 1306) → `startVirginBlockShared` (1249) → `ensureBagPageAvailable` (866) → `acquireOldGenBlock` (871) → **lock `thread_mutex_`** (`Allocator.cpp:753`) | | |
| 3 | first-fit picks a Posted extent → `onReuse` → `pool.wait(J)` → **blocks, holding `promo_mu_` and `thread_mutex_`** | wants `promo_mu_`: spins 256 rounds, yields 256, then sleeps 10 µs per round (`SpinMutex::lock`, `MinorWork.hpp:91-107`) | runs J (takes only the pool's `m_`) |
| 4 | | | J Done, notify |
| 5 | wakes, returns the extent, unlocks both | gets `promo_mu_` | |

There is no cycle: W takes neither `promo_mu_` nor `thread_mutex_` (HEAP_058: "workers never take
`thread_mutex_`"). So this is a **stall**, not a deadlock.

**Every route into the chain** (census of `promo_mu_`, `thread_mutex_` and the pool's `m_`, 2026-09-28):
- `promo_mu_` is taken only in `allocatePromotion` (1547 for a block-sized object, small test
  geometries only; 1587 for the ladder). Under it, `acquireOldGenBlock` is reached through
  `startVirginBlockShared` → `ensureBagPageAvailable` (871), `allocateFromBagPage` (2430) and
  `allocateLargeBlock` (2743).
- **A release route exists (CR-014).** Under `promo_mu_`, `sweepOnDemandAllocate` (2136),
  `allocateFromBagPage` (2410) and `panicSweepAndRetryAllocation` (2164) call `lazySweep`, whose
  tail path (5466-5476) runs
  `onSweepComplete` (5488) → `maybeShrinkCapacity` → `releaseBlockToAllocator` (5995) →
  `releaseOldGenBlock` → `onRelease` → `awaitPopulateOverlapping` → `pool.wait` on a **populate**.
  Same shape, different job. M7b's job is generic, so the model covers it.
- The callers are the parallel minor's gang **and 7c's pause tenure engine**: `runJobParallel`
  (`NurseryTenure.cpp:1168`, mode 1 with `tenure_sync_threads > 1`, and help) runs
  `allocatePromotion` on `GCMarkGang` members (984). Only the concurrent tenure collector stays
  out: it allocates from its grant (`grantAllocateShared`, 985; 07 plan P§3.17 T6/T10).
- Under `thread_mutex_` a thread may block on: the pool (`wait` in `onReuse`, `onRelease`,
  `takeSlot`, `drainAll`); and a **background-gang join**: `tenureTeardown` →
  `collector->stopAndJoin()` (`NurseryTenure.cpp:904`), called under `thread_mutex_` from
  `cleanupThread` (`Allocator.cpp:359-366`), `finishTenureForExit` (384-385) and `reset` →
  `~ThreadLocalHeap` (`ThreadLocalHeap.cpp:241`). No cycle today: collector members take no
  allocator lock. Mutant `collector_takes_tm` (§5, to add) guards that.
- No thread runs a `GCMarkGang` of more than one member under `thread_mutex_` (`tenureTeardown`
  finishes with `n = 1`), and `ylos_mu_`, `PermanentSpace::mutex_` and the census mutexes are
  leaves. The lock graph is `promo_mu_` → `thread_mutex_` → {pool `m_`, a background-gang join}:
  acyclic.

A side effect: `callerInPause()` (`Allocator.cpp:1206`) reads the calling thread's `tl_heap_`,
which is null on gang threads, so G1's stall is counted as "outside a pause". That is stats only.

The model checks the chain for deadlock and starvation, and shows the stall is reachable
(`MODEL_M7_StallWitness`, §4.7). Its mutants show what would deadlock:
- a path that takes `thread_mutex_` before `promo_mu_`;
- a job body that takes `thread_mutex_`.

### 2.5 Every route back to a released extent (the HEAP_059 hazard)

A discard can land on live data only if the extent's pages are handed out again while the job is
queued or running. Every route, checked against the code (2026-09-28):

| Route | Reaches the pages through | In the model |
|---|---|---|
| old-gen mutator allocation: `ensureBagPageAvailable` (`OldGenSpace.cpp:871`), `allocateFromBagPage` (2430), legacy `populateFromBlock` (2519), evacuation (6621), `ensureOldGenCapacityFor` (`Allocator.cpp:960`) | `acquireOldGenBlock`'s first-fit branch (`Allocator.cpp:775-792`) → `onReuse` before any touch | the reuse branch |
| YLOS / large objects: `allocateLargeBlock` (2743) | the same branch (a page request may also take a larger extent; `onReuse` keys on its base and covers it whole) | the reuse branch |
| promotion on gang threads (parallel minor, pause tenure engine) | the same branch, under `promo_mu_` | the reuse branch (one caller at a time); M7b for the locks |
| another heap | the same branch (the free list is process-wide) | outside M7 (CR-012) |
| the bump paths: `acquireOldGenBlock`'s fresh branch, `acquireOldGenRegion` | never: they map only above `old_gen_committed`, which drops only in `reset()`, after `drainAll(true)` | the fresh branch |
| the nursery | never: its slices live above `nursery_offset` (`Allocator.cpp:598-724`), and the window is clamped there (`onGCPauseEnd`, 1257-1258) | — |
| `reset()`, `~Allocator` | `drainAll` waits for every slot first (1031, 223) | outside M7 (V5) |

So every reuse funnels through one call, `onReuse`, and the model's single reuse branch covers
all of them. What M7 **assumes** is the release side: the old gen releases an extent only when no
heap structure (block table, bag, cursor, stash, grant, free-cell list) still refers to it. V2b
checks that at every sync point; CR-014 and CR-016 are suspected breaches, and M4 owns them.

## 3. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| `PageWork::onRelease` | `PageWork.cpp:135-149` | `M_Choose` (release branch), `M_RelWait`, `M_RelPend` |
| `PageWork::awaitPopulateOverlapping` | 127-133 | `M_RelWait` loop |
| `PageWork::onReuse` | 151-169 | `M_Reuse` |
| `PageWork::onFreshBump` | 171-187 | the fresh-acquire branch |
| `PageWork::syncPoint` (reap, age, post, top up) | 234-266 | the sync branch: its first step in `M_Choose` (`ReapAllDone`, the aging choice), then `M_Take`, `M_Post`, `M_Window`, `M_TakeP`, `M_PostP` |
| `postDiscardBatch`, `topUpWindow` | 189-232 | `M_Post`, `M_PostP` |
| `takeSlot`, `reapDone`, `reap`, `awaitSlot` | 76-125 | procedures `TakeSlot`, `AwaitSlot`; macros `Reap`, `ReapAllDone` |
| `PageWork::runJob` (the job bodies) | 50-63 | process `Worker`, `W_Body` |
| `Allocator::acquireOldGenBlock` (first-fit, swap-remove, `onReuse`, V1, V4, `MADV_WILLNEED`) | `Allocator.cpp:752-885` (swap-remove 785-786, onReuse 792, V1 795, V4 808, `MADV_WILLNEED` 820) | the reuse branch, `M_Touch` |
| `Allocator::releaseOldGenBlock` | 891-939 (onRelease 901) | the release branch |
| `Allocator::onGCPauseEnd` (epochs, `syncPoint`) | 1243-1262 | the sync branch |
| `Allocator::validatePageWork` (V2a, V2b, V3) | 1272-1316 | `TrackedInFree` (V2a), `NoOwnedPosted` (V2b); V3 (populate bounds) is about addresses, not modelled |
| `OldGenSpace::allocatePromotion` (lock sections 1547-1557, 1587-1632) → `ladderFrom2W` (1306) → `startVirginBlockShared` (1249) → `ensureBagPageAvailable` (866-882); CR-014's release route (§2.4) | `OldGenSpace.cpp:1536-1646` | `LockOrder.tla`: `P_Promo`, `P_Tm`, `P_Reuse` |
| `minorwork::SpinMutex` | `MinorWork.hpp:85-113` | `promo` |

**Outside M7:**
- the pool's internals (M6a);
- which blocks the old gen releases, and when (OldGenSpace policy), and the release contract of
  §2.5 (M4; V2b at runtime);
- partial overlaps of a bump request with the window's end. The model works in whole extents. The
  window's 2 MiB granule and `alloc_buffer_size` blocks make a straddle possible in the code, but
  `onFreshBump` only splits the commit and never waits, so a straddle adds no new interleaving. An
  extent that overlaps **two** windows (a large block across a window boundary) is covered: the
  model's window is any subset of the fresh extents, so an extent can sit in two populates and
  `M_RelWait` loops;
- `reset()`, `~Allocator`, `drainHelperWork` (`drainAll`; V5), the double-release abort
  (`onRelease`, 140-142), and `decommit_on_oldgen_release = false` (`onRelease` returns after the
  populate wait; `onReuse` returns `NeverDiscarded`): a subset of the modelled behaviours;
- mode 1 (`Sync`: `post` runs the job inline, `GCHelperPool.cpp:162-167`): a subset of the worker
  interleavings; a `topUpWindow` commit failure (no populate): a subset;
- several heaps (CR-012, §10 Q1).

## 4. The model

### 4.1 Two modules

- **`PageWork.tla` (M7a)**: extents, the free list, PageWork tracking, job slots, the caller's
  four operations (release, reuse, fresh acquire, sync point), and pool workers running bodies.
- **`LockOrder.tla` (M7b)**: gang members, `promo_mu_`, a recursive `thread_mutex_`, one posted
  job (a discard met by `onReuse`, or a populate met by `onRelease` on CR-014's route) and a
  worker.

### 4.2 Abstractions

| Real thing | Model | Why sound |
|---|---|---|
| Extents of varied sizes; first-fit by size | all extents one size; first-fit = index 1; the exact swap-remove | page requests are all `alloc_buffer_size`. The size test, the page-request skips (the `heap_base` extent, non-page-multiple extents, `Allocator.cpp:778-779`) and a page request taking a larger extent read no PageWork state; `onReuse` keys on the extent's base and covers it whole |
| 8 job slots, "wait for the oldest" | 2 slots, "wait for any busy slot" | a superset of the real choices (over-approximation) |
| 1..64 pool workers, FIFO | 1 or 2 workers that take **any** Posted job | M6's contract promises no order, so this over-approximates FIFO; one worker already reaches the populate/discard race, 2 run bodies truly at once |
| `thread_mutex_` around every PageWork call, from the mutator or a gang thread (§2.1) | implicit: one caller process makes every call; worker steps interleave between its steps | `thread_mutex_` serialises every call and workers read only their own job's fields (`runJob`, 50-63), so which thread holds the lock is invisible to PageWork. Faithful for one heap. **Several heaps share one PageWork** (CR-012, outside M7, §10 Q1) |
| Aging: `delay_majors` (default 1), `delay_syncs` (default never), `pending_cap` (default 0), prefix of `pending_order_` | at a sync point, **any subset** of the Pending extents | the rule reads only mutator state (epochs, `pending_bytes`), so GC_DET_001 for it is the determinism gate's job (G8, `testDecommitModesAgreeOnCounters`), not M7's. No M7 property depends on when a discard is posted, and the free choice covers every setting (H2/H3 age by syncs and the cap). The lazy deletion in `pending_order_` (stale entries skipped by `seq`) is not modelled: see mutant `age_stale_entry` (§5, to add) |
| The window `[max(window_end_, bump), roundUp(bump + ahead, 2 MiB))` | at a sync point, **any subset** of the fresh extents (possibly empty: no window, a failed commit, populate unsupported) | only the release wait depends on it, and any subset over-approximates the real range, including an extent in two windows |
| Page contents | not modelled | the only way a discard zeroes heap data is a discard under an owner, which `HEAP_059` checks on `owner` |
| `MADV_POPULATE_WRITE` | a body step with no effect | content-neutral by definition |
| The pool | M6's contract: `Posted → Running → Done`, run once, fair workers | checked in M6a |

### 4.3 Constants

| Constant | Module | Meaning | Values |
|---|---|---|---|
| `Extents`, `InitHeap`, `InitFresh` | M7a | extents; those owned at start (below bump); those above bump (window range) | `{1,2,3}`, `{1,2}`, `{3}` |
| `Slots` | M7a | job slots | `{1,2}` |
| `Workers` | M7a | pool workers | `{"w1"}` or `{"w1","w2"}` |
| `MaxOps` | M7a | bound on caller operations | 5 (quick pass configs), 4 (mutants: each needs at most 4, §5), 7 (deep) |
| `Members` | M7b | gang members | `{"mut","g1"}` |
| `MUTANT` | both | §5 | |

### 4.4 Variables (M7a)

| Variable | Code counterpart |
|---|---|
| `owner[x]` | heap-owned / free / above the bump (`fresh`) |
| `freeList` | `Allocator::old_gen_free_blocks_` |
| `gFree` | ghost: the free list as a job-blind allocator would keep it (GC_DET_001); equal to `freeList` in every base state, so it adds no states |
| `pw[x]`, `postedIn[x]` | `PageWork::pending_` / `posted_discard_` entries (`postedIn` is reset at reap, so no stale slot numbers) |
| `sstate[s]`, `skind[s]`, `sext[s]` | `slots_[s]`: job state, kind, extents or populate range |
| `takenSlot` | `takeSlot`'s return value |

Removed by the 2026-09-28 review (they added states and no bug-finding power): `content` (never
read by a property), `pendMajor`, `majors` and `DelayMajors` (aging is a free choice), `covered`
(the window is a free choice). The caller's locals are `n`, `ext`, `rs`, `rsel`, `batch`, `win`;
a worker's are `cur`, `todo`.

M7b's variables are the lock holders (`promo`, `tmOwner` with `tmDepth`), the job state, `reused`
(the job's extent was handed out once), and `waiting` (blocked in `wait`). The pool's `m_` is not
a variable: it is a leaf lock, never held across a wait (`cv_done_.wait` releases it), so it
cannot close a cycle.

### 4.5 Labels to code

| Label | Code | Step |
|---|---|---|
| `M_Choose` (release) | `Allocator.cpp:891-901` | pick an owned extent; compute the overlapping populates |
| `M_RelWait` | `PageWork.cpp:127-133` | wait for one overlapping populate, reap it; loop |
| `M_RelPend` | 135-149 | Pending; append to the free list (and the ghost) |
| `M_Choose` (reuse) | `Allocator.cpp:775-786` | first-fit + swap-remove (the ghost does the same) |
| `M_Reuse` | `PageWork.cpp:151-169` | cancel Pending, or wait for Posted |
| `M_Touch` | `Allocator.cpp:793-827` | V1 holds here (invariant `V1`); V4, `MADV_WILLNEED`; the heap owns it |
| fresh branch | `PageWork.cpp:171-187` | bump acquire, no wait |
| `M_Choose` (sync) | `Allocator.cpp:1253-1258`; `PageWork.cpp:237-261` | `reapDone`, then choose the aged batch (any subset of Pending) |
| `M_Take`/`M_Post` | 113-125, 189-208 | take a slot; post the Discard job |
| `M_Window`/`M_TakeP`/`M_PostP` | 210-232 | choose the window (any subset of the fresh extents); post a Populate |
| `AS_Wait` | 103-111 | `pool.wait` then `reap` |
| `TS_*` | 113-125 | `takeSlot` |
| `W_Take`, `W_Body`, `W_Done` | `GCHelperPool.cpp:203-221`, `PageWork.cpp:50-63` | dequeue; one `madvise` per extent; Done |
| `P_Promo` | `OldGenSpace.cpp:1587-1596` | `promo_mu_` |
| `P_Tm` | `Allocator.cpp:753` | `thread_mutex_` (recursive) |
| `P_Reuse`, `PW_*` | `Allocator.cpp:792`, `PageWork.cpp:160` (or `onRelease` → 131 on CR-014's route), `GCHelperPool.cpp:236-252` | onReuse / onRelease → wait |

### 4.6 The PlusCal sketches

Files: `test/tla/M7-pagework/PageWork.tla` and `LockOrder.tla`. This is the text that passed the
translator (`pcal -nocfg`) and SANY with no errors on 2026-09-28, after the review's revision; the
translations are omitted. `PageWork.tla`'s procedure `AwaitSlot` has a parameter, so its configs
need `defaultInitValue = defaultInitValue` (primer §2, pitfall 3).

**M7a — PageWork.tla**

```tla
------------------------------ MODULE PageWork ------------------------------
(***************************************************************************)
(* M7a: PageWork (runtime/src/allocator/PageWork.cpp): deferred decommit   *)
(* (Pending -> Posted discard -> reaped; a reuse cancels or waits) and     *)
(* commit-ahead (populate jobs; a release waits for an overlapping one),   *)
(* driven by one caller at a time under Allocator::thread_mutex_ (the      *)
(* mutator, or a gang thread promoting), with the jobs run on helper-pool  *)
(* workers. The pool is M6a's: a posted job runs once; wait returns only   *)
(* when it is Done. Aging and the window are free choices (any subset),    *)
(* an over-approximation of every decommit_delay_* / cap / window setting. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Extents,         \* old-gen extents of one size (alloc_buffer_size)
    InitHeap,        \* extents the heap owns at the start (below the bump)
    InitFresh,       \* extents above the bump (the commit-ahead window's range)
    Slots,           \* PageWork::slots_ (kJobSlots = 8 in code)
    Workers,         \* pool workers (gc_helper_threads, default 1)
    MaxOps,          \* bound on caller operations
    MUTANT           \* "none", "reuse_no_wait", "release_no_await_populate",
                     \* "skip_posted_extents"

TruncLast(sq) == SubSeq(sq, 1, Len(sq) - 1)
Range(sq) == {sq[i] : i \in 1..Len(sq)}
\* old_gen_free_blocks_' swap-remove: *it = back(); pop_back().
RemoveAt(sq, i) == IF i = Len(sq) THEN TruncLast(sq)
                   ELSE TruncLast([sq EXCEPT ![i] = sq[Len(sq)]])
\* The mutant's choice: the first extent whose discard is not Posted.
FirstNotPosted(sq, st) ==
    CHOOSE i \in 1..Len(sq) : st[sq[i]] # "Posted" /\ \A k \in 1..(i - 1) : st[sq[k]] = "Posted"

(* --algorithm PageWork
variables
    owner     = [e \in Extents |-> IF e \in InitHeap THEN "heap"
                                   ELSE IF e \in InitFresh THEN "fresh" ELSE "free"],
    freeList  = <<>>,                       \* old_gen_free_blocks_
    gFree     = <<>>,                       \* ghost: the same list, job-blind (GC_DET_001)
    pw        = [e \in Extents |-> "none"], \* PageWork tracking: none / Pending / Posted
    postedIn  = [e \in Extents |-> 0],      \* Posted::slot (0 when not Posted)
    sstate    = [s \in Slots |-> "Idle"],   \* HelperJob::state of PageJob s
    skind     = [s \in Slots |-> "None"],   \* Discard / Populate
    sext      = [s \in Slots |-> {}],       \* extents (discard) or window extents (populate)
    takenSlot = 0;                          \* TakeSlot's result

define
    PopulateInFlightOver(e) ==
        \E s \in Slots : skind[s] = "Populate" /\ sstate[s] \in {"Posted", "Running"}
                         /\ e \in sext[s]
    \* V2b: no heap-owned extent is Pending or Posted.
    NoOwnedPosted == \A x \in Extents : owner[x] = "heap" => pw[x] = "none"
    \* GC_DET_001: the free list (hence every acquire's choice) never depends
    \* on helper progress: it equals its job-blind ghost.
    DetChoice == freeList = gFree
end define;

\* PageWork::reap(s): observed Done; forget the posted extents; slot Idle.
macro Reap(s) begin
    pw := [x \in Extents |-> IF skind[s] = "Discard" /\ x \in sext[s] /\ pw[x] = "Posted"
                                /\ postedIn[x] = s THEN "none" ELSE pw[x]];
    postedIn := [x \in Extents |-> IF skind[s] = "Discard" /\ x \in sext[s] /\ postedIn[x] = s
                                      THEN 0 ELSE postedIn[x]];
    skind[s] := "None";
    sext[s] := {};
    sstate[s] := "Idle";
end macro;

\* PageWork::reapDone(): reap every Done slot.
macro ReapAllDone() begin
    pw := [x \in Extents |-> IF \E s \in Slots : sstate[s] = "Done" /\ skind[s] = "Discard"
                                   /\ x \in sext[s] /\ postedIn[x] = s /\ pw[x] = "Posted"
                              THEN "none" ELSE pw[x]];
    postedIn := [x \in Extents |-> IF \E s \in Slots : sstate[s] = "Done" /\ skind[s] = "Discard"
                                         /\ x \in sext[s] /\ postedIn[x] = s
                                    THEN 0 ELSE postedIn[x]];
    skind  := [s \in Slots |-> IF sstate[s] = "Done" THEN "None" ELSE skind[s]];
    sext   := [s \in Slots |-> IF sstate[s] = "Done" THEN {} ELSE sext[s]];
    sstate := [s \in Slots |-> IF sstate[s] = "Done" THEN "Idle" ELSE sstate[s]];
end macro;

\* awaitSlot(s): pool.wait(s) (returns when Done), then reap.
procedure AwaitSlot(as)
begin
  AS_Wait:
    await sstate[as] \in {"Idle", "Done"};
    if sstate[as] = "Done" then Reap(as); end if;
    return;
end procedure;

\* takeSlot: reapDone, then an Idle slot, else wait for the oldest (any here).
procedure TakeSlot()
variables ts = 0;
begin
  TS_ReapDone:
    ReapAllDone();
    if \E s \in Slots : sstate[s] = "Idle" then
        takenSlot := CHOOSE s \in Slots : sstate[s] = "Idle";
        return;
    end if;
  TS_Oldest:
    with s \in Slots do ts := s; end with;
  TS_Wait:
    call AwaitSlot(ts);
  TS_Got:
    takenSlot := ts;                     \* (return resets the local ts)
    return;
end procedure;

\* The caller: each operation is one PageWork call under thread_mutex_.
fair process Mutator = "mut"
variables n = 0, ext = 0, rs = {}, rsel = 0, batch = {}, win = {};
begin
  M_Loop:
    while n < MaxOps do
      M_Choose:
        either                                            \* releaseOldGenBlock(ext)
            await \E x \in Extents : owner[x] = "heap";
            with x \in {y \in Extents : owner[y] = "heap"} do ext := x; end with;
            rs := {s \in Slots : skind[s] = "Populate" /\ sstate[s] # "Idle" /\ ext \in sext[s]};
          M_RelWait:                                      \* awaitPopulateOverlapping
            if MUTANT # "release_no_await_populate" /\ rs # {} then
                rsel := CHOOSE s \in rs : TRUE;
                rs := rs \ {rsel};
                call AwaitSlot(rsel);
                goto M_RelWait;
            end if;
          M_RelPend:                                      \* onRelease: Pending, free list
            owner[ext] := "free";
            pw[ext] := "Pending";
            freeList := Append(freeList, ext);
            gFree := Append(gFree, ext);
            ext := 0; rs := {};
        or                                                \* acquireOldGenBlock: reuse
            await freeList # <<>>;
            if MUTANT = "skip_posted_extents" /\ \E i \in 1..Len(freeList) : pw[freeList[i]] # "Posted" then
                ext := freeList[FirstNotPosted(freeList, pw)];
                freeList := RemoveAt(freeList, FirstNotPosted(freeList, pw));
            else
                ext := freeList[1];                         \* first fit (all extents one size)
                freeList := RemoveAt(freeList, 1);
            end if;
            gFree := RemoveAt(gFree, 1);                  \* the job-blind choice
          M_Reuse:                                        \* onReuse (BEFORE any touch)
            if pw[ext] = "Pending" then
                pw[ext] := "none";                          \* Cancelled: still resident
            elsif pw[ext] = "Posted" then
                if MUTANT = "reuse_no_wait" then
                    pw[ext] := "none";
                else
                    call AwaitSlot(postedIn[ext]);          \* AfterDiscard
                end if;
            end if;
          M_Touch:                                        \* (V1 holds here) the heap owns it
            owner[ext] := "heap";
            ext := 0;
        or                                                \* acquireOldGenBlock: fresh bump
            await \E x \in Extents : owner[x] = "fresh";
            with x \in {y \in Extents : owner[y] = "fresh"} do
                owner[x] := "heap";                       \* onFreshBump: never waits
            end with;
        or                                                \* onGCPauseEnd -> syncPoint
            ReapAllDone();                                \* (a) reapDone
            with b \in SUBSET {x \in Extents : pw[x] = "Pending"} do
                batch := b;                               \* (b) age: any choice
            end with;
            if batch # {} then
              M_Take:
                call TakeSlot();
              M_Post:                                     \* (c) one Discard job
                skind[takenSlot] := "Discard";
                sext[takenSlot] := batch;
                pw := [x \in Extents |-> IF x \in batch THEN "Posted" ELSE pw[x]];
                postedIn := [x \in Extents |-> IF x \in batch THEN takenSlot ELSE postedIn[x]];
                sstate[takenSlot] := "Posted";
            end if;
          M_Window:                                       \* (d) topUpWindow: any fresh range
            with w \in SUBSET {x \in Extents : owner[x] = "fresh"} do
                win := w;
            end with;
            if win # {} then
              M_TakeP:
                call TakeSlot();
              M_PostP:
                skind[takenSlot] := "Populate";
                sext[takenSlot] := win;
                sstate[takenSlot] := "Posted";
            end if;
          M_SyncDone:
            batch := {};
            win := {};
        end either;
      M_Next:
        n := n + 1;
    end while;
end process;

\* Pool workers run job bodies (M6a: each posted job runs once; any order).
fair process Worker \in Workers
variables cur = 0, todo = {};
begin
  W_Loop:
    while TRUE do
      W_Take:                                             \* dequeue: any Posted job
        await \E s \in Slots : sstate[s] = "Posted";
        with s \in {x \in Slots : sstate[x] = "Posted"} do
            cur := s;
            sstate[s] := "Running";
            todo := sext[s];
        end with;
      W_Body:                                             \* one madvise per extent
        while todo # {} do
            todo := todo \ {CHOOSE x \in todo : TRUE};
        end while;
      W_Done:
        sstate[cur] := "Done";
        cur := 0;
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION

-----------------------------------------------------------------------------
\* HEAP_059: a running Discard job never has a heap-owned extent left to
\* madvise (it would zero the new owner's objects).
HEAP_059 == \A w \in Workers :
    (pc[w] = "W_Body" /\ skind[cur[w]] = "Discard") => \A x \in todo[w] : owner[x] = "free"

\* HEAP_060's purpose: no Discard runs over an extent a populate still covers.
HEAP_060 == \A w \in Workers :
    (pc[w] = "W_Body" /\ skind[cur[w]] = "Discard") => \A x \in todo[w] : ~PopulateInFlightOver(x)

\* V1: the extent onReuse hands back is neither Pending nor Posted.
V1 == pc["mut"] = "M_Touch" => pw[ext] = "none"

\* V2a: every tracked extent is in the free list, except the one an acquire has
\* just swap-removed and is passing to onReuse (the same thread_mutex_ section
\* in the code; two steps here).
TrackedInFree == \A x \in Extents : pw[x] # "none" => (x \in Range(freeList) \/ x = ext)

\* Liveness: the caller's waits all return (worker fairness).
MutatorFinishes == <>(pc["mut"] = "Done")
=============================================================================
```

**M7b — LockOrder.tla**

```tla
------------------------------ MODULE LockOrder ------------------------------
(***************************************************************************)
(* M7b: the lock chain of a parallel minor whose promotion reaches the     *)
(* allocator (CR-007):                                                     *)
(*   promo_mu_ (minorwork::SpinMutex)                                      *)
(*     -> Allocator::thread_mutex_ (std::recursive_mutex)                  *)
(*       -> GCHelperPool::wait (PageWork::onReuse on a Posted discard, or  *)
(*          onRelease on an in-flight populate: CR-014's release route).   *)
(* Pool workers take only the pool's m_, a leaf lock never held across a   *)
(* wait (cv_done_.wait releases it), so m_ is not modelled. The mutator is *)
(* gang member "mut".                                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Members,         \* parallel-minor gang members, including "mut" (worker 0)
    MUTANT           \* "none", "tm_then_promo", "worker_takes_tm"

(* --algorithm LockOrder
variables
    promo   = "none",            \* promo_mu_ holder
    tmOwner = "none",            \* thread_mutex_ owner (recursive: depth below)
    tmDepth = 0,
    job     = "Posted",          \* the helper job whose extent the chain meets
    reused  = FALSE,             \* that extent was handed out (once)
    waiting = {};                \* blocked in cv_done_.wait

define
    TmFree(p) == tmOwner \in {"none", p}
end define;

\* pool.wait(job): under m_, check Done, else block (the wait releases m_);
\* re-check on wake.
procedure PoolWait()
begin
  PW_Lock:
    if job = "Done" then return;
    else waiting := waiting \cup {self};
    end if;
  PW_Blocked:
    await self \notin waiting;
    goto PW_Lock;
end procedure;

\* allocatePromotion -> ladder -> startVirginBlockShared / allocateFromBagPage
\* -> ensureBagPageAvailable -> Allocator::acquireOldGenBlock (under promo_mu_).
fair process Member \in Members
begin
  P_First:
    if MUTANT = "tm_then_promo" /\ self = "mut" then   \* a path taking the locks in reverse
        await TmFree(self);
        tmOwner := self; tmDepth := tmDepth + 1;
      P_ThenPromo:
        await promo = "none";
        promo := self;
        goto P_Release;
    end if;
  P_Promo:                                              \* SpinMutex::lock (spin/yield/sleep)
    await promo = "none";
    promo := self;
  P_Tm:                                                 \* lock_guard<recursive_mutex>
    await TmFree(self);
    tmOwner := self;
    tmDepth := tmDepth + 1;
  P_Pick:                                               \* first-fit meets the job's extent, once
    if ~reused then
        reused := TRUE;
      P_Reuse:                                          \* onReuse: Posted -> awaitSlot -> wait
        if job # "Done" then call PoolWait(); end if;
    end if;
  P_Release:
    tmDepth := tmDepth - 1;                             \* ~lock_guard (recursive depth)
    if tmDepth = 0 then tmOwner := "none"; end if;
  P_Unpromo:
    promo := "none";
end process;

\* A pool worker running the job (M6a's workerLoop; it takes only m_).
fair process Worker = "w1"
begin
  W_Take:
    await job = "Posted";
    job := "Running";
  W_Body:                                               \* madvise: no allocator lock ...
    if MUTANT = "worker_takes_tm" then                  \* ... unless a job calls back in
        await tmOwner = "none";
        tmOwner := "w1"; tmDepth := 1;
      W_BodyRel:
        tmOwner := "none"; tmDepth := 0;
    end if;
  W_Done:                                               \* Done under m_
    job := "Done";
  W_Notify:                                             \* cv_done_.notify_all
    waiting := {};
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION

-----------------------------------------------------------------------------
\* Liveness: every member finishes its promotion (no starvation behind the
\* spin lock while the holder waits for the helper).
AllFinish == <>(\A p \in Members \cup {"w1"} : pc[p] = "Done")

\* CR-007's stall, as a reachability witness (expected: VIOLATED in
\* lock_order_stall): one member holds promo_mu_ and thread_mutex_ and is
\* blocked in wait, while another waits for promo_mu_.
MODEL_M7_StallWitness ==
    ~\E p, q \in Members : /\ p # q /\ promo = p /\ tmOwner = p
                           /\ p \in waiting /\ pc[q] = "P_Promo"
=============================================================================
```

### 4.7 Properties

| Property | Module | Kind | Meaning | Expected |
|---|---|---|---|---|
| `HEAP_059` | M7a | invariant | **HEAP_059**: every extent a running Discard job has still to `madvise` is free (nothing the heap owns is discarded) | holds; fails under `reuse_no_wait` |
| `HEAP_060` | M7a | invariant | HEAP_060's purpose: no running Discard job has an extent that a Posted or Running populate covers | holds; fails under `release_no_await_populate` |
| `V1` | M7a | invariant | V1: at `M_Touch` the extent handed out is untracked | holds |
| `NoOwnedPosted` | M7a | invariant | V2b: no owned extent is Pending/Posted | holds |
| `TrackedInFree` | M7a | invariant | V2a: tracked extents are in the free list (except the one in `onReuse`) | holds |
| `DetChoice` | M7a | invariant | GC_DET_001: the free list equals its job-blind ghost | holds; fails under `skip_posted_extents` |
| `MutatorFinishes` | M7a | liveness | every wait returns | holds (fair workers) |
| deadlock | M7b | TLC's deadlock check, **`CHECK_DEADLOCK TRUE` written in every M7b cfg** (the translation's `Terminating` makes finished runs legal) | the lock chain cannot deadlock | holds; fails under `tm_then_promo`, `worker_takes_tm` |
| `AllFinish` | M7b | liveness (the same formula as the translator's `Termination`) | every member finishes | holds |
| `MODEL_M7_StallWitness` | M7b | invariant used as a **reachability witness** | "no member is blocked on `promo_mu_` while the holder waits for the job" | **fails** in `lock_order_stall`: this is CR-007's stall, shown reachable; if it ever passes, M7b no longer reaches the chain and `lock_order`'s pass means nothing |

The review turned the three `assert`s of the first draft into the named invariants `HEAP_059`,
`HEAP_060` and `V1` (A7): a runner that matches names cannot match an assertion's line and column.
They are state predicates on the worker's `todo` and the caller's `pc`, equivalent to the asserts on
every behaviour: a violating state of one leads to a violating step of the other.

For M7a, configurations set `CHECK_DEADLOCK FALSE`: workers loop forever, and the translation's
`Terminating` does not cover them. `MutatorFinishes` covers progress instead. For M7b the opposite:
a deadlock **is** the verdict, so every M7b cfg says `CHECK_DEADLOCK TRUE` explicitly (so that a
copied M7a cfg cannot switch it off), and the runner (parent §6.1) must accept "deadlock" as a
named expected outcome.

## 5. Negative controls

| `MUTANT` | Code change | Configuration | Must violate |
|---|---|---|---|
| `reuse_no_wait` | `onReuse` of a Posted extent returns without `awaitSlot` | `pw_basic` | `HEAP_059` (3 ops: release 1; sync, age `{1}`; reuse 1) |
| `release_no_await_populate` | `onRelease` skips `awaitPopulateOverlapping` | `pw_basic` (one worker suffices, §4.2) and `pw_two_workers` | `HEAP_060` (4 ops: sync, window `{3}`; fresh 3; release 3; sync, age `{3}`) |
| `skip_posted_extents` | first-fit skips extents whose discard is Posted | `pw_basic` | `DetChoice` (4 ops: release 1; sync, age `{1}`; release 2; reuse) |
| `tm_then_promo` | a path taking `thread_mutex_` before `promo_mu_` | `lock_order` | deadlock |
| `worker_takes_tm` | a job body calls into the allocator | `lock_order` | deadlock |
| `collector_takes_tm` (to add) | a 7c collector member takes `thread_mutex_` (e.g. a grant refill through `acquireOldGenBlock`) while the mutator holds it in `tenureTeardown` → `stopAndJoin` (§2.4) | `lock_order` + a process `Collector` and a mutator step "hold `tm`, await the collector's end" | deadlock |
| `age_stale_entry` (to add) | the aging loop drops the `pending_.find` / `seq` check and posts a cancelled extent's stale `pending_order_` entry | `pw_basic` + a ghost `stale[x]` (set at cancel, cleared at the next sync step) that the mutant's aging choice may include | `NoOwnedPosted` (at `M_Post`, before any worker runs) |

Every mutant cfg lists only its target (plus `CHECK_DEADLOCK TRUE` for M7b), and nothing else can
stop TLC first: no mutant makes another M7a invariant fail before its target (checked by hand for
the three M7a mutants), M7a has no `assert` left, and no operator is applied outside its domain.

"Decommit delay counted in pause ends" and the first draft's `discard_before_age` are not mutants:
they change *when* discards are posted, and the model's aging is already a free choice, so every
posting time is explored in the base configurations (the reuse wait covers every timing). Plan 03
rejected the pause-end delay on cost.

## 6. Configurations

| Config | Module | Key constants | Expected |
|---|---|---|---|
| `pw_basic` | M7a | 3 extents (`{1,2}` owned, `{3}` fresh), 2 slots, 1 worker, `MaxOps = 5` | pass |
| `pw_two_workers` | M7a | as `pw_basic`, 2 workers | pass |
| `lock_order` | M7b | `Members = {"mut","g1"}`, `CHECK_DEADLOCK TRUE`, `PROPERTY AllFinish` | pass |
| `lock_order_stall` | M7b | as `lock_order`, `INVARIANT MODEL_M7_StallWitness` | **violates** `MODEL_M7_StallWitness` (the witness) |
| `pw_deep` | M7a (deep) | 4 extents, 3 slots, 2 workers, `MaxOps = 7` | pass |
| mutants | as §5, `MaxOps = 4` | | fail as listed |

Every M7a cfg sets `defaultInitValue = defaultInitValue` and `CHECK_DEADLOCK FALSE`. The M7a pass
configs check `HEAP_059`, `HEAP_060`, `V1`, `NoOwnedPosted`, `TrackedInFree`, `DetChoice` and the
property `MutatorFinishes`, and use no symmetry set (liveness is checked). The first draft's
`pw_default_delay` is gone with `DelayMajors`. The state counts are unmeasured: the free aging and
window choices branch at most 2^3 ways per sync point at this scale, so `pw_basic` should stay well
inside the quick budget. If `pw_two_workers` does not, run it at `MaxOps = 4`, which still reaches
every mutant.

## 7. Accuracy notes (rules A1–A9)

| Rule | M7 |
|---|---|
| A1 | PageWork calls are serialised by `thread_mutex_`, so each call body is one step, split only where it **waits**: a wait is where a worker can interleave, and the model puts a label there (`M_RelWait`, `M_Reuse` → `AS_Wait`, `TS_Wait`). The reuse is split between the choice and `onReuse` to state V2's exception honestly. The sync point's first step is `reapDone` plus the aging choice (`syncPoint` 237-261 has no wait before `takeSlot`); the first draft had no `reapDone` there, so Done slots stayed unreaped across a sync point that posted nothing, which the code never does and a trace would show. One `madvise` per extent is one worker step. A worker's dequeue and its Done store are one step each (both under the pool's `m_`). |
| A2 | Extents are the unit (both the madvise unit and the free-list unit). No sub-extent sharing. |
| A3 | Footprint: 07 plan T10 (helper jobs never target a granted block), plan 03 P§3.6-3.7, HEAP_058 (workers take no allocator lock), V1–V3. Census (2026-09-28): `PageWork.{hpp,cpp}` have no atomics or locks of their own; the only shared atomic is `HelperJob::state` (acquire loads in `isIdle`/`isDone`, the post CAS, the worker's stores under `m_`). Plain shared data (`old_gen_free_blocks_`, `old_gen_committed`, `pending_`, `posted_discard_`, `pending_order_`, `window_end_`, the slots' `kind`/`extents`/`lo`/`hi`) is written only under `thread_mutex_`; a worker reads only its own job's fields, written before `post`. `promo_mu_` (`SpinMutex`, `OldGenSpace.hpp:765`), `thread_mutex_` (`Allocator.hpp:407`), the pool's `m_` are the locks in the chain (§2.4). |
| A4 | One message-passing assumption, not the pool mutex alone. `HelperJob::state = Done` is stored with release inside `m_` (`GCHelperPool::workerLoop`, `GCHelperPool.cpp:219`), but `GCHelperPool::wait`'s fast path (`:238`) and `HelperJob::isDone` (`GCHelperPool.hpp:57`) load it with acquire **without** the mutex. The job's outputs (the discard or populate, and its `failures` field) reach the waiter through that release/acquire pair alone. It is checked by the W plan's proposed pool-job driver (`w_pool_done`), not by M7. The rest of each handoff is the pool mutex (M6's PoolJob contract). |
| A5 | `gc-helper-tsan` `harness.cpp` H2 (PageWork over fake ops, with a lock standing in for `thread_mutex_`; the fake discard already checks "the extent is free before and after a yield") and H3 (real `mmap`, per-page patterns). §8. |
| A6 | §5. |
| A7 | Invariants `HEAP_059`, `HEAP_060`, `V1`; `NoOwnedPosted` = V2b, `TrackedInFree` = V2a, `DetChoice` = GC_DET_001 (the extent choice only); `MODEL_M7_StallWitness`; HEAP_058 via M7b's deadlock check. V3 (populate bounds, addresses), V4 (poison on resident reuse), V5 (drained at reset) and V6 (mode 0 inert) are runtime-only and outside the model. |
| A8 | 3–4 extents, 2–3 slots, 1–2 workers, 4–7 caller operations. No counter wraps: the epochs are gone from the model (aging is a free choice). |
| A9 | `file`: `PageWork.cpp`, `PageWork.hpp`. `region`: `Allocator::acquireOldGenBlock`, `releaseOldGenBlock`, `acquireOldGenRegion`, `onGCPauseEnd`, `rebuildPageWork`, `cleanupThread`, `finishTenureForExit`; `OldGenSpace::ensureBagPageAvailable`, `startVirginBlockShared`, `allocateFromBagPage`'s acquire, `allocatePromotion`'s lock sections, `lazySweep`'s two completion paths (CR-014); `NurserySpace::tenureTeardown`, `runJobParallel`; `GCHelperPool::wait`, `workerLoop`. `census`: `Allocator.cpp`, `GCHelperPool.cpp`, `MinorWork.hpp` (`SpinMutex`). `grep`: `promo_mu_`, `thread_mutex_`, `acquireOldGenBlock(`, `releaseOldGenBlock(`, `stopAndJoin(`. |

## 8. Trace validation

- **Harness:** `test/gc-helper-tsan/harness.cpp` (`script`, 166-243).
  - H2 already drives PageWork from a random script under a lock, with fake page ops. Log from the
    script and the fake ops.
  - H3 uses real `mmap`/`madvise`, and its per-page patterns detect a discard under an owner
    directly. Its log is the same.
  - Both age by **syncs and the cap** (`cfg.delay = 2`, `cfg.pending_cap = 16` extents, the
    4-argument `syncPoint`, so `major_epoch` never moves). The first draft's majors-only aging
    could not have accepted these traces; the free aging choice does, with the `sync` event
    pinning the batch. Their windows are 4 extents (`ahead = 4 * kExt`), which the free window
    choice also accepts.
- **Events:**

  | Event | Where | Fields |
  |---|---|---|
  | `release` | `onRelease` | extent, waited slots |
  | `reuse` | `onReuse` | extent, result (`Cancelled`/`AfterDiscard`/`NeverDiscarded`) |
  | `fresh` | `onFreshBump` | extent, bytes to commit |
  | `sync` | `syncPoint` | epoch, major epoch, aged extents |
  | `post` | `postDiscardBatch`, `topUpWindow` | slot, kind, extents / range |
  | `body` | the fake `discard` / `populate` ops | slot, extent |
  | `done`, `reap` | worker completion, `reap` | slot |

- **Ordering:** every mutator event happens under the script's lock, so the mutator's log order is
  total. A `body` event is **not** ordered by the pool mutex: `runJob` runs outside `m_`
  (`GCHelperPool.cpp:216`). Stamp every event from one process-wide atomic counter
  (`fetch_add`, seq_cst): in the fake op at its first state check (the model's `W_Body` step), and
  in the script right at `w.state[k].store(InUse)` / `store(Free)` (the model's `M_Touch` /
  `M_RelPend`). `done` is stamped under `m_` in `workerLoop` (219).
- **The trace spec** matches `release`/`reuse`/`sync`/`post` to the caller's branches and `body`
  to `W_Body`. A `body` on an extent the trace shows as owned is rejected by `HEAP_059`, which is
  exactly H3's pattern check, stated formally.

## 9. Implementation steps

1. Create `test/tla/M7-pagework/` with both modules (§4.6), `MC.tla`, the §6 configurations,
   MAPPING.md (§4.5 plus A3) and AUDIT.md.
2. `pcal` + `sany`, then TLC on `pw_basic`, `pw_two_workers`, `lock_order`, `lock_order_stall`.
3. Run each §5 mutant; confirm the named failure.
4. Deep configuration.
5. Wire into `models.txt` / `manifest.txt` (A9).
6. Register: CR-007. Once `lock_order` passes, both lock mutants deadlock and `lock_order_stall`
   reaches the witness, the **deadlock** hypothesis is Not-a-bug (stall, not deadlock). The stall
   itself and its misattribution to "outside a pause" stay open: split CR-007 (register rule
   "split an entry when its parts need different fixes") rather than closing it. Whether the stall
   matters is measurement, "GC-pressure stress with `gc_thread_mode = 2`" (CR-006 adds that arm to
   `gc-heap-tsan`). Add CR-014's release route (§2.4) to CR-007's Where.
7. Trace validation (§8) on H2, then H3.

## 10. Open questions

1. **Several heaps, one PageWork: CR-012 is deliberately outside M7.** M7a models one heap: one
   caller at a time, one free list, one set of clocks. What M7 does not see, all needing more than
   one mutator (only `main.cpp`'s `program_threads` today):
   - triggers reading `old_gen_in_use_bytes_` without `thread_mutex_` (CR-012's data race);
   - `validatePageWork` (`Allocator.cpp:1281-1289`, validate builds) reading **every** heap's
     `blocks_` and `unassigned_blocks_` under `thread_mutex_` only, while the other heaps' mutators
     change them without it: the same race class;
   - `acquireOldGenRegion` re-mapping part of the window (§2.3's last row);
   - per-heap GC_DET_001: the process-wide epochs age one heap's releases by another heap's
     pauses, and the shared free list makes which extent a heap gets depend on the other heaps.
     The clocks cannot break HEAP_059 or HEAP_060: M7a's aging is already a free choice, so any
     clock is covered. Only determinism is at stake.

   If multiple mutators are ever supported, M7a needs an explicit `thread_mutex_` and a second
   caller, and `DetChoice` must be restated per heap given the interleaving of the heaps.
2. **Can `releaseOldGenBlock` run under `promo_mu_` on a gang thread? Yes (audit finished
   2026-09-28).** The callers are `releaseBlockToAllocator` (`OldGenSpace.cpp:5995`, which asserts
   `!cycleActive()`) and `releaseUnassignedBlockToAllocator` (6135), reached from
   `maybeShrinkCapacity`. `lazySweep`'s in-loop completion defers the shrink inside a parallel
   minor (`sweepCompleteInPromotion`, 1361; with one worker it runs the shrink at once, but then
   no other member can stall), but its **tail** completion (5466-5476) calls `onSweepComplete`
   unconditionally. That is CR-014, and `lazySweep` runs under `promo_mu_` from
   `sweepOnDemandAllocate` (2136), `allocateFromBagPage` (2410) and
   `panicSweepAndRetryAllocation` (2164) in `ladderFrom2W`.
   So a gang thread can wait on a populate while holding `promo_mu_` and `thread_mutex_`. M7b
   needs no new step: its member's wait is on a generic job (§4.1). Fixing CR-014 as proposed
   (route the tail through the `par_promo_active_` check) removes this route.

## 11. Adversarial review (2026-09-28)

Against the current tree. Severity: **Blocker** (a wrong verdict, or the model cannot catch its
bug), **Major** (a hidden bug class, a likely false alarm or blow-up), **Minor** (drift, wording).

| Id | Sev | Finding | Change |
|---|---|---|---|
| R1 | Blocker | The abstraction table said `delay_syncs`/`pending_cap` were over-approximated by "the aging choice", but aging was deterministic (majors only). The H2/H3 harness, the §8 trace target, ages by syncs and the cap and never moves `major_epoch`, so trace validation would have rejected every H2/H3 trace that posts a discard | aging is now any subset of the Pending extents; `majors`, `pendMajor`, `DelayMajors`, `MaxMajors`, `pw_default_delay` removed (§2.1, §4.2, §8) |
| R2 | Major | The window was deterministic ("every fresh extent not yet covered"), so an extent could never sit in two populates and `M_RelWait`'s loop was dead; the harness windows are 4 extents | the window is any subset of the fresh extents; `covered` removed |
| R3 | Major | The mutant targets were `assert`s with no name (A7; the runner matches names) | `HEAP_059`, `HEAP_060`, `V1` are named invariants (§4.7) |
| R4 | Major | M7b could pass vacuously: nothing showed CR-007's stall is reachable | `MODEL_M7_StallWitness` and config `lock_order_stall` (expected: violated) |
| R5 | Major | Open question 2 had an answer: CR-014's `lazySweep` tail path releases under `promo_mu_` on a gang thread, so a gang thread can wait on a populate holding both locks | §2.4, §10 Q2; M7b's job is generic, no new step |
| R6 | Major | Premise: "every PageWork call runs on the mutator"; "the 7c tenure collector never enters this chain". Gang threads call `onReuse` (CR-007), and the pause tenure engine (`runJobParallel`, `NurseryTenure.cpp:1168`) promotes through `allocatePromotion` on `GCMarkGang` members | §2.1, §2.4, §4.2 corrected; only the concurrent collector stays out |
| R7 | Major | A wait-for edge the lock model lacks: `tenureTeardown` → `collector->stopAndJoin()` under `thread_mutex_` (`cleanupThread`, `finishTenureForExit`, `reset`) | §2.4 lock census; mutant `collector_takes_tm` (to add) |
| R8 | Major | Bug class not expressible: the lazy deletion in `pending_order_` (stale entries of cancelled extents skipped by `seq`) | mutant `age_stale_entry` (to add), with the smallest model change |
| R9 | Major | The sync point had no `reapDone` step (`syncPoint` 237) | `ReapAllDone()` in the sync step |
| R10 | Minor | §2.3 said two workers are needed for the populate/discard race; the model's workers take any Posted job, so one suffices | text; mutant now also runs on `pw_basic` |
| R11 | Minor | Dead or stale state: `content` never read, M7b's `m` always `"none"`, `postedIn`/`pendMajor` stale after reap/cancel | removed / reset at reap |
| R12 | Minor | M7b's deadlock verdict relied on TLC's default; configs must not inherit M7a's `CHECK_DEADLOCK FALSE`; `defaultInitValue` was not mentioned | §4.7, §6 |
| R13 | Minor | §8 ordering: `body` events run outside the pool mutex, so "M6's per-mutex counter" cannot order them | a process-wide atomic stamp (§8) |
| R14 | Minor | The contract is M6a's pool half, not LaunchJoin (parent §5.0 names LaunchJoin for M7) | header |
| R15 | Minor | CR-012 scope was implicit; `validatePageWork` reading other heaps' `blocks_` and `acquireOldGenRegion` re-mapping the window were unlisted | §10 Q1 says outside M7 and lists them; §2.3 table |
| R16 | Minor | Line drift: V1 795, V4 808, `acquireOldGenBlock` ends 885, `validatePageWork` ends 1316, `allocatePromotion` 1536-1646 | §3, §4.5 |
| R18 | Major | (From the W review.) The A4 row said "None; every handoff is the pool mutex", but `wait()`'s fast path and `isDone()` read `Done` with acquire outside `m_`, so the job's outputs travel by that release/acquire pair alone | A4 row rewritten; the check belongs to the W plan's proposed `w_pool_done` driver |
| R17 | — | Checked and right: the S1 argument (every reuse funnels through `onReuse`, §2.5); the three M7a mutants reach their targets within 3–4 operations; no base invariant is violated by hand simulation; the lock graph is acyclic today | §2.5 added |

The revised sketches (§4.6) pass `pcal -nocfg` and SANY with no errors (tla2tools 1.8.0). TLC and
Apalache were not run.

