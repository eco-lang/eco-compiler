---------------------------- MODULE SliceControl ----------------------------
(***************************************************************************)
(* M2: the marker loop, tickets and termination.                           *)
(*                                                                         *)
(* Plan: plans/threaded-gc-tla-M2-slice-control.md. One model of           *)
(* markwork::runMarkerLoop (runtime/src/allocator/MarkWork.hpp) and of the *)
(* five environments that drive it (OldGenSpace::ParallelEnv and the four  *)
(* nursery environments). MAPPING.md maps every label to the code; AUDIT.md *)
(* records the results and every change from the plan's sketch.            *)
(*                                                                         *)
(* A label sits only at a shared access. Owner-only work (the ring, the    *)
(* private stack, the ticket count, the role, the saved word) is folded    *)
(* into the next shared access, and a call that does nothing (an empty     *)
(* publishAll, a returnTickets of zero) is not a step.                     *)
(*                                                                         *)
(* Edit the PlusCal, never the translation: re-translate a scratch copy    *)
(* with `pcal -nocfg SliceControl.tla` and copy it back.                   *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Nodes, Edges, Roots,      \* the immutable object graph (P1: frozen heap)
    BgSlots,                  \* slots whose participants start counted active
    FgSlot,                   \* 0 = no foreground joiner
    VictimSlots,              \* slots with a deque but no participant (c.n > participants)
    InitDeque,                \* [Slots -> Seq(Nodes)]: work in the deques at launch
    InitStack,                \* [Slots -> Seq(Nodes)]: work on private stacks at launch (5b: slot 0)
    Budget0,                  \* initial c.budget (tickets)
    TB,                       \* kTicketBatch (256 in code)
    RING,                     \* kRingDepth (16 in code)
    PUB_MIN,                  \* kPublishMin (64 in code)
    AnyWorkCountsPriv,        \* TRUE = ParallelEnv (mark), FALSE = the nursery envs
    StopAllowed,              \* a stop request may arrive (bg episodes, 7c L3)
    AssistRuns,               \* how many assists the joiner makes before its closing join
    AssistBudget,             \* tickets for the assist
    DoClosing,                \* the joiner ends with a closing (Member) run
    CapGiveUps,               \* TRUE only for liveness: cap the spurious empty steals
    MaxGiveUps,               \* the cap per run when CapGiveUps
    EpochMod,                 \* 0 = exact epoch (dirty flags); k > 0 = epoch mod k (wrap)
    MUTANT                    \* "none" or a negative control (plan §5, AUDIT.md)

JoinerSet == IF FgSlot = 0 THEN {} ELSE {FgSlot}
Procs == BgSlots \cup JoinerSet                   \* the participants
Slots == Procs \cup VictimSlots                   \* the victim range c.n
MutId == 0
MutSet == IF StopAllowed THEN {MutId} ELSE {}
Children(nd) == {m \in Nodes : <<nd, m>> \in Edges}
RECURSIVE ReachFrom(_)
ReachFrom(S) == LET N == S \cup UNION {Children(nd) : nd \in S}
                IN IF N = S THEN S ELSE ReachFrom(N)
Reachable == ReachFrom(Roots)
Range(sq) == {sq[i] : i \in 1..Len(sq)}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
\* anyWork()'s range: the victim range c.n (05c). The mutant scans only the
\* slots of the participants counted at launch (the pre-05c "n = members").
AnyWorkRange == IF MUTANT = "anywork_participants_only" THEN BgSlots ELSE Slots
\* A drain run (kDrainBudget): the budget can never run out, since at most two
\* scans per node (split_tas) and TB held tickets per participant are ever
\* drawn from it. Then budget.load() > 0 always holds, the idle loop's budget
\* loads have a fixed outcome, and they are not steps (MAPPING.md §3).
BudgetNeverEmpty == Budget0 > 2 * Cardinality(Nodes) + TB * Cardinality(Procs)
\* The saved word s: with an exact epoch (EpochMod = 0) only whether s.active
\* is zero matters (the code tests active == 0 and CASes only from such a
\* word; the dirty flags stand for the epoch), so the model keeps its sign.
Saved(w) == IF EpochMod = 0
            THEN [w EXCEPT !.active = IF @ = 0 THEN 0 ELSE IF @ > 0 THEN 1 ELSE -1]
            ELSE w

ASSUME /\ UNION {Range(InitDeque[x]) \cup Range(InitStack[x]) : x \in Slots} = Roots
       /\ PUB_MIN >= 2 /\ TB >= 1 /\ RING >= 1
       /\ MutId \notin Slots
       /\ AssistRuns \in Nat
       /\ (AssistRuns > 0 \/ DoClosing) <=> FgSlot # 0

(* --algorithm SliceControl
variables
    deque   = InitDeque,                      \* WorkStealingDeque per slot
    pstack  = InitStack,                      \* private stack (owner only)
    priv    = [x \in Slots |-> Len(InitStack[x])],  \* published size of pstack (relaxed)
    mark    = [nd \in Nodes |-> nd \in Roots], \* mark bits (fetch_or)
    scanned = [nd \in Nodes |-> 0],           \* ghost: scans per node
    budget  = Budget0,                        \* c.budget
    apool   = 0,                              \* the assist's pool
    word    = [active |-> Cardinality(BgSlots), epoch |-> 0, done |-> FALSE],
    dirty   = [p \in Procs |-> FALSE],        \* EpochMod = 0: "reactivated since my load"
    stop    = FALSE,                          \* c.stop
    share   = 0,                              \* c.share_epoch
    uBudget = 0,                              \* ghost: scans by participants drawing on c.budget
    uAssist = 0;                              \* ghost: scans by the assist

define
    NullWord == [active |-> 0, epoch |-> 0, done |-> FALSE]
    NoWorkAnywhere == \A x \in Slots : deque[x] = <<>> /\ pstack[x] = <<>>
    \* Every entry scanned at most once (IM10).
    ScanOnce == \A nd \in Nodes : scanned[nd] <= 1
    \* The done bit is set only when nothing is left to do (P§3.3):
    \* either the budget ran out, or no entry is held anywhere.
    TerminationSafe ==
        word.done => (budget = 0 \/ (NoWorkAnywhere /\ word.active = 0))
    \* The deciders between their state load (I_Load) and their done-CAS.
    DecWindow == {"I_Stop", "I_Budget1", "I_Scan1", "I_Priv1",
                  "I_Budget2", "I_Scan2", "I_Priv2", "I_Decide"}
    \* reactivate(): the epoch bump. EpochMod = 0: the epoch never wraps, and its
    \* only use is to fail the done-CAS of a decider that loaded the word
    \* earlier, so it is exactly a dirty flag per open decision window.
    NextEpoch(e) == IF EpochMod = 0 THEN 0 ELSE (e + 1) % EpochMod
    Bump(me) == IF EpochMod = 0
                THEN [p \in Procs |-> p # me /\ pc[p] \in DecWindow]
                ELSE dirty
    \* Guards read at the start of a step (define operators are not primed).
    PoolLeft(pl) == IF pl = "budget" THEN budget ELSE apool
    CanPublish(me) == pstack[me] # <<>> /\ MUTANT # "skip_exit_publish"
    OwnPriv(me) == AnyWorkCountsPriv /\ priv[me] # 0
    \* MUTANTs idle_before_publish and idle_before_publish_onescan (plan §5).
    IdleBeforePublish == MUTANT \in {"idle_before_publish", "idle_before_publish_onescan"}
end define;

\* ---------------------------------------------------------------------------
\* Owner-only helpers (text substitution into the calling step)
\* ---------------------------------------------------------------------------

\* claimTicket's successful batch CAS (MarkWork.hpp); the caller has
\* checked that the pool is not empty. One ticket is consumed at once.
macro ClaimBatch() begin
    if pool = "budget" then
        tickets := (IF budget < TB THEN budget ELSE TB) - 1;
        budget  := budget - (IF budget < TB THEN budget ELSE TB);
    else
        tickets := (IF apool < TB THEN apool ELSE TB) - 1;
        apool   := apool - (IF apool < TB THEN apool ELSE TB);
    end if;
end macro;

\* returnTickets(w, pool): one fetch_add; callers skip it for zero tickets.
\* MUTANT assist_returns_to_budget: always to c.budget.
macro ReturnTickets() begin
    if pool = "budget" \/ MUTANT = "assist_returns_to_budget" then
        budget := budget + tickets;
    else
        apool := apool + tickets;
    end if;
    tickets := 0;
end macro;

macro GoIdle() begin
    if MUTANT # "joiner_invisible" \/ role # "Assist" then
        word := [word EXCEPT !.active = @ - 1];      \* state.fetch_sub(1)
    end if;                                          \* (joiner_invisible: an assist that
end macro;                                           \* never touches the word)

\* One deque.push of the oldest private entry (publishAll / publishHalf).
macro PushOne() begin
    deque[self] := Append(deque[self], Head(pstack[self]));
    pstack[self] := Tail(pstack[self]);
end macro;

\* After the loop-top loads: fill the ring, scan it, or leave (runMarkerLoop).
macro Dispatch() begin
    if stopping then
        if ring = <<>> then goto R_ExitActive;       \* ring empty; still active
        else goto R_Scan; end if;
    elsif Len(ring) >= RING then
        goto R_Scan;
    else
        goto R_Fill;
    end if;
end macro;

\* The loop top: stop.load(relaxed), then share_epoch.load (a step of its own).
macro LoopTop() begin
    stopping := stop;
    if JoinerSet # {} then goto R_Share; else Dispatch(); end if;
end macro;

\* `continue` after a step that made a shared access: the loop-top loads are
\* steps of their own, unless their value is constant (no stop request can
\* come; no joiner bumps share_epoch).
macro ToTop() begin
    if StopAllowed then goto R_Top;
    elsif JoinerSet # {} then goto R_Share;
    else Dispatch();
    end if;
end macro;

\* After an entry went into the ring: fill on, or scan.
macro AfterTake() begin
    if Len(ring) >= RING then goto R_Scan; else goto R_Fill; end if;
end macro;

\* env.takeOwn(self) (OldGenSpace::ParallelEnv::takeOwn; the
\* nursery envs alike): private stack first (pop + priv store), else
\* deque.take(). d = 1 when the ticket was already in hand (the claim needed
\* no shared access and folds into this step).
macro TakeOwn(d) begin
    if pstack[self] # <<>> then
        ring := Append(ring, pstack[self][Len(pstack[self])]);
        pstack[self] := SubSeq(pstack[self], 1, Len(pstack[self]) - 1);
        priv[self] := Len(pstack[self]);
        tickets := tickets - d;
        if Len(pstack[self]) >= PUB_MIN then         \* every 64th pop: publishHalf
            either AfterTake();
            or goto R_PopPub;
            end either;
        else
            AfterTake();
        end if;
    elsif deque[self] # <<>> then                    \* deque.take(): bottom
        ring := Append(ring, deque[self][Len(deque[self])]);
        deque[self] := SubSeq(deque[self], 1, Len(deque[self]) - 1);
        tickets := tickets - d;
        if Len(ring) >= RING then goto R_Scan; else goto R_Fill; end if;
    else
        tickets := tickets + 1 - d;                  \* ++w.tickets; break
        if ring = <<>> then goto R_Steal; else goto R_Scan; end if;
    end if;
end macro;

\* (1) One round of the fill loop (runMarkerLoop): claimTicket, then takeOwn.
macro Fill() begin
    if tickets > 0 then
        TakeOwn(1);                                  \* a ticket in hand: this step is takeOwn
    elsif PoolLeft(pool) > 0 then
        ClaimBatch();                                \* the batch CAS on the pool
        goto R_TakeOwn;
    elsif ring = <<>> then
        goto R_Steal;                                \* the claim failed: break
    else
        goto R_Scan;
    end if;
end macro;

\* After one child: the next child, or back to the loop top.
macro NextKid() begin
    if kids # {} then goto R_Kids; else ToTop(); end if;
end macro;

\* greyObject's testAndSetMark (a fetch_or, OldGenSpace::testAndSetMark) on one child
\* of the entry being scanned. MUTANT split_tas: a plain load here, and a plain
\* store later (R_Push).
macro GreyKid(kk) begin
    with ch = Min(kk) do                             \* the children in field order
        kids := kk \ {ch};
        if mark[ch] then
            NextKid();                               \* already marked: nothing to push
        else
            c := ch;
            if MUTANT # "split_tas" then mark[ch] := TRUE; end if;
            goto R_Push;
        end if;
    end with;
end macro;

\* (3) stealAny with a ticket in hand (MarkWork.hpp stealAny, runMarkerLoop): each
\* deque.steal() is atomic; "nothing" is a legal outcome while work exists
\* (victims read at different moments, or four passes of lost CASes).
\* d = 1 when the ticket was already in hand.
macro StealTry(d) begin
    either
        with v \in {x \in Slots \ {self} : deque[x] # <<>>} do
            ring := Append(ring, Head(deque[v]));
            deque[v] := Tail(deque[v]);
        end with;
        if MUTANT = "steal_without_ticket" then
            goto R_StealClaim;                       \* the hook claims after the steal
        else
            tickets := tickets - d;
            ToTop();
        end if;
    or
        await ~CapGiveUps \/ giveups < MaxGiveUps
              \/ \A x \in Slots \ {self} : deque[x] = <<>>;
        if CapGiveUps /\ \E x \in Slots \ {self} : deque[x] # <<>> then
            giveups := giveups + 1;
        end if;
        if MUTANT # "steal_without_ticket" then
            tickets := tickets + 1 - d;              \* ++w.tickets
        end if;
        if role = "Assist" then goto R_ExitActive;   \* an Assist never idles
        else goto R_Idle; end if;
    end either;
end macro;

\* Into anyWork() after the state load: `budget.load(acquire) > 0` is a step,
\* unless the budget can never run out (BudgetNeverEmpty).
macro ToBudget1() begin
    if BudgetNeverEmpty then aw := AnyWorkRange; goto I_Scan1;
    else goto I_Budget1; end if;
end macro;

\* The active == 0 branch: re-read budget and work (idleUntilWorkOrDone).
macro ToBudget2() begin
    if MUTANT = "idle_before_publish_onescan" then aw := {}; goto I_Decide;
    elsif BudgetNeverEmpty then aw := AnyWorkRange; goto I_Scan2;
    else aw := {}; goto I_Budget2; end if;
end macro;

\* Leave idleUntilWorkOrDone (done or stop): the exit's publishAll and
\* returnTickets are no-ops, since the idle path published and returned
\* before goIdle; so the run returns in this step unless a mutant left work.
macro ExitIdle() begin
    if pstack[self] = <<>> /\ tickets = 0 then return;
    else goto R_ExitIdle; end if;
end macro;

\* ---------------------------------------------------------------------------
\* publishAll(self): one deque.push per step, oldest first; priv is stored
\* only at the end (OldGenSpace::publishAll, NurserySpace::publishAllP).
\* Callers skip it on an empty stack (`if (w.stack.empty()) return;`). A
\* caller whose step makes no other shared access does the first push itself
\* (PushOne, then the call); a caller whose step has its own shared access
\* (a load, goIdle) calls with the whole stack, and PA_Loop does the first
\* push. MUTANT skip_exit_publish is the code's test_leave_private_on_exit_
\* hook: ParallelEnv::publishAll returns before doing anything at every call
\* site (CanPublish is FALSE).
\* ---------------------------------------------------------------------------
procedure PublishAll()
begin
  PA_Loop:
    if pstack[self] # <<>> then
        PushOne();
        if pstack[self] # <<>> then goto PA_Loop; end if;
    else
        priv[self] := 0;                             \* priv.store(0)
        return;
    end if;
  PA_Priv:
    priv[self] := 0;
    return;
end procedure;

\* ---------------------------------------------------------------------------
\* runMarkerLoop(env, self, c, pool, role, joined) (MarkWork.hpp),
\* after the joiner's reactivate(), which the Joiner process does at the call.
\* ---------------------------------------------------------------------------
procedure Run(role, pool)
variables ring = <<>>, tickets = 0, active = TRUE, seen = 0,
          stopping = FALSE, kids = {}, c = 0,
          sw = NullWord, aw = {}, giveups = 0, half = 0;
begin
  R_Top:                                             \* the run's first step, and the loop
    if StopAllowed then                              \* top when a stop can come:
        LoopTop();                                   \* c.stopRequested() (relaxed)
    elsif JoinerSet # {} then                        \* stop is constant: this step is
        if share # seen then                         \* R_Share's share_epoch load
            seen := share;
            if CanPublish(self) then                 \* publishAll (its pushes are
                call PublishAll();                   \* steps of their own), then
                goto R_Fill;                         \* the fill
            else
                Dispatch();
            end if;
        else
            Dispatch();
        end if;
    else
        Fill();                                      \* stop and share_epoch are constant
    end if;
  R_Share:                                           \* share_epoch.load(relaxed)
    if share # seen then
        seen := share;
        if CanPublish(self) then                     \* publishAll, then the fill
            call PublishAll();
            goto R_Fill;
        else
            Dispatch();
        end if;
    else
        Dispatch();
    end if;
  R_Fill:                                            \* (1) fill the ring
    if stopping \/ Len(ring) >= RING then            \* only after R_Share's publish
        Dispatch();
    else
        Fill();
    end if;
  R_TakeOwn:                                         \* env.takeOwn(self), after a claim CAS
    TakeOwn(0);
  R_Scan:                                            \* (2) scan the oldest ring entry
    with e = Head(ring) do
        scanned[e] := scanned[e] + 1;
        ring := Tail(ring);
        if pool = "budget" then uBudget := uBudget + 1;
        else uAssist := uAssist + 1; end if;
        if Children(e) = {} then
            LoopTop();                               \* `continue`
        else
            GreyKid(Children(e));                    \* the first child's fetch_or
        end if;
    end with;
  R_Kids:                                            \* the next child's fetch_or
    GreyKid(kids);
  R_Push:                                            \* pushGrey: stack push + priv store
    if MUTANT = "split_tas" then mark[c] := TRUE; end if;   \* the plain store, later
    pstack[self] := Append(pstack[self], c);
    priv[self] := Len(pstack[self]);
    c := 0;
    if Len(pstack[self]) >= PUB_MIN then
        either NextKid();                            \* not at a multiple of 32
        or goto R_PubHalf;
        end either;
    else
        NextKid();
    end if;
  R_PubHalf:                                         \* publishHalf: deque.emptyApprox();
    if deque[self] = <<>> then                       \* only the owner can make an empty
        half := Len(pstack[self]) \div 2 - 1;        \* deque non-empty, so the first push
        PushOne();                                   \* folds into this step
        if half > 0 then goto R_PubHalfLoop; else goto R_PubHalfPriv; end if;
    else
        NextKid();
    end if;
  R_PubHalfLoop:                                     \* one deque.push per step
    PushOne();
    half := half - 1;
    if half > 0 then goto R_PubHalfLoop; end if;
  R_PubHalfPriv:                                     \* priv.store(stack.size())
    priv[self] := Len(pstack[self]);
    NextKid();
  R_PopPub:                                          \* takeOwn's publishHalf: emptyApprox
    if deque[self] = <<>> then                       \* (as R_PubHalf)
        half := Len(pstack[self]) \div 2 - 1;
        PushOne();
        if half > 0 then goto R_PopPubLoop; else goto R_PopPubPriv; end if;
    else
        AfterTake();
    end if;
  R_PopPubLoop:
    PushOne();
    half := half - 1;
    if half > 0 then goto R_PopPubLoop; end if;
  R_PopPubPriv:
    priv[self] := Len(pstack[self]);
    AfterTake();
  R_Steal:                                           \* (3) steal, ticket first
    if MUTANT = "steal_without_ticket" then
        StealTry(0);                                 \* the hook: steal before claiming
    elsif tickets > 0 then
        StealTry(1);                                 \* a ticket in hand: this step is the steal
    elsif PoolLeft(pool) > 0 then
        ClaimBatch();
        goto R_StealTry;
    elsif role = "Assist" then
        goto R_ExitActive;                           \* never idles: leave (active)
    else
        goto R_Idle;
    end if;
  R_StealTry:                                        \* stealAny, after a claim CAS
    StealTry(0);
  R_StealClaim:                                      \* MUTANT steal_without_ticket only:
    if tickets > 0 then                              \* claimTicket after the steal; if it
        tickets := tickets - 1;                      \* fails, env.scan(self, e) without
        ToTop();                                     \* a ticket
    elsif PoolLeft(pool) > 0 then
        ClaimBatch();
        ToTop();
    else
        goto R_Scan;
    end if;
  R_Idle:                                            \* (4) idle: publishAll, returnTickets, goIdle
    if IdleBeforePublish then
        ReturnTickets();                             \* variant: return, goIdle, then publish
    elsif CanPublish(self) then
        PushOne();
        call PublishAll();
    elsif MUTANT = "return_after_idle" then
        GoIdle();                                    \* variant: goIdle, then return
        active := FALSE;
        goto R_Idle3;
    elsif tickets # 0 then
        ReturnTickets();
        goto R_Idle3;
    else
        GoIdle();
        active := FALSE;
        goto I_Load;
    end if;
  R_Idle2:
    if IdleBeforePublish then
        GoIdle();
        active := FALSE;
        if CanPublish(self) then call PublishAll(); end if;
    elsif MUTANT = "return_after_idle" then
        GoIdle();
        active := FALSE;
    elsif tickets # 0 then
        ReturnTickets();
    else
        GoIdle();
        active := FALSE;
        goto I_Load;
    end if;
  R_Idle3:
    if active then
        GoIdle();
        active := FALSE;
    elsif MUTANT = "return_after_idle" then
        ReturnTickets();
    end if;
  I_Load:                                            \* idleUntilWorkOrDone: s = state.load
    if word.done then
        ExitIdle();
    else
        sw := Saved(word);
        if ~StopAllowed then ToBudget1(); end if;    \* stop is constant: its load folds in
    end if;
  I_Stop:                                            \* c.stopRequested()
    if stop then
        if MUTANT = "stop_sets_done" then word := [word EXCEPT !.done = TRUE]; end if;
        dirty[self] := FALSE;
        ExitIdle();
    else
        ToBudget1();
    end if;
  I_Budget1:                                         \* budget.load(acquire) > 0 && anyWork()
    if budget > 0 then
        aw := AnyWorkRange;
    elsif sw.active # 0 then                         \* backoff; retry
        dirty[self] := FALSE; sw := NullWord;
        goto I_Load;
    elsif MUTANT = "idle_before_publish_onescan" then
        goto I_Decide;                               \* no re-check
    else
        goto I_Budget2;
    end if;
  I_Scan1:                                           \* anyWork(): slot order, first hit returns
    with x = Min(aw) do
        if deque[x] # <<>> \/ (x = self /\ OwnPriv(self)) then
            aw := {};                                \* !deque.emptyApprox() (own priv:
            goto I_React;                            \* only the owner writes it)
        elsif AnyWorkCountsPriv /\ x # self then
            goto I_Priv1;
        elsif aw # {x} then
            aw := aw \ {x};
            goto I_Scan1;
        elsif sw.active # 0 then
            aw := {}; dirty[self] := FALSE; sw := NullWord;
            goto I_Load;
        else
            ToBudget2();
        end if;
    end with;
  I_Priv1:                                           \* || priv.load(): a second load
    with x = Min(aw) do
        if priv[x] # 0 then
            aw := {};
            goto I_React;
        elsif aw # {x} then
            aw := aw \ {x};
            goto I_Scan1;
        elsif sw.active # 0 then
            aw := {}; dirty[self] := FALSE; sw := NullWord;
            goto I_Load;
        else
            ToBudget2();
        end if;
    end with;
  I_React:                                           \* c.reactivate()
    if word.done then
        dirty[self] := FALSE;
        ExitIdle();
    else
        word := [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)];
        dirty := Bump(self);
        active := TRUE;
        sw := NullWord;
        ToTop();
    end if;
  I_Budget2:                                         \* active == 0 in s: re-read budget, work
    if budget > 0 then
        aw := AnyWorkRange;
    else
        goto I_Decide;
    end if;
  I_Scan2:
    with x = Min(aw) do
        if deque[x] # <<>> \/ (x = self /\ OwnPriv(self)) then
            aw := {}; dirty[self] := FALSE; sw := NullWord;
            goto I_Load;                             \* work: `continue`
        elsif AnyWorkCountsPriv /\ x # self then
            goto I_Priv2;
        elsif aw # {x} then
            aw := aw \ {x};
            goto I_Scan2;
        else
            aw := {};
            goto I_Decide;
        end if;
    end with;
  I_Priv2:
    with x = Min(aw) do
        if priv[x] # 0 then
            aw := {}; dirty[self] := FALSE; sw := NullWord;
            goto I_Load;
        elsif aw # {x} then
            aw := aw \ {x};
            goto I_Scan2;
        else
            aw := {};
            goto I_Decide;
        end if;
    end with;
  I_Decide:                                          \* CAS(state: s -> s | done)
    if MUTANT = "two_word"                           \* two_word: no CAS at all
       \/ (MUTANT # "never_decide" /\ Saved(word) = sw /\ ~dirty[self]) then
        word := [word EXCEPT !.done = TRUE];
        dirty[self] := FALSE;
        ExitIdle();
    else                                             \* CAS failed: `continue`
        dirty[self] := FALSE; sw := NullWord;
        goto I_Load;
    end if;
  R_ExitActive:                                      \* exit while still active
    if IdleBeforePublish then           \* 05c Step 3 variant: goIdle first
        GoIdle();
        if CanPublish(self) then call PublishAll(); end if;
    elsif CanPublish(self) then
        PushOne();
        call PublishAll();
    elsif tickets # 0 then
        ReturnTickets();
        goto R_ExitActive3;
    else
        GoIdle();
        return;
    end if;
  R_ExitActive2:
    if ~IdleBeforePublish /\ tickets = 0 then
        GoIdle();
        return;
    else
        ReturnTickets();
    end if;
  R_ExitActive3:
    if ~IdleBeforePublish then GoIdle(); end if;
    return;
  R_ExitIdle:                                        \* exit after termination or stop with
    sw := NullWord;                                  \* private work left (mutants only)
    if CanPublish(self) then PushOne(); call PublishAll(); end if;
  R_ExitIdle2:
    if tickets # 0 then ReturnTickets(); else return; end if;
  R_ExitIdle3:
    return;
end procedure;

\* ---------------------------------------------------------------------------
\* The threads
\* ---------------------------------------------------------------------------

\* Background members, 5b members, minor and tenure workers: counted active at launch.
fair process Member \in BgSlots
begin
  M_Run:
    call Run("Member", "budget");
end process;

\* The foreground joiner (the mutator's GCMarkGang member on slot FgSlot):
\* AssistRuns assists (assistEpisode), then optionally the closing join
\* (closingFinish). A joined run starts with c.reactivate() and returns at once
\* when the control is already done (runMarkerLoop's first lines).
fair process Joiner \in JoinerSet
variables k = 0;                                     \* assists done
begin
  J_Start:                                           \* share_epoch.fetch_add
    share := share + 1;
    if AssistRuns > 0 then
        apool := AssistBudget;                       \* std::atomic<int64_t> pool{budget}
    else
        goto J_CJoin;
    end if;
  J_AJoin:                                           \* assistEntry: c.reactivate()
    if MUTANT \in {"joiner_no_reactivate", "joiner_invisible"} then
        call Run("Assist", "assist");
    elsif word.done then
        goto J_AssistCheck;
    else
        word := [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)];
        dirty := Bump(self);
        call Run("Assist", "assist");
    end if;
  J_AssistCheck:                                     \* units == budget - pool: AssistExact
    k := k + 1;
    uAssist := 0;
    if k < AssistRuns then                           \* the next assist: share_epoch.fetch_add
        share := share + 1;
        apool := AssistBudget;
        goto J_AJoin;
    elsif DoClosing then
        apool := 0;                                  \* (dead after the check)
        share := share + 1;                          \* closingFinish: share_epoch.fetch_add
    else
        apool := 0;
        goto Done;
    end if;
  J_CJoin:                                           \* closingEntry: c.reactivate()
    if MUTANT = "joiner_no_reactivate" then
        call Run("Member", "budget");
    elsif word.done then
        goto J_ClosingCheck;
    else
        word := [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)];
        dirty := Bump(self);
        call Run("Member", "budget");
    end if;
  J_ClosingCheck:                                    \* reapBackground(true): bg_->join();
    await \A m \in BgSlots : pc[m] = "Done";         \* then the assert: ClosingFinished
end process;

\* Another thread (a fork hook, atexit, or a late 7c collector) runs
\* stopAndJoin(): stop_->store(true) at any moment. Not fair: it may never run.
process Mutator \in MutSet
begin
  S_Stop:
    stop := TRUE;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
CONSTANT defaultInitValue
VARIABLES pc, deque, pstack, priv, mark, scanned, budget, apool, word, dirty, 
          stop, share, uBudget, uAssist, stack

(* define statement *)
NullWord == [active |-> 0, epoch |-> 0, done |-> FALSE]
NoWorkAnywhere == \A x \in Slots : deque[x] = <<>> /\ pstack[x] = <<>>

ScanOnce == \A nd \in Nodes : scanned[nd] <= 1


TerminationSafe ==
    word.done => (budget = 0 \/ (NoWorkAnywhere /\ word.active = 0))

DecWindow == {"I_Stop", "I_Budget1", "I_Scan1", "I_Priv1",
              "I_Budget2", "I_Scan2", "I_Priv2", "I_Decide"}



NextEpoch(e) == IF EpochMod = 0 THEN 0 ELSE (e + 1) % EpochMod
Bump(me) == IF EpochMod = 0
            THEN [p \in Procs |-> p # me /\ pc[p] \in DecWindow]
            ELSE dirty

PoolLeft(pl) == IF pl = "budget" THEN budget ELSE apool
CanPublish(me) == pstack[me] # <<>> /\ MUTANT # "skip_exit_publish"
OwnPriv(me) == AnyWorkCountsPriv /\ priv[me] # 0

IdleBeforePublish == MUTANT \in {"idle_before_publish", "idle_before_publish_onescan"}

VARIABLES role, pool, ring, tickets, active, seen, stopping, kids, c, sw, aw, 
          giveups, half, k

vars == << pc, deque, pstack, priv, mark, scanned, budget, apool, word, dirty, 
           stop, share, uBudget, uAssist, stack, role, pool, ring, tickets, 
           active, seen, stopping, kids, c, sw, aw, giveups, half, k >>

ProcSet == (BgSlots) \cup (JoinerSet) \cup (MutSet)

Init == (* Global variables *)
        /\ deque = InitDeque
        /\ pstack = InitStack
        /\ priv = [x \in Slots |-> Len(InitStack[x])]
        /\ mark = [nd \in Nodes |-> nd \in Roots]
        /\ scanned = [nd \in Nodes |-> 0]
        /\ budget = Budget0
        /\ apool = 0
        /\ word = [active |-> Cardinality(BgSlots), epoch |-> 0, done |-> FALSE]
        /\ dirty = [p \in Procs |-> FALSE]
        /\ stop = FALSE
        /\ share = 0
        /\ uBudget = 0
        /\ uAssist = 0
        (* Procedure Run *)
        /\ role = [ self \in ProcSet |-> defaultInitValue]
        /\ pool = [ self \in ProcSet |-> defaultInitValue]
        /\ ring = [ self \in ProcSet |-> <<>>]
        /\ tickets = [ self \in ProcSet |-> 0]
        /\ active = [ self \in ProcSet |-> TRUE]
        /\ seen = [ self \in ProcSet |-> 0]
        /\ stopping = [ self \in ProcSet |-> FALSE]
        /\ kids = [ self \in ProcSet |-> {}]
        /\ c = [ self \in ProcSet |-> 0]
        /\ sw = [ self \in ProcSet |-> NullWord]
        /\ aw = [ self \in ProcSet |-> {}]
        /\ giveups = [ self \in ProcSet |-> 0]
        /\ half = [ self \in ProcSet |-> 0]
        (* Process Joiner *)
        /\ k = [self \in JoinerSet |-> 0]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self \in BgSlots -> "M_Run"
                                        [] self \in JoinerSet -> "J_Start"
                                        [] self \in MutSet -> "S_Stop"]

PA_Loop(self) == /\ pc[self] = "PA_Loop"
                 /\ IF pstack[self] # <<>>
                       THEN /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                            /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                            /\ IF pstack'[self] # <<>>
                                  THEN /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "PA_Priv"]
                            /\ UNCHANGED << priv, stack >>
                       ELSE /\ priv' = [priv EXCEPT ![self] = 0]
                            /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                            /\ UNCHANGED << deque, pstack >>
                 /\ UNCHANGED << mark, scanned, budget, apool, word, dirty, 
                                 stop, share, uBudget, uAssist, role, pool, 
                                 ring, tickets, active, seen, stopping, kids, 
                                 c, sw, aw, giveups, half, k >>

PA_Priv(self) == /\ pc[self] = "PA_Priv"
                 /\ priv' = [priv EXCEPT ![self] = 0]
                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                 /\ UNCHANGED << deque, pstack, mark, scanned, budget, apool, 
                                 word, dirty, stop, share, uBudget, uAssist, 
                                 role, pool, ring, tickets, active, seen, 
                                 stopping, kids, c, sw, aw, giveups, half, k >>

PublishAll(self) == PA_Loop(self) \/ PA_Priv(self)

R_Top(self) == /\ pc[self] = "R_Top"
               /\ IF StopAllowed
                     THEN /\ stopping' = [stopping EXCEPT ![self] = stop]
                          /\ IF JoinerSet # {}
                                THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                ELSE /\ IF stopping'[self]
                                           THEN /\ IF ring[self] = <<>>
                                                      THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                      ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                           ELSE /\ IF Len(ring[self]) >= RING
                                                      THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                      ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                          /\ UNCHANGED << deque, pstack, priv, budget, apool, 
                                          stack, ring, tickets, seen >>
                     ELSE /\ IF JoinerSet # {}
                                THEN /\ IF share # seen[self]
                                           THEN /\ seen' = [seen EXCEPT ![self] = share]
                                                /\ IF CanPublish(self)
                                                      THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                                                    pc        |->  "R_Fill" ] >>
                                                                                                \o stack[self]]
                                                           /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                                      ELSE /\ IF stopping[self]
                                                                 THEN /\ IF ring[self] = <<>>
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                 ELSE /\ IF Len(ring[self]) >= RING
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                           /\ stack' = stack
                                           ELSE /\ IF stopping[self]
                                                      THEN /\ IF ring[self] = <<>>
                                                                 THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                 ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                      ELSE /\ IF Len(ring[self]) >= RING
                                                                 THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                 ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                /\ UNCHANGED << stack, seen >>
                                     /\ UNCHANGED << deque, pstack, priv, 
                                                     budget, apool, ring, 
                                                     tickets >>
                                ELSE /\ IF tickets[self] > 0
                                           THEN /\ IF pstack[self] # <<>>
                                                      THEN /\ ring' = [ring EXCEPT ![self] = Append(ring[self], pstack[self][Len(pstack[self])])]
                                                           /\ pstack' = [pstack EXCEPT ![self] = SubSeq(pstack[self], 1, Len(pstack[self]) - 1)]
                                                           /\ priv' = [priv EXCEPT ![self] = Len(pstack'[self])]
                                                           /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 1]
                                                           /\ IF Len(pstack'[self]) >= PUB_MIN
                                                                 THEN /\ \/ /\ IF Len(ring'[self]) >= RING
                                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                                         \/ /\ pc' = [pc EXCEPT ![self] = "R_PopPub"]
                                                                 ELSE /\ IF Len(ring'[self]) >= RING
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                           /\ deque' = deque
                                                      ELSE /\ IF deque[self] # <<>>
                                                                 THEN /\ ring' = [ring EXCEPT ![self] = Append(ring[self], deque[self][Len(deque[self])])]
                                                                      /\ deque' = [deque EXCEPT ![self] = SubSeq(deque[self], 1, Len(deque[self]) - 1)]
                                                                      /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 1]
                                                                      /\ IF Len(ring'[self]) >= RING
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                                 ELSE /\ tickets' = [tickets EXCEPT ![self] = tickets[self] + 1 - 1]
                                                                      /\ IF ring[self] = <<>>
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Steal"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                      /\ UNCHANGED << deque, 
                                                                                      ring >>
                                                           /\ UNCHANGED << pstack, 
                                                                           priv >>
                                                /\ UNCHANGED << budget, apool >>
                                           ELSE /\ IF PoolLeft(pool[self]) > 0
                                                      THEN /\ IF pool[self] = "budget"
                                                                 THEN /\ tickets' = [tickets EXCEPT ![self] = (IF budget < TB THEN budget ELSE TB) - 1]
                                                                      /\ budget' = budget - (IF budget < TB THEN budget ELSE TB)
                                                                      /\ apool' = apool
                                                                 ELSE /\ tickets' = [tickets EXCEPT ![self] = (IF apool < TB THEN apool ELSE TB) - 1]
                                                                      /\ apool' = apool - (IF apool < TB THEN apool ELSE TB)
                                                                      /\ UNCHANGED budget
                                                           /\ pc' = [pc EXCEPT ![self] = "R_TakeOwn"]
                                                      ELSE /\ IF ring[self] = <<>>
                                                                 THEN /\ pc' = [pc EXCEPT ![self] = "R_Steal"]
                                                                 ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                           /\ UNCHANGED << budget, 
                                                                           apool, 
                                                                           tickets >>
                                                /\ UNCHANGED << deque, pstack, 
                                                                priv, ring >>
                                     /\ UNCHANGED << stack, seen >>
                          /\ UNCHANGED stopping
               /\ UNCHANGED << mark, scanned, word, dirty, stop, share, 
                               uBudget, uAssist, role, pool, active, kids, c, 
                               sw, aw, giveups, half, k >>

R_Share(self) == /\ pc[self] = "R_Share"
                 /\ IF share # seen[self]
                       THEN /\ seen' = [seen EXCEPT ![self] = share]
                            /\ IF CanPublish(self)
                                  THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                                pc        |->  "R_Fill" ] >>
                                                                            \o stack[self]]
                                       /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                  ELSE /\ IF stopping[self]
                                             THEN /\ IF ring[self] = <<>>
                                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                             ELSE /\ IF Len(ring[self]) >= RING
                                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                       /\ stack' = stack
                       ELSE /\ IF stopping[self]
                                  THEN /\ IF ring[self] = <<>>
                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                             ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                  ELSE /\ IF Len(ring[self]) >= RING
                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                             ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                            /\ UNCHANGED << stack, seen >>
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, word, dirty, stop, share, uBudget, 
                                 uAssist, role, pool, ring, tickets, active, 
                                 stopping, kids, c, sw, aw, giveups, half, k >>

R_Fill(self) == /\ pc[self] = "R_Fill"
                /\ IF stopping[self] \/ Len(ring[self]) >= RING
                      THEN /\ IF stopping[self]
                                 THEN /\ IF ring[self] = <<>>
                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                 ELSE /\ IF Len(ring[self]) >= RING
                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                           /\ UNCHANGED << deque, pstack, priv, budget, apool, 
                                           ring, tickets >>
                      ELSE /\ IF tickets[self] > 0
                                 THEN /\ IF pstack[self] # <<>>
                                            THEN /\ ring' = [ring EXCEPT ![self] = Append(ring[self], pstack[self][Len(pstack[self])])]
                                                 /\ pstack' = [pstack EXCEPT ![self] = SubSeq(pstack[self], 1, Len(pstack[self]) - 1)]
                                                 /\ priv' = [priv EXCEPT ![self] = Len(pstack'[self])]
                                                 /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 1]
                                                 /\ IF Len(pstack'[self]) >= PUB_MIN
                                                       THEN /\ \/ /\ IF Len(ring'[self]) >= RING
                                                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                               \/ /\ pc' = [pc EXCEPT ![self] = "R_PopPub"]
                                                       ELSE /\ IF Len(ring'[self]) >= RING
                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                 /\ deque' = deque
                                            ELSE /\ IF deque[self] # <<>>
                                                       THEN /\ ring' = [ring EXCEPT ![self] = Append(ring[self], deque[self][Len(deque[self])])]
                                                            /\ deque' = [deque EXCEPT ![self] = SubSeq(deque[self], 1, Len(deque[self]) - 1)]
                                                            /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 1]
                                                            /\ IF Len(ring'[self]) >= RING
                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                       ELSE /\ tickets' = [tickets EXCEPT ![self] = tickets[self] + 1 - 1]
                                                            /\ IF ring[self] = <<>>
                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Steal"]
                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                            /\ UNCHANGED << deque, 
                                                                            ring >>
                                                 /\ UNCHANGED << pstack, priv >>
                                      /\ UNCHANGED << budget, apool >>
                                 ELSE /\ IF PoolLeft(pool[self]) > 0
                                            THEN /\ IF pool[self] = "budget"
                                                       THEN /\ tickets' = [tickets EXCEPT ![self] = (IF budget < TB THEN budget ELSE TB) - 1]
                                                            /\ budget' = budget - (IF budget < TB THEN budget ELSE TB)
                                                            /\ apool' = apool
                                                       ELSE /\ tickets' = [tickets EXCEPT ![self] = (IF apool < TB THEN apool ELSE TB) - 1]
                                                            /\ apool' = apool - (IF apool < TB THEN apool ELSE TB)
                                                            /\ UNCHANGED budget
                                                 /\ pc' = [pc EXCEPT ![self] = "R_TakeOwn"]
                                            ELSE /\ IF ring[self] = <<>>
                                                       THEN /\ pc' = [pc EXCEPT ![self] = "R_Steal"]
                                                       ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                 /\ UNCHANGED << budget, apool, 
                                                                 tickets >>
                                      /\ UNCHANGED << deque, pstack, priv, 
                                                      ring >>
                /\ UNCHANGED << mark, scanned, word, dirty, stop, share, 
                                uBudget, uAssist, stack, role, pool, active, 
                                seen, stopping, kids, c, sw, aw, giveups, half, 
                                k >>

R_TakeOwn(self) == /\ pc[self] = "R_TakeOwn"
                   /\ IF pstack[self] # <<>>
                         THEN /\ ring' = [ring EXCEPT ![self] = Append(ring[self], pstack[self][Len(pstack[self])])]
                              /\ pstack' = [pstack EXCEPT ![self] = SubSeq(pstack[self], 1, Len(pstack[self]) - 1)]
                              /\ priv' = [priv EXCEPT ![self] = Len(pstack'[self])]
                              /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 0]
                              /\ IF Len(pstack'[self]) >= PUB_MIN
                                    THEN /\ \/ /\ IF Len(ring'[self]) >= RING
                                                     THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                     ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                            \/ /\ pc' = [pc EXCEPT ![self] = "R_PopPub"]
                                    ELSE /\ IF Len(ring'[self]) >= RING
                                               THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                               ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                              /\ deque' = deque
                         ELSE /\ IF deque[self] # <<>>
                                    THEN /\ ring' = [ring EXCEPT ![self] = Append(ring[self], deque[self][Len(deque[self])])]
                                         /\ deque' = [deque EXCEPT ![self] = SubSeq(deque[self], 1, Len(deque[self]) - 1)]
                                         /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 0]
                                         /\ IF Len(ring'[self]) >= RING
                                               THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                               ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                    ELSE /\ tickets' = [tickets EXCEPT ![self] = tickets[self] + 1 - 0]
                                         /\ IF ring[self] = <<>>
                                               THEN /\ pc' = [pc EXCEPT ![self] = "R_Steal"]
                                               ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                         /\ UNCHANGED << deque, ring >>
                              /\ UNCHANGED << pstack, priv >>
                   /\ UNCHANGED << mark, scanned, budget, apool, word, dirty, 
                                   stop, share, uBudget, uAssist, stack, role, 
                                   pool, active, seen, stopping, kids, c, sw, 
                                   aw, giveups, half, k >>

R_Scan(self) == /\ pc[self] = "R_Scan"
                /\ LET e == Head(ring[self]) IN
                     /\ scanned' = [scanned EXCEPT ![e] = scanned[e] + 1]
                     /\ ring' = [ring EXCEPT ![self] = Tail(ring[self])]
                     /\ IF pool[self] = "budget"
                           THEN /\ uBudget' = uBudget + 1
                                /\ UNCHANGED uAssist
                           ELSE /\ uAssist' = uAssist + 1
                                /\ UNCHANGED uBudget
                     /\ IF Children(e) = {}
                           THEN /\ stopping' = [stopping EXCEPT ![self] = stop]
                                /\ IF JoinerSet # {}
                                      THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                      ELSE /\ IF stopping'[self]
                                                 THEN /\ IF ring'[self] = <<>>
                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                 ELSE /\ IF Len(ring'[self]) >= RING
                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                /\ UNCHANGED << mark, kids, c >>
                           ELSE /\ LET ch == Min((Children(e))) IN
                                     /\ kids' = [kids EXCEPT ![self] = (Children(e)) \ {ch}]
                                     /\ IF mark[ch]
                                           THEN /\ IF kids'[self] # {}
                                                      THEN /\ pc' = [pc EXCEPT ![self] = "R_Kids"]
                                                      ELSE /\ IF StopAllowed
                                                                 THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                                                 ELSE /\ IF JoinerSet # {}
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                                            ELSE /\ IF stopping[self]
                                                                                       THEN /\ IF ring'[self] = <<>>
                                                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                       ELSE /\ IF Len(ring'[self]) >= RING
                                                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                                /\ UNCHANGED << mark, c >>
                                           ELSE /\ c' = [c EXCEPT ![self] = ch]
                                                /\ IF MUTANT # "split_tas"
                                                      THEN /\ mark' = [mark EXCEPT ![ch] = TRUE]
                                                      ELSE /\ TRUE
                                                           /\ mark' = mark
                                                /\ pc' = [pc EXCEPT ![self] = "R_Push"]
                                /\ UNCHANGED stopping
                /\ UNCHANGED << deque, pstack, priv, budget, apool, word, 
                                dirty, stop, share, stack, role, pool, tickets, 
                                active, seen, sw, aw, giveups, half, k >>

R_Kids(self) == /\ pc[self] = "R_Kids"
                /\ LET ch == Min(kids[self]) IN
                     /\ kids' = [kids EXCEPT ![self] = kids[self] \ {ch}]
                     /\ IF mark[ch]
                           THEN /\ IF kids'[self] # {}
                                      THEN /\ pc' = [pc EXCEPT ![self] = "R_Kids"]
                                      ELSE /\ IF StopAllowed
                                                 THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                                 ELSE /\ IF JoinerSet # {}
                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                            ELSE /\ IF stopping[self]
                                                                       THEN /\ IF ring[self] = <<>>
                                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                       ELSE /\ IF Len(ring[self]) >= RING
                                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                /\ UNCHANGED << mark, c >>
                           ELSE /\ c' = [c EXCEPT ![self] = ch]
                                /\ IF MUTANT # "split_tas"
                                      THEN /\ mark' = [mark EXCEPT ![ch] = TRUE]
                                      ELSE /\ TRUE
                                           /\ mark' = mark
                                /\ pc' = [pc EXCEPT ![self] = "R_Push"]
                /\ UNCHANGED << deque, pstack, priv, scanned, budget, apool, 
                                word, dirty, stop, share, uBudget, uAssist, 
                                stack, role, pool, ring, tickets, active, seen, 
                                stopping, sw, aw, giveups, half, k >>

R_Push(self) == /\ pc[self] = "R_Push"
                /\ IF MUTANT = "split_tas"
                      THEN /\ mark' = [mark EXCEPT ![c[self]] = TRUE]
                      ELSE /\ TRUE
                           /\ mark' = mark
                /\ pstack' = [pstack EXCEPT ![self] = Append(pstack[self], c[self])]
                /\ priv' = [priv EXCEPT ![self] = Len(pstack'[self])]
                /\ c' = [c EXCEPT ![self] = 0]
                /\ IF Len(pstack'[self]) >= PUB_MIN
                      THEN /\ \/ /\ IF kids[self] # {}
                                       THEN /\ pc' = [pc EXCEPT ![self] = "R_Kids"]
                                       ELSE /\ IF StopAllowed
                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                                  ELSE /\ IF JoinerSet # {}
                                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                             ELSE /\ IF stopping[self]
                                                                        THEN /\ IF ring[self] = <<>>
                                                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                        ELSE /\ IF Len(ring[self]) >= RING
                                                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                              \/ /\ pc' = [pc EXCEPT ![self] = "R_PubHalf"]
                      ELSE /\ IF kids[self] # {}
                                 THEN /\ pc' = [pc EXCEPT ![self] = "R_Kids"]
                                 ELSE /\ IF StopAllowed
                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                            ELSE /\ IF JoinerSet # {}
                                                       THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                       ELSE /\ IF stopping[self]
                                                                  THEN /\ IF ring[self] = <<>>
                                                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                             ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                  ELSE /\ IF Len(ring[self]) >= RING
                                                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                             ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                /\ UNCHANGED << deque, scanned, budget, apool, word, dirty, 
                                stop, share, uBudget, uAssist, stack, role, 
                                pool, ring, tickets, active, seen, stopping, 
                                kids, sw, aw, giveups, half, k >>

R_PubHalf(self) == /\ pc[self] = "R_PubHalf"
                   /\ IF deque[self] = <<>>
                         THEN /\ half' = [half EXCEPT ![self] = Len(pstack[self]) \div 2 - 1]
                              /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                              /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                              /\ IF half'[self] > 0
                                    THEN /\ pc' = [pc EXCEPT ![self] = "R_PubHalfLoop"]
                                    ELSE /\ pc' = [pc EXCEPT ![self] = "R_PubHalfPriv"]
                         ELSE /\ IF kids[self] # {}
                                    THEN /\ pc' = [pc EXCEPT ![self] = "R_Kids"]
                                    ELSE /\ IF StopAllowed
                                               THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                               ELSE /\ IF JoinerSet # {}
                                                          THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                          ELSE /\ IF stopping[self]
                                                                     THEN /\ IF ring[self] = <<>>
                                                                                THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                     ELSE /\ IF Len(ring[self]) >= RING
                                                                                THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                              /\ UNCHANGED << deque, pstack, half >>
                   /\ UNCHANGED << priv, mark, scanned, budget, apool, word, 
                                   dirty, stop, share, uBudget, uAssist, stack, 
                                   role, pool, ring, tickets, active, seen, 
                                   stopping, kids, c, sw, aw, giveups, k >>

R_PubHalfLoop(self) == /\ pc[self] = "R_PubHalfLoop"
                       /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                       /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                       /\ half' = [half EXCEPT ![self] = half[self] - 1]
                       /\ IF half'[self] > 0
                             THEN /\ pc' = [pc EXCEPT ![self] = "R_PubHalfLoop"]
                             ELSE /\ pc' = [pc EXCEPT ![self] = "R_PubHalfPriv"]
                       /\ UNCHANGED << priv, mark, scanned, budget, apool, 
                                       word, dirty, stop, share, uBudget, 
                                       uAssist, stack, role, pool, ring, 
                                       tickets, active, seen, stopping, kids, 
                                       c, sw, aw, giveups, k >>

R_PubHalfPriv(self) == /\ pc[self] = "R_PubHalfPriv"
                       /\ priv' = [priv EXCEPT ![self] = Len(pstack[self])]
                       /\ IF kids[self] # {}
                             THEN /\ pc' = [pc EXCEPT ![self] = "R_Kids"]
                             ELSE /\ IF StopAllowed
                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                        ELSE /\ IF JoinerSet # {}
                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                   ELSE /\ IF stopping[self]
                                                              THEN /\ IF ring[self] = <<>>
                                                                         THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                         ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                              ELSE /\ IF Len(ring[self]) >= RING
                                                                         THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                         ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                       /\ UNCHANGED << deque, pstack, mark, scanned, budget, 
                                       apool, word, dirty, stop, share, 
                                       uBudget, uAssist, stack, role, pool, 
                                       ring, tickets, active, seen, stopping, 
                                       kids, c, sw, aw, giveups, half, k >>

R_PopPub(self) == /\ pc[self] = "R_PopPub"
                  /\ IF deque[self] = <<>>
                        THEN /\ half' = [half EXCEPT ![self] = Len(pstack[self]) \div 2 - 1]
                             /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                             /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                             /\ IF half'[self] > 0
                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_PopPubLoop"]
                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_PopPubPriv"]
                        ELSE /\ IF Len(ring[self]) >= RING
                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                             /\ UNCHANGED << deque, pstack, half >>
                  /\ UNCHANGED << priv, mark, scanned, budget, apool, word, 
                                  dirty, stop, share, uBudget, uAssist, stack, 
                                  role, pool, ring, tickets, active, seen, 
                                  stopping, kids, c, sw, aw, giveups, k >>

R_PopPubLoop(self) == /\ pc[self] = "R_PopPubLoop"
                      /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                      /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                      /\ half' = [half EXCEPT ![self] = half[self] - 1]
                      /\ IF half'[self] > 0
                            THEN /\ pc' = [pc EXCEPT ![self] = "R_PopPubLoop"]
                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_PopPubPriv"]
                      /\ UNCHANGED << priv, mark, scanned, budget, apool, word, 
                                      dirty, stop, share, uBudget, uAssist, 
                                      stack, role, pool, ring, tickets, active, 
                                      seen, stopping, kids, c, sw, aw, giveups, 
                                      k >>

R_PopPubPriv(self) == /\ pc[self] = "R_PopPubPriv"
                      /\ priv' = [priv EXCEPT ![self] = Len(pstack[self])]
                      /\ IF Len(ring[self]) >= RING
                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                      /\ UNCHANGED << deque, pstack, mark, scanned, budget, 
                                      apool, word, dirty, stop, share, uBudget, 
                                      uAssist, stack, role, pool, ring, 
                                      tickets, active, seen, stopping, kids, c, 
                                      sw, aw, giveups, half, k >>

R_Steal(self) == /\ pc[self] = "R_Steal"
                 /\ IF MUTANT = "steal_without_ticket"
                       THEN /\ \/ /\ \E v \in {x \in Slots \ {self} : deque[x] # <<>>}:
                                       /\ ring' = [ring EXCEPT ![self] = Append(ring[self], Head(deque[v]))]
                                       /\ deque' = [deque EXCEPT ![v] = Tail(deque[v])]
                                  /\ IF MUTANT = "steal_without_ticket"
                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_StealClaim"]
                                             /\ UNCHANGED tickets
                                        ELSE /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 0]
                                             /\ IF StopAllowed
                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                                   ELSE /\ IF JoinerSet # {}
                                                              THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                              ELSE /\ IF stopping[self]
                                                                         THEN /\ IF ring'[self] = <<>>
                                                                                    THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                    ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                         ELSE /\ IF Len(ring'[self]) >= RING
                                                                                    THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                    ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                  /\ UNCHANGED giveups
                               \/ /\ ~CapGiveUps \/ giveups[self] < MaxGiveUps
                                     \/ \A x \in Slots \ {self} : deque[x] = <<>>
                                  /\ IF CapGiveUps /\ \E x \in Slots \ {self} : deque[x] # <<>>
                                        THEN /\ giveups' = [giveups EXCEPT ![self] = giveups[self] + 1]
                                        ELSE /\ TRUE
                                             /\ UNCHANGED giveups
                                  /\ IF MUTANT # "steal_without_ticket"
                                        THEN /\ tickets' = [tickets EXCEPT ![self] = tickets[self] + 1 - 0]
                                        ELSE /\ TRUE
                                             /\ UNCHANGED tickets
                                  /\ IF role[self] = "Assist"
                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Idle"]
                                  /\ UNCHANGED <<deque, ring>>
                            /\ UNCHANGED << budget, apool >>
                       ELSE /\ IF tickets[self] > 0
                                  THEN /\ \/ /\ \E v \in {x \in Slots \ {self} : deque[x] # <<>>}:
                                                  /\ ring' = [ring EXCEPT ![self] = Append(ring[self], Head(deque[v]))]
                                                  /\ deque' = [deque EXCEPT ![v] = Tail(deque[v])]
                                             /\ IF MUTANT = "steal_without_ticket"
                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_StealClaim"]
                                                        /\ UNCHANGED tickets
                                                   ELSE /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 1]
                                                        /\ IF StopAllowed
                                                              THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                                              ELSE /\ IF JoinerSet # {}
                                                                         THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                                         ELSE /\ IF stopping[self]
                                                                                    THEN /\ IF ring'[self] = <<>>
                                                                                               THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                               ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                    ELSE /\ IF Len(ring'[self]) >= RING
                                                                                               THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                               ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                             /\ UNCHANGED giveups
                                          \/ /\ ~CapGiveUps \/ giveups[self] < MaxGiveUps
                                                \/ \A x \in Slots \ {self} : deque[x] = <<>>
                                             /\ IF CapGiveUps /\ \E x \in Slots \ {self} : deque[x] # <<>>
                                                   THEN /\ giveups' = [giveups EXCEPT ![self] = giveups[self] + 1]
                                                   ELSE /\ TRUE
                                                        /\ UNCHANGED giveups
                                             /\ IF MUTANT # "steal_without_ticket"
                                                   THEN /\ tickets' = [tickets EXCEPT ![self] = tickets[self] + 1 - 1]
                                                   ELSE /\ TRUE
                                                        /\ UNCHANGED tickets
                                             /\ IF role[self] = "Assist"
                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Idle"]
                                             /\ UNCHANGED <<deque, ring>>
                                       /\ UNCHANGED << budget, apool >>
                                  ELSE /\ IF PoolLeft(pool[self]) > 0
                                             THEN /\ IF pool[self] = "budget"
                                                        THEN /\ tickets' = [tickets EXCEPT ![self] = (IF budget < TB THEN budget ELSE TB) - 1]
                                                             /\ budget' = budget - (IF budget < TB THEN budget ELSE TB)
                                                             /\ apool' = apool
                                                        ELSE /\ tickets' = [tickets EXCEPT ![self] = (IF apool < TB THEN apool ELSE TB) - 1]
                                                             /\ apool' = apool - (IF apool < TB THEN apool ELSE TB)
                                                             /\ UNCHANGED budget
                                                  /\ pc' = [pc EXCEPT ![self] = "R_StealTry"]
                                             ELSE /\ IF role[self] = "Assist"
                                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Idle"]
                                                  /\ UNCHANGED << budget, 
                                                                  apool, 
                                                                  tickets >>
                                       /\ UNCHANGED << deque, ring, giveups >>
                 /\ UNCHANGED << pstack, priv, mark, scanned, word, dirty, 
                                 stop, share, uBudget, uAssist, stack, role, 
                                 pool, active, seen, stopping, kids, c, sw, aw, 
                                 half, k >>

R_StealTry(self) == /\ pc[self] = "R_StealTry"
                    /\ \/ /\ \E v \in {x \in Slots \ {self} : deque[x] # <<>>}:
                               /\ ring' = [ring EXCEPT ![self] = Append(ring[self], Head(deque[v]))]
                               /\ deque' = [deque EXCEPT ![v] = Tail(deque[v])]
                          /\ IF MUTANT = "steal_without_ticket"
                                THEN /\ pc' = [pc EXCEPT ![self] = "R_StealClaim"]
                                     /\ UNCHANGED tickets
                                ELSE /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 0]
                                     /\ IF StopAllowed
                                           THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                           ELSE /\ IF JoinerSet # {}
                                                      THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                      ELSE /\ IF stopping[self]
                                                                 THEN /\ IF ring'[self] = <<>>
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                 ELSE /\ IF Len(ring'[self]) >= RING
                                                                            THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                            ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                          /\ UNCHANGED giveups
                       \/ /\ ~CapGiveUps \/ giveups[self] < MaxGiveUps
                             \/ \A x \in Slots \ {self} : deque[x] = <<>>
                          /\ IF CapGiveUps /\ \E x \in Slots \ {self} : deque[x] # <<>>
                                THEN /\ giveups' = [giveups EXCEPT ![self] = giveups[self] + 1]
                                ELSE /\ TRUE
                                     /\ UNCHANGED giveups
                          /\ IF MUTANT # "steal_without_ticket"
                                THEN /\ tickets' = [tickets EXCEPT ![self] = tickets[self] + 1 - 0]
                                ELSE /\ TRUE
                                     /\ UNCHANGED tickets
                          /\ IF role[self] = "Assist"
                                THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                ELSE /\ pc' = [pc EXCEPT ![self] = "R_Idle"]
                          /\ UNCHANGED <<deque, ring>>
                    /\ UNCHANGED << pstack, priv, mark, scanned, budget, apool, 
                                    word, dirty, stop, share, uBudget, uAssist, 
                                    stack, role, pool, active, seen, stopping, 
                                    kids, c, sw, aw, half, k >>

R_StealClaim(self) == /\ pc[self] = "R_StealClaim"
                      /\ IF tickets[self] > 0
                            THEN /\ tickets' = [tickets EXCEPT ![self] = tickets[self] - 1]
                                 /\ IF StopAllowed
                                       THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                       ELSE /\ IF JoinerSet # {}
                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                  ELSE /\ IF stopping[self]
                                                             THEN /\ IF ring[self] = <<>>
                                                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                             ELSE /\ IF Len(ring[self]) >= RING
                                                                        THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                 /\ UNCHANGED << budget, apool >>
                            ELSE /\ IF PoolLeft(pool[self]) > 0
                                       THEN /\ IF pool[self] = "budget"
                                                  THEN /\ tickets' = [tickets EXCEPT ![self] = (IF budget < TB THEN budget ELSE TB) - 1]
                                                       /\ budget' = budget - (IF budget < TB THEN budget ELSE TB)
                                                       /\ apool' = apool
                                                  ELSE /\ tickets' = [tickets EXCEPT ![self] = (IF apool < TB THEN apool ELSE TB) - 1]
                                                       /\ apool' = apool - (IF apool < TB THEN apool ELSE TB)
                                                       /\ UNCHANGED budget
                                            /\ IF StopAllowed
                                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                                  ELSE /\ IF JoinerSet # {}
                                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                                             ELSE /\ IF stopping[self]
                                                                        THEN /\ IF ring[self] = <<>>
                                                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                        ELSE /\ IF Len(ring[self]) >= RING
                                                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                                       ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                            /\ UNCHANGED << budget, apool, 
                                                            tickets >>
                      /\ UNCHANGED << deque, pstack, priv, mark, scanned, word, 
                                      dirty, stop, share, uBudget, uAssist, 
                                      stack, role, pool, ring, active, seen, 
                                      stopping, kids, c, sw, aw, giveups, half, 
                                      k >>

R_Idle(self) == /\ pc[self] = "R_Idle"
                /\ IF IdleBeforePublish
                      THEN /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                 THEN /\ budget' = budget + tickets[self]
                                      /\ apool' = apool
                                 ELSE /\ apool' = apool + tickets[self]
                                      /\ UNCHANGED budget
                           /\ tickets' = [tickets EXCEPT ![self] = 0]
                           /\ pc' = [pc EXCEPT ![self] = "R_Idle2"]
                           /\ UNCHANGED << deque, pstack, word, stack, active >>
                      ELSE /\ IF CanPublish(self)
                                 THEN /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                                      /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                                      /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                               pc        |->  "R_Idle2" ] >>
                                                                           \o stack[self]]
                                      /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                      /\ UNCHANGED << budget, apool, word, 
                                                      tickets, active >>
                                 ELSE /\ IF MUTANT = "return_after_idle"
                                            THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                                       THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                                       ELSE /\ TRUE
                                                            /\ word' = word
                                                 /\ active' = [active EXCEPT ![self] = FALSE]
                                                 /\ pc' = [pc EXCEPT ![self] = "R_Idle3"]
                                                 /\ UNCHANGED << budget, apool, 
                                                                 tickets >>
                                            ELSE /\ IF tickets[self] # 0
                                                       THEN /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                                                  THEN /\ budget' = budget + tickets[self]
                                                                       /\ apool' = apool
                                                                  ELSE /\ apool' = apool + tickets[self]
                                                                       /\ UNCHANGED budget
                                                            /\ tickets' = [tickets EXCEPT ![self] = 0]
                                                            /\ pc' = [pc EXCEPT ![self] = "R_Idle3"]
                                                            /\ UNCHANGED << word, 
                                                                            active >>
                                                       ELSE /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                                                  THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                                                  ELSE /\ TRUE
                                                                       /\ word' = word
                                                            /\ active' = [active EXCEPT ![self] = FALSE]
                                                            /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                                                            /\ UNCHANGED << budget, 
                                                                            apool, 
                                                                            tickets >>
                                      /\ UNCHANGED << deque, pstack, stack >>
                /\ UNCHANGED << priv, mark, scanned, dirty, stop, share, 
                                uBudget, uAssist, role, pool, ring, seen, 
                                stopping, kids, c, sw, aw, giveups, half, k >>

R_Idle2(self) == /\ pc[self] = "R_Idle2"
                 /\ IF IdleBeforePublish
                       THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                  THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                  ELSE /\ TRUE
                                       /\ word' = word
                            /\ active' = [active EXCEPT ![self] = FALSE]
                            /\ IF CanPublish(self)
                                  THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                                pc        |->  "R_Idle3" ] >>
                                                                            \o stack[self]]
                                       /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_Idle3"]
                                       /\ stack' = stack
                            /\ UNCHANGED << budget, apool, tickets >>
                       ELSE /\ IF MUTANT = "return_after_idle"
                                  THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                             THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                             ELSE /\ TRUE
                                                  /\ word' = word
                                       /\ active' = [active EXCEPT ![self] = FALSE]
                                       /\ pc' = [pc EXCEPT ![self] = "R_Idle3"]
                                       /\ UNCHANGED << budget, apool, tickets >>
                                  ELSE /\ IF tickets[self] # 0
                                             THEN /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                                        THEN /\ budget' = budget + tickets[self]
                                                             /\ apool' = apool
                                                        ELSE /\ apool' = apool + tickets[self]
                                                             /\ UNCHANGED budget
                                                  /\ tickets' = [tickets EXCEPT ![self] = 0]
                                                  /\ pc' = [pc EXCEPT ![self] = "R_Idle3"]
                                                  /\ UNCHANGED << word, active >>
                                             ELSE /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                                        THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                                        ELSE /\ TRUE
                                                             /\ word' = word
                                                  /\ active' = [active EXCEPT ![self] = FALSE]
                                                  /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                                                  /\ UNCHANGED << budget, 
                                                                  apool, 
                                                                  tickets >>
                            /\ stack' = stack
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, dirty, 
                                 stop, share, uBudget, uAssist, role, pool, 
                                 ring, seen, stopping, kids, c, sw, aw, 
                                 giveups, half, k >>

R_Idle3(self) == /\ pc[self] = "R_Idle3"
                 /\ IF active[self]
                       THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                  THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                  ELSE /\ TRUE
                                       /\ word' = word
                            /\ active' = [active EXCEPT ![self] = FALSE]
                            /\ UNCHANGED << budget, apool, tickets >>
                       ELSE /\ IF MUTANT = "return_after_idle"
                                  THEN /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                             THEN /\ budget' = budget + tickets[self]
                                                  /\ apool' = apool
                                             ELSE /\ apool' = apool + tickets[self]
                                                  /\ UNCHANGED budget
                                       /\ tickets' = [tickets EXCEPT ![self] = 0]
                                  ELSE /\ TRUE
                                       /\ UNCHANGED << budget, apool, tickets >>
                            /\ UNCHANGED << word, active >>
                 /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, dirty, 
                                 stop, share, uBudget, uAssist, stack, role, 
                                 pool, ring, seen, stopping, kids, c, sw, aw, 
                                 giveups, half, k >>

I_Load(self) == /\ pc[self] = "I_Load"
                /\ IF word.done
                      THEN /\ IF pstack[self] = <<>> /\ tickets[self] = 0
                                 THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                      /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                      /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                      /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                      /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                      /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                      /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                      /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                      /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                      /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                      /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                      /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                      /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "R_ExitIdle"]
                                      /\ UNCHANGED << stack, role, pool, ring, 
                                                      tickets, active, seen, 
                                                      stopping, kids, c, sw, 
                                                      aw, giveups, half >>
                      ELSE /\ sw' = [sw EXCEPT ![self] = Saved(word)]
                           /\ IF ~StopAllowed
                                 THEN /\ IF BudgetNeverEmpty
                                            THEN /\ aw' = [aw EXCEPT ![self] = AnyWorkRange]
                                                 /\ pc' = [pc EXCEPT ![self] = "I_Scan1"]
                                            ELSE /\ pc' = [pc EXCEPT ![self] = "I_Budget1"]
                                                 /\ aw' = aw
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "I_Stop"]
                                      /\ aw' = aw
                           /\ UNCHANGED << stack, role, pool, ring, tickets, 
                                           active, seen, stopping, kids, c, 
                                           giveups, half >>
                /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                apool, word, dirty, stop, share, uBudget, 
                                uAssist, k >>

I_Stop(self) == /\ pc[self] = "I_Stop"
                /\ IF stop
                      THEN /\ IF MUTANT = "stop_sets_done"
                                 THEN /\ word' = [word EXCEPT !.done = TRUE]
                                 ELSE /\ TRUE
                                      /\ word' = word
                           /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                           /\ IF pstack[self] = <<>> /\ tickets[self] = 0
                                 THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                      /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                      /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                      /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                      /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                      /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                      /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                      /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                      /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                      /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                      /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                      /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                      /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "R_ExitIdle"]
                                      /\ UNCHANGED << stack, role, pool, ring, 
                                                      tickets, active, seen, 
                                                      stopping, kids, c, sw, 
                                                      aw, giveups, half >>
                      ELSE /\ IF BudgetNeverEmpty
                                 THEN /\ aw' = [aw EXCEPT ![self] = AnyWorkRange]
                                      /\ pc' = [pc EXCEPT ![self] = "I_Scan1"]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "I_Budget1"]
                                      /\ aw' = aw
                           /\ UNCHANGED << word, dirty, stack, role, pool, 
                                           ring, tickets, active, seen, 
                                           stopping, kids, c, sw, giveups, 
                                           half >>
                /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                apool, stop, share, uBudget, uAssist, k >>

