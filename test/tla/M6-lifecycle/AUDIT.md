# M6 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary is not built yet.

## 2026-09-28 — first implementation

**Tree:** 2026-09-28, post-7c, with the compiled-out `ECO_TLA_TRACE` hooks that landed in
`GCHelperPool.cpp`, `OldGenSpace.cpp` and `ThreadLocalHeap.cpp` during this work (they moved lines
by up to 20 and change no step; MAPPING.md cites a 23:40 snapshot). More hooks landed overnight
(`OldGenSpace.cpp` about +80 lines, `PageWork.cpp` +20 to +40 by 02:30 on 2026-09-29); they too
add only `ECO_TLA_TRACE` lines, so the model is unaffected and the function names stay the
anchors. **Tools:** the dev image:
tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b). **Machine:** shared, loaded; quick rows ran 2 at a
time with 2 workers, deep rows one at a time with 4 workers.

### Results

Quick tier: **43/43 as expected in 77 s** (`run_models.py --model M6 --jobs 2 --workers 2`). The
state counts are TLC's distinct states; times are TLC's own.

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `pool_basic` | pass | pass | 8,672 | 6 s |
| `pool_mut_fork` | pass | pass | 23,984 | 7 s |
| `pool_host_fork_parent` | pass | pass | 29,192 | 10 s |
| `pool_host_fork_stranded` | violates `ChildNoStranded` (CR-003) | as expected | 368 | 2 s |
| `pool_host_fork_locks` | violates `ChildLocksFree` (CR-015) | as expected | 238 | 1 s |
| `pool_host_fork_fix_drain` | violates `ChildNoStranded` | as expected | 254 | 1 s |
| `pool_host_fork_fix_post` | violates `ChildNoStranded` | as expected | 397 | 1 s |
| `pool_host_fork_fix_both` | pass | pass | 11,880 | 8 s |
| `pool_host_fork_tm_first` | pass | pass | 10,012 | 7 s |
| `pool_host_fork_tm_last` | violates `MutatorProgress` | as expected | 6,276 | 4 s |
| `pool_host_child_hang` | violates `HostChildProgress` (CR-015, CR-003) | as expected | 9,308 | 4 s |
| `pool_host_child_fix_both` | violates `HostChildProgress` (CR-015) | as expected | 5,508 | 4 s |
| `pool_host_child_guard` | pass | pass | 7,696 | 4 s |
| `pool_host_child_fix_all` | pass | pass | 10,556 | 4 s |
| 6 M6a mutants | each its target | each as expected | 504 – 22,352 | 1 – 4 s |
| `gangs_episode` | pass | pass | 1,574 | 1 s |
| `gangs_mut_fork` | pass | pass | 4,668 | 3 s |
| `gangs_mut_fork_mark_first` | pass | pass | 4,668 | 2 s |
| `gangs_mut_fork_1cpu` | pass | pass | 2,896 | 2 s |
| `gangs_host_fork_safe` | pass | pass | 17,838 | 4 s |
| `gangs_host_fork_1cpu` | pass | pass | 11,716 | 3 s |
| `gangs_host_fork` | violates `ClosingFinished` (CR-005) | as expected | 14,325 | 2 s |
| `gangs_host_fork_1cpu_closing` | violates `ClosingFinished` (CR-005) | as expected | 8,806 | 2 s |
| `gangs_host_fork_window` | violates `ChildHeldAny` (CR-004 window) | as expected | 618 | 1 s |
| `gangs_two_gangs_window` | violates `ChildHeldTenure` (CR-013 window) | as expected | 2,912 | 1 s |
| `gangs_host_fork_stall` | violates `StopWaitsOwnEpisode` (CR-023) | as expected | 2,927 | 1 s |
| `gangs_host_fork_fix_closing` | pass | pass | 17,838 | 5 s |
| `gangs_exit` | pass | pass | 2,074 | 2 s |
| `gangs_exit_host_fork` | pass | pass | 19,622 | 5 s |
| 9 M6b mutants | each its target | each as expected | 63 – 18,275 | 0 – 3 s |

Deep tier (`tla-check-deep`), one row at a time, 4 workers, under the machine's deep-run lock:

**18/18 as expected.** Every deep row is small: the slowest took 97 s.

| Configuration | What it stretches | Expected | Result | States | Time |
|---|---|---|---|---|---|
| `pool_deep_2workers` | 2 workers, 4 operations, the mutator forks | pass | pass | 171,680 | 1 min 14 s |
| `pool_deep_2workers_host` | 2 workers, 4 operations, host fork | pass | pass | 222,240 | 1 min 33 s |
| `pool_deep_ops6_host` | 6 operations, host fork | pass | pass | 53,280 | 16 s |
| `pool_deep_fix_all_2workers` | resolution (b), 2 workers, 5 operations, host child uses the pool | pass | pass | 185,360 | 37 s |
| `pool_deep_tm_first_2workers` | the `thread_mutex_` handler alone, same bounds | pass | pass | 192,808 | 30 s |
| `gangs_deep_host_fork_mark_first_safe` | `host_fork_safe`, prepare order `mark_first` | pass | pass | 11,225 | 2 s |
| `gangs_deep_host_fork_mark_first` | `host_fork`, `mark_first` | violates `ClosingFinished` (CR-005) | as expected | 10,890 | 1 s |
| `gangs_deep_host_fork_steps2` | host fork, 2 minor ends before the closing | pass | pass | 21,207 | 2 s |
| `gangs_deep_two_gangs` | 7c collector as a second gang, host fork | pass | pass | 88,795 | 6 s |
| `gangs_deep_two_gangs_mut` | two gangs, the mutator forks (+ `ChildHeldTenure`) | pass | pass | 23,166 | 5 s |
| `gangs_deep_b2_episode` | B = 2, no fork, 2 minor ends | pass | pass | 8,952 | 1 s |
| `gangs_deep_b2_host_fork_safe` | B = 2, host fork | pass | pass | 88,427 | 9 s |
| `gangs_deep_b2_mut_fork` | B = 2, the mutator forks | pass | pass | 23,636 | 6 s |
| `gangs_deep_1cpu_two_gangs` | one CPU, two gangs, 2 minor ends, host fork | pass | pass | 103,042 | 9 s |
| `gangs_deep_wide` | two gangs, B = 2, 2 minor ends, host fork | pass | pass | 645,675 | 1 min 29 s |
| `gangs_deep_wide_mark_first` | as `wide`, `mark_first` | pass | pass | 528,339 | 1 min 4 s |
| `gangs_deep_wide_mut` | as `wide`, the mutator forks | pass | pass | 197,658 | 42 s |
| `gangs_deep_wide_exit` | as `wide`, plus the mutator's `exit()` | pass | pass | 782,327 | 1 min 37 s |

