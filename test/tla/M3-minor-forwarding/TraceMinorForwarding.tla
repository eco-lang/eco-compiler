------------------------ MODULE TraceMinorForwarding ------------------------
(***************************************************************************)
(* M3 trace validation (plans/threaded-gc-tla-M3-minor-forwarding.md §9;   *)
(* MAPPING.md §11).                                                         *)
(*                                                                          *)
(* The log comes from test/gc-helper-tsan/minor_harness.cpp in its trace    *)
(* build (`gc-minor-trace tiny <seed> <workers> <spine run> <pace us>`):     *)
(* one tiny heap of M3's example kind, copied by the real MinorWork.hpp     *)
(* claim / publish / wait and the real runMarkerLoop on GCMarkGang, through *)
(* the harness's replica of evacuateP / spineRunP / copyClaimed /           *)
(* reachYoungLargeP. The header carries the heap (the model's constants).   *)
(* Threads: "mut" (worker 0: the root phase, then member 0 of the drain)    *)
(* and "eco-mark<i>" (member i); model worker i + 1.                        *)
(*                                                                          *)
(* Events, each one model step (or a check that changes nothing):          *)
(*  - MinorWork.hpp hooks: claim (ok: the CAS's rmw, U -> BUSY; failed: the *)
(*    word it observed), publish (BUSY -> FWD(dst)), wait (the first non-  *)
(*    BUSY word waitPublished read);                                       *)
(*  - the harness: load (loadHeader's value, at the call site: evacuate or  *)
(*    the spine run), copy (the copy's id: 100 * k + id, k its copy number, *)
(*    and promote), slot (the store into slot idx of parent, 0 = a root;   *)
(*    with a put key when the copy is pushed), link and trunc (the spine    *)
(*    run), heads (the heads pass and its count m), scan (an entry taken,   *)
(*    with the get key of its push), ylos (the ylos_mu section: won,        *)
(*    promoted; totally ordered by its clock) and ypush.                    *)
(* A header word's events are ordered by the values they read and wrote    *)
(* (rd / rmw on "h<addr>"), pushes before takes by put / get, and the gang *)
(* events (dropped by TraceMinorForwarding.keep) order the root phase      *)
(* before the members. Matched in any order the log's happens-before       *)
(* allows (TraceAnyOrder).                                                  *)
(*                                                                          *)
(* Hidden (not logged): the control steps (W_Roots .. W_Start, W_Scan,      *)
(* W_Idle, the drain's exit, SC_*, E_Read, E_Kind, E_Loop towards a claim   *)
(* or a wait, E_Copy, S_Init, S_Loop, S_Copy, the heads loop, S_Done) and   *)
(* the copy's two memcpys (C_Body, C_Hdr). Never: the mutants' S_Walk,      *)
(* S_WalkNext and Y_Set.                                                    *)
(***************************************************************************)
EXTENDS MinorForwarding, TraceAnyOrder

\* ---- the heap and the bounds, from the log's header -----------------------
TH == TraceHdr
SetOf(s) == {s[j] : j \in DOMAIN s}
TH_FromIds  == SetOf(TH.from)
TH_ConsIds  == SetOf(TH.cons)
TH_YlosIds  == SetOf(TH.ylos)
TH_OldIds   == SetOf(TH.old)
TH_Obj(o)   == TH.objs[CHOOSE j \in DOMAIN TH.objs : TH.objs[j][1] = o]
TH_Fields   == [o \in TH_FromIds \cup TH_YlosIds |-> TH_Obj(o)[3]]
TH_Age      == [o \in TH_FromIds \cup TH_YlosIds |-> TH_Obj(o)[2]]
TH_Roots    == TH.roots
TH_Workers  == 1..TH.workers
TH_MaxRun   == TH.maxrun
TH_PromoAge == TH.promoage
TH_NoIds    == {}
TH_NoRetire == [x \in {} |-> 0]

\* The model worker of a log thread: "mut" is worker 0 (model 1), member i of
\* the gang is "eco-mark<i>" (model i + 1).
WOf(u) == CHOOSE j \in Workers : u = IF j = 1 THEN "mut" ELSE "eco-mark" \o ToString(j - 1)

\* A logged header word: w = 0 unforwarded, 1 BUSY, 2 forwarded to `to`.
Word(e) == IF e.w = 0 THEN Unfwd ELSE IF e.w = 1 THEN Busy ELSE e.to

\* ---- matched steps: A(u, e) for thread u's event e -------------------------
Matched(u, e) ==
    LET w == WOf(u) IN
    CASE e.ev = "scan" ->                       \* take (M2's Drain contract)
            W_Loop(w) /\ pc'[w] = "W_Scan" /\ we'[w] = e.e
      [] e.ev = "load" ->
            \/ E_Load(w) /\ ev[w] = e.obj /\ hdr[e.obj] = Word(e)
            \/ S_Load(w) /\ st[w] = e.obj /\ hdr[e.obj] = Word(e)
      [] e.ev = "claim" /\ e.ok ->
            \/ E_Claim(w) /\ ev[w] = e.obj /\ pc'[w] = "E_Copy"
            \/ S_Claim(w) /\ st[w] = e.obj /\ pc'[w] = "S_Copy"
      [] e.ev = "claim" ->                      \* a lost claim: the word it observed
            \/ E_Claim(w) /\ ev[w] = e.obj /\ pc'[w] = "E_Loop" /\ ehw'[w] = Word(e)
            \/ S_Claim(w) /\ st[w] = e.obj /\ pc'[w] = "S_Loop" /\ hdr[e.obj] = Word(e)
      [] e.ev = "wait" ->
            \/ E_Wait(w) /\ ev[w] = e.obj /\ ehw'[w] = Word(e)
            \/ S_Wait(w) /\ st[w] = e.obj /\ hdr[e.obj] = Word(e)
      [] e.ev = "copy" ->
            C_Alloc(w) /\ cv[w] = e.obj /\ cd'[w] = e.dst /\ promo'[cd'[w]] = e.promote
      [] e.ev = "publish" ->
            C_Pub(w) /\ cv[w] = e.obj /\ hdr'[e.obj] = e.dst
      [] e.ev = "slot" ->
            /\ eo[w] = e.parent /\ ei[w] = e.idx
            /\ \/ E_Slot(w) /\ res[w] = e.val
               \/ E_Loop(w) /\ ehw[w] \in CopyIds /\ ehw[w] = e.val
      [] e.ev = "link" ->
            S_Link(w) /\ sprev[w] = e.prev /\ res[w] = e.cell
      [] e.ev = "heads" ->
            S_Heads(w) /\ pc'[w] = "S_HeadLoop" /\ sm'[w] = e.m
      [] e.ev = "ylos" ->
            /\ Y_Lock(w) /\ yy[w] = e.obj
            /\ e.won = ~yReached[e.obj]
            /\ e.won => yPromoted'[e.obj] = e.promoted
      [] e.ev = "ypush" ->
            Y_Push(w) /\ yy[w] = e.obj
      \* ---- checks
      [] e.ev = "trunc" ->                      \* S_Load pushed the run's last copy
            strunc[w] /\ sprev[w] = e.prev /\ e.prev \in grey /\ UNCHANGED vars
      [] OTHER -> FALSE

\* ---- hidden steps -----------------------------------------------------------
Hidden(w) ==
    \/ W_Roots(w) \/ W_RootLoop(w) \/ W_RootNext(w) \/ W_Start(w)
    \/ W_Loop(w) /\ pc'[w] = "W_Exit"
    \/ W_Scan(w) \/ W_Idle(w) \/ W_Exit(w)
    \/ SC_Loop(w) \/ SC_Next(w) \/ SC_Done(w)
    \/ E_Read(w) \/ E_Kind(w)
    \/ E_Loop(w) /\ ehw[w] \notin CopyIds
    \/ E_Copy(w) \/ C_Body(w) \/ C_Hdr(w)
    \/ S_Init(w) \/ S_Loop(w) \/ S_Copy(w)
    \/ S_Heads(w) /\ pc'[w] = "S_Done"
    \/ S_HeadLoop(w) \/ S_HeadNext(w) \/ S_Done(w)

TraceInit == Init /\ TPInit
TraceNext == \/ TPMatch(Matched)
             \/ (\E w \in Workers : Hidden(w)) /\ UNCHANGED tpos
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, tpos>>
=============================================================================
