-------------------------------- MODULE Gangs --------------------------------
(***************************************************************************)
(* M6b: GCBackgroundGang (launch / join / stopAndJoin / running /          *)
(* finishedApprox), the 5c episode driver that uses it (reapBackground,    *)
(* the relaunch after a stop, closingFinish over GCMarkGang::run), the     *)
(* 7c tenure collector as an optional second gang (tenureJoin's join,      *)
(* stop and orphan paths), GCFork's gangs-layer prepare (register-fixes    *)
(* §7.1: the fork hold, then stopAllForFork, then the gangs' m_, then      *)
(* run_m_; PrepareOrder "mark_first" keeps the pre-GCFork order as a       *)
(* robustness variant), with fork() by the mutator or by another thread, a *)
(* foreign stopAndJoin (ForeignStop), and stopAllAtExit on the mutator's   *)
(* own exit(). The marker loop and the tenure job are reduced to M2's      *)
(* Drain contract (procedure Mark).                                        *)
(* Plan: plans/threaded-gc-tla-M6-lifecycle.md. MAPPING.md maps every      *)
(* label to the code; AUDIT.md records the results.                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Forker,          \* "mut" or "host"
    ForkAllowed,     \* the forker may fork once
    PrepareOrder,    \* "bg_first" (GCFork's fixed order: the background gangs, then the
                     \* mark gang) or "mark_first" (the pre-GCFork order when the mark gang
                     \* registered last; kept as a variant the fix must also pass)
    ExitAllowed,     \* the mutator may call exit() between pauses (stopAllAtExit)
    Work0,           \* grey entries at the t0 launch
    Steps,           \* ordinary minor ends before the closing step
    B,               \* members of the 5c background gang (1 or 2)
    MarkThreads,     \* mark_threads_: 2 (GCMarkGang::run takes run_m_), or 1 (one CPU:
                     \* run(n = 1) calls the closing member inline, no lock, no member)
    TwoGangs,        \* the 7c tenure collector is a second registered gang
    ForeignStop,     \* the host may call stopAndJoin on the 5c gang without a fork (exit,
                     \* reset, a test): no fork hold protects that stop (CR-023)
    RelaunchWaitsStopper, \* a relaunched 5c episode's member finishes only after a pending
                     \* foreign stop returned (an episode that waits on the stopper's
                     \* thread: the CR-023 stall becomes a deadlock)
    MUTANT           \* "none", "running_after_notify", "join_no_wait", "no_stop_in_prepare",
                     \* "run_no_wait", "join_in_run", "relaunch_unreaped", "child_no_unlock";
                     \* the pre-fix behaviours (register-fixes §7.2 step 9, A6): "no_fork_hold",
                     \* "hold_after_stop" (CR-013/004), "no_stop_gen", "stop_gen_clears_running"
                     \* (CR-023), "closing_asserts_finished" (CR-005)

CM == "cm"                              \* the 5c marker gang (eco-cmark)
TN == "tn"                              \* the 7c tenure collector (eco-tenure)
AllGangs  == {CM, TN}
LiveGangs == IF TwoGangs THEN {CM, TN} ELSE {CM}
\* bgRegistry() in construction order: the tenure collector is built at the
\* first region minor, the 5c gang at the first concurrent t0.
R1 == IF TwoGangs THEN TN ELSE CM
R2 == CM
ForkerId == IF Forker = "mut" THEN "mut" ELSE "host"
BgIds  == IF B = 1 THEN {"bg1"} ELSE {"bg1", "bg2"}       \* 5c members (parent)
CBgIds == IF B = 1 THEN {"cbg1"} ELSE {"cbg1", "cbg2"}    \* ... restarted by a mutator's child
TnIds  == IF TwoGangs THEN {"tb1"} ELSE {}                \* 7c collector member (parent)
CTnIds == IF TwoGangs THEN {"ctb1"} ELSE {}
Members(g)  == IF g = CM THEN BgIds ELSE TnIds
CMembers(g) == IF g = CM THEN CBgIds ELSE CTnIds
NM(g) == Cardinality(Members(g))
GangOf(p) == IF p \in TnIds \cup CTnIds THEN TN ELSE CM
ParentParts == {"mut", "fg1"} \cup BgIds \cup TnIds       \* ring owners in the parent
ChildParts  == {"mut", "cfg1"} \cup CBgIds \cup CTnIds    \* ... in a mutator's child

(* --algorithm Gangs
variables
    world     = "parent",
    exited    = FALSE,         \* stopAllAtExit returned (the mutator is exiting)
    reg       = "none",        \* bgRegistryMutex()
    runM      = "none",        \* GCMarkGang::run_m_
    bm        = [g \in AllGangs |-> "none"],    \* GCBackgroundGang::m_
    running   = [g \in AllGangs |-> FALSE],     \* running_ (atomic)
    gen       = [g \in AllGangs |-> 0],         \* generation_
    joinedGen = [g \in AllGangs |-> 0],         \* ghost: the generation the last join returned for
    finished  = [g \in AllGangs |-> 0],         \* finished_ (and finished_pub_)
    ctl       = [g \in AllGangs |-> [stop |-> FALSE, done |-> FALSE]],  \* the job's control
    work      = [g \in AllGangs |-> IF g = CM THEN Work0 ELSE 0],     \* entries in the deques
    held      = [p \in ParentParts \cup ChildParts |-> 0],  \* entries in participant p's ring
    bgEp      = "None",        \* OldGenSpace::bg_ep_ (mutator-owned)
    fgGo      = FALSE,         \* the closing run started member 1, which has not finished
    hold      = [g \in AllGangs |-> FALSE],     \* fork_hold_ (CR-013/004: launch refuses)
    refused   = 0,             \* ghost: launches refused by a fork hold
    fstop     = 0;             \* ghost: the 5c generation a pending foreign stop stopped (0: none)

define
    Parts(g) == IF g = CM
                THEN IF world = "parent" THEN {"mut", "fg1"} \cup BgIds ELSE {"mut", "cfg1"} \cup CBgIds
                ELSE IF world = "parent" THEN TnIds ELSE CTnIds
    Alive(p) == \/ world = "parent" /\ p \in ParentParts \cup {"host"}
                \/ world = "child"  /\ (p = ForkerId \/ (Forker = "mut" /\ p \in ChildParts))
    \* Ring entries held by threads that do not exist (in the child).
    DeadHeld == {p \in ParentParts : ~Alive(p) /\ held[p] > 0}
    \* LaunchJoin (parent plan 5.0), the parts SC can check (plan 4.9).
    \* LJ1: running() = FALSE => every live member is parked.
    LJ_JoinExact == \A g \in LiveGangs : ~running[g] =>
                        /\ \A p \in Members(g)  : pc[p] = "B_Wait"  \/ ~Alive(p)
                        /\ \A p \in CMembers(g) : pc[p] = "CB_Wait" \/ ~Alive(p)
    \* LJ2: in the parent, running() is TRUE exactly from a launch to its join.
    LJ_RunningExact == world = "parent" => \A g \in LiveGangs : running[g] <=> joinedGen[g] # gen[g]
    \* LJ1 for GCMarkGang::run: outside a run by the mutator, its member is parked.
    LJ_RunJoined == runM # "mut" => /\ (pc["fg1"] = "FG_Wait" \/ ~Alive("fg1"))
                                    /\ (pc["cfg1"] = "CF_Wait" \/ ~Alive("cfg1"))
    \* A child forked by the MUTATOR continues the heap: no dead thread holds an entry.
    ChildHeapSafe == (world = "child" /\ Forker = "mut") => DeadHeld = {}
    \* The same check for ANY forker: expected to fail for a host fork (the
    \* CR-004 window), which is harmless only because that child has no mutator.
    ChildHeldAny == world = "child" => DeadHeld = {}
    \* closingFinish's assert (CR-005, register-fixes §7.2 step 6): the episode
    \* Finished, or None after a foreign stop (the drain below completes the mark).
    \* Mutant closing_asserts_finished: the pre-fix assert(bg_ep_ == Finished).
    ClosingFinished == pc["mut"] = "U_Assert" =>
                           \/ bgEp = "Finished"
                           \/ MUTANT # "closing_asserts_finished" /\ bgEp = "None"
    \* The handoff: no entry held in any ring (IM15) and none left in the deques
    \* (closingFinish's assert(markStackEmpty())).
    HandoffClean == pc["mut"] = "U_Handoff" => (work[CM] = 0 /\ \A p \in Parts(CM) : held[p] = 0)
    \* After stopAllAtExit no background member is inside a job.
    ExitSafe == exited => \A p \in BgIds \cup TnIds : pc[p] = "B_Wait"
    \* CR-013's window at the gang level: in a child, no dead tenure-collector
    \* member holds an item (fails for a host fork, as ChildHeldAny does).
    ChildHeldTenure == world = "child" => \A p \in TnIds : held[p] = 0
end define;

\* The marker loop (or the tenure job) reduced to M2's Drain contract: take
\* entries into the ring and scan them; a stop scans the ring and leaves
\* without done; done iff no work anywhere.
procedure Mark(mg)
begin
  K_Step:
    await Alive(self);
    if ctl[mg].stop then
        held[self] := 0;               \* ring scanned, private work published
        return;
    elsif held[self] > 0 then
        held[self] := held[self] - 1;  \* scan one entry
    elsif work[mg] > 0 then
        work[mg] := work[mg] - 1;      \* take one entry into the ring
        held[self] := 1;
    elsif ~ctl[mg].done /\ \A p \in Parts(mg) : held[p] = 0 then
        ctl[mg].done := TRUE;          \* termination (M2: done iff no work anywhere)
        return;
    elsif ctl[mg].done then
        return;
    end if;
  K_Again:
    goto K_Step;
end procedure;

\* GCBackgroundGang::launch: under m_, set fn / ctx / stop, finished_ = 0,
\* ++generation_, running_ = true (inside the lock, before notify_all).
\* For the 5c gang the mutator-owned writes of launchBackground (a fresh
\* SliceControl, bg_ep_ = Running) come first; for the 7c collector the new
\* job's items.
procedure Launch(lg)
begin
  L_Lock:
    await Alive(self) /\ bm[lg] = "none";
    if hold[lg] then                   \* CR-013/004: a fork's prepare holds the gang: refuse
        refused := refused + 1;        \* (stats_.fork_refusals); the caller's job is built
        ctl[lg] := [stop |-> FALSE, done |-> FALSE];
        if lg = TN then work[TN] := 1; end if;   \* the job stays; tenureJoin's orphan path runs it
        if lg = CM then bgEp := "None"; end if;  \* launchBackground: a stopped episode
        return;
    else
        gen[lg] := gen[lg] + 1;
        finished[lg] := 0;
        ctl[lg] := [stop |-> FALSE, done |-> FALSE];
        if lg = TN then work[TN] := 1; end if;
        if lg = CM then bgEp := "Running"; end if;
        if MUTANT # "running_after_notify" then
            running[lg] := TRUE;
            return;
        end if;
    end if;
  L_Late:                              \* mutant: running_ stored after unlock / notify_all
    await Alive(self);
    running[lg] := TRUE;
    return;
end procedure;

\* GCBackgroundGang::join: under m_, return if !running_; else joinLocked.
procedure Join(jg)
begin
  J_Lock:
    await Alive(self) /\ bm[jg] = "none";
    if ~running[jg] then
        return;
    elsif MUTANT = "join_no_wait" then  \* mutant: joinLocked does not wait
        running[jg] := FALSE;
        joinedGen[jg] := gen[jg];
        return;
    end if;
  J_Wait:                              \* cv_done_.wait(finished_ >= members) releases m_
    await Alive(self) /\ bm[jg] = "none" /\ finished[jg] >= NM(jg);
    running[jg] := FALSE;
    joinedGen[jg] := gen[jg];
    return;
end procedure;

\* GCBackgroundGang::stopAndJoin: under m_, return if !running_; store the
\* stop, then joinLocked. From stopAllForFork, stopAllAtExit and tenureJoin.
procedure StopAndJoin(sg)
variables sgen = 0;                    \* my_gen: the generation this stop was for (CR-023)
begin
  SJ_Lock:
    await Alive(self) /\ bm[sg] = "none";
    if ~running[sg] then
        return;
    else
        ctl[sg].stop := TRUE;          \* stop_->store(true, release)
        sgen := gen[sg];
        if self = "host" /\ sg = CM then fstop := gen[sg]; end if;
    end if;
  SJ_Wait:                             \* cv_done_.wait(gen != my_gen || finished >= members)
    if MUTANT = "join_no_wait" then
        await Alive(self) /\ bm[sg] = "none";
        running[sg] := FALSE;
        joinedGen[sg] := gen[sg];
    elsif MUTANT = "no_stop_gen" then  \* pre-fix: joinLocked, generation-blind
        await Alive(self) /\ bm[sg] = "none" /\ finished[sg] >= NM(sg);
        running[sg] := FALSE;
        joinedGen[sg] := gen[sg];
    else
        await Alive(self) /\ bm[sg] = "none" /\ (finished[sg] >= NM(sg) \/ gen[sg] # sgen);
        if gen[sg] = sgen then         \* we join our own episode
            running[sg] := FALSE;
            joinedGen[sg] := gen[sg];
        elsif MUTANT = "stop_gen_clears_running" then
            running[sg] := FALSE;      \* mutant: clears the NEW episode's running_
        end if;                        \* else the owner joined my_gen and relaunched
    end if;
    if self = "host" then fstop := 0; end if;
    return;
end procedure;

\* reapBackground(wait): the hint, join (exact publication), then Finished / None.
procedure Reap(wait)
begin
  RP_Check:
    await Alive(self);
    if bgEp # "Running" then return; end if;
  RP_Hint:                             \* !wait && running() && !finishedApprox(): return
    await Alive(self);                 \* two acquire loads, merged (plan 4.3)
    if ~wait /\ running[CM] /\ finished[CM] < NM(CM) then return; end if;
  RP_Join:
    call Join(CM);
  RP_Set:
    await Alive(self);
    bgEp := IF ctl[CM].done THEN "Finished" ELSE "None";
    return;
end procedure;

\* The prepare handlers in reverse registration order (PrepareOrder; the
\* pool's runs last and is M6a), fork, then the parent or the child branch.
procedure ForkGangs()
begin
  G_Mark1:                             \* GCMarkGang::atforkPrepare first (mark_first)
    await Alive(self);
    if PrepareOrder = "mark_first" then
        await runM = "none";
        runM := self;
    end if;
  G_Reg:                               \* bg atforkPrepare: bgRegistryMutex().lock()
    await Alive(self) /\ reg = "none";
    reg := self;
  G_Hold:                              \* each g->m_: fork_hold_ = true, BEFORE the stops
    await Alive(self);
    if MUTANT \notin {"no_fork_hold", "hold_after_stop"} then
        await \A g \in LiveGangs : bm[g] = "none";
        hold := [g \in AllGangs |-> g \in LiveGangs];
    end if;
  G_Stop1:                             \* stopAllForFork: if (g->running()) g->stopAndJoin()
    await Alive(self);
    if running[R1] /\ MUTANT # "no_stop_in_prepare" then call StopAndJoin(R1); end if;
  G_Stop2:
    await Alive(self);
    if TwoGangs /\ running[R2] /\ MUTANT # "no_stop_in_prepare" then call StopAndJoin(R2); end if;
  G_Hold2:                             \* mutant hold_after_stop: the hold set after the stops
    await Alive(self);
    if MUTANT = "hold_after_stop" then
        await \A g \in LiveGangs : bm[g] = "none";
        hold := [g \in AllGangs |-> g \in LiveGangs];
    end if;
  G_Lock1:                             \* then lock every g->m_ (CR-004 window before this)
    await Alive(self) /\ bm[R1] = "none";
    bm[R1] := self;
  G_Lock2:
    await Alive(self);
    if TwoGangs then
        await bm[R2] = "none";
        bm[R2] := self;
    end if;
  G_RunM:                              \* GCMarkGang::atforkPrepare last (bg_first)
    await Alive(self);
    if PrepareOrder = "bg_first" then
        await runM = "none";
        runM := self;
    end if;
  G_Fork:
    either                             \* parent: the parent handlers clear the hold, unlock
        hold := [g \in AllGangs |-> FALSE];
        bm := [g \in AllGangs |-> "none"];
        runM := "none";
        reg := "none";
    or                                 \* child: atforkChild re-creates both gangs' state
        world := "child";
        hold := [g \in AllGangs |-> FALSE];
        running := [g \in AllGangs |-> FALSE];
        finished := [g \in AllGangs |-> 0];
        fgGo := FALSE;
        if MUTANT # "child_no_unlock" then
            bm := [g \in AllGangs |-> "none"];
            runM := "none";
            reg := "none";
        end if;
    end either;
  G_Ret:
    return;
end procedure;

\* stopAllAtExit, run by exit() on the calling thread (the mutator).
procedure ExitGangs()
begin
  X_Reg:
    await Alive(self) /\ reg = "none";
    reg := self;
  X_Stop1:
    call StopAndJoin(R1);
  X_Stop2:
    await Alive(self);
    if TwoGangs then call StopAndJoin(R2); end if;
  X_Done:
    await Alive(self);
    reg := "none";
    exited := TRUE;
    return;
end procedure;

\* The heap's mutator: the t0 launch, Steps ordinary minor ends, then the
\* closing step (its own reap / relaunch, then closingFinish), then the
\* handoff. Each minor end: tenureJoin (7c), runCycleStepConcurrent's reap
\* and relaunch (5c), tenureLaunch (7c). Between pauses it may fork
\* (Forker = "mut") or call exit(), which does not return.
fair process Mutator = "mut"
variables k = 0, forked = FALSE;
begin
  U_Launch:                            \* t0 pause: afterSnapshot -> launchBackground
    call Launch(CM);
  U_Launch2:                           \* ... and at the pause's end, tenureLaunch
    await Alive("mut");
    if TwoGangs then call Launch(TN); end if;
  U_MaybeFork:                         \* between pauses: fork, exit, or neither
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
  U_Tenure:                            \* minor start: tenureJoin (tenure_help = 1)
    await Alive("mut");
    if exited then goto U_Exit;        \* exit() never returns to the program
    elsif ~TwoGangs then goto U_Reap;
    elsif ~running[TN] then goto U_TFinish;   \* orphan: a fork hook stopped it (trap 25)
    elsif finished[TN] >= NM(TN) then call Join(TN);
    else call StopAndJoin(TN);         \* late: the mutator's own stop
    end if;
  U_TFinish:                           \* finish the job here if it is not done, then merge
    await Alive("mut");
    if ~ctl[TN].done then work[TN] := 0; end if;
  U_Reap:                              \* minor end: runCycleStepConcurrent's reapBackground(false)
    call Reap(FALSE);
  U_Relaunch:                          \* stopped -> relaunch; the work is already in the deques
    await Alive("mut");
    if (bgEp = "None" \/ (MUTANT = "relaunch_unreaped" /\ ~ctl[CM].done)) /\ work[CM] > 0 then
        call Launch(CM);
    elsif bgEp = "None" then
        bgEp := "Finished";
    end if;
  U_Next:                              \* the closing step, or tenureLaunch and the next minor
    await Alive("mut");
    if k = Steps then
        goto U_Close;
    elsif TwoGangs then
        k := k + 1;
        call Launch(TN);
        goto U_MaybeFork;
    else
        k := k + 1;
        goto U_MaybeFork;
    end if;
  U_Close:                             \* closingFinish: reapBackground(false)
    call Reap(FALSE);
  U_CloseRun:
    await Alive("mut");
    if bgEp = "Running" then
      U_RunLock:                       \* GCMarkGang::run(n = 2): run_m_, start member 1
        await Alive("mut");
        if MarkThreads = 2 then        \* run(n = 1): fn(ctx, 0) inline, no run_m_ (:408-411)
            await runM = "none";
            runM := "mut";
            fgGo := TRUE;
        end if;
      U_Mark:                          \* member 0 on the caller (closingEntry)
        call Mark(CM);
      U_FgWait:                        \* cv_done_.wait(finished_ == n - 1), then release run_m_
        await Alive("mut") /\ (~fgGo \/ MUTANT = "run_no_wait");
        if MarkThreads = 2 /\ MUTANT # "join_in_run" then runM := "none"; end if;
      U_Reap2:                         \* reapBackground(true)
        call Reap(TRUE);
      U_Assert:                        \* assert(bg_ep_ == Finished): invariant ClosingFinished
        await Alive("mut");
        if MarkThreads = 2 /\ MUTANT = "join_in_run" then runM := "none"; end if;
    end if;
  U_Drain:                             \* a stopped episode left work: runMarkers drains it
    await Alive("mut");
    if work[CM] > 0 then work[CM] := 0; end if;
  U_Handoff:                           \* invariant HandoffClean is evaluated here
    await Alive("mut");
    skip;
  U_Exit:
    await Alive("mut");
    skip;
end process;

\* Background members (GCBackgroundGang::memberLoop) of either gang, parent only.
fair process BgMember \in BgIds \cup TnIds
variables seen = 0;
begin
  B_Wait:                              \* cv_start_.wait(stopping_ || generation_ != seen)
    await Alive(self) /\ bm[GangOf(self)] = "none" /\ gen[GangOf(self)] # seen;
    seen := gen[GangOf(self)];
  B_Run:                               \* fn(ctx, i): bgEntry (runMarkerLoop) or tenureEntry
    call Mark(GangOf(self));
  B_Fin:                               \* under m_: ++finished_, finished_pub_, notify_all
    await Alive(self) /\ bm[GangOf(self)] = "none";
    \* RelaunchWaitsStopper: a relaunched 5c episode ends only after the pending foreign stop returned.
    await ~(RelaunchWaitsStopper /\ GangOf(self) = CM /\ fstop # 0 /\ gen[CM] # fstop);
    finished[GangOf(self)] := finished[GangOf(self)] + 1;
    goto B_Wait;
end process;

\* The mark gang's member 1 (GCMarkGang::memberLoop) during the closing run.
fair process FgMember = "fg1"
begin
  FG_Wait:
    await Alive("fg1") /\ fgGo;
  FG_Run:
    call Mark(CM);
  FG_Fin:                              \* ++finished_ == n - 1: notify the caller
    await Alive("fg1");
    fgGo := FALSE;
    goto FG_Wait;
end process;

\* Members a mutator's child restarts lazily (startThreadsLocked) when it
\* relaunches: they exist only from the child's first launch on.
fair process CBgMember \in CBgIds \cup CTnIds
variables cseen = 0;
begin
  CB_Wait:
    await Alive(self) /\ bm[GangOf(self)] = "none" /\ running[GangOf(self)]
          /\ gen[GangOf(self)] # cseen;
    cseen := gen[GangOf(self)];
  CB_Run:
    call Mark(GangOf(self));
  CB_Fin:
    await Alive(self) /\ bm[GangOf(self)] = "none";
    finished[GangOf(self)] := finished[GangOf(self)] + 1;
    goto CB_Wait;
end process;

fair process CFgMember = "cfg1"
begin
  CF_Wait:
    await Alive("cfg1") /\ fgGo;
  CF_Run:
    call Mark(CM);
  CF_Fin:
    await Alive("cfg1");
    fgGo := FALSE;
    goto CF_Wait;
end process;

\* Another thread (an embedding host, or a second heap's mutator) that may fork,
\* or (ForeignStop) stop the 5c episode without a fork (no hold protects it).
fair process Host = "host"
begin
  H_Act:
    await Alive("host");
    either
        await Forker = "host" /\ ForkAllowed;
        call ForkGangs();
    or
        await ForeignStop /\ running[CM];
        call StopAndJoin(CM);
    or
        skip;
    end either;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
CONSTANT defaultInitValue
VARIABLES pc, world, exited, reg, runM, bm, running, gen, joinedGen, finished, 
          ctl, work, held, bgEp, fgGo, hold, refused, fstop, stack

(* define statement *)
Parts(g) == IF g = CM
            THEN IF world = "parent" THEN {"mut", "fg1"} \cup BgIds ELSE {"mut", "cfg1"} \cup CBgIds
            ELSE IF world = "parent" THEN TnIds ELSE CTnIds
Alive(p) == \/ world = "parent" /\ p \in ParentParts \cup {"host"}
            \/ world = "child"  /\ (p = ForkerId \/ (Forker = "mut" /\ p \in ChildParts))

DeadHeld == {p \in ParentParts : ~Alive(p) /\ held[p] > 0}


LJ_JoinExact == \A g \in LiveGangs : ~running[g] =>
                    /\ \A p \in Members(g)  : pc[p] = "B_Wait"  \/ ~Alive(p)
                    /\ \A p \in CMembers(g) : pc[p] = "CB_Wait" \/ ~Alive(p)

LJ_RunningExact == world = "parent" => \A g \in LiveGangs : running[g] <=> joinedGen[g] # gen[g]

LJ_RunJoined == runM # "mut" => /\ (pc["fg1"] = "FG_Wait" \/ ~Alive("fg1"))
                                /\ (pc["cfg1"] = "CF_Wait" \/ ~Alive("cfg1"))

ChildHeapSafe == (world = "child" /\ Forker = "mut") => DeadHeld = {}


ChildHeldAny == world = "child" => DeadHeld = {}



ClosingFinished == pc["mut"] = "U_Assert" =>
                       \/ bgEp = "Finished"
                       \/ MUTANT # "closing_asserts_finished" /\ bgEp = "None"


HandoffClean == pc["mut"] = "U_Handoff" => (work[CM] = 0 /\ \A p \in Parts(CM) : held[p] = 0)

ExitSafe == exited => \A p \in BgIds \cup TnIds : pc[p] = "B_Wait"


ChildHeldTenure == world = "child" => \A p \in TnIds : held[p] = 0

VARIABLES mg, lg, jg, sg, sgen, wait, k, forked, seen, cseen

vars == << pc, world, exited, reg, runM, bm, running, gen, joinedGen, 
           finished, ctl, work, held, bgEp, fgGo, hold, refused, fstop, stack, 
           mg, lg, jg, sg, sgen, wait, k, forked, seen, cseen >>

ProcSet == {"mut"} \cup (BgIds \cup TnIds) \cup {"fg1"} \cup (CBgIds \cup CTnIds) \cup {"cfg1"} \cup {"host"}

Init == (* Global variables *)
        /\ world = "parent"
        /\ exited = FALSE
        /\ reg = "none"
        /\ runM = "none"
        /\ bm = [g \in AllGangs |-> "none"]
        /\ running = [g \in AllGangs |-> FALSE]
        /\ gen = [g \in AllGangs |-> 0]
        /\ joinedGen = [g \in AllGangs |-> 0]
        /\ finished = [g \in AllGangs |-> 0]
        /\ ctl = [g \in AllGangs |-> [stop |-> FALSE, done |-> FALSE]]
        /\ work = [g \in AllGangs |-> IF g = CM THEN Work0 ELSE 0]
        /\ held = [p \in ParentParts \cup ChildParts |-> 0]
        /\ bgEp = "None"
        /\ fgGo = FALSE
        /\ hold = [g \in AllGangs |-> FALSE]
        /\ refused = 0
        /\ fstop = 0
        (* Procedure Mark *)
        /\ mg = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure Launch *)
        /\ lg = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure Join *)
        /\ jg = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure StopAndJoin *)
        /\ sg = [ self \in ProcSet |-> defaultInitValue]
        /\ sgen = [ self \in ProcSet |-> 0]
        (* Procedure Reap *)
        /\ wait = [ self \in ProcSet |-> defaultInitValue]
        (* Process Mutator *)
        /\ k = 0
        /\ forked = FALSE
        (* Process BgMember *)
        /\ seen = [self \in BgIds \cup TnIds |-> 0]
        (* Process CBgMember *)
        /\ cseen = [self \in CBgIds \cup CTnIds |-> 0]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self = "mut" -> "U_Launch"
                                        [] self \in BgIds \cup TnIds -> "B_Wait"
                                        [] self = "fg1" -> "FG_Wait"
                                        [] self \in CBgIds \cup CTnIds -> "CB_Wait"
                                        [] self = "cfg1" -> "CF_Wait"
                                        [] self = "host" -> "H_Act"]

K_Step(self) == /\ pc[self] = "K_Step"
                /\ Alive(self)
                /\ IF ctl[mg[self]].stop
                      THEN /\ held' = [held EXCEPT ![self] = 0]
                           /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                           /\ mg' = [mg EXCEPT ![self] = Head(stack[self]).mg]
                           /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                           /\ UNCHANGED << ctl, work >>
                      ELSE /\ IF held[self] > 0
                                 THEN /\ held' = [held EXCEPT ![self] = held[self] - 1]
                                      /\ pc' = [pc EXCEPT ![self] = "K_Again"]
                                      /\ UNCHANGED << ctl, work, stack, mg >>
                                 ELSE /\ IF work[mg[self]] > 0
                                            THEN /\ work' = [work EXCEPT ![mg[self]] = work[mg[self]] - 1]
                                                 /\ held' = [held EXCEPT ![self] = 1]
                                                 /\ pc' = [pc EXCEPT ![self] = "K_Again"]
                                                 /\ UNCHANGED << ctl, stack, 
                                                                 mg >>
                                            ELSE /\ IF ~ctl[mg[self]].done /\ \A p \in Parts(mg[self]) : held[p] = 0
                                                       THEN /\ ctl' = [ctl EXCEPT ![mg[self]].done = TRUE]
                                                            /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                                            /\ mg' = [mg EXCEPT ![self] = Head(stack[self]).mg]
                                                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                                       ELSE /\ IF ctl[mg[self]].done
                                                                  THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                                                       /\ mg' = [mg EXCEPT ![self] = Head(stack[self]).mg]
                                                                       /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "K_Again"]
                                                                       /\ UNCHANGED << stack, 
                                                                                       mg >>
                                                            /\ ctl' = ctl
                                                 /\ UNCHANGED << work, held >>
                /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                joinedGen, finished, bgEp, fgGo, hold, refused, 
                                fstop, lg, jg, sg, sgen, wait, k, forked, seen, 
                                cseen >>

K_Again(self) == /\ pc[self] = "K_Again"
                 /\ pc' = [pc EXCEPT ![self] = "K_Step"]
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                 sg, sgen, wait, k, forked, seen, cseen >>

Mark(self) == K_Step(self) \/ K_Again(self)

L_Lock(self) == /\ pc[self] = "L_Lock"
                /\ Alive(self) /\ bm[lg[self]] = "none"
                /\ IF hold[lg[self]]
                      THEN /\ refused' = refused + 1
                           /\ ctl' = [ctl EXCEPT ![lg[self]] = [stop |-> FALSE, done |-> FALSE]]
                           /\ IF lg[self] = TN
                                 THEN /\ work' = [work EXCEPT ![TN] = 1]
                                 ELSE /\ TRUE
                                      /\ work' = work
                           /\ IF lg[self] = CM
                                 THEN /\ bgEp' = "None"
                                 ELSE /\ TRUE
                                      /\ bgEp' = bgEp
                           /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                           /\ lg' = [lg EXCEPT ![self] = Head(stack[self]).lg]
                           /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                           /\ UNCHANGED << running, gen, finished >>
                      ELSE /\ gen' = [gen EXCEPT ![lg[self]] = gen[lg[self]] + 1]
                           /\ finished' = [finished EXCEPT ![lg[self]] = 0]
                           /\ ctl' = [ctl EXCEPT ![lg[self]] = [stop |-> FALSE, done |-> FALSE]]
                           /\ IF lg[self] = TN
                                 THEN /\ work' = [work EXCEPT ![TN] = 1]
                                 ELSE /\ TRUE
                                      /\ work' = work
                           /\ IF lg[self] = CM
                                 THEN /\ bgEp' = "Running"
                                 ELSE /\ TRUE
                                      /\ bgEp' = bgEp
                           /\ IF MUTANT # "running_after_notify"
                                 THEN /\ running' = [running EXCEPT ![lg[self]] = TRUE]
                                      /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ lg' = [lg EXCEPT ![self] = Head(stack[self]).lg]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "L_Late"]
                                      /\ UNCHANGED << running, stack, lg >>
                           /\ UNCHANGED refused
                /\ UNCHANGED << world, exited, reg, runM, bm, joinedGen, held, 
                                fgGo, hold, fstop, mg, jg, sg, sgen, wait, k, 
                                forked, seen, cseen >>

L_Late(self) == /\ pc[self] = "L_Late"
                /\ Alive(self)
                /\ running' = [running EXCEPT ![lg[self]] = TRUE]
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ lg' = [lg EXCEPT ![self] = Head(stack[self]).lg]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << world, exited, reg, runM, bm, gen, joinedGen, 
                                finished, ctl, work, held, bgEp, fgGo, hold, 
                                refused, fstop, mg, jg, sg, sgen, wait, k, 
                                forked, seen, cseen >>

Launch(self) == L_Lock(self) \/ L_Late(self)

J_Lock(self) == /\ pc[self] = "J_Lock"
                /\ Alive(self) /\ bm[jg[self]] = "none"
                /\ IF ~running[jg[self]]
                      THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                           /\ jg' = [jg EXCEPT ![self] = Head(stack[self]).jg]
                           /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                           /\ UNCHANGED << running, joinedGen >>
                      ELSE /\ IF MUTANT = "join_no_wait"
                                 THEN /\ running' = [running EXCEPT ![jg[self]] = FALSE]
                                      /\ joinedGen' = [joinedGen EXCEPT ![jg[self]] = gen[jg[self]]]
                                      /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ jg' = [jg EXCEPT ![self] = Head(stack[self]).jg]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "J_Wait"]
                                      /\ UNCHANGED << running, joinedGen, 
                                                      stack, jg >>
                /\ UNCHANGED << world, exited, reg, runM, bm, gen, finished, 
                                ctl, work, held, bgEp, fgGo, hold, refused, 
                                fstop, mg, lg, sg, sgen, wait, k, forked, seen, 
                                cseen >>

J_Wait(self) == /\ pc[self] = "J_Wait"
                /\ Alive(self) /\ bm[jg[self]] = "none" /\ finished[jg[self]] >= NM(jg[self])
                /\ running' = [running EXCEPT ![jg[self]] = FALSE]
                /\ joinedGen' = [joinedGen EXCEPT ![jg[self]] = gen[jg[self]]]
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ jg' = [jg EXCEPT ![self] = Head(stack[self]).jg]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << world, exited, reg, runM, bm, gen, finished, 
                                ctl, work, held, bgEp, fgGo, hold, refused, 
                                fstop, mg, lg, sg, sgen, wait, k, forked, seen, 
                                cseen >>

Join(self) == J_Lock(self) \/ J_Wait(self)

SJ_Lock(self) == /\ pc[self] = "SJ_Lock"
                 /\ Alive(self) /\ bm[sg[self]] = "none"
                 /\ IF ~running[sg[self]]
                       THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                            /\ sgen' = [sgen EXCEPT ![self] = Head(stack[self]).sgen]
                            /\ sg' = [sg EXCEPT ![self] = Head(stack[self]).sg]
                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                            /\ UNCHANGED << ctl, fstop >>
                       ELSE /\ ctl' = [ctl EXCEPT ![sg[self]].stop = TRUE]
                            /\ sgen' = [sgen EXCEPT ![self] = gen[sg[self]]]
                            /\ IF self = "host" /\ sg[self] = CM
                                  THEN /\ fstop' = gen[sg[self]]
                                  ELSE /\ TRUE
                                       /\ fstop' = fstop
                            /\ pc' = [pc EXCEPT ![self] = "SJ_Wait"]
                            /\ UNCHANGED << stack, sg >>
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, work, held, bgEp, fgGo, 
                                 hold, refused, mg, lg, jg, wait, k, forked, 
                                 seen, cseen >>

SJ_Wait(self) == /\ pc[self] = "SJ_Wait"
                 /\ IF MUTANT = "join_no_wait"
                       THEN /\ Alive(self) /\ bm[sg[self]] = "none"
                            /\ running' = [running EXCEPT ![sg[self]] = FALSE]
                            /\ joinedGen' = [joinedGen EXCEPT ![sg[self]] = gen[sg[self]]]
                       ELSE /\ IF MUTANT = "no_stop_gen"
                                  THEN /\ Alive(self) /\ bm[sg[self]] = "none" /\ finished[sg[self]] >= NM(sg[self])
                                       /\ running' = [running EXCEPT ![sg[self]] = FALSE]
                                       /\ joinedGen' = [joinedGen EXCEPT ![sg[self]] = gen[sg[self]]]
                                  ELSE /\ Alive(self) /\ bm[sg[self]] = "none" /\ (finished[sg[self]] >= NM(sg[self]) \/ gen[sg[self]] # sgen[self])
                                       /\ IF gen[sg[self]] = sgen[self]
                                             THEN /\ running' = [running EXCEPT ![sg[self]] = FALSE]
                                                  /\ joinedGen' = [joinedGen EXCEPT ![sg[self]] = gen[sg[self]]]
                                             ELSE /\ IF MUTANT = "stop_gen_clears_running"
                                                        THEN /\ running' = [running EXCEPT ![sg[self]] = FALSE]
                                                        ELSE /\ TRUE
                                                             /\ UNCHANGED running
                                                  /\ UNCHANGED joinedGen
                 /\ IF self = "host"
                       THEN /\ fstop' = 0
                       ELSE /\ TRUE
                            /\ fstop' = fstop
                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                 /\ sgen' = [sgen EXCEPT ![self] = Head(stack[self]).sgen]
                 /\ sg' = [sg EXCEPT ![self] = Head(stack[self]).sg]
                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                 /\ UNCHANGED << world, exited, reg, runM, bm, gen, finished, 
                                 ctl, work, held, bgEp, fgGo, hold, refused, 
                                 mg, lg, jg, wait, k, forked, seen, cseen >>

StopAndJoin(self) == SJ_Lock(self) \/ SJ_Wait(self)

RP_Check(self) == /\ pc[self] = "RP_Check"
                  /\ Alive(self)
                  /\ IF bgEp # "Running"
                        THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                             /\ wait' = [wait EXCEPT ![self] = Head(stack[self]).wait]
                             /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                        ELSE /\ pc' = [pc EXCEPT ![self] = "RP_Hint"]
                             /\ UNCHANGED << stack, wait >>
                  /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                  joinedGen, finished, ctl, work, held, bgEp, 
                                  fgGo, hold, refused, fstop, mg, lg, jg, sg, 
                                  sgen, k, forked, seen, cseen >>

RP_Hint(self) == /\ pc[self] = "RP_Hint"
                 /\ Alive(self)
                 /\ IF ~wait[self] /\ running[CM] /\ finished[CM] < NM(CM)
                       THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                            /\ wait' = [wait EXCEPT ![self] = Head(stack[self]).wait]
                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "RP_Join"]
                            /\ UNCHANGED << stack, wait >>
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, mg, lg, jg, sg, 
                                 sgen, k, forked, seen, cseen >>

RP_Join(self) == /\ pc[self] = "RP_Join"
                 /\ /\ jg' = [jg EXCEPT ![self] = CM]
                    /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Join",
                                                             pc        |->  "RP_Set",
                                                             jg        |->  jg[self] ] >>
                                                         \o stack[self]]
                 /\ pc' = [pc EXCEPT ![self] = "J_Lock"]
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, mg, lg, sg, sgen, 
                                 wait, k, forked, seen, cseen >>

RP_Set(self) == /\ pc[self] = "RP_Set"
                /\ Alive(self)
                /\ bgEp' = IF ctl[CM].done THEN "Finished" ELSE "None"
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ wait' = [wait EXCEPT ![self] = Head(stack[self]).wait]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                joinedGen, finished, ctl, work, held, fgGo, 
                                hold, refused, fstop, mg, lg, jg, sg, sgen, k, 
                                forked, seen, cseen >>

Reap(self) == RP_Check(self) \/ RP_Hint(self) \/ RP_Join(self)
                 \/ RP_Set(self)

G_Mark1(self) == /\ pc[self] = "G_Mark1"
                 /\ Alive(self)
                 /\ IF PrepareOrder = "mark_first"
                       THEN /\ runM = "none"
                            /\ runM' = self
                       ELSE /\ TRUE
                            /\ runM' = runM
                 /\ pc' = [pc EXCEPT ![self] = "G_Reg"]
                 /\ UNCHANGED << world, exited, reg, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                 sg, sgen, wait, k, forked, seen, cseen >>

G_Reg(self) == /\ pc[self] = "G_Reg"
               /\ Alive(self) /\ reg = "none"
               /\ reg' = self
               /\ pc' = [pc EXCEPT ![self] = "G_Hold"]
               /\ UNCHANGED << world, exited, runM, bm, running, gen, 
                               joinedGen, finished, ctl, work, held, bgEp, 
                               fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                               sg, sgen, wait, k, forked, seen, cseen >>

G_Hold(self) == /\ pc[self] = "G_Hold"
                /\ Alive(self)
                /\ IF MUTANT \notin {"no_fork_hold", "hold_after_stop"}
                      THEN /\ \A g \in LiveGangs : bm[g] = "none"
                           /\ hold' = [g \in AllGangs |-> g \in LiveGangs]
                      ELSE /\ TRUE
                           /\ hold' = hold
                /\ pc' = [pc EXCEPT ![self] = "G_Stop1"]
                /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                joinedGen, finished, ctl, work, held, bgEp, 
                                fgGo, refused, fstop, stack, mg, lg, jg, sg, 
                                sgen, wait, k, forked, seen, cseen >>

G_Stop1(self) == /\ pc[self] = "G_Stop1"
                 /\ Alive(self)
                 /\ IF running[R1] /\ MUTANT # "no_stop_in_prepare"
                       THEN /\ /\ sg' = [sg EXCEPT ![self] = R1]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "StopAndJoin",
                                                                        pc        |->  "G_Stop2",
                                                                        sgen      |->  sgen[self],
                                                                        sg        |->  sg[self] ] >>
                                                                    \o stack[self]]
                            /\ sgen' = [sgen EXCEPT ![self] = 0]
                            /\ pc' = [pc EXCEPT ![self] = "SJ_Lock"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "G_Stop2"]
                            /\ UNCHANGED << stack, sg, sgen >>
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, mg, lg, jg, wait, 
                                 k, forked, seen, cseen >>

G_Stop2(self) == /\ pc[self] = "G_Stop2"
                 /\ Alive(self)
                 /\ IF TwoGangs /\ running[R2] /\ MUTANT # "no_stop_in_prepare"
                       THEN /\ /\ sg' = [sg EXCEPT ![self] = R2]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "StopAndJoin",
                                                                        pc        |->  "G_Hold2",
                                                                        sgen      |->  sgen[self],
                                                                        sg        |->  sg[self] ] >>
                                                                    \o stack[self]]
                            /\ sgen' = [sgen EXCEPT ![self] = 0]
                            /\ pc' = [pc EXCEPT ![self] = "SJ_Lock"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "G_Hold2"]
                            /\ UNCHANGED << stack, sg, sgen >>
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, mg, lg, jg, wait, 
                                 k, forked, seen, cseen >>