I_Budget1(self) == /\ pc[self] = "I_Budget1"
                   /\ IF budget > 0
                         THEN /\ aw' = [aw EXCEPT ![self] = AnyWorkRange]
                              /\ pc' = [pc EXCEPT ![self] = "I_Scan1"]
                              /\ UNCHANGED << dirty, sw >>
                         ELSE /\ IF sw[self].active # 0
                                    THEN /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                                         /\ sw' = [sw EXCEPT ![self] = NullWord]
                                         /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                                    ELSE /\ IF MUTANT = "idle_before_publish_onescan"
                                               THEN /\ pc' = [pc EXCEPT ![self] = "I_Decide"]
                                               ELSE /\ pc' = [pc EXCEPT ![self] = "I_Budget2"]
                                         /\ UNCHANGED << dirty, sw >>
                              /\ aw' = aw
                   /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                   apool, word, stop, share, uBudget, uAssist, 
                                   stack, role, pool, ring, tickets, active, 
                                   seen, stopping, kids, c, giveups, half, k >>

I_Scan1(self) == /\ pc[self] = "I_Scan1"
                 /\ LET x == Min(aw[self]) IN
                      IF deque[x] # <<>> \/ (x = self /\ OwnPriv(self))
                         THEN /\ aw' = [aw EXCEPT ![self] = {}]
                              /\ pc' = [pc EXCEPT ![self] = "I_React"]
                              /\ UNCHANGED << dirty, sw >>
                         ELSE /\ IF AnyWorkCountsPriv /\ x # self
                                    THEN /\ pc' = [pc EXCEPT ![self] = "I_Priv1"]
                                         /\ UNCHANGED << dirty, sw, aw >>
                                    ELSE /\ IF aw[self] # {x}
                                               THEN /\ aw' = [aw EXCEPT ![self] = aw[self] \ {x}]
                                                    /\ pc' = [pc EXCEPT ![self] = "I_Scan1"]
                                                    /\ UNCHANGED << dirty, sw >>
                                               ELSE /\ IF sw[self].active # 0
                                                          THEN /\ aw' = [aw EXCEPT ![self] = {}]
                                                               /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                                                               /\ sw' = [sw EXCEPT ![self] = NullWord]
                                                               /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                                                          ELSE /\ IF MUTANT = "idle_before_publish_onescan"
                                                                     THEN /\ aw' = [aw EXCEPT ![self] = {}]
                                                                          /\ pc' = [pc EXCEPT ![self] = "I_Decide"]
                                                                     ELSE /\ IF BudgetNeverEmpty
                                                                                THEN /\ aw' = [aw EXCEPT ![self] = AnyWorkRange]
                                                                                     /\ pc' = [pc EXCEPT ![self] = "I_Scan2"]
                                                                                ELSE /\ aw' = [aw EXCEPT ![self] = {}]
                                                                                     /\ pc' = [pc EXCEPT ![self] = "I_Budget2"]
                                                               /\ UNCHANGED << dirty, 
                                                                               sw >>
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, word, stop, share, uBudget, uAssist, 
                                 stack, role, pool, ring, tickets, active, 
                                 seen, stopping, kids, c, giveups, half, k >>