### Negative controls (rule A6)

Every invariant and property has at least one configuration that TLC rejects with its name. Each
counterexample was read, to check that it is the intended story and not another path.

| Target | Negative control | Shortest behaviour TLC reported | Intended story? |
|---|---|---|---|
| `PoolRunOnce` | `no_dequeue` | post j1; the worker takes, runs and finishes it; takes it again (`runs` = 2) | yes (plan §5) |
| `WaitSeesDone` | `wait_no_recheck` | post j1, post j2; the worker takes j1; wait on j2 blocks; j1's notify wakes it with j2 Posted | yes |
| `ParentJobsFinish` | `no_start` | post j1; no worker ever starts | yes |
| `MutatorProgress` | `lost_wakeup` | post j1; the worker takes it; wait: `WR_Lock` sees Running and holds `m`; the worker writes Done without `m` and notifies nobody; `WR_Block`; stuck | yes, exactly |
| `ChildProgress` (M6a) | `child_keeps_started` | post (workers start), fork, post in the child (no worker starts: `started_` still set), wait; stuck | yes (needs 4 operations) |
| `HostChildProgress` | `guard_after_tm`; also `pool_host_child_hang` | the mutator takes `thread_mutex_`; another thread forks; the child's first allocator call blocks on it for ever | yes |
| `ChildNoStranded` | `pool_host_fork_stranded` (CR-003) | below | yes |
| `ChildLocksFree` | `pool_host_fork_locks` (CR-015) | below | yes |
| `LJ_RunningExact` | `running_after_notify` | `U_Launch`, `L_Lock`: `gen` = 1 with `running` false (2 steps) | yes, exactly |
| `LJ_JoinExact` | `join_no_wait` | the member starts; the closing run marks everything; `Reap(TRUE)` clears `running` while the member is still in `Mark` (45 states) | yes |
| `ExitSafe` | `join_no_wait_exit` | launch; the mutator exits: stop, no wait, `exited`; the launched member then starts | yes (the member starts after `exit`, a variant of the plan's) |
| `ChildHeapSafe` | `no_stop_in_prepare` | launch; the mutator forks; the member takes an entry before prepare locks `m_`; child | yes, exactly |
| `LJ_RunJoined` | `run_no_wait` | closing run; mutator and member mark; the mutator finds done and returns while the member is still in `Mark` | yes |
| `HandoffClean` | `run_no_wait_handoff` | closing run; the member takes an entry; another thread's stop; the mutator leaves on the stop, reaps None, drains the deques, and reaches the handoff while the member still holds the entry | yes, exactly |
| `ParentProgress` | `join_in_run` | the forker holds the gang's `m_` and waits for `run_m_`; the mutator holds `run_m_` and waits in `join` for the gang's `m_` (the plan's §1 item 7 chain) | yes, exactly |
| `LaunchIdle` | `relaunch_unreaped` | t0 launch; the first minor's reap returns early (not finished); the relaunch reaches `L_Lock` with `running` set | yes |
| `ChildProgress` (M6b) | `child_no_unlock` | the mutator forks; the child's first reap blocks in `join` on the gang `m_` its own prepare took | yes |
| `ClosingFinished` | `gangs_host_fork` (CR-005) | below | yes |
| `ChildHeldAny` | `gangs_host_fork_window` (CR-004) | below | yes |
| `ChildHeldTenure` | `gangs_two_gangs_window` (CR-013) | below | yes |
| `StopWaitsOwnEpisode` | `gangs_host_fork_stall` (CR-023) | below | yes |

### Register entries: the counterexamples

"Host" is any thread other than the heap's mutator: an embedding host, or a second heap's mutator
forking with `Process.cpp`.

- **CR-003 → Reproduced** (`pool_host_fork_stranded`, 10 states). The mutator takes
  `thread_mutex_` and CASes j1 Idle → Posted (outside `m_`). The host drains (`outstanding` is 0:
  j1 is not queued yet), locks `m_` and forks. The child holds j1 Posted, in no queue, with no
  thread to post it. TLC's shortest path is the **CAS window**, not the register's
  drain-then-post story; the register's story is `pool_host_fork_fix_post` (10 states: the post
  completes between the drain and the lock, and `atforkChild` empties the queue). Both windows are
  in the code as built. A Running job is stranded the same way (the worker does not exist in the
  child).
- **CR-003's candidate fixes.** Drain under `m_` alone fails through the CAS window
  (`fix_drain`, 9 states). The CAS under `m_` alone fails through the drain/lock window
  (`fix_post`). Both together pass (`fix_both`, 11,880 states). **So does a `thread_mutex_` atfork
  handler whose prepare runs before the pool's** (`tm_first`, 10,012 states, deep with two workers
  and five operations: 192,808): every post and wait holds `thread_mutex_`, so while the forker
  holds it no post is between its CAS and its enqueue, and none can start after the drain.
- **CR-015 → Reproduced** (`pool_host_fork_locks`, 9 states). The mutator takes `thread_mutex_`
  to post; the host forks. The child inherits `thread_mutex_` held by a thread that does not exist.
  `pool_host_child_hang` (14 states) shows the consequence: the child's first allocator call, or
  its `exit()` (`~Allocator` locks `thread_mutex_` and drains), blocks for ever
  (`HostChildProgress`). With CR-003 fixed and no `thread_mutex_` handler the child still hangs
  (`pool_host_child_fix_both`).
- **The `thread_mutex_` handler's order matters** (`pool_host_fork_tm_last`, 11 states, violates
  `MutatorProgress`). If its prepare runs **after** the pool's, the forker holds `m_` and waits for
  `thread_mutex_`, while the mutator holds `thread_mutex_` and waits for `m_` in `post`: a parent
  deadlock. The handler must be registered after the pool's (for example right after
  `pool.configure` in `Allocator::rebuildPageWork`), so that its prepare runs first.
