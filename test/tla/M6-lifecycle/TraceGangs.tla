----------------------------- MODULE TraceGangs -----------------------------
(***************************************************************************)
(* M6b trace validation (plans/threaded-gc-tla-M6-lifecycle.md §8;         *)
(* MAPPING.md A5): one recorded 5c cycle of the real allocator             *)
(* (test/gc-heap-tsan/fork_harness.cpp, `gc-fork-trace gangs ...`), with   *)
(* at most one fork by another thread ("host") or by the mutator, replayed *)
(* against Gangs' Next in any order the log allows (TraceAnyOrder).        *)
(*                                                                         *)
(* Threads: "mut" (the heap's mutator), "host", the background member      *)
(* (eco-cmark0: bg1), the 7c tenure collector's member (eco-tenure0: tb1)  *)
(* and the mark gang's member 1 (eco-mark1: fg1); in a mutator's child,   *)
(* the members the child starts (cbg1, ctb1, cfg1: threads whose first     *)
(* event follows the fork's child handler). The harness runs the region   *)
(* nursery, so the log has a tenure gang (TwoGangs): its key is the gang   *)
(* key that is neither the header's bgkey nor its fgkey. The t0 pause      *)
(* joins a tenure job launched before the log starts (U_Pre: its launch is *)
(* hidden, and its member's events may predate the log, so they may be     *)
(* hidden too). Events and the model step each one is:                    *)
(*   minor, t0, t0end  a pause starts; the t0 snapshot (checks only)       *)
(*   launch            launchBackground: U_Launch at t0, else a check      *)
(*   gang.launch       GCBackgroundGang::launch's m_ section: L_Lock, for   *)
(*                     the gang the event names (5c, or 7c tenureLaunch)   *)
(*   gang.refuse       launch refused under a fork hold: L_Lock's refusal  *)
(*                     (register-fixes §7.2 step 4; the M1 projection then  *)
(*                     logs the step as "running" with refused = TRUE and  *)
(*                     a "stop": the events of a fork-stopped episode)     *)
(*   relaunch          runCycleStepConcurrent's relaunch: U_Relaunch       *)
(*   reap done wait    reapBackground after its join: RP_Set               *)
(*   step k ep refused the end of the cycle step: U_Next (ep = bgEp, or a *)
(*                     refused relaunch: bgEp = None)                      *)
(*   gang.run/runEnd   GCMarkGang::run (the closing join): U_RunLock,      *)
(*                     U_FgWait; the drain's run: checks at U_Drain        *)
(*   closing           closingFinish's end: U_Drain                        *)
(*   handoff           the handoff: U_Handoff                              *)
(*   gang.start/exit   memberLoop around fn: B_Wait / B_Fin (FG_Wait /     *)
(*                     FG_Fin for the closing run; checks for the drain's) *)
(*   gang.stop         stopAndJoin's stop under m_: SJ_Lock (either gang;  *)
(*                     the mutator's tenureJoin stops a late 7c job)       *)
(*   gang.join stop    joinLocked after its wait: SJ_Wait or J_Wait; a     *)
(*                     stopAndJoin whose generation was joined and         *)
(*                     relaunched by the owner returns with no gang.join   *)
(*                     (SJ_Wait with gen # sgen, hidden: CR-023's fix)     *)
(*   stop              stopAllForFork after a stopAndJoin (a check)        *)
(*   fork.mprep        GCMarkGang's prepare: G_Mark1 or G_RunM             *)
(*   fork.bgreg        the gangs' prepare, registry locked: G_Reg          *)
(*   fork.bghold       ... every gang's fork_hold_ set: G_Hold             *)
(*   fork.bglock       ... every gang's m_ locked: G_Lock1                 *)
(*   fork.mparent/bparent, fork.mchild/bchild                              *)
(*                     the first of the two is G_Fork (parent / child),   *)
(*                     the second a check                                  *)
(* Hidden: the Mutator's control steps, the early returns of reap, join    *)
(* and stopAndJoin, the prepare's steps that do nothing in this order, the *)
(* marker loop (Mark: M2's contract, so the grey count is abstract), and   *)
(* the calls.                                                              *)
(***************************************************************************)
EXTENDS Gangs, TraceAnyOrder

\* ---- constants from the log ------------------------------------------------
TG_Forker == IF TraceHdr.forker = "host" THEN "host" ELSE "mut"
TG_ForkAllowed == TraceHdr.forker # "none"
TG_Order == TraceHdr.order
TG_MarkThreads == TraceHdr.mark_threads
\* The 7c tenure collector's gang key: any gang key but the 5c gang's and the mark gang's.
IsTnKey(key) == key # TraceHdr.bgkey /\ key # TraceHdr.fgkey
GangKey(key) == IF IsTnKey(key) THEN TN ELSE CM
TG_TwoGangs == \E i \in 1..TraceLen : "gang" \in DOMAIN TraceLog[i] /\ IsTnKey(TraceLog[i].gang)
\* A "step" ends every minor of the cycle, the closing one included.
TG_Steps == TraceCount("step") - 1

ChildEvs == {"fork.mchild", "fork.bchild"}
TG_ChildAt == IF TraceCount("fork.mchild") + TraceCount("fork.bchild") = 0 THEN TraceLen + 1
              ELSE CHOOSE i \in 1..TraceLen : /\ TraceLog[i].ev \in ChildEvs
                                              /\ \A x \in 1..(i - 1) : TraceLog[x].ev \notin ChildEvs
StartsGang(u, key) == \E x \in 1..Len(TraceHdr.tev[u]) :
                        LET e == TraceLog[TraceHdr.tev[u][x]]
                        IN e.ev = "gang.start" /\ e.gang = key
StartsTn(u) == \E x \in 1..Len(TraceHdr.tev[u]) :
                 LET e == TraceLog[TraceHdr.tev[u][x]]
                 IN e.ev = "gang.start" /\ IsTnKey(e.gang)
\* The model's process for each thread of the log.
TG_P == [u \in TraceThreads |->
            IF u \in {"mut", "host"} THEN u
            ELSE IF StartsGang(u, TraceHdr.bgkey)
                 THEN IF TraceHdr.tev[u][1] > TG_ChildAt THEN "cbg1" ELSE "bg1"
            ELSE IF StartsTn(u)
                 THEN IF TraceHdr.tev[u][1] > TG_ChildAt THEN "ctb1" ELSE "tb1"
                 ELSE IF TraceHdr.tev[u][1] > TG_ChildAt THEN "cfg1" ELSE "fg1"]

EpName(x) == CASE x = "Running" -> "running" [] x = "Finished" -> "finished" [] OTHER -> "none"

\* ---- matched steps ---------------------------------------------------------
Matched(u, e) ==
  LET p == TG_P[u] IN
  CASE e.ev = "minor" -> p = "mut" /\ pc["mut"] \in {"U_T0Join", "U_Launch", "U_Tenure", "U_HandoffJoin", "U_Handoff"}
                         /\ UNCHANGED vars
    [] e.ev \in {"t0", "t0end"} -> pc["mut"] = "U_Launch" /\ UNCHANGED vars
    [] e.ev = "launch" -> IF pc["mut"] = "U_Launch" THEN U_Launch ELSE pc["mut"] = "L_Lock" /\ UNCHANGED vars
    [] e.ev = "gang.launch" -> p = "mut" /\ lg["mut"] = GangKey(e.gang) /\ ~hold[lg["mut"]] /\ L_Lock("mut")
    [] e.ev = "gang.refuse" -> p = "mut" /\ lg["mut"] = GangKey(e.gang) /\ hold[lg["mut"]] /\ L_Lock("mut")
    [] e.ev = "relaunch" -> U_Relaunch /\ pc'["mut"] = "L_Lock"
    [] e.ev = "reap" -> ctl[CM].done = e.done /\ wait["mut"] = e.wait /\ RP_Set("mut")
    [] e.ev = "step" -> (IF e.refused THEN bgEp = "None" ELSE EpName(bgEp) = e.ep) /\ U_Next
    [] e.ev = "gang.run" -> IF pc["mut"] = "U_RunLock" THEN U_RunLock
                            ELSE pc["mut"] = "U_Drain" /\ UNCHANGED vars
    [] e.ev = "gang.runEnd" -> IF pc["mut"] = "U_FgWait" THEN U_FgWait
                               ELSE pc["mut"] = "U_Drain" /\ UNCHANGED vars
    [] e.ev = "closing" -> U_Drain
    [] e.ev = "handoff" -> U_Handoff
    [] e.ev = "gang.start" /\ e.gang # TraceHdr.fgkey ->    \* a background member, 5c or 7c
            IF p \in {"bg1", "tb1"} THEN B_Wait(p) ELSE p \in {"cbg1", "ctb1"} /\ CB_Wait(p)
    [] e.ev = "gang.start" ->                               \* the mark gang's member 1
            IF fgGo /\ pc[p] \in {"FG_Wait", "CF_Wait"}
            THEN IF p = "fg1" THEN FG_Wait ELSE CF_Wait
            ELSE pc["mut"] = "U_Drain" /\ UNCHANGED vars      \* the drain's run
    [] e.ev = "gang.exit" /\ e.gang # TraceHdr.fgkey ->
            IF p \in {"bg1", "tb1"} THEN B_Fin(p) ELSE p \in {"cbg1", "ctb1"} /\ CB_Fin(p)
    [] e.ev = "gang.exit" ->
            IF pc[p] \in {"FG_Fin", "CF_Fin"}
            THEN IF p = "fg1" THEN FG_Fin ELSE CF_Fin
            ELSE pc["mut"] = "U_Drain" /\ UNCHANGED vars
    [] e.ev = "gang.stop" -> sg[p] = GangKey(e.gang) /\ SJ_Lock(p) /\ pc'[p] = "SJ_Wait"
    [] e.ev = "gang.join" -> IF e.stop THEN sg[p] = GangKey(e.gang) /\ SJ_Wait(p)
                             ELSE jg[p] = GangKey(e.gang) /\ J_Wait(p)
    [] e.ev = "stop" -> UNCHANGED vars
    [] e.ev = "fork.mprep" -> IF PrepareOrder = "mark_first" THEN G_Mark1(p) ELSE G_RunM(p)
    [] e.ev = "fork.bgreg" -> G_Reg(p)
    [] e.ev = "fork.bghold" -> G_Hold(p)
    [] e.ev = "fork.bglock" -> G_Lock1(p)
    [] e.ev \in {"fork.mparent", "fork.bparent"} ->
            IF pc[p] = "G_Fork" THEN G_Fork(p) /\ world' = "parent" ELSE UNCHANGED vars
    [] e.ev \in ChildEvs ->
            IF pc[p] = "G_Fork" THEN G_Fork(p) /\ world' = "child" ELSE UNCHANGED vars
    [] OTHER -> FALSE                                       \* an event this spec does not know

\* ---- hidden steps: model steps the code does not log ----------------------
Hidden ==
    \/ U_Pre \/ U_T0Join \/ U_Launch2 \/ U_MaybeFork \/ U_Tenure \/ U_Reap
    \/ U_CloseLaunch \/ U_HandoffJoin \/ U_HandoffLaunch
    \/ T_Join("mut") \/ T_Finish("mut")                         \* tenureJoin's decision and finish
    \* The tenure job launched before the log (U_Pre, the first 7c launch), and its
    \* member's start and exit when they predate the log.
    \/ gen[TN] = 0 /\ lg["mut"] = TN /\ L_Lock("mut")
    \/ \E p \in TnIds : gen[TN] = 1 /\ (B_Wait(p) \/ B_Fin(p))
    \/ U_Relaunch /\ pc'["mut"] # "L_Lock"
    \/ U_Close \/ U_CloseRun \/ U_Mark \/ U_Reap2 \/ U_Assert \/ U_Exit
    \/ MarkThreads = 1 /\ (U_RunLock \/ U_FgWait)             \* run(n = 1) logs no gang.run
    \/ \E p \in {"mut", "host"} :
          \/ RP_Check(p) \/ RP_Hint(p) \/ RP_Join(p)
          \/ J_Lock(p)                                        \* join()'s lock and check (logs nothing)
          \/ SJ_Lock(p) /\ pc'[p] # "SJ_Wait"                 \* stopAndJoin(): not running, returns
          \/ SJ_Wait(p) /\ gen[sg[p]] # sgen[p]               \* my_gen joined by the owner: no gang.join
          \/ G_Hold2(p)                                       \* the hold is G_Hold's (no mutant here)
          \/ PrepareOrder = "bg_first" /\ G_Mark1(p)
          \/ PrepareOrder = "mark_first" /\ G_RunM(p)
          \/ G_Stop1(p) \/ G_Stop2(p) \/ G_Lock2(p) \/ G_Ret(p)
    \/ \E p \in ParentParts \cup ChildParts : K_Step(p) \/ K_Again(p)
    \/ \E p \in BgIds \cup TnIds : B_Run(p)
    \/ \E p \in CBgIds \cup CTnIds : CB_Run(p)
    \/ FG_Run \/ CF_Run
    \/ H_Act

TraceInit == Init /\ TPInit
TraceNext == TPMatch(Matched) \/ (Hidden /\ UNCHANGED tpos)
=============================================================================
