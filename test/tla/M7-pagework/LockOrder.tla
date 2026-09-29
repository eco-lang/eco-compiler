------------------------------ MODULE LockOrder ------------------------------
(***************************************************************************)
(* M7b: the lock chain of a parallel minor whose promotion reaches the     *)
(* allocator (CR-007):                                                     *)
(*   promo_mu_ (minorwork::SpinMutex)                                      *)
(*     -> Allocator::thread_mutex_ (std::recursive_mutex)                  *)
(*       -> GCHelperPool::wait (PageWork::onReuse on a Posted discard, or  *)
(*          onRelease on an in-flight populate: CR-014's release route).   *)
(* and the other wait-for edge under thread_mutex_: the mutator's          *)
(* tenureTeardown -> collector->stopAndJoin() (cleanupThread,              *)
(* finishTenureForExit, reset), joining the 7c tenure collector.           *)
(* Pool workers take only the pool's m_, a leaf lock never held across a   *)
(* wait (cv_done_.wait releases it), so m_ is not modelled. The mutator is *)
(* gang member "mut".                                                      *)
(*                                                                         *)
(* plans/threaded-gc-tla-M7-pagework.md; MAPPING.md; AUDIT.md.             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Members,         \* parallel-minor gang members, including "mut" (worker 0)
    MUTANT           \* "none", "tm_then_promo", "worker_takes_tm",
                     \* "collector_takes_tm", "lost_wakeup"

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

\* pool.wait(job): the acquire fast path, then under m_ check Done, else block
\* (the wait releases m_); re-check on wake. The MUTANT lost_wakeup checks
\* outside m_ and then blocks without re-checking.
procedure PoolWait()
begin
  PW_Lock:
    if job = "Done" then
        return;
    elsif MUTANT = "lost_wakeup" then
        goto PW_Late;
    else
        waiting := waiting \cup {self};
    end if;
  PW_Blocked:
    await self \notin waiting;
    goto PW_Lock;
  PW_Late:
    waiting := waiting \cup {self};
    goto PW_Blocked;
end procedure;

\* allocatePromotion -> ladder -> startVirginBlockShared / allocateFromBagPage
\* -> ensureBagPageAvailable -> Allocator::acquireOldGenBlock (under promo_mu_).
\* Then, on the mutator only, a later tenureTeardown under thread_mutex_.
fair process Member \in Members
begin
  P_Promo:
    if MUTANT = "tm_then_promo" /\ self = "mut" then   \* a path taking the locks in reverse
        await TmFree(self);
        tmOwner := self; tmDepth := tmDepth + 1;
      P_ThenPromo:
        await promo = "none";
        promo := self;
        goto P_Release;
    else
        await promo = "none";                          \* SpinMutex::lock (spin/yield/sleep)
        promo := self;
    end if;
  P_Tm:                                                 \* lock_guard<recursive_mutex>
    await TmFree(self);
    tmOwner := self;
    tmDepth := tmDepth + 1;
  P_Pick:                                               \* first-fit meets the job's extent, once
    if ~reused then
        reused := TRUE;
      P_Reuse:                                          \* onReuse / onRelease -> awaitSlot -> wait
        if job # "Done" then call PoolWait(); end if;
    end if;
  P_Release:
    tmDepth := tmDepth - 1;                             \* ~lock_guard (recursive depth)
    if tmDepth = 0 then tmOwner := "none"; end if;
  P_Unpromo:
    promo := "none";
    if self = "mut" then                                \* later, outside the pause:
      T_Tm:                                             \* cleanupThread / finishTenureForExit
        await TmFree(self);
        tmOwner := self; tmDepth := tmDepth + 1;
      T_Join:                                           \* tenureTeardown -> stopAndJoin()
        await pc["coll"] = "Done";
      T_Rel:
        tmDepth := tmDepth - 1;
        if tmDepth = 0 then tmOwner := "none"; end if;
    end if;
end process;

\* A pool worker running the job (M6's workerLoop; it takes only m_).
fair process Worker = "w1"
begin
  W_Take:                                               \* dequeue under m_
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
  W_Notify:                                             \* cv_done_.notify_all (outside m_)
    waiting := {};
end process;

\* The 7c tenure collector (a GCBackgroundGang member): it allocates from its
\* grant (grantAllocateShared) and takes no allocator lock ...
fair process Collector = "coll"
begin
  C_Work:
    if MUTANT = "collector_takes_tm" then               \* ... unless it refills through
        await tmOwner = "none";                         \* acquireOldGenBlock
        tmOwner := "coll"; tmDepth := 1;
      C_WorkRel:
        tmOwner := "none"; tmDepth := 0;
    end if;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, promo, tmOwner, tmDepth, job, reused, waiting, stack

(* define statement *)
TmFree(p) == tmOwner \in {"none", p}


vars == << pc, promo, tmOwner, tmDepth, job, reused, waiting, stack >>

ProcSet == (Members) \cup {"w1"} \cup {"coll"}

Init == (* Global variables *)
        /\ promo = "none"
        /\ tmOwner = "none"
        /\ tmDepth = 0
        /\ job = "Posted"
        /\ reused = FALSE
        /\ waiting = {}
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self \in Members -> "P_Promo"
                                        [] self = "w1" -> "W_Take"
                                        [] self = "coll" -> "C_Work"]

PW_Lock(self) == /\ pc[self] = "PW_Lock"
                 /\ IF job = "Done"
                       THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                            /\ UNCHANGED waiting
                       ELSE /\ IF MUTANT = "lost_wakeup"
                                  THEN /\ pc' = [pc EXCEPT ![self] = "PW_Late"]
                                       /\ UNCHANGED waiting
                                  ELSE /\ waiting' = (waiting \cup {self})
                                       /\ pc' = [pc EXCEPT ![self] = "PW_Blocked"]
                            /\ stack' = stack
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused >>

PW_Blocked(self) == /\ pc[self] = "PW_Blocked"
                    /\ self \notin waiting
                    /\ pc' = [pc EXCEPT ![self] = "PW_Lock"]
                    /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, 
                                    waiting, stack >>

PW_Late(self) == /\ pc[self] = "PW_Late"
                 /\ waiting' = (waiting \cup {self})
                 /\ pc' = [pc EXCEPT ![self] = "PW_Blocked"]
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, stack >>

PoolWait(self) == PW_Lock(self) \/ PW_Blocked(self) \/ PW_Late(self)

P_Promo(self) == /\ pc[self] = "P_Promo"
                 /\ IF MUTANT = "tm_then_promo" /\ self = "mut"
                       THEN /\ TmFree(self)
                            /\ tmOwner' = self
                            /\ tmDepth' = tmDepth + 1
                            /\ pc' = [pc EXCEPT ![self] = "P_ThenPromo"]
                            /\ promo' = promo
                       ELSE /\ promo = "none"
                            /\ promo' = self
                            /\ pc' = [pc EXCEPT ![self] = "P_Tm"]
                            /\ UNCHANGED << tmOwner, tmDepth >>
                 /\ UNCHANGED << job, reused, waiting, stack >>

P_ThenPromo(self) == /\ pc[self] = "P_ThenPromo"
                     /\ promo = "none"
                     /\ promo' = self
                     /\ pc' = [pc EXCEPT ![self] = "P_Release"]
                     /\ UNCHANGED << tmOwner, tmDepth, job, reused, waiting, 
                                     stack >>

P_Tm(self) == /\ pc[self] = "P_Tm"
              /\ TmFree(self)
              /\ tmOwner' = self
              /\ tmDepth' = tmDepth + 1
              /\ pc' = [pc EXCEPT ![self] = "P_Pick"]
              /\ UNCHANGED << promo, job, reused, waiting, stack >>

P_Pick(self) == /\ pc[self] = "P_Pick"
                /\ IF ~reused
                      THEN /\ reused' = TRUE
                           /\ pc' = [pc EXCEPT ![self] = "P_Reuse"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "P_Release"]
                           /\ UNCHANGED reused
                /\ UNCHANGED << promo, tmOwner, tmDepth, job, waiting, stack >>

P_Reuse(self) == /\ pc[self] = "P_Reuse"
                 /\ IF job # "Done"
                       THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PoolWait",
                                                                     pc        |->  "P_Release" ] >>
                                                                 \o stack[self]]
                            /\ pc' = [pc EXCEPT ![self] = "PW_Lock"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "P_Release"]
                            /\ stack' = stack
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting >>

P_Release(self) == /\ pc[self] = "P_Release"
                   /\ tmDepth' = tmDepth - 1
                   /\ IF tmDepth' = 0
                         THEN /\ tmOwner' = "none"
                         ELSE /\ TRUE
                              /\ UNCHANGED tmOwner
                   /\ pc' = [pc EXCEPT ![self] = "P_Unpromo"]
                   /\ UNCHANGED << promo, job, reused, waiting, stack >>

P_Unpromo(self) == /\ pc[self] = "P_Unpromo"
                   /\ promo' = "none"
                   /\ IF self = "mut"
                         THEN /\ pc' = [pc EXCEPT ![self] = "T_Tm"]
                         ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                   /\ UNCHANGED << tmOwner, tmDepth, job, reused, waiting, 
                                   stack >>

T_Tm(self) == /\ pc[self] = "T_Tm"
              /\ TmFree(self)
              /\ tmOwner' = self
              /\ tmDepth' = tmDepth + 1
              /\ pc' = [pc EXCEPT ![self] = "T_Join"]
              /\ UNCHANGED << promo, job, reused, waiting, stack >>

T_Join(self) == /\ pc[self] = "T_Join"
                /\ pc["coll"] = "Done"
                /\ pc' = [pc EXCEPT ![self] = "T_Rel"]
                /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                                stack >>

T_Rel(self) == /\ pc[self] = "T_Rel"
               /\ tmDepth' = tmDepth - 1
               /\ IF tmDepth' = 0
                     THEN /\ tmOwner' = "none"
                     ELSE /\ TRUE
                          /\ UNCHANGED tmOwner
               /\ pc' = [pc EXCEPT ![self] = "Done"]
               /\ UNCHANGED << promo, job, reused, waiting, stack >>

Member(self) == P_Promo(self) \/ P_ThenPromo(self) \/ P_Tm(self)
                   \/ P_Pick(self) \/ P_Reuse(self) \/ P_Release(self)
                   \/ P_Unpromo(self) \/ T_Tm(self) \/ T_Join(self)
                   \/ T_Rel(self)

W_Take == /\ pc["w1"] = "W_Take"
          /\ job = "Posted"
          /\ job' = "Running"
          /\ pc' = [pc EXCEPT !["w1"] = "W_Body"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, reused, waiting, stack >>

W_Body == /\ pc["w1"] = "W_Body"
          /\ IF MUTANT = "worker_takes_tm"
                THEN /\ tmOwner = "none"
                     /\ tmOwner' = "w1"
                     /\ tmDepth' = 1
                     /\ pc' = [pc EXCEPT !["w1"] = "W_BodyRel"]
                ELSE /\ pc' = [pc EXCEPT !["w1"] = "W_Done"]
                     /\ UNCHANGED << tmOwner, tmDepth >>
          /\ UNCHANGED << promo, job, reused, waiting, stack >>

W_BodyRel == /\ pc["w1"] = "W_BodyRel"
             /\ tmOwner' = "none"
             /\ tmDepth' = 0
             /\ pc' = [pc EXCEPT !["w1"] = "W_Done"]
             /\ UNCHANGED << promo, job, reused, waiting, stack >>

W_Done == /\ pc["w1"] = "W_Done"
          /\ job' = "Done"
          /\ pc' = [pc EXCEPT !["w1"] = "W_Notify"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, reused, waiting, stack >>

W_Notify == /\ pc["w1"] = "W_Notify"
            /\ waiting' = {}
            /\ pc' = [pc EXCEPT !["w1"] = "Done"]
            /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, stack >>

Worker == W_Take \/ W_Body \/ W_BodyRel \/ W_Done \/ W_Notify

C_Work == /\ pc["coll"] = "C_Work"
          /\ IF MUTANT = "collector_takes_tm"
                THEN /\ tmOwner = "none"
                     /\ tmOwner' = "coll"
                     /\ tmDepth' = 1
                     /\ pc' = [pc EXCEPT !["coll"] = "C_WorkRel"]
                ELSE /\ pc' = [pc EXCEPT !["coll"] = "Done"]
                     /\ UNCHANGED << tmOwner, tmDepth >>
          /\ UNCHANGED << promo, job, reused, waiting, stack >>

C_WorkRel == /\ pc["coll"] = "C_WorkRel"
             /\ tmOwner' = "none"
             /\ tmDepth' = 0
             /\ pc' = [pc EXCEPT !["coll"] = "Done"]
             /\ UNCHANGED << promo, job, reused, waiting, stack >>

Collector == C_Work \/ C_WorkRel

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Worker \/ Collector
           \/ (\E self \in ProcSet: PoolWait(self))
           \/ (\E self \in Members: Member(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Members : WF_vars(Member(self)) /\ WF_vars(PoolWait(self))
        /\ WF_vars(Worker)
        /\ WF_vars(Collector)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

-----------------------------------------------------------------------------
\* Liveness: every thread finishes (no starvation behind the spin lock while
\* the holder waits for the helper; the teardown's join returns).
AllFinish == <>(\A p \in ProcSet : pc[p] = "Done")

\* CR-007's stall, as a reachability witness (expected: VIOLATED in
\* lock_order_stall): one member holds promo_mu_ and thread_mutex_ and is
\* blocked in wait, while another waits for promo_mu_.
MODEL_M7_StallWitness ==
    ~\E p, q \in Members : /\ p # q /\ promo = p /\ tmOwner = p
                           /\ p \in waiting /\ pc[q] = "P_Promo"
=============================================================================
