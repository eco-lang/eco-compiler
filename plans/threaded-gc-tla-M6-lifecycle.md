# Threaded GC — TLA+ model M6: thread lifecycle, fork and exit

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). **Adversarial review on 2026-09-28 against the
current tree** (§11): the sketches were corrected, and the corrected text in §4.6 passes the PlusCal
translator and SANY (tla2tools 1.8.0). **TLC has not run on them.** The "expected" results in §5
and §6 are predictions from reading the code; the first TLC run confirms or corrects each one.

**Parents:** `plans/threaded-gc-tla-verification.md` (rules A1–A9, §5.0 contracts) and
`plans/threaded-gc-tla-primer.md` (§3.4 locks and condition variables, §3.5 fork). The layout and
depth follow `plans/threaded-gc-tla-M2-slice-control.md`.

**Register entries this model settles:** CR-003, CR-004, CR-005, CR-015, and the fork part of
CR-008 (`plans/threaded-gc-concurrency-register.md`).

**Contracts provided** (parent plan §5.0; §4.9 here): **LaunchJoin** to M1, M2, M3 and M5, and
**PoolJob** to M7.

---

## 1. Why this model, and what it checks

The GC runs work on three kinds of helper threads:

| Thread set | Class | Started | Runs | Stopped / joined |
|---|---|---|---|---|
| Helper pool (`eco-gc-N`) | `GCHelperPool` (one per process) | lazily at the first `post` | small jobs: discard or prefault pages (M7) | never joined; parked forever |
| Mark gang (`eco-mark-N`) | `GCMarkGang` (one per process) | lazily at the first parallel run | in-pause parallel work: 5b slices, 5c assists and closing joins, phase-6 minors, 7c help, heals | every `run` returns only after all members finish |
| Background gangs (`eco-cmark-N`, `eco-tenure-N`) | `GCBackgroundGang` (one per heap per use: 5c markers, 7c tenure collectors) | at the first `launch` | seconds-long work while the mutator runs | `join`, or `stopAndJoin` (set the stop flag, then join) |

Each class has a small protocol (mutex + condition variables + a few atomics) for starting work,
finishing it and waiting for it. Each also registers `pthread_atfork` handlers, so that a `fork()`
leaves consistent state in the child, where only the forking thread exists.

M6 checks, for every interleaving at small scale:
1. **No lost job, no double run (PoolJob):** every job posted to the pool is run exactly once and
   eventually observed Done (parent), and `wait` returns only when the job is Done.
2. **No stranded job in a child:** a child never holds a job that is Posted or Running but that
   no child thread will ever run. That is CR-003.
3. **No lock held by a dead thread in a child:** in the child, no mutex is owned by a thread that
   was not copied.
4. **Join means joined (LaunchJoin):** `join` and `stopAndJoin` return only after every member
   finished, and in the parent `running()` is true exactly from a launch to its join.
5. **Stop leaves recoverable work:** after `stopAndJoin`, all unfinished work is in the deques.
   This is M2's contract (§5.0 of the parent plan), assumed here.
6. **Fork and exit are safe:**
   - a child forked by the mutator continues the heap without losing mark work (CR-004 analysis);
   - a fork from another thread during a closing join trips `closingFinish`'s assert in the
     parent (CR-005, an expected failure until fixed or ruled unsupported);
   - after `stopAllAtExit`, run by the mutator's own `exit()`, no background member runs (§2.7).
7. **No deadlock in the parent** (`ParentProgress`), including the chain "the forker holds the
   background gang's `m_` and waits for `run_m_`, while the mutator holds `run_m_`".

## 2. The protocols in plain words

### 2.1 The helper pool's job (`GCHelperPool.cpp:149-258`)

A `HelperJob` moves through `Idle → Posted → Running → Done`, and back to `Idle` when its owner
calls `resetForReuse`.

```
post(job):   CAS job.state Idle -> Posted             (outside m_)
             lock m_; start workers if needed; enqueue; ++outstanding; unlock
             cv_work.notify_one()
worker:      lock m_; wait on cv_work until queue non-empty; dequeue; state = Running; unlock
             run the job body (no lock)
             lock m_; state = Done (release); --outstanding; unlock
             cv_done.notify_all()
wait(job):   if state == Done (acquire): return        (no stall)
             lock m_; wait on cv_done until state == Done; unlock   (a stall)
drain():     lock m_; wait on cv_done until outstanding == 0; unlock
```

Every post and every wait happens **under `Allocator::thread_mutex_`** (HEAP_058): every
`page_work_->` call in `Allocator.cpp` sits in a function that holds it (`:223` `~Allocator`,
`:792` `acquireOldGenBlock`, `:901` `releaseOldGenBlock`, `:1257` `onGCPauseEnd`, `:1266`
`drainHelperWork`). The holder is usually the mutator: it posts at the pause-end sync point and
waits through PageWork (M7). **It can also be a `GCMarkGang` member inside a pause**: a parallel
minor or the pause tenure engine allocates through `startVirginBlockShared` →
`ensureBagPageAvailable` → `acquireOldGenBlock` (`OldGenSpace.cpp:1249-1251, 866-871`;
`NurseryTenure.cpp:984`), possibly under `promo_mu_` (CR-007, M7). The model's `Mutator` process
therefore stands for "whichever thread holds `thread_mutex_`" (§4.3). Workers never take
`thread_mutex_`.

`wait()` reads the state **outside `m_` first** (`:238`, acquire), and so do `HelperJob::isDone` /
`isIdle` (`GCHelperPool.hpp:56-57`), which PageWork's `reapDone` and `takeSlot` use. So `Done` is
published to a waiter either by `m_` or by the release store at `:219` paired with those acquire
loads alone (§7, A4).

**How a condition-variable wait is modelled** (primer §3.4). `cv_done.wait(lk, pred)` is:
- check `pred` under the lock;
- if it is false, atomically release the lock and go to sleep;
- when notified, wake, re-take the lock, and check `pred` again.

