------------------------- MODULE TraceSliceControl -------------------------
(***************************************************************************)
(* M2 trace validation (plans/threaded-gc-tla-M2-slice-control.md §8;     *)
(* MAPPING.md §9; test/tla/README.md, "Trace validation").                 *)
(*                                                                         *)
(* The log comes from test/gc-helper-tsan/mark_harness.cpp (trace build    *)
(* `gc-mark-trace`): the REAL markwork::runMarkerLoop over SynthHeap /     *)
(* SynthEnv (a mirror of OldGenSpace::ParallelEnv: private stacks, priv    *)
(* counted by anyWork), on a small graph. Two scenarios:                   *)
(*  - slices: n Members (GCMarkGang), the root on slot 0's private stack,  *)
(*    several slices of 1..b tickets, then a drain; each slice is a new    *)
(*    SliceControl over the deques the previous one left (NewCtl);         *)
(*  - episode: B background Members (GCBackgroundGang, slots 1..B), the    *)
(*    root in slot 1's deque, and this thread as slot 0: A assists of a    *)
(*    fixed pool, then a stop (stopAndJoin) or the closing join (also     *)
(*    once the members have returned: its reactivate() finds done).       *)
(* Events: MarkWork.hpp's "mw." hooks (run, claim, take, scan, steal,      *)
(* stealNone, ret, idle, react, reactDone, seeDone, seeStop, decide,       *)
(* exit), SynthHeap's push / pub / priv, and the harness's orchestration   *)
(* (ctl, end, assist, assistEnd, closing, stopReq, joined). The gang       *)
(* events order the threads and are then dropped (TraceSliceControl.keep). *)
(* The state word's RMWs (goIdle, reactivate, the done-CAS) and the        *)
(* budget's (claims, returns) are chained by value; every deque push of a  *)
(* publish precedes the steal of that entry (put / get).                   *)
(*                                                                         *)
(* Every event is one model step of the participant it names (slot w is   *)
(* the model's process w + 1), constrained by the event's values, or a    *)
(* check on the state. Hidden (unlogged) are exactly the code's steps      *)
(* without a hook: a failed ticket claim (the pool read 0), the loop-top   *)
(* stop and share_epoch loads, the children's test-and-sets after the      *)
(* first, publishHalf's emptyApprox when the deque is not empty, and the   *)
(* idle loop's state, budget and anyWork loads (HiddenAt). Matched in any  *)
(* order the log's happens-before allows (TraceAnyOrder).                  *)
(***************************************************************************)
EXTENDS SliceControl, TraceAnyOrder

VARIABLE drain                 \* the current control is a drain (kDrainBudget)

BIG == 1000000000              \* the model's budget for a drain (the log's is 2^61 - 1)

\* ---- the instance, from the log's header ----------------------------------
TH_Scen      == TraceHdr.scenario
TH_Nodes     == 1..TraceHdr.nodes
TH_Edges     == {<<TraceHdr.edges[j][1], TraceHdr.edges[j][2]>> : j \in DOMAIN TraceHdr.edges}
TH_BgSlots   == IF TH_Scen = "slices" THEN 1..TraceHdr.n ELSE 2..(TraceHdr.B + 1)
TH_FgSlot    == IF TH_Scen = "slices" THEN 0 ELSE 1
TH_Slots     == TH_BgSlots \cup (IF TH_FgSlot = 0 THEN {} ELSE {TH_FgSlot})
TH_InitStack == [x \in TH_Slots |-> IF TH_Scen = "slices" /\ x = 1 THEN TraceHdr.stack0 ELSE <<>>]
TH_InitDeque == [x \in TH_Slots |-> IF TH_Scen = "episode" THEN TraceHdr.deque0[x] ELSE <<>>]
TH_Budget0   == IF TH_Scen = "slices" THEN 1 ELSE BIG
TH_Stop      == TH_Scen = "episode" /\ TraceHdr.stop
TH_Assists   == IF TH_Scen = "episode" THEN TraceHdr.assists ELSE 0
TH_ABudget   == IF TH_Scen = "episode" THEN TraceHdr.abudget ELSE 0
TH_Closing   == TH_Scen = "episode" /\ ~TraceHdr.stop
\* Reachable (used only by Drain, which the trace does not check) would be the
\* first constant TLC evaluates at startup, before the log is cached: every
\* Edges it reads would parse the log again. The cfg replaces it.
TH_NoReach   == {}

\* ---- the model's steps ------------------------------------------------------
Step(p) == \/ Run(p) \/ PublishAll(p)
           \/ p \in BgSlots /\ Member(p)
           \/ p \in JoinerSet /\ Joiner(p)
PoolV(p)  == IF pool[p] = "budget" THEN budget ELSE apool
PoolV2(p) == IF pool[p] = "budget" THEN budget' ELSE apool'
\* A logged pool value (a string beyond 32 bits in a drain) equals the model's.
PoolIs(p, e) == IF drain /\ e.pool = "budget" THEN TRUE
                ELSE PoolV(p) = e.old /\ PoolV2(p) = e.new
\* Fill() and the steal's claim with no ticket in hand and an empty pool: the
\* claim fails on its load (no hook).
ClaimFails(p) == tickets[p] = 0 /\ PoolV(p) = 0
InRun(p) == stack[p] # <<>>
Entries == UNION {Range(deque[x]) : x \in Slots}

\* The steps the code does not log (see the header).
HiddenAt(p) ==
    CASE pc[p] \in {"R_Kids", "R_Share", "I_Budget1", "I_Scan1", "I_Priv1",
                    "I_Budget2", "I_Scan2", "I_Priv2"}   -> TRUE
      [] pc[p] = "R_Top"  -> StopAllowed \/ JoinerSet # {} \/ ClaimFails(p)
      [] pc[p] = "R_Fill" -> stopping[p] \/ Len(ring[p]) >= RING \/ ClaimFails(p)
      [] pc[p] = "R_Steal" -> ClaimFails(p)
      [] pc[p] \in {"R_PubHalf", "R_PopPub"} -> deque[p] # <<>>
      [] pc[p] = "I_Load" -> ~word.done
      [] pc[p] = "I_Stop" -> ~stop
      [] pc[p] = "J_AssistCheck" -> k[p] + 1 >= AssistRuns /\ ~DoClosing
      [] OTHER -> FALSE
Hidden == \E p \in Procs : HiddenAt(p) /\ Step(p)

\* A new SliceControl over the deques the last run left (a slice, or the
\* episode's launch): the members start, the control is fresh.
NewCtl(e) ==
    /\ \A p \in BgSlots : pc[p] \in {"M_Run", "Done"}
    /\ \A p \in JoinerSet : pc[p] = "J_Start"
    /\ e.active = Cardinality(BgSlots) /\ e.victims = Cardinality(Slots)
    /\ pc' = [p \in ProcSet |-> IF p \in BgSlots THEN "M_Run" ELSE pc[p]]
    /\ word' = [active |-> e.active, epoch |-> 0, done |-> FALSE]
    /\ dirty' = [p \in Procs |-> FALSE]
    /\ budget' = IF e.drain THEN BIG ELSE e.budget
    /\ uBudget' = 0
    /\ drain' = e.drain
    /\ UNCHANGED <<deque, pstack, priv, mark, scanned, apool, stop, share, uAssist, stack,
                   role, pool, ring, tickets, active, seen, stopping, kids, c, sw, aw,
                   giveups, half, k>>

\* ---- thread u's event e ----------------------------------------------------
M(p, labels) == pc[p] \in labels /\ Step(p)

Matched(u, e) ==
  LET p == IF "w" \in DOMAIN e THEN e.w + 1 ELSE 0
      J == FgSlot
  IN
  CASE e.ev = "mw.ctl" -> NewCtl(e)
    [] e.ev = "mw.run" /\ ~e.joined ->
          M(p, {"M_Run"}) /\ UNCHANGED drain
    [] e.ev = "mw.run" ->                    \* a joiner, before its reactivate()
          pc[p] = (IF e.assist THEN "J_AJoin" ELSE "J_CJoin") /\ UNCHANGED <<vars, drain>>
    [] e.ev = "mw.claim" ->
          /\ M(p, {"R_Top", "R_Fill", "R_Steal"})
          /\ (e.pool = "budget") = (pool[p] = "budget")
          /\ PoolV2(p) = PoolV(p) - e.took /\ PoolIs(p, e)
          /\ UNCHANGED drain
    [] e.ev = "mw.take" /\ e.e # 0 ->
          /\ M(p, {"R_Top", "R_Fill", "R_TakeOwn"})
          /\ ring'[p] = Append(ring[p], e.e)
          /\ UNCHANGED drain
    [] e.ev = "mw.take" ->                   \* takeOwn found nothing: ++tickets; break
          /\ M(p, {"R_Top", "R_Fill", "R_TakeOwn"})
          /\ pc[p] = "R_TakeOwn" \/ tickets[p] > 0
          /\ ~stopping[p] /\ Len(ring[p]) < RING
          /\ pstack[p] = <<>> /\ deque[p] = <<>>
          /\ UNCHANGED drain
    [] e.ev = "mw.scan" ->
          M(p, {"R_Scan"}) /\ Head(ring[p]) = e.e /\ UNCHANGED drain
    [] e.ev = "mw.push" ->
          M(p, {"R_Push"}) /\ c[p] = e.e /\ UNCHANGED drain
    [] e.ev = "mw.pub" ->
          /\ M(p, {"R_PubHalf", "R_PubHalfLoop", "R_PopPub", "R_PopPubLoop", "R_Idle",
                   "PA_Loop", "R_ExitActive", "R_ExitIdle"})
          /\ pstack[p] # <<>> /\ Head(pstack[p]) = e.e
          /\ deque'[p] = Append(deque[p], e.e)
          /\ UNCHANGED drain
    [] e.ev = "mw.priv" ->
          /\ M(p, {"R_PubHalfPriv", "R_PopPubPriv", "PA_Priv", "PA_Loop"})
          /\ priv'[p] = e.cnt /\ deque' = deque
          /\ UNCHANGED drain
    [] e.ev = "mw.steal" ->
          /\ M(p, {"R_Steal", "R_StealTry"})
          /\ deque[e.v + 1] # <<>> /\ Head(deque[e.v + 1]) = e.e
          /\ deque'[e.v + 1] = Tail(deque[e.v + 1])
          /\ ring'[p] = Append(ring[p], e.e)
          /\ UNCHANGED drain
    [] e.ev = "mw.stealNone" ->
          /\ M(p, {"R_Steal", "R_StealTry"})
          /\ pc[p] = "R_StealTry" \/ tickets[p] > 0
          /\ deque' = deque /\ ring' = ring
          /\ UNCHANGED drain
    [] e.ev = "mw.ret" ->
          /\ M(p, {"R_Idle", "R_Idle2", "R_Idle3", "R_ExitActive", "R_ExitActive2", "R_ExitIdle2"})
          /\ (e.pool = "budget") = (pool[p] = "budget")
          /\ e.cnt = tickets[p] /\ PoolV2(p) = PoolV(p) + e.cnt /\ PoolIs(p, e)
          /\ UNCHANGED drain
    [] e.ev = "mw.idle" ->
          /\ M(p, {"R_Idle", "R_Idle2", "R_Idle3", "R_ExitActive", "R_ExitActive2", "R_ExitActive3"})
          /\ word'.active = word.active - 1 /\ word'.active = e.act
          /\ UNCHANGED drain
    [] e.ev = "mw.react" ->
          /\ M(p, {"I_React", "J_AJoin", "J_CJoin"})
          /\ word'.active = word.active + 1 /\ word'.active = e.act
          /\ UNCHANGED drain
    [] e.ev = "mw.reactDone" ->
          M(p, {"I_React", "J_AJoin", "J_CJoin"}) /\ word.done /\ UNCHANGED drain
    [] e.ev = "mw.seeDone" ->
          M(p, {"I_Load"}) /\ word.done /\ UNCHANGED drain
    [] e.ev = "mw.seeStop" ->
          M(p, {"I_Stop"}) /\ stop /\ UNCHANGED drain
    [] e.ev = "mw.decide" ->
          M(p, {"I_Decide"}) /\ (word' # word) = e.ok /\ UNCHANGED drain   \* the CAS set done
    [] e.ev = "mw.exit" ->                   \* the run has returned
          ~InRun(p) /\ pc[p] \notin {"M_Run", "J_AJoin", "J_CJoin"} /\ UNCHANGED <<vars, drain>>
    \* ---- the harness (the mutator thread)
    [] e.ev = "mw.end" ->                    \* after a slice's gang run
          /\ \A m \in BgSlots : pc[m] = "Done"
          /\ word.done = e.done /\ uBudget = e.units
          /\ IF drain THEN TRUE ELSE budget = e.left
          /\ UNCHANGED <<vars, drain>>
    [] e.ev = "mw.assist" ->                 \* share_epoch.fetch_add; the pool
          /\ M(J, {"J_Start", "J_AssistCheck"}) /\ pc'[J] = "J_AJoin"
          /\ apool' = e.budget
          /\ UNCHANGED drain
    [] e.ev = "mw.assistEnd" ->              \* units == budget - pool
          pc[J] = "J_AssistCheck" /\ uAssist = e.units /\ apool = e.left /\ UNCHANGED <<vars, drain>>
    [] e.ev = "mw.closing" ->                \* share_epoch.fetch_add
          M(J, {"J_Start", "J_AssistCheck"}) /\ pc'[J] = "J_CJoin" /\ UNCHANGED drain
    [] e.ev = "mw.stopReq" ->
          S_Stop(MutId) /\ UNCHANGED drain
    [] e.ev = "mw.joined" /\ DoClosing ->    \* reapBackground(true): the join
          /\ J_ClosingCheck(J)
          /\ word.done = e.done /\ Cardinality(Entries) = e.left
          /\ UNCHANGED drain
    [] e.ev = "mw.joined" ->                 \* stopAndJoin returned
          /\ \A m \in Procs : pc[m] = "Done"
          /\ word.done = e.done /\ Cardinality(Entries) = e.left
          /\ UNCHANGED <<vars, drain>>
    [] OTHER -> FALSE

TraceInit == Init /\ TPInit /\ drain = FALSE
TraceNext == \/ TPMatch(Matched)
             \/ Hidden /\ UNCHANGED <<tpos, drain>>
=============================================================================
