------------------------------ MODULE PageWork ------------------------------
(***************************************************************************)
(* M7a: PageWork (runtime/src/allocator/PageWork.cpp): deferred decommit   *)
(* (Pending -> Posted discard -> reaped; a reuse cancels or waits) and     *)
(* commit-ahead (populate jobs; a release waits for an overlapping one),   *)
(* driven by one caller at a time under Allocator::thread_mutex_ (the      *)
(* mutator, or a gang thread promoting), with the jobs run on helper-pool  *)
(* workers. The pool is M6's PoolJob contract: a posted job runs once, in  *)
(* any order; wait returns only when it is Done. Aging and the window are  *)
(* free choices (any subset), an over-approximation of every               *)
(* decommit_delay_* / cap / window setting.                                *)
(*                                                                         *)
(* plans/threaded-gc-tla-M7-pagework.md; the model <-> code map is         *)
(* MAPPING.md, the results and every change from the plan are AUDIT.md.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Extents,         \* old-gen extents of one size (alloc_buffer_size)
    InitHeap,        \* extents the heap owns at the start (below the bump)
    InitFresh,       \* extents above the bump (the commit-ahead window's range)
    Slots,           \* PageWork::slots_ (kJobSlots = 8 in the code)
    Workers,         \* pool workers (gc_helper_threads, default 1)
    MaxOps,          \* bound on caller operations
    MUTANT           \* "none", or one of the negative controls (AUDIT.md):
                     \* "reuse_no_wait", "release_no_await_populate",
                     \* "skip_posted_extents", "reuse_keeps_pending",
                     \* "reuse_bypass", "age_stale_entry", "takeslot_no_wait",
                     \* "job_never_done"

TruncLast(sq) == SubSeq(sq, 1, Len(sq) - 1)
Range(sq) == {sq[i] : i \in 1..Len(sq)}
\* old_gen_free_blocks_'s swap-remove: *it = back(); pop_back().
RemoveAt(sq, i) == IF i = Len(sq) THEN TruncLast(sq)
                   ELSE TruncLast([sq EXCEPT ![i] = sq[Len(sq)]])
\* MUTANT skip_posted_extents: the first extent whose discard is not Posted.
FirstNotPosted(sq, st) ==
    CHOOSE i \in 1..Len(sq) : st[sq[i]] # "Posted" /\ \A k \in 1..(i - 1) : st[sq[k]] = "Posted"

(* --algorithm PageWork
variables
    owner     = [e \in Extents |-> IF e \in InitHeap THEN "heap"
                                   ELSE IF e \in InitFresh THEN "fresh" ELSE "free"],
    freeList  = <<>>,                       \* old_gen_free_blocks_
    gFree     = <<>>,                       \* ghost: the same list, job-blind (GC_DET_001)
    pw        = [e \in Extents |-> "none"], \* PageWork tracking: none / Pending / Posted
    postedIn  = [e \in Extents |-> 0],      \* Posted::slot (0 when not Posted)
    sstate    = [s \in Slots |-> "Idle"],   \* HelperJob::state of PageJob s
    skind     = [s \in Slots |-> "None"],   \* PageJob::kind: None / Discard / Populate
    sext      = [s \in Slots |-> {}],       \* extents (Discard) or window extents (Populate)
    takenSlot = 0,                          \* TakeSlot's result (0 when dead)
    stale     = {};                         \* ghost, MUTANT age_stale_entry only: extents
                                            \* whose pending_order_ entry went stale at a cancel

define
    PopulateInFlightOver(e) ==
        \E s \in Slots : skind[s] = "Populate" /\ sstate[s] \in {"Posted", "Running"}
                         /\ e \in sext[s]
    \* V2b: no heap-owned extent is Pending or Posted.
    NoOwnedPosted == \A x \in Extents : owner[x] = "heap" => pw[x] = "none"
    \* GC_DET_001: the free list (hence every acquire's choice) never depends
    \* on helper progress: it equals its job-blind ghost.
    DetChoice == freeList = gFree
    \* The model's free choices, named so that a trace spec can narrow each to the
    \* value its log dictates (TracePageWork.cfg overrides them; an override must
    \* stay a subset of these). AgeChoices reads pw from before the sync step's
    \* reap (primer rule 13), which is sound: a reap changes no Pending extent.
    ReapChoices   == SUBSET {s \in Slots : sstate[s] = "Done"}            \* reapDone
    AgeChoices    == SUBSET ({x \in Extents : pw[x] = "Pending"} \cup stale) \* aging
    WindowChoices == SUBSET {x \in Extents : owner[x] = "fresh"}          \* topUpWindow
end define;

\* PageWork::reap(s): observed Done; forget the slot's posted extents; slot Idle.
macro Reap(s) begin
    pw := [x \in Extents |-> IF skind[s] = "Discard" /\ x \in sext[s] /\ pw[x] = "Posted"
                                /\ postedIn[x] = s THEN "none" ELSE pw[x]];
    postedIn := [x \in Extents |-> IF skind[s] = "Discard" /\ x \in sext[s] /\ postedIn[x] = s
                                      THEN 0 ELSE postedIn[x]];
    skind[s] := "None";
    sext[s] := {};
    sstate[s] := "Idle";
end macro;

\* PageWork::reapDone(): reap the slots it sees Done. It reads each slot with its
\* own acquire load, so it is not atomic: a slot that turns Done after the loop
\* passed it stays unreaped. Every outcome is some subset R of the slots Done at
\* the loop's end (the step's instant), so the step reaps any such subset.
macro ReapSomeDone() begin
    with R \in ReapChoices do
        pw := [x \in Extents |-> IF \E s \in R : skind[s] = "Discard"
                                       /\ x \in sext[s] /\ postedIn[x] = s /\ pw[x] = "Posted"
                                  THEN "none" ELSE pw[x]];
        postedIn := [x \in Extents |-> IF \E s \in R : skind[s] = "Discard"
                                             /\ x \in sext[s] /\ postedIn[x] = s
                                        THEN 0 ELSE postedIn[x]];
        skind  := [s \in Slots |-> IF s \in R THEN "None" ELSE skind[s]];
        sext   := [s \in Slots |-> IF s \in R THEN {} ELSE sext[s]];
        sstate := [s \in Slots |-> IF s \in R THEN "Idle" ELSE sstate[s]];
    end with;
end macro;

\* awaitSlot(s): returns at once if Idle; else pool.wait(s) (returns when
\* Done), then reap.
procedure AwaitSlot(as)
begin
  AS_Wait:
    await sstate[as] \in {"Idle", "Done"};
    if sstate[as] = "Done" then Reap(as); end if;
    return;
end procedure;

\* takeSlot: reapDone, then the first Idle slot (lowest index), else wait for
\* the oldest (here: any busy slot, a superset of the code's choice).
procedure TakeSlot()
variables ts = 0;
begin
  TS_ReapDone:
    ReapSomeDone();
    if \E s \in Slots : sstate[s] = "Idle" then
        takenSlot := CHOOSE s \in Slots : sstate[s] = "Idle" /\ \A t \in Slots : sstate[t] = "Idle" => s <= t;
        return;
    end if;
  TS_Oldest:
    with s \in Slots do ts := s; end with;
  TS_Wait:
    if MUTANT = "takeslot_no_wait" then
        skip;                                \* hands back a busy slot
    else
        call AwaitSlot(ts);
    end if;
  TS_Got:
    takenSlot := ts;                         \* (return resets the local ts)
    return;
end procedure;

\* The caller: each operation is one PageWork call under thread_mutex_.
fair process Mutator = "mut"
variables n = 0, ext = 0, rs = {}, rsel = 0, batch = {}, win = {};
begin
  M_Choose:
    while n < MaxOps do
        n := n + 1;
        either                                            \* releaseOldGenBlock(ext)
            await \E x \in Extents : owner[x] = "heap";
            with x \in {y \in Extents : owner[y] = "heap"} do ext := x; end with;
            rs := {s \in Slots : skind[s] = "Populate" /\ sstate[s] # "Idle" /\ ext \in sext[s]};
          M_RelWait:                                      \* awaitPopulateOverlapping
            if MUTANT # "release_no_await_populate" /\ rs # {} then
                rsel := CHOOSE s \in rs : \A t \in rs : s <= t;     \* slot order
                rs := rs \ {rsel};
                call AwaitSlot(rsel);
                goto M_RelWait;
            end if;
          M_RelPend:                                      \* onRelease: Pending; the free list
            owner[ext] := "free";
            pw[ext] := "Pending";
            freeList := Append(freeList, ext);
            gFree := Append(gFree, ext);
            ext := 0; rs := {}; rsel := 0;
        or                                                \* acquireOldGenBlock: first-fit reuse
            await freeList # <<>>;
            if MUTANT = "skip_posted_extents" /\ \E i \in 1..Len(freeList) : pw[freeList[i]] # "Posted" then
                ext := freeList[FirstNotPosted(freeList, pw)];
                freeList := RemoveAt(freeList, FirstNotPosted(freeList, pw));
            else
                ext := freeList[1];                         \* first fit (all extents one size)
                freeList := RemoveAt(freeList, 1);
            end if;
            gFree := RemoveAt(gFree, 1);                  \* the job-blind choice
          M_Reuse:                                        \* onReuse (BEFORE any touch)
            if MUTANT = "reuse_bypass" then
                skip;                                     \* a route that never calls onReuse
            elsif pw[ext] = "Pending" then
                if MUTANT # "reuse_keeps_pending" then
                    pw[ext] := "none";                    \* Cancelled: still resident
                end if;
                if MUTANT = "age_stale_entry" then
                    stale := stale \cup {ext};            \* its pending_order_ entry is stale
                end if;
            elsif pw[ext] = "Posted" then
                if MUTANT = "reuse_no_wait" then
                    pw[ext] := "none";
                else
                    call AwaitSlot(postedIn[ext]);        \* AfterDiscard
                end if;
            end if;
          M_Touch:                                        \* (V1 holds here) the heap owns it
            owner[ext] := "heap";
            ext := 0;
        or                                                \* acquireOldGenBlock: fresh bump
            await \E x \in Extents : owner[x] = "fresh";
            with x \in {y \in Extents : owner[y] = "fresh"} do
                owner[x] := "heap";                       \* onFreshBump: never waits
            end with;
        or                                                \* onGCPauseEnd -> syncPoint
            ReapSomeDone();                               \* (a) reapDone
            with b \in AgeChoices do
                batch := b;                               \* (b) age: any choice
            end with;
            stale := {};
            if batch # {} then
              M_Take:
                call TakeSlot();
              M_Post:                                     \* (c) one Discard job
                skind[takenSlot] := "Discard";
                sext[takenSlot] := batch;
                pw := [x \in Extents |-> IF x \in batch THEN "Posted" ELSE pw[x]];
                postedIn := [x \in Extents |-> IF x \in batch THEN takenSlot ELSE postedIn[x]];
                sstate[takenSlot] := "Posted";
                takenSlot := 0;
            end if;
          M_Window:                                       \* (d) topUpWindow: any fresh range
            with w \in WindowChoices do
                win := w;
            end with;
            batch := {};
            if win # {} then
              M_TakeP:
                call TakeSlot();
              M_PostP:
                skind[takenSlot] := "Populate";
                sext[takenSlot] := win;
                sstate[takenSlot] := "Posted";
                takenSlot := 0;
                win := {};
            end if;
        end either;
    end while;
end process;

\* Pool workers run job bodies (M6's PoolJob contract: each posted job runs
\* once; any order).
fair process Worker \in Workers
variables cur = 0, todo = {};
begin
  W_Take:                                                 \* dequeue (under m_): any Posted job
    await \E s \in Slots : sstate[s] = "Posted";
    with s \in {x \in Slots : sstate[x] = "Posted"} do
        cur := s;
        sstate[s] := "Running";
        todo := IF skind[s] = "Discard" THEN sext[s] ELSE {};  \* a populate is one content-
                                                          \* neutral madvise: folded into Done
    end with;
  W_Body:                                                 \* runJob: one madvise per extent, in
    if todo # {} then                                     \* batch order (any here); then Done
        with x \in todo do todo := todo \ {x}; end with;   \* (release, under m_)
        goto W_Body;
    else
        if MUTANT # "job_never_done" then                 \* (the mutant: the pool loses it)
            sstate[cur] := "Done";
        end if;
        cur := 0;
        goto W_Take;
    end if;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
CONSTANT defaultInitValue
VARIABLES pc, owner, freeList, gFree, pw, postedIn, sstate, skind, sext, 
          takenSlot, stale, stack

(* define statement *)
PopulateInFlightOver(e) ==
    \E s \in Slots : skind[s] = "Populate" /\ sstate[s] \in {"Posted", "Running"}
                     /\ e \in sext[s]

NoOwnedPosted == \A x \in Extents : owner[x] = "heap" => pw[x] = "none"


DetChoice == freeList = gFree




ReapChoices   == SUBSET {s \in Slots : sstate[s] = "Done"}
AgeChoices    == SUBSET ({x \in Extents : pw[x] = "Pending"} \cup stale)
WindowChoices == SUBSET {x \in Extents : owner[x] = "fresh"}

VARIABLES as, ts, n, ext, rs, rsel, batch, win, cur, todo

vars == << pc, owner, freeList, gFree, pw, postedIn, sstate, skind, sext, 
           takenSlot, stale, stack, as, ts, n, ext, rs, rsel, batch, win, cur, 
           todo >>

ProcSet == {"mut"} \cup (Workers)

Init == (* Global variables *)
        /\ owner = [e \in Extents |-> IF e \in InitHeap THEN "heap"
                                      ELSE IF e \in InitFresh THEN "fresh" ELSE "free"]
        /\ freeList = <<>>
        /\ gFree = <<>>
        /\ pw = [e \in Extents |-> "none"]
        /\ postedIn = [e \in Extents |-> 0]
        /\ sstate = [s \in Slots |-> "Idle"]
        /\ skind = [s \in Slots |-> "None"]
        /\ sext = [s \in Slots |-> {}]
        /\ takenSlot = 0
        /\ stale = {}
        (* Procedure AwaitSlot *)
        /\ as = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure TakeSlot *)
        /\ ts = [ self \in ProcSet |-> 0]
        (* Process Mutator *)
        /\ n = 0
        /\ ext = 0
        /\ rs = {}
        /\ rsel = 0
        /\ batch = {}
        /\ win = {}
        (* Process Worker *)
        /\ cur = [self \in Workers |-> 0]
        /\ todo = [self \in Workers |-> {}]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self = "mut" -> "M_Choose"
                                        [] self \in Workers -> "W_Take"]

AS_Wait(self) == /\ pc[self] = "AS_Wait"
                 /\ sstate[as[self]] \in {"Idle", "Done"}
                 /\ IF sstate[as[self]] = "Done"
                       THEN /\ pw' = [x \in Extents |-> IF skind[as[self]] = "Discard" /\ x \in sext[as[self]] /\ pw[x] = "Posted"
                                                           /\ postedIn[x] = as[self] THEN "none" ELSE pw[x]]
                            /\ postedIn' = [x \in Extents |-> IF skind[as[self]] = "Discard" /\ x \in sext[as[self]] /\ postedIn[x] = as[self]
                                                                 THEN 0 ELSE postedIn[x]]
                            /\ skind' = [skind EXCEPT ![as[self]] = "None"]
                            /\ sext' = [sext EXCEPT ![as[self]] = {}]
                            /\ sstate' = [sstate EXCEPT ![as[self]] = "Idle"]
                       ELSE /\ TRUE
                            /\ UNCHANGED << pw, postedIn, sstate, skind, sext >>
                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                 /\ as' = [as EXCEPT ![self] = Head(stack[self]).as]
                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                 /\ UNCHANGED << owner, freeList, gFree, takenSlot, stale, ts, 
                                 n, ext, rs, rsel, batch, win, cur, todo >>

AwaitSlot(self) == AS_Wait(self)

TS_ReapDone(self) == /\ pc[self] = "TS_ReapDone"
                     /\ \E R \in ReapChoices:
                          /\ pw' = [x \in Extents |-> IF \E s \in R : skind[s] = "Discard"
                                                            /\ x \in sext[s] /\ postedIn[x] = s /\ pw[x] = "Posted"
                                                       THEN "none" ELSE pw[x]]
                          /\ postedIn' = [x \in Extents |-> IF \E s \in R : skind[s] = "Discard"
                                                                  /\ x \in sext[s] /\ postedIn[x] = s
                                                             THEN 0 ELSE postedIn[x]]
                          /\ skind' = [s \in Slots |-> IF s \in R THEN "None" ELSE skind[s]]
                          /\ sext' = [s \in Slots |-> IF s \in R THEN {} ELSE sext[s]]
                          /\ sstate' = [s \in Slots |-> IF s \in R THEN "Idle" ELSE sstate[s]]
                     /\ IF \E s \in Slots : sstate'[s] = "Idle"
                           THEN /\ takenSlot' = (CHOOSE s \in Slots : sstate'[s] = "Idle" /\ \A t \in Slots : sstate'[t] = "Idle" => s <= t)
                                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                /\ ts' = [ts EXCEPT ![self] = Head(stack[self]).ts]
                                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                           ELSE /\ pc' = [pc EXCEPT ![self] = "TS_Oldest"]
                                /\ UNCHANGED << takenSlot, stack, ts >>
                     /\ UNCHANGED << owner, freeList, gFree, stale, as, n, ext, 
                                     rs, rsel, batch, win, cur, todo >>