I_Priv1(self) == /\ pc[self] = "I_Priv1"
                 /\ LET x == Min(aw[self]) IN
                      IF priv[x] # 0
                         THEN /\ aw' = [aw EXCEPT ![self] = {}]
                              /\ pc' = [pc EXCEPT ![self] = "I_React"]
                              /\ UNCHANGED << dirty, sw >>
                         ELSE /\ IF aw[self] # {x}
                                    THEN /\ aw' = [aw EXCEPT ![self] = aw[self] \ {x}]
                                         /\ pc' = [pc EXCEPT ![self] = "I_Scan1"]
                                         /\ UNCHANGED << dirty, sw >>
                                    ELSE /\ IF sw[self].active # 0
                                               THEN /\ aw' = [aw EXCEPT ![self] = {}]
                                                    /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                                                    /\ sw' = [sw EXCEPT ![self] = NullWord]
                                                    /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                                               ELSE /\ IF MUTANT = "idle_before_publish_onescan"
                                                          THEN /\ aw' = [aw EXCEPT ![self] = {}]
                                                               /\ pc' = [pc EXCEPT ![self] = "I_Decide"]
                                                          ELSE /\ IF BudgetNeverEmpty
                                                                     THEN /\ aw' = [aw EXCEPT ![self] = AnyWorkRange]
                                                                          /\ pc' = [pc EXCEPT ![self] = "I_Scan2"]
                                                                     ELSE /\ aw' = [aw EXCEPT ![self] = {}]
                                                                          /\ pc' = [pc EXCEPT ![self] = "I_Budget2"]
                                                    /\ UNCHANGED << dirty, sw >>
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, word, stop, share, uBudget, uAssist, 
                                 stack, role, pool, ring, tickets, active, 
                                 seen, stopping, kids, c, giveups, half, k >>

