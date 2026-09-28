# Threaded GC — TLA+ model M6: thread lifecycle, fork and exit

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). The PlusCal sketches in §4.6 pass the PlusCal
translator and SANY (tla2tools 1.8.0). **TLC has not run on them.** The "expected" results in §5
and §6 are predictions from reading the code; the first TLC run confirms or corrects each one.

**Parents:** `plans/threaded-gc-tla-verification.md` (rules A1–A9, §5.0 contracts) and
`plans/threaded-gc-tla-primer.md` (§3.4 locks and condition variables, §3.5 fork). The layout and
depth follow `plans/threaded-gc-tla-M2-slice-control.md`.

**Register entries this model settles:** CR-003, CR-004, CR-005, and the fork part of CR-008
(`plans/threaded-gc-concurrency-register.md`).

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
1. **No lost job:** every job posted to the pool is eventually run and observed Done (parent).
2. **No stranded job in a child:** a child never holds a job that is Posted or Running but that
   no child thread will ever run. That is CR-003.
3. **No lock held by a dead thread in a child:** in the child, no mutex is owned by a thread that
   was not copied.
4. **Join means joined:** `join` and `stopAndJoin` return only after every member finished.
   `running()` is exact for its owner.
5. **Stop leaves recoverable work:** after `stopAndJoin`, all unfinished work is in the deques.
   This is M2's contract (§5.0 of the parent plan), assumed here.
6. **Fork and exit are safe:**
   - a child forked by the mutator continues the heap without losing mark work (CR-004 analysis);
   - the parent survives a fork from another thread during a closing join (CR-005);
   - after `stopAllAtExit` no background member touches the heap.
7. **No deadlock**, including the chain "the forker holds the background gang's `m_` and waits for
   `run_m_`, while the mutator holds `run_m_`".

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

The mutator posts and waits **under `Allocator::thread_mutex_`** (HEAP_058). It posts at the
pause-end sync point, and waits in `acquireOldGenBlock` / `releaseOldGenBlock` through PageWork
(M7). Workers never take `thread_mutex_`.

**How a condition-variable wait is modelled** (primer §3.4). `cv_done.wait(lk, pred)` is:
- check `pred` under the lock;
- if it is false, atomically release the lock and go to sleep;
- when notified, wake, re-take the lock, and check `pred` again.

The model says exactly that:

```tla
WR_Lock:                         \* lock m_, check the predicate
    await Alive(self) /\ m = "none";
    if jstate[wj] = "Done" then goto WR_Reap;
    else doneWaiters := doneWaiters \cup {self};   \* block; wait releases m_
    end if;
WR_Blocked:                      \* woken by notify_all, then re-lock and re-check
    await Alive(self) /\ self \notin doneWaiters;
    goto WR_Lock;
```

`notify_all` is the worker's step `doneWaiters := {}`.
- A **lost wakeup** happens when a notify reaches nobody because the waiter has not blocked yet,
  and the waiter then blocks forever.
- It is impossible in the real code, because Done is written under `m_` *before* the notify. The
  waiter either sees Done when it checks under the lock, or is already in `doneWaiters` when the
  notify clears it.
- The mutant `lost_wakeup` (§5) moves the write after the notify and outside the lock, and TLC must
  then find a waiter stuck forever.

`cv_work`'s wait needs no explicit waiter set: nobody checks its predicate outside the lock. It is
the one-step `await m = "none" /\ queue # <<>>` (primer §3.4).

### 2.2 The background gang (`GCHelperPool.cpp:499-690`)

```
launch(fn, ctx, stop):  lock m_; start threads if needed; set fn/ctx/stop; finished = 0;
                        ++generation; running_ = true (release); unlock; notify_all(cv_start)
member:                 lock m_; wait on cv_start until generation changes; copy fn; unlock
                        fn(ctx, i)                        -- the marker loop (M2) or a tenure job
                        lock m_; ++finished; finished_pub = finished (release); notify cv_done; unlock
join():                 lock m_; if !running_: return; wait on cv_done until finished == members;
                        running_ = false; unlock
stopAndJoin():          lock m_; if !running_: return; *stop = true (release); then as join()
finishedApprox():       finished_pub >= members (acquire), a hint only (GC_DET_001)
```

5c's driver (`OldGenSpace.cpp`) uses it like this:
- `launchBackground` (4431) at the end of the t0 pause;
- at each minor end, `reapBackground(false)` (4505) joins if the members have finished, and records
  the episode as `Finished` (done) or `None` (stopped);