TS_Oldest(self) == /\ pc[self] = "TS_Oldest"
                   /\ \E s \in Slots:
                        ts' = [ts EXCEPT ![self] = s]
                   /\ pc' = [pc EXCEPT ![self] = "TS_Wait"]
                   /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, 
                                   sstate, skind, sext, takenSlot, stale, 
                                   stack, as, n, ext, rs, rsel, batch, win, 
                                   cur, todo >>

TS_Wait(self) == /\ pc[self] = "TS_Wait"
                 /\ IF MUTANT = "takeslot_no_wait"
                       THEN /\ TRUE
                            /\ pc' = [pc EXCEPT ![self] = "TS_Got"]
                            /\ UNCHANGED << stack, as >>
                       ELSE /\ /\ as' = [as EXCEPT ![self] = ts[self]]
                               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "AwaitSlot",
                                                                        pc        |->  "TS_Got",
                                                                        as        |->  as[self] ] >>
                                                                    \o stack[self]]
                            /\ pc' = [pc EXCEPT ![self] = "AS_Wait"]
                 /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, sstate, 
                                 skind, sext, takenSlot, stale, ts, n, ext, rs, 
                                 rsel, batch, win, cur, todo >>

TS_Got(self) == /\ pc[self] = "TS_Got"
                /\ takenSlot' = ts[self]
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ ts' = [ts EXCEPT ![self] = Head(stack[self]).ts]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, sstate, 
                                skind, sext, stale, as, n, ext, rs, rsel, 
                                batch, win, cur, todo >>