I_React(self) == /\ pc[self] = "I_React"
                 /\ IF word.done
                       THEN /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                            /\ IF pstack[self] = <<>> /\ tickets[self] = 0
                                  THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                       /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                       /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                       /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                       /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                       /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                       /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                       /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                       /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                       /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                       /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                       /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                       /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                       /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                       /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "R_ExitIdle"]
                                       /\ UNCHANGED << stack, role, pool, ring, 
                                                       tickets, active, seen, 
                                                       stopping, kids, c, sw, 
                                                       aw, giveups, half >>
                            /\ word' = word
                       ELSE /\ word' = [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)]
                            /\ dirty' = Bump(self)
                            /\ active' = [active EXCEPT ![self] = TRUE]
                            /\ sw' = [sw EXCEPT ![self] = NullWord]
                            /\ IF StopAllowed
                                  THEN /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                                  ELSE /\ IF JoinerSet # {}
                                             THEN /\ pc' = [pc EXCEPT ![self] = "R_Share"]
                                             ELSE /\ IF stopping[self]
                                                        THEN /\ IF ring[self] = <<>>
                                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_ExitActive"]
                                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                        ELSE /\ IF Len(ring[self]) >= RING
                                                                   THEN /\ pc' = [pc EXCEPT ![self] = "R_Scan"]
                                                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_Fill"]
                            /\ UNCHANGED << stack, role, pool, ring, tickets, 
                                            seen, stopping, kids, c, aw, 
                                            giveups, half >>
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, stop, share, uBudget, uAssist, k >>