- **CR-005 → Reproduced** (`gangs_host_fork`, 46 states; `gangs_host_fork_1cpu_closing`, 42;
  deep `mark_first`). The host's `stopAllForFork` sets the episode's stop and waits. The member has
  not finished, so the ordinary step's `reapBackground(false)` and then `closingFinish`'s own return
  early (Running, not finished): no relaunch. The closing run's members see the stop and leave; the
  run returns; `reapBackground(true)` joins (the member exits on the stop); `done` is false, so
  `bg_ep_ = None` and `assert(bg_ep_ == Finished)` fails in the **parent**. **The window is wider
  than the register says:** any foreign stop whose members have not finished when `closingFinish`
  starts, not only a stop during the join. It also fires on one CPU (inline closing, no `run_m_`).
  With the candidate fix (`closingFinish` accepts None and drains) the parent is correct:
  `ClosingFinished` and `HandoffClean` pass (`gangs_host_fork_fix_closing`).
- **CR-004 → window confirmed** (`gangs_host_fork_window`, 15 states). The host takes the registry
  and runs `stopAllForFork` while the gang is not running (nothing to stop); the mutator launches;
  the member takes an entry into its ring; the host locks `m_` and forks. In the child the entry
  is in a dead thread's ring. **The window is wider than the register says: any launch** between
  `stopAllForFork` and the `m_` lock, not only a relaunch after the stop (TLC's path is a t0
  launch; before a gang's very first launch the code's constructor would block on the registry, so
  the path is real for every later cycle's t0, and the relaunch path is real always). It is
  **harmless**: `ChildHeapSafe` (a child forked by the mutator loses nothing) holds in every
  mutator-fork configuration, quick and deep, both prepare orders, one CPU, two gangs, B = 2. A
  host's child has no mutator for the heap (HEAP_007). Proposed: **Not-a-bug**, with the step-7
  guard.
- **CR-013 → window confirmed at the gang level** (`gangs_two_gangs_window`, 17 states, violates
  `ChildHeldTenure`): the same launch-in-the-window path for the 7c collector (the tenure launch at
  the pause's end, then the member takes an item). What the child's teardown does with the orphan
  job is M5's.
- **CR-023 → Reproduced** (`gangs_host_fork_stall`, 24 states). The host's `stopAndJoin` stops
  generation 1 and waits. The member exits; the mutator's own join wins, reaps None and relaunches
  generation 2 (fresh control, `finished_ = 0`) while the host still waits in `joinLocked`. The
  host now waits for an episode it did not stop. Nothing is lost: `ParentProgress` holds in every
  host-fork configuration.
- **CR-024 → still Confirmed.** `GCHelperPool.hpp:235` still says "registered at the first
  launch"; the constructor registers (GHP:510-522). The model follows the code.
- **CR-008.** The fork harness needs, besides the host fork and the `exit()` arm: a host fork while
  a relaunch is due (CR-004 / CR-013 / CR-023), and a stop that lands before `closingFinish`
  (CR-005).

### Plan §9 step 7: the two resolutions, modelled

**(a) "fork without exec only from the heap's mutator, one mutator", with a guard.**
- The supported case holds everywhere: every `Forker = "mut"` configuration passes, including
  `ChildNoStranded`, `ChildLocksFree`, `ChildHeapSafe`, `ChildProgress` in both modules (the child
  continues the pool and the cycle), both prepare orders, one CPU, two gangs, B = 2.
- The guard (`GUARD = "before_tm"`: the child aborts its first use of a heap it does not own)
  makes a host's child terminate (`pool_host_child_guard` passes). **It must run before
  `thread_mutex_` is taken**: checked after it, the child still hangs on the dead mutator's
  `thread_mutex_` (`guard_after_tm` violates `HostChildProgress`). It must also cover `exit()`:
  `~Allocator` takes `thread_mutex_` first (A:221).
- **The guard does not cover CR-005 or CR-023: both are in the parent.** A foreign fork still
  aborts the parent's closing (`gangs_host_fork` is unchanged by a child-side guard) and can stall
  the fork's prepare for an episode. Under (a) they become "unsupported, but the parent aborts
  with an unrelated assert". A clear message needs a prepare-side check (the forking thread is not
  the owner of a running gang), or CR-005's fix anyway.

**(b) Fix all three.**
- `FIX = "all"` (post's CAS and the drain under `m_`, plus a `thread_mutex_` handler whose prepare
  runs first) passes everything with a host child that uses the pool (`pool_host_child_fix_all`;
  deep with two workers and five operations, 185,360 states). `closingFinish` accepting None
  passes (`gangs_host_fork_fix_closing`).
- **The `thread_mutex_` handler alone fixes both CR-003 and CR-015** (`tm_first`), if its prepare
  runs before the pool's; the other order deadlocks the parent (`tm_last`). It adds lock-order
  edges: the forker holds the gang registry, every gang's `m_` and `run_m_` (gang prepares run
  first) when it takes `thread_mutex_`. `~Allocator` (and the test-only `reset`) hold
  `thread_mutex_` while `~OldGenSpace` / `~GCBackgroundGang` take a gang's `m_` and the registry.
  That cycle needs a fork during exit teardown; M7's lock-order model should check it before this
  fix lands.
- **(b) unmasks CR-013 at the child's `exit()`.** As built, a host child's `exit()` hangs on
  `thread_mutex_` (CR-015) before it reaches the heap teardown. With (b) it gets through
  `drainAll` to `thread_heaps_.clear()` → `tenureTeardown`, which runs the orphan tenure job on the
  dead mutator's heap (CR-013). So (b) still needs a child-side ownership check at teardown, which
  is (a)'s guard.
- CR-023 is a separate stall that neither resolution removes (fix candidates in the register).

**Verdict for the register:** the model supports (a) as the contract, with the guard placed before
`thread_mutex_` in every allocator entry and in `~Allocator`, plus CR-005's fix (or a prepare-side
refusal) for the parent. (b) is sound for the pool with the `thread_mutex_` handler first, but
still needs the guard for CR-013.

### Changes from the plan's sketch (plan §4.6), and why

1. **`ChildNoStranded` was wrong for a mutator's child.** The sketch's "Posted or Running ⇒ still
   queued" failed on `pool_mut_fork` (931 states): the child's own post, between its CAS and its
   enqueue, and a job the child's own worker dequeued. It now says "some live thread will move the
   job on" (`InFlight`: queued, run by a live worker, or between the live poster's CAS and
   enqueue). The property is defined after the translation (it reads `j`, `cur`, `ccur`).