- `runCycleStepConcurrent` (4660) **relaunches** a stopped episode whose work is still in the deques
  (4689-4696);
- `closingFinish` (4569) runs a closing join on the mark gang, then `reapBackground(true)`, then
  asserts `bg_ep_ == Finished` (4599).

7c uses a second `GCBackgroundGang` per heap, the tenure collector:
- `tenureLaunch` (`NurseryTenure.cpp:568/572`) launches it;
- `tenureJoin` (575) joins it or stops it;
- a job whose gang is not running is "stopped by a fork hook", and the next minor finishes it on
  the mutator (`NurseryTenure.cpp:615`, "trap 25").

### 2.3 The mark gang (`GCHelperPool.cpp:327-482`)

`run(fn, ctx, n)` takes `run_m_` (one run at a time), starts members 1..n−1 through a generation
counter, runs member 0 itself, and waits until all have finished. It is used only inside pauses.

### 2.4 The fork handlers

`pthread_atfork(prepare, parent, child)` handlers run their prepare step in **reverse
registration order**, and their parent and child steps in registration order. Registration happens
at first use:

| Class | Registered at | Prepare | Parent | Child |
|---|---|---|---|---|
| `GCHelperPool` | `configure` (109-114), at heap initialize | `drain()`, then `m_.lock()` **as two separate critical sections** (260-265) | unlock `m_` | re-construct `m_`/cvs, forget workers, `head_ = tail_ = nullptr`, `outstanding_ = 0`, `started_ = false` (271-287) |
| `GCMarkGang` | `configure` (337-342), at the first parallel run | lock `run_m_` (waits out a run), lock `m_` (458-464) | unlock both | re-construct, forget threads (472-482) |
| `GCBackgroundGang` | first constructor (505-511), plus `std::atexit(stopAllAtExit)` | lock the registry; `stopAllForFork()` (for each gang: `if running() stopAndJoin()`); then lock every gang's `m_` (664-669) | unlock | re-construct, `running_ = false`, forget threads (676-690) |

The registration order depends on which is used first:
- The pool is always first (heap initialize).
- In a program whose first minors are serial and whose region nursery launches a tenure collector
  early, the background gang can register **before** the mark gang.

So the prepare order is usually "background gang, mark gang, pool", but not always. The model
checks both (constant `PrepareOrder`, §6).

**What the runtime itself does.** The only `fork()` calls are in `eco-kernel-cpp/src/eco/Process.cpp`
(70, 124). They run on the mutator between pauses, and the child immediately `execvp`s. The unit
tests fork between pauses from the mutator and continue in the child. **A fork from another
thread** (an embedding host, e.g. a Node child-process spawn) is the case the handlers were never
designed around. That is where CR-003/004/005 live.

### 2.5 The three windows, as timelines

**CR-003: a post between the drain and the lock.** H is the host thread, M the mutator.

| # | H (forking) | M (mutator) | pool state |
|---|---|---|---|
| 1 | prepare: `drain()` sees `outstanding == 0`, releases `m_` | | queue empty |
| 2 | | pause end: holds `thread_mutex_`; `post(j)`: CAS Idle→Posted, lock `m_`, enqueue, `++outstanding` | j Posted, queued |
| 3 | prepare: `m_.lock()` | | |
| 4 | `fork()`; the child runs `atforkChild`: queue and `outstanding` reset | | **child: j Posted, not queued, no worker will run it** |