TakeSlot(self) == TS_ReapDone(self) \/ TS_Oldest(self) \/ TS_Wait(self)
                     \/ TS_Got(self)

M_Choose == /\ pc["mut"] = "M_Choose"
            /\ IF n < MaxOps
                  THEN /\ n' = n + 1
                       /\ \/ /\ \E x \in Extents : owner[x] = "heap"
                             /\ \E x \in {y \in Extents : owner[y] = "heap"}:
                                  ext' = x
                             /\ rs' = {s \in Slots : skind[s] = "Populate" /\ sstate[s] # "Idle" /\ ext' \in sext[s]}
                             /\ pc' = [pc EXCEPT !["mut"] = "M_RelWait"]
                             /\ UNCHANGED <<owner, freeList, gFree, pw, postedIn, sstate, skind, sext, stale, batch>>
                          \/ /\ freeList # <<>>
                             /\ IF MUTANT = "skip_posted_extents" /\ \E i \in 1..Len(freeList) : pw[freeList[i]] # "Posted"
                                   THEN /\ ext' = freeList[FirstNotPosted(freeList, pw)]
                                        /\ freeList' = RemoveAt(freeList, FirstNotPosted(freeList, pw))
                                   ELSE /\ ext' = freeList[1]
                                        /\ freeList' = RemoveAt(freeList, 1)
                             /\ gFree' = RemoveAt(gFree, 1)
                             /\ pc' = [pc EXCEPT !["mut"] = "M_Reuse"]
                             /\ UNCHANGED <<owner, pw, postedIn, sstate, skind, sext, stale, rs, batch>>
                          \/ /\ \E x \in Extents : owner[x] = "fresh"
                             /\ \E x \in {y \in Extents : owner[y] = "fresh"}:
                                  owner' = [owner EXCEPT ![x] = "heap"]
                             /\ pc' = [pc EXCEPT !["mut"] = "M_Choose"]
                             /\ UNCHANGED <<freeList, gFree, pw, postedIn, sstate, skind, sext, stale, ext, rs, batch>>
                          \/ /\ \E R \in ReapChoices:
                                  /\ pw' = [x \in Extents |-> IF \E s \in R : skind[s] = "Discard"
                                                                    /\ x \in sext[s] /\ postedIn[x] = s /\ pw[x] = "Posted"
                                                               THEN "none" ELSE pw[x]]
                                  /\ postedIn' = [x \in Extents |-> IF \E s \in R : skind[s] = "Discard"
                                                                          /\ x \in sext[s] /\ postedIn[x] = s
                                                                     THEN 0 ELSE postedIn[x]]
                                  /\ skind' = [s \in Slots |-> IF s \in R THEN "None" ELSE skind[s]]
                                  /\ sext' = [s \in Slots |-> IF s \in R THEN {} ELSE sext[s]]
                                  /\ sstate' = [s \in Slots |-> IF s \in R THEN "Idle" ELSE sstate[s]]
                             /\ \E b \in AgeChoices:
                                  batch' = b
                             /\ stale' = {}
                             /\ IF batch' # {}
                                   THEN /\ pc' = [pc EXCEPT !["mut"] = "M_Take"]
                                   ELSE /\ pc' = [pc EXCEPT !["mut"] = "M_Window"]
                             /\ UNCHANGED <<owner, freeList, gFree, ext, rs>>
                  ELSE /\ pc' = [pc EXCEPT !["mut"] = "Done"]
                       /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, 
                                       sstate, skind, sext, stale, n, ext, rs, 
                                       batch >>
            /\ UNCHANGED << takenSlot, stack, as, ts, rsel, win, cur, todo >>

