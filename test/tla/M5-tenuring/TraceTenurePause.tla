------------------------- MODULE TraceTenurePause --------------------------
(***************************************************************************)
(* M5 trace validation (b), the pause projection (plans/threaded-gc-tla-M5-  *)
(* tenuring.md §9; MAPPING.md §8): a recorded run of the REAL allocator's    *)
(* region nursery replayed against Tenuring.tla.                             *)
(*                                                                          *)
(* The log comes from test/gc-heap-tsan/tiny_tenure.cpp in the trace build  *)
(* (`gc-heap-trace tenure <seed> [steps [jitter_us [major %]]]`): at most 8  *)
(* Tuple2 objects (one pointer field, id n = the model's logical id), two   *)
(* roots, k = 1, tenure mode 2, one exact collector ("eco-tenure0"), help  *)
(* on, no incremental marking. Events, each one model step or a check:      *)
(*  - the driver (mut): alloc o r v, load r r2 v, drop r (M_Epoch's        *)
(*    branches); after every collection troots (a check: each root's id    *)
(*    and whether it is old, and the reachable ids);                       *)
(*  - ThreadLocalHeap.cpp (M1's hooks): minor, major (M_Epoch's minor and   *)
(*    major branches);                                                      *)
(*  - NurseryTenure.cpp: tj.launch (MN_Launch with a Tenuring extent: the   *)
(*    extent, its new generation, the distinct starts and the heal slots);  *)
(*    tj.help (J_Help calling the engine: the job is not done); tj.merge    *)
(*    (J_Merge: the objects forwarded and the slots healed);                *)
(*  - GCHelperPool.cpp: gang.start and gang.exit (the collector: C_Wait,    *)
(*    C_Fin), gang.join (the pause: J_Wait's join, or J_Stop after          *)
(*    stopAndJoin's store);                                                 *)
(*  - NurseryRegion.cpp: mzap zapped (MJ_Mark: the sweep and HEAP_074 zap; *)
(*    zapped = the dead Young survivors zapped; 2026-09-30, CR-017).       *)
(* Hidden: the minor's and the major's other steps (MN labels, MJ_Join, MJ_Cycle), which the *)
(* model computes from its heap (the code's slot order and placement are    *)
(* not compared: the model's cells are matched through logical ids and     *)
(* counts only), J_Wait's stop store, J_Help when the job is done, J_Ret,   *)
(* C_Run, F_Maybe, and every engine step (the E labels) of the collector and of the  *)
(* help: the storm (TraceTenuring.tla) matches those one by one.            *)
(***************************************************************************)
EXTENDS Tenuring, TraceAnyOrder

\* ---- constants from the log -------------------------------------------------
TH == TraceHdr
TP_EC       == TH.ec
TP_SC       == TH.ec
TP_OC       == TH.maxid
TP_MaxLid   == TH.maxid
TP_Roots    == {1, 2}
TP_MaxMinors == TraceCount("minor")
TP_MaxMajors == TraceCount("major")
TP_MaxOps   == TraceCount("alloc") + TraceCount("load") + TraceCount("drop")
TP_GenMod   == TraceCount("minor") + 2

Col == 101
Rt(n) == IF n = "r1" THEN 1 ELSE 2
LidIn(h, a) == IF a = Nil THEN 0 ELSE h[a].lid
Bits(m) == {j \in 1..MaxLid : (m \div (2 ^ j)) % 2 = 1}

Matched(u, ee) ==
    CASE ee.ev = "alloc" ->
            LET c == <<"E", ebump>> IN
            /\ M_Epoch /\ nextLid = ee.o /\ nextLid' = nextLid + 1
            /\ root'[Rt(ee.r)] = c /\ ~heap'[c].b
            /\ LidIn(heap', heap'[c].f[1]) = ee.v
      [] ee.ev = "load" ->
            /\ M_Epoch /\ nextLid' = nextLid /\ ops' = ops + 1 /\ heap' = heap
            /\ root' = [root EXCEPT ![Rt(ee.r)] = heap[root[Rt(ee.r2)]].f[1]]
            /\ LidIn(heap, root'[Rt(ee.r)]) = ee.v
      [] ee.ev = "drop" ->
            M_Epoch /\ nextLid' = nextLid /\ ops' = ops + 1 /\ root' = [root EXCEPT ![Rt(ee.r)] = Nil]
      [] ee.ev = "minor" -> M_Epoch /\ pc'[MutId] = "MN_Join"
      [] ee.ev = "major" -> M_Epoch /\ pc'[MutId] = "MJ_Join"
      [] ee.ev = "mzap" ->                        \* HEAP_074: the major's zap of dead Young survivors
            /\ MJ_Mark
            /\ Cardinality({a \in SAddr : heap[a].lid # 0 /\ heap'[a].lid = 0}) = ee.zapped
      [] ee.ev = "tj.launch" ->
            /\ ee.path = "exact"
            /\ MN_Launch /\ \E x \in X : xstate[x] = "Tenuring"
            /\ job'.x = ee.x + 1 /\ gen'[job'.x] = ee.gen
            /\ Len(jstarts') = ee.starts /\ Len(jheal') = ee.heal
      [] ee.ev = "gang.join" /\ ee.stop -> u = "mut" /\ J_Stop(MutId)
      [] ee.ev = "gang.join" -> u = "mut" /\ job.st = "Running" /\ J_Wait(MutId) /\ pc'[MutId] = "J_Help"
      [] ee.ev = "tj.help" -> ee.engine = "exact" /\ J_Help(MutId) /\ ~JobDone
      [] ee.ev = "tj.merge" ->
            /\ ee.heal /\ ee.ylos = 0
            /\ J_Merge(MutId) /\ job.st = "Running"
            /\ Cardinality({a \in XObjs(job.x) : FwdOf(a) # Nil}) = ee.tenured
            /\ Cardinality({s \in Range(jheal) : IsS(HealVal(s), job.x)}) = ee.healed
      [] ee.ev = "gang.start" -> u # "mut" /\ C_Wait(Col)
      [] ee.ev = "gang.exit" -> u # "mut" /\ C_Fin(Col)
      [] ee.ev = "troots" ->                      \* a check after a collection
            /\ pc[MutId] = "M_Epoch"
            /\ LidIn(heap, root[1]) = ee.v1 /\ IsO(root[1]) = ee.old1
            /\ LidIn(heap, root[2]) = ee.v2 /\ IsO(root[2]) = ee.old2
            /\ {heap[a].lid : a \in ReachAll} = Bits(ee.reach)
            /\ UNCHANGED vars
      [] OTHER -> FALSE

Hidden ==
    \/ MN_Join \/ MN_Begin \/ MN_Slot \/ MN_Classify \/ MN_Fwd \/ MN_Set \/ MN_Resolve \/ MN_Next
    \/ MN_Epilogue \/ MN_Cycle \/ MN_Sync \/ MN_Done
    \/ MN_Launch /\ ~(\E x \in X : xstate[x] = "Tenuring")
    \/ MJ_Join \/ MJ_Cycle
    \/ J_Wait(MutId) /\ job.st # "Running"
    \/ J_Wait(MutId) /\ pc'[MutId] = "J_Stop"            \* stopAndJoin's store; gang.join is its join
    \/ J_Help(MutId) /\ JobDone
    \/ J_Merge(MutId) /\ job.st # "Running"
    \/ J_Ret(MutId) \/ C_Run(Col) \/ F_Maybe
    \/ \E w \in {MutId, Col} :
          E_Loop(w) \/ E_Item(w) \/ E_Load(w) \/ E_Claim(w) \/ E_WaitBusy(w) \/ E_Copy(w)
          \/ E_Pub(w) \/ E_Fix(w) \/ E_Ret(w)

TraceInit == Init /\ TPInit
TraceNext == \/ TPMatch(Matched)
             \/ Hidden /\ UNCHANGED tpos
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, tpos>>
=============================================================================