G_Hold2(self) == /\ pc[self] = "G_Hold2"
                 /\ Alive(self)
                 /\ IF MUTANT = "hold_after_stop"
                       THEN /\ \A g \in LiveGangs : bm[g] = "none"
                            /\ hold' = [g \in AllGangs |-> g \in LiveGangs]
                       ELSE /\ TRUE
                            /\ hold' = hold
                 /\ pc' = [pc EXCEPT ![self] = "G_Lock1"]
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, refused, fstop, stack, mg, lg, jg, sg, 
                                 sgen, wait, k, forked, seen, cseen >>

G_Lock1(self) == /\ pc[self] = "G_Lock1"
                 /\ Alive(self) /\ bm[R1] = "none"
                 /\ bm' = [bm EXCEPT ![R1] = self]
                 /\ pc' = [pc EXCEPT ![self] = "G_Lock2"]
                 /\ UNCHANGED << world, exited, reg, runM, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                 sg, sgen, wait, k, forked, seen, cseen >>

G_Lock2(self) == /\ pc[self] = "G_Lock2"
                 /\ Alive(self)
                 /\ IF TwoGangs
                       THEN /\ bm[R2] = "none"
                            /\ bm' = [bm EXCEPT ![R2] = self]
                       ELSE /\ TRUE
                            /\ bm' = bm
                 /\ pc' = [pc EXCEPT ![self] = "G_RunM"]
                 /\ UNCHANGED << world, exited, reg, runM, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                 sg, sgen, wait, k, forked, seen, cseen >>

