--------------------------- MODULE TracePageWork ---------------------------
(***************************************************************************)
(* M7 trace validation (plans/threaded-gc-tla-M7-pagework.md §8;           *)
(* MAPPING.md §10): a recorded run of test/gc-helper-tsan/harness.cpp's    *)
(* H2 (fake page ops) or H3 (real mmap/madvise) script, replayed against   *)
(* M7a's Next.                                                             *)
(*                                                                         *)
(* The log comes from the trace build `gc-helper-trace pagework ...`: the  *)
(* script thread ("mut") calls PageWork under a lock that stands in for    *)
(* Allocator::thread_mutex_, and the pool's workers ("eco-gc<i>") run the  *)
(* jobs. Every event is stamped from one process-wide seq_cst counter      *)
(* (PageWork.cpp's PW_TRACE), so the merged log is one total order and is  *)
(* matched in that order (TraceInOrder). Events, and the model step each   *)
(* one is:                                                                 *)
(*   rel x         releaseOldGenBlock -> onRelease: M_Choose (release)     *)
(*   pend x        onRelease's end (Pending; the script's free-list        *)
(*                 append follows under the lock): M_RelPend               *)
(*   acq x st slot onReuse's entry: M_Choose (first-fit reuse); st is the  *)
(*                 code's tracking of x (0 none, 1 Pending, 2 Posted in    *)
(*                 slot), which must be the model's pw / postedIn          *)
(*   reused x r    onReuse's return: M_Touch (the heap owns x)             *)
(*   fresh x       onFreshBump: M_Choose (fresh bump)                      *)
(*   reaped mask   reapDone's end: in takeSlot, TS_ReapDone reaping        *)
(*                 exactly mask; in syncPoint, recorded for the sync step  *)
(*   age x         syncPoint's aging of x (x must be Pending): recorded    *)
(*   sync size     after the aging: M_Choose (sync point), reaping the     *)
(*                 recorded mask and aging exactly the recorded extents    *)
(*   window lo hi  topUpWindow opened [lo, hi): M_Window                   *)
(*   await slot    awaitSlot after pool.wait and reap: AS_Wait             *)
(*   post slot seq kind  postDiscardBatch / topUpWindow: M_Post / M_PostP  *)
(*   start seq     runJob's entry on a worker: W_Take                      *)
(*   body seq x    after each discard madvise: W_Body (one extent)         *)
(*   jobdone seq   runJob's end (the Done store follows under m_): W_Body  *)
(*                 (Done)                                                  *)
(* Code slot k is model slot k + 1; a job is known by its post sequence    *)
(* number (jobSeq). Hidden: the caller's control steps (M_RelWait's call   *)
(* and exit, M_Reuse, the takeSlot and awaitSlot calls, the busy slot      *)
(* takeSlot waits for, which the await then names), a sync point without a *)
(* window, and the loop's exit.                                            *)
(*                                                                         *)
(* Every matched step must also keep the model's invariants (HEAP_059,     *)
(* HEAP_060, V1, V2a/b, DetChoice, PostIdle): a run that breaks one is     *)
(* rejected, as a real run of H3 would die on its page patterns.           *)
(***************************************************************************)
EXTENDS PageWork, TraceInOrder

VARIABLES reapAcc,        \* the sync point's reapDone mask, until its sync step
          ageAcc,         \* the extents the sync point aged, until its sync step
          jobSeq          \* [Slots -> the post sequence number of its job; 0: none yet]

\* ---- constants from the log ------------------------------------------------
TP_Extents == 1..TraceHdr.N
TP_Slots   == 1..TraceHdr.slots
TP_Workers == TraceThreads \ {"mut"}
TP_MaxOps  == TraceCount("rel") + TraceCount("acq") + TraceCount("fresh") + TraceCount("sync")

Mut == pc["mut"]
Slot(e) == e.slot + 1
Mask(m) == {s \in Slots : (m \div (2 ^ (s - 1))) % 2 = 1}
Tracked(st) == IF st = 0 THEN "none" ELSE IF st = 1 THEN "Pending"
               ELSE IF st = 2 THEN "Posted" ELSE "invalid"
HasSeq(q) == \E s \in Slots : jobSeq[s] = q
SlotOfSeq(q) == CHOOSE s \in Slots : jobSeq[s] = q
\* This step reaps exactly the slots R (Done -> Idle). Conjoined BEFORE the model's
\* action, sstate' is bound first and the action's choice of R becomes a check.
ReapsExactly(R) == /\ R \subseteq {s \in Slots : sstate[s] = "Done"}
                   /\ sstate' = [s \in Slots |-> IF s \in R THEN "Idle" ELSE sstate[s]]
Invariants == HEAP_059 /\ HEAP_060 /\ V1 /\ NoOwnedPosted /\ TrackedInFree /\ DetChoice /\ PostIdle
Aux == <<reapAcc, ageAcc, jobSeq>>
IsWorker(e) == e.t \in Workers

\* ---- the model's free choices, narrowed to the value the log dictates --------
\* (TracePageWork.cfg: ReapChoices <- TP_ReapChoices, ...). Each is the logged value
\* if the model's own choice set contains it, else nothing: an override never admits
\* a value the model could not choose. Without them TLC would enumerate SUBSET of the
\* fresh extents at every window step.
TP_ReapChoices ==
    LET R == IF TLEvent.ev = "sync" THEN reapAcc
             ELSE IF TLEvent.ev = "reaped" THEN Mask(TLEvent.mask) ELSE {}
    IN IF R \subseteq {s \in Slots : sstate[s] = "Done"} THEN {R} ELSE {}
TP_AgeChoices ==
    IF TLEvent.ev = "sync" /\ ageAcc \subseteq ({x \in Extents : pw[x] = "Pending"} \cup stale)
    THEN {ageAcc} ELSE {}
TP_WindowChoices ==
    IF TLEvent.ev = "window"
    THEN LET w == TLEvent.lo..(TLEvent.hi - 1)
         IN IF w \subseteq {x \in Extents : owner[x] = "fresh"} THEN {w} ELSE {}
    ELSE {{}}

\* ---- matched steps --------------------------------------------------------
Matched(e) ==
  /\ CASE e.ev = "rel" ->
            ext' = e.x /\ M_Choose /\ pc'["mut"] = "M_RelWait" /\ UNCHANGED Aux
       [] e.ev = "pend" ->
            M_RelPend /\ ext = e.x /\ UNCHANGED Aux
       [] e.ev = "acq" ->
            /\ pw[e.x] = Tracked(e.st)
            /\ e.st = 2 => postedIn[e.x] = Slot(e)
            /\ ext' = e.x /\ M_Choose /\ pc'["mut"] = "M_Reuse"
            /\ UNCHANGED Aux
       [] e.ev = "reused" ->
            M_Touch /\ ext = e.x /\ UNCHANGED Aux
       [] e.ev = "fresh" ->
            M_Choose /\ owner[e.x] = "fresh" /\ owner'[e.x] = "heap" /\ UNCHANGED Aux
       [] e.ev = "reaped" /\ Mut = "M_Choose" ->          \* the sync point's reapDone
            /\ Mask(e.mask) \subseteq {s \in Slots : sstate[s] = "Done"}
            /\ reapAcc' = Mask(e.mask)
            /\ UNCHANGED <<vars, ageAcc, jobSeq>>
       [] e.ev = "reaped" /\ Mut # "M_Choose" ->          \* takeSlot's reapDone
            ReapsExactly(Mask(e.mask)) /\ TS_ReapDone("mut") /\ UNCHANGED Aux
       [] e.ev = "age" ->
            /\ Mut = "M_Choose" /\ pw[e.x] = "Pending" /\ e.x \notin ageAcc
            /\ ageAcc' = ageAcc \cup {e.x}
            /\ UNCHANGED <<vars, reapAcc, jobSeq>>
       [] e.ev = "sync" ->
            /\ Cardinality(ageAcc) = e.size
            /\ batch' = ageAcc
            /\ ReapsExactly(reapAcc)
            /\ M_Choose /\ pc'["mut"] \in {"M_Take", "M_Window"}
            /\ reapAcc' = {} /\ ageAcc' = {} /\ UNCHANGED jobSeq
       [] e.ev = "window" ->
            win' = e.lo..(e.hi - 1) /\ M_Window /\ UNCHANGED Aux
       [] e.ev = "await" ->
            AS_Wait("mut") /\ as["mut"] = Slot(e) /\ sstate[Slot(e)] = "Done" /\ UNCHANGED Aux
       [] e.ev = "post" ->
            /\ takenSlot = Slot(e)
            /\ IF e.kind = 1 THEN M_Post ELSE e.kind = 2 /\ M_PostP
            /\ jobSeq' = [jobSeq EXCEPT ![Slot(e)] = e.seq]
            /\ UNCHANGED <<reapAcc, ageAcc>>
       [] e.ev = "start" ->
            /\ IsWorker(e) /\ HasSeq(e.seq)
            /\ W_Take(e.t) /\ cur'[e.t] = SlotOfSeq(e.seq)
            /\ UNCHANGED Aux
       [] e.ev = "body" ->
            /\ IsWorker(e) /\ HasSeq(e.seq) /\ cur[e.t] = SlotOfSeq(e.seq)
            /\ e.x \in todo[e.t]
            /\ W_Body(e.t) /\ todo'[e.t] = todo[e.t] \ {e.x}
            /\ UNCHANGED Aux
       [] e.ev = "jobdone" ->
            /\ IsWorker(e) /\ HasSeq(e.seq) /\ cur[e.t] = SlotOfSeq(e.seq)
            /\ todo[e.t] = {}
            /\ W_Body(e.t)
            /\ UNCHANGED Aux
       [] OTHER -> FALSE                                  \* an event this spec does not know
  /\ Invariants'

\* ---- hidden steps: the caller's steps the code does not log ---------------
Hidden ==
    \/ M_RelWait                                  \* the wait loop's call, or its exit
    \/ M_Reuse                                    \* cancel, or call awaitSlot
    \/ M_Take \/ M_TakeP                   \* the takeSlot calls
    \/ TS_Oldest("mut") \/ TS_Wait("mut") \/ TS_Got("mut")
    \/ win' = {} /\ M_Window                      \* a sync point that opens no window
    \/ AS_Wait("mut") /\ sstate[as["mut"]] = "Idle"      \* awaitSlot on an Idle slot (returns)
    \/ M_Choose /\ pc'["mut"] = "Done"                   \* the loop's exit

TraceInit == Init /\ TLInit /\ reapAcc = {} /\ ageAcc = {} /\ jobSeq = [s \in Slots |-> 0]
TraceNext == \/ TLMatch(Matched)
             \/ Hidden /\ UNCHANGED <<tl, reapAcc, ageAcc, jobSeq>>
=============================================================================
