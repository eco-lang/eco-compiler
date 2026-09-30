---------------------------- MODULE TraceHeap ----------------------------
(***************************************************************************)
(* M1 trace validation (b): the tiny graph                                 *)
(* (plans/threaded-gc-tla-M1-snapshot-mark.md §8 (b); MAPPING.md §10).     *)
(*                                                                         *)
(* The log comes from test/gc-heap-tsan/tiny_graph.cpp (trace build,       *)
(* `gc-heap-trace tiny <seed> ...`): at most 8 objects through the real    *)
(* allocator, with background marking. Events:                             *)
(*  - the driver's operations, in the model's vocabulary: load, drop,      *)
(*    cellw, cellr, alloc (object ids, 0 = Nil); after every collection    *)
(*    "heap": the ids allocated and old / allocated and young (bitmasks);  *)
(*    and at the start of every post-mark tail (a probe inside the pause,  *)
(*    OldGenSpace::runPostMarkTail) "marks": which allocated old ids are   *)
(*    marked, the code's liveness decision at a handoff or a STW major;    *)
(*  - the collector: the cycle events of trace (a), every grey (a newly    *)
(*    set mark bit, during a cycle) and every scan, on the thread that did *)
(*    it: the mutator ("mut", which is also member 0 of every in-pause     *)
(*    gang run), the foreground gang ("eco-mark<i>") and the background    *)
(*    gang ("eco-cmark<i>").                                               *)
(* The gangs' launch / start / exit / join / run events order the threads  *)
(* (the merger turns them into each event's vector clock) and are then     *)
(* dropped (TraceHeap.keep).                                               *)
(*                                                                         *)
(* It replays the log against M1's Next with pc and the ghosts hidden. The *)
(* heap is the real one: the model starts from the driver's heap (the      *)
(* header) and every operation, minor, scan, handoff and major is a        *)
(* matched step, so the model's grey set, marks and frees must agree with  *)
(* the code's at every check:                                              *)
(*  - a scan must be of a grey object; a grey must be a marked old object; *)
(*  - t0end: the snapshot greyed exactly as many objects as the model's    *)
(*    P_T0 (so, with the greys, the same set);                             *)
(*  - marks: at a handoff, the marked old objects are exactly the model's   *)
(*    (IM1/IM2 on the real heap: every reachable one is marked, and        *)
(*    nothing else but the snapshot's floating garbage and the black       *)
(*    allocations); at a STW major, exactly the reachable old objects;     *)
(*  - heap: the allocated old and young ids equal the model's (promotion,  *)
(*    and the frees of minors, handoffs and majors);                       *)
(*  - the cycle checks of trace (a) (k, the episode, the closing at T).    *)
(* A background scan is the Marker's step; a scan on "mut" or a            *)
(* foreground member is the pause's (A_Loop or D_Loop). Events are matched *)
(* in any order the log's happens-before allows (TraceAnyOrder): the       *)
(* background members' scans are ordered against the mutator only through *)
(* the gang events and the grey -> scan keys.                              *)
(*                                                                         *)
(* Hidden: the mutator's control steps, the decisions (trigger, assist,    *)
(* pressure: each is logged when taken), the loops' exits, the STW major's *)
(* J_STW (checked by the next heap event), and the background              *)
(* termination.                                                            *)
(***************************************************************************)
EXTENDS SnapshotMark, TraceAnyOrder

VARIABLE mgang            \* the marking gang (from launch events)

V(x) == IF x = 0 THEN Nil ELSE x                        \* a logged id: 0 is Nil
Bits(m) == {o \in Obj : (m \div (2 ^ o)) % 2 = 1}       \* a logged set of ids

\* ---- the starting heap and the bounds, from the log's header -------------
TH_Init  == TraceHdr.init
TH_Alloc == {TH_Init.alloc[j] : j \in DOMAIN TH_Init.alloc}
TH_Old   == {TH_Init.old[j] : j \in DOMAIN TH_Init.old}
TH_Gen   == [o \in Obj |-> IF o \in TH_Old THEN "old" ELSE "young"]
TH_Age   == [o \in Obj |-> 0]
TH_FldOf(o) == LET js == {j \in DOMAIN TH_Init.fld : TH_Init.fld[j][1] = o}
               IN IF js = {} THEN Nil ELSE V(TH_Init.fld[CHOOSE j \in js : TRUE][2])
TH_Fld   == [o \in Obj |-> [i \in Fields |-> TH_FldOf(o)]]
TH_Root  == [r \in RootSlots |-> V(TH_Init.root[r])]
TH_Cell  == [c \in CellSlots |-> V(TH_Init.cell[c])]
TH_T         == TraceHdr.T
TH_MaxMinors == TraceCount("minor") + 1          \* the mutator loop runs while minors < MaxMinors
TH_MaxMajors == TraceCount("major")
TH_MaxStops  == TraceCount("stop")
TH_MaxOps    == TraceCount("load") + TraceCount("drop") + TraceCount("cellw")
                + TraceCount("cellr") + TraceCount("alloc")

IsBg(u) == u \in {"eco-cmark" \o ToString(j) : j \in 0..63}
Mut == pc[MutId]

\* ---- the effect of scanning o (the model's ScanOne for an allocated o) ----
ScanEffect(o) == /\ o \in grey
                 /\ o \in alloc
                 /\ grey' = (grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]}
                 /\ mark' = [x \in Obj |-> mark[x] \/ x \in OldKids({o})]

\* A mutator operation: M_Choose's branch with this result.
Op(e) ==
    /\ M_Choose
    /\ pc'[MutId] = "M_Loop"
    /\ CASE e.ev = "load" ->
              /\ root[e.r2] # Nil /\ fld[root[e.r2]][1] = V(e.v)
              /\ root' = [root EXCEPT ![e.r] = V(e.v)] /\ UNCHANGED <<alloc, fld, cell>>
         [] e.ev = "drop" ->
              root' = [root EXCEPT ![e.r] = Nil] /\ UNCHANGED <<alloc, fld, cell>>
         [] e.ev = "cellw" ->
              /\ root[e.r] = V(e.v)
              /\ cell' = [cell EXCEPT ![e.c] = V(e.v)] /\ UNCHANGED <<alloc, fld, root>>
         [] e.ev = "cellr" ->
              /\ cell[e.c] = V(e.v)
              /\ root' = [root EXCEPT ![e.r] = V(e.v)] /\ UNCHANGED <<alloc, fld, cell>>
         [] e.ev = "alloc" ->
              /\ alloc' = alloc \cup {e.o}
              /\ root' = [root EXCEPT ![e.r] = e.o]
              /\ fld'[e.o][1] = V(e.v)
         [] OTHER -> FALSE

\* ---- matched steps: A(u, e) for thread u's event e ------------------------
Matched(u, e) ==
    CASE e.ev \in {"load", "drop", "cellw", "cellr", "alloc"} ->
            u = "mut" /\ Op(e) /\ UNCHANGED mgang
      [] e.ev = "minor" ->
            P_Minor(MutId) /\ UNCHANGED mgang
      [] e.ev = "major" ->
            J_Join(MutId) /\ e.cyc = CycleOn /\ UNCHANGED mgang
      [] e.ev = "t0" ->
            P_T0(MutId) /\ e.T = T /\ UNCHANGED mgang
      [] e.ev = "step" ->
            /\ P_Marking(MutId) /\ pc'[MutId] = "P_Decide"
            /\ k' = e.k /\ episode' = e.ep
            /\ UNCHANGED mgang
      [] e.ev = "pressure" ->
            P_Marking(MutId) /\ pc'[MutId] = "P_Pressure" /\ UNCHANGED mgang
      [] e.ev = "assist" ->
            A_Done(MutId) /\ UNCHANGED mgang
      [] e.ev = "closing" ->
            cycle = "marking" /\ D_Done(MutId) /\ UNCHANGED mgang
      [] e.ev = "handoff" ->
            /\ H_Free(MutId)
            /\ IF e.why = "schedule"
               THEN cycle = "handoffDue" /\ e.k = k + 1 /\ e.k = T + 1
               ELSE e.k = k
            /\ UNCHANGED mgang
      [] e.ev = "scan" /\ IsBg(u) ->           \* a background member: the Marker
            e.obj \in Obj /\ K_Loop /\ ScanEffect(e.obj) /\ UNCHANGED mgang
      [] e.ev = "scan" ->                      \* the pause: an assist or a drain
            /\ e.obj \in Obj
            /\ \/ Mut = "A_Loop" /\ A_Loop(MutId)
               \/ Mut = "D_Loop" /\ D_Loop(MutId)
            /\ ScanEffect(e.obj)
            /\ UNCHANGED mgang
      [] e.ev = "stop" /\ e.gang = mgang /\ episode = "running" ->
            F_Loop /\ UNCHANGED mgang
      \* ---- checks
      [] e.ev = "stop" ->
            UNCHANGED <<vars, mgang>>
      [] e.ev = "grey" ->                      \* the scan (or t0) before it on its thread marked it
            e.obj \in Obj /\ mark[e.obj] /\ gen[e.obj] = "old" /\ CycleOn /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "t0end" ->
            cycle = "marking" /\ k = 0 /\ Cardinality(grey) = e.greys /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "marks" /\ e.where = "handoff" ->  \* the tail of a handoff: before H_Free frees
            Mut = "H_Free" /\ {o \in CellObjs : mark[o]} = Bits(e.marked) /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "marks" ->                     \* the tail of a STW major: before J_STW frees
            Mut = "J_STW" /\ Live \cap CellObjs = Bits(e.marked) /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "heap" ->                      \* after a whole pause
            /\ Mut = "M_Loop"
            /\ e.cyc = CycleOn
            /\ {o \in alloc : gen[o] = "old"} = Bits(e.old)
            /\ {o \in alloc : gen[o] = "young"} = Bits(e.young)
            /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "launch" ->
            /\ IF Mut = "P_Marking" THEN episode = "none" /\ e.nxt = "step"
                                    ELSE episode = "running" /\ cycle = "marking" /\ k = 0
            /\ mgang' = e.gang
            /\ UNCHANGED vars
      [] e.ev = "relaunch" ->
            Mut = "P_Marking" /\ episode = "none" /\ e.nxt = "launch" /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "reap" ->
            /\ IF e.done THEN episode = "finished" ELSE episode = "none"
            /\ Mut = "P_Marking" => e.nxt \in {"step", "relaunch"}
            /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "join" ->
            CycleOn /\ e.marking = (cycle = "marking") /\ UNCHANGED <<vars, mgang>>
      [] OTHER -> FALSE

\* ---- hidden steps ----------------------------------------------------------
Hidden ==
    \/ M_Loop
    \/ M_Choose /\ pc'[MutId] \in {"P_Minor", "J_Join"}    \* the pause calls; operations are logged
    \/ P_Trigger(MutId) \/ P_Decide(MutId) \/ P_Handoff(MutId)
    \/ P_Closing(MutId) \/ P_Closing2(MutId) \/ P_Pressure(MutId) \/ P_Pressure2(MutId)
    \/ J_Handoff(MutId) \/ J_STW(MutId)
    \/ D_Loop(MutId) /\ pc'[MutId] = "D_Done"                \* the drain's exit (grey = {})
    \/ A_Loop(MutId) /\ pc'[MutId] = "A_Done"                \* the assist's exit or early stop
    \/ D_Done(MutId) /\ cycle # "marking"                    \* a join after the closing
    \/ K_Loop /\ episode' = "finished"                       \* the background termination
    \/ F_Loop /\ stops >= MaxStops

TraceInit == Init /\ TPInit /\ mgang = ""
TraceNext == \/ TPMatch(Matched)
             \/ Hidden /\ UNCHANGED <<tpos, mgang>>
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, tpos, mgang>>
=============================================================================