I_Budget2(self) == /\ pc[self] = "I_Budget2"
                   /\ IF budget > 0
                         THEN /\ aw' = [aw EXCEPT ![self] = AnyWorkRange]
                              /\ pc' = [pc EXCEPT ![self] = "I_Scan2"]
                         ELSE /\ pc' = [pc EXCEPT ![self] = "I_Decide"]
                              /\ aw' = aw
                   /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                   apool, word, dirty, stop, share, uBudget, 
                                   uAssist, stack, role, pool, ring, tickets, 
                                   active, seen, stopping, kids, c, sw, 
                                   giveups, half, k >>

I_Scan2(self) == /\ pc[self] = "I_Scan2"
                 /\ LET x == Min(aw[self]) IN
                      IF deque[x] # <<>> \/ (x = self /\ OwnPriv(self))
                         THEN /\ aw' = [aw EXCEPT ![self] = {}]
                              /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                              /\ sw' = [sw EXCEPT ![self] = NullWord]
                              /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                         ELSE /\ IF AnyWorkCountsPriv /\ x # self
                                    THEN /\ pc' = [pc EXCEPT ![self] = "I_Priv2"]
                                         /\ aw' = aw
                                    ELSE /\ IF aw[self] # {x}
                                               THEN /\ aw' = [aw EXCEPT ![self] = aw[self] \ {x}]
                                                    /\ pc' = [pc EXCEPT ![self] = "I_Scan2"]
                                               ELSE /\ aw' = [aw EXCEPT ![self] = {}]
                                                    /\ pc' = [pc EXCEPT ![self] = "I_Decide"]
                              /\ UNCHANGED << dirty, sw >>
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, word, stop, share, uBudget, uAssist, 
                                 stack, role, pool, ring, tickets, active, 
                                 seen, stopping, kids, c, giveups, half, k >>

