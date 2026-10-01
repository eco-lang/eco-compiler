----------------------------- MODULE HelperPool -----------------------------
(***************************************************************************)
(* M6a: GCHelperPool (runtime/src/allocator/GCHelperPool.cpp): the job     *)
(* state machine, post / worker / wait, and the pthread_atfork handlers,   *)
(* with fork() taken either by the mutator or by another ("host") thread.  *)
(* Plan: plans/threaded-gc-tla-M6-lifecycle.md. MAPPING.md maps every      *)
(* label to the code; AUDIT.md records the results.                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Jobs,            \* job objects the mutator owns (PageWork's slots)
    Forker,          \* "mut" = the mutator forks; "host" = another thread forks
    ForkAllowed,     \* the forker may call fork() once
    ChildUsesPool,   \* the host's child uses PageWork, or calls exit() (~Allocator drains)
    MaxOps,          \* bound on the mutator's operations
    NWorkers,        \* pool workers (threads_), 1 or 2
    GUARD,           \* the "fork only from the mutator" guard in the child (resolution
                     \* (a) of CR-003, not adopted): "none", "before_tm", "after_tm"
    MUTANT           \* "none", "lost_wakeup", "wait_no_recheck", "no_dequeue",
                     \* "no_start", "child_keeps_started"; and the pre-fix fork
                     \* handlers (register-fixes §7.2 step 9, A6): "as_built_2026_09"
                     \* (CR-003/015 as built), "no_tm_cas_outside", "no_tm_drain_split",
                     \* "no_tm" (no thread_mutex_ layer), "tm_last" (it runs after the pool's)

ForkerId == IF Forker = "mut" THEN "mut" ELSE "host"
PWorkers == IF NWorkers = 1 THEN {"w1"} ELSE {"w1", "w2"}     \* parent pool workers
CWorkers == IF NWorkers = 1 THEN {"cw1"} ELSE {"cw1", "cw2"}  \* workers the child starts
Range(sq) == {sq[i] : i \in 1..Len(sq)}
\* The fork design (register-fixes §7.1, CR-003/015, HEAP_058/HEAP_075), the
\* default since 2026-10-01: post's CAS and enqueue in one m_ section
\* (PostUnderLock); the pool's prepare drains and keeps m_ in one section
\* (DrainHoldsLock); GCFork's allocator layer locks Allocator::thread_mutex_
\* BEFORE the pool's prepare (TmFirst; the parent unlocks it, the child
\* re-creates it). The mutants turn pieces off (the old FIX rows, A6).
DrainHoldsLock == MUTANT \notin {"no_tm_drain_split", "as_built_2026_09"}
PostUnderLock  == MUTANT \notin {"no_tm_cas_outside", "as_built_2026_09"}
TmHandler      == MUTANT \notin {"no_tm_cas_outside", "no_tm_drain_split", "no_tm", "as_built_2026_09"}
TmFirst        == TmHandler /\ MUTANT # "tm_last"
TmLast         == MUTANT = "tm_last"

(* --algorithm HelperPool
variables
    world       = "parent",   \* "child" after the fork step takes the child branch
    m           = "none",     \* holder of GCHelperPool::m_
    tm          = "none",     \* holder of Allocator::thread_mutex_ (no atfork handler)
    queue       = <<>>,       \* head_ / tail_ (FIFO)
    outstanding = 0,          \* outstanding_
    started     = FALSE,      \* started_ (workers are started lazily at a post)
    spawned     = FALSE,      \* ghost: this address space's worker threads exist
    jstate      = [x \in Jobs |-> "Idle"],   \* HelperJob::state
    doneWaiters = {},         \* threads blocked in cv_done_.wait
    runs        = [x \in Jobs |-> 0];      \* ghost: runs since the job's last post

define
    \* A thread runs in the parent, or in the child if it is the forking thread
    \* (or a worker the child started).
    Alive(p) == \/ world = "parent" /\ p \notin CWorkers
                \/ world = "child" /\ (p = ForkerId \/ p \in CWorkers)
    \* PoolJob (provided to M7): a post is run at most once, and a job that
    \* is Running or Done was run exactly once since its post.
    PoolRunOnce ==
        \A x \in Jobs : runs[x] <= 1 /\ (jstate[x] \in {"Running", "Done"} => runs[x] = 1)
    \* CR-015: no mutex is held in the child by a thread that does not exist there.
    ChildLocksFree ==
        world = "child" => (m \in {"none", ForkerId} /\ tm \in {"none", ForkerId})
end define;

\* The fork: the prepare handlers, then either the parent or the child branch.
procedure DoFork()
begin
  F_Tm:                            \* GCFork's allocator layer: thread_mutex_, before the pool's
    await Alive(self);
    if TmFirst then
        await tm = "none";
        tm := self;
    end if;
  F_Drain:                         \* atforkPrepare: drain() = cv_done_.wait(outstanding_ == 0)
    await Alive(self);
    if DrainHoldsLock then         \* the fix: drain and keep m_ in ONE section
        await m = "none" /\ outstanding = 0;
        m := self;
        goto F_TmLast;
    else                           \* pre-fix (mutants): drain, release m_ ...
        await m = "none" /\ outstanding = 0;
    end if;
  F_Lock:                          \* ... then m_.lock() separately (the CR-003 window)
    await Alive(self) /\ m = "none";
    m := self;
  F_TmLast:                        \* mutant tm_last: thread_mutex_'s prepare, after the pool's
    await Alive(self);
    if TmLast then
        await tm = "none";
        tm := self;
    end if;
  F_Fork:
    either                         \* parent: atforkParent unlocks m_ (and thread_mutex_)
        m := "none";
        if TmHandler then tm := "none"; end if;
    or                             \* child: only the forking thread exists; atforkChild
        world := "child";          \* re-creates m_ / the condvars and forgets the queue
        m := "none";
        if TmHandler then tm := "none"; end if;
        queue := <<>>;
        outstanding := 0;
        started := IF MUTANT = "child_keeps_started" THEN started ELSE FALSE;
        spawned := FALSE;          \* the parent's workers do not exist in the child
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
\* takeSlot, always under thread_mutex_ (HEAP_058). It stands for every
\* thread that holds thread_mutex_ (a GCMarkGang member in a pause included).
\* It may itself fork between pauses (Forker = "mut").
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
          M_PostCas:                                   \* CAS Idle -> Posted
            await Alive("mut");
            if PostUnderLock then
                await m = "none";                      \* the fix: CAS and enqueue in one m_ section
                jstate[j] := "Posted";
                runs[j] := 0;
                if ~started /\ MUTANT # "no_start" then started := TRUE; spawned := TRUE; end if;
                queue := Append(queue, j);
                outstanding := outstanding + 1;
                goto M_PostDone;
            else
                jstate[j] := "Posted";
                runs[j] := 0;
            end if;
          M_PostQ:                                     \* under m_: start, enqueue, ++outstanding
            await Alive("mut") /\ m = "none";
            if ~started /\ MUTANT # "no_start" then started := TRUE; spawned := TRUE; end if;
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

\* Another thread (an embedding host, or a second heap's mutator) that may
\* fork, and whose child may go on using the pool (PageWork's takeSlot, or
\* ~Allocator's drainAll at the child's exit()).
fair process Host = "host"
variables hj = "none";
begin
  H_Fork:
    await Alive("host");
    if Forker = "host" /\ ForkAllowed then
        call DoFork();
    end if;
  H_Child:                                             \* only a host that forked exists in the child
    await Alive("host");
    if world = "child" /\ ChildUsesPool /\ Forker = "host" then
        if GUARD = "before_tm" then goto H_End; end if;   \* the guard aborts: heap not owned
      H_Tm:                                            \* first Allocator call, or ~Allocator at exit()
        await Alive("host") /\ tm = "none";
        tm := "host";
        if GUARD = "after_tm" then goto H_End; end if;
      H_Pick:
        await Alive("host");
        if \E x \in Jobs : jstate[x] # "Idle" then
            with x \in {y \in Jobs : jstate[y] # "Idle"} do hj := x; end with;
          H_Wait:
            call WaitAndReap(hj);
        end if;
      H_Unlock:
        await Alive("host");
        tm := "none";
        hj := "none";
    end if;
  H_End:
    await Alive("host");
    skip;
end process;

\* Parent pool workers (workerLoop).
fair process Worker \in PWorkers
variables cur = "none";
begin
  W_Loop:
    while TRUE do
      W_Take:                      \* cv_work_.wait(head_ || stopping_), dequeue, Running
        await world = "parent" /\ m = "none" /\ spawned /\ queue # <<>>;
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
        await world = "child" /\ m = "none" /\ spawned /\ queue # <<>>;
        ccur := Head(queue);
        queue := Tail(queue);
        jstate[ccur] := "Running";
        runs[ccur] := runs[ccur] + 1;
      C_Done:
        await world = "child" /\ m = "none";
        jstate[ccur] := "Done";
        outstanding := outstanding - 1;
      C_Notify:
        await world = "child";
        doneWaiters := {};
        ccur := "none";
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
CONSTANT defaultInitValue
VARIABLES pc, world, m, tm, queue, outstanding, started, spawned, jstate, 
          doneWaiters, runs, stack

(* define statement *)
Alive(p) == \/ world = "parent" /\ p \notin CWorkers
            \/ world = "child" /\ (p = ForkerId \/ p \in CWorkers)


PoolRunOnce ==
    \A x \in Jobs : runs[x] <= 1 /\ (jstate[x] \in {"Running", "Done"} => runs[x] = 1)

ChildLocksFree ==
    world = "child" => (m \in {"none", ForkerId} /\ tm \in {"none", ForkerId})

VARIABLES wj, j, n, forked, hj, cur, ccur

vars == << pc, world, m, tm, queue, outstanding, started, spawned, jstate, 
           doneWaiters, runs, stack, wj, j, n, forked, hj, cur, ccur >>

ProcSet == {"mut"} \cup {"host"} \cup (PWorkers) \cup (CWorkers)

Init == (* Global variables *)
        /\ world = "parent"
        /\ m = "none"
        /\ tm = "none"
        /\ queue = <<>>
        /\ outstanding = 0
        /\ started = FALSE
        /\ spawned = FALSE
        /\ jstate = [x \in Jobs |-> "Idle"]
        /\ doneWaiters = {}
        /\ runs = [x \in Jobs |-> 0]
        (* Procedure WaitAndReap *)
        /\ wj = [ self \in ProcSet |-> defaultInitValue]
        (* Process Mutator *)
        /\ j = "none"
        /\ n = 0
        /\ forked = FALSE
        (* Process Host *)
        /\ hj = "none"
        (* Process Worker *)
        /\ cur = [self \in PWorkers |-> "none"]
        (* Process CWorker *)
        /\ ccur = [self \in CWorkers |-> "none"]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self = "mut" -> "M_Loop"
                                        [] self = "host" -> "H_Fork"
                                        [] self \in PWorkers -> "W_Loop"
                                        [] self \in CWorkers -> "C_Loop"]

F_Tm(self) == /\ pc[self] = "F_Tm"
              /\ Alive(self)
              /\ IF TmFirst
                    THEN /\ tm = "none"
                         /\ tm' = self
                    ELSE /\ TRUE
                         /\ tm' = tm
              /\ pc' = [pc EXCEPT ![self] = "F_Drain"]
              /\ UNCHANGED << world, m, queue, outstanding, started, spawned, 
                              jstate, doneWaiters, runs, stack, wj, j, n, 
                              forked, hj, cur, ccur >>

F_Drain(self) == /\ pc[self] = "F_Drain"
                 /\ Alive(self)
                 /\ IF DrainHoldsLock
                       THEN /\ m = "none" /\ outstanding = 0
                            /\ m' = self
                            /\ pc' = [pc EXCEPT ![self] = "F_TmLast"]
                       ELSE /\ m = "none" /\ outstanding = 0
                            /\ pc' = [pc EXCEPT ![self] = "F_Lock"]
                            /\ m' = m
                 /\ UNCHANGED << world, tm, queue, outstanding, started, 
                                 spawned, jstate, doneWaiters, runs, stack, wj, 
                                 j, n, forked, hj, cur, ccur >>

F_Lock(self) == /\ pc[self] = "F_Lock"
                /\ Alive(self) /\ m = "none"
                /\ m' = self
                /\ pc' = [pc EXCEPT ![self] = "F_TmLast"]
                /\ UNCHANGED << world, tm, queue, outstanding, started, 
                                spawned, jstate, doneWaiters, runs, stack, wj, 
                                j, n, forked, hj, cur, ccur >>

F_TmLast(self) == /\ pc[self] = "F_TmLast"
                  /\ Alive(self)
                  /\ IF TmLast
                        THEN /\ tm = "none"
                             /\ tm' = self
                        ELSE /\ TRUE
                             /\ tm' = tm
                  /\ pc' = [pc EXCEPT ![self] = "F_Fork"]
                  /\ UNCHANGED << world, m, queue, outstanding, started, 
                                  spawned, jstate, doneWaiters, runs, stack, 
                                  wj, j, n, forked, hj, cur, ccur >>

F_Fork(self) == /\ pc[self] = "F_Fork"
                /\ \/ /\ m' = "none"
                      /\ IF TmHandler
                            THEN /\ tm' = "none"
                            ELSE /\ TRUE
                                 /\ tm' = tm
                      /\ UNCHANGED <<world, queue, outstanding, started, spawned, doneWaiters>>
                   \/ /\ world' = "child"
                      /\ m' = "none"
                      /\ IF TmHandler
                            THEN /\ tm' = "none"
                            ELSE /\ TRUE
                                 /\ tm' = tm
                      /\ queue' = <<>>
                      /\ outstanding' = 0
                      /\ started' = (IF MUTANT = "child_keeps_started" THEN started ELSE FALSE)
                      /\ spawned' = FALSE
                      /\ doneWaiters' = {}
                /\ pc' = [pc EXCEPT ![self] = "F_Ret"]
                /\ UNCHANGED << jstate, runs, stack, wj, j, n, forked, hj, cur, 
                                ccur >>

F_Ret(self) == /\ pc[self] = "F_Ret"
               /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
               /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
               /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                               spawned, jstate, doneWaiters, runs, wj, j, n, 
                               forked, hj, cur, ccur >>

DoFork(self) == F_Tm(self) \/ F_Drain(self) \/ F_Lock(self)
                   \/ F_TmLast(self) \/ F_Fork(self) \/ F_Ret(self)

WR_Load(self) == /\ pc[self] = "WR_Load"
                 /\ Alive(self)
                 /\ IF jstate[wj[self]] = "Done"
                       THEN /\ pc' = [pc EXCEPT ![self] = "WR_Reap"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "WR_Lock"]
                 /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                 spawned, jstate, doneWaiters, runs, stack, wj, 
                                 j, n, forked, hj, cur, ccur >>

WR_Lock(self) == /\ pc[self] = "WR_Lock"
                 /\ Alive(self) /\ m = "none"
                 /\ IF jstate[wj[self]] = "Done"
                       THEN /\ pc' = [pc EXCEPT ![self] = "WR_Reap"]
                            /\ m' = m
                       ELSE /\ m' = self
                            /\ pc' = [pc EXCEPT ![self] = "WR_Block"]
                 /\ UNCHANGED << world, tm, queue, outstanding, started, 
                                 spawned, jstate, doneWaiters, runs, stack, wj, 
                                 j, n, forked, hj, cur, ccur >>

WR_Block(self) == /\ pc[self] = "WR_Block"
                  /\ Alive(self)
                  /\ doneWaiters' = (doneWaiters \cup {self})
                  /\ m' = "none"
                  /\ pc' = [pc EXCEPT ![self] = "WR_Blocked"]
                  /\ UNCHANGED << world, tm, queue, outstanding, started, 
                                  spawned, jstate, runs, stack, wj, j, n, 
                                  forked, hj, cur, ccur >>

WR_Blocked(self) == /\ pc[self] = "WR_Blocked"
                    /\ Alive(self) /\ self \notin doneWaiters
                    /\ IF MUTANT = "wait_no_recheck"
                          THEN /\ pc' = [pc EXCEPT ![self] = "WR_Reap"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "WR_Lock"]
                    /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                    spawned, jstate, doneWaiters, runs, stack, 
                                    wj, j, n, forked, hj, cur, ccur >>

WR_Reap(self) == /\ pc[self] = "WR_Reap"
                 /\ Alive(self)
                 /\ jstate' = [jstate EXCEPT ![wj[self]] = "Idle"]
                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                 /\ wj' = [wj EXCEPT ![self] = Head(stack[self]).wj]
                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                 /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                 spawned, doneWaiters, runs, j, n, forked, hj, 
                                 cur, ccur >>

WaitAndReap(self) == WR_Load(self) \/ WR_Lock(self) \/ WR_Block(self)
                        \/ WR_Blocked(self) \/ WR_Reap(self)

M_Loop == /\ pc["mut"] = "M_Loop"
          /\ IF n < MaxOps
                THEN /\ pc' = [pc EXCEPT !["mut"] = "M_Choose"]
                ELSE /\ pc' = [pc EXCEPT !["mut"] = "Done"]
          /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                          jstate, doneWaiters, runs, stack, wj, j, n, forked, 
                          hj, cur, ccur >>

M_Choose == /\ pc["mut"] = "M_Choose"
            /\ Alive("mut")
            /\ \/ /\ tm = "none" /\ \E x \in Jobs : jstate[x] = "Idle"
                  /\ tm' = "mut"
                  /\ \E x \in {y \in Jobs : jstate[y] = "Idle"}:
                       j' = x
                  /\ pc' = [pc EXCEPT !["mut"] = "M_PostCas"]
                  /\ UNCHANGED <<stack, forked>>
               \/ /\ tm = "none" /\ \E x \in Jobs : jstate[x] # "Idle"
                  /\ tm' = "mut"
                  /\ \E x \in {y \in Jobs : jstate[y] # "Idle"}:
                       j' = x
                  /\ pc' = [pc EXCEPT !["mut"] = "M_Wait"]
                  /\ UNCHANGED <<stack, forked>>
               \/ /\ Forker = "mut" /\ ForkAllowed /\ ~forked /\ tm = "none"
                  /\ forked' = TRUE
                  /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "DoFork",
                                                            pc        |->  "M_Next" ] >>
                                                        \o stack["mut"]]
                  /\ pc' = [pc EXCEPT !["mut"] = "F_Tm"]
                  /\ UNCHANGED <<tm, j>>
            /\ UNCHANGED << world, m, queue, outstanding, started, spawned, 
                            jstate, doneWaiters, runs, wj, n, hj, cur, ccur >>

M_PostCas == /\ pc["mut"] = "M_PostCas"
             /\ Alive("mut")
             /\ IF PostUnderLock
                   THEN /\ m = "none"
                        /\ jstate' = [jstate EXCEPT ![j] = "Posted"]
                        /\ runs' = [runs EXCEPT ![j] = 0]
                        /\ IF ~started /\ MUTANT # "no_start"
                              THEN /\ started' = TRUE
                                   /\ spawned' = TRUE
                              ELSE /\ TRUE
                                   /\ UNCHANGED << started, spawned >>
                        /\ queue' = Append(queue, j)
                        /\ outstanding' = outstanding + 1
                        /\ pc' = [pc EXCEPT !["mut"] = "M_PostDone"]
                   ELSE /\ jstate' = [jstate EXCEPT ![j] = "Posted"]
                        /\ runs' = [runs EXCEPT ![j] = 0]
                        /\ pc' = [pc EXCEPT !["mut"] = "M_PostQ"]
                        /\ UNCHANGED << queue, outstanding, started, spawned >>
             /\ UNCHANGED << world, m, tm, doneWaiters, stack, wj, j, n, 
                             forked, hj, cur, ccur >>

M_PostQ == /\ pc["mut"] = "M_PostQ"
           /\ Alive("mut") /\ m = "none"
           /\ IF ~started /\ MUTANT # "no_start"
                 THEN /\ started' = TRUE
                      /\ spawned' = TRUE
                 ELSE /\ TRUE
                      /\ UNCHANGED << started, spawned >>
           /\ queue' = Append(queue, j)
           /\ outstanding' = outstanding + 1
           /\ pc' = [pc EXCEPT !["mut"] = "M_PostDone"]
           /\ UNCHANGED << world, m, tm, jstate, doneWaiters, runs, stack, wj, 
                           j, n, forked, hj, cur, ccur >>

M_PostDone == /\ pc["mut"] = "M_PostDone"
              /\ Alive("mut")
              /\ tm' = "none"
              /\ j' = "none"
              /\ pc' = [pc EXCEPT !["mut"] = "M_Next"]
              /\ UNCHANGED << world, m, queue, outstanding, started, spawned, 
                              jstate, doneWaiters, runs, stack, wj, n, forked, 
                              hj, cur, ccur >>

M_Wait == /\ pc["mut"] = "M_Wait"
          /\ /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "WaitAndReap",
                                                       pc        |->  "M_WaitDone",
                                                       wj        |->  wj["mut"] ] >>
                                                   \o stack["mut"]]
             /\ wj' = [wj EXCEPT !["mut"] = j]
          /\ pc' = [pc EXCEPT !["mut"] = "WR_Load"]
          /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                          jstate, doneWaiters, runs, j, n, forked, hj, cur, 
                          ccur >>

M_WaitDone == /\ pc["mut"] = "M_WaitDone"
              /\ Alive("mut")
              /\ tm' = "none"
              /\ j' = "none"
              /\ pc' = [pc EXCEPT !["mut"] = "M_Next"]
              /\ UNCHANGED << world, m, queue, outstanding, started, spawned, 
                              jstate, doneWaiters, runs, stack, wj, n, forked, 
                              hj, cur, ccur >>

M_Next == /\ pc["mut"] = "M_Next"
          /\ Alive("mut")
          /\ n' = n + 1
          /\ pc' = [pc EXCEPT !["mut"] = "M_Loop"]
          /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                          jstate, doneWaiters, runs, stack, wj, j, forked, hj, 
                          cur, ccur >>

Mutator == M_Loop \/ M_Choose \/ M_PostCas \/ M_PostQ \/ M_PostDone
              \/ M_Wait \/ M_WaitDone \/ M_Next

H_Fork == /\ pc["host"] = "H_Fork"
          /\ Alive("host")
          /\ IF Forker = "host" /\ ForkAllowed
                THEN /\ stack' = [stack EXCEPT !["host"] = << [ procedure |->  "DoFork",
                                                                pc        |->  "H_Child" ] >>
                                                            \o stack["host"]]
                     /\ pc' = [pc EXCEPT !["host"] = "F_Tm"]
                ELSE /\ pc' = [pc EXCEPT !["host"] = "H_Child"]
                     /\ stack' = stack
          /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                          jstate, doneWaiters, runs, wj, j, n, forked, hj, cur, 
                          ccur >>