G_RunM(self) == /\ pc[self] = "G_RunM"
                /\ Alive(self)
                /\ IF PrepareOrder = "bg_first"
                      THEN /\ runM = "none"
                           /\ runM' = self
                      ELSE /\ TRUE
                           /\ runM' = runM
                /\ pc' = [pc EXCEPT ![self] = "G_Fork"]
                /\ UNCHANGED << world, exited, reg, bm, running, gen, 
                                joinedGen, finished, ctl, work, held, bgEp, 
                                fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                sg, sgen, wait, k, forked, seen, cseen >>

G_Fork(self) == /\ pc[self] = "G_Fork"
                /\ \/ /\ hold' = [g \in AllGangs |-> FALSE]
                      /\ bm' = [g \in AllGangs |-> "none"]
                      /\ runM' = "none"
                      /\ reg' = "none"
                      /\ UNCHANGED <<world, running, finished, fgGo>>
                   \/ /\ world' = "child"
                      /\ hold' = [g \in AllGangs |-> FALSE]
                      /\ running' = [g \in AllGangs |-> FALSE]
                      /\ finished' = [g \in AllGangs |-> 0]
                      /\ fgGo' = FALSE
                      /\ IF MUTANT # "child_no_unlock"
                            THEN /\ bm' = [g \in AllGangs |-> "none"]
                                 /\ runM' = "none"
                                 /\ reg' = "none"
                            ELSE /\ TRUE
                                 /\ UNCHANGED << reg, runM, bm >>
                /\ pc' = [pc EXCEPT ![self] = "G_Ret"]
                /\ UNCHANGED << exited, gen, joinedGen, ctl, work, held, bgEp, 
                                refused, fstop, stack, mg, lg, jg, sg, sgen, 
                                wait, k, forked, seen, cseen >>