I_Priv2(self) == /\ pc[self] = "I_Priv2"
                 /\ LET x == Min(aw[self]) IN
                      IF priv[x] # 0
                         THEN /\ aw' = [aw EXCEPT ![self] = {}]
                              /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                              /\ sw' = [sw EXCEPT ![self] = NullWord]
                              /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                         ELSE /\ IF aw[self] # {x}
                                    THEN /\ aw' = [aw EXCEPT ![self] = aw[self] \ {x}]
                                         /\ pc' = [pc EXCEPT ![self] = "I_Scan2"]
                                    ELSE /\ aw' = [aw EXCEPT ![self] = {}]
                                         /\ pc' = [pc EXCEPT ![self] = "I_Decide"]
                              /\ UNCHANGED << dirty, sw >>
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, word, stop, share, uBudget, uAssist, 
                                 stack, role, pool, ring, tickets, active, 
                                 seen, stopping, kids, c, giveups, half, k >>

I_Decide(self) == /\ pc[self] = "I_Decide"
                  /\ IF MUTANT = "two_word"
                        \/ (MUTANT # "never_decide" /\ Saved(word) = sw[self] /\ ~dirty[self])
                        THEN /\ word' = [word EXCEPT !.done = TRUE]
                             /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                             /\ IF pstack[self] = <<>> /\ tickets[self] = 0
                                   THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                        /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                        /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                        /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                        /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                        /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                        /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                        /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                        /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                        /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                        /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                        /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                        /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                        /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                        /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                   ELSE /\ pc' = [pc EXCEPT ![self] = "R_ExitIdle"]
                                        /\ UNCHANGED << stack, role, pool, 
                                                        ring, tickets, active, 
                                                        seen, stopping, kids, 
                                                        c, sw, aw, giveups, 
                                                        half >>
                        ELSE /\ dirty' = [dirty EXCEPT ![self] = FALSE]
                             /\ sw' = [sw EXCEPT ![self] = NullWord]
                             /\ pc' = [pc EXCEPT ![self] = "I_Load"]
                             /\ UNCHANGED << word, stack, role, pool, ring, 
                                             tickets, active, seen, stopping, 
                                             kids, c, aw, giveups, half >>
                  /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                  apool, stop, share, uBudget, uAssist, k >>

R_ExitActive(self) == /\ pc[self] = "R_ExitActive"
                      /\ IF IdleBeforePublish
                            THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                       THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                       ELSE /\ TRUE
                                            /\ word' = word
                                 /\ IF CanPublish(self)
                                       THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                                     pc        |->  "R_ExitActive2" ] >>
                                                                                 \o stack[self]]
                                            /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                       ELSE /\ pc' = [pc EXCEPT ![self] = "R_ExitActive2"]
                                            /\ stack' = stack
                                 /\ UNCHANGED << deque, pstack, budget, apool, 
                                                 role, pool, ring, tickets, 
                                                 active, seen, stopping, kids, 
                                                 c, sw, aw, giveups, half >>
                            ELSE /\ IF CanPublish(self)
                                       THEN /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                                            /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                                            /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                                     pc        |->  "R_ExitActive2" ] >>
                                                                                 \o stack[self]]
                                            /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                                            /\ UNCHANGED << budget, apool, 
                                                            word, role, pool, 
                                                            ring, tickets, 
                                                            active, seen, 
                                                            stopping, kids, c, 
                                                            sw, aw, giveups, 
                                                            half >>
                                       ELSE /\ IF tickets[self] # 0
                                                  THEN /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                                             THEN /\ budget' = budget + tickets[self]
                                                                  /\ apool' = apool
                                                             ELSE /\ apool' = apool + tickets[self]
                                                                  /\ UNCHANGED budget
                                                       /\ tickets' = [tickets EXCEPT ![self] = 0]
                                                       /\ pc' = [pc EXCEPT ![self] = "R_ExitActive3"]
                                                       /\ UNCHANGED << word, 
                                                                       stack, 
                                                                       role, 
                                                                       pool, 
                                                                       ring, 
                                                                       active, 
                                                                       seen, 
                                                                       stopping, 
                                                                       kids, c, 
                                                                       sw, aw, 
                                                                       giveups, 
                                                                       half >>
                                                  ELSE /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                                             THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                                             ELSE /\ TRUE
                                                                  /\ word' = word
                                                       /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                                       /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                                       /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                                       /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                                       /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                                       /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                                       /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                                       /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                                       /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                                       /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                                       /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                                       /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                                       /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                                       /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                                       /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                                       /\ UNCHANGED << budget, 
                                                                       apool >>
                                            /\ UNCHANGED << deque, pstack >>
                      /\ UNCHANGED << priv, mark, scanned, dirty, stop, share, 
                                      uBudget, uAssist, k >>