M_RelWait == /\ pc["mut"] = "M_RelWait"
             /\ IF MUTANT # "release_no_await_populate" /\ rs # {}
                   THEN /\ rsel' = (CHOOSE s \in rs : \A t \in rs : s <= t)
                        /\ rs' = rs \ {rsel'}
                        /\ /\ as' = [as EXCEPT !["mut"] = rsel']
                           /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "AwaitSlot",
                                                                     pc        |->  "M_RelWait",
                                                                     as        |->  as["mut"] ] >>
                                                                 \o stack["mut"]]
                        /\ pc' = [pc EXCEPT !["mut"] = "AS_Wait"]
                   ELSE /\ pc' = [pc EXCEPT !["mut"] = "M_RelPend"]
                        /\ UNCHANGED << stack, as, rs, rsel >>
             /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, sstate, 
                             skind, sext, takenSlot, stale, ts, n, ext, batch, 
                             win, cur, todo >>

M_RelPend == /\ pc["mut"] = "M_RelPend"
             /\ owner' = [owner EXCEPT ![ext] = "free"]
             /\ pw' = [pw EXCEPT ![ext] = "Pending"]
             /\ freeList' = Append(freeList, ext)
             /\ gFree' = Append(gFree, ext)
             /\ ext' = 0
             /\ rs' = {}
             /\ rsel' = 0
             /\ pc' = [pc EXCEPT !["mut"] = "M_Choose"]
             /\ UNCHANGED << postedIn, sstate, skind, sext, takenSlot, stale, 
                             stack, as, ts, n, batch, win, cur, todo >>