G_Ret(self) == /\ pc[self] = "G_Ret"
               /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
               /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
               /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                               joinedGen, finished, ctl, work, held, bgEp, 
                               fgGo, hold, refused, fstop, mg, lg, jg, sg, 
                               sgen, wait, k, forked, seen, cseen >>

ForkGangs(self) == G_Mark1(self) \/ G_Reg(self) \/ G_Hold(self)
                      \/ G_Stop1(self) \/ G_Stop2(self) \/ G_Hold2(self)
                      \/ G_Lock1(self) \/ G_Lock2(self) \/ G_RunM(self)
                      \/ G_Fork(self) \/ G_Ret(self)

X_Reg(self) == /\ pc[self] = "X_Reg"
               /\ Alive(self) /\ reg = "none"
               /\ reg' = self
               /\ pc' = [pc EXCEPT ![self] = "X_Stop1"]
               /\ UNCHANGED << world, exited, runM, bm, running, gen, 
                               joinedGen, finished, ctl, work, held, bgEp, 
                               fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                               sg, sgen, wait, k, forked, seen, cseen >>

X_Stop1(self) == /\ pc[self] = "X_Stop1"
                 /\ /\ sg' = [sg EXCEPT ![self] = R1]
                    /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "StopAndJoin",
                                                             pc        |->  "X_Stop2",
                                                             sgen      |->  sgen[self],
                                                             sg        |->  sg[self] ] >>
                                                         \o stack[self]]
                 /\ sgen' = [sgen EXCEPT ![self] = 0]
                 /\ pc' = [pc EXCEPT ![self] = "SJ_Lock"]
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, mg, lg, jg, wait, 
                                 k, forked, seen, cseen >>