H_Child == /\ pc["host"] = "H_Child"
           /\ Alive("host")
           /\ IF world = "child" /\ ChildUsesPool /\ Forker = "host"
                 THEN /\ IF GUARD = "before_tm"
                            THEN /\ pc' = [pc EXCEPT !["host"] = "H_End"]
                            ELSE /\ pc' = [pc EXCEPT !["host"] = "H_Tm"]
                 ELSE /\ pc' = [pc EXCEPT !["host"] = "H_End"]
           /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                           jstate, doneWaiters, runs, stack, wj, j, n, forked, 
                           hj, cur, ccur >>

H_Tm == /\ pc["host"] = "H_Tm"
        /\ Alive("host") /\ tm = "none"
        /\ tm' = "host"
        /\ IF GUARD = "after_tm"
              THEN /\ pc' = [pc EXCEPT !["host"] = "H_End"]
              ELSE /\ pc' = [pc EXCEPT !["host"] = "H_Pick"]
        /\ UNCHANGED << world, m, queue, outstanding, started, spawned, jstate, 
                        doneWaiters, runs, stack, wj, j, n, forked, hj, cur, 
                        ccur >>

H_Pick == /\ pc["host"] = "H_Pick"
          /\ Alive("host")
          /\ IF \E x \in Jobs : jstate[x] # "Idle"
                THEN /\ \E x \in {y \in Jobs : jstate[y] # "Idle"}:
                          hj' = x
                     /\ pc' = [pc EXCEPT !["host"] = "H_Wait"]
                ELSE /\ pc' = [pc EXCEPT !["host"] = "H_Unlock"]
                     /\ hj' = hj
          /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                          jstate, doneWaiters, runs, stack, wj, j, n, forked, 
                          cur, ccur >>

H_Wait == /\ pc["host"] = "H_Wait"
          /\ /\ stack' = [stack EXCEPT !["host"] = << [ procedure |->  "WaitAndReap",
                                                        pc        |->  "H_Unlock",
                                                        wj        |->  wj["host"] ] >>
                                                    \o stack["host"]]
             /\ wj' = [wj EXCEPT !["host"] = hj]
          /\ pc' = [pc EXCEPT !["host"] = "WR_Load"]
          /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                          jstate, doneWaiters, runs, j, n, forked, hj, cur, 
                          ccur >>