R_ExitActive2(self) == /\ pc[self] = "R_ExitActive2"
                       /\ IF ~IdleBeforePublish /\ tickets[self] = 0
                             THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                        THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                        ELSE /\ TRUE
                                             /\ word' = word
                                  /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                  /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                  /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                  /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                  /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                  /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                  /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                  /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                  /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                  /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                  /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                  /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                  /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                  /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                  /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                  /\ UNCHANGED << budget, apool >>
                             ELSE /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                        THEN /\ budget' = budget + tickets[self]
                                             /\ apool' = apool
                                        ELSE /\ apool' = apool + tickets[self]
                                             /\ UNCHANGED budget
                                  /\ tickets' = [tickets EXCEPT ![self] = 0]
                                  /\ pc' = [pc EXCEPT ![self] = "R_ExitActive3"]
                                  /\ UNCHANGED << word, stack, role, pool, 
                                                  ring, active, seen, stopping, 
                                                  kids, c, sw, aw, giveups, 
                                                  half >>
                       /\ UNCHANGED << deque, pstack, priv, mark, scanned, 
                                       dirty, stop, share, uBudget, uAssist, k >>

R_ExitActive3(self) == /\ pc[self] = "R_ExitActive3"
                       /\ IF ~IdleBeforePublish
                             THEN /\ IF MUTANT # "joiner_invisible" \/ role[self] # "Assist"
                                        THEN /\ word' = [word EXCEPT !.active = @ - 1]
                                        ELSE /\ TRUE
                                             /\ word' = word
                             ELSE /\ TRUE
                                  /\ word' = word
                       /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                       /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                       /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                       /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                       /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                       /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                       /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                       /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                       /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                       /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                       /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                       /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                       /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                       /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                       /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                       /\ UNCHANGED << deque, pstack, priv, mark, scanned, 
                                       budget, apool, dirty, stop, share, 
                                       uBudget, uAssist, k >>

R_ExitIdle(self) == /\ pc[self] = "R_ExitIdle"
                    /\ sw' = [sw EXCEPT ![self] = NullWord]
                    /\ IF CanPublish(self)
                          THEN /\ deque' = [deque EXCEPT ![self] = Append(deque[self], Head(pstack[self]))]
                               /\ pstack' = [pstack EXCEPT ![self] = Tail(pstack[self])]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "PublishAll",
                                                                        pc        |->  "R_ExitIdle2" ] >>
                                                                    \o stack[self]]
                               /\ pc' = [pc EXCEPT ![self] = "PA_Loop"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "R_ExitIdle2"]
                               /\ UNCHANGED << deque, pstack, stack >>
                    /\ UNCHANGED << priv, mark, scanned, budget, apool, word, 
                                    dirty, stop, share, uBudget, uAssist, role, 
                                    pool, ring, tickets, active, seen, 
                                    stopping, kids, c, aw, giveups, half, k >>

R_ExitIdle2(self) == /\ pc[self] = "R_ExitIdle2"
                     /\ IF tickets[self] # 0
                           THEN /\ IF pool[self] = "budget" \/ MUTANT = "assist_returns_to_budget"
                                      THEN /\ budget' = budget + tickets[self]
                                           /\ apool' = apool
                                      ELSE /\ apool' = apool + tickets[self]
                                           /\ UNCHANGED budget
                                /\ tickets' = [tickets EXCEPT ![self] = 0]
                                /\ pc' = [pc EXCEPT ![self] = "R_ExitIdle3"]
                                /\ UNCHANGED << stack, role, pool, ring, 
                                                active, seen, stopping, kids, 
                                                c, sw, aw, giveups, half >>
                           ELSE /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                                /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                                /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                                /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                                /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                                /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                                /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                                /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                                /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                                /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                                /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                                /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                                /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                /\ UNCHANGED << budget, apool >>
                     /\ UNCHANGED << deque, pstack, priv, mark, scanned, word, 
                                     dirty, stop, share, uBudget, uAssist, k >>

R_ExitIdle3(self) == /\ pc[self] = "R_ExitIdle3"
                     /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                     /\ ring' = [ring EXCEPT ![self] = Head(stack[self]).ring]
                     /\ tickets' = [tickets EXCEPT ![self] = Head(stack[self]).tickets]
                     /\ active' = [active EXCEPT ![self] = Head(stack[self]).active]
                     /\ seen' = [seen EXCEPT ![self] = Head(stack[self]).seen]
                     /\ stopping' = [stopping EXCEPT ![self] = Head(stack[self]).stopping]
                     /\ kids' = [kids EXCEPT ![self] = Head(stack[self]).kids]
                     /\ c' = [c EXCEPT ![self] = Head(stack[self]).c]
                     /\ sw' = [sw EXCEPT ![self] = Head(stack[self]).sw]
                     /\ aw' = [aw EXCEPT ![self] = Head(stack[self]).aw]
                     /\ giveups' = [giveups EXCEPT ![self] = Head(stack[self]).giveups]
                     /\ half' = [half EXCEPT ![self] = Head(stack[self]).half]
                     /\ role' = [role EXCEPT ![self] = Head(stack[self]).role]
                     /\ pool' = [pool EXCEPT ![self] = Head(stack[self]).pool]
                     /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                     /\ UNCHANGED << deque, pstack, priv, mark, scanned, 
                                     budget, apool, word, dirty, stop, share, 
                                     uBudget, uAssist, k >>

Run(self) == R_Top(self) \/ R_Share(self) \/ R_Fill(self)
                \/ R_TakeOwn(self) \/ R_Scan(self) \/ R_Kids(self)
                \/ R_Push(self) \/ R_PubHalf(self) \/ R_PubHalfLoop(self)
                \/ R_PubHalfPriv(self) \/ R_PopPub(self)
                \/ R_PopPubLoop(self) \/ R_PopPubPriv(self)
                \/ R_Steal(self) \/ R_StealTry(self) \/ R_StealClaim(self)
                \/ R_Idle(self) \/ R_Idle2(self) \/ R_Idle3(self)
                \/ I_Load(self) \/ I_Stop(self) \/ I_Budget1(self)
                \/ I_Scan1(self) \/ I_Priv1(self) \/ I_React(self)
                \/ I_Budget2(self) \/ I_Scan2(self) \/ I_Priv2(self)
                \/ I_Decide(self) \/ R_ExitActive(self)
                \/ R_ExitActive2(self) \/ R_ExitActive3(self)
                \/ R_ExitIdle(self) \/ R_ExitIdle2(self)
                \/ R_ExitIdle3(self)

M_Run(self) == /\ pc[self] = "M_Run"
               /\ /\ pool' = [pool EXCEPT ![self] = "budget"]
                  /\ role' = [role EXCEPT ![self] = "Member"]
                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Run",
                                                           pc        |->  "Done",
                                                           ring      |->  ring[self],
                                                           tickets   |->  tickets[self],
                                                           active    |->  active[self],
                                                           seen      |->  seen[self],
                                                           stopping  |->  stopping[self],
                                                           kids      |->  kids[self],
                                                           c         |->  c[self],
                                                           sw        |->  sw[self],
                                                           aw        |->  aw[self],
                                                           giveups   |->  giveups[self],
                                                           half      |->  half[self],
                                                           role      |->  role[self],
                                                           pool      |->  pool[self] ] >>
                                                       \o stack[self]]
               /\ ring' = [ring EXCEPT ![self] = <<>>]
               /\ tickets' = [tickets EXCEPT ![self] = 0]
               /\ active' = [active EXCEPT ![self] = TRUE]
               /\ seen' = [seen EXCEPT ![self] = 0]
               /\ stopping' = [stopping EXCEPT ![self] = FALSE]
               /\ kids' = [kids EXCEPT ![self] = {}]
               /\ c' = [c EXCEPT ![self] = 0]
               /\ sw' = [sw EXCEPT ![self] = NullWord]
               /\ aw' = [aw EXCEPT ![self] = {}]
               /\ giveups' = [giveups EXCEPT ![self] = 0]
               /\ half' = [half EXCEPT ![self] = 0]
               /\ pc' = [pc EXCEPT ![self] = "R_Top"]
               /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                               apool, word, dirty, stop, share, uBudget, 
                               uAssist, k >>

Member(self) == M_Run(self)