2. **`ChildHeapSafe` / `ChildHeldAny` counted the child mutator's own ring.** A mutator's child
   runs the closing and holds entries legitimately. They now count dead threads' rings only
   (`DeadHeld`).
3. **The closing step reaps and relaunches first**, as `runCycleStepConcurrent` does before
   `closingFinish` (OGS:4705-4722). The sketch went straight from the loop to `closingFinish`.
   `Steps` counts the ordinary steps; with `Steps = 1` there are two fork points.
4. **One CPU** (`MarkThreads = 1`): `run(n ≤ 1)` runs the closing member inline with no
   `run_m_` (GHP:414-417), so the mark gang's prepare does not wait for it. The plan named this
   (§2.3) but its model used n = 2 only.
5. **The 7c collector** (`TwoGangs`): a second gang with `tenureJoin`'s orphan / join / stop paths
   and `tenureLaunch` at the pause's end, in registry order `[tn, cm]`. Gang state became
   functions over `{cm, tn}`. `B = 2` generalises the members.
6. **`launch`'s `assert` became the invariant `LaunchIdle`** with the mutant `relaunch_unreaped`
   (no `assert` is left). **`MaxGen` is gone**: generations are bounded by the run, and a binding
   bound would stall the mutator and fail `ParentProgress` spuriously.