H_Unlock == /\ pc["host"] = "H_Unlock"
            /\ Alive("host")
            /\ tm' = "none"
            /\ hj' = "none"
            /\ pc' = [pc EXCEPT !["host"] = "H_End"]
            /\ UNCHANGED << world, m, queue, outstanding, started, spawned, 
                            jstate, doneWaiters, runs, stack, wj, j, n, forked, 
                            cur, ccur >>

H_End == /\ pc["host"] = "H_End"
         /\ Alive("host")
         /\ TRUE
         /\ pc' = [pc EXCEPT !["host"] = "Done"]
         /\ UNCHANGED << world, m, tm, queue, outstanding, started, spawned, 
                         jstate, doneWaiters, runs, stack, wj, j, n, forked, 
                         hj, cur, ccur >>

Host == H_Fork \/ H_Child \/ H_Tm \/ H_Pick \/ H_Wait \/ H_Unlock \/ H_End

W_Loop(self) == /\ pc[self] = "W_Loop"
                /\ pc' = [pc EXCEPT ![self] = "W_Take"]
                /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                spawned, jstate, doneWaiters, runs, stack, wj, 
                                j, n, forked, hj, cur, ccur >>

W_Take(self) == /\ pc[self] = "W_Take"
                /\ world = "parent" /\ m = "none" /\ spawned /\ queue # <<>>
                /\ cur' = [cur EXCEPT ![self] = Head(queue)]
                /\ IF MUTANT # "no_dequeue"
                      THEN /\ queue' = Tail(queue)
                      ELSE /\ TRUE
                           /\ queue' = queue
                /\ jstate' = [jstate EXCEPT ![cur'[self]] = "Running"]
                /\ runs' = [runs EXCEPT ![cur'[self]] = runs[cur'[self]] + 1]
                /\ pc' = [pc EXCEPT ![self] = "W_Run"]
                /\ UNCHANGED << world, m, tm, outstanding, started, spawned, 
                                doneWaiters, stack, wj, j, n, forked, hj, ccur >>

W_Run(self) == /\ pc[self] = "W_Run"
               /\ world = "parent"
               /\ TRUE
               /\ pc' = [pc EXCEPT ![self] = "W_Done"]
               /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                               spawned, jstate, doneWaiters, runs, stack, wj, 
                               j, n, forked, hj, cur, ccur >>

W_Done(self) == /\ pc[self] = "W_Done"
                /\ IF MUTANT = "lost_wakeup"
                      THEN /\ world = "parent"
                      ELSE /\ world = "parent" /\ m = "none"
                /\ jstate' = [jstate EXCEPT ![cur[self]] = "Done"]
                /\ outstanding' = outstanding - 1
                /\ pc' = [pc EXCEPT ![self] = "W_Notify"]
                /\ UNCHANGED << world, m, tm, queue, started, spawned, 
                                doneWaiters, runs, stack, wj, j, n, forked, hj, 
                                cur, ccur >>

W_Notify(self) == /\ pc[self] = "W_Notify"
                  /\ world = "parent"
                  /\ doneWaiters' = {}
                  /\ cur' = [cur EXCEPT ![self] = "none"]
                  /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                  /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                  spawned, jstate, runs, stack, wj, j, n, 
                                  forked, hj, ccur >>

Worker(self) == W_Loop(self) \/ W_Take(self) \/ W_Run(self) \/ W_Done(self)
                   \/ W_Notify(self)

C_Loop(self) == /\ pc[self] = "C_Loop"
                /\ pc' = [pc EXCEPT ![self] = "C_Take"]
                /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                spawned, jstate, doneWaiters, runs, stack, wj, 
                                j, n, forked, hj, cur, ccur >>

C_Take(self) == /\ pc[self] = "C_Take"
                /\ world = "child" /\ m = "none" /\ spawned /\ queue # <<>>
                /\ ccur' = [ccur EXCEPT ![self] = Head(queue)]
                /\ queue' = Tail(queue)
                /\ jstate' = [jstate EXCEPT ![ccur'[self]] = "Running"]
                /\ runs' = [runs EXCEPT ![ccur'[self]] = runs[ccur'[self]] + 1]
                /\ pc' = [pc EXCEPT ![self] = "C_Done"]
                /\ UNCHANGED << world, m, tm, outstanding, started, spawned, 
                                doneWaiters, stack, wj, j, n, forked, hj, cur >>

C_Done(self) == /\ pc[self] = "C_Done"
                /\ world = "child" /\ m = "none"
                /\ jstate' = [jstate EXCEPT ![ccur[self]] = "Done"]
                /\ outstanding' = outstanding - 1
                /\ pc' = [pc EXCEPT ![self] = "C_Notify"]
                /\ UNCHANGED << world, m, tm, queue, started, spawned, 
                                doneWaiters, runs, stack, wj, j, n, forked, hj, 
                                cur, ccur >>

C_Notify(self) == /\ pc[self] = "C_Notify"
                  /\ world = "child"
                  /\ doneWaiters' = {}
                  /\ ccur' = [ccur EXCEPT ![self] = "none"]
                  /\ pc' = [pc EXCEPT ![self] = "C_Loop"]
                  /\ UNCHANGED << world, m, tm, queue, outstanding, started, 
                                  spawned, jstate, runs, stack, wj, j, n, 
                                  forked, hj, cur >>

CWorker(self) == C_Loop(self) \/ C_Take(self) \/ C_Done(self)
                    \/ C_Notify(self)

Next == Mutator \/ Host
           \/ (\E self \in ProcSet: DoFork(self) \/ WaitAndReap(self))
           \/ (\E self \in PWorkers: Worker(self))
           \/ (\E self \in CWorkers: CWorker(self))

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(Mutator) /\ WF_vars(WaitAndReap("mut")) /\ WF_vars(DoFork("mut"))
        /\ WF_vars(Host) /\ WF_vars(DoFork("host")) /\ WF_vars(WaitAndReap("host"))
        /\ \A self \in PWorkers : WF_vars(Worker(self))
        /\ \A self \in CWorkers : WF_vars(CWorker(self))

\* END TRANSLATION

-----------------------------------------------------------------------------
\* The properties that read procedure locals or pc of a named process, and
\* the liveness properties, are defined after the translation.

\* A job that some live thread will still move on: queued, run by a live
\* worker, or between the live poster's CAS and its enqueue (M_PostQ).
InFlight(x) == \/ x \in Range(queue)
               \/ \E w \in PWorkers : Alive(w) /\ cur[w] = x
               \/ \E w \in CWorkers : Alive(w) /\ ccur[w] = x
               \/ Alive("mut") /\ pc["mut"] = "M_PostQ" /\ j = x
\* CR-003: in the child, every Posted or Running job is in flight (the plan's
\* sketch said "still queued", which a child's own post or its own worker breaks).
ChildNoStranded ==
    world = "child" => \A x \in Jobs : jstate[x] \in {"Posted", "Running"} => InFlight(x)
\* PoolJob (provided to M7): wait() returns only when the job is Done.
WaitSeesDone == \A p \in {"mut", "host"} : pc[p] = "WR_Reap" => jstate[wj[p]] = "Done"
\* Liveness (parent): every posted job is eventually Done or reaped.
ParentJobsFinish ==
    \A x \in Jobs : (world = "parent" /\ jstate[x] = "Posted")
                        ~> (jstate[x] \in {"Done", "Idle"} \/ world = "child")
\* Liveness: the thread_mutex_ holder finishes its operations in the parent
\* (fails under lost_wakeup).
MutatorProgress == <>(world = "child" \/ pc["mut"] = "Done")
\* Liveness: a child forked by the mutator goes on using the pool: its posts
\* start fresh workers and its waits return (atforkChild's reset).
ChildProgress == (world = "child" /\ Forker = "mut") ~> (pc["mut"] = "Done")
\* Liveness: a child forked by another thread that uses the pool (or calls
\* exit(), whose ~Allocator takes thread_mutex_ and drains) does not hang.
\* Fails as built (CR-003, CR-015); the plan's step-7 resolutions must pass it.
HostChildProgress == (world = "child" /\ Forker = "host") ~> (pc["host"] = "Done")
=============================================================================