In the child, a later `wait(j)` (PageWork's `takeSlot` waiting for its oldest slot) never returns.
Two further facts found while writing the model:
- **The candidate fix "drain while holding `m_`" is not enough.** `post`'s Idle→Posted CAS happens
  *outside* `m_`. A fork between M's CAS and M's enqueue strands j with `outstanding == 0`, which
  the fixed drain accepts. The CAS must move under `m_` too (configuration `host_fork_fix_both`).
- **In the same window, M holds `Allocator::thread_mutex_`**, which has no atfork handler. The
  child's first allocator call deadlocks on it whatever the pool does (invariant `ChildLocksFree`).

**CR-004: a relaunch between `stopAllForFork` and locking `m_`.**

| # | H (forking) | M (mutator) | background member B |
|---|---|---|---|
| 1 | bg prepare: registry lock; `stopAllForFork()` stops and joins the episode | | exits on stop (work back in deques) |
| 2 | | minor end: `reapBackground` → episode `None` with work → **relaunch** (takes and releases `m_`) | wakes, takes an entry into its ring |
| 3 | bg prepare: lock `m_` (now free) | | scanning |
| 4 | `fork()` | | **child: B does not exist; the entry in its ring is gone** |

TLC should confirm the window exists (invariant `ChildHeldAny` fails for a host fork). **It is
harmless for the heap**:
- In a child forked by another thread, the heap's mutator does not exist either. A heap is driven
  only by its owner thread (HEAP_007): its thread-local heap pointer, its stack, its roots.
- So no thread in the child can ever run the mark cycle that lost the entry.
- In a child forked **by the mutator**, step 2 cannot happen, because the mutator is inside
  `fork()`.

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

This happens in the **parent**. Release builds skip the assert and drain the rest with
`runMarkers` (4601-4604), which is correct. M2's `episode_stop` configuration reproduces the
marker-loop half; M6 reproduces the whole chain, and checks that step 4 is not a deadlock.

## 3. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| `HelperJob` states, `resetForReuse` | `GCHelperPool.hpp:42-59`; `.cpp:58` | `jstate`, `WR_Reap` |
| `GCHelperPool::post` | `GCHelperPool.cpp:149-178` | `M_PostCas`, `M_PostQ`, `M_PostDone` |
| `GCHelperPool::workerLoop` | 180-224 | process `Worker`: `W_Take`, `W_Run`, `W_Done`, `W_Notify` |
| `GCHelperPool::wait`, `drain` | 236-258 | procedure `WaitAndReap`; `F_Drain` |
| pool atfork prepare/parent/child | 260-287 | procedure `DoFork` |
| `GCMarkGang::run`, `memberLoop`, atfork | 357-482 | `runM`, `U_RunLock`/`U_FgWait`, `FgMember`, `G_RunM` |
| `GCBackgroundGang::launch`/`memberLoop`/`join`/`joinLocked`/`stopAndJoin` | 543-643 | procedures `Launch`, `Reap`, `StopAndJoin`; process `BgMember` |
| `stopAllForFork`, `stopAllAtExit`, bg atfork | 650-690 | procedures `ForkGangs`, `ExitGangs` |
| `reapBackground`, `closingFinish`, relaunch in `runCycleStepConcurrent` | `OldGenSpace.cpp:4505, 4569 (assert 4599), 4689-4696` | `Reap`, `U_Close*`, `U_Relaunch` |
| 7c tenure collector launch / join / orphan path | `NurseryTenure.cpp:568-572, 575-640 (615)` | the same gang protocol; configuration `two_gangs` |
| `Allocator::thread_mutex_` around posts and waits | `Allocator.cpp:753, 892, 1253` | `tm` |
| the runtime's own fork | `eco-kernel-cpp/src/eco/Process.cpp:70, 124` | `Forker = "mut"` |

**Outside M6:**
- what the jobs do (M7);
- the marker loop (M2's contract, in `Mark()`);
- the heap (M1);
- memory orders. Every handoff here is a mutex release/acquire, except the hints `finished_pub_`
  and `running_`, which are acquire/release atomics that the model reads in SC.

## 4. The model

### 4.1 Two modules

- **`HelperPool.tla` (M6a)**: the pool, its fork handlers, `thread_mutex_`, the mutator's
  post/wait, a host thread, and child workers.
- **`Gangs.tla` (M6b)**: one background gang, the mark gang's `run_m_`, the 5c driver, the fork
  prepare sequence and `stopAllAtExit`.

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
  in the child, so they are frozen mid-step, as threads that no longer exist.

Invariants then speak about the child's state: stranded jobs, held locks, work held by dead
threads.

### 4.3 Abstractions

| Real thing | Model | Why sound |
|---|---|---|
| Pool with 1..64 workers | 1 parent worker, 1 child worker | One worker exhibits every window. Two add only reordering, which is a deep configuration |
| Job bodies (`madvise`) | `skip` (M6a) | M6 checks lifecycle, not effects (M7 does effects) |
| `PageWork` slots | `Jobs = {"j1","j2"}` owned by the mutator | the mutator posts only Idle jobs and waits only on non-Idle ones, as `takeSlot` / `awaitSlot` do |
| The marker loop | procedure `Mark()`: take an entry into the ring, scan it; on stop, scan the ring and leave; `done` iff no work anywhere | M2's contract (Drain, parent plan §5.0); M2 checks it |
| `SliceControl` | `ctl = [stop, done]`, replaced at each launch | each launch creates a fresh control (`launchBackground`) |
| Background gang with B members | B = 1 | stop/join/finished semantics are per member; B = 2 is a deep configuration |
| The mark gang's `m_`, generation | `fgGo` (run started) and `runM` | the member count is fixed; only `run_m_` interacts with fork |
| Two background gangs (5c and 7c) | one (the `two_gangs` configuration duplicates it) | `stopAllForFork` loops over instances, and each is independent |
| `running_` / `finished_pub_` atomics | plain variables | written under `m_` except where the mutant moves them |

### 4.4 Constants

| Constant | Module | Meaning | Values |
|---|---|---|---|
| `Forker` | both | who calls `fork()` | `"mut"` (supported), `"host"` (another thread) |
| `ForkAllowed` | both | fork happens (once) | TRUE/FALSE |
| `ChildUsesPool` | M6a | the host's child keeps using PageWork / the pool | TRUE/FALSE |
| `Jobs` | M6a | PageWork slots | `{"j1","j2"}` |
| `MaxOps` | M6a | mutator operations | 3–4 |
| `FIX` | M6a | candidate CR-003 fixes | `"none"`, `"drain_under_lock"`, `"post_under_lock_and_drain"` |
| `ExitAllowed` | M6b | the host may run `stopAllAtExit` | TRUE/FALSE |
| `Work0` | M6b | grey entries at launch | 2 |
| `Steps` | M6b | minor ends before closing | 1–2 |
| `MaxGen` | M6b | launches (relaunches) bound | 3 |
| `PrepareOrder` (to add) | M6b | `"bg_first"` / `"mark_first"` (§2.4) | both |
| `MUTANT` | both | §5 | |

### 4.5 Variables

| Variable | Module | Code counterpart |
|---|---|---|
| `world` | both | parent or child address space |
| `m` | M6a | `GCHelperPool::m_` (holder) |
| `tm` | M6a | `Allocator::thread_mutex_` (holder) |
| `queue`, `outstanding`, `started` | M6a | `head_`/`tail_`, `outstanding_`, `started_` |
| `jstate` | M6a | `HelperJob::state` per job |
| `doneWaiters` | M6a | threads blocked on `cv_done_` |
| `reg`, `bm`, `runM` | M6b | registry mutex, gang `m_`, mark gang `run_m_` (holders) |
| `running`, `gen`, `finished` | M6b | `running_`, `generation_`, `finished_` |
| `ctl` | M6b | the episode's `SliceControl` (`stop`, `done`) |
| `work`, `held[p]` | M6b | entries in deques; entries in participant p's ring |
| `bgEp` | M6b | `OldGenSpace::bg_ep_` |
| `fgGo` | M6b | the closing run started / its member finished |
| `exited` | M6b | `stopAllAtExit` returned (heap teardown may begin) |

### 4.6 The PlusCal sketches

Files: `test/tla/M6-lifecycle/HelperPool.tla` and `Gangs.tla`. This is the text that passed the
translator; the generated translations are omitted.

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
    ChildUsesPool,   \* the child's thread goes on using the pool / PageWork
    MaxOps,          \* bound on the mutator's operations
    FIX,             \* "none", "drain_under_lock", "post_under_lock_and_drain"
    MUTANT           \* "none", "lost_wakeup"

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
    doneWaiters = {};         \* threads blocked in cv_done_.wait

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
  WR_Lock:                         \* lock m_, check the predicate
    await Alive(self) /\ m = "none";
    if jstate[wj] = "Done" then goto WR_Reap;
    else doneWaiters := doneWaiters \cup {self};   \* block; wait releases m_
    end if;
  WR_Blocked:                      \* woken by notify_all, then re-lock and re-check
    await Alive(self) /\ self \notin doneWaiters;
    goto WR_Lock;
  WR_Reap:
    await Alive(self);
    assert jstate[wj] \in {"Done", "Idle"};
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
                if ~started then started := TRUE; end if;
                queue := Append(queue, j);
                outstanding := outstanding + 1;
                goto M_PostDone;
            else
                jstate[j] := "Posted";
            end if;
          M_PostQ:                                     \* under m_: start, enqueue, ++outstanding
            await Alive("mut") /\ m = "none";
            if ~started then started := TRUE; end if;
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
process Host = "host"
variables hj = "none";
begin
  H_Fork:
    if Forker = "host" /\ ForkAllowed then
        call DoFork();
    end if;
  H_Child:
    if world = "child" /\ ChildUsesPool then
      H_Tm:                                            \* the child's first Allocator call
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
        queue := Tail(queue);
        assert jstate[cur] = "Posted";
        jstate[cur] := "Running";
      W_Run:                       \* runJob: the body (madvise), no lock
        await world = "parent";
        skip;
      W_Done:
        await world = "parent";
        if MUTANT = "lost_wakeup" then
            doneWaiters := {};     \* notify first ...
          W_LateDone:
            await world = "parent";
            jstate[cur] := "Done"; \* ... then publish Done outside the lock
            outstanding := outstanding - 1;
        else
            await m = "none";      \* under m_: Done (release), --outstanding
            jstate[cur] := "Done";
            outstanding := outstanding - 1;
          W_Notify:                \* cv_done_.notify_all() outside the lock
            await world = "parent";
            doneWaiters := {};
        end if;
      W_Clear:
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
(* the relaunch after a stop, closingFinish over GCMarkGang::run), and the *)
(* atfork prepare handlers in reverse registration order (background gang, *)
(* then mark gang), with fork() by the mutator or by another thread, and   *)
(* stopAllAtExit. The marker loop itself is M2's: here it is its contract. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Forker,          \* "mut" or "host"
    ForkAllowed,     \* the forker may fork once
    ExitAllowed,     \* the host may run the atexit handler (stopAllAtExit)
    Work0,           \* grey entries at launch
    Steps,           \* minor ends before the closing step (runCycleStepConcurrent)
    MaxGen,          \* bound on launches
    MUTANT           \* "none", "running_after_notify"

ForkerId == IF Forker = "mut" THEN "mut" ELSE "host"
ParentParts == {"mut", "bg1", "fg1"}     \* marker-loop participants in the parent
ChildParts  == {"mut", "cbg1", "cfg1"}   \* ... in a child forked by the mutator

(* --algorithm Gangs
variables
    world    = "parent",
    exited   = FALSE,          \* stopAllAtExit returned: heap teardown may begin
    reg      = "none",         \* bgRegistryMutex()
    bm       = "none",         \* GCBackgroundGang::m_
    runM     = "none",         \* GCMarkGang::run_m_
    running  = FALSE,          \* GCBackgroundGang::running_ (atomic)
    gen      = 0,              \* generation_
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
    \* A child forked by the MUTATOR continues the heap: nothing may be lost.
    ChildHeapSafe == (world = "child" /\ Forker = "mut") => \A p \in ParentParts : held[p] = 0
    \* The same check for ANY forker: expected to fail for a host fork (the
    \* CR-004 window), which is harmless only because that child has no mutator.
    ChildHeldAny == world = "child" => \A p \in ParentParts : held[p] = 0
    \* After stopAllAtExit no background member is inside an episode.
    ExitSafe == exited => pc["bg1"] \in {"B_Wait", "Done"}
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
    gen := gen + 1;
    finished := 0;
    ctl := [stop |-> FALSE, done |-> FALSE];
    bgEp := "Running";
    if MUTANT # "running_after_notify" then
        running := TRUE;
        return;
    end if;
  L_Late:                              \* mutant: running_ stored after notify_all
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
    if ~wait /\ running /\ finished < 1 then return; end if;
  RP_Join:                             \* join(): under m_; if !running_ return
    await bm = "none";
    if running then
      RP_JoinWait:                     \* cv_done_.wait(finished_ >= members) releases m_
        await bm = "none" /\ finished >= 1;
        running := FALSE;
    end if;
  RP_Set:
    bgEp := IF ctl.done THEN "Finished" ELSE "None";
    return;
end procedure;

\* GCBackgroundGang::stopAndJoin (from stopAllForFork / stopAllAtExit).
procedure StopAndJoin()
begin
  SJ_Lock:
    await bm = "none";
    if ~running then return;
    else ctl.stop := TRUE;             \* stop_->store(true), then wait (releases m_)
    end if;
  SJ_Wait:
    await bm = "none" /\ finished >= 1;
    running := FALSE;
    return;
end procedure;

\* The prepare handlers (reverse registration: background gang, mark gang;
\* the pool's is M6a), fork, then the parent or the child branch.
procedure ForkGangs()
begin
  G_Reg:                               \* bg atforkPrepare: bgRegistryMutex().lock()
    await reg = "none";
    reg := self;
  G_Stop:                              \* stopAllForFork: if (g->running()) stopAndJoin
    if running then call StopAndJoin(); end if;
  G_LockM:                             \* then hold every g->m_ (CR-004 window before this)
    await bm = "none";
    bm := self;
  G_RunM:                              \* GCMarkGang::atforkPrepare: run_m_.lock()
    await runM = "none";
    runM := self;
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

\* stopAllAtExit: under the registry mutex, stopAndJoin every gang.
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
\* stop), then closingFinish, then the handoff check.
fair process Mutator = "mut"
variables k = 0, forked = FALSE;
begin
  U_Launch:
    call Launch();
  U_Steps:
    while k < Steps do
      U_MaybeFork:                     \* a fork by the mutator happens between pauses
        await Alive("mut");
        either
            await Forker = "mut" /\ ForkAllowed /\ ~forked;
            forked := TRUE;
            call ForkGangs();
        or
            skip;
        end either;
      U_Reap:
        call Reap(FALSE);
      U_Relaunch:                      \* runCycleStepConcurrent: stopped -> relaunch
        await Alive("mut");
        if bgEp = "None" /\ work > 0 then
            call Launch();
        elsif bgEp = "None" then
            bgEp := "Finished";
        end if;
      U_Next:
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
        await Alive("mut") /\ ~fgGo;
        runM := "none";
      U_Reap2:                         \* reapBackground(true)
        call Reap(TRUE);
      U_Assert:
        assert bgEp = "Finished";      \* closingFinish's assert: CR-005 when stopped
    end if;
  U_Drain:                             \* a stopped episode left work: runMarkers drain
    await Alive("mut");
    if work > 0 then work := 0; end if;
  U_Handoff:
    assert \A p \in Parts : held[p] = 0;
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

\* Another thread: it may fork (Forker = "host") or run the atexit handlers.
process Host = "host"
begin
  H_Act:
    either
        await Forker = "host" /\ ForkAllowed;
        call ForkGangs();
    or
        await ExitAllowed;
        call ExitGangs();
    or
        skip;
    end either;
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION
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
| `WR_Load` | 237-239 | `state.load(acquire)` |
| `WR_Lock`, `WR_Blocked` | 243-247 | `cv_done_.wait(lk, Done)` |
| `WR_Reap` | `PageWork.cpp:76-95`, `.cpp:58` | `reap` → `resetForReuse` |
| `W_Take` | 203-215 | `cv_work_.wait`, dequeue, `Running` (under `m_`) |
| `W_Run` | 216 | `runJob` (no lock) |
| `W_Done`, `W_Notify` | 217-222 | `Done` + `--outstanding` under `m_`; `notify_all` outside |
| `F_Drain`, `F_Lock` | 260-265 | `drain()` critical section; then `m_.lock()` |
| `F_Fork` | 267-287 | parent / child handlers |
| `L_Lock` (`Launch`) | 599-616 | `launch`'s `m_` section (`running_` inside it) |
| `RP_Hint`, `RP_Join`, `RP_JoinWait`, `RP_Set` | `OldGenSpace.cpp:4505-4526`; `.cpp:622-636` | `reapBackground`; `join`; `joinLocked`'s wait |
| `SJ_Lock`, `SJ_Wait` | 638-643, 622-630 | `stopAndJoin` |
| `G_Reg`, `G_Stop`, `G_LockM` | 664-669, 650-657 | bg prepare |
| `G_RunM` | 458-464 | mark gang prepare (`run_m_`) |
| `G_Fork` | 466-482, 671-690 | parent / child handlers |
| `X_Reg`, `X_Stop`, `X_Done` | 659-662 | `stopAllAtExit` |
| `B_Wait`, `B_Run`, `B_Fin` | 543-597 | the member loop |
| `U_RunLock` … `U_Assert` | `OldGenSpace.cpp:4569-4606`; `.cpp:407-431` | `closingFinish` over `GCMarkGang::run` |
| `U_Relaunch` | `OldGenSpace.cpp:4688-4700` | relaunch after a stop |

### 4.8 Properties

| Property | Module | Kind | Meaning | Expected |
|---|---|---|---|---|
| `ChildNoStranded` | M6a | invariant | in a child, every Posted/Running job is still queued | holds for `Forker = "mut"`; **fails for `"host"` (CR-003)**; still fails with `drain_under_lock`; holds with `post_under_lock_and_drain` |
| `ChildLocksFree` | M6a | invariant | in a child, `m_` and `thread_mutex_` are free or held by the forker | holds for `"mut"`; **fails for `"host"`** (`thread_mutex_`: new finding, §2.5) |
| `ParentJobsFinish` | M6a | liveness | every posted job is eventually Done (parent) | holds |
| `MutatorProgress` | M6a | liveness | the mutator finishes its operations | holds; fails under `lost_wakeup` |
| `WR_Reap`'s assert | M6a | assertion | only Done/Idle jobs are reset | holds |
| `ChildHeapSafe` | M6b | invariant | a child forked by the mutator holds no entry in a dead thread's ring | holds |
| `ChildHeldAny` | M6b | invariant | the same for any forker | **fails for `"host"`**: documents the CR-004 window (harmless, §2.5) |
| `ExitSafe` | M6b | invariant | after `stopAllAtExit`, the member is parked | holds; fails under `running_after_notify` |
| `U_Assert` | M6b | assertion | `closingFinish`'s `bg_ep_ == Finished` | **fails for a host fork during closing (CR-005)** |
| `U_Handoff`'s assert | M6b | assertion | no entry held at the handoff | holds |
| deadlock | both | TLC deadlock check **off** (frozen child threads look like deadlock); instead `ParentProgress == [](world = "parent") => <>(pc["mut"] = "Done")` (to add) | holds |

## 5. Negative controls

| `MUTANT` / `FIX` | Code change | Configuration | Must violate |
|---|---|---|---|
| (the code as is) + `Forker = "host"` | — (CR-003) | `host_fork_stranded` | `ChildNoStranded` |
| `FIX = "drain_under_lock"` | drain and keep `m_` in one section | `host_fork_fix_drain` | `ChildNoStranded` (via the CAS window) |
| `FIX = "post_under_lock_and_drain"` | + move the CAS under `m_` | `host_fork_fix_both` | nothing (the positive control for the fix) |
| `lost_wakeup` | the worker notifies, then writes Done outside `m_` | `pool_basic` | `MutatorProgress` |
| `running_after_notify` | `launch` stores `running_` after unlock/notify | `exit` | `ExitSafe` (`stopAllAtExit` sees `!running` while the member runs) |
| `join_no_wait` (to add) | `joinLocked` returns without waiting for `finished` | `episode` | `U_Handoff` / `ChildHeapSafe` |
| `no_stop_in_prepare` (to add) | bg prepare skips `stopAllForFork` | `mut_fork` | `ChildHeapSafe` (a child forked by the mutator loses ring entries) |

`decommit delay counted in pause ends` is **not** an M6/M7 mutant. It changes *when* discards are
posted (a policy), never whether one runs under an owner. Plan 03 rejected it for cost, not
safety.

## 6. Configurations

| Config | Module | Key constants | Expected |
|---|---|---|---|
| `pool_basic` | M6a | `ForkAllowed = FALSE`, `MaxOps = 4` | pass |
| `mut_fork` | M6a | `Forker = "mut"`, `ChildUsesPool = FALSE` | pass |
| `host_fork_stranded` | M6a | `Forker = "host"`, `ChildUsesPool = TRUE`, invariant `ChildNoStranded` only | **fail (CR-003)** |
| `host_fork_locks` | M6a | as above, invariant `ChildLocksFree` only | **fail (thread_mutex_)** |
| `host_fork_fix_drain` | M6a | + `FIX = "drain_under_lock"` | **fail** (the CAS window) |
| `host_fork_fix_both` | M6a | + `FIX = "post_under_lock_and_drain"`, `ChildNoStranded` | pass |
| `episode` | M6b | `ForkAllowed = FALSE`, `ExitAllowed = FALSE`, `Steps = 2` | pass |
| `mut_fork` | M6b | `Forker = "mut"` | pass (`ChildHeapSafe`) |
| `host_fork` | M6b | `Forker = "host"`, invariants `ChildHeapSafe` + `U_Assert` | **fail `U_Assert` (CR-005)**; `ChildHeapSafe` holds |
| `host_fork_window` | M6b | `Forker = "host"`, invariant `ChildHeldAny` | **fail** (documents the CR-004 window) |
| `exit` | M6b | `ExitAllowed = TRUE` | pass |
| `mark_first` | M6b | `PrepareOrder = "mark_first"` (to add) | same verdicts as `host_fork` |
| `two_gangs` | M6b (deep) | two gang instances (5c markers, 7c collector) in `stopAllForFork` | same verdicts |

Every configuration sets `defaultInitValue = defaultInitValue` and `CHECK_DEADLOCK FALSE`
(§4.8).

## 7. Accuracy notes (rules A1–A9)

| Rule | M6 |
|---|---|
| A1 | Every `m_`/`run_m_`/registry critical section whose intermediate states nobody else observes is one step. Locks held **across** steps (prepare holds them across the fork; `thread_mutex_` across a post or a wait) are explicit holder variables. Condition waits are check-under-lock + block + re-lock (§2.1). `post`'s CAS is a separate step from its enqueue: the CR-003 fix analysis depends on that. |
| A2 | Job state, `running_`, `finished_pub_`, the generation: whole words. No sub-word sharing. |
| A3 | 05c H13 (gang objects), the atfork registration table (§2.4), `thread_mutex_` (HEAP_058), PageWork slots as jobs. |
| A4 | None needed for the mutex handoffs. The hints (`finished_pub_` acquire, `running_` acquire) are read only by their owner or as hints (GC_DET_001). A W-companion is not required. |
| A5 | `gc-helper-tsan` `harness.cpp` H1 (3 posters, random drain) for M6a; `mark_harness.cpp` `bgGangStorm` for M6b; plus the **fork harness** CR-008 proposes (§8). |
| A6 | §5. The "code as is" configurations are themselves negative controls for CR-003/005. |
| A7 | HEAP_007, HEAP_058, GC_DET_001 (pool half), IM14/IM15 (quiescence and no private work after a join), the `closingFinish` assert. |
| A8 | 1 worker, 2 jobs, 1 gang member, 1 fork, 1–2 minor steps. Deep: 2 workers, B = 2, two gangs. |
| A9 | `file`: `GCHelperPool.cpp`, `GCHelperPool.hpp`. `region`: `launchBackground`, `reapBackground`, `stopBackground`, `closingFinish`, the relaunch in `runCycleStepConcurrent`, `tenureLaunch`'s collector launch, `tenureJoin`, `tenureTeardown`, `Allocator::onGCPauseEnd`. `census`: `OldGenSpace.cpp`, `NurseryTenure.cpp`, `Allocator.cpp`. |

## 8. Trace validation

- **Harnesses:**
  - `test/gc-helper-tsan/harness.cpp` H1 for the pool;
  - `mark_harness.cpp` `bgGangStorm` (launch/stop/join storms) for the gang;
  - **a new fork harness** (register CR-008) for fork. A host thread forks at random moments while
    the mutator posts, relaunches episodes and runs closing joins. The child either records state
    and `_exit`s, or (mutator forks only) continues.
- **Events** (compiled in only with `ECO_TLA_TRACE`):

  | Event | Where | Fields |
  |---|---|---|
  | `post_cas`, `post_enq` | `post` 153, 170-175 | job, `outstanding` after |
  | `take`, `done` | `workerLoop` 207-214, 218-220 | job, `outstanding` |
  | `wait_block`, `wait_wake` | `wait` 243-247 | job |
  | `launch`, `member_start`, `member_fin`, `join`, `stop` | `launch`, `memberLoop`, `joinLocked`, `stopAndJoin` | generation, `finished` |
  | `prep_begin`, `prep_end`, `fork_parent`, `fork_child` | each atfork handler | handler name |

- **Ordering:** everything here happens under a mutex. Log a per-mutex acquisition counter inside
  each critical section; it totally orders the events of that mutex.
- **Child traces:** the child writes its own log. The trace spec checks it against the `world =
  "child"` branch.

## 9. Implementation steps

1. Create `test/tla/M6-lifecycle/` with both modules (§4.6), `MC.tla`, the §6 configurations,
   MAPPING.md (§4.7 plus A3's table) and AUDIT.md.
2. `pcal` + `sany`, then TLC on `pool_basic`, `mut_fork` (both modules), `episode`, `exit`.
3. Run the expected-failure configurations. For each, record the trace in the register:
   - `host_fork_stranded` → CR-003 Reproduced;
   - `host_fork_locks` → a new entry: "`thread_mutex_` held across a non-mutator fork";
   - `host_fork_fix_drain` → note on CR-003's fix;
   - `host_fork` → CR-005 Reproduced (with M2's `episode_stop`);
   - `host_fork_window` → CR-004 window confirmed. Confirm `ChildHeapSafe` holds in the same
     configuration, then propose CR-004 → Not-a-bug.
4. Add `PrepareOrder`, `ParentProgress`, and the "to add" mutants; confirm the verdicts.
5. Deep: `two_gangs`, 2 workers, B = 2.
6. Wire into `models.txt` and `manifest.txt` (A9).
7. **Resolution work for the register (a code change is not part of this model plan).** The
   modelling result points to one contract, which should be written down:

   > `fork()` without an immediate `exec` is supported only from a heap's mutator between pauses.

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
2. Can the 7c tenure collector register the gang atfork handlers before `GCMarkGang` in a real run?
   §2.4 argues yes. Check with a startup trace, because the verdicts of `mark_first` and `bg_first`
   should be identical, but only the model can say so.