7. **`spawned`** (ghost: this address space's worker threads exist) separates the threads from
   `started_`. Without it the mutant `child_keeps_started` could not be expressed: the child's
   workers were enabled by `started`.
8. **`Alive` guards** on every host step in M6a (the sketch's `H_Child` had none).
9. **New properties, each with a negative control:** `ChildProgress` (both modules: the sketch
   checked nothing about a mutator's child continuing), `HostChildProgress` (step 7),
   `LaunchIdle`, `ChildHeldTenure`, `StopWaitsOwnEpisode` (CR-023). `HandoffClean` also checks the
   deques (`closingFinish`'s `assert(markStackEmpty())`).
10. **Step-7 constants:** `FIX` gained `post_under_lock`, `tm_first`, `tm_last`, `all` (M6a) and
    `closing_accepts_none` (M6b); `GUARD` is new. `ChildUsesPool = TRUE` is used by the
    `pool_host_child_*` rows (the plan kept it FALSE because no property read the child host's
    progress; `HostChildProgress` does).
11. **Gang construction is not modelled** (every gang is registered from the start). See MAPPING
    §3; it only adds behaviours.

**Differences between the plan and the code** (the model follows the code):
- line drift after the trace hooks: `launchBackground` 4431 → 4444, `reapBackground` 4505 →
  4519, `closingFinish` 4569 → 4585 (assert 4599 → 4615), `runCycleStepConcurrent` 4660 → 4677
  (reap 4688 → 4705); `GCHelperPool.cpp` +1 to +20 (for example `running_` stores 612/625 →
  627/644, `stopAllForFork` 650 → 669); `ThreadLocalHeap.cpp` +2;
- the relaunch also happens in the closing step (item 3 above);
- the CR-004 and CR-005 windows are wider than the plan's timelines (above).

### Not detectable as modelled

- A `notify_all` → `notify_one` regression on the background gang's `cv_done_` (two possible
  waiters: the owner's `join` and a foreign `stopAndJoin`). The joins are plain `await`s. The
  smallest change that would catch it is a waiter set as `doneWaiters` is for the pool (plan §5).
- Memory orders (A4: `w_pool_done`, `w_running_chain`, W pending).

### Not done in this step

- Trace validation (plan §8) and the fork harness it needs (CR-008): later wave.
- The canary (`test/tla/manifest.txt`): later wave. The lines M6 needs are below.
- The W companions `w_pool_done`, `w_running_chain`.

### A9: the canary lines M6 needs (for the later wave)

- `file`: `runtime/src/allocator/GCHelperPool.cpp`, `runtime/src/allocator/GCHelperPool.hpp`
  (models M6, M7). These pin the A4 memory orders too: the `Done` store and the fast-path load
  (GHP:220, 239; `isDone`/`isIdle` hpp:56-57), `running_` (GHP:627, 644; `running()` hpp:258),
  `finished_pub_` (GHP:608, `finishedApprox` GHP:636).
- `region` (a `TLA-REGION` marker around each; models M6, plus the ones named):
  - `OldGenSpace.cpp`: `launchBackground` (M1, M2); `reapBackground` (M1); `stopBackground`;
    `closingFinish` (M1, M2); in `runCycleStepConcurrent`, the reap, the relaunch and the closing
    branch (M1); `~OldGenSpace`; the first lines of `OldGenSpace::reset` (the `stopAndJoin`);
    `ensureGang`; `resolveMarkThreads`, `resolveMinorThreads`, `resolveConcMarkThreads` (they
    decide `MarkThreads` and the prepare order);
  - `NurseryTenure.cpp`: `tenureLaunch`'s collector construction and launch (M5);
    `tenureConcLaunch`'s launch (M5); `tenureJoin`'s `running()` / `finishedApprox` / `join` /
    `stopAndJoin` / orphan decisions (M5); `tenureTeardown` (M5);
  - `ThreadLocalHeap.cpp`: in `minorGC`, the order `tenureJoin` → minor → `stepMarkCycle` →
    `TenureLaunchScope`; `~ThreadLocalHeap`'s `tenureTeardown` call;
  - `Allocator.cpp`: `~Allocator`; `onGCPauseEnd`; `drainHelperWork`; `rebuildPageWork` (the pool's
    configure = its atfork registration); the PageWork calls in `acquireOldGenBlock` and
    `releaseOldGenBlock` (M7);
  - `runtime/src/codegen/eco_entry.cpp`: `atexitPrintStats` and its `std::atexit` registration.
- `census`: `OldGenSpace.cpp`, `NurseryTenure.cpp`, `Allocator.cpp`, `ThreadLocalHeap.cpp`.
- `grep`, three separate patterns (no alternation) over `runtime/src`, `eco-kernel-cpp` and
  `elm-kernel-cpp`: `pthread_atfork`, `std::atexit`, `fork(`. A new registration or fork site
  changes the prepare order or the `Forker` premise.

## 2026-09-29 — wave 2: the fork harness and trace validation (plan §8, §9 step 8)

**Tree:** 2026-09-29, with the trace hooks of the other models. **Runtime edits:** compiled-out
hooks only (below); the production compile is unchanged: `GCHelperPool.cpp` preprocessed with
`build/`'s EcoRuntimeStatic flags differs from the hook-free text by exactly 19 `((void)0);` (one per
`M6_TRACE`), `OldGenSpace.cpp` not at all, and both compile.

### The fork harness (`test/gc-heap-tsan/fork_harness.cpp`, CR-008)

The real allocator (helper pool on, 5c on, asserts and validation on, the P1 census off: see
below), not under TSan. Each trial is its own process with a deadline; each child probes under
`alarm()`. Final runs (seed 1000; `gc-fork-harness <arm> 40 1000`, `mut` 20 trials; the relaunch
counts from the trace build, whose probe classifies CR-023 exactly):

| Arm | Forks | Result | Register |
|---|---|---|---|
| `mut` (the supported contract) | 302 | **302 clean**: every child finished its cycle, every rooted value checked, `exit()` returned | contract holds |
| `host` | 1,015 | 32 children blocked on `thread_mutex_` (3.2%); no stranded job seen on its own; 8 of 40 trials aborted (CR-005) | CR-015 |
| `host-exit` | 1,372 | 32 children hung in `~Allocator` (2.3%); 9 died by a signal (0.7%); 5 trials CR-005 | CR-015 / CR-003 at `exit()`; new (below) |
| `two-heap` | 993 | 78 children blocked on `thread_mutex_` held by the other heap's mutator (7.9%) | CR-015 with two mutators |
| `closing` | 1,148 | **14 of 40 trials** aborted in `assert(bg_ep_ == Finished)` | CR-005 |
| `closing-early` | 285 | **16 of 40 trials** aborted | CR-005's wider window |
| `relaunch` (trace build) | 11,653 | 46 launches inside prepare: **3 in the CR-004 window, 43 CR-023 stalls**; 16 trials CR-005 | CR-004, CR-023 |
| `det-cr015` | 1 per trial | 3/3 (and 2/2): child blocks on `thread_mutex_` | CR-015, deterministic |
| `det-cr003` | 1 per trial | 3/3 (and 2/2): `thread_mutex_` free, drain blocks on a stranded job | CR-003, deterministic |
| `det-cr005` | 1 per trial | 3/3 (and 2/2): the parent aborts | CR-005, deterministic |
| `det-cr004` | 1 per trial | 3/3 (and 2/2): a relaunch between the stop and the lock | CR-004, deterministic (harmless) |

Notes:
- **CR-003 never showed at random.** Its CAS window is always inside a post, which holds
  `thread_mutex_`, so a host child there blocks on `thread_mutex_` first (CR-015). Its
  drain-then-post window is a few instructions wide. `det-cr003` pauses the forker between
  `drain()` and `m_.lock()` (probe `m6.pool.drained`) while the mutator completes a post: the child
  then blocks in `drainHelperWork`, every time. This also shows the model's step-7 point at the
  code level: the as-built CAS window is masked by CR-015, so a `thread_mutex_` handler whose
  prepare runs first closes both.
- **CR-023 at the code level:** 43 of 11,653 random host forks, exactly classified (the fork's
  `stopAndJoin` stored its stop at launch count L, and a launch followed while it waited; the gang
  was not running at the end of prepare). Three of the 24 recorded host-fork gang traces are
  CR-023 instances too (`gangs,host,12,...`: `gang.stop` gen 2, the host's `gang.join` gen 3), and
  `TraceGangs` accepts them, as the model allows it.
- **New: tearing down a heap the child does not own is unsafe beyond CR-013.** 9 of 1,372
  `host-exit` children died by a signal: `~ThreadLocalHeap` walking the dead mutator's RootSet hash
  set, copied in mid-update (SIGSEGV), and one malloc abort in the same teardown. The harness's
  mutator adds and removes RootSet roots on every allocation, so the rate overstates production,
  but the cause is general: any mutator-owned container can be copied mid-update, and the host
  child's `exit()` destroys it. The step-7 guard (skip the teardown of heaps the forking thread
  does not own) covers it; CR-003/CR-015's fixes alone do not. Proposed for the register.
- **Validate builds only: the P1 census is not fork-safe.** Its process-wide mutex and tables
  have no atfork handler: with `ECO_P1_CENSUS` on (the validate default), 3 of 307 two-heap
  children blocked in `p1::recordPromoted`, and host-exit children hung in the census's atexit
  print or crashed in `p1::forget`. The harness turns the census off (`FORK_HARNESS_CENSUS=1` keeps
  it) so the arms measure the GC's protocols.

### Trace validation

Hooks (compiled out; in a trace build they log only while an M6 harness sets `gc::tla_m6`):
- `GCHelperPool.cpp`: `pool.cas`, `pool.enq`, `pool.take`, `pool.done`, `pool.wfast`, `pool.wchk`,
  `pool.reset` (the job state as `rmw`/`rd` on its versioned value; `m_` sections on the `m6` clock),
  `pool.drained`, `pool.plock`, `pool.parent`, `pool.child`; `gang.stop` (in `stopAndJoin`);
  `fork.mprep`, `fork.mparent`, `fork.mchild`, `fork.bgreg`, `fork.bglock`, `fork.bparent`,
  `fork.bchild`. Probes (pause points for the deterministic arms): `m6.post.cas`,
  `m6.pool.drained`, `m6.stopset`, `m6.bg.stopped`.
- `OldGenSpace.cpp`: probe `m6.closing` (in `closingFinish`, the episode still running).
- The gangs' own events (`gang.launch/start/exit/join/run/runEnd`) and M1's cycle events are reused.

**A cross-model fix during the work.** The probes first fired in every trace harness. M1's
`tiny_graph.cpp` logs a `marks` event for every probe callback, so M1's `TraceHeap` rows rejected
at the first `m6.*` probe. The probes are now gated on `gc::tla_m6` too. After the fix M1 18/18,
M2 20/20, M3 15/15, M4 12/12, M5 27/27 and M7 15/15 of their trace rows ran as expected.

Specs:
- `TracePool.tla` (M6a, TraceAnyOrder) on `test/gc-helper-tsan/pool_trace.cpp` (`gc-pool-trace`):
  the real pool, a poster under a `thread_mutex_` stand-in, no fork / host fork (parent log) /
  mutator fork (parent log, or the child's log with its own workers). Hidden: the Mutator's
  control steps, the wait's block and wake, the workers' loop steps, and a **spurious wake-up**
  (the model's `WR_Blocked` needs a notify; a real condition variable may wake without one).
- `TraceGangs.tla` (M6b, TraceAnyOrder) on `gc-fork-trace gangs ...`: one 5c cycle of the real
  allocator (legacy nursery, B = 1), no fork / host fork racing the pauses / mutator fork (parent
  or child log), both prepare orders, mark threads 1 and 2, members held until the closing or not.
  The marker loop is hidden (M2's contract), so the log's grey count does not matter.

Rows (`test/tla/traces.txt`): 7 + 8 accept rows, 6 + 6 negative controls. Full runs: **28/28 as
expected** three times, then one run with the hang below (22/28: its 6 rows share the hung log),
then **28/28 as expected** after the fix.
States: 2,300 to 28,000 per row; 25–50 s for all rows.

Findings while building the specs:
- `TraceGangs` rejected every log at first: `join()`'s lock-and-check step (`J_Lock`) logs nothing,
  and it was neither hidden nor matched. A trace-spec error, not a model error.
- The pool's job ids had to be strings (the model's "no job" is `"none"`).
- A host fork recorded by `gangs` can itself hit CR-005 (the stop still pending at the closing):
  one run aborted. The scenario now waits for the fork before the closing minor; `det-cr005`
  covers CR-005.
- That wait then hung one run (`gangs,host,1,4,2,bg_first,1`, the harness timed out): the fork's
  `stopAndJoin` was waiting out a relaunched episode (CR-023) whose member the test hold
  (`test_bg_hold_`) kept from ending, while the mutator waited for the fork. In production the
  relaunched episode ends on its own (a stall, CR-023's severity); any episode that waits for the
  mutator would make CR-023 a deadlock. The scenario now releases the hold before it waits
  (12 of 12 reruns completed, one of them a CR-023 instance).

### Canary lines for the new files (A9, later wave)

- `file`: `test/gc-heap-tsan/fork_harness.cpp`, `test/gc-helper-tsan/pool_trace.cpp`,
  `test/tla/M6-lifecycle/TracePool.tla`, `TraceGangs.tla` (with their `.cfg` and `.keep`).
- `region` (add to wave 1's list): the M6 hook block at the top of `GCHelperPool.cpp` (the
  `tla_m6` macros), and in `OldGenSpace.cpp` the `m6.closing` probe inside `closingFinish` (already
  inside the `closingFinish` region).

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 39 pins
name this model (6 census, 3 file, 6 grep, 24 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: region TLH.destructor (e50c08c7f202), census Allocator.hpp (bedee6e4aa91), grep F.threadMutex (e1f93bebd039).

Change (plans/threaded-gc-register-repros-impl.md, register reproductions; snapshot of the
prior tree `snapshots/register-repros/pre-impl-2026-09-30.tgz`). Code-level guards were added for
the open register entries. The runtime changes are of three kinds only, and none adds, removes or
reorders an atomic step, a lock, a shared location or a memory order on a production path:
- **test accessors** (`AllocatorTestAccess`: `acquireOldGenBlock`, `releaseOldGenBlock`,
  `freeBlocks`, `threadMutexHeldElsewhere`, `adoptThreadHeap`; `OldGenSpaceTestAccess`:
  `sweepCompleteDeferred`, `promoMuHeld`, `cyclePressureFinishDue`). They forward to existing
  functions or read existing fields; unit tests and harnesses call them only. They fire the
  footprint greps `F.promoMu`, `F.threadMutex`, `F.pageWorkCalls`, `F.oldGenFreeBlocks`,
  `F.setThreadHeap`, `F.parPromoActive` and the `Allocator.hpp` census by name only.
- **trace-only probes** (`ECO_TLA_TRACE_ONLY`, compiled out of every other build):
  `m5.item.taken`, `m5.item.copied`, `m5.item.popped` (`TenureWork.hpp`, gated by the new
  `tla_probes`, default false), `m5.l3.claimed` (`NT.TenureParEnv`), `m6.tlh.dtor`
  (`TLH.destructor`), `m6.census.locked` (`P1Census.cpp`). `tlatrace::probe` emits no event;
  it only calls the harness's callback while recording, so no recorded trace changes.
- **a stats-only counter** in `OGS.lazySweep`'s tail completion (`sweep_tail_completions`,
  `sweep_tail_in_promotion`), inside the existing `#if ENABLE_GC_STATS` block in the same
  `promo_mu_` section as the existing `total_post_sweep_shrink_ns` write.
`test/gc-heap-tsan/promo_sweep.cpp` gained non-trace arms (`promoDetMain`, tail mode, exact arrays
every minor); its trace section (`promoTraceMain`, the M4 trace harness) is byte-identical.

Runs (2026-09-30, this tree): `run_traces.py` (every harness rebuilt): **135/135 as expected** in 83 s.

The destructor's probe fires only in the fork harness's `det-cr031` arm (gated by `tla_m6`), which also records no event. `adoptThreadHeap` is a test-only accessor used by the fork harness's `-minor` arms, which run outside the fork contract on purpose. The M6 trace rows (TraceGangs, TracePool) all give their expected verdicts on the rebuilt `gc-fork-trace`.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes Phase 2 (§4.1-§4.4): CR-014, CR-001 (race), CR-002, CR-028 fixed (GC_MODEL_001, one audit for the batch)

Pins fired for M6: census `runtime/src/allocator/OldGenSpace.cpp` (**2afe7bc4cf4d**: new relaxed `atomic_ref<GCPhase>` accesses of `gc_phase_` in promotion). No gang, pool, fork or lifecycle step changes; the new lines are M4's.

**Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.2: CR-012 option F (a second live mutator is forbidden), CR-012(d) fixed (GC_MODEL_001)

Pins fired: region `AL.acquireOldGenBlock` (**4f5f0b1d4dcd**), region `AL.releaseOldGenBlock` (**0fe08577fb84**), census `Allocator.cpp` (**88ca56595b84**), census `Allocator.hpp` (**1936ebd9fe0e**), grep `F.threadMutex` (**ac671f10dc1d**: the new `allowMultipleMutators` lock_guard).

Change (plans/threaded-gc-register-fixes.md §6.2, CR-012 option F; HEAP_007, HEAP_060, GC_DET_001
amended): (1) `initThread` aborts when another `ThreadLocalHeap` is live unless
`allowMultipleMutators(true)` (a new `thread_mutex_`-guarded flag, reset by `reset()`; opted in only by
`main.cpp --threads N>1` and the two-heap test harnesses). (2) `acquireOldGenRegion` goes through
`PageWork::onFreshBump` (and the commit observer) like `acquireOldGenBlock`'s bump, so a heap's
initial region commits only the part above the commit-ahead window (CR-012(d), fixed with sequential
mutators too). (3) Hardening (§6.2 step 6): `old_gen_in_use_bytes_` is a `std::atomic<size_t>`
written only under `thread_mutex_` by a relaxed load + relaxed store (`addOldGenInUse` /
`subOldGenInUse`), read relaxed by `getOldGenCommittedBytes` (the unlocked triggers): no RMW, no
ordering, same values; TSan `cr012:a` is now clean. `allowMultipleMutators` takes `thread_mutex_` as a
leaf (it calls nothing).

M6 models the lifecycle locks (registry, gangs, pool, `thread_mutex_` in the fork prepare). The new `thread_mutex_` holder (`allowMultipleMutators`) takes no other lock and is called only at setup; the in-use counter accesses stay inside the existing `thread_mutex_` sections; the `initThread` abort runs under `thread_mutex_` with nothing else held. No lock order changes. **Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.3: CR-007 fixed, no-wait acquire for a promotion holder with n > 1 (GC_MODEL_001)

Pins fired: region `AL.acquireOldGenBlock` (**58fd49f66454**).

Change (plans/threaded-gc-register-fixes.md §6.3, CR-007; HEAP_058/HEAP_059 amended): a promotion
holder of a parallel promotion with n > 1 workers (`OldGenSpace::acquireWaitPolicy()` =
`AcquireWait::AvoidUnderPromo`, passed at `ensureBagPageAvailable`, `allocateFromBagPage` and
`allocateLargeBlock`) gets the no-wait policy in `Allocator::acquireOldGenBlock` (modes 1/2 with
decommit on): (1) the first fitting **Pending** extent (`PageWork::isPending`, job-blind; `onReuse`
cancels it, never waits), (2) else a fresh bump, (3) else -- the old-gen cap leaves no bump room --
today's first fit (may wait; counted). The first-fit body was factored into a `takeFreeAt` lambda
(no behaviour change for `Allowed`). New PageWork API: `isPending`, `decommitOn`, `noteNoWait` (the
counters `nowait_pending_reuse_bytes`, `nowait_fresh_bytes`, `nowait_fallback_waits` and the M7 trace
event `nw`), `noteNoWaitSkip` (`nowait_skipped_extents`). Validate builds: a no-wait Pending reuse
must not raise `reuse_waits`, and `releaseBlockToAllocator` / `releaseUnassignedBlockToAllocator` abort
while `acquireWaitPolicy() != Allowed`. No lock, atomic or memory order is added; every new
PageWork call runs under `thread_mutex_` like the old ones.

M6 sees `acquireOldGenBlock` only as a `thread_mutex_` holder that may wait on a pool job; the policy removes waits (outside the cap) and adds no lock. **Verdict: no model change needed.**


## 2026-10-01 — register-fixes Phase 5: the unified fork design (CR-003/004/005/013/015/023/031/032) (GC_MODEL_001)

Pins fired: files `GCHelperPool.hpp` (**376411c19869**), `GCHelperPool.cpp` (**22f4e3f2b546**); new file and census pins `GCFork.cpp`; regions `OGS.launchBackground` (**011248915015**), `OGS.runCycleStepConcurrent` (**289cdccf4bd4**), `OGS.closingFinish` (**af1f59d07ebb**), `TLH.minorGC` (**896f924a1e35**), `NT.tenureLaunch` (**c844a0dfc358**), `NT.tenureConcLaunch` (**873a1bb7f7be**), `AL.onGCPauseEnd` (**21aae9bc0c5a**), `AL.destructor` (**4cd5c1af901a**); censuses `Allocator.cpp` (**98ff871fcd48**), `Allocator.hpp` (**12959cd0b43c**), `GCHelperPool.cpp` (**98e0cc199b0b**), `GCHelperPool.hpp` (**297cf886ba5a**), `NurserySpace.cpp` (**ac75856d10b4**), `P1Census.cpp` (**ce0924594df0**), new census pins `ThreadLocalHeap.{cpp,hpp}`; greps `F.bgEp` (**add33fc189d1**), `F.atfork` (**850ac4ab5ed2**), `F.threadMutex` (**6cdf9fdc0767**).

Change (plans/threaded-gc-register-fixes.md §7, Phase 5; HEAP_007 fork contract, HEAP_058, HEAP_065,
HEAP_070 amended, HEAP_075 new): (1) `GCFork.{hpp,cpp}`: ONE `pthread_atfork` registration with fixed
layers (gangs: registry -> each background gang's `m_` to set `fork_hold_` -> `stopAllForFork` -> each
gang's `m_` held -> `GCMarkGang` `run_m_` -> its `m_`; allocator: `thread_mutex_`; census: the P1 census
mutex and detector N's; pool: `GCHelperPool::m_`, drained and held); the three old registrations are
gone. (2) No teardown holds `thread_mutex_` while it takes a gang lock (`cleanupThread`,
`finishTenureForExit`, `reset`, `~Allocator`). (3) CR-003/015: `post`'s Idle->Posted CAS and the enqueue
in one `m_` section; the pool prepare drains and keeps `m_` in one section; the allocator layer locks
`thread_mutex_`, the child re-creates it and records `fork_child_` / `fork_owner_`. (4) CR-013/004:
`GCBackgroundGang::launch` returns false (refuses) while `fork_hold_`; `launchBackground` then leaves
`bg_ep_ = None` (`cm.episodes_refused`), `tenureLaunch` / `tenureConcLaunch` count `rs.fork_refusals`
and the join's orphan path finishes the job. (5) CR-023: `stopAndJoin` waits for
`generation_ != my_gen || finished_ >= members` and clears `running_` only for its own generation;
`launch` notifies `cv_done_`. (6) CR-005: `closingFinish` accepts `bg_ep_ == None`. (7) CR-031:
`~Allocator` (and `initThread`, `getCombinedStats`, `validatePageWork`) never touch a heap the forker
does not own in a forked child; validate builds check `ThreadLocalHeap::owner_` in `minorGC` /
`majorGC`. (8) CR-032: the census layer; `atexitReport` returns in a forked child. Trace-only: the
probe `m6.tm.held` in `onGCPauseEnd` (under `thread_mutex_`), `fork.bghold`, `gang.refuse`, the step
event's `refused` field and an M1 `stop` after a refused launch.

**Model first (before the code).**
- **HelperPool.tla (M6a).** The `FIX` constant is gone: the fixed handlers are the default
  (`DrainHoldsLock`, `PostUnderLock`, `TmFirst`), and `MUTANT` turns pieces off. Rows flipped to
  **pass**: `pool_host_fork_stranded` (9,464 states; ChildNoStranded, ChildLocksFree, PoolRunOnce,
  WaitSeesDone, ParentJobsFinish, MutatorProgress), `pool_host_fork_locks` (9,464), `pool_host_child_hang`
  (10,556; HostChildProgress). A6 mutants (the old fix rows): `pool_as_built_2026_09` violates
  ChildNoStranded (449), `pool_no_tm_cas_outside` ChildNoStranded (305), `pool_no_tm_drain_split`
  ChildNoStranded (575), `pool_no_tm` ChildLocksFree (231), `pool_no_tm_child_hang` HostChildProgress
  (5,508), `pool_tm_last` MutatorProgress (4,408); `pool_guard_after_tm` now runs with `no_tm` (the
  guard's design) and still violates HostChildProgress. The `no_start` mutant also gates the start in the
  merged post step. Rows `pool_host_fork_fix_*`, `_tm_first`, `_tm_last`, `pool_host_child_fix_*`,
  `pool_deep_tm_first_2workers` were deleted (identical to the flipped rows or now mutants); the host-fork
  deep rows also check ChildNoStranded / ChildLocksFree.
- **Gangs.tla (M6b).** New `hold` (fork_hold_), `G_Hold` after `G_Reg` (each gang's m_, the hold set
  BEFORE the stops), the refusal branch of `L_Lock` (CM: `bgEp := "None"`; TN: the job stays,
  `U_TFinish` finishes it), `SJ_Wait` waiting for `finished >= NM \/ gen # sgen` and clearing `running`
  only when `gen = sgen`, `ClosingFinished` accepting `None`, `FIX` removed; `ForeignStop` (a stop with
  no fork, no hold) and `RelaunchWaitsStopper` (the relaunched member ends only after the stopper
  returned; ghost `fstop`). `StopWaitsOwnEpisode` is now "same generation, or the stopper's wake-up is
  enabled". The prepare order is `bg_first` in the code (GCFork); `PrepareOrder = "mark_first"` stays as a
  variant the fix must also pass. Rows flipped to **pass**: `gangs_host_fork` (14,959), `_1cpu_closing`
  (9,018), `gangs_host_fork_window` (14,959; also ChildHeldTenure, ParentProgress),
  `gangs_two_gangs_window` (97,084), `gangs_host_fork_stall` (14,959), deep `gangs_deep_host_fork_mark_first`
  (11,784); `gangs_host_fork_fix_closing` deleted (now the default). New rows: `gangs_foreign_stop` pass
  (4,979; ParentProgress, StopWaitsOwnEpisode, LJ_*, ClosingFinished, HandoffClean), deep
  `gangs_deep_b2_foreign_stop` pass (31,935). New A6 mutants: `no_fork_hold` ChildHeldTenure (4,921),
  `hold_after_stop` ChildHeldTenure (4,243), `no_fork_hold_window` ChildHeldAny (1,135), `no_stop_gen`
  ParentProgress (4,979), `stop_gen_clears_running` LJ_RunningExact (973), `closing_asserts_finished`
  ClosingFinished (12,035).
- `run_models.py --model M6`: quick 48/48; deep 18/18 (`gangs_deep_wide_exit` 1,032,905 states, the largest).
- **Trace specs.** `TracePool`: `pool.cas` is the merged CAS-and-enqueue step (`M_PostCas`), `pool.enq` a
  check of its count at `M_PostDone`; `pool.drained` is `F_Drain` (m_ kept) and `pool.plock` a check;
  `pool_trace.cpp` registers a GCFork allocator layer for its `thread_mutex_` stand-in (F_Tm). The old
  negative control `drop:pool.enq:1` matched nothing any more (the event is a check now) and became
  `set:pool.enq:1:out=7` (reject). `TraceGangs`: `fork.bghold` = `G_Hold`, `gang.refuse` = `L_Lock`'s
  refusal, a `step` with `refused` checks `bgEp = None`, a stopAndJoin whose generation was relaunched
  returns with no `gang.join` (hidden `SJ_Wait`); `.keep` gains `fork.bghold`, `gang.refuse`; new
  negative control `drop:fork.bghold:1` (reject). The `gangs` harness writes `order = bg_first` (the
  order that runs) for both registration orders. `run_traces.py --model M6`: 29/29.

**Code**: as above. A6 negative controls in code (revert checks, `run_fork_arms.py --flavor trace`):
allocator layer off -> `det-cr015` hang_tm 3/3 (and `det-cr003` hang_tm: the forker took the pool's m_
while the mutator held thread_mutex_); pool fix and allocator layer off -> `det-cr003` hang_drain 3/3
(the pool fix alone is masked in code by the allocator layer, as `pool_host_fork_tm_first` predicted);
hold off -> `det-cr004` window 3/3, `det-cr013-*` reproduce; closing assert restored -> `det-cr005`
aborts 3/3; `~Allocator` drop off -> `det-cr031` 3/3 (and with the hold off too, `det-cr013-l3-exit`);
census layer off -> `det-cr032` 3/3; `stopAndJoin` generation-blind -> CRT `CR-023` stalls, clearing
running unconditionally -> CRT `CR-023` sees running() false. `det-cr015` now pauses at the new probe
`m6.tm.held` (thread_mutex_ only): its old pause point, post's CAS, is under the pool's m_ since the fix.

**Verdict: model updated (HelperPool, Gangs, TracePool, TraceGangs, MAPPING.md).**