M_Reuse == /\ pc["mut"] = "M_Reuse"
           /\ IF MUTANT = "reuse_bypass"
                 THEN /\ TRUE
                      /\ pc' = [pc EXCEPT !["mut"] = "M_Touch"]
                      /\ UNCHANGED << pw, stale, stack, as >>
                 ELSE /\ IF pw[ext] = "Pending"
                            THEN /\ IF MUTANT # "reuse_keeps_pending"
                                       THEN /\ pw' = [pw EXCEPT ![ext] = "none"]
                                       ELSE /\ TRUE
                                            /\ pw' = pw
                                 /\ IF MUTANT = "age_stale_entry"
                                       THEN /\ stale' = (stale \cup {ext})
                                       ELSE /\ TRUE
                                            /\ stale' = stale
                                 /\ pc' = [pc EXCEPT !["mut"] = "M_Touch"]
                                 /\ UNCHANGED << stack, as >>
                            ELSE /\ IF pw[ext] = "Posted"
                                       THEN /\ IF MUTANT = "reuse_no_wait"
                                                  THEN /\ pw' = [pw EXCEPT ![ext] = "none"]
                                                       /\ pc' = [pc EXCEPT !["mut"] = "M_Touch"]
                                                       /\ UNCHANGED << stack, 
                                                                       as >>
                                                  ELSE /\ /\ as' = [as EXCEPT !["mut"] = postedIn[ext]]
                                                          /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "AwaitSlot",
                                                                                                    pc        |->  "M_Touch",
                                                                                                    as        |->  as["mut"] ] >>
                                                                                                \o stack["mut"]]
                                                       /\ pc' = [pc EXCEPT !["mut"] = "AS_Wait"]
                                                       /\ pw' = pw
                                       ELSE /\ pc' = [pc EXCEPT !["mut"] = "M_Touch"]
                                            /\ UNCHANGED << pw, stack, as >>
                                 /\ stale' = stale
           /\ UNCHANGED << owner, freeList, gFree, postedIn, sstate, skind, 
                           sext, takenSlot, ts, n, ext, rs, rsel, batch, win, 
                           cur, todo >>