X_Stop2(self) == /\ pc[self] = "X_Stop2"
                 /\ Alive(self)
                 /\ IF TwoGangs
                       THEN /\ /\ sg' = [sg EXCEPT ![self] = R2]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "StopAndJoin",
                                                                        pc        |->  "X_Done",
                                                                        sgen      |->  sgen[self],
                                                                        sg        |->  sg[self] ] >>
                                                                    \o stack[self]]
                            /\ sgen' = [sgen EXCEPT ![self] = 0]
                            /\ pc' = [pc EXCEPT ![self] = "SJ_Lock"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "X_Done"]
                            /\ UNCHANGED << stack, sg, sgen >>
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, mg, lg, jg, wait, 
                                 k, forked, seen, cseen >>

X_Done(self) == /\ pc[self] = "X_Done"
                /\ Alive(self)
                /\ reg' = "none"
                /\ exited' = TRUE
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << world, runM, bm, running, gen, joinedGen, 
                                finished, ctl, work, held, bgEp, fgGo, hold, 
                                refused, fstop, mg, lg, jg, sg, sgen, wait, k, 
                                forked, seen, cseen >>

ExitGangs(self) == X_Reg(self) \/ X_Stop1(self) \/ X_Stop2(self)
                      \/ X_Done(self)

U_Launch == /\ pc["mut"] = "U_Launch"
            /\ /\ lg' = [lg EXCEPT !["mut"] = CM]
               /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Launch",
                                                         pc        |->  "U_Launch2",
                                                         lg        |->  lg["mut"] ] >>
                                                     \o stack["mut"]]
            /\ pc' = [pc EXCEPT !["mut"] = "L_Lock"]
            /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                            joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                            hold, refused, fstop, mg, jg, sg, sgen, wait, k, 
                            forked, seen, cseen >>

