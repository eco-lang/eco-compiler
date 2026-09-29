# M6 — helper pool, gangs, fork and exit: model ↔ code

Two modules, sharing no variables (the pool's atfork prepare runs last and takes no gang lock):
- `HelperPool.tla` (M6a): `GCHelperPool`'s jobs, `post` / worker / `wait`, the pool's atfork
  handlers, `Allocator::thread_mutex_`, the mutator's posts and waits, a thread that forks.
- `Gangs.tla` (M6b): `GCBackgroundGang` (5c markers, and the 7c tenure collector as an optional
  second gang), `GCMarkGang::run`'s `run_m_`, the 5c episode driver in `OldGenSpace`, 7c's
  `tenureJoin`, the gangs' atfork handlers in either registration order, and `stopAllAtExit`.

The plan is `plans/threaded-gc-tla-M6-lifecycle.md`. **This file cites code, never plan text**
(parent plan §12, trap 1).

Line numbers are a snapshot of the tree of 2026-09-28 23:40 (post-7c), taken after the first
compiled-out `ECO_TLA_TRACE` hooks landed. The trace work went on adding hooks overnight (by
2026-09-29 02:30, `OldGenSpace.cpp` had moved about 80 more lines, `PageWork.cpp` about 20 to 40,
`GCHelperPool.cpp` 1). **The function names are the anchors**; the hooks change no modelled step
(checked 2026-09-29: only `ECO_TLA_TRACE` / `ECO_TLA_TRACE_ONLY` lines were added). Refresh the
numbers when the canary pins these regions. `GHP` = `runtime/src/allocator/GCHelperPool.cpp`, `OGS` = `OldGenSpace.cpp`,
`NT` = `NurseryTenure.cpp`, `A` = `Allocator.cpp`, `PW` = `PageWork.cpp`, `TLH` =
`ThreadLocalHeap.cpp`.

## 1. Variables

### M6a (`HelperPool.tla`)

| Variable | Meaning | Code counterpart |
|---|---|---|
| `world` | `"parent"`, or `"child"` after the fork step takes the child branch | the address space |
| `m` | holder of the pool mutex | `GCHelperPool::m_` |
| `tm` | holder of the allocator mutex | `Allocator::thread_mutex_` (a `recursive_mutex`, no atfork handler) |
| `queue`, `outstanding`, `started` | the FIFO, the count, the lazy start flag | `head_`/`tail_`/`HelperJob::next`, `outstanding_`, `started_` (all under `m_`) |
| `spawned` | ghost: this address space's worker threads exist | `workers_` (the child abandons the parent's) |
| `jstate[x]` | `Idle → Posted → Running → Done`, back to `Idle` on reuse | `HelperJob::state` |
| `doneWaiters` | threads blocked in the condition wait | `cv_done_`'s waiters |
| `runs[x]` | ghost: runs of job `x` since its last post | — (`PoolRunOnce`) |
| `j`, `hj`, `wj`, `cur`, `ccur` | the job a thread is working on | `PageWork` slot; `wait`'s argument; the worker's `job` |

### M6b (`Gangs.tla`)