M_Touch == /\ pc["mut"] = "M_Touch"
           /\ owner' = [owner EXCEPT ![ext] = "heap"]
           /\ ext' = 0
           /\ pc' = [pc EXCEPT !["mut"] = "M_Choose"]
           /\ UNCHANGED << freeList, gFree, pw, postedIn, sstate, skind, sext, 
                           takenSlot, stale, stack, as, ts, n, rs, rsel, batch, 
                           win, cur, todo >>

M_Take == /\ pc["mut"] = "M_Take"
          /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "TakeSlot",
                                                    pc        |->  "M_Post",
                                                    ts        |->  ts["mut"] ] >>
                                                \o stack["mut"]]
          /\ ts' = [ts EXCEPT !["mut"] = 0]
          /\ pc' = [pc EXCEPT !["mut"] = "TS_ReapDone"]
          /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, sstate, skind, 
                          sext, takenSlot, stale, as, n, ext, rs, rsel, batch, 
                          win, cur, todo >>

M_Post == /\ pc["mut"] = "M_Post"
          /\ skind' = [skind EXCEPT ![takenSlot] = "Discard"]
          /\ sext' = [sext EXCEPT ![takenSlot] = batch]
          /\ pw' = [x \in Extents |-> IF x \in batch THEN "Posted" ELSE pw[x]]
          /\ postedIn' = [x \in Extents |-> IF x \in batch THEN takenSlot ELSE postedIn[x]]
          /\ sstate' = [sstate EXCEPT ![takenSlot] = "Posted"]
          /\ takenSlot' = 0
          /\ pc' = [pc EXCEPT !["mut"] = "M_Window"]
          /\ UNCHANGED << owner, freeList, gFree, stale, stack, as, ts, n, ext, 
                          rs, rsel, batch, win, cur, todo >>