J_Start(self) == /\ pc[self] = "J_Start"
                 /\ share' = share + 1
                 /\ IF AssistRuns > 0
                       THEN /\ apool' = AssistBudget
                            /\ pc' = [pc EXCEPT ![self] = "J_AJoin"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "J_CJoin"]
                            /\ apool' = apool
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 word, dirty, stop, uBudget, uAssist, stack, 
                                 role, pool, ring, tickets, active, seen, 
                                 stopping, kids, c, sw, aw, giveups, half, k >>

J_AJoin(self) == /\ pc[self] = "J_AJoin"
                 /\ IF MUTANT \in {"joiner_no_reactivate", "joiner_invisible"}
                       THEN /\ /\ pool' = [pool EXCEPT ![self] = "assist"]
                               /\ role' = [role EXCEPT ![self] = "Assist"]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Run",
                                                                        pc        |->  "J_AssistCheck",
                                                                        ring      |->  ring[self],
                                                                        tickets   |->  tickets[self],
                                                                        active    |->  active[self],
                                                                        seen      |->  seen[self],
                                                                        stopping  |->  stopping[self],
                                                                        kids      |->  kids[self],
                                                                        c         |->  c[self],
                                                                        sw        |->  sw[self],
                                                                        aw        |->  aw[self],
                                                                        giveups   |->  giveups[self],
                                                                        half      |->  half[self],
                                                                        role      |->  role[self],
                                                                        pool      |->  pool[self] ] >>
                                                                    \o stack[self]]
                            /\ ring' = [ring EXCEPT ![self] = <<>>]
                            /\ tickets' = [tickets EXCEPT ![self] = 0]
                            /\ active' = [active EXCEPT ![self] = TRUE]
                            /\ seen' = [seen EXCEPT ![self] = 0]
                            /\ stopping' = [stopping EXCEPT ![self] = FALSE]
                            /\ kids' = [kids EXCEPT ![self] = {}]
                            /\ c' = [c EXCEPT ![self] = 0]
                            /\ sw' = [sw EXCEPT ![self] = NullWord]
                            /\ aw' = [aw EXCEPT ![self] = {}]
                            /\ giveups' = [giveups EXCEPT ![self] = 0]
                            /\ half' = [half EXCEPT ![self] = 0]
                            /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                            /\ UNCHANGED << word, dirty >>
                       ELSE /\ IF word.done
                                  THEN /\ pc' = [pc EXCEPT ![self] = "J_AssistCheck"]
                                       /\ UNCHANGED << word, dirty, stack, 
                                                       role, pool, ring, 
                                                       tickets, active, seen, 
                                                       stopping, kids, c, sw, 
                                                       aw, giveups, half >>
                                  ELSE /\ word' = [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)]
                                       /\ dirty' = Bump(self)
                                       /\ /\ pool' = [pool EXCEPT ![self] = "assist"]
                                          /\ role' = [role EXCEPT ![self] = "Assist"]
                                          /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Run",
                                                                                   pc        |->  "J_AssistCheck",
                                                                                   ring      |->  ring[self],
                                                                                   tickets   |->  tickets[self],
                                                                                   active    |->  active[self],
                                                                                   seen      |->  seen[self],
                                                                                   stopping  |->  stopping[self],
                                                                                   kids      |->  kids[self],
                                                                                   c         |->  c[self],
                                                                                   sw        |->  sw[self],
                                                                                   aw        |->  aw[self],
                                                                                   giveups   |->  giveups[self],
                                                                                   half      |->  half[self],
                                                                                   role      |->  role[self],
                                                                                   pool      |->  pool[self] ] >>
                                                                               \o stack[self]]
                                       /\ ring' = [ring EXCEPT ![self] = <<>>]
                                       /\ tickets' = [tickets EXCEPT ![self] = 0]
                                       /\ active' = [active EXCEPT ![self] = TRUE]
                                       /\ seen' = [seen EXCEPT ![self] = 0]
                                       /\ stopping' = [stopping EXCEPT ![self] = FALSE]
                                       /\ kids' = [kids EXCEPT ![self] = {}]
                                       /\ c' = [c EXCEPT ![self] = 0]
                                       /\ sw' = [sw EXCEPT ![self] = NullWord]
                                       /\ aw' = [aw EXCEPT ![self] = {}]
                                       /\ giveups' = [giveups EXCEPT ![self] = 0]
                                       /\ half' = [half EXCEPT ![self] = 0]
                                       /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, stop, share, uBudget, uAssist, k >>

J_AssistCheck(self) == /\ pc[self] = "J_AssistCheck"
                       /\ k' = [k EXCEPT ![self] = k[self] + 1]
                       /\ uAssist' = 0
                       /\ IF k'[self] < AssistRuns
                             THEN /\ share' = share + 1
                                  /\ apool' = AssistBudget
                                  /\ pc' = [pc EXCEPT ![self] = "J_AJoin"]
                             ELSE /\ IF DoClosing
                                        THEN /\ apool' = 0
                                             /\ share' = share + 1
                                             /\ pc' = [pc EXCEPT ![self] = "J_CJoin"]
                                        ELSE /\ apool' = 0
                                             /\ pc' = [pc EXCEPT ![self] = "Done"]
                                             /\ share' = share
                       /\ UNCHANGED << deque, pstack, priv, mark, scanned, 
                                       budget, word, dirty, stop, uBudget, 
                                       stack, role, pool, ring, tickets, 
                                       active, seen, stopping, kids, c, sw, aw, 
                                       giveups, half >>

J_CJoin(self) == /\ pc[self] = "J_CJoin"
                 /\ IF MUTANT = "joiner_no_reactivate"
                       THEN /\ /\ pool' = [pool EXCEPT ![self] = "budget"]
                               /\ role' = [role EXCEPT ![self] = "Member"]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Run",
                                                                        pc        |->  "J_ClosingCheck",
                                                                        ring      |->  ring[self],
                                                                        tickets   |->  tickets[self],
                                                                        active    |->  active[self],
                                                                        seen      |->  seen[self],
                                                                        stopping  |->  stopping[self],
                                                                        kids      |->  kids[self],
                                                                        c         |->  c[self],
                                                                        sw        |->  sw[self],
                                                                        aw        |->  aw[self],
                                                                        giveups   |->  giveups[self],
                                                                        half      |->  half[self],
                                                                        role      |->  role[self],
                                                                        pool      |->  pool[self] ] >>
                                                                    \o stack[self]]
                            /\ ring' = [ring EXCEPT ![self] = <<>>]
                            /\ tickets' = [tickets EXCEPT ![self] = 0]
                            /\ active' = [active EXCEPT ![self] = TRUE]
                            /\ seen' = [seen EXCEPT ![self] = 0]
                            /\ stopping' = [stopping EXCEPT ![self] = FALSE]
                            /\ kids' = [kids EXCEPT ![self] = {}]
                            /\ c' = [c EXCEPT ![self] = 0]
                            /\ sw' = [sw EXCEPT ![self] = NullWord]
                            /\ aw' = [aw EXCEPT ![self] = {}]
                            /\ giveups' = [giveups EXCEPT ![self] = 0]
                            /\ half' = [half EXCEPT ![self] = 0]
                            /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                            /\ UNCHANGED << word, dirty >>
                       ELSE /\ IF word.done
                                  THEN /\ pc' = [pc EXCEPT ![self] = "J_ClosingCheck"]
                                       /\ UNCHANGED << word, dirty, stack, 
                                                       role, pool, ring, 
                                                       tickets, active, seen, 
                                                       stopping, kids, c, sw, 
                                                       aw, giveups, half >>
                                  ELSE /\ word' = [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)]
                                       /\ dirty' = Bump(self)
                                       /\ /\ pool' = [pool EXCEPT ![self] = "budget"]
                                          /\ role' = [role EXCEPT ![self] = "Member"]
                                          /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Run",
                                                                                   pc        |->  "J_ClosingCheck",
                                                                                   ring      |->  ring[self],
                                                                                   tickets   |->  tickets[self],
                                                                                   active    |->  active[self],
                                                                                   seen      |->  seen[self],
                                                                                   stopping  |->  stopping[self],
                                                                                   kids      |->  kids[self],
                                                                                   c         |->  c[self],
                                                                                   sw        |->  sw[self],
                                                                                   aw        |->  aw[self],
                                                                                   giveups   |->  giveups[self],
                                                                                   half      |->  half[self],
                                                                                   role      |->  role[self],
                                                                                   pool      |->  pool[self] ] >>
                                                                               \o stack[self]]
                                       /\ ring' = [ring EXCEPT ![self] = <<>>]
                                       /\ tickets' = [tickets EXCEPT ![self] = 0]
                                       /\ active' = [active EXCEPT ![self] = TRUE]
                                       /\ seen' = [seen EXCEPT ![self] = 0]
                                       /\ stopping' = [stopping EXCEPT ![self] = FALSE]
                                       /\ kids' = [kids EXCEPT ![self] = {}]
                                       /\ c' = [c EXCEPT ![self] = 0]
                                       /\ sw' = [sw EXCEPT ![self] = NullWord]
                                       /\ aw' = [aw EXCEPT ![self] = {}]
                                       /\ giveups' = [giveups EXCEPT ![self] = 0]
                                       /\ half' = [half EXCEPT ![self] = 0]
                                       /\ pc' = [pc EXCEPT ![self] = "R_Top"]
                 /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                 apool, stop, share, uBudget, uAssist, k >>

J_ClosingCheck(self) == /\ pc[self] = "J_ClosingCheck"
                        /\ \A m \in BgSlots : pc[m] = "Done"
                        /\ pc' = [pc EXCEPT ![self] = "Done"]
                        /\ UNCHANGED << deque, pstack, priv, mark, scanned, 
                                        budget, apool, word, dirty, stop, 
                                        share, uBudget, uAssist, stack, role, 
                                        pool, ring, tickets, active, seen, 
                                        stopping, kids, c, sw, aw, giveups, 
                                        half, k >>

Joiner(self) == J_Start(self) \/ J_AJoin(self) \/ J_AssistCheck(self)
                   \/ J_CJoin(self) \/ J_ClosingCheck(self)

S_Stop(self) == /\ pc[self] = "S_Stop"
                /\ stop' = TRUE
                /\ pc' = [pc EXCEPT ![self] = "Done"]
                /\ UNCHANGED << deque, pstack, priv, mark, scanned, budget, 
                                apool, word, dirty, share, uBudget, uAssist, 
                                stack, role, pool, ring, tickets, active, seen, 
                                stopping, kids, c, sw, aw, giveups, half, k >>

Mutator(self) == S_Stop(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == (\E self \in ProcSet: PublishAll(self) \/ Run(self))
           \/ (\E self \in BgSlots: Member(self))
           \/ (\E self \in JoinerSet: Joiner(self))
           \/ (\E self \in MutSet: Mutator(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in BgSlots : WF_vars(Member(self)) /\ WF_vars(Run(self)) /\ WF_vars(PublishAll(self))
        /\ \A self \in JoinerSet : WF_vars(Joiner(self)) /\ WF_vars(Run(self)) /\ WF_vars(PublishAll(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

-----------------------------------------------------------------------------
(***************************************************************************)
(* Properties checked once the participants have exited, and the asserts   *)
(* of the code's callers. Named invariants, never PlusCal asserts: the     *)
(* runner matches a violation by name.                                     *)
(***************************************************************************)
AllDone == \A p \in Procs : pc[p] = "Done"

\* The Drain contract (parent plan §5.0), checked once every participant has
\* exited: nothing is held privately (IM15: an empty stack and priv = 0,
\* assertNoPrivateWork), every greyed-but-unscanned node is in a deque (what
\* 5c's relaunch, the closing drain and 7c's help start from), and a run that
\* terminated with budget left scanned everything reachable. With ScanOnce and
\* TerminationSafe this is what M1, M3, M5 and M6 assume.
Drain ==
    AllDone =>
        /\ \A x \in Slots : pstack[x] = <<>> /\ priv[x] = 0
        /\ {nd \in Nodes : mark[nd] /\ scanned[nd] = 0}
               \subseteq UNION {Range(deque[x]) : x \in Slots}
        /\ (word.done /\ budget > 0) => \A nd \in Reachable : scanned[nd] = 1

\* Exact tickets (IM12, GC_DET_001): scans by participants drawing on c.budget
\* = tickets consumed.
TicketsExact == AllDone => uBudget = Budget0 - budget

\* The contract's name for both (the configurations check them separately).
Postcondition == Drain /\ TicketsExact

\* The assert in OldGenSpace::assistEpisode: the assist's
\* units == budget - pool.
AssistExact ==
    \A j \in JoinerSet : pc[j] = "J_AssistCheck" => uAssist = AssistBudget - apool

\* The assert in OldGenSpace::closingFinish after reapBackground(true):
\* bg_ep_ == Finished. Violated with StopAllowed and DoClosing: register CR-005.
ClosingFinished ==
    \A j \in JoinerSet :
        (pc[j] = "J_ClosingCheck" /\ \A m \in BgSlots : pc[m] = "Done") => word.done

\* The premise of the folded budget loads (BudgetNeverEmpty): in a drain run
\* the budget never runs out, so `budget.load() > 0` always holds in the idle
\* loop. A check of the model's own abstraction, not of the code.
BudgetOK == BudgetNeverEmpty => budget > 0

\* Liveness: every participant eventually exits.
AllExit == <>AllDone
=============================================================================