U_Launch2 == /\ pc["mut"] = "U_Launch2"
             /\ Alive("mut")
             /\ IF TwoGangs
                   THEN /\ /\ lg' = [lg EXCEPT !["mut"] = TN]
                           /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Launch",
                                                                     pc        |->  "U_MaybeFork",
                                                                     lg        |->  lg["mut"] ] >>
                                                                 \o stack["mut"]]
                        /\ pc' = [pc EXCEPT !["mut"] = "L_Lock"]
                   ELSE /\ pc' = [pc EXCEPT !["mut"] = "U_MaybeFork"]
                        /\ UNCHANGED << stack, lg >>
             /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                             joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                             hold, refused, fstop, mg, jg, sg, sgen, wait, k, 
                             forked, seen, cseen >>

U_MaybeFork == /\ pc["mut"] = "U_MaybeFork"
               /\ Alive("mut")
               /\ \/ /\ Forker = "mut" /\ ForkAllowed /\ ~forked
                     /\ forked' = TRUE
                     /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "ForkGangs",
                                                               pc        |->  "U_Tenure" ] >>
                                                           \o stack["mut"]]
                     /\ pc' = [pc EXCEPT !["mut"] = "G_Mark1"]
                  \/ /\ ExitAllowed
                     /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "ExitGangs",
                                                               pc        |->  "U_Tenure" ] >>
                                                           \o stack["mut"]]
                     /\ pc' = [pc EXCEPT !["mut"] = "X_Reg"]
                     /\ UNCHANGED forked
                  \/ /\ TRUE
                     /\ pc' = [pc EXCEPT !["mut"] = "U_Tenure"]
                     /\ UNCHANGED <<stack, forked>>
               /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                               joinedGen, finished, ctl, work, held, bgEp, 
                               fgGo, hold, refused, fstop, mg, lg, jg, sg, 
                               sgen, wait, k, seen, cseen >>

U_Tenure == /\ pc["mut"] = "U_Tenure"
            /\ Alive("mut")
            /\ IF exited
                  THEN /\ pc' = [pc EXCEPT !["mut"] = "U_Exit"]
                       /\ UNCHANGED << stack, jg, sg, sgen >>
                  ELSE /\ IF ~TwoGangs
                             THEN /\ pc' = [pc EXCEPT !["mut"] = "U_Reap"]
                                  /\ UNCHANGED << stack, jg, sg, sgen >>
                             ELSE /\ IF ~running[TN]
                                        THEN /\ pc' = [pc EXCEPT !["mut"] = "U_TFinish"]
                                             /\ UNCHANGED << stack, jg, sg, 
                                                             sgen >>
                                        ELSE /\ IF finished[TN] >= NM(TN)
                                                   THEN /\ /\ jg' = [jg EXCEPT !["mut"] = TN]
                                                           /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Join",
                                                                                                     pc        |->  "U_TFinish",
                                                                                                     jg        |->  jg["mut"] ] >>
                                                                                                 \o stack["mut"]]
                                                        /\ pc' = [pc EXCEPT !["mut"] = "J_Lock"]
                                                        /\ UNCHANGED << sg, 
                                                                        sgen >>
                                                   ELSE /\ /\ sg' = [sg EXCEPT !["mut"] = TN]
                                                           /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "StopAndJoin",
                                                                                                     pc        |->  "U_TFinish",
                                                                                                     sgen      |->  sgen["mut"],
                                                                                                     sg        |->  sg["mut"] ] >>
                                                                                                 \o stack["mut"]]
                                                        /\ sgen' = [sgen EXCEPT !["mut"] = 0]
                                                        /\ pc' = [pc EXCEPT !["mut"] = "SJ_Lock"]
                                                        /\ jg' = jg
            /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                            joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                            hold, refused, fstop, mg, lg, wait, k, forked, 
                            seen, cseen >>

U_TFinish == /\ pc["mut"] = "U_TFinish"
             /\ Alive("mut")
             /\ IF ~ctl[TN].done
                   THEN /\ work' = [work EXCEPT ![TN] = 0]
                   ELSE /\ TRUE
                        /\ work' = work
             /\ pc' = [pc EXCEPT !["mut"] = "U_Reap"]
             /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                             joinedGen, finished, ctl, held, bgEp, fgGo, hold, 
                             refused, fstop, stack, mg, lg, jg, sg, sgen, wait, 
                             k, forked, seen, cseen >>

U_Reap == /\ pc["mut"] = "U_Reap"
          /\ /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Reap",
                                                       pc        |->  "U_Relaunch",
                                                       wait      |->  wait["mut"] ] >>
                                                   \o stack["mut"]]
             /\ wait' = [wait EXCEPT !["mut"] = FALSE]
          /\ pc' = [pc EXCEPT !["mut"] = "RP_Check"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                          hold, refused, fstop, mg, lg, jg, sg, sgen, k, 
                          forked, seen, cseen >>