M_Window == /\ pc["mut"] = "M_Window"
            /\ \E w \in WindowChoices:
                 win' = w
            /\ batch' = {}
            /\ IF win' # {}
                  THEN /\ pc' = [pc EXCEPT !["mut"] = "M_TakeP"]
                  ELSE /\ pc' = [pc EXCEPT !["mut"] = "M_Choose"]
            /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, sstate, 
                            skind, sext, takenSlot, stale, stack, as, ts, n, 
                            ext, rs, rsel, cur, todo >>

M_TakeP == /\ pc["mut"] = "M_TakeP"
           /\ stack' = [stack EXCEPT !["mut"] = << [ procedure |->  "TakeSlot",
                                                     pc        |->  "M_PostP",
                                                     ts        |->  ts["mut"] ] >>
                                                 \o stack["mut"]]
           /\ ts' = [ts EXCEPT !["mut"] = 0]
           /\ pc' = [pc EXCEPT !["mut"] = "TS_ReapDone"]
           /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, sstate, skind, 
                           sext, takenSlot, stale, as, n, ext, rs, rsel, batch, 
                           win, cur, todo >>

M_PostP == /\ pc["mut"] = "M_PostP"
           /\ skind' = [skind EXCEPT ![takenSlot] = "Populate"]
           /\ sext' = [sext EXCEPT ![takenSlot] = win]
           /\ sstate' = [sstate EXCEPT ![takenSlot] = "Posted"]
           /\ takenSlot' = 0
           /\ win' = {}
           /\ pc' = [pc EXCEPT !["mut"] = "M_Choose"]
           /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, stale, stack, 
                           as, ts, n, ext, rs, rsel, batch, cur, todo >>