| Variable | Meaning | Code counterpart |
|---|---|---|
| `world` | parent or child | the address space |
| `reg` | holder of the gang registry mutex | `bgRegistryMutex()` (GHP:499) |
| `runM` | holder of the mark gang's run mutex | `GCMarkGang::run_m_` |
| `bm[g]` | holder of gang `g`'s mutex | `GCBackgroundGang::m_` |
| `running[g]` | launched and not yet joined | `running_` (atomic) |
| `gen[g]`, `finished[g]` | generation, members finished | `generation_`, `finished_` (and `finished_pub_`, the same value published) |
| `joinedGen[g]` | ghost: the generation the last join returned for | — (`LJ_RunningExact`) |
| `ctl[g]` | the job's control: `stop`, `done` | 5c: `bg_ctl_` (`SliceControl`, a fresh one per launch); 7c: `J.stop` / `tenure_ctl_` and the job's `done` |
| `work[g]` | entries in the deques (5c) or items left (7c) | the markers' deques; the tenure job's work list |
| `held[p]` | entries in participant `p`'s ring | a marker's private stack and ring (M2's `priv`) |
| `bgEp` | the episode state | `OldGenSpace::bg_ep_` (mutator-owned) |
| `fgGo` | the closing run started member 1, which has not finished | `GCMarkGang::generation_` / `finished_` for n = 2 |
| `exited` | `stopAllAtExit` returned on the mutator's `exit()` | — |
| `sgen` | ghost: the generation a `stopAndJoin` stopped | — (`StopWaitsOwnEpisode`, CR-023) |
| `seen`, `cseen` | the member's last generation | `memberLoop`'s `seen` |

Gang ids: `"cm"` = the 5c gang (`OldGenSpace::bg_`, eco-cmark), `"tn"` = the 7c collector
(`RegionState::collector`, eco-tenure). Processes: `mut` (the heap's mutator), `host` (another
thread), `bg1`/`bg2` and `tb1` (parent members), `fg1` (the mark gang's member 1), and `cbg*`,
`ctb1`, `cfg1` (members a mutator's child restarts).

## 2. Steps (A1: one label = one atomic step of the code)

### M6a

| Label | Code | Why one step |
|---|---|---|
| `M_Choose` (post) | the caller takes `thread_mutex_` (A:753 `acquireOldGenBlock`, A:892 `releaseOldGenBlock`, A:1253 `onGCPauseEnd`) and picks an Idle slot (`PageWork::takeSlot`, PW:113) | lock acquisition; the slot choice is owner-only PageWork state |
| `M_PostCas` | `GCHelperPool::post`: CAS Idle → Posted (GHP:155), **outside `m_`** | one CAS. With `FIX` post-under-lock, the CAS moves into the next step |
| `M_PostQ` | `post`'s `m_` section: start the workers (GHP:172), enqueue, `++outstanding_` (GHP:171-177) | one critical section |
| `M_PostDone` | `cv_work_.notify_one` (GHP:178); the caller releases `thread_mutex_` | the notify needs no step of its own: nobody checks `cv_work_`'s predicate outside `m_` |
| `M_Choose` (wait), `M_Wait` | `PageWork::awaitSlot` (PW:103), from `takeSlot`'s wait for the oldest slot, `onReuse` or `drainAll` (PW:268) | lock acquisition, then the call |
| `WR_Load` | `wait`'s fast path `state.load(acquire)` (GHP:239), or `HelperJob::isDone` (hpp:57) from `PageWork::reapDone` (PW:97) | one acquire load |
| `WR_Lock`, `WR_Block`, `WR_Blocked` | `cv_done_.wait(lk, state == Done)` (GHP:244-247): lock and check; join the waiters and unlock; wake, re-lock, re-check | the waiter holds `m` from its check to its block, so a writer that skips `m_` (mutant `lost_wakeup`) lands exactly where it can in the code |
| `WR_Reap` | `PageWork::reap` (PW:76) → `HelperJob::resetForReuse` (GHP:59) | owner-only; `WaitSeesDone` is evaluated here |
| `M_WaitDone` | the caller releases `thread_mutex_` | |
| `M_Choose` (fork) | the mutator forks between pauses (`eco-kernel-cpp/src/eco/Process.cpp:70, 124`) | |
| `F_Tm` | (`FIX` `tm_first`, `all`) a proposed `thread_mutex_` atfork prepare that runs before the pool's | one lock acquisition |
| `F_Drain` | `GCHelperPool::atforkPrepare` (GHP:261) → `drain()` (GHP:255): `cv_done_.wait(outstanding_ == 0)` | one critical section (every writer of `outstanding_` holds `m_`). With a drain fix it keeps `m_` |
| `F_Lock` | `atforkPrepare`'s `m_.lock()` (GHP:265) | lock acquisition: **the CR-003 window is between `F_Drain` and `F_Lock`** |
| `F_TmLast` | (`FIX` `tm_last`) the same handler, run after the pool's | |
| `F_Fork` | `atforkParent` (GHP:268) or `atforkChild` (GHP:272-288: re-create `m_`/condvars, forget workers, empty queue, `outstanding_ = 0`, `started_ = false`) | `fork()` with its handlers is atomic for the other threads |
| `W_Take` | `workerLoop`'s first `m_` section (GHP:205-216): wait for work, dequeue, the not-Posted abort (GHP:213), `Running` | one critical section |
| `W_Run` | `runJob` (GHP:217) | the body, no lock |
| `W_Done` | `workerLoop`'s second `m_` section (GHP:219-222): `Done` (release, GHP:220), `--outstanding_` | see §3, `W_Done` |
| `W_Notify` | `cv_done_.notify_all()` outside the lock (GHP:223) | a separate step, so a notify can reach nobody |
| `C_Take`, `C_Done`, `C_Notify` | the same `workerLoop`, on workers the child starts at its first post | |
| `H_Fork` | another thread's `fork()`: an embedding host, or a second heap's mutator (`Process.cpp`) | |
| `H_Tm`, `H_Pick`, `H_Wait`, `H_Unlock` | the host child's first allocator call, or its `exit()`: `~Allocator` (A:218-224) locks `thread_mutex_` and runs `drainAll` | |
| `H_Child` (with `GUARD`) | the step-7 guard: a use of a heap the forking thread does not own aborts | proposed, not in the code |

### M6b

| Label | Code | Why one step |
|---|---|---|
| `K_Step`, `K_Again` (`Mark`) | the job body: `bgEntry` (OGS:4417) → `runMarkerLoop` (`MarkWork.hpp`), `closingEntry` (OGS:4437), the tenure engines (`tenureEntry`, `tenureConcEntry`, NT) | M2's Drain contract (§3) |
| `L_Lock` (`Launch`) | 5c: `launchBackground` (OGS:4444-4484): fresh `bg_ctl_` (OGS:4472), `bg_ep_ = Running` (OGS:4479), then `GCBackgroundGang::launch` (GHP:614-631: the already-running abort, start threads, `finished_ = 0`, `++generation_`, `running_ = true` inside `m_`, GHP:627). 7c: `tenureLaunch` (NT:428-573, launch NT:572) or `tenureConcLaunch` (NT:1222, launch NT:1234) | the mutator-owned writes before the lock are invisible to members (§3); then one critical section |
| `L_Late` | mutant `running_after_notify` only | |
| `J_Lock`, `J_Wait` (`Join`) | `join` (GHP:651-655): under `m_`, return if `!running_`; `joinLocked` (GHP:639-649): `cv_done_.wait(finished_ >= members)`, `running_ = false` (GHP:644) | check-under-lock, then the wait's wake-up (§3: no waiter set) |
| `SJ_Lock`, `SJ_Wait` (`StopAndJoin`) | `stopAndJoin` (GHP:657-662): under `m_`, return if `!running_`; `stop_->store(true)` (GHP:660); `joinLocked` | as `Join` |
| `RP_Check`, `RP_Hint`, `RP_Join`, `RP_Set` (`Reap`) | `reapBackground` (OGS:4519-4541): the hint `running() && !finishedApprox()` (OGS:4524), `join`, then `bg_ep_` = Finished or None | `RP_Hint` merges two acquire loads (§3) |
| `G_Mark1` / `G_RunM` | `GCMarkGang::atforkPrepare` (GHP:468): `run_m_.lock()`, then its `m_` (not modelled, §3); first (`mark_first`) or last (`bg_first`) | lock acquisition |
| `G_Reg` | `GCBackgroundGang::atforkPrepare` (GHP:684): `bgRegistryMutex().lock()` | lock acquisition |
| `G_Stop1`, `G_Stop2` | `stopAllForFork` (GHP:669-677): per registered gang, `if (g->running()) g->stopAndJoin()` | one acquire load of `running_`, then the call |
| `G_Lock1`, `G_Lock2` | then `g->m_.lock()` for every gang (GHP:688): **the CR-004 / CR-013 window is between `G_Stop*` and `G_Lock*`** | one lock acquisition per gang |
| `G_Fork` | parent: `atforkParent` (GHP:476, GHP:691); child: `atforkChild` (GHP:482, GHP:696: re-create the mutexes, forget threads, `finished_ = 0`, `running_ = false`, re-create the registry mutex) | |
| `X_Reg`, `X_Stop1`, `X_Stop2`, `X_Done` | `stopAllAtExit` (GHP:679-682), registered with `std::atexit` by the first gang's constructor (GHP:521), run by the mutator's `exit()` (`Process.cpp:231`) | |
| `U_Launch`, `U_Launch2` | the t0 pause: `afterSnapshot` → `launchBackground` (OGS:4669); the pause's end: `tenureLaunch` (TLH:743) | |
| `U_MaybeFork` | between pauses: the mutator forks, calls `exit()`, or neither | |
| `U_Tenure`, `U_TFinish` | minor start: `tenureJoin` (NT:575-667, called TLH:728/734), `tenure_help = 1`: orphan test `!running()` (NT:614-615), `finishedApprox` → `join`, else `stopAndJoin`; finish the job here if not done (NT:631) | one acquire load, then the call |
| `U_Reap`, `U_Relaunch` | minor end: `runCycleStepConcurrent` (OGS:4677): `reapBackground(false)` (OGS:4705), relaunch a stopped episode with work left (OGS:4706-4712), or `bg_ep_ = Finished` | mutator-owned state plus the reap |
| `U_Next` | `cycle_k_ >= cycle_slices_` → the closing (OGS:4722); otherwise `tenureLaunch` at the pause's end (TLH:743) | |
| `U_Close` … `U_Assert` | `closingFinish` (OGS:4585-4652): `reapBackground(false)` (OGS:4590); if Running, `GCMarkGang::run(closingEntry, mark_threads_)` (OGS:4603); `reapBackground(true)` (OGS:4614); `assert(bg_ep_ == Finished)` (OGS:4615) | |
| `U_RunLock`, `U_FgWait` | `GCMarkGang::run` (GHP:413-440): with n = 2, `run_m_` (GHP:418), start member 1, `fn(ctx, 0)` on the caller, `cv_done_.wait(finished_ == n - 1)` (GHP:438); with n ≤ 1 (`MarkThreads = 1`), `fn(ctx, 0)` inline, no lock (GHP:414-417) | |
| `U_Drain` | `closingFinish`'s drain of a stopped episode's leftovers, `runMarkers` (OGS:4617-4620) | §3 |
| `U_Handoff` | the handoff (`handoffMarkCycle`, OGS:4271, after `cycle_state_ = HandoffDue`) | `HandoffClean` is evaluated here |
| `B_Wait`, `B_Run`, `B_Fin` | `GCBackgroundGang::memberLoop` (GHP:553-612): `cv_start_.wait(generation_ != seen)` (GHP:588); `fn`; under `m_` `++finished_`, `finished_pub_` (GHP:608), `notify_all` | two critical sections around the body |
| `FG_Wait`, `FG_Run`, `FG_Fin` | `GCMarkGang::memberLoop` (GHP:358-411): wait (GHP:380), `fn`, `++finished_ == n - 1` → notify (GHP:408) | |
| `CB_*`, `CF_*` | the same member loops, on threads a mutator's child starts at its first launch or run (`startThreadsLocked`) | |
| `H_Act` | another thread's `fork()` | |

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| a pool of 1..64 workers | 1 worker (quick), 2 (deep); the same in the child | one worker shows every window; two add reorderings only (deep, all pass) |
| job bodies (`madvise`) | `skip` | M6 checks the lifecycle; M7 checks the effects |
| `PageWork`'s slots and its choice of slot | `Jobs = {j1, j2}`; post any Idle job, wait on any non-Idle job | over-approximates `takeSlot` (oldest first), `reapDone`, `onReuse`, `drainAll` |
| every thread that posts or waits | one `Mutator` holding `tm` | every post and wait is under `thread_mutex_` (HEAP_058), which serialises them; the pool does not look at the caller. That includes a `GCMarkGang` member allocating a block inside a pause |
| `W_Done`: the `Done` store and `--outstanding_` | one step | both are in one `m_` section; the only reader outside `m_` (the fast path) reads the state alone, and after `Done` the worker touches no job field (GHP:219-222) |
| Sync mode, `configured_`, `stopping_`, `shutdownForTesting` | not modelled | Sync runs inline at `post`; `configured_` is set before any post; the others are test-only |
| `reapBackground`'s hint: `running()` then `finishedApprox()` | one step `RP_Hint` | between launches `running_` only falls and `finished_pub_` only rises, so every outcome of the split loads (return, or join) is an outcome of the merged one |
| `launchBackground`'s writes before `launch` (`bg_ctl_` replaced, `bg_ep_ = Running`) | inside `L_Lock` | `bg_ep_` is mutator-owned; no member can read the old control (it was joined), and `stopAndJoin` checks `running_` under `m_` before it touches `stop_` |
| the marker loop, the tenure engines | procedure `Mark`: take an entry into the ring, scan it; on stop, scan the ring and leave; done iff no work anywhere | M2's **Drain** contract (parent plan §5.0), assumed. M5 owns the tenure engines' version |
| `SliceControl`, the tenure job's control | `ctl[g] = [stop, done]`, replaced at each launch | each launch creates a fresh control |
| the background gang's `cv_done_` waiters (the owner's `join`, a foreign `stopAndJoin`) | `await finished >= members` (no waiter set) | the code notifies all under `m_` (GHP:609). A `notify_one` regression would lose one of two waiters and **cannot be seen here** (plan §5) |
| the mark gang's `m_`, `generation_`, `running_n_`, `finished_` | `fgGo`, `runM` | n is fixed; only `run_m_` interacts with fork: prepare takes `run_m_` first, so it holds the mark gang's `m_` only while no run is in progress |
| gang construction (`GCBackgroundGang` constructor takes the registry mutex, GHP:514) | not modelled: every gang is registered from the start | before a gang's first launch the model lets a launch land where the code's constructor would block on the registry. That adds behaviours (sound for the pass rows). The windows TLC shows through a first launch exist for any later cycle's t0 launch, which needs no constructor |
| paced assists (`assistEpisode`, OGS:4549), `runMarkers`' drain, the tenure help runs | not modelled as runs (the drain is one step `U_Drain`) | each is a `GCMarkGang::run` inside a pause that ends on its own (a budget, a drain, or a stop) and takes no background-gang or registry lock inside `run_m_`. For fork they only add intervals where `run_m_` is held, which the closing run already has. With one CPU they run inline (no `run_m_`), as `MarkThreads = 1` models for the closing |
| two gangs (5c markers, 7c collector) | `TwoGangs`: registry order `[tn, cm]` | the collector is built at the first region minor, the 5c gang at the first concurrent t0; `stopAllForFork` loops over instances |
| B background members | B = 1 (quick), 2 (deep) | stop / join / finished semantics are per member |
| `exit()` | the mutator only, between pauses (`ExitGangs`); it does not return | the supported callers (the Elm thread's `exit`, or `main` after `pthread_join` when no mutator is left). A foreign `exit()` while a mutator runs is out of scope |
| the exit major (`atexitPrintStats`, `ECO_GC_EXIT_MAJOR`), `~Allocator`, `~OldGenSpace`, `tenureTeardown` | not modelled | they run after `stopAllAtExit`; `closingFinish` then takes its drain path and never relaunches |
| `OldGenSpace::reset`, `stopBackground` | not modelled | test paths: the mutator's own `stopAndJoin` before teardown (05c H13) |
| the relaunch bound | none | generations are bounded by the run (one t0 launch, one relaunch per stop, one fork or exit; the 7c job once per minor) |
| memory orders | SC | §6 (A4) |

## 4. Footprint (A3)

Census of `GCHelperPool.hpp`/`.cpp` (2026-09-28). Every shared location has a variable or a
written abstraction:

| Location | Model |
|---|---|
| pool: `m_`, `cv_work_`, `cv_done_`, `head_`/`tail_`/`next`, `outstanding_`, `started_`, `HelperJob::state` | `m`, `await`, `doneWaiters`, `queue`, `outstanding`, `started`, `jstate` |
| pool: `configured_`, `mode_`, `threads_`, `workers_` | set once before any post; `workers_` → `spawned` |
| pool: `stopping_`, `shutdownForTesting`, `stats_` | test-only; statistics (relaxed, never read by a decision) |
| mark gang: `run_m_`, `m_`, `cv_start_`, `cv_done_`, `generation_`, `running_n_`, `finished_`, `fn_`/`ctx_` | `runM`, `fgGo` (n fixed) |
| background gang: `m_`, `cv_start_`, `cv_done_`, `generation_`, `finished_`, `finished_pub_`, `running_`, `started_`, `stop_`, `fn_`/`ctx_` | `bm`, `gen`, `finished`, `running`, `ctl.stop`; `started_` as the child members' `running` guard |
| background gang: `stopping_`, `tids_`, `stats_` | destruction; test-only; statistics |
| registry: `bgRegistryMutex()`, `bgRegistry()`, `bg_hooks_registered` | `reg`; the registry is fixed (`R1`, `R2`) |
| `Allocator::thread_mutex_` (HEAP_058) | `tm` |
| `OldGenSpace::bg_ep_`, `bg_ctl_` | `bgEp`, `ctl["cm"]` |
| 7c: `R.collector`, `J.state`, `J.stop`, `tenure_ctl_` | the gang `"tn"`, `ctl["tn"]` |

Footprint rows (`test/tla/footprint-greps.txt`):
- **H10** (05c P§3.6: slot state the mutator touches only while no member runs, IM14): rests on
  `LJ_JoinExact` and `LaunchIdle` (`assertSlotsQuiescent("launch")`, OGS:4446). The slot state
  itself is M2's.
- **H13** (`ensureMarkers`; `reset` stops the episode first): the gang objects' part is this
  census; `reset` is a test path (§3).

## 5. Properties (A7)

| Property | Module | Kind | Id | Where the code checks it |
|---|---|---|---|---|
| `PoolRunOnce` | M6a | invariant | MODEL_M6_1 (PoolJob) | the worker's not-Posted abort (GHP:213) |
| `WaitSeesDone` | M6a | invariant | MODEL_M6_2 (PoolJob) | `resetForReuse`'s abort (GHP:61) |
| `ParentJobsFinish` | M6a | liveness | MODEL_M6_3 (PoolJob) | — |
| `MutatorProgress` | M6a | liveness | MODEL_M6_4 | — |
| `ChildNoStranded` | M6a | invariant | MODEL_M6_5 (CR-003) | — |
| `ChildLocksFree` | M6a | invariant | MODEL_M6_6 (CR-015; HEAP_058) | — |
| `ChildProgress` | M6a | liveness | MODEL_M6_7 | — |
| `HostChildProgress` | M6a | liveness | MODEL_M6_8 (CR-003, CR-015 at the child's `exit()`) | — |
| `LJ_JoinExact` | M6b | invariant | MODEL_M6_9 (LaunchJoin LJ1; IM14 rests on it) | — |
| `LJ_RunningExact` | M6b | invariant | MODEL_M6_10 (LaunchJoin LJ2) | — |
| `LJ_RunJoined` | M6b | invariant | MODEL_M6_11 (LaunchJoin LJ1, `GCMarkGang::run`) | — |
| `LaunchIdle` | M6b | invariant | MODEL_M6_12 | `launch`'s `poolAbort("already running")` (GHP:617-619); IM14 `assertSlotsQuiescent("launch")` |
| `ClosingFinished` | M6b | invariant | the code's assert (CR-005) | `closingFinish` `assert(bg_ep_ == Finished)` (OGS:4615) |
| `HandoffClean` | M6b | invariant | IM15 at the handoff | `assertNoPrivateWork("closing")`, `assert(markStackEmpty())` (OGS:4625) |
| `ChildHeapSafe` | M6b | invariant | MODEL_M6_13 | — |
| `ChildHeldAny` | M6b | invariant | MODEL_M6_14 (CR-004 window) | — |
| `ChildHeldTenure` | M6b | invariant | MODEL_M6_15 (CR-013 window) | — |
| `ExitSafe` | M6b | invariant | MODEL_M6_16 | — |
| `StopWaitsOwnEpisode` | M6b | invariant | MODEL_M6_17 (CR-023) | — |
| `ParentProgress` | M6b | liveness | MODEL_M6_18 | — |
| `ChildProgress` | M6b | liveness | MODEL_M6_19 | — |

`WaitSeesDone`, `ChildNoStranded`, `LaunchIdle`, `StopWaitsOwnEpisode` and the liveness
properties are defined after the translation, because they read procedure or process locals
(`wj`, `j`, `cur`, `lg`, `sg`, `sgen`) or `pc` of named processes.

## 6. Accuracy rules (A1–A9)

| Rule | M6 |
|---|---|
| A1 | §2. Critical sections nobody observes mid-way are one step. Locks held **across** steps are holder variables: prepare holds them across the fork; `thread_mutex_` across a post or a wait; `m_` between a waiter's check and its block. `post`'s CAS is its own step (the CR-003 analysis needs it). `wait`'s fast path is its own step outside `m_`. Three merges are argued in §3: `W_Done`, `RP_Hint`, and `launchBackground`'s writes in `L_Lock` |
| A2 | job state, `running_`, `finished_pub_`, the generation: whole words. No sub-word sharing |
| A3 | §4 |
| A4 | Mutex handoffs need nothing (an unlock synchronises with the next lock). Three atomic handoffs are **assumptions**: (1) `HelperJob::state`'s `Done`, release at GHP:220 inside `m_`, read by acquire loads **outside** `m_` (GHP:239, `isDone` hpp:57): a job's outputs reach a fast-path waiter by that pair alone. **W companion `w_pool_done`: PASS** (GenMC RC11, 2026-09-28; `POOL_RELAXED_DONE`, `POOL_RELAXED_DONE_REAP`, `POOL_RELAXED_FASTPATH`, `POOL_RELAXED_ISDONE` flagged). (2) `running_`, release at GHP:627 / GHP:644, acquire in `running()` (hpp:258): `tenureJoin`'s orphan test acts on `!running()` with no join, and after a foreign `stopAndJoin` the chain is member → `m_` → joiner → `running_` → owner. **W companion `w_running_chain`: PASS**, for both `!running()` sites of `tenureJoin` (the L3 branch `NurseryTenure.cpp:584-585` and `:611-631`); `RUNNING_RELAXED_STORE`, `RUNNING_RELAXED_LOAD`, `RUNNING_JOIN_EARLY` flagged. (3) `finished_pub_` (GHP:608): a hint only; every decision goes through `join`. No W needed |
| A5 | **Done (2026-09-29).** `TracePool.tla` on `test/gc-helper-tsan/pool_trace.cpp` (`gc-pool-trace`: the real pool, a poster under a `thread_mutex_` stand-in, no fork, a host fork, a mutator fork with the parent's or the child's log); `TraceGangs.tla` on `test/gc-heap-tsan/fork_harness.cpp` (`gc-fork-trace gangs ...`: one 5c cycle of the real allocator with a host or mutator fork, both prepare orders, one and two mark threads). Events and the step each matches: the specs' headers and §9 below. Rows in `test/tla/traces.txt`; AUDIT.md 2026-09-29 |
| A6 | every invariant and liveness property has a negative control that TLC rejects with its name (AUDIT.md). One bug class is not detectable as modelled: `notify_one` on the gang's `cv_done_` |
| A7 | §5 |
| A8 | Quick: 1 worker, 2 jobs, 2–4 mutator operations; 1 background member, 2 entries, 1 fork, 1–2 minor ends. Deep: 2 workers, 5–6 operations; B = 2, two gangs, 2 minor ends, both prepare orders, one CPU. No counter wraps (the generation is 64-bit) |
| A9 | Later wave (`test/tla/manifest.txt`); the lines M6 needs are in AUDIT.md |

## 7. Contracts

- **Provides LaunchJoin** (to M1, M2, M3, M5): `LJ_JoinExact`, `LJ_RunningExact`, `LJ_RunJoined`,
  plus `LaunchIdle`. LJ3 (a member starts only for a launched generation, after the launch's
  writes) holds by construction: `gen`, `ctl`, `bgEp` and `running` change in one step, and a
  member starts only on `gen # seen`. LJ4 (a stop is honoured at the next item boundary) is the job
  body's obligation (M2, M5). "Publishes" is A4.
- **Provides PoolJob** (to M7): `PoolRunOnce`, `WaitSeesDone`, `ParentJobsFinish`. No order is
  promised (the model's FIFO is the code's, GHP:174; M7 must not rely on it). It does **not** hold
  in a child forked by a thread other than the mutator (CR-003).
- **Assumes Drain** (from M2): procedure `Mark`.

## 8. Differences from the plan's sketch (all in AUDIT.md)

- `ChildNoStranded` counts a job as stranded only if no live thread will move it on (`InFlight`):
  the sketch's "still queued" fails on a mutator's own child posting.
- `ChildHeapSafe` / `ChildHeldAny` count only dead threads' rings (`DeadHeld`): the sketch counted
  the child mutator's own ring.
- The closing step does its own reap and relaunch before `closingFinish`, as
  `runCycleStepConcurrent` does; `Steps` counts the ordinary steps before it.
- `MarkThreads = 1` (one CPU: the closing runs inline without `run_m_`), `TwoGangs` (the 7c
  collector and `tenureJoin`), `B = 2`, and `FIX` / `GUARD` for the step-7 resolutions.
- `launch`'s `assert` became the invariant `LaunchIdle`; `MaxGen` is gone; `spawned` separates
  "threads exist" from `started_`.
- New properties: `ChildProgress` (both), `HostChildProgress`, `LaunchIdle`, `ChildHeldTenure`,
  `StopWaitsOwnEpisode`; `HandoffClean` also checks the deques.

## 9. Trace validation (A5)

| Spec | Harness | Events (hooks) | Matched steps | Hidden |
|---|---|---|---|---|
| `TracePool.tla` | `gc-pool-trace` (`test/gc-helper-tsan/pool_trace.cpp`) | `pool.cas`, `pool.enq`, `pool.take`, `pool.done`, `pool.wfast`, `pool.wchk`, `pool.reset`, `pool.drained`, `pool.plock`, `pool.parent`, `pool.child` (`GCHelperPool.cpp`, M6 hooks) | `M_PostCas`, `M_PostQ`, `W_Take`/`C_Take`, `W_Done`/`C_Done`, `WR_Load`, `WR_Lock`, `WR_Reap`, `F_Drain`, `F_Lock`, `F_Fork` | the Mutator's control steps, `WR_Block`/`WR_Blocked`, the workers' loop steps, `F_Tm`/`F_TmLast`/`F_Ret`, the Host's steps, a spurious wake-up (trace spec only) |
| `TraceGangs.tla` | `gc-fork-trace gangs` (`test/gc-heap-tsan/fork_harness.cpp`) | M1's `minor`, `t0`, `t0end`, `launch`, `relaunch`, `reap`, `step`, `closing`, `handoff`, `stop`; `gang.launch/start/exit/join/run/runEnd` (shared); M6's `gang.stop`, `fork.mprep`, `fork.bgreg`, `fork.bglock`, `fork.mparent/bparent`, `fork.mchild/bchild` | `U_Launch`, `L_Lock`, `U_Relaunch`, `RP_Set`, `U_Next`, `U_RunLock`, `U_FgWait`, `U_Drain`, `U_Handoff`, `B_Wait`/`CB_Wait`, `B_Fin`/`CB_Fin`, `FG_Wait`/`CF_Wait`, `FG_Fin`/`CF_Fin`, `SJ_Lock`, `SJ_Wait`, `J_Wait`, `G_Mark1`/`G_RunM`, `G_Reg`, `G_Lock1`, `G_Fork` | the Mutator's control steps and calls, the early returns of `Reap`, `Join` (`J_Lock`) and `StopAndJoin`, the prepare's no-op steps, the marker loop (`Mark`), `H_Act` |

Thread names map to the model's processes: `mut`, `host`; pool workers `eco-gc<i>` (the child's:
those whose first event follows `pool.child`); `eco-cmark0` = `bg1` (the child's = `cbg1`),
`eco-mark1` = `fg1` (`cfg1`), told apart by the gang key in the header (`bgkey`, `fgkey`).

The fork harness's deterministic guards use M6's probe hooks as pause points:
`m6.post.cas` (post, after its CAS: CR-015 and CR-003's CAS window), `m6.pool.drained` (the pool's
prepare between `drain()` and `m_.lock()`: CR-003), `m6.closing` (`closingFinish` with the episode
running: CR-005), `m6.stopset` (`stopAndJoin` after the stop), `m6.bg.stopped` (the gangs' prepare
between `stopAllForFork` and the `m_` locks: the CR-004 window). They fire only while
`gc::tla_m6` is set.

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/GCHelperPool.hpp` | `-` |
| file | `runtime/src/allocator/GCHelperPool.cpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.launchBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.reapBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.stopBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.runCycleStepConcurrent` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.closingFinish` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.ensureGang` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.resolveMarkThreads` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.resolveMinorThreads` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.resolveConcMarkThreads` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.destructor` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.reset` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.minorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.destructor` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureLaunch` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureJoin` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureTeardown` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcLaunch` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcFinish` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.acquireOldGenBlock` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.releaseOldGenBlock` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.onGCPauseEnd` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.rebuildPageWork` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.drainHelperWork` |
| region | `runtime/src/allocator/Allocator.cpp` | `AL.destructor` |
| census | `runtime/src/allocator/Allocator.cpp` | `-` |
| census | `runtime/src/allocator/Allocator.hpp` | `-` |
| census | `runtime/src/allocator/GCHelperPool.cpp` | `-` |
| census | `runtime/src/allocator/GCHelperPool.hpp` | `-` |
| census | `runtime/src/allocator/NurseryTenure.cpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.cpp` | `-` |
| grep | `-` | `F.bgEp` |
| grep | `-` | `F.atfork` |
| grep | `-` | `F.atexit` |
| grep | `-` | `F.fork` |
| grep | `-` | `F.threadMutex` |
| grep | `-` | `F.stopAndJoin` |
<!-- canary-pins end -->