U_Relaunch == /\ pc["mut"] = "U_Relaunch"
              /\ Alive("mut")
              /\ IF (bgEp = "None" \/ (MUTANT = "relaunch_unreaped" /\ ~ctl[CM].done)) /\ work[CM] > 0
                    THEN /\ /\ lg' = [lg EXCEPT !["mut"] = CM]
                            /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Launch",
                                                                      pc        |->  "U_Next",
                                                                      lg        |->  lg["mut"] ] >>
                                                                  \o stack["mut"]]
                         /\ pc' = [pc EXCEPT !["mut"] = "L_Lock"]
                         /\ bgEp' = bgEp
                    ELSE /\ IF bgEp = "None"
                               THEN /\ bgEp' = "Finished"
                               ELSE /\ TRUE
                                    /\ bgEp' = bgEp
                         /\ pc' = [pc EXCEPT !["mut"] = "U_Next"]
                         /\ UNCHANGED << stack, lg >>
              /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                              joinedGen, finished, ctl, work, held, fgGo, hold, 
                              refused, fstop, mg, jg, sg, sgen, wait, k, 
                              forked, seen, cseen >>

U_Next == /\ pc["mut"] = "U_Next"
          /\ Alive("mut")
          /\ IF k = Steps
                THEN /\ pc' = [pc EXCEPT !["mut"] = "U_Close"]
                     /\ UNCHANGED << stack, lg, k >>
                ELSE /\ IF TwoGangs
                           THEN /\ k' = k + 1
                                /\ /\ lg' = [lg EXCEPT !["mut"] = TN]
                                   /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Launch",
                                                                             pc        |->  "U_MaybeFork",
                                                                             lg        |->  lg["mut"] ] >>
                                                                         \o stack["mut"]]
                                /\ pc' = [pc EXCEPT !["mut"] = "L_Lock"]
                           ELSE /\ k' = k + 1
                                /\ pc' = [pc EXCEPT !["mut"] = "U_MaybeFork"]
                                /\ UNCHANGED << stack, lg >>
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                          hold, refused, fstop, mg, jg, sg, sgen, wait, forked, 
                          seen, cseen >>

U_Close == /\ pc["mut"] = "U_Close"
           /\ /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Reap",
                                                        pc        |->  "U_CloseRun",
                                                        wait      |->  wait["mut"] ] >>
                                                    \o stack["mut"]]
              /\ wait' = [wait EXCEPT !["mut"] = FALSE]
           /\ pc' = [pc EXCEPT !["mut"] = "RP_Check"]
           /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                           joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                           hold, refused, fstop, mg, lg, jg, sg, sgen, k, 
                           forked, seen, cseen >>

U_CloseRun == /\ pc["mut"] = "U_CloseRun"
              /\ Alive("mut")
              /\ IF bgEp = "Running"
                    THEN /\ pc' = [pc EXCEPT !["mut"] = "U_RunLock"]
                    ELSE /\ pc' = [pc EXCEPT !["mut"] = "U_Drain"]
              /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                              joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                              hold, refused, fstop, stack, mg, lg, jg, sg, 
                              sgen, wait, k, forked, seen, cseen >>

U_RunLock == /\ pc["mut"] = "U_RunLock"
             /\ Alive("mut")
             /\ IF MarkThreads = 2
                   THEN /\ runM = "none"
                        /\ runM' = "mut"
                        /\ fgGo' = TRUE
                   ELSE /\ TRUE
                        /\ UNCHANGED << runM, fgGo >>
             /\ pc' = [pc EXCEPT !["mut"] = "U_Mark"]
             /\ UNCHANGED << world, exited, reg, bm, running, gen, joinedGen, 
                             finished, ctl, work, held, bgEp, hold, refused, 
                             fstop, stack, mg, lg, jg, sg, sgen, wait, k, 
                             forked, seen, cseen >>

U_Mark == /\ pc["mut"] = "U_Mark"
          /\ /\ mg' = [mg EXCEPT !["mut"] = CM]
             /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Mark",
                                                       pc        |->  "U_FgWait",
                                                       mg        |->  mg["mut"] ] >>
                                                   \o stack["mut"]]
          /\ pc' = [pc EXCEPT !["mut"] = "K_Step"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                          hold, refused, fstop, lg, jg, sg, sgen, wait, k, 
                          forked, seen, cseen >>

U_FgWait == /\ pc["mut"] = "U_FgWait"
            /\ Alive("mut") /\ (~fgGo \/ MUTANT = "run_no_wait")
            /\ IF MarkThreads = 2 /\ MUTANT # "join_in_run"
                  THEN /\ runM' = "none"
                  ELSE /\ TRUE
                       /\ runM' = runM
            /\ pc' = [pc EXCEPT !["mut"] = "U_Reap2"]
            /\ UNCHANGED << world, exited, reg, bm, running, gen, joinedGen, 
                            finished, ctl, work, held, bgEp, fgGo, hold, 
                            refused, fstop, stack, mg, lg, jg, sg, sgen, wait, 
                            k, forked, seen, cseen >>

U_Reap2 == /\ pc["mut"] = "U_Reap2"
           /\ /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "Reap",
                                                        pc        |->  "U_Assert",
                                                        wait      |->  wait["mut"] ] >>
                                                    \o stack["mut"]]
              /\ wait' = [wait EXCEPT !["mut"] = TRUE]
           /\ pc' = [pc EXCEPT !["mut"] = "RP_Check"]
           /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                           joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                           hold, refused, fstop, mg, lg, jg, sg, sgen, k, 
                           forked, seen, cseen >>

U_Assert == /\ pc["mut"] = "U_Assert"
            /\ Alive("mut")
            /\ IF MarkThreads = 2 /\ MUTANT = "join_in_run"
                  THEN /\ runM' = "none"
                  ELSE /\ TRUE
                       /\ runM' = runM
            /\ pc' = [pc EXCEPT !["mut"] = "U_Drain"]
            /\ UNCHANGED << world, exited, reg, bm, running, gen, joinedGen, 
                            finished, ctl, work, held, bgEp, fgGo, hold, 
                            refused, fstop, stack, mg, lg, jg, sg, sgen, wait, 
                            k, forked, seen, cseen >>

U_Drain == /\ pc["mut"] = "U_Drain"
           /\ Alive("mut")
           /\ IF work[CM] > 0
                 THEN /\ work' = [work EXCEPT ![CM] = 0]
                 ELSE /\ TRUE
                      /\ work' = work
           /\ pc' = [pc EXCEPT !["mut"] = "U_Handoff"]
           /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                           joinedGen, finished, ctl, held, bgEp, fgGo, hold, 
                           refused, fstop, stack, mg, lg, jg, sg, sgen, wait, 
                           k, forked, seen, cseen >>

U_Handoff == /\ pc["mut"] = "U_Handoff"
             /\ Alive("mut")
             /\ TRUE
             /\ pc' = [pc EXCEPT !["mut"] = "U_Exit"]
             /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                             joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                             hold, refused, fstop, stack, mg, lg, jg, sg, sgen, 
                             wait, k, forked, seen, cseen >>

U_Exit == /\ pc["mut"] = "U_Exit"
          /\ Alive("mut")
          /\ TRUE
          /\ pc' = [pc EXCEPT !["mut"] = "Done"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                          hold, refused, fstop, stack, mg, lg, jg, sg, sgen, 
                          wait, k, forked, seen, cseen >>

Mutator == U_Launch \/ U_Launch2 \/ U_MaybeFork \/ U_Tenure \/ U_TFinish
              \/ U_Reap \/ U_Relaunch \/ U_Next \/ U_Close \/ U_CloseRun
              \/ U_RunLock \/ U_Mark \/ U_FgWait \/ U_Reap2 \/ U_Assert
              \/ U_Drain \/ U_Handoff \/ U_Exit

B_Wait(self) == /\ pc[self] = "B_Wait"
                /\ Alive(self) /\ bm[GangOf(self)] = "none" /\ gen[GangOf(self)] # seen[self]
                /\ seen' = [seen EXCEPT ![self] = gen[GangOf(self)]]
                /\ pc' = [pc EXCEPT ![self] = "B_Run"]
                /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                joinedGen, finished, ctl, work, held, bgEp, 
                                fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                sg, sgen, wait, k, forked, cseen >>

B_Run(self) == /\ pc[self] = "B_Run"
               /\ /\ mg' = [mg EXCEPT ![self] = GangOf(self)]
                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Mark",
                                                           pc        |->  "B_Fin",
                                                           mg        |->  mg[self] ] >>
                                                       \o stack[self]]
               /\ pc' = [pc EXCEPT ![self] = "K_Step"]
               /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                               joinedGen, finished, ctl, work, held, bgEp, 
                               fgGo, hold, refused, fstop, lg, jg, sg, sgen, 
                               wait, k, forked, seen, cseen >>

