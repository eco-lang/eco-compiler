------------------------------ MODULE LockOrder ------------------------------
(***************************************************************************)
(* M7b: the lock chain of a parallel minor whose promotion reaches the     *)
(* allocator (CR-007):                                                     *)
(*   promo_mu_ (minorwork::SpinMutex)                                      *)
(*     -> Allocator::thread_mutex_ (std::recursive_mutex)                  *)
(*       -> GCHelperPool::wait (PageWork::onReuse on a Posted discard, or  *)
(*          onRelease on an in-flight populate: CR-014's release route).   *)
(* The parallel minor is a GCMarkGang::run: its caller ("mut", member 0)   *)
(* holds run_m_ until every member returned. After the minor the mutator   *)
(* tears the 7c tenure collector down (cleanupThread, finishTenureForExit, *)
(* reset -> tenureTeardown -> collector->stopAndJoin()), which takes the   *)
(* collector gang's m_ -- since register-fixes §7.2 step 2 (HEAP_075)      *)
(* OUTSIDE thread_mutex_ (mutant teardown_under_tm: the pre-fix hold).     *)
(* With Fork, a thread forks: GCFork's one prepare takes, in order, the    *)
(* collector gang's m_ (after stopping it: stopAllForFork), run_m_,        *)
(* thread_mutex_, then drains the pool and holds its m_ (register-fixes    *)
(* §7.1; mutant fork_tm_first: thread_mutex_ first).                       *)
(* Pool workers take only the pool's m_, a leaf lock never held across a   *)
(* wait (cv_done_.wait releases it), so m_ is not modelled: the forker's   *)
(* drain is "the job is Done".                                             *)
(*                                                                         *)
(* plans/threaded-gc-tla-M7-pagework.md; MAPPING.md; AUDIT.md.             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Members,         \* parallel-minor gang members, including "mut" (worker 0)
    CapExhausted,    \* CR-007: the old-gen cap leaves no fresh bump room, so the
                     \* no-wait acquire falls back to first fit (and may wait)
    Fork,            \* another thread forks once (GCFork's prepare, HEAP_075)
    MUTANT           \* a SET of: "tm_then_promo", "worker_takes_tm",
                     \* "collector_takes_tm", "lost_wakeup", "nowait_off",
                     \* "teardown_under_tm", "fork_tm_first"

(* --algorithm LockOrder
variables
    promo   = "none",            \* promo_mu_ holder
    tmOwner = "none",            \* thread_mutex_ owner (recursive: depth below)
    tmDepth = 0,
    job     = "Posted",          \* the helper job whose extent the chain meets
    reused  = FALSE,             \* that extent was handed out (once)
    waiting = {},                \* blocked in cv_done_.wait
    runM    = "none",            \* GCMarkGang::run_m_ holder
    runGo   = FALSE,             \* the run started its members
    bm      = "none";            \* the collector gang's GCBackgroundGang::m_ holder

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
    elsif "lost_wakeup" \in MUTANT then
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
\* "mut" runs the gang (run_m_); the others start when the run starts them.
\* Then, on the mutator only, the run's join and a later tenureTeardown.
fair process Member \in Members
begin
  R_Run:                                                \* GCMarkGang::run: run_m_, start members
    if self = "mut" then
        await runM = "none";
        runM := self;
        runGo := TRUE;
    else
        await runGo;                                    \* memberLoop: woken by the run
    end if;
  P_Promo:
    if "tm_then_promo" \in MUTANT /\ self = "mut" then   \* a path taking the locks in reverse
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
    \* CR-007 (register-fixes 6.3): a promo_mu_ holder with n > 1 workers takes
    \* only Pending extents (never this Posted one), else a fresh bump; it
    \* reuses the Posted extent (and may wait) only when the cap leaves no bump
    \* room. The CR-014 release route (onRelease awaiting a populate) exists
    \* only with one worker since CR-014's fix (MAPPING §4), so with Members of
    \* two or more it is not a route here.
    if ~reused /\ (CapExhausted \/ "nowait_off" \in MUTANT) then
        reused := TRUE;
      P_Reuse:                                          \* onReuse -> awaitSlot -> wait
        if job # "Done" then call PoolWait(); end if;
    end if;
  P_Release:
    tmDepth := tmDepth - 1;                             \* ~lock_guard (recursive depth)
    if tmDepth = 0 then tmOwner := "none"; end if;
  P_Unpromo:
    promo := "none";
    if self = "mut" then                                \* later, outside the pause:
      R_Join:                                           \* run's cv_done_.wait, then run_m_ released
        await \A q \in Members \ {"mut"} : pc[q] = "Done";
        runM := "none";
      T_Tm:                                             \* cleanupThread / finishTenureForExit:
        if "teardown_under_tm" \in MUTANT then          \* mutant: the pre-fix thread_mutex_ hold
            await TmFree(self);
            tmOwner := self; tmDepth := tmDepth + 1;
        end if;
      T_JLock:                                          \* tenureTeardown -> stopAndJoin(): m_
        await bm = "none";
      T_Join:                                           \* joinLocked (releases m_ while waiting)
        await pc["coll"] = "Done";
      T_Rel:
        if "teardown_under_tm" \in MUTANT then
            tmDepth := tmDepth - 1;
            if tmDepth = 0 then tmOwner := "none"; end if;
        end if;
    end if;
end process;

\* A pool worker running the job (M6's workerLoop; it takes only m_).
fair process Worker = "w1"
begin
  W_Take:                                               \* dequeue under m_
    await job = "Posted";
    job := "Running";
  W_Body:                                               \* madvise: no allocator lock ...
    if "worker_takes_tm" \in MUTANT then                \* ... unless a job calls back in
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
    if "collector_takes_tm" \in MUTANT then             \* ... unless it refills through
        await tmOwner = "none";                         \* acquireOldGenBlock
        tmOwner := "coll"; tmDepth := 1;
      C_WorkRel:
        tmOwner := "none"; tmDepth := 0;
    end if;
end process;

\* Another thread forks once (Fork): GCFork's prepare, layers in order
\* (registry and the fork hold are not modelled: nothing else in this model
\* takes them). The parent handlers release everything at F_Fork.
fair process Forker = "fork"
begin
  F_TmFirst:                                            \* mutant fork_tm_first: thread_mutex_ first
    if Fork /\ "fork_tm_first" \in MUTANT then
        await tmOwner = "none";
        tmOwner := "fork"; tmDepth := 1;
    end if;
  F_Stop:                                               \* stopAllForFork -> stopAndJoin: m_, stop
    if Fork then
        await bm = "none";
      F_StopWait:                                       \* joinLocked (releases m_ while waiting)
        await pc["coll"] = "Done";
      F_Bm:                                             \* then every gang's m_, held across fork
        await bm = "none";
        bm := "fork";
      F_RunM:                                           \* GCMarkGang's prepare: run_m_ (then its m_)
        await runM = "none";
        runM := "fork";
      F_Tm:                                             \* the allocator layer: thread_mutex_
        if "fork_tm_first" \notin MUTANT then
            await tmOwner = "none";
            tmOwner := "fork"; tmDepth := 1;
        end if;
      F_Pool:                                           \* the census leaf; the pool: drain under m_
        await job = "Done";
      F_Fork:                                           \* fork(); the parent handlers unlock
        bm := "none";
        runM := "none";
        tmOwner := "none"; tmDepth := 0;
    end if;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, promo, tmOwner, tmDepth, job, reused, waiting, runM, runGo, bm, 
          stack

(* define statement *)
TmFree(p) == tmOwner \in {"none", p}


vars == << pc, promo, tmOwner, tmDepth, job, reused, waiting, runM, runGo, bm, 
           stack >>

ProcSet == (Members) \cup {"w1"} \cup {"coll"} \cup {"fork"}

Init == (* Global variables *)
        /\ promo = "none"
        /\ tmOwner = "none"
        /\ tmDepth = 0
        /\ job = "Posted"
        /\ reused = FALSE
        /\ waiting = {}
        /\ runM = "none"
        /\ runGo = FALSE
        /\ bm = "none"
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self \in Members -> "R_Run"
                                        [] self = "w1" -> "W_Take"
                                        [] self = "coll" -> "C_Work"
                                        [] self = "fork" -> "F_TmFirst"]

PW_Lock(self) == /\ pc[self] = "PW_Lock"
                 /\ IF job = "Done"
                       THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                            /\ UNCHANGED waiting
                       ELSE /\ IF "lost_wakeup" \in MUTANT
                                  THEN /\ pc' = [pc EXCEPT ![self] = "PW_Late"]
                                       /\ UNCHANGED waiting
                                  ELSE /\ waiting' = (waiting \cup {self})
                                       /\ pc' = [pc EXCEPT ![self] = "PW_Blocked"]
                            /\ stack' = stack
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, runM, 
                                 runGo, bm >>

PW_Blocked(self) == /\ pc[self] = "PW_Blocked"
                    /\ self \notin waiting
                    /\ pc' = [pc EXCEPT ![self] = "PW_Lock"]
                    /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, 
                                    waiting, runM, runGo, bm, stack >>

PW_Late(self) == /\ pc[self] = "PW_Late"
                 /\ waiting' = (waiting \cup {self})
                 /\ pc' = [pc EXCEPT ![self] = "PW_Blocked"]
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, runM, 
                                 runGo, bm, stack >>

PoolWait(self) == PW_Lock(self) \/ PW_Blocked(self) \/ PW_Late(self)

R_Run(self) == /\ pc[self] = "R_Run"
               /\ IF self = "mut"
                     THEN /\ runM = "none"
                          /\ runM' = self
                          /\ runGo' = TRUE
                     ELSE /\ runGo
                          /\ UNCHANGED << runM, runGo >>
               /\ pc' = [pc EXCEPT ![self] = "P_Promo"]
               /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                               bm, stack >>

P_Promo(self) == /\ pc[self] = "P_Promo"
                 /\ IF "tm_then_promo" \in MUTANT /\ self = "mut"
                       THEN /\ TmFree(self)
                            /\ tmOwner' = self
                            /\ tmDepth' = tmDepth + 1
                            /\ pc' = [pc EXCEPT ![self] = "P_ThenPromo"]
                            /\ promo' = promo
                       ELSE /\ promo = "none"
                            /\ promo' = self
                            /\ pc' = [pc EXCEPT ![self] = "P_Tm"]
                            /\ UNCHANGED << tmOwner, tmDepth >>
                 /\ UNCHANGED << job, reused, waiting, runM, runGo, bm, stack >>

P_ThenPromo(self) == /\ pc[self] = "P_ThenPromo"
                     /\ promo = "none"
                     /\ promo' = self
                     /\ pc' = [pc EXCEPT ![self] = "P_Release"]
                     /\ UNCHANGED << tmOwner, tmDepth, job, reused, waiting, 
                                     runM, runGo, bm, stack >>

P_Tm(self) == /\ pc[self] = "P_Tm"
              /\ TmFree(self)
              /\ tmOwner' = self
              /\ tmDepth' = tmDepth + 1
              /\ pc' = [pc EXCEPT ![self] = "P_Pick"]
              /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, 
                              stack >>

P_Pick(self) == /\ pc[self] = "P_Pick"
                /\ IF ~reused /\ (CapExhausted \/ "nowait_off" \in MUTANT)
                      THEN /\ reused' = TRUE
                           /\ pc' = [pc EXCEPT ![self] = "P_Reuse"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "P_Release"]
                           /\ UNCHANGED reused
                /\ UNCHANGED << promo, tmOwner, tmDepth, job, waiting, runM, 
                                runGo, bm, stack >>

P_Reuse(self) == /\ pc[self] = "P_Reuse"
                 /\ IF job # "Done"
                       THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PoolWait",
                                                                     pc        |->  "P_Release" ] >>
                                                                 \o stack[self]]
                            /\ pc' = [pc EXCEPT ![self] = "PW_Lock"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "P_Release"]
                            /\ stack' = stack
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                                 runM, runGo, bm >>

P_Release(self) == /\ pc[self] = "P_Release"
                   /\ tmDepth' = tmDepth - 1
                   /\ IF tmDepth' = 0
                         THEN /\ tmOwner' = "none"
                         ELSE /\ TRUE
                              /\ UNCHANGED tmOwner
                   /\ pc' = [pc EXCEPT ![self] = "P_Unpromo"]
                   /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, 
                                   bm, stack >>

P_Unpromo(self) == /\ pc[self] = "P_Unpromo"
                   /\ promo' = "none"
                   /\ IF self = "mut"
                         THEN /\ pc' = [pc EXCEPT ![self] = "R_Join"]
                         ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                   /\ UNCHANGED << tmOwner, tmDepth, job, reused, waiting, 
                                   runM, runGo, bm, stack >>

R_Join(self) == /\ pc[self] = "R_Join"
                /\ \A q \in Members \ {"mut"} : pc[q] = "Done"
                /\ runM' = "none"
                /\ pc' = [pc EXCEPT ![self] = "T_Tm"]
                /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                                runGo, bm, stack >>

T_Tm(self) == /\ pc[self] = "T_Tm"
              /\ IF "teardown_under_tm" \in MUTANT
                    THEN /\ TmFree(self)
                         /\ tmOwner' = self
                         /\ tmDepth' = tmDepth + 1
                    ELSE /\ TRUE
                         /\ UNCHANGED << tmOwner, tmDepth >>
              /\ pc' = [pc EXCEPT ![self] = "T_JLock"]
              /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, 
                              stack >>

T_JLock(self) == /\ pc[self] = "T_JLock"
                 /\ bm = "none"
                 /\ pc' = [pc EXCEPT ![self] = "T_Join"]
                 /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                                 runM, runGo, bm, stack >>

T_Join(self) == /\ pc[self] = "T_Join"
                /\ pc["coll"] = "Done"
                /\ pc' = [pc EXCEPT ![self] = "T_Rel"]
                /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                                runM, runGo, bm, stack >>

T_Rel(self) == /\ pc[self] = "T_Rel"
               /\ IF "teardown_under_tm" \in MUTANT
                     THEN /\ tmDepth' = tmDepth - 1
                          /\ IF tmDepth' = 0
                                THEN /\ tmOwner' = "none"
                                ELSE /\ TRUE
                                     /\ UNCHANGED tmOwner
                     ELSE /\ TRUE
                          /\ UNCHANGED << tmOwner, tmDepth >>
               /\ pc' = [pc EXCEPT ![self] = "Done"]
               /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, 
                               stack >>

Member(self) == R_Run(self) \/ P_Promo(self) \/ P_ThenPromo(self)
                   \/ P_Tm(self) \/ P_Pick(self) \/ P_Reuse(self)
                   \/ P_Release(self) \/ P_Unpromo(self) \/ R_Join(self)
                   \/ T_Tm(self) \/ T_JLock(self) \/ T_Join(self)
                   \/ T_Rel(self)

W_Take == /\ pc["w1"] = "W_Take"
          /\ job = "Posted"
          /\ job' = "Running"
          /\ pc' = [pc EXCEPT !["w1"] = "W_Body"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, reused, waiting, runM, 
                          runGo, bm, stack >>

W_Body == /\ pc["w1"] = "W_Body"
          /\ IF "worker_takes_tm" \in MUTANT
                THEN /\ tmOwner = "none"
                     /\ tmOwner' = "w1"
                     /\ tmDepth' = 1
                     /\ pc' = [pc EXCEPT !["w1"] = "W_BodyRel"]
                ELSE /\ pc' = [pc EXCEPT !["w1"] = "W_Done"]
                     /\ UNCHANGED << tmOwner, tmDepth >>
          /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, stack >>

W_BodyRel == /\ pc["w1"] = "W_BodyRel"
             /\ tmOwner' = "none"
             /\ tmDepth' = 0
             /\ pc' = [pc EXCEPT !["w1"] = "W_Done"]
             /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, 
                             stack >>

W_Done == /\ pc["w1"] = "W_Done"
          /\ job' = "Done"
          /\ pc' = [pc EXCEPT !["w1"] = "W_Notify"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, reused, waiting, runM, 
                          runGo, bm, stack >>

W_Notify == /\ pc["w1"] = "W_Notify"
            /\ waiting' = {}
            /\ pc' = [pc EXCEPT !["w1"] = "Done"]
            /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, runM, runGo, 
                            bm, stack >>

Worker == W_Take \/ W_Body \/ W_BodyRel \/ W_Done \/ W_Notify

C_Work == /\ pc["coll"] = "C_Work"
          /\ IF "collector_takes_tm" \in MUTANT
                THEN /\ tmOwner = "none"
                     /\ tmOwner' = "coll"
                     /\ tmDepth' = 1
                     /\ pc' = [pc EXCEPT !["coll"] = "C_WorkRel"]
                ELSE /\ pc' = [pc EXCEPT !["coll"] = "Done"]
                     /\ UNCHANGED << tmOwner, tmDepth >>
          /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, stack >>

C_WorkRel == /\ pc["coll"] = "C_WorkRel"
             /\ tmOwner' = "none"
             /\ tmDepth' = 0
             /\ pc' = [pc EXCEPT !["coll"] = "Done"]
             /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, 
                             stack >>

Collector == C_Work \/ C_WorkRel

F_TmFirst == /\ pc["fork"] = "F_TmFirst"
             /\ IF Fork /\ "fork_tm_first" \in MUTANT
                   THEN /\ tmOwner = "none"
                        /\ tmOwner' = "fork"
                        /\ tmDepth' = 1
                   ELSE /\ TRUE
                        /\ UNCHANGED << tmOwner, tmDepth >>
             /\ pc' = [pc EXCEPT !["fork"] = "F_Stop"]
             /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, 
                             stack >>

F_Stop == /\ pc["fork"] = "F_Stop"
          /\ IF Fork
                THEN /\ bm = "none"
                     /\ pc' = [pc EXCEPT !["fork"] = "F_StopWait"]
                ELSE /\ pc' = [pc EXCEPT !["fork"] = "Done"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, runM, 
                          runGo, bm, stack >>

F_StopWait == /\ pc["fork"] = "F_StopWait"
              /\ pc["coll"] = "Done"
              /\ pc' = [pc EXCEPT !["fork"] = "F_Bm"]
              /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, 
                              runM, runGo, bm, stack >>

F_Bm == /\ pc["fork"] = "F_Bm"
        /\ bm = "none"
        /\ bm' = "fork"
        /\ pc' = [pc EXCEPT !["fork"] = "F_RunM"]
        /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, runM, 
                        runGo, stack >>

F_RunM == /\ pc["fork"] = "F_RunM"
          /\ runM = "none"
          /\ runM' = "fork"
          /\ pc' = [pc EXCEPT !["fork"] = "F_Tm"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, runGo, 
                          bm, stack >>

F_Tm == /\ pc["fork"] = "F_Tm"
        /\ IF "fork_tm_first" \notin MUTANT
              THEN /\ tmOwner = "none"
                   /\ tmOwner' = "fork"
                   /\ tmDepth' = 1
              ELSE /\ TRUE
                   /\ UNCHANGED << tmOwner, tmDepth >>
        /\ pc' = [pc EXCEPT !["fork"] = "F_Pool"]
        /\ UNCHANGED << promo, job, reused, waiting, runM, runGo, bm, stack >>

F_Pool == /\ pc["fork"] = "F_Pool"
          /\ job = "Done"
          /\ pc' = [pc EXCEPT !["fork"] = "F_Fork"]
          /\ UNCHANGED << promo, tmOwner, tmDepth, job, reused, waiting, runM, 
                          runGo, bm, stack >>

F_Fork == /\ pc["fork"] = "F_Fork"
          /\ bm' = "none"
          /\ runM' = "none"
          /\ tmOwner' = "none"
          /\ tmDepth' = 0
          /\ pc' = [pc EXCEPT !["fork"] = "Done"]
          /\ UNCHANGED << promo, job, reused, waiting, runGo, stack >>

Forker == F_TmFirst \/ F_Stop \/ F_StopWait \/ F_Bm \/ F_RunM \/ F_Tm
             \/ F_Pool \/ F_Fork

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Worker \/ Collector \/ Forker
           \/ (\E self \in ProcSet: PoolWait(self))
           \/ (\E self \in Members: Member(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Members : WF_vars(Member(self)) /\ WF_vars(PoolWait(self))
        /\ WF_vars(Worker)
        /\ WF_vars(Collector)
        /\ WF_vars(Forker)

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
