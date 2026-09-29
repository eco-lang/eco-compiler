--------------------------- MODULE TraceTenuring ---------------------------
(***************************************************************************)
(* M5 trace validation (plans/threaded-gc-tla-M5-tenuring.md §9;           *)
(* MAPPING.md §8): a recorded storm of tenure jobs replayed against        *)
(* Tenuring.tla's engine, join, stop, help and merge.                       *)
(*                                                                          *)
(* The log comes from test/gc-helper-tsan/tenure_harness.cpp in its trace  *)
(* build (`gc-tenure-trace tiny <seed> <jobs> <nten> <nfresh> <nold>        *)
(* <nylos> <nf> <stop %> <pace us>`): per job a tiny heap of node objects   *)
(* (nf slots each), rebuilt at the same addresses, so the extent's shadow   *)
(* keeps the entries of earlier generations; the real SerialEngine          *)
(* (TenureWork.hpp) on the real GCBackgroundGang ("eco-tenure0"), and the   *)
(* harness's pause ("mut"): launch, join or stopAndJoin, help, and a        *)
(* replica of mergeJob's YLOS resolve and heal. The header carries every   *)
(* job's heap and inputs. Ids: tenuring object i = 100 + i (model cell      *)
(* <<"S", 1, i + 1>>), fresh j = 200 + j (<<"S", 2, j + 1>>), old k =       *)
(* 300 + k (<<"O", k + 1>>), YLOS y = 400 + y (<<"Y", y + 1>>), a copy =    *)
(* 1000 + n (its model cell is where the model's exact engine put it:       *)
(* cmap), 0 = null or a constant (Nil). A slot is named by its byte offset. *)
(*                                                                          *)
(* Events, each one model step (or a check that changes nothing):          *)
(*  - mut: job k (the hand-over pause: the job's heap and inputs, then      *)
(*    MN_Launch's generation bump and launch: TJob below, which stands for  *)
(*    the minor the harness does not run); tstopreq (J_Wait, stop branch);  *)
(*    gang.join (J_Wait's join, or J_Stop after a stop); tmerge (J_Merge);  *)
(*    theal / tyres / tshadow (checks of the merged heap and the shadow);   *)
(*  - eco-tenure0: gang.start (C_Wait), gang.exit (C_Fin);                  *)
(*  - either thread (the collector, or help in the pause), TenureWork.hpp:  *)
(*    titem (a start or heal item: E_Item), tchild (one slot of a copy's or *)
(*    a reached YLOS object's scan: E_Item), tload (tenure's shadow load:   *)
(*    E_Load, with the entry observed), treach (reachYlos: E_Load), tcopy   *)
(*    (E_Copy), tpub (E_Pub), tfix (childOfCopy's slot store: E_Fix), tstop *)
(*    (run() saw the stop flag: E_Loop's return), tend (step() found no     *)
(*    item: E_Loop's exit).                                                 *)
(* Hidden: the control steps (M_Epoch's minor branch, MN_Join, MN_Sync,     *)
(* MN_Done, J_Help, J_Ret, C_Run, E_Loop towards an item, E_Ret, F_Maybe),  *)
(* E_Load and E_Fix when they do nothing (a null, constant or old target).  *)
(* Never: E_Claim and E_WaitBusy (the exact engine claims nothing), the     *)
(* minor's steps (TJob replaces them), majors, cycles.                      *)
(* Ordering: per thread; launch -> start and exit -> join (the gang's       *)
(* put/get keys); tstopreq -> tstop (key S<flag>.<gen>). Matched in any     *)
(* order that allows (TraceAnyOrder).                                       *)
(***************************************************************************)
EXTENDS Tenuring, TraceAnyOrder

VARIABLE cmap                    \* a copy's log id -> the model cell of that copy

\* ---- constants from the log's header --------------------------------------
TH == TraceHdr
TT_NF     == TH.nf
TT_SC     == IF TH.nten > TH.nfresh THEN TH.nten ELSE TH.nfresh
TT_OC     == TH.nold + TH.nten
TT_YC     == TH.nylos
TT_GenMod == TH.njobs + 2
TT_Roots  == {1}

\* A logged id as a model address.
Adr(id) == IF id = 0 THEN Nil
           ELSE IF id >= 1000 THEN (IF id \in DOMAIN cmap THEN cmap[id] ELSE <<"X", id>>)
           ELSE IF id >= 400 THEN <<"Y", id - 399>>
           ELSE IF id >= 300 THEN <<"O", id - 299>>
           ELSE IF id >= 200 THEN <<"S", 2, id - 199>>
           ELSE <<"S", 1, id - 99>>
\* A logged slot offset as a field index.
Idx(off) == (off - TH.slot0) \div TH.stride + 1
Col == 101                                   \* the collector (one member: the exact engine)
W(u) == IF u = "mut" THEN MutId ELSE Col

\* ---- the hand-over pause of job k: the job's heap, then MN_Launch ---------
CellOf(sl) == [lid |-> 1, f |-> [i \in Fields |-> Adr(sl[i])], b |-> FALSE]
NewHeap(J) ==
    [a \in Addr |->
        IF a[1] = "S" /\ a[2] = 1 /\ a[3] <= Len(J.ten) THEN CellOf(J.ten[a[3]])
        ELSE IF a[1] = "S" /\ a[2] = 2 /\ a[3] <= Len(J.fresh) THEN CellOf(J.fresh[a[3]])
        ELSE IF a[1] = "O" /\ a[2] <= TH.nold THEN [Empty EXCEPT !.lid = 1]
        ELSE IF a[1] = "Y" /\ a[2] <= Len(J.ylos) THEN CellOf(J.ylos[a[2]])
        ELSE Empty]
TJob(ee) ==
    LET J == TH.jobs[ee.k]
        h2 == NewHeap(J)
        g1 == gen[1]
        wrap == NextGen(g1) = 1 /\ g1 # 0
        ng == IF wrap THEN 1 ELSE NextGen(g1)          \* MN_Launch: bump, or discard on wrap
    IN /\ \/ pc[MutId] = "M_Epoch" /\ job.st = "None"
          \/ pc[MutId] = "MN_Begin"
       /\ pc[Col] = "C_Wait" /\ running = 0
       /\ ng = J.gen                                    \* the code's generation is the model's
       /\ heap' = h2
       /\ root' = [r \in Roots |-> Nil]
       /\ xstate' = [x \in X |-> IF x = 1 THEN "Tenuring" ELSE IF x = 2 THEN "Young" ELSE "Free"]
       /\ xage' = [x \in X |-> IF x = 2 THEN 1 ELSE 0]
       /\ gen' = [gen EXCEPT ![1] = ng]
       /\ shadow' = IF wrap THEN [shadow EXCEPT ![1] = [c \in 1..SC |-> NoEntry]] ELSE shadow
       /\ ys' = [c \in 1..YC |-> Gen(1)]                \* the hand-over generation's YLOS
       /\ job' = [st |-> "Running", x |-> 1]
       /\ jstarts' = [j \in 1..Len(J.starts) |-> Adr(J.starts[j])]
       /\ jheal' = [j \in 1..Len(J.heal) |-> <<<<"S", 2, J.heal[j][1] + 1>>, J.heal[j][2]>>]
       /\ jstack' = <<>> /\ ns' = 1 /\ nh' = 1
       /\ jreached' = {} /\ jylos' = <<>> /\ ny' = 1
       /\ ageX' = 0 /\ jSA' = <<>> /\ nsa' = 1 /\ astack' = <<>> /\ amark' = {} /\ swept' = TRUE
       /\ zap' = {}
       /\ grant' = {a \in OAddr : h2[a].lid = 0}
       /\ stop' = FALSE
       /\ running' = Collectors
       /\ go' = [c \in CollIds |-> TRUE]
       /\ cw' = {} /\ ncopy' = [a \in SAddr |-> 0]
       /\ S' = {} /\ H' = {} /\ SA' = {} /\ ypr' = {}
       /\ liveHand' = {} /\ liveHandY' = {} /\ liveAge' = {}
       /\ pc' = [pc EXCEPT ![MutId] = "MN_Sync"]
       /\ UNCHANGED <<lheap, lroot, nextLid, ops, ebump, calive, minors, majors, cycle, grey, black,
                      cage, stack, canStop, tgt, fix, e, res, sc, si, scy, slots, efwd, fill, hand,
                      agex, prev, retire, ftop, fbot, cur, t, v>>

\* ---- matched steps: A(u, ee) for thread u's event ee ------------------------
\* A start or heal item: the engine is between items and its stack is empty.
ItemOK(w, ee) ==
    /\ sc[w] = Nil /\ jstack = <<>>
    /\ tgt'[w] = Adr(ee.tgt)
    /\ IF ee.k = "start" THEN ns = ee.idx + 1 /\ ns <= Len(jstarts)
       ELSE ns > Len(jstarts) /\ nh = ee.idx + 1 /\ nh <= Len(jheal)
\* One slot of a scan: the next slot of the scan in progress, or the first slot
\* of the copy on top of the stack, or of the next reached YLOS object.
ChildOK(w, ee) ==
    /\ tgt'[w] = Adr(ee.tgt)
    /\ IF sc[w] # Nil THEN sc[w] = Adr(ee.par) /\ si[w] = Idx(ee.off)
       ELSE /\ Idx(ee.off) = 1
            /\ IF jstack # <<>> THEN jstack[Len(jstack)] = Adr(ee.par)
               ELSE ns > Len(jstarts) /\ nh > Len(jheal) /\ ny <= Len(jylos) /\ jylos[ny] = Adr(ee.par)
\* The shadow entry of a tenuring object as logged: state, generation, and the
\* destination when it is forwarded in the current generation.
EntryOK(a, ee) ==
    LET en == shadow[1][a[3]]
    IN /\ en.st = ee.st /\ en.g = ee.g
       /\ IF ee.st = 2 /\ ee.g = gen[1] THEN en.dst = Adr(ee.dst) ELSE ee.dst = 0

Matched(u, ee) ==
    LET w == W(u) IN
    /\ CASE ee.ev = "job" -> u = "mut" /\ TJob(ee)
         [] ee.ev = "gang.start" -> w = Col /\ C_Wait(Col)
         [] ee.ev = "gang.exit" -> w = Col /\ C_Fin(Col)
         [] ee.ev = "tstopreq" -> w = MutId /\ J_Wait(MutId) /\ pc'[MutId] = "J_Stop"
         [] ee.ev = "gang.join" /\ ee.stop -> w = MutId /\ J_Stop(MutId)
         [] ee.ev = "gang.join" -> w = MutId /\ job.st = "Running" /\ J_Wait(MutId) /\ pc'[MutId] = "J_Help"
         [] ee.ev = "titem" -> E_Item(w) /\ ItemOK(w, ee)
         [] ee.ev = "tchild" -> E_Item(w) /\ ChildOK(w, ee)
         [] ee.ev = "tload" -> /\ E_Load(w) /\ IsS(tgt[w], job.x) /\ tgt[w] = Adr(ee.obj)
                               /\ EntryOK(tgt[w], ee)
         [] ee.ev = "treach" -> /\ E_Load(w) /\ tgt[w] \in HandY(job.x) /\ tgt[w] = Adr(ee.obj)
                                /\ ee.new = (tgt[w] \notin jreached)
         [] ee.ev = "tcopy" -> E_Copy(w) /\ tgt[w] = Adr(ee.obj)
         [] ee.ev = "tpub" -> E_Pub(w) /\ tgt[w] = Adr(ee.obj) /\ res[w] = Adr(ee.dst)
         [] ee.ev = "tfix" -> /\ E_Fix(w) /\ fix[w] # Nil /\ IsS(tgt[w], job.x)
                              /\ fix[w] = <<Adr(ee.par), Idx(ee.off)>> /\ res[w] = Adr(ee.val)
         [] ee.ev = "tstop" -> E_Loop(w) /\ pc'[w] \notin {"E_Item", "E_Ret"}
         [] ee.ev = "tend" -> E_Loop(w) /\ pc'[w] = "E_Ret"
         [] ee.ev = "tmerge" -> w = MutId /\ job.st = "Running" /\ J_Merge(MutId)
         [] ee.ev \in {"theal", "tyres"} ->
               /\ heap[Adr(ee.par)].f[Idx(ee.off)] = Adr(ee.val)
               /\ UNCHANGED vars
         [] ee.ev = "tshadow" -> EntryOK(Adr(ee.obj), ee) /\ UNCHANGED vars
         [] OTHER -> FALSE
    /\ IF ee.ev = "tcopy" THEN cmap' = cmap @@ (ee.dst :> res'[w]) ELSE UNCHANGED cmap

\* ---- hidden steps -----------------------------------------------------------
Hidden ==
    \/ M_Epoch /\ job.st = "Running" /\ pc'[MutId] = "MN_Join"
    \/ MN_Join \/ MN_Sync \/ MN_Done \/ J_Help(MutId) \/ J_Ret(MutId)
    \/ C_Run(Col) \/ F_Maybe
    \/ \E w \in {MutId, Col} :
          \/ E_Loop(w) /\ pc'[w] = "E_Item"
          \/ E_Load(w) /\ ~IsS(tgt[w], job.x) /\ tgt[w] \notin HandY(job.x)
          \/ E_Fix(w) /\ ~(fix[w] # Nil /\ IsS(tgt[w], job.x))
          \/ E_Ret(w)

TraceInit == Init /\ TPInit /\ cmap = <<>>
TraceNext == \/ TPMatch(Matched)
             \/ Hidden /\ UNCHANGED <<tpos, cmap>>
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, tpos, cmap>>
=============================================================================