B_Fin(self) == /\ pc[self] = "B_Fin"
               /\ Alive(self) /\ bm[GangOf(self)] = "none"
               /\ ~(RelaunchWaitsStopper /\ GangOf(self) = CM /\ fstop # 0 /\ gen[CM] # fstop)
               /\ finished' = [finished EXCEPT ![GangOf(self)] = finished[GangOf(self)] + 1]
               /\ pc' = [pc EXCEPT ![self] = "B_Wait"]
               /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                               joinedGen, ctl, work, held, bgEp, fgGo, hold, 
                               refused, fstop, stack, mg, lg, jg, sg, sgen, 
                               wait, k, forked, seen, cseen >>

BgMember(self) == B_Wait(self) \/ B_Run(self) \/ B_Fin(self)

FG_Wait == /\ pc["fg1"] = "FG_Wait"
           /\ Alive("fg1") /\ fgGo
           /\ pc' = [pc EXCEPT !["fg1"] = "FG_Run"]
           /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                           joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                           hold, refused, fstop, stack, mg, lg, jg, sg, sgen, 
                           wait, k, forked, seen, cseen >>

FG_Run == /\ pc["fg1"] = "FG_Run"
          /\ /\ mg' = [mg EXCEPT !["fg1"] = CM]
             /\ stack' = [stack EXCEPT !["fg1"] = << [ procedure |->  "Mark",
                                                       pc        |->  "FG_Fin",
                                                       mg        |->  mg["fg1"] ] >>
                                                   \o stack["fg1"]]
          /\ pc' = [pc EXCEPT !["fg1"] = "K_Step"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                          hold, refused, fstop, lg, jg, sg, sgen, wait, k, 
                          forked, seen, cseen >>

FG_Fin == /\ pc["fg1"] = "FG_Fin"
          /\ Alive("fg1")
          /\ fgGo' = FALSE
          /\ pc' = [pc EXCEPT !["fg1"] = "FG_Wait"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, hold, 
                          refused, fstop, stack, mg, lg, jg, sg, sgen, wait, k, 
                          forked, seen, cseen >>

FgMember == FG_Wait \/ FG_Run \/ FG_Fin

CB_Wait(self) == /\ pc[self] = "CB_Wait"
                 /\ Alive(self) /\ bm[GangOf(self)] = "none" /\ running[GangOf(self)]
                    /\ gen[GangOf(self)] # cseen[self]
                 /\ cseen' = [cseen EXCEPT ![self] = gen[GangOf(self)]]
                 /\ pc' = [pc EXCEPT ![self] = "CB_Run"]
                 /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                 joinedGen, finished, ctl, work, held, bgEp, 
                                 fgGo, hold, refused, fstop, stack, mg, lg, jg, 
                                 sg, sgen, wait, k, forked, seen >>

CB_Run(self) == /\ pc[self] = "CB_Run"
                /\ /\ mg' = [mg EXCEPT ![self] = GangOf(self)]
                   /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Mark",
                                                            pc        |->  "CB_Fin",
                                                            mg        |->  mg[self] ] >>
                                                        \o stack[self]]
                /\ pc' = [pc EXCEPT ![self] = "K_Step"]
                /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                joinedGen, finished, ctl, work, held, bgEp, 
                                fgGo, hold, refused, fstop, lg, jg, sg, sgen, 
                                wait, k, forked, seen, cseen >>

CB_Fin(self) == /\ pc[self] = "CB_Fin"
                /\ Alive(self) /\ bm[GangOf(self)] = "none"
                /\ finished' = [finished EXCEPT ![GangOf(self)] = finished[GangOf(self)] + 1]
                /\ pc' = [pc EXCEPT ![self] = "CB_Wait"]
                /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                                joinedGen, ctl, work, held, bgEp, fgGo, hold, 
                                refused, fstop, stack, mg, lg, jg, sg, sgen, 
                                wait, k, forked, seen, cseen >>

CBgMember(self) == CB_Wait(self) \/ CB_Run(self) \/ CB_Fin(self)

CF_Wait == /\ pc["cfg1"] = "CF_Wait"
           /\ Alive("cfg1") /\ fgGo
           /\ pc' = [pc EXCEPT !["cfg1"] = "CF_Run"]
           /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                           joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                           hold, refused, fstop, stack, mg, lg, jg, sg, sgen, 
                           wait, k, forked, seen, cseen >>

CF_Run == /\ pc["cfg1"] = "CF_Run"
          /\ /\ mg' = [mg EXCEPT !["cfg1"] = CM]
             /\ stack' = [stack EXCEPT !["cfg1"] = << [ procedure |->  "Mark",
                                                        pc        |->  "CF_Fin",
                                                        mg        |->  mg["cfg1"] ] >>
                                                    \o stack["cfg1"]]
          /\ pc' = [pc EXCEPT !["cfg1"] = "K_Step"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, fgGo, 
                          hold, refused, fstop, lg, jg, sg, sgen, wait, k, 
                          forked, seen, cseen >>

CF_Fin == /\ pc["cfg1"] = "CF_Fin"
          /\ Alive("cfg1")
          /\ fgGo' = FALSE
          /\ pc' = [pc EXCEPT !["cfg1"] = "CF_Wait"]
          /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, 
                          joinedGen, finished, ctl, work, held, bgEp, hold, 
                          refused, fstop, stack, mg, lg, jg, sg, sgen, wait, k, 
                          forked, seen, cseen >>

CFgMember == CF_Wait \/ CF_Run \/ CF_Fin

H_Act == /\ pc["host"] = "H_Act"
         /\ Alive("host")
         /\ \/ /\ Forker = "host" /\ ForkAllowed
               /\ stack' = [stack EXCEPT !["host"] = << [ procedure |->  "ForkGangs",
                                                          pc        |->  "Done" ] >>
                                                      \o stack["host"]]
               /\ pc' = [pc EXCEPT !["host"] = "G_Mark1"]
               /\ UNCHANGED <<sg, sgen>>
            \/ /\ ForeignStop /\ running[CM]
               /\ /\ sg' = [sg EXCEPT !["host"] = CM]
                  /\ stack' = [stack EXCEPT !["host"] = << [ procedure |->  "StopAndJoin",
                                                             pc        |->  "Done",
                                                             sgen      |->  sgen["host"],
                                                             sg        |->  sg["host"] ] >>
                                                         \o stack["host"]]
               /\ sgen' = [sgen EXCEPT !["host"] = 0]
               /\ pc' = [pc EXCEPT !["host"] = "SJ_Lock"]
            \/ /\ TRUE
               /\ pc' = [pc EXCEPT !["host"] = "Done"]
               /\ UNCHANGED <<stack, sg, sgen>>
         /\ UNCHANGED << world, exited, reg, runM, bm, running, gen, joinedGen, 
                         finished, ctl, work, held, bgEp, fgGo, hold, refused, 
                         fstop, mg, lg, jg, wait, k, forked, seen, cseen >>

Host == H_Act

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Mutator \/ FgMember \/ CFgMember \/ Host
           \/ (\E self \in ProcSet:  \/ Mark(self) \/ Launch(self) \/ Join(self)
                                     \/ StopAndJoin(self) \/ Reap(self)
                                     \/ ForkGangs(self) \/ ExitGangs(self))
           \/ (\E self \in BgIds \cup TnIds: BgMember(self))
           \/ (\E self \in CBgIds \cup CTnIds: CBgMember(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ /\ WF_vars(Mutator)
           /\ WF_vars(Launch("mut"))
           /\ WF_vars(ForkGangs("mut"))
           /\ WF_vars(ExitGangs("mut"))
           /\ WF_vars(Join("mut"))
           /\ WF_vars(StopAndJoin("mut"))
           /\ WF_vars(Reap("mut"))
           /\ WF_vars(Mark("mut"))
        /\ \A self \in BgIds \cup TnIds : WF_vars(BgMember(self)) /\ WF_vars(Mark(self))
        /\ WF_vars(FgMember) /\ WF_vars(Mark("fg1"))
        /\ \A self \in CBgIds \cup CTnIds : WF_vars(CBgMember(self)) /\ WF_vars(Mark(self))
        /\ WF_vars(CFgMember) /\ WF_vars(Mark("cfg1"))
        /\ WF_vars(Host) /\ WF_vars(ForkGangs("host")) /\ WF_vars(StopAndJoin("host"))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION
-----------------------------------------------------------------------------
\* Properties that read procedure locals, and the liveness properties.

\* launch()'s poolAbort("already running"), as an invariant: a launch starts
\* only on a joined gang.
LaunchIdle == pc["mut"] = "L_Lock" => ~running[lg["mut"]]
\* CR-023: a foreign stopAndJoin waits only for the episode it stopped: once
\* the owner relaunched (gen # my_gen), the stopper's wake-up is enabled
\* (register-fixes §7.2 step 5; mutant no_stop_gen waits out the new episode).
StopWaitsOwnEpisode == pc["host"] = "SJ_Wait" =>
                           \/ gen[sg["host"]] = sgen["host"]
                           \/ ENABLED SJ_Wait("host")
\* Liveness (parent): the mutator reaches the handoff or exits (no deadlock).
ParentProgress == [](world = "parent") => <>(pc["mut"] = "Done")
\* Liveness: a mutator's child continues the cycle to the handoff.
ChildProgress == (world = "child" /\ Forker = "mut") ~> (pc["mut"] = "Done")
=============================================================================