The model says exactly that. The waiter **holds `m` explicitly** between its check and its block,
because the check and the block are atomic only against threads that take `m_` (an excerpt: the
sketch's `WR_Blocked` also has the `wait_no_recheck` mutant branch):

```tla
WR_Lock:                         \* lock m_, check the predicate under it
    await Alive(self) /\ m = "none";
    if jstate[wj] = "Done" then goto WR_Reap;   \* true: unlock and return
    else m := self;                \* false: m_ stays held until the wait blocks
    end if;
WR_Block:                        \* cv_done_.wait: join the waiters AND release m_
    await Alive(self);
    doneWaiters := doneWaiters \cup {self};
    m := "none";
WR_Blocked:                      \* woken by notify_all, then re-lock and re-check
    await Alive(self) /\ self \notin doneWaiters;
    goto WR_Lock;
```

`notify_all` is the worker's separate step `W_Notify` (`doneWaiters := {}`), outside the lock as
in the code (`:222`).
- A **lost wakeup** happens when a notify reaches nobody because the waiter has not blocked yet,
  and the waiter then blocks forever.
- It is impossible in the real code, because Done is written under `m_` *before* the notify. The
  waiter either sees Done when it checks under the lock, or is already in `doneWaiters` when the
  notify clears it.
- The mutant `lost_wakeup` (§5) writes Done **without taking `m_`** (the notify still follows).
  That lands between `WR_Lock` and `WR_Block`, and TLC must find a waiter stuck forever. (A
  waiter modelled as one check-and-block step would hide this: the review found the first draft
  did.)

`cv_work`'s wait needs no explicit waiter set: nobody checks its predicate outside the lock. It is
the one-step `await m = "none" /\ queue # <<>>` (primer §3.4).

### 2.2 The background gang (`GCHelperPool.cpp:499-690`)

```
launch(fn, ctx, stop):  lock m_; start threads if needed; set fn/ctx/stop; finished = 0;
                        ++generation; running_ = true (release); unlock; notify_all(cv_start)
member:                 lock m_; wait on cv_start until generation changes; copy fn; unlock
                        fn(ctx, i)                        -- the marker loop (M2) or a tenure job
                        lock m_; ++finished; finished_pub = finished (release); notify cv_done; unlock
join():                 lock m_; if !running_: return; wait on cv_done until finished >= members;
                        running_ = false (release); unlock
stopAndJoin():          lock m_; if !running_: return; *stop = true (release); then as join()
finishedApprox():       finished_pub >= members (acquire), a hint only (GC_DET_001)
```

5c's driver (`OldGenSpace.cpp`) uses it like this:
- `launchBackground` (4431) at the end of the t0 pause;
- at each minor end, `runCycleStepConcurrent` (4660) calls `reapBackground(false)` (defined at
  4505, called at 4688). It joins if the members have finished, and records the episode as
  `Finished` (done) or `None` (stopped);
- `runCycleStepConcurrent` then **relaunches** a stopped episode whose work is still in the deques
  (4689-4696);
- `closingFinish` (4569) runs a closing join on the mark gang, then `reapBackground(true)`, then
  asserts `bg_ep_ == Finished` (4599).

7c uses a second `GCBackgroundGang` per heap, the tenure collector:
- `tenureLaunch` (`NurseryTenure.cpp:428`) launches it at `:572` (exact engine), or through
  `tenureConcLaunch` at `:1234` (L3);
- `tenureJoin` (575-667) joins it or stops it. With `tenure_help = 1`, **the default**
  (`AllocatorCommon.hpp:267`), a late job is stopped by the **mutator's own** `stopAndJoin`
  (`:590`, `:625`), so `stopAndJoin` is a normal path, not only a fork or exit path;
- a job whose gang is not running is "stopped by a fork hook", and the next minor finishes it on
  the mutator (`NurseryTenure.cpp:614-615, 631`, "trap 25"). This test decides on `!running()`
  **without a join**, so it relies on `running()` being exact (LaunchJoin, §4.9).

**A relaunch can also land inside a foreign `stopAndJoin`'s wait.** `joinLocked`'s condition wait
(`:624`) releases `m_`. If the mutator's own join wins `m_` after the stopped member finishes, the
mutator can reap and relaunch (`launch` resets `finished_ = 0`, `:609`). The foreign joiner then
re-checks `finished_ >= members`, finds 0, and waits for the **relaunched, unstopped** episode to
end on its own: a fork prepare stalled for a whole episode. Nothing is lost (the joiner waits for
the member). The model has this interleaving (`SJ_Wait` re-checks `finished`).

### 2.3 The mark gang (`GCHelperPool.cpp:327-482`)

`run(fn, ctx, n)` takes `run_m_` (one run at a time), starts members 1..n−1 through a generation
counter, runs member 0 itself, and waits until all have finished. It is used only inside pauses.
With `n <= 1` it calls `fn(ctx, 0)` inline and takes **no lock** (`:408-411`): with one CPU
(`mark_threads_ = 1`) the closing join and the assists run inline, and the mark gang's prepare
does not wait for them. The model uses `n = 2`. The instance is **process-wide**: runs from
several heaps are serialised by `run_m_`.

### 2.4 The fork handlers

`pthread_atfork(prepare, parent, child)` handlers run their prepare step in **reverse
registration order**, and their parent and child steps in registration order. Registration happens
at first use:

| Class | Registered at | Prepare | Parent | Child |
|---|---|---|---|---|
| `GCHelperPool` | `configure` (109-114), at heap initialize (`Allocator::rebuildPageWork`, `Allocator.cpp:1226`; not at all in `gc_thread_mode = 0`) | `drain()`, then `m_.lock()` **as two separate critical sections** (260-265) | unlock `m_` | re-construct `m_`/cvs, forget workers, `head_ = tail_ = nullptr`, `outstanding_ = 0`, `started_ = false` (271-287) |
| `GCMarkGang` | `configure` (337-342), at the first `ensureGang()` (`OldGenSpace.cpp:2935`): the first parallel minor (n > 1), assist, closing join or parallel 5b run | lock `run_m_` (waits out a run), lock `m_` (458-464) | unlock both | re-construct, forget threads (472-482) |
| `GCBackgroundGang` | first constructor (505-511), plus `std::atexit(stopAllAtExit)` (the header comment, `GCHelperPool.hpp:235-236`, says "at the first launch": drift) | lock the registry; `stopAllForFork()` (for each gang: `if running() stopAndJoin()`); then lock every gang's `m_` (664-669) | unlock | re-construct, `running_ = false`, forget threads (676-690) |

The registration order depends on which is used first:
- The pool is always first (heap initialize).
- With several CPUs the first minor is parallel, so the mark gang registers next.
- **With one CPU** (`availableCpus()` = 1, from the affinity mask or a cgroup `cpu.max` quota,
  `GCHelperPool.cpp:692-718`), `mark_threads_ = minor_threads_ = 1` but `conc_threads_ = 1`
  (`OldGenSpace.cpp:2922`, `resolveMarkThreads`; `:2946`, `resolveMinorThreads`; `:2955-2967`,
  `resolveConcMarkThreads`: `cpus > 1 ? cpus - 1 : 1`). Minors never call `ensureGang`
  (`NurseryParallel.cpp:739`, `NurseryRegion.cpp:862`: only for n > 1). The first background gang
  is built at the first concurrent t0 (`launchBackground`, `:4456`) or the first tenure launch
  (`NurseryTenure.cpp:565`), and the mark gang registers later, at the first assist or closing
  (`:4543`, `:4584`).

So the prepare order is "background gang, mark gang, pool" on multi-CPU hosts and "mark gang,
background gang, pool" on one CPU (a common container quota). Nothing the code does depends on the
order: no background member ever takes `run_m_` or the mark gang's `m_`, and the pool's prepare runs
last either way. The model checks both (constant `PrepareOrder`, §6).

**What the runtime itself does.** The only `fork()` calls are in `eco-kernel-cpp/src/eco/Process.cpp`
(70, 124). They run on the mutator between pauses, and the child immediately `execvp`s. The unit
tests fork between pauses from the mutator and continue in the child. **A fork from another
thread** (an embedding host, e.g. a Node child-process spawn, **or a second heap's mutator**, §2.6)
is the case the handlers were never designed around. That is where CR-003/004/005/015 live.

**What the child inherits** (read from the handlers):
- every GC mutex and condition variable is re-constructed, **except `Allocator::thread_mutex_`**,
  which has no handler (CR-015);
- the pool forgets its queue and its count, but not the jobs' states: a job Posted or Running in
  the parent stays so (CR-003);
- no gang thread survives; `running_ = false`; `bg_ep_` (a heap field) may still say `Running`,
  which the next `reapBackground` turns into `None` and a relaunch;
- a heap whose mutator is not the forking thread has no driver in the child. Its teardown still runs
  if the child calls `exit()` (§2.7).

### 2.5 The windows, as timelines

**CR-003: a post between the drain and the lock.** H is the host thread, M the mutator.

| # | H (forking) | M (mutator) | pool state |
|---|---|---|---|
| 1 | prepare: `drain()` sees `outstanding == 0`, releases `m_` | | queue empty |
| 2 | | pause end: holds `thread_mutex_`; `post(j)`: CAS Idle→Posted, lock `m_`, enqueue, `++outstanding` | j Posted, queued |
| 3 | prepare: `m_.lock()` | | |
| 4 | `fork()`; the child runs `atforkChild`: queue and `outstanding` reset | | **child: j Posted, not queued, no worker will run it** |

Between steps 2 and 3 a worker may also dequeue j (`Running`, `:207-214`); the child then holds a
job that is Running with no thread to finish it. In the child, a later `wait(j)` (PageWork's
`takeSlot` waiting for its oldest slot) never returns. **So does the child's `exit()`**: the static
`g_allocator_storage`'s destructor (`Allocator.cpp:218-224`) locks `thread_mutex_` and runs
`drainAll`, which waits on every non-Idle slot. The hazard therefore needs only a child that calls
`exit()` rather than `_exit()` or `exec`; it does not need the child to allocate.
Two further facts found while writing the model:
- **The candidate fix "drain while holding `m_`" is not enough.** `post`'s Idle→Posted CAS happens
  *outside* `m_`. A fork between M's CAS and M's enqueue strands j with `outstanding == 0`, which
  the fixed drain accepts. The CAS must move under `m_` too (configuration `host_fork_fix_both`).
- **In the same window, M holds `Allocator::thread_mutex_`**, which has no atfork handler. The
  child's first allocator call, or its `exit()` (`~Allocator` takes it first), deadlocks on it
  whatever the pool does (invariant `ChildLocksFree`, CR-015).

**CR-004: a relaunch between `stopAllForFork` and locking `m_`.**

| # | H (forking) | M (mutator) | background member B |
|---|---|---|---|
| 1 | bg prepare: registry lock; `stopAllForFork()` stops and joins the episode | | exits on stop (work back in deques) |
| 2 | | minor end: `reapBackground` → episode `None` with work → **relaunch** (takes and releases `m_`) | wakes, takes an entry into its ring |
| 3 | bg prepare: lock `m_` (now free) | | scanning |
| 4 | `fork()` | | **child: B does not exist; the entry in its ring is gone** |

TLC should confirm the window exists (invariant `ChildHeldAny` fails for a host fork). **It is
harmless for the heap** (confirmed by reading the code in the review):
- In a child forked by another thread, the heap's mutator does not exist either. A heap is driven
  only by its owner thread (HEAP_007): its thread-local heap pointer, its stack, its roots.
- So no thread in the child can ever run the mark cycle that lost the entry. The child's only other
  path into that heap is teardown at `exit()` (`~Allocator` → `thread_heaps_.clear()`), and
  `~OldGenSpace` (`OldGenSpace.cpp:229-233`) only calls `stopAndJoin` (a no-op: `running_` was
  reset) and destroys the gang; it never marks.
- In a child forked **by the mutator**, step 2 cannot happen, because the mutator is inside
  `fork()`. With several mutators this still holds for the forker's own heap (§2.6).
- **The 7c analogue (CR-013) does not get the same exit.** The same teardown runs
  `tenureTeardown` (`~ThreadLocalHeap`, `ThreadLocalHeap.cpp:238-241` →
  `NurseryTenure.cpp:900-914`), which **does** run the orphan job (`runJobExact` or
  `tenureConcFinish`) on the dead mutator's heap, on the exiting host thread. That belongs to M5
  and the register (reported with this review).

The meaningful invariant is `ChildHeapSafe`: a child forked by the mutator loses nothing. It
should hold. If TLC agrees, CR-004 moves to Not-a-bug, with a guard (§9 step 7).

**CR-005: a fork-stop during the closing join.**

| # | H (forking) | M (mutator, in `closingFinish`) | members |
|---|---|---|---|
| 1 | | `GCMarkGang::run(closing)`: holds `run_m_` | fg member and bg member marking |
| 2 | bg prepare: `stopAllForFork()` sets stop; waits for B | | B exits on stop; the fg member leaves idle on stop (M2) |
| 3 | bg prepare: locks bg `m_`; mark prepare: waits for `run_m_` | `run` returns, releases `run_m_` | |
| 4 | takes `run_m_`, forks; parent unlocks | `reapBackground(true)`: `join()` waits for bg `m_` until H unlocks, then returns | |
| 5 | | episode not done → `bg_ep_ = None` → **`assert(bg_ep_ == Finished)` fails** (4599) | |

This happens in the **parent**. Only the `release` preset skips the assert and drains the rest with
`runMarkers` (4601-4604), which is correct. The everyday `build` preset keeps asserts on
(`CMakePresets.json:34-35`, `-UNDEBUG`), so there the parent aborts. The same chain fires if the
closing join's episode is stopped by any thread other than the mutator (a second heap's mutator
forking, §2.6). M2's `episode_stop` configuration reproduces the marker-loop half; M6 reproduces
the whole chain (invariant `ClosingFinished`), and checks that step 4 is not a deadlock
(`ParentProgress`).

### 2.6 Several heaps (several mutators)

- **Shared by every heap:** the pool and PageWork (one per process, every post and wait under
  `thread_mutex_`), `GCMarkGang` (runs serialised by `run_m_`), and the background-gang registry
  with its atfork and atexit hooks. **Per heap:** the `GCBackgroundGang` instances (5c, 7c).
- M6a's single `Mutator` stands for whichever thread holds `thread_mutex_`. The lock serialises
  every poster and waiter, so a second mutator adds no pool behaviour.
- **A second mutator does change the fork verdicts.** When mutator A forks between its own pauses
  (`Process.cpp`), mutator B is a non-mutator for that fork. B can hold `thread_mutex_`, sit
  between `post`'s CAS and its enqueue, relaunch its episode in the CR-004 window, or be in its
  closing join (CR-005). So `Forker = "host"` also models "another heap's mutator forks", and
  `ChildUsesPool = TRUE` is then the natural case: A's heap lives on in the child and uses
  PageWork. The `Forker = "mut"` pass verdicts hold **only with one mutator** (CR-012's premise).
- `ChildHeapSafe`'s argument survives: in the child only A's heap has a mutator, and A cannot
  relaunch while it is inside `fork()`.
- Today more than one mutator exists only in the benchmark driver (`runtime/src/main.cpp`
  program threads), which never forks, and the runtime's own forks `exec` at once
  (`Process.cpp:76-77, 140-141`).

### 2.7 Exit and teardown (read from the code)

- **Pool workers and mark-gang members** are joinable `std::thread`s held by leaky singletons
  (`GCHelperPool.cpp:65-73`, `322-325`). They are never joined and never destroyed, so no
  joinable-thread destructor runs. They die parked with the process.
- **Background gangs.** `stopAllAtExit` stops and joins every instance on the thread that calls
  `exit()`. It runs **before** `~Allocator`: `g_allocator_storage` (`Allocator.cpp:315`) is
  constructed during static initialisation, before the `atexit` registration, so its destructor
  runs after the handler. It also runs before the stats handler `atexitPrintStats` (registered at
  the top of `main`, `eco_entry.cpp:261`), whose optional STW major (`ECO_GC_EXIT_MAJOR`) reaches
  `closingFinish`, sees `running()` false, takes the drain path and never relaunches.
- **`~Allocator`** (`Allocator.cpp:218-229`), under `thread_mutex_`: `drainAll`, then
  `thread_heaps_.clear()`. That runs `~ThreadLocalHeap` → `tenureTeardown` (stop, finish, merge,
  destroy the collector) and `~OldGenSpace` → `stopAndJoin`, then destroys the gang (joining its
  threads, `GCHelperPool.cpp:516-532`). Only then does `releaseReservation` unmap the heap. So even
  a gang relaunched after `stopAllAtExit` is joined before the unmap.
- **Who calls `exit()`:** the Elm thread (the kernel's `exit`, `Process.cpp:227-231`), which is
  the mutator; or the main thread after `pthread_join` (`eco_entry.cpp:343`), when no mutator is
  left. The benchmark driver also joins its program threads first. `exit()` on another thread
  while a mutator runs is out of scope: `~Allocator` would destroy that mutator's heap under it.
- M6b models the first case: `ExitAllowed` lets the mutator call `exit()` between pauses, and
  `exit()` does not return.

## 3. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| `HelperJob` states, `isDone`/`isIdle` (acquire, no lock), `resetForReuse` | `GCHelperPool.hpp:42-59`; `.cpp:58-63` | `jstate`, `WR_Load`, `WR_Reap` |
| `GCHelperPool::post` | `GCHelperPool.cpp:149-178` | `M_PostCas`, `M_PostQ`, `M_PostDone` |
| `GCHelperPool::workerLoop` | 180-224 | process `Worker`: `W_Take`, `W_Run`, `W_Done`, `W_Notify` |
| `GCHelperPool::wait` (fast path 238-239, stall 242-247), `drain` (254-258) | 236-258 | procedure `WaitAndReap`; `F_Drain` |
| PageWork's reads and waits: `reapDone`, `takeSlot`, `awaitSlot` | `PageWork.cpp:97-125` | the `Mutator`'s wait branch |
| pool atfork prepare/parent/child | 260-287 | procedure `DoFork` |
| `GCMarkGang::run`, `memberLoop`, atfork | 357-482 | `runM`, `U_RunLock`/`U_FgWait`, `FgMember`, `G_Mark1`/`G_RunM` |
| `GCBackgroundGang::launch`/`memberLoop`/`join`/`joinLocked`/`stopAndJoin` | 543-643 | procedures `Launch`, `Reap`, `StopAndJoin`; process `BgMember` |
| `stopAllForFork`, `stopAllAtExit`, bg atfork | 650-690 | procedures `ForkGangs`, `ExitGangs` |
| `launchBackground`, `reapBackground`, `closingFinish`, relaunch in `runCycleStepConcurrent` | `OldGenSpace.cpp:4431-4471, 4505-4526, 4569-4637 (assert 4599), 4688-4699` | `Launch`, `Reap`, `U_Close*`, `U_Relaunch` |
| `~OldGenSpace` (stop, then destroy the gang) | `OldGenSpace.cpp:229-233` | §2.5 CR-004 argument (not modelled) |
| 7c tenure collector launch / join / orphan path / teardown | `NurseryTenure.cpp:428-573 (launch 572, 1234), 575-667 (orphan 614-615, 631), 900-914` | the same gang protocol (M5 models the job); configuration `two_gangs` |
| `ensureGang` (mark gang configure) | `OldGenSpace.cpp:2935-2944` | `PrepareOrder` (§2.4) |
| `Allocator::thread_mutex_` around posts and waits | `Allocator.cpp:753, 892, 1253` (and `223`, `1265`) | `tm` |
| `~Allocator`, `atexitPrintStats` | `Allocator.cpp:218-229`; `eco_entry.cpp:190-212, 261` | §2.7; `ExitGangs` on the mutator |
| the runtime's own fork | `eco-kernel-cpp/src/eco/Process.cpp:70, 124` | `Forker = "mut"` |

**Outside M6:**
- what the jobs do (M7);
- the marker loop (M2's contract, in `Mark()`);
- the heap (M1);
- memory orders. Launch, join and `run` are mutex release/acquire handoffs. Three handoffs are not:
  the job state's `Done` (release at `:219`, acquire outside `m_` at `:238` and in `isDone`),
  `running_` (release at `:612`/`:625`, acquire in `running()`, `GCHelperPool.hpp:258`), and the
  hint `finished_pub_`. The model reads them in SC; §4.9 and §7 (A4) say who checks the orders.

## 4. The model

### 4.1 Two modules

- **`HelperPool.tla` (M6a)**: the pool, its fork handlers, `thread_mutex_`, the mutator's
  post/wait, a host thread, and child workers.
- **`Gangs.tla` (M6b)**: one background gang, the mark gang's `run_m_`, the 5c driver, the fork
  prepare sequence in either order, and `stopAllAtExit` on the mutator's `exit()`.

They share no variables: the pool's prepare runs last and is independent of the gangs'. One module
would multiply the two state spaces for no extra behaviour.

### 4.2 Modelling fork (primer §3.5)

`fork()` is one step with two outcomes, which TLC explores separately (`either ... or ...`):

- **Parent:** the parent handlers run (unlock what prepare locked), and everything continues.
- **Child:** `world := "child"`, and the child handlers run (reset the pool / gang state, drop
  waiters). From then on only these processes may take steps:
  - the forking thread;
  - worker processes that the child itself starts later (`CWorker`, `CBgMember`, `CFgMember`).

  Every other process's steps begin with `await Alive(self)` (or `Alive("<id>")`), which is false
  in the child, so they are frozen mid-step, as threads that no longer exist. **Every** step of a
  process or procedure that a fork can freeze needs the guard. The first draft left it off `Reap`'s
  later steps, `L_Late`, `U_Next`, `U_Assert` and `U_Handoff`, so a dead mutator could finish a
  join and trip the closing assert inside a host's child (fixed in the review).

Invariants then speak about the child's state: stranded jobs, held locks, work held by dead
threads.

### 4.3 Abstractions

| Real thing | Model | Why sound |
|---|---|---|
| Pool with 1..64 workers | 1 parent worker, 1 child worker | One worker exhibits every window. Two add only reordering, which is a deep configuration |
| Job bodies (`madvise`) | `skip` (M6a) | M6 checks lifecycle, not effects (M7 does effects) |
| `PageWork` slots | `Jobs = {"j1","j2"}` owned by the mutator | the mutator posts only Idle jobs and waits only on non-Idle ones, as `takeSlot` / `awaitSlot` do |
| Every thread that posts or waits (the mutator; a `GCMarkGang` member in a pause, via `acquireOldGenBlock`, §2.1) | one process `Mutator` holding `tm` | all of them hold `thread_mutex_`, which serialises them, and the pool does not look at the caller. A host fork cannot in fact land while a gang member holds `tm` once the mark gang's prepare is registered (it waits out the run); the model allows it anyway, an over-approximation |
| `W_Done`: the `Done` store and `--outstanding_` in one `m_` section | one step | the only reader outside `m_` (the acquire fast path) reads the state alone, and after the `Done` store the worker touches no job field (`:219-220`), so a reap and re-post between the two writes is invisible |
| `reapBackground`'s hint: `running()` then `finishedApprox()` (two acquire loads, `:4510`) | one step `RP_Hint` | between launches `running` only falls and `finished` only rises, so every outcome of the split reads (return early, or join) is an outcome of the merged read |
| `launchBackground`'s writes before `launch` (`bg_ctl_` replaced, `bg_ep_ = Running`, `:4459-4466`) | inside `L_Lock` | `bg_ep_` is mutator-owned, and no member can read the old control: the previous episode was joined, and `stopAndJoin` checks `running_` before touching `stop_` |
| The marker loop | procedure `Mark()`: take an entry into the ring, scan it; on stop, scan the ring and leave; `done` iff no work anywhere | M2's contract (Drain, parent plan §5.0); M2 checks it |
| `SliceControl` | `ctl = [stop, done]`, replaced at each launch | each launch creates a fresh control (`launchBackground`) |
| Background gang with B members | B = 1 | stop/join/finished semantics are per member; B = 2 is a deep configuration |
| The mark gang's `m_`, generation | `fgGo` (run started) and `runM` | the member count is fixed; only `run_m_` interacts with fork |
| Two background gangs (5c and 7c) | one (the `two_gangs` configuration duplicates it) | `stopAllForFork` loops over instances, and each is independent |
| `running_` / `finished_pub_` atomics | plain variables | written under `m_` except where the mutant moves them; read without `m_` by `stopAllForFork`, `reapBackground` and `tenureJoin` |
| The background gang's `cv_done_` waiters (the owner's `join`, a foreign `stopAndJoin`) | `await finished >= 1` (no waiter set) | the code notifies all under `m_` (`:594`); a regression to `notify_one` would lose one of two waiters, and this abstraction cannot see it (§5) |
| `exit()` | the mutator only (`ExitGangs` at `U_MaybeFork`; `exit` does not return) | the supported callers (§2.7). A foreign `exit()` while a mutator runs is out of scope |

### 4.4 Constants

| Constant | Module | Meaning | Values |
|---|---|---|---|
| `Forker` | both | who calls `fork()` | `"mut"` (supported), `"host"` (another thread) |
| `ForkAllowed` | both | fork happens (once) | TRUE/FALSE |
| `ChildUsesPool` | M6a | the host's child waits on a slot: its PageWork use, or its `exit()` (`~Allocator` drains) | FALSE in every quick configuration (no property reads the child host's progress); TRUE for the fork harness's trace |
| `Jobs` | M6a | PageWork slots | `{"j1","j2"}` |
| `MaxOps` | M6a | mutator operations | 2–4 |
| `FIX` | M6a | candidate CR-003 fixes | `"none"`, `"drain_under_lock"`, `"post_under_lock_and_drain"` |
| `ExitAllowed` | M6b | the mutator may call `exit()` between pauses (`stopAllAtExit`) | TRUE/FALSE |
| `Work0` | M6b | grey entries at launch | 2 |
| `Steps` | M6b | minor ends before closing | 1–2 |
| `MaxGen` | M6b | launches (relaunches) bound; never binding, since each relaunch needs a stop and there is at most one fork | 3 |
| `PrepareOrder` | M6b | `"bg_first"` / `"mark_first"` (§2.4) | both |
| `MUTANT` | both | §5 | M6a: `none`, `lost_wakeup`, `wait_no_recheck`, `no_dequeue`, `no_start`; M6b: `none`, `running_after_notify`, `join_no_wait`, `no_stop_in_prepare`, `run_no_wait`, `join_in_run` |

### 4.5 Variables

| Variable | Module | Code counterpart |
|---|---|---|
| `world` | both | parent or child address space |
| `m` | M6a | `GCHelperPool::m_` (holder) |
| `tm` | M6a | `Allocator::thread_mutex_` (holder) |
| `queue`, `outstanding`, `started` | M6a | `head_`/`tail_`, `outstanding_`, `started_` |
| `jstate` | M6a | `HelperJob::state` per job |
| `doneWaiters` | M6a | threads blocked on `cv_done_` |
| `runs` | M6a | ghost: runs of each job since its last post (`PoolRunOnce`) |
| `reg`, `bm`, `runM` | M6b | registry mutex, gang `m_`, mark gang `run_m_` (holders) |
| `running`, `gen`, `finished` | M6b | `running_`, `generation_`, `finished_` |
| `joinedGen` | M6b | ghost: the generation the last join returned for (`LJ_RunningExact`) |
| `ctl` | M6b | the episode's `SliceControl` (`stop`, `done`) |
| `work`, `held[p]` | M6b | entries in deques; entries in participant p's ring |
| `bgEp` | M6b | `OldGenSpace::bg_ep_` |
| `fgGo` | M6b | the closing run started / its member finished |
| `exited` | M6b | `stopAllAtExit` returned on the mutator's `exit()` (teardown follows) |

### 4.6 The PlusCal sketches

Files: `test/tla/M6-lifecycle/HelperPool.tla` and `Gangs.tla`. This is the text that passed the
translator and SANY (tla2tools 1.8.0) after the adversarial review of 2026-09-28; the generated
translations are omitted.

**M6a — HelperPool.tla**

```tla
----------------------------- MODULE HelperPool -----------------------------
(***************************************************************************)
(* M6a: GCHelperPool (runtime/src/allocator/GCHelperPool.cpp): the job     *)
(* state machine, post / worker / wait, and the pthread_atfork handlers,   *)
(* with fork() taken either by the mutator or by another ("host") thread.  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Jobs,            \* job objects the mutator owns (PageWork's slots)
    Forker,          \* "mut" = the mutator forks; "host" = another thread forks
    ForkAllowed,     \* the forker may call fork() once
    ChildUsesPool,   \* the child's thread uses PageWork, or calls exit() (~Allocator drains)
    MaxOps,          \* bound on the mutator's operations
    FIX,             \* "none", "drain_under_lock", "post_under_lock_and_drain"
    MUTANT           \* "none", "lost_wakeup", "wait_no_recheck", "no_dequeue", "no_start"

ForkerId == IF Forker = "mut" THEN "mut" ELSE "host"
PWorkers == {"w1"}            \* parent pool workers (threads_ = 1)
CWorkers == {"cw1"}           \* workers the child starts at its first post
Range(sq) == {sq[i] : i \in 1..Len(sq)}

(* --algorithm HelperPool
variables
    world       = "parent",   \* "child" after the fork step takes the child branch
    m           = "none",     \* holder of GCHelperPool::m_
    tm          = "none",     \* holder of Allocator::thread_mutex_ (no atfork handler)
    queue       = <<>>,       \* head_ / tail_ (FIFO)
    outstanding = 0,          \* outstanding_
    started     = FALSE,      \* started_ (workers are started lazily at a post)
    jstate      = [x \in Jobs |-> "Idle"],   \* HelperJob::state
    doneWaiters = {},         \* threads blocked in cv_done_.wait
    runs        = [x \in Jobs |-> 0];      \* ghost: runs since the job's last post

define
    \* A thread runs in the parent, or in the child if it is the forking thread
    \* (or a worker the child started).
    Alive(p) == \/ world = "parent" /\ p \notin CWorkers
                \/ world = "child" /\ (p = ForkerId \/ p \in CWorkers)
    \* No job is Posted or Running in the child unless it is still queued: the
    \* child's workers can only run queued jobs (CR-003).
    ChildNoStranded ==
        world = "child" =>
            \A x \in Jobs : jstate[x] \in {"Posted", "Running"} => x \in Range(queue)
    \* PoolJob (provided to M7): a post is run at most once, and a job that
    \* is Running or Done was run exactly once since its post.
    PoolRunOnce ==
        \A x \in Jobs : runs[x] <= 1 /\ (jstate[x] \in {"Running", "Done"} => runs[x] = 1)
    \* No mutex is held in the child by a thread that does not exist there.
    ChildLocksFree ==
        world = "child" => (m \in {"none", ForkerId} /\ tm \in {"none", ForkerId})
end define;

\* The fork: the prepare handler, then either the parent or the child branch.
procedure DoFork()
begin
  F_Drain:                        \* atforkPrepare: drain() = cv_done_.wait(outstanding_ == 0)
    if FIX # "none" then           \* candidate fix: drain and keep m_ in ONE section
        await m = "none" /\ outstanding = 0;
        m := self;
        goto F_Fork;
    else                           \* as built: drain, release m_ ...
        await m = "none" /\ outstanding = 0;
    end if;
  F_Lock:                          \* ... then m_.lock() separately (the CR-003 window)
    await m = "none";
    m := self;
  F_Fork:
    either                         \* parent: atforkParent unlocks m_
        m := "none";
    or                             \* child: only the forking thread exists; atforkChild
        world := "child";          \* re-creates m_ / the condvars and forgets the queue
        m := "none";
        queue := <<>>;
        outstanding := 0;
        started := FALSE;
        doneWaiters := {};
    end either;
  F_Ret:
    return;
end procedure;

\* wait(job) followed by PageWork::reap -> resetForReuse (Done -> Idle).
procedure WaitAndReap(wj)
begin
  WR_Load:                         \* state.load(acquire) outside the lock
    await Alive(self);
    if jstate[wj] = "Done" then goto WR_Reap; end if;
  WR_Lock:                         \* lock m_, check the predicate under it
    await Alive(self) /\ m = "none";
    if jstate[wj] = "Done" then goto WR_Reap;   \* true: unlock and return
    else m := self;                \* false: m_ stays held until the wait blocks
    end if;
  WR_Block:                        \* cv_done_.wait: join the waiters AND release m_
    await Alive(self);
    doneWaiters := doneWaiters \cup {self};
    m := "none";
  WR_Blocked:                      \* woken by notify_all, then re-lock and re-check
    await Alive(self) /\ self \notin doneWaiters;
    if MUTANT = "wait_no_recheck" then goto WR_Reap;   \* mutant: cv_done_.wait(lk), no predicate
    else goto WR_Lock;
    end if;
  WR_Reap:                         \* invariant WaitSeesDone holds here
    await Alive(self);
    jstate[wj] := "Idle";
    return;
end procedure;

\* The mutator: posts at the pause-end sync point and waits in onReuse /
\* takeSlot, always under thread_mutex_ (HEAP_058). It may itself fork
\* between pauses (Forker = "mut").
fair process Mutator = "mut"
variables j = "none", n = 0, forked = FALSE;
begin
  M_Loop:
    while n < MaxOps do
      M_Choose:
        await Alive("mut");
        either                                         \* post(job)
            await tm = "none" /\ \E x \in Jobs : jstate[x] = "Idle";
            tm := "mut";
            with x \in {y \in Jobs : jstate[y] = "Idle"} do j := x; end with;
          M_PostCas:                                   \* CAS Idle -> Posted, outside m_
            await Alive("mut");
            if FIX = "post_under_lock_and_drain" then
                await m = "none";                      \* fix: the CAS moves under m_
                jstate[j] := "Posted";
                runs[j] := 0;
                if ~started then started := TRUE; end if;
                queue := Append(queue, j);
                outstanding := outstanding + 1;
                goto M_PostDone;
            else
                jstate[j] := "Posted";
                runs[j] := 0;
            end if;
          M_PostQ:                                     \* under m_: start, enqueue, ++outstanding
            await Alive("mut") /\ m = "none";
            if ~started /\ MUTANT # "no_start" then started := TRUE; end if;
            queue := Append(queue, j);
            outstanding := outstanding + 1;
          M_PostDone:                                  \* notify_one (implicit); unlock thread_mutex_
            await Alive("mut");
            tm := "none";
            j := "none";
        or                                             \* awaitSlot: wait for a job, reap it
            await tm = "none" /\ \E x \in Jobs : jstate[x] # "Idle";
            tm := "mut";
            with x \in {y \in Jobs : jstate[y] # "Idle"} do j := x; end with;
          M_Wait:
            call WaitAndReap(j);
          M_WaitDone:
            await Alive("mut");
            tm := "none";
            j := "none";
        or                                             \* fork between pauses
            await Forker = "mut" /\ ForkAllowed /\ ~forked /\ tm = "none";
            forked := TRUE;
            call DoFork();
        end either;
      M_Next:
        await Alive("mut");
        n := n + 1;
    end while;
end process;

\* Another thread (an embedding host) that may fork, and whose child may go
\* on using the pool through PageWork (takeSlot waits for the oldest slot).
fair process Host = "host"
variables hj = "none";
begin
  H_Fork:
    if Forker = "host" /\ ForkAllowed then
        call DoFork();
    end if;
  H_Child:                                             \* only a host that forked exists in the child
    if world = "child" /\ ChildUsesPool /\ Forker = "host" then
      H_Tm:                                            \* first Allocator call, or ~Allocator at exit()
        await tm = "none";
        tm := "host";
      H_Pick:
        if \E x \in Jobs : jstate[x] # "Idle" then
            with x \in {y \in Jobs : jstate[y] # "Idle"} do hj := x; end with;
          H_Wait:
            call WaitAndReap(hj);
        end if;
      H_Unlock:
        tm := "none";
    end if;
end process;

\* Parent pool workers (workerLoop).
fair process Worker \in PWorkers
variables cur = "none";
begin
  W_Loop:
    while TRUE do
      W_Take:                      \* cv_work_.wait(head_ || stopping_), dequeue, Running
        await world = "parent" /\ m = "none" /\ started /\ queue # <<>>;
        cur := Head(queue);
        if MUTANT # "no_dequeue" then queue := Tail(queue); end if;
        jstate[cur] := "Running";  \* the code aborts unless Posted (:211-213)
        runs[cur] := runs[cur] + 1;
      W_Run:                       \* runJob: the body (madvise), no lock
        await world = "parent";
        skip;
      W_Done:                      \* under m_: Done (release), --outstanding
        if MUTANT = "lost_wakeup" then
            await world = "parent";            \* mutant: written without taking m_
        else
            await world = "parent" /\ m = "none";
        end if;
        jstate[cur] := "Done";
        outstanding := outstanding - 1;
      W_Notify:                    \* cv_done_.notify_all() outside the lock
        await world = "parent";
        doneWaiters := {};
        cur := "none";
    end while;
end process;

\* Workers the child starts at its first post (started_ was reset).
fair process CWorker \in CWorkers
variables ccur = "none";
begin
  C_Loop:
    while TRUE do
      C_Take:
        await world = "child" /\ m = "none" /\ started /\ queue # <<>>;
        ccur := Head(queue);
        queue := Tail(queue);
        jstate[ccur] := "Running";
        runs[ccur] := runs[ccur] + 1;
      C_Done:
        await world = "child" /\ m = "none";
        jstate[ccur] := "Done";
        outstanding := outstanding - 1;
      C_Notify:
        doneWaiters := {};
        ccur := "none";
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION

-----------------------------------------------------------------------------
\* Liveness (parent): every posted job is eventually Done or reaped.
ParentJobsFinish ==
    \A x \in Jobs : (world = "parent" /\ jstate[x] = "Posted")
                        ~> (jstate[x] \in {"Done", "Idle"} \/ world = "child")
\* PoolJob (provided to M7): wait() returns only when the job is Done.
WaitSeesDone == \A p \in {"mut", "host"} : pc[p] = "WR_Reap" => jstate[wj[p]] = "Done"
\* Liveness: the mutator finishes its operations (fails under lost_wakeup).
MutatorProgress == <>(world = "child" \/ pc["mut"] = "Done")
=============================================================================
```

**M6b — Gangs.tla**

```tla
-------------------------------- MODULE Gangs --------------------------------
(***************************************************************************)
(* M6b: GCBackgroundGang (launch / join / stopAndJoin / running /          *)
(* finishedApprox), the 5c episode driver that uses it (reapBackground,    *)
(* the relaunch after a stop, closingFinish over GCMarkGang::run), the     *)
(* atfork prepare handlers in either registration order, with fork() by    *)
(* the mutator or by another thread, and stopAllAtExit on the mutator's    *)
(* own exit(). The marker loop itself is M2's: here it is its contract.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Forker,          \* "mut" or "host"
    ForkAllowed,     \* the forker may fork once
    PrepareOrder,    \* "bg_first" (mark gang registered first) or "mark_first"
    ExitAllowed,     \* the mutator may call exit() between pauses (stopAllAtExit)
    Work0,           \* grey entries at launch
    Steps,           \* minor ends before the closing step (runCycleStepConcurrent)
    MaxGen,          \* bound on launches (never binding: each relaunch needs a stop)
    MUTANT           \* "none", "running_after_notify", "join_no_wait", "no_stop_in_prepare",
                     \* "run_no_wait", "join_in_run"

ForkerId == IF Forker = "mut" THEN "mut" ELSE "host"
ParentParts == {"mut", "bg1", "fg1"}     \* marker-loop participants in the parent
ChildParts  == {"mut", "cbg1", "cfg1"}   \* ... in a child forked by the mutator

(* --algorithm Gangs
variables
    world    = "parent",
    exited   = FALSE,          \* stopAllAtExit returned (the mutator is exiting)
    reg      = "none",         \* bgRegistryMutex()
    bm       = "none",         \* GCBackgroundGang::m_
    runM     = "none",         \* GCMarkGang::run_m_
    running  = FALSE,          \* GCBackgroundGang::running_ (atomic)
    gen      = 0,              \* generation_
    joinedGen = 0,             \* ghost: the generation the last join returned for
    finished = 0,              \* finished_ (members = 1)
    ctl      = [stop |-> FALSE, done |-> FALSE],   \* the episode's SliceControl
    work     = Work0,          \* grey entries in the deques
    held     = [p \in ParentParts \cup ChildParts |-> 0],   \* entries in a ring
    bgEp     = "None",         \* OldGenSpace::bg_ep_ (mutator-owned)
    fgGo     = FALSE;          \* the closing run started the mark gang's member

define
    Parts == IF world = "parent" THEN ParentParts ELSE ChildParts
    Alive(p) == \/ world = "parent" /\ p \in ParentParts \cup {"host"}
                \/ world = "child"  /\ (p = ForkerId \/ (Forker = "mut" /\ p \in ChildParts))
    \* LaunchJoin (parent plan 5.0), the parts SC can check (4.9).
    \* LJ1: running() = FALSE => every live member is parked: a join returns
    \* only after the member returned, and a launch sets running_ in the same
    \* critical section as generation_.
    LJ_JoinExact == ~running => /\ (pc["bg1"] = "B_Wait" \/ ~Alive("bg1"))
                                /\ (pc["cbg1"] = "CB_Wait" \/ ~Alive("cbg1"))
    \* LJ2: in the parent, running() is TRUE exactly from a launch to its join.
    LJ_RunningExact == world = "parent" => (running <=> joinedGen # gen)
    \* LJ1 for GCMarkGang::run: outside a run by the mutator, its members are parked.
    LJ_RunJoined == runM # "mut" => /\ (pc["fg1"] = "FG_Wait" \/ ~Alive("fg1"))
                                    /\ (pc["cfg1"] = "CF_Wait" \/ ~Alive("cfg1"))
    \* A child forked by the MUTATOR continues the heap: nothing may be lost.
    ChildHeapSafe == (world = "child" /\ Forker = "mut") => \A p \in ParentParts : held[p] = 0
    \* The same check for ANY forker: expected to fail for a host fork (the
    \* CR-004 window), which is harmless only because that child has no mutator.
    ChildHeldAny == world = "child" => \A p \in ParentParts : held[p] = 0
    \* closingFinish's assert(bg_ep_ == Finished) (OldGenSpace.cpp:4599).
    ClosingFinished == pc["mut"] = "U_Assert" => bgEp = "Finished"
    \* The handoff: no entry held in any ring (IM15 at the handoff).
    HandoffClean == pc["mut"] = "U_Handoff" => \A p \in Parts : held[p] = 0
    \* After stopAllAtExit no background member is inside an episode.
    ExitSafe == exited => pc["bg1"] = "B_Wait"
end define;

\* The marker loop reduced to M2's contract: take entries into the ring, scan
\* them; a stop scans the ring and leaves without done; done iff no work.
procedure Mark()
begin
  K_Step:
    await Alive(self);
    if ctl.stop then
        held[self] := 0;               \* ring scanned, private work published
        return;
    elsif held[self] > 0 then
        held[self] := held[self] - 1;  \* scan one entry
    elsif work > 0 then
        work := work - 1;              \* take one entry into the ring
        held[self] := 1;
    elsif ~ctl.done /\ \A p \in Parts : held[p] = 0 then
        ctl.done := TRUE;              \* termination (M2: done iff no work anywhere)
        return;
    elsif ctl.done then
        return;
    end if;
  K_Again:
    goto K_Step;
end procedure;

\* GCBackgroundGang::launch: under m_, set fn / ctl, finished = 0, ++generation,
\* running_ = true (inside the lock, before notify_all).
procedure Launch()
begin
  L_Lock:
    await Alive(self) /\ bm = "none" /\ gen < MaxGen;
    assert ~running;                   \* launch(): poolAbort("already running")
    gen := gen + 1;
    finished := 0;
    ctl := [stop |-> FALSE, done |-> FALSE];
    bgEp := "Running";
    if MUTANT # "running_after_notify" then
        running := TRUE;
        return;
    end if;
  L_Late:                              \* mutant: running_ stored after notify_all
    await Alive(self);
    running := TRUE;
    return;
end procedure;

\* reapBackground(wait): join (exact publication), then Finished / None.
procedure Reap(wait)
begin
  RP_Check:
    await Alive(self);
    if bgEp # "Running" then return; end if;
  RP_Hint:                             \* !wait && running() && !finishedApprox(): return
    await Alive(self);                 \* two acquire loads; merged (monotone, 4.3)
    if ~wait /\ running /\ finished < 1 then return; end if;
  RP_Join:                             \* join(): under m_; if !running_ return
    await Alive(self) /\ bm = "none";
    if running then
        if MUTANT = "join_no_wait" then
            running := FALSE;          \* mutant: joinLocked does not wait
            joinedGen := gen;
        else
          RP_JoinWait:                 \* cv_done_.wait(finished_ >= members) releases m_
            await Alive(self) /\ bm = "none" /\ finished >= 1;
            running := FALSE;
            joinedGen := gen;
        end if;
    end if;
  RP_Set:
    await Alive(self);
    bgEp := IF ctl.done THEN "Finished" ELSE "None";
    return;
end procedure;

\* GCBackgroundGang::stopAndJoin (from stopAllForFork / stopAllAtExit).
procedure StopAndJoin()
begin
  SJ_Lock:
    await Alive(self) /\ bm = "none";
    if ~running then return;
    else ctl.stop := TRUE;             \* stop_->store(true), then wait (releases m_)
    end if;
  SJ_Wait:
    if MUTANT = "join_no_wait" then
        await Alive(self) /\ bm = "none";
    else
        await Alive(self) /\ bm = "none" /\ finished >= 1;
    end if;
    running := FALSE;
    joinedGen := gen;
    return;
end procedure;

\* The prepare handlers in reverse registration order (PrepareOrder; the
\* pool's runs last and is M6a), fork, then the parent or the child branch.
procedure ForkGangs()
begin
  G_Mark1:                             \* GCMarkGang::atforkPrepare first (mark_first)
    if PrepareOrder = "mark_first" then
        await runM = "none";
        runM := self;
    end if;
  G_Reg:                               \* bg atforkPrepare: bgRegistryMutex().lock()
    await reg = "none";
    reg := self;
  G_Stop:                              \* stopAllForFork: if (g->running()) stopAndJoin
    if running /\ MUTANT # "no_stop_in_prepare" then call StopAndJoin(); end if;
  G_LockM:                             \* then hold every g->m_ (CR-004 window before this)
    await bm = "none";
    bm := self;
  G_RunM:                              \* GCMarkGang::atforkPrepare last (bg_first)
    if PrepareOrder = "bg_first" then
        await runM = "none";
        runM := self;
    end if;
  G_Fork:
    either                             \* parent: the parent handlers unlock
        bm := "none"; runM := "none"; reg := "none";
    or                                 \* child: atforkChild re-inits both gangs
        world := "child";
        running := FALSE; finished := 0;
        bm := "none"; runM := "none"; reg := "none";
        fgGo := FALSE;
    end either;
  G_Ret:
    return;
end procedure;

\* stopAllAtExit, run by exit() on the calling thread (the mutator).
procedure ExitGangs()
begin
  X_Reg:
    await reg = "none";
    reg := self;
  X_Stop:
    call StopAndJoin();
  X_Done:
    reg := "none";
    exited := TRUE;
    return;
end procedure;

\* The heap's mutator: t0 launch, Steps minor ends (reap; relaunch after a
\* stop), then closingFinish, then the handoff. Between pauses it may fork
\* (Forker = "mut") or call exit(), which does not return.
fair process Mutator = "mut"
variables k = 0, forked = FALSE;
begin
  U_Launch:
    call Launch();
  U_Steps:
    while k < Steps do
      U_MaybeFork:                     \* between pauses: fork, exit, or neither
        await Alive("mut");
        either
            await Forker = "mut" /\ ForkAllowed /\ ~forked;
            forked := TRUE;
            call ForkGangs();
        or
            await ExitAllowed;
            call ExitGangs();
        or
            skip;
        end either;
      U_Reap:
        await Alive("mut");
        if exited then goto U_Exit;    \* exit() never returns to the program
        else call Reap(FALSE);
        end if;
      U_Relaunch:                      \* runCycleStepConcurrent: stopped -> relaunch
        await Alive("mut");
        if bgEp = "None" /\ work > 0 then
            call Launch();
        elsif bgEp = "None" then
            bgEp := "Finished";
        end if;
      U_Next:
        await Alive("mut");
        k := k + 1;
    end while;
  U_Close:                             \* closingFinish: reapBackground(false)
    call Reap(FALSE);
  U_CloseRun:
    await Alive("mut");
    if bgEp = "Running" then
      U_RunLock:                       \* GCMarkGang::run(n = 2) takes run_m_
        await Alive("mut") /\ runM = "none";
        runM := "mut";
        fgGo := TRUE;                  \* member 1 starts (generation, notify)
      U_Mark:                          \* the mutator is member 0 (a closing Member)
        call Mark();
      U_FgWait:                        \* cv_done_.wait(finished_ == n - 1)
        await Alive("mut") /\ (~fgGo \/ MUTANT = "run_no_wait");
        if MUTANT # "join_in_run" then runM := "none"; end if;
      U_Reap2:                         \* reapBackground(true)
        call Reap(TRUE);
      U_Assert:                        \* closingFinish's assert: invariant ClosingFinished
        await Alive("mut");
        if MUTANT = "join_in_run" then runM := "none"; end if;   \* mutant: join inside the run
    end if;
  U_Drain:                             \* a stopped episode left work: runMarkers drain
    await Alive("mut");
    if work > 0 then work := 0; end if;
  U_Handoff:                           \* invariant HandoffClean is evaluated here
    await Alive("mut");
    skip;
  U_Exit:
    skip;
end process;

\* The background member (GCBackgroundGang::memberLoop), parent only.
fair process BgMember = "bg1"
variables seen = 0;
begin
  B_Wait:                              \* cv_start_.wait(stopping_ || generation_ != seen)
    await Alive("bg1") /\ bm = "none" /\ gen # seen;
    seen := gen;
  B_Run:
    call Mark();
  B_Fin:                               \* under m_: ++finished_, publish, notify cv_done_
    await Alive("bg1") /\ bm = "none";
    finished := finished + 1;
    goto B_Wait;
end process;

\* The mark gang's member 1 (GCMarkGang::memberLoop) during the closing run.
fair process FgMember = "fg1"
begin
  FG_Wait:
    await Alive("fg1") /\ fgGo;
  FG_Run:
    call Mark();
  FG_Fin:
    await Alive("fg1");
    fgGo := FALSE;                     \* ++finished_ == n - 1: notify the caller
    goto FG_Wait;
end process;

\* Threads the child restarts lazily (startThreadsLocked) when the child's
\* mutator relaunches or runs the closing join.
fair process CBgMember = "cbg1"
variables cseen = 0;
begin
  CB_Wait:
    await world = "child" /\ Forker = "mut" /\ bm = "none" /\ gen # cseen /\ running;
    cseen := gen;
  CB_Run:
    call Mark();
  CB_Fin:
    await bm = "none";
    finished := finished + 1;
    goto CB_Wait;
end process;

fair process CFgMember = "cfg1"
begin
  CF_Wait:
    await world = "child" /\ Forker = "mut" /\ fgGo;
  CF_Run:
    call Mark();
  CF_Fin:
    fgGo := FALSE;
    goto CF_Wait;
end process;

\* Another thread (an embedding host, or a second heap's mutator) that may fork.
fair process Host = "host"
begin
  H_Act:
    either
        await Forker = "host" /\ ForkAllowed;
        call ForkGangs();
    or
        skip;
    end either;
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION
-----------------------------------------------------------------------------
\* Liveness (parent): the mutator reaches the handoff or exits.
ParentProgress == [](world = "parent") => <>(pc["mut"] = "Done")
=============================================================================
```

**Two translator notes found while writing these** (for the primer's §2 list):
- In a process declared `process P = "id"`, this translator does **not** substitute `self` in the
  process body. SANY then reports `Unknown operator: 'self'`, so write the literal id
  (`Alive("mut")`). Procedures are fine, because they take `self` as a parameter.
- Any spec with a procedure must `EXTENDS Sequences`, since the translation keeps the call stack as
  a sequence (`Head`/`Tail`).

### 4.7 Labels to code

| Label(s) | Code (`GCHelperPool.cpp` unless noted) | Atomic operation |
|---|---|---|
| `M_Choose` (post branch), `M_PostCas` | 149-157 | take `thread_mutex_` (caller); CAS Idle→Posted |
| `M_PostQ` | 169-176 | the `m_` critical section: start workers, enqueue, `++outstanding` |
| `M_PostDone` | 177; caller | notify (implicit); release `thread_mutex_` |
| `WR_Load` | 238-239; `GCHelperPool.hpp:57` (`isDone`, from `PageWork::reapDone`) | `state.load(acquire)` **outside `m_`** |
| `WR_Lock`, `WR_Block`, `WR_Blocked` | 243-247 | `cv_done_.wait(lk, Done)`: lock and check; join the waiters and unlock; wake, re-lock |
| `WR_Reap` | `PageWork.cpp:76-95`, `.cpp:58-63` | `reap` → `resetForReuse` |
| `W_Take` | 203-215 | `cv_work_.wait`, dequeue, `Running` (under `m_`) |
| `W_Run` | 216 | `runJob` (no lock) |
| `W_Done`, `W_Notify` | 217-221, 222 | `Done` (release) + `--outstanding` under `m_`; `notify_all` outside |
| `F_Drain`, `F_Lock` | 260-265 | `drain()` critical section; then `m_.lock()` |
| `F_Fork` | 267-287 | parent / child handlers |
| `L_Lock` (`Launch`) | 599-616; `OldGenSpace.cpp:4459-4467` | `launch`'s `m_` section (`running_` inside it), plus the mutator-owned writes just before it |
| `RP_Hint`, `RP_Join`, `RP_JoinWait`, `RP_Set` | `OldGenSpace.cpp:4505-4526`; `.cpp:622-636` | `reapBackground`; `join`; `joinLocked`'s wait |
| `SJ_Lock`, `SJ_Wait` | 638-643, 622-630 | `stopAndJoin` |
| `G_Reg`, `G_Stop`, `G_LockM` | 664-669, 650-657 | bg prepare |
| `G_Mark1` / `G_RunM` | 458-464 | mark gang prepare (`run_m_`), first or last by `PrepareOrder` |
| `G_Fork` | 466-482, 671-690 | parent / child handlers |
| `U_MaybeFork` (exit branch), `X_Reg`, `X_Stop`, `X_Done` | 659-662; `Process.cpp:227-231` | `stopAllAtExit` inside the mutator's `exit()` |
| `B_Wait`, `B_Run`, `B_Fin` | 543-597 | the member loop |
| `U_RunLock` … `U_Assert` | `OldGenSpace.cpp:4569-4600`; `.cpp:407-431` | `closingFinish` over `GCMarkGang::run`; `U_Assert` is where `ClosingFinished` is evaluated |
| `U_Drain`, `U_Handoff` | `OldGenSpace.cpp:4601-4609`; `4308` | the drain after a stop; the handoff (`HandoffClean`) |
| `U_Relaunch` | `OldGenSpace.cpp:4688-4700` | relaunch after a stop |

### 4.8 Properties

Every safety property is a **named invariant**, not an `assert`: an `assert` stops TLC in every
configuration, whatever the configuration lists, while the runner matches invariant names
(parent plan §6.1). The only `assert` left is `L_Lock`'s `~running` (`launch`'s `poolAbort`), which
holds in every configuration and under every mutant (the mutator runs `Launch` sequentially).

| Property | Module | Kind | Meaning | Expected |
|---|---|---|---|---|
| `PoolRunOnce` | M6a | invariant | PoolJob: a post is run at most once; a Running or Done job ran exactly once | holds; fails under `no_dequeue` |
| `WaitSeesDone` | M6a | invariant (defined after the translation: it reads `wj`) | PoolJob: `wait` returns only when the job is Done | holds; fails under `wait_no_recheck` |
| `ParentJobsFinish` | M6a | liveness | PoolJob: every posted job is eventually Done (parent) | holds; fails under `no_start` |
| `MutatorProgress` | M6a | liveness | the `thread_mutex_` holder finishes its operations (no lost wakeup) | holds; fails under `lost_wakeup` |
| `ChildNoStranded` | M6a | invariant | in a child, every Posted/Running job is still queued | holds for `Forker = "mut"`; **fails for `"host"` (CR-003)**; still fails with `drain_under_lock`; holds with `post_under_lock_and_drain` |
| `ChildLocksFree` | M6a | invariant | in a child, `m_` and `thread_mutex_` are free or held by the forker | holds for `"mut"`; **fails for `"host"` (CR-015)** |
| `LJ_JoinExact` | M6b | invariant | LaunchJoin LJ1: `running()` false ⇒ every live background member is parked | holds; fails under `join_no_wait` (and `running_after_notify`) |
| `LJ_RunningExact` | M6b | invariant | LaunchJoin LJ2: in the parent, `running()` is true exactly from a launch to its join | holds; fails under `running_after_notify` |
| `LJ_RunJoined` | M6b | invariant | LaunchJoin LJ1 for `GCMarkGang::run`: outside a run, its members are parked | holds; fails under `run_no_wait` |
| `ChildHeapSafe` | M6b | invariant | a child forked by the mutator holds no entry in a dead thread's ring | holds; fails under `no_stop_in_prepare`; **vacuous** for `Forker = "host"` by definition |
| `ChildHeldAny` | M6b | invariant | the same for any forker | **fails for `"host"`**: documents the CR-004 window (harmless, §2.5) |
| `ClosingFinished` | M6b | invariant | `closingFinish`'s `assert(bg_ep_ == Finished)`, at `U_Assert` | holds without a foreign stop; **fails for a host fork during the closing join (CR-005)** |
| `HandoffClean` | M6b | invariant | no ring entry is held at the handoff | holds; fails under `run_no_wait` with a stop |
| `ExitSafe` | M6b | invariant | after the mutator's `stopAllAtExit`, the member is parked | holds; fails under `join_no_wait` |
| `ParentProgress` | M6b | liveness | no deadlock in the parent: the mutator reaches the end (or exits) | holds for both forkers and both prepare orders; fails under `join_in_run` |
| deadlock | both | TLC's check | **off** (`CHECK_DEADLOCK FALSE`): frozen child threads look like deadlock. `ParentProgress` and `MutatorProgress` stand in for it in the parent | — |

Liveness needs fairness: every process is `fair` (weakly fair), including the hosts. An unfair
host could stop for ever while holding `m_` or a gang's `m_` and fail the liveness properties
spuriously (the first draft's hosts were unfair).

### 4.9 The contracts M6 provides

Both contracts are checked at sequential consistency. **TLA+ at SC cannot check "publishes"**:
every write is visible at once. What SC can check is the ordering: nobody reads the shared state
before the handoff, and nobody writes it after. Publication then rests on the C++ rule that a mutex
unlock synchronises with the next lock of that mutex, except for the three atomic handoffs named
below, which are W/TSan items (§7, A4).

**LaunchJoin** (parent plan §5.0; used by M1, M2, M3 and M5):

| Part | How M6 discharges it |
|---|---|
| LJ1: `join` / `stopAndJoin` / `run` return only after every member returned | `LJ_JoinExact` for the background gang (owner or foreign joiner, parent or child); `LJ_RunJoined` for `GCMarkGang::run` |
| LJ2: in the parent, `running()` is false only after a join, and true from the launch on | `LJ_RunningExact`. In a child, `running()` is false after the reset with no join: that is the orphan state `tenureJoin` tests (`NurseryTenure.cpp:614-615, 631`), and the property deliberately excludes it |
| LJ3: a member starts only for a launched generation, after the launch's writes | by construction: `gen`, `ctl`, `bgEp` and `running` change in the one `L_Lock` step, and a member starts only on `gen # seen` (`B_Wait`) |
| LJ4: a `stopAndJoin` stop is honoured at the member's next item boundary | **an assumption on the job body, not a gang property.** The gang's part is one step (`SJ_Lock`: the stop is stored under `m_` before the wait, `:641`). `Mark()` checks the stop only at `K_Step`, between items; M2 (Drain) owns this for the marker loop and M5 for the tenure engines. A member that took `m_` in `memberLoop` runs its job outside the lock (`:575-588`), so a later lock of `m_` by prepare does not stop it (CR-004, CR-013) |
| "launch / join publish" | launch, join and `run` are `m_` handoffs. **Not** a mutex handoff: `running_` (release at `:612`, `:625`; acquire in `running()`, `GCHelperPool.hpp:258`), which `tenureJoin`'s orphan test relies on with no join. After a foreign `stopAndJoin` the chain is member → `m_` → joiner → `running_` → owner. `finished_pub_` is a hint (every decision still goes through `join`) |

**PoolJob** (used by M7): "a posted job runs exactly once, in any order; `wait` returns only when the
job is Done, and Done publishes the runner's writes to the waiter."

| Part | How M6 discharges it |
|---|---|
| runs at most once per post | `PoolRunOnce` (the code's own guard is the `poolAbort` at `:211-213`) |
| runs at least once, and is eventually Done (parent) | `ParentJobsFinish` |
| `wait` returns only on Done | `WaitSeesDone` |
| in any order | M6 promises no order. The model's queue is FIFO, as the code's is (`:173`); M7 must not rely on it |
| from any waiter | the model's `Mutator` is whichever thread holds `thread_mutex_`, including a `GCMarkGang` member inside a pause (§2.1, §4.3) |
| Done publishes the runner's writes | not checkable at SC. After a stall, `m_` publishes. On the fast path (`wait`'s `:238`, `isDone` at `GCHelperPool.hpp:57`, used by `PageWork::reapDone`), only the release store at `:219` and those acquire loads do: a message-passing assumption, for a W driver `w_pool_done` |
| — in a child forked by another thread | PoolJob does **not** hold there: CR-003 |

## 5. Negative controls

Each mutant configuration lists **only** its target property, so that nothing else can stop TLC
first. "Shortest" is the hand count of the behaviour TLC should report.

| `MUTANT` / `FIX` | Code change | Configuration | Must violate | Shortest behaviour |
|---|---|---|---|---|
| (the code as is) + `Forker = "host"` | — (CR-003) | `host_fork_stranded` | `ChildNoStranded` | host drains; mutator takes `tm` and CASes j to Posted; host locks `m_`; fork, child branch |
| (the code as is) + `Forker = "host"` | — (CR-015) | `host_fork_locks` | `ChildLocksFree` | mutator takes `tm`; host forks (child branch) |
| `FIX = "drain_under_lock"` | drain and keep `m_` in one section | `host_fork_fix_drain` | `ChildNoStranded` (via the CAS window) | mutator CASes j; host drains (0 outstanding) and locks; fork |
| `FIX = "post_under_lock_and_drain"` | + move the CAS under `m_` | `host_fork_fix_both` | nothing (the positive control for the fix) | — |
| `lost_wakeup` | the worker writes Done and `--outstanding` **without `m_`** (the notify still follows) | `pool_basic` | `MutatorProgress` | post; wait: `WR_Lock` sees Running and holds `m`; worker writes Done and notifies nobody; `WR_Block`; stuck |
| `wait_no_recheck` | `cv_done_.wait(lk)` with no predicate | `pool_basic` (`MaxOps` ≥ 3) | `WaitSeesDone` | post j1, post j2, wait on j2; j1's notify wakes it with j2 Posted |
| `no_dequeue` | the worker leaves the job at the head | `pool_basic` | `PoolRunOnce` | post; take; run; Done; take again (`runs` = 2) |
| `no_start` | the first post does not start the workers | `pool_basic` | `ParentJobsFinish` | post; the worker never becomes enabled |
| `running_after_notify` | `launch` stores `running_` after unlock/notify | `episode` | `LJ_RunningExact` | `U_Launch`, `L_Lock` (2 steps). With `LJ_JoinExact` listed instead: one more step (`B_Wait`) |
| `join_no_wait` | `joinLocked` returns without waiting | `episode` | `LJ_JoinExact` | the closing path: `Reap(TRUE)` sets `running` false while the member is in `Mark` or about to start (≈ 30 steps with `Steps = 1`) |
| `join_no_wait` | as above | `exit` | `ExitSafe` | launch; member starts; mutator exits: `SJ_Lock` stops, `SJ_Wait` does not wait; `X_Done` |
| `no_stop_in_prepare` | bg prepare skips `stopAllForFork` | `mut_fork` | `ChildHeapSafe` | launch; member takes an entry; the mutator forks; child branch |
| `run_no_wait` | `GCMarkGang::run` returns without waiting for its members | `episode` | `LJ_RunJoined` | closing run; the mutator marks everything alone and returns; the member then starts |
| `run_no_wait` | as above | `host_fork_safe` | `HandoffClean` | the member takes an entry; a host fork stops the episode; the mutator leaves on the stop and reaches the handoff first |
| `join_in_run` | `closingFinish` calls `reapBackground(true)` before `run` releases `run_m_` | `host_fork_safe` | `ParentProgress` | host holds the gang's `m_` and waits for `run_m_`; the mutator holds `run_m_` and waits for the gang's `m_` (the §1 item 7 chain) |

`decommit delay counted in pause ends` is **not** an M6/M7 mutant. It changes *when* discards are
posted (a policy), never whether one runs under an owner. Plan 03 rejected it for cost, not
safety.

**Not detectable as modelled** (review, 2026-09-28): a `notify_all` → `notify_one` regression on
the background gang's `cv_done_` (`:594`), which has two possible waiters (the owner's `join`
and a foreign `stopAndJoin`). The model's joins are plain `await`s. The smallest change that would
catch it: give the gang's `cv_done_` an explicit waiter set, as `doneWaiters` does for the pool
(`RP_JoinWait`/`SJ_Wait` split into check-and-block + blocked), and add a mutant that wakes one.
Deep tier only, if at all.

## 6. Configurations

Every configuration sets `defaultInitValue = defaultInitValue` and `CHECK_DEADLOCK FALSE`
(§4.8). `ChildUsesPool = FALSE` throughout (§4.4). Unless stated: `Jobs = {"j1","j2"}`,
`Work0 = 2`, `MaxGen = 3`, `PrepareOrder = "bg_first"`, `ExitAllowed = FALSE`, `FIX = "none"`.

| Config | Module | Key constants | Checks | Expected |
|---|---|---|---|---|
| `pool_basic` | M6a | `ForkAllowed = FALSE`, `MaxOps = 4` | `PoolRunOnce`, `WaitSeesDone`; `ParentJobsFinish`, `MutatorProgress` | pass |
| `mut_fork` | M6a | `Forker = "mut"`, `MaxOps = 3` | `ChildNoStranded`, `ChildLocksFree`, `PoolRunOnce`, `WaitSeesDone`; `MutatorProgress` | pass (one mutator only, §2.6) |
| `host_fork_stranded` | M6a | `Forker = "host"`, `MaxOps = 2` | `ChildNoStranded` | **fail (CR-003)** |
| `host_fork_locks` | M6a | as above | `ChildLocksFree` | **fail (CR-015)** |
| `host_fork_fix_drain` | M6a | + `FIX = "drain_under_lock"` | `ChildNoStranded` | **fail** (the CAS window) |
| `host_fork_fix_both` | M6a | + `FIX = "post_under_lock_and_drain"` | `ChildNoStranded` | pass |
| `episode` | M6b | `ForkAllowed = FALSE`, `Steps = 2` | `LJ_JoinExact`, `LJ_RunningExact`, `LJ_RunJoined`, `ClosingFinished`, `HandoffClean`; `ParentProgress` | pass |
| `mut_fork` | M6b | `Forker = "mut"`, `Steps = 1` | as `episode`, + `ChildHeapSafe` | pass |
| `mut_fork_mark_first` | M6b | + `PrepareOrder = "mark_first"` | as `mut_fork` | pass |
| `host_fork_safe` | M6b | `Forker = "host"`, `Steps = 1` | `LJ_JoinExact`, `LJ_RunningExact`, `LJ_RunJoined`, `HandoffClean`; `ParentProgress` | pass (the fork-time deadlock check) |
| `host_fork` | M6b | `Forker = "host"`, `Steps = 1` | `ClosingFinished` | **fail (CR-005)** |
| `host_fork_window` | M6b | `Forker = "host"`, `Steps = 1` | `ChildHeldAny` | **fail** (documents the CR-004 window) |
| `exit` | M6b | `ExitAllowed = TRUE`, `ForkAllowed = FALSE`, `Steps = 2` | `ExitSafe`, `LJ_JoinExact`; `ParentProgress` | pass |
| `host_fork_mark_first` | M6b (deep) | `host_fork` and `host_fork_safe` with `PrepareOrder = "mark_first"` | as those | same verdicts |
| `two_gangs` | M6b (deep) | two gang instances (5c markers, 7c collector) in `stopAllForFork` | as `host_fork_safe` | same verdicts; it adds only the window between stopping gang 1 and gang 2, the same shape as CR-004's |

**Budget.** M6a is a few thousand states per configuration. M6b's largest quick configurations
(`episode` with `Steps = 2`; `host_fork_safe`) interleave three `Mark` loops over two entries plus
the fork's handler steps; the reviewer's estimate is 10^4–10^5 states, well inside the quick tier.
`MaxGen` never binds, and `Steps = 1` suffices for every fork window (one minor end after the stop).

## 7. Accuracy notes (rules A1–A9)

| Rule | M6 |
|---|---|
| A1 | Every `m_`/`run_m_`/registry critical section whose intermediate states nobody else observes is one step. Locks held **across** steps (prepare holds them across the fork; `thread_mutex_` across a post or a wait; `m_` between a waiter's check and its block) are explicit holder variables. Condition waits are check-under-lock, block-and-release, wake-and-re-lock (§2.1). `post`'s CAS is a separate step from its enqueue: the CR-003 fix analysis depends on that. `wait`'s fast path is its own step outside `m_` (`WR_Load`). Three merges are argued in §4.3: `W_Done`'s two writes, `RP_Hint`'s two loads, and `launchBackground`'s mutator-owned writes folded into `L_Lock`. |
| A2 | Job state, `running_`, `finished_pub_`, the generation: whole words. No sub-word sharing. |
| A3 | Census of `GCHelperPool.cpp`/`.hpp` (2026-09-28). **Pool:** `m_`, `cv_work_`, `cv_done_`, `head_`/`tail_`, `outstanding_`, `started_`, `HelperJob::state`/`next` → `m`, `queue`, `outstanding`, `started`, `jstate`, `doneWaiters`; `cv_work_` as an `await`; `configured_` and `mode_` are set once before any post; `stopping_` and `shutdownForTesting` are test-only. **Mark gang:** `run_m_`, `m_`, `cv_start_`, `cv_done_`, `generation_`, `running_n_`, `finished_`, `fn_`/`ctx_` → `runM`, `fgGo` (n fixed). **Background gang:** `m_`, `cv_start_`, `cv_done_`, `generation_`, `finished_`, `finished_pub_`, `running_`, `started_`, `stop_`, `fn_`/`ctx_` → `bm`, `gen`, `finished`, `running`, `ctl.stop`; `tids_` is test-only. **Registry:** `bgRegistryMutex()`, `bgRegistry()`, `bg_hooks_registered` → `reg` (one gang). Outside the file: `Allocator::thread_mutex_` → `tm` (HEAP_058); `OldGenSpace::bg_ep_`, `bg_ctl_` → `bgEp`, `ctl`; 05c P§3.6 H10 (slot state the mutator touches only while no member runs, IM14, which rests on `LJ_JoinExact`) and H13 (`reset` stops the episode first). 05c's table has no row for the gang objects themselves: this census is it. |
| A4 | Mutex handoffs need nothing (unlock synchronises with the next lock). Three atomic handoffs are **assumptions**: (1) `HelperJob::state`'s Done, release at `:219` (inside `m_`) to the acquire loads **outside** `m_` at `:238` and in `isDone` (`GCHelperPool.hpp:57`, from `PageWork::reapDone`): a job's outputs (PageWork's `failures`, the timestamps) reach a fast-path waiter by this pair alone. Proposed W driver **`w_pool_done`**: the runner writes a field and stores Done (release); the waiter's acquire load sees Done and must read the field. (2) `running_`, release at `:612`/`:625` to the acquire in `running()` (`GCHelperPool.hpp:258`): `tenureJoin`'s orphan test acts on `!running()` with no join, and after a foreign `stopAndJoin` the chain crosses three threads (member → `m_` → joiner → `running_` → owner). C11 makes this hold while the orders stay as they are; propose a W driver `w_running_chain`, and at least pin the orders in the canary (A9). (3) `finished_pub_`: a hint only, no W needed. The stop flag's release store (`:641`) is a signal, not a publication. |
| A5 | `gc-helper-tsan` `harness.cpp` **H2/H3** (`script`, `:166-244`) for M6a: one scripted poster under `big_lock`, which stands for `thread_mutex_`, as the model's single `Mutator` does. **H1** (`h1`, `:51-80`: three posters with no common lock, and random drains) is **not** a behaviour of M6a; it would need a variant with a set of posters and no `tm`. `mark_harness.cpp` `bgGangStorm` (`:566-592`) for M6b's launch, stop and join; plus the **fork harness** CR-008 proposes (§8). |
| A6 | §5: every invariant and liveness property has at least one mutant, and the "code as is" host-fork configurations are the negative controls for CR-003/004/005/015. One bug class is not detectable as modelled (`notify_one` on the gang's `cv_done_`, §5). |
| A7 | HEAP_007, HEAP_058, GC_DET_001 (pool half), IM14/IM15 (quiescence and no private work after a join: `LJ_JoinExact`, `HandoffClean`), the `closingFinish` assert (`ClosingFinished`). The model-only properties (`LJ_*`, `PoolRunOnce`, `WaitSeesDone`, `Child*`, `ExitSafe`, the liveness properties) get `MODEL_M6_<k>` aliases in the committed spec, listed in MAPPING.md. |
| A8 | 1 worker, 2 jobs, `MaxOps` 2–4, 1 gang member, 1 fork, 1–2 minor steps, `MaxGen` 3 (never binding). Deep: 2 workers, B = 2, two gangs, `mark_first` host forks. No counter wraps (the generation is 64-bit). |
| A9 | `file`: `GCHelperPool.cpp`, `GCHelperPool.hpp`. `region`: `launchBackground`, `reapBackground`, `stopBackground`, `closingFinish`, the relaunch in `runCycleStepConcurrent`, `~OldGenSpace`, `ensureGang`, `tenureLaunch`'s collector launch, `tenureConcLaunch`, `tenureJoin`, `tenureTeardown`, `Allocator::onGCPauseEnd`, `Allocator::acquireOldGenBlock`'s PageWork calls, `~Allocator`, `atexitPrintStats`. `census`: `OldGenSpace.cpp`, `NurseryTenure.cpp`, `Allocator.cpp`. **Pins** (the A4 assumptions): the memory orders at `GCHelperPool.cpp:219, 238, 612, 625` and `GCHelperPool.hpp:56-57, 258`. **Greps:** `pthread_atfork`, `std::atexit` and `fork(` (three separate patterns; no alternation, which this container's `grep` mishandles) over `runtime/src` and `eco-kernel-cpp` (a new registration or fork site changes §2.4's order or the `Forker` premise). |

## 8. Trace validation

- **Harnesses:**
  - `test/gc-helper-tsan/harness.cpp` H2/H3 for the pool (one poster under `big_lock`; H1 is not
    a behaviour of M6a, §7 A5);
  - `mark_harness.cpp` `bgGangStorm` (launch/stop/join storms) for the gang;
  - **a new fork harness** (register CR-008) for fork. A host thread forks at random moments while
    the mutator posts, relaunches episodes and runs closing joins. The child either records state
    and `_exit`s, or (mutator forks only) continues.
- **Events** (compiled in only with `ECO_TLA_TRACE`):

  | Event | Where | Fields |
  |---|---|---|
  | `post_cas`, `post_enq` | `post` 153, 170-175 | job, `outstanding` after |
  | `take`, `done` | `workerLoop` 207-214, 218-220 | job, `outstanding` |
  | `wait_fast` | `wait` 238, `isDone` (hpp:57) | job, state read (no lock) |
  | `wait_block`, `wait_wake` | `wait` 243-247 | job |
  | `launch`, `member_start`, `member_fin`, `join`, `stop` | `launch`, `memberLoop`, `joinLocked`, `stopAndJoin` | generation, `finished` |
  | `prep_begin`, `prep_end`, `fork_parent`, `fork_child` | each atfork handler | handler name |

- **Ordering:** most events happen under a mutex. Log a per-mutex acquisition counter inside
  each critical section; it totally orders the events of that mutex. The unlocked reads (`wait`'s
  fast path, `isDone`, `running()`, `finishedApprox()`) are not ordered that way: log the value
  read, and let the trace spec place the event at any point consistent with that value.
- **Child traces:** the child writes its own log. The trace spec checks it against the `world =
  "child"` branch.

## 9. Implementation steps

1. Create `test/tla/M6-lifecycle/` with both modules (§4.6), `MC.tla`, the §6 configurations,
   MAPPING.md (§4.7 plus A3's table) and AUDIT.md.
2. `pcal` + `sany` (grep SANY's output for errors: its exit status is 0 either way), then TLC on
   the pass configurations: `pool_basic`, `mut_fork` (both modules), `episode`,
   `mut_fork_mark_first`, `host_fork_safe`, `exit`.
3. Run the expected-failure configurations. For each, record the trace in the register:
   - `host_fork_stranded` → CR-003 Reproduced;
   - `host_fork_locks` → CR-015 Reproduced;
   - `host_fork_fix_drain` → note on CR-003's fix;
   - `host_fork` → CR-005 Reproduced (with M2's `episode_stop`);
   - `host_fork_window` → CR-004 window confirmed. `ChildHeapSafe` holds in `mut_fork` and is
     vacuous for a host fork; with the code-reading argument of §2.5 (the child never marks the
     dead heap, not even at teardown), propose CR-004 → Not-a-bug.
4. Run every §5 mutant; each must fail with its named property and nothing else.
5. Deep: `host_fork_mark_first`, `two_gangs`, 2 workers, B = 2.
6. Wire into `models.txt` and `manifest.txt` (A9).
7. **Resolution work for the register (a code change is not part of this model plan).** The
   modelling result points to one contract, which should be written down:

   > `fork()` without an immediate `exec` (or `_exit`) is supported only from a heap's mutator
   > between pauses, and only while the process has one mutator (§2.6).

   Guard it: the pool's and the gangs' child handlers record whether the forking thread owns each
   live heap, and any later use of a heap the child does not own aborts with a clear message. With
   that guard, CR-003/004 become Won't-fix (guarded) and CR-005's assert is reachable only in an
   unsupported state. The alternative is to fix all three: `post_under_lock_and_drain`, an atfork
   handler for `thread_mutex_`, and making `closingFinish` accept `None` after a fork-stop. The
   model can check either choice.
8. Trace validation (§8) once the fork harness exists.

## 10. Open questions

1. Do other runtime mutexes (PermanentSpace, Scheduler, PortRuntime) need the same treatment as
   `thread_mutex_` under a non-mutator fork? They are outside the GC. The §9 step 7 contract covers
   them all.
2. ~~Can the 7c tenure collector register the gang atfork handlers before `GCMarkGang` in a real
   run?~~ **Answered in the review: yes**, whenever `availableCpus()` is 1 (§2.4). Both orders are in
   the configurations.
3. CR-013's "no mutator in the child" exit does not hold at teardown: a host child that calls
   `exit()` runs `tenureTeardown` on the dead mutator's heap (§2.5). M5 owns the consequence (a
   skipped item in a heap about to be destroyed: harmless unless the teardown itself aborts in a
   validator or waits on a half-published shadow word).

## 11. Adversarial review (2026-09-28)

Against the current tree. Tools run: `pcal -nocfg` and SANY on the corrected sketches (both pass;
SANY's output grepped for errors, and the grep confirmed on a deliberately broken copy). TLC was
not run: every "expected" verdict is a hand simulation.

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | `exit` (expected pass) failed on the code as modelled: the host ran `stopAllAtExit` while the mutator went on, so `ExitSafe` broke (exit before the first launch, or a relaunch after it), and an exit-stop during the closing join tripped the always-on `U_Assert` | exit moved to the mutator, its real caller (§2.7); `running_after_notify` retargeted to `LJ_RunningExact` |
| R2 | Blocker | steps a fork can freeze lacked `Alive` guards (`Reap`'s later steps, `L_Late`, `U_Next`, `U_Assert`, `U_Handoff`; M6a's host in a mutator's child): a dead mutator could finish a join and trip the closing assert inside a host's child | guards added (§4.2) |
| R3 | Major | no property discharged **LaunchJoin**, which M1, M2, M3 and M5 consume | `LJ_JoinExact`, `LJ_RunningExact`, `LJ_RunJoined`; §4.9 states LJ3 (by construction), LJ4 (the job body's obligation) and what "publishes" leaves to W |
| R4 | Major | **PoolJob** (M7's contract) was not stated; no run-once property; waiters assumed to be the mutator | `PoolRunOnce`, `WaitSeesDone` (replaces `WR_Reap`'s assert), `ParentJobsFinish`; the `Mutator` process is any `thread_mutex_` holder, including gang members in a pause (§2.1, §4.3) |
| R5 | Major | the waiter's check-and-block was one step holding no lock, so a writer that skips `m_` (the realistic lost-wakeup regression) could not land between them | `WR_Lock` holds `m`, new `WR_Block`; `lost_wakeup` now writes Done without `m_` |
| R6 | Major | `U_Assert`/`U_Handoff` were `assert`s, which stop TLC in every configuration and could mask `ChildHeldAny` or any mutant's target | invariants `ClosingFinished`, `HandoffClean` (§4.8) |
| R7 | Major | the host processes were not fair: a host stuttering while holding `m_` or the gang's `m_` fails the liveness properties spuriously | both hosts `fair` |
| R8 | Major | `PrepareOrder`, `ParentProgress` and three mutants were "to add"; `ExitSafe`, `ParentProgress` and the mark gang's join had no working mutant | all in the sketch; new mutants `run_no_wait`, `join_in_run` (the §1 item 7 chain), `no_dequeue`, `wait_no_recheck`, `no_start`; every property has one (§5) |
| R9 | Major | several mutators: a second mutator's own fork is a non-mutator fork for every other heap, so the `Forker = "mut"` pass verdicts hold only with one mutator | §2.6; §9 step 7's contract amended |
| R10 | Major | A4 said no W-companion was needed, but Done reaches a fast-path waiter by release/acquire outside `m_` (`:219` → `:238`, `isDone`), and `tenureJoin`'s orphan test acts on `running()` with no join | A4 lists both; W drivers `w_pool_done`, `w_running_chain` proposed; the orders pinned in A9 |
| R11 | Minor | CR-003 can also strand a Running job, and a host child hangs at `exit()` (`~Allocator` drains under `thread_mutex_`); CR-015 likewise | §2.5 |
| R12 | Minor | CR-004's "harmless" argument confirmed, including teardown (`~OldGenSpace` never marks); CR-013's analogue fails at teardown (`tenureTeardown` runs the orphan job) | §2.5, §10 Q3 (M5's) |
| R13 | Minor | CR-005 aborts the parent in the everyday `build` preset (asserts on, `-UNDEBUG`), not only in "assert builds" | §2.5 |
| R14 | Minor | open question 2 answered: with one CPU the background gang registers before the mark gang | §2.4, §10 |
| R15 | Minor | a relaunch can land inside a foreign `stopAndJoin`'s wait, stalling fork prepare for a whole episode (nothing lost) | §2.2 (the model already has it) |
| R16 | Minor | A5 named H1 (three posters, no common lock), which is not a behaviour of M6a | H2/H3 (§7 A5, §8); unlocked reads get their own trace rule |
| R17 | Minor | reference drift: `reapBackground`'s call site (4688), `tenureLaunch` (428, 1234), `tenureJoin`'s range and the default `tenure_help = 1`, "05c H13 (gang objects)", CR-015 missing from the entry list, the header comment on `atexit` registration | §2.2, §2.4, §3, §7 A3, header |
| R18 | Minor | `ChildHeapSafe` is vacuous for a host fork, yet `host_fork` claimed it "holds" | §4.8, §6 |
| R19 | Minor | configurations lacked defaults, carried `ChildUsesPool = TRUE` for no checkable gain, and had no pass configuration for deadlock freedom under a host fork | §6 (`host_fork_safe`, defaults, budget) |
| R20 | Minor | not detectable as modelled: `notify_one` on the gang's `cv_done_` (two possible waiters) | documented with the smallest fix (§5) |
