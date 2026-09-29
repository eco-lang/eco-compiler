---------------------------- MODULE TraceCycle ----------------------------
(***************************************************************************)
(* M1 trace validation (a): the cycle projection                           *)
(* (plans/threaded-gc-tla-M1-snapshot-mark.md §8 (a); MAPPING.md §10).     *)
(*                                                                         *)
(* The log comes from the real allocator (test/gc-heap-tsan, trace build,  *)
(* `gc-heap-trace cycle <scenario>`): the mutator thread's cycle events    *)
(* (minor, t0, launch, relaunch, reap, step, assist, closing, pressure,    *)
(* join, handoff, major) and the fork hook's stop, all on one thread, so   *)
(* they are matched in log order.                                          *)
(*                                                                         *)
(* THE HEAP IS HIDDEN. M1's own Next runs on a small static heap: the      *)
(* mutator's heap operations are disabled (Ops = {}), so the only heap     *)
(* changes are the model's own minors, markers, handoffs and majors, on    *)
(* MC.tla's four objects. The real heap's grey set is not the model's, so  *)
(* every model choice that depends on it is left FREE, and the trace       *)
(* constrains only the cycle-level state:                                  *)
(*   constrained: the pause kind and order (a minor, a t0 only when idle,  *)
(*     a step only while marking, the closing exactly at k = T, the        *)
(*     handoff exactly at the next minor or at a pressure / join finish,   *)
(*     a major's join), k at every step and handoff, T, the episode after  *)
(*     every step (running / finished), the episode before every reap      *)
(*     (finished if done, none if stopped), a relaunch only after a stop,  *)
(*     and no reap / relaunch before a pressure finish of the same pause;  *)
(*   free (hidden model steps, or choices the trace does not fix): every   *)
(*     scan (background, assist, closing), so the grey set can be empty or *)
(*     not when the code's is; the background termination ("early done"),  *)
(*     placed anywhere before the reap that reports it; how much an assist *)
(*     scans; the trigger decision, the assist decision and the pressure   *)
(*     decision (each is logged when taken). Relaunch versus finished at a *)
(*     step after a stop is data-dependent (grey # {}); it is free because *)
(*     the model's t0 grey set is never empty (r1 -> 1 is old) and hidden  *)
(*     scans may empty it or not before the stop.                          *)
(*                                                                         *)
(* Two mapping rules (plan §8): the fork hook's stop and the next reap     *)
(* (done = false) are ONE Forker step, so the stop matches F_Loop and the  *)
(* reap is a check that the episode is none; and a pressure finish is      *)
(* decided before any reap or relaunch of its pause.                       *)
(*                                                                         *)
(* A stop of another gang (a tenure collector, region mode) is ignored. A  *)
(* stop of the marking gang after its members finished with done is a     *)
(* no-op in the model (the gang was still running() until joined, but the *)
(* episode had finished): the next reap reports done.                      *)
(***************************************************************************)
EXTENDS SnapshotMark, TraceInOrder

VARIABLE mgang            \* the marking gang (from launch events): stops of other gangs are ignored

\* ---- the static heap: MC.tla's starting heap -------------------------------
TC_Alloc == {1, 2, 3, 4}
TC_Gen   == [o \in Obj |-> IF o \in {1, 2, 4} THEN "old" ELSE "young"]
TC_Age   == [o \in Obj |-> 0]
TC_Fld   == [o \in Obj |-> [i \in Fields |->
                IF i = 1 /\ o = 1 THEN 2 ELSE IF i = 1 /\ o = 3 THEN 4 ELSE Nil]]
TC_Root  == [r \in RootSlots |-> IF r = "r1" THEN 1 ELSE 3]
TC_Cell  == [c \in CellSlots |-> Nil]
\* ---- bounds from the log ---------------------------------------------------
TC_T         == TraceHdr.T
TC_MaxMinors == TraceCount("minor") + 1       \* the mutator loop runs while minors < MaxMinors
TC_MaxMajors == TraceCount("major")
TC_MaxStops  == TraceCount("stop")

Mut == pc[MutId]

\* ---- matched steps: one model step per event --------------------------------
\* Each holds for the model step of event e; mgang changes only at a launch.
Matched(e) ==
    CASE e.ev = "minor" ->
            P_Minor(MutId) /\ UNCHANGED mgang
      [] e.ev = "major" ->
            J_Join(MutId) /\ e.cyc = CycleOn /\ UNCHANGED mgang
      [] e.ev = "t0" ->
            P_T0(MutId) /\ e.T = T /\ UNCHANGED mgang
      [] e.ev = "step" ->                     \* P_Marking, the reap / relaunch branch
            /\ P_Marking(MutId)
            /\ pc'[MutId] = "P_Decide"
            /\ k' = e.k
            /\ episode' = e.ep
            /\ UNCHANGED mgang
      [] e.ev = "pressure" ->                 \* P_Marking, the pressure branch
            P_Marking(MutId) /\ pc'[MutId] = "P_Pressure" /\ UNCHANGED mgang
      [] e.ev = "assist" ->
            A_Done(MutId) /\ UNCHANGED mgang
      [] e.ev = "closing" ->                  \* closingFinish ends with bg_ep_ = None
            cycle = "marking" /\ D_Done(MutId) /\ UNCHANGED mgang
      [] e.ev = "handoff" ->
            /\ H_Free(MutId)
            /\ IF e.why = "schedule"
               THEN cycle = "handoffDue" /\ e.k = k + 1 /\ e.k = T + 1   \* the minor's k++
               ELSE e.k = k
            /\ UNCHANGED mgang
      [] e.ev = "stop" /\ e.gang = mgang /\ episode = "running" ->
            F_Loop /\ UNCHANGED mgang
      \* ---- checks: no model step (the model folds these into the steps above)
      [] e.ev = "stop" ->                     \* another gang, or an episode that already finished
            UNCHANGED <<vars, mgang>>
      [] e.ev = "launch" ->                   \* after t0, or a relaunch (before its step)
            /\ IF Mut = "P_Marking" THEN episode = "none" /\ e.nxt = "step"
                                    ELSE episode = "running" /\ cycle = "marking" /\ k = 0
            /\ mgang' = e.gang
            /\ UNCHANGED vars
      [] e.ev = "relaunch" ->
            Mut = "P_Marking" /\ episode = "none" /\ e.nxt = "launch" /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "reap" ->
            /\ IF e.done THEN episode = "finished" ELSE episode = "none"
            /\ Mut = "P_Marking" => e.nxt \in {"step", "relaunch"}   \* never before a pressure
            /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "t0end" ->
            cycle = "marking" /\ k = 0 /\ UNCHANGED <<vars, mgang>>
      [] e.ev = "join" ->
            CycleOn /\ e.marking = (cycle = "marking") /\ UNCHANGED <<vars, mgang>>
      [] OTHER -> FALSE                       \* an event this projection does not know

\* ---- hidden steps: model steps the code does not log -------------------------
Hidden ==
    \/ M_Loop
    \/ M_Choose                               \* only the pause calls: Ops = {}
    \/ P_Trigger(MutId) \/ P_Decide(MutId) \/ P_Handoff(MutId)
    \/ P_Closing(MutId) \/ P_Closing2(MutId) \/ P_Pressure(MutId) \/ P_Pressure2(MutId)
    \/ J_Handoff(MutId) \/ J_STW(MutId)
    \/ D_Loop(MutId) \/ A_Loop(MutId)         \* scans in the pause, and the loops' exits
    \/ D_Done(MutId) /\ cycle # "marking"     \* a join after the closing: the code drains nothing
    \/ K_Loop                                 \* background scans and termination ("early done")
    \/ F_Loop /\ stops >= MaxStops            \* the Forker's exit

TraceInit == Init /\ TLInit /\ mgang = ""
TraceNext == \/ TLMatch(Matched)
             \/ Hidden /\ UNCHANGED <<tl, mgang>>
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, tl, mgang>>
=============================================================================