Mutator == M_Choose \/ M_RelWait \/ M_RelPend \/ M_Reuse \/ M_Touch
              \/ M_Take \/ M_Post \/ M_Window \/ M_TakeP \/ M_PostP

W_Take(self) == /\ pc[self] = "W_Take"
                /\ \E s \in Slots : sstate[s] = "Posted"
                /\ \E s \in {x \in Slots : sstate[x] = "Posted"}:
                     /\ cur' = [cur EXCEPT ![self] = s]
                     /\ sstate' = [sstate EXCEPT ![s] = "Running"]
                     /\ todo' = [todo EXCEPT ![self] = IF skind[s] = "Discard" THEN sext[s] ELSE {}]
                /\ pc' = [pc EXCEPT ![self] = "W_Body"]
                /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, skind, 
                                sext, takenSlot, stale, stack, as, ts, n, ext, 
                                rs, rsel, batch, win >>

W_Body(self) == /\ pc[self] = "W_Body"
                /\ IF todo[self] # {}
                      THEN /\ \E x \in todo[self]:
                                todo' = [todo EXCEPT ![self] = todo[self] \ {x}]
                           /\ pc' = [pc EXCEPT ![self] = "W_Body"]
                           /\ UNCHANGED << sstate, cur >>
                      ELSE /\ IF MUTANT # "job_never_done"
                                 THEN /\ sstate' = [sstate EXCEPT ![cur[self]] = "Done"]
                                 ELSE /\ TRUE
                                      /\ UNCHANGED sstate
                           /\ cur' = [cur EXCEPT ![self] = 0]
                           /\ pc' = [pc EXCEPT ![self] = "W_Take"]
                           /\ todo' = todo
                /\ UNCHANGED << owner, freeList, gFree, pw, postedIn, skind, 
                                sext, takenSlot, stale, stack, as, ts, n, ext, 
                                rs, rsel, batch, win >>

Worker(self) == W_Take(self) \/ W_Body(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Mutator
           \/ (\E self \in ProcSet: AwaitSlot(self) \/ TakeSlot(self))
           \/ (\E self \in Workers: Worker(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(Mutator) /\ WF_vars(AwaitSlot("mut")) /\ WF_vars(TakeSlot("mut"))
        /\ \A self \in Workers : WF_vars(Worker(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

-----------------------------------------------------------------------------
\* HEAP_059: a running Discard job never has a heap-owned extent left to
\* madvise (it would zero the new owner's objects).
HEAP_059 == \A w \in Workers :
    (pc[w] = "W_Body" /\ skind[cur[w]] = "Discard") => \A x \in todo[w] : owner[x] = "free"

\* HEAP_060's purpose: no running Discard job has an extent that a Posted or
\* Running populate still covers.
HEAP_060 == \A w \in Workers :
    (pc[w] = "W_Body" /\ skind[cur[w]] = "Discard") => \A x \in todo[w] : ~PopulateInFlightOver(x)

\* V1 (acquireOldGenBlock, after onReuse): the extent handed out is neither
\* Pending nor Posted.
V1 == pc["mut"] = "M_Touch" => pw[ext] = "none"

\* V2a: every tracked extent is in the free list, except the one an acquire has
\* just swap-removed and is passing to onReuse (one thread_mutex_ section in
\* the code; two steps here).
TrackedInFree == \A x \in Extents : pw[x] # "none" => (x \in Range(freeList) \/ x = ext)

\* GCHelperPool::post's CAS (Idle -> Posted, poolAbort otherwise): a job is
\* written and posted only into an Idle slot, so the caller never rewrites
\* the fields of a job a worker is running (PageWork.hpp's slot fields).
PostIdle == pc["mut"] \in {"M_Post", "M_PostP"} => sstate[takenSlot] = "Idle"

\* Liveness: the caller's waits all return (worker fairness, PoolJob).
MutatorFinishes == <>(pc["mut"] = "Done")
=============================================================================
