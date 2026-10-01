----------------------------- MODULE TracePool -----------------------------
(***************************************************************************)
(* M6a trace validation (plans/threaded-gc-tla-M6-lifecycle.md §8;         *)
(* MAPPING.md A5): a recorded run of test/gc-helper-tsan/pool_trace.cpp    *)
(* (the real GCHelperPool, Concurrent mode) replayed against HelperPool's  *)
(* Next, in any order the log's happens-before allows (TraceAnyOrder).     *)
(*                                                                         *)
(* Threads: "mut" (the poster, M6a's Mutator; under a lock standing for    *)
(* thread_mutex_), "host" (a thread that forks), the pool's workers        *)
(* "eco-gc<i>" (Worker), and in a child's log the workers the child        *)
(* started (CWorker: the ones whose first event follows pool.child).       *)
(* Events (GCHelperPool.cpp's M6 hooks) and the model step each one is:    *)
(*   pool.cas job        post's CAS Idle -> Posted, under m_: M_PostCas     *)
(*                       (since register-fixes 7.2 the CAS, the start and  *)
(*                       the enqueue are one m_ section: one step)         *)
(*   pool.enq job out    the same section's enqueue: a check at M_PostDone *)
(*                       (outstanding = out)                               *)
(*   pool.take job       workerLoop's dequeue (Running): W_Take / C_Take   *)
(*   pool.done job out   workerLoop's Done under m_: W_Done / C_Done       *)
(*   pool.wfast job st   wait's load outside m_: WR_Load (state st)        *)
(*   pool.wchk job st    wait's predicate under m_: WR_Lock (state st)     *)
(*   pool.reset job      resetForReuse: WR_Reap                            *)
(*   pool.drained        prepare's m_.lock() and drain, one section:       *)
(*                       F_Drain (register-fixes 7.2: m_ stays held)       *)
(*   pool.plock          the same section, logged after the drain: a check *)
(*   pool.parent         atforkParent: F_Fork, parent branch               *)
(*   pool.child          atforkChild (in the child): F_Fork, child branch  *)
(* Hidden: the Mutator's control steps (M_Loop, M_Choose, M_PostDone,      *)
(* M_Wait, M_WaitDone, M_Next), the Host's (H_Fork, H_Child, H_End), the   *)
(* condition wait's block and wake (WR_Block, WR_Blocked), the fork's      *)
(* call and return (F_Tm: the harness's thread_mutex_ stand-in, locked by *)
(* its GCFork allocator layer; F_TmLast, F_Ret), the workers' W_Loop,      *)
(* W_Run, W_Notify, C_Loop, C_Notify, and a spurious wake-up (below).      *)
(***************************************************************************)
EXTENDS HelperPool, TraceAnyOrder

\* ---- constants from the log ------------------------------------------------
\* Job k of the log is the model's "j<k>" (the model's "no job" is the string "none").
J(k) == "j" \o ToString(k)
TP_Jobs == {J(k) : k \in 1..TraceHdr.jobs}
TP_Forker == IF TraceHdr.forker = "none" THEN "mut" ELSE TraceHdr.forker
TP_ForkAllowed == TraceHdr.forker # "none"
\* Every operation of the poster is a post (one pool.cas) or a wait (one
\* pool.wfast); a fork by the poster is one more.
TP_MaxOps == TraceCount("pool.cas") + TraceCount("pool.wfast")
             + (IF TraceHdr.forker = "mut" THEN 1 ELSE 0)
TP_Workers == TraceThreads \ {"mut", "host"}
TP_ChildAt == IF TraceCount("pool.child") = 0 THEN TraceLen + 1
              ELSE CHOOSE i \in 1..TraceLen : TraceLog[i].ev = "pool.child"
\* A worker the child started logs nothing before pool.child.
TP_PWorkers == {u \in TP_Workers : TraceHdr.tev[u][1] < TP_ChildAt}
TP_CWorkers == TP_Workers \ TP_PWorkers

St(k) == CASE k = 0 -> "Idle" [] k = 1 -> "Posted" [] k = 2 -> "Running" [] OTHER -> "Done"

\* ---- matched steps ---------------------------------------------------------
Matched(u, e) ==
    CASE e.ev = "pool.cas" ->
            u = "mut" /\ j = J(e.job) /\ M_PostCas
      [] e.ev = "pool.enq" ->
            u = "mut" /\ j = J(e.job) /\ pc["mut"] = "M_PostDone" /\ outstanding = e.out
            /\ UNCHANGED vars
      [] e.ev = "pool.take" ->
            IF u \in PWorkers THEN W_Take(u) /\ cur'[u] = J(e.job)
            ELSE u \in CWorkers /\ C_Take(u) /\ ccur'[u] = J(e.job)
      [] e.ev = "pool.done" ->
            /\ outstanding' = e.out
            /\ IF u \in PWorkers THEN cur[u] = J(e.job) /\ W_Done(u)
               ELSE u \in CWorkers /\ ccur[u] = J(e.job) /\ C_Done(u)
      [] e.ev = "pool.wfast" ->
            wj[u] = J(e.job) /\ jstate[J(e.job)] = St(e.st) /\ WR_Load(u)
      [] e.ev = "pool.wchk" ->
            wj[u] = J(e.job) /\ jstate[J(e.job)] = St(e.st) /\ WR_Lock(u)
      [] e.ev = "pool.reset" ->
            wj[u] = J(e.job) /\ WR_Reap(u)
      [] e.ev = "pool.drained" -> F_Drain(u)
      [] e.ev = "pool.plock" -> pc[u] = "F_TmLast" /\ m = u /\ UNCHANGED vars
      [] e.ev = "pool.parent" -> F_Fork(u) /\ world' = "parent"
      [] e.ev = "pool.child" -> F_Fork(u) /\ world' = "child"
      [] OTHER -> FALSE                       \* an event this spec does not know

\* ---- hidden steps: model steps the code does not log ----------------------
\* A condition variable may wake a waiter with no notify (the code re-checks
\* the predicate under m_, which the next pool.wchk logs). M6a has no such
\* step (its WR_Blocked waits for a W_Notify); the trace spec adds it, so a
\* real spurious wake-up is not a rejection.
SpuriousWake == \E p \in {"mut", "host"} :
                    /\ pc[p] = "WR_Blocked" /\ p \in doneWaiters
                    /\ doneWaiters' = doneWaiters \ {p}
                    /\ UNCHANGED <<world, m, tm, queue, outstanding, started, spawned, jstate, runs,
                                   pc, stack, wj, j, n, forked, hj, cur, ccur>>
Hidden ==
    \/ M_Loop \/ M_Choose \/ M_PostDone \/ M_Wait \/ M_WaitDone \/ M_Next
    \/ H_Fork \/ H_Child \/ H_End
    \/ \E p \in {"mut", "host"} : WR_Block(p) \/ WR_Blocked(p) \/ F_Tm(p) \/ F_TmLast(p) \/ F_Ret(p)
    \/ \E w \in PWorkers : W_Loop(w) \/ W_Run(w) \/ W_Notify(w)
    \/ \E w \in CWorkers : C_Loop(w) \/ C_Notify(w)
    \/ SpuriousWake

TraceInit == Init /\ TPInit
TraceNext == TPMatch(Matched) \/ (Hidden /\ UNCHANGED tpos)
=============================================================================
