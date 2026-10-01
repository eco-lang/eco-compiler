--------------------------------- MODULE MC ---------------------------------
(***************************************************************************)
(* The miniature heaps of plans/threaded-gc-tla-M4-promotion-bitmap.md     *)
(* §4.2, one per scenario, as the constants PromoBitmap reads.             *)
(*                                                                         *)
(*  M: mixed, cells 1-5, bytes M1 = {1,2,3}, M2 = {4,5}, ONE 64-bit word   *)
(*  D: mixed, all dead at the mark, cells 6-7 (byte D1); swept before M    *)
(*  U: uniform, the mutator's cursor block = the shared promotion block,   *)
(*     cells 8-11, chunk units {8,9} (U1) and {10,11} (U2)                 *)
(*  V: uniform, the refill block (sweep_virgin); cells 12-13               *)
(*  Z: uniform, a t0 block with live object 14 and free cell 15           *)
(*  G: uniform, the tenure grant; cells 16-17 (epoch_l3: also 20-21, G2)   *)
(*  K: uniform, the mutator's cursor block in the epoch; cells 18-19       *)
(*                                                                         *)
(* Scenarios: sweep, sweep_virgin, sweep_1class (a parallel minor while a  *)
(* lazy sweep is pending; sweep_1class without the second size class),    *)
(* minor_virgin (a parallel minor with nothing to sweep and no           *)
(* cycle), cycle (a parallel minor during a mark cycle), epoch / epoch_l3  *)
(* (the mutator and the 7c collector between two minors).                 *)
(***************************************************************************)
EXTENDS PromoBitmap

CONSTANTS Scenario, CycleActive,
          NWorkers,  \* promotion workers in a parallel minor: 2, 3 (deep), or 1 (flip_one_worker)
          NA         \* promotions per worker (every worker the same)

IsSweep  == Scenario \in {"sweep", "sweep_virgin", "sweep_1class"}
IsEpoch  == Scenario \in {"epoch", "epoch_l3"}
IsMinor  == IsSweep \/ Scenario \in {"cycle", "minor_virgin"}   \* a parallel minor
HasV     == Scenario \in {"sweep_virgin", "minor_virgin"}        \* V queued for the refill

MC_Cells  == IF Scenario = "epoch_l3" THEN 1..21 ELSE 1..19
MC_Blocks == {"M", "D", "U", "V", "Z", "G", "K"}
MC_Bytes  == {"M1", "M2", "D1", "U1", "U2", "V1", "Z1", "G1", "K1"}
             \cup (IF Scenario = "epoch_l3" THEN {"G2"} ELSE {})
MC_CellBlock == [c \in MC_Cells |->
    CASE c \in 1..5   -> "M" [] c \in 6..7   -> "D" [] c \in 8..11 -> "U"
      [] c \in 12..13 -> "V" [] c \in 14..15 -> "Z" [] c \in 16..17 -> "G"
      [] c \in 18..19 -> "K" [] c \in 20..21 -> "G"]
MC_CellByte == [c \in MC_Cells |->
    CASE c \in {1, 2, 3} -> "M1" [] c \in {4, 5} -> "M2" [] c \in {6, 7} -> "D1"
      [] c \in {8, 9} -> "U1" [] c \in {10, 11} -> "U2" [] c \in {12, 13} -> "V1"
      [] c \in {14, 15} -> "Z1" [] c \in {16, 17} -> "G1" [] c \in {18, 19} -> "K1"
      [] c \in {20, 21} -> "G2"]
\* The scans read 64-bit words: M's cells share one; a chunk is whole words;
\* blocks never share a word. chunk_unit_subword puts U1 and U2 in one word.
MC_ByteWord == [y \in MC_Bytes |->
    IF y \in {"M1", "M2"} THEN {"M1", "M2"}
    ELSE IF "chunk_unit_subword" \in MUTANT /\ y \in {"U1", "U2"} THEN {"U1", "U2"}
    ELSE {y}]
MC_Mixed == {"M", "D"}
MC_Present == CASE IsSweep -> {"D", "M", "U"} \cup (IF HasV THEN {"V"} ELSE {})
                [] Scenario = "minor_virgin" -> {"M", "U", "V"}
                [] Scenario = "cycle" -> {"M", "U", "Z"}
                [] OTHER -> {"M", "Z", "G", "K", "V"}   \* V: an empty block the flip may take
\* Chunk units (claimChunkW): whole words; chunk_unit_subbyte breaks the rule.
MC_Units == [b \in MC_Blocks |->
    IF "chunk_unit_subbyte" \in MUTANT /\ b = "U" THEN <<{8}, {9, 10}, {11}>>
    ELSE CASE b = "U" -> <<{8, 9}, {10, 11}>>
           [] b = "V" -> <<{12, 13}>>
           \* reuse_released: D, released by a shrink, comes back as a virgin uniform
           \* block of the class at the same start (its cells re-carved: one chunk).
           [] b = "D" /\ "reuse_released" \in MUTANT -> <<{6, 7}>>
           [] b = "Z" -> <<{14, 15}>>
           [] b = "G" /\ Scenario = "epoch_l3" -> <<{16, 17}, {20, 21}>>
           [] OTHER   -> <<>>]
\* claim_after_exhaustion: an unclamped chunk past U's end covers V's cells.
MC_PastEnd == [b \in MC_Blocks |-> IF b = "U" THEN {12, 13} ELSE {}]
MC_T0Blocks == IF Scenario \in {"cycle", "epoch", "epoch_l3"} /\ (CycleActive \/ Scenario = "cycle")
               THEN {"M", "Z"} ELSE {}
MC_T0Live   == IF MC_T0Blocks = {} THEN {} ELSE {2, 3, 14}
MC_GrantBlock == CASE "grant_t0_block" \in MUTANT        -> "Z"
                   [] "grant_includes_cursor" \in MUTANT -> "K"
                   [] OTHER                            -> "G"
\* marker_on_post_t0 (CR-017's worst case): stale greys in a post-t0 chunk
\* (11), grant (16) or cursor (19) block.
MC_MarkerTodo == MC_T0Live \cup (IF "marker_on_post_t0" \in MUTANT THEN {11, 16, 19} ELSE {})
MC_Workers    == IF IsMinor THEN (CASE NWorkers = 3 -> {1, 2, 8} [] NWorkers = 1 -> {1} [] OTHER -> {1, 2}) ELSE {}
MC_Markers    == IF MC_T0Blocks # {} THEN {3} ELSE {}
MC_Collectors == CASE Scenario = "epoch" -> {4} [] Scenario = "epoch_l3" -> {4, 7} [] OTHER -> {}
MC_Mutators   == IF IsEpoch THEN {5} ELSE {}
MC_Mergers    == IF IsMinor THEN {6} ELSE {}
MC_NAllocs    == [w \in MC_Workers |-> NA]
\* reuse_released rows: the stash owner needs one promotion more than the reuser.
MC_NAllocsReuse == [w \in MC_Workers |-> IF w = 1 THEN NA + 1 ELSE NA]
\* A second size class only where a sweep is pending: the sweeper of another
\* class leaves the flushed cells, and does not retire this class's shared block.
\* sweep_1class (deep, three workers) is sweep with the modelled class only.
MC_TwoClasses == IsSweep /\ Scenario # "sweep_1class"

\* ---- starting states ----
\* sweep: after a mark, D (all dead, kept by the min-heap floor) comes first in
\* block order, then M (live 2, 3, 5; dead gaps 1, 4), the last block. One item =
\* one gap-sweep iteration (the budget is tested only at its head, :5336): flush
\* the gap before the next live object (g), clear its bit (l, 0 = none), and at
\* a block's end mark it fully swept (e). D's dead cells are one trailing run.
SweepItems == <<[g |-> <<6, 7>>, l |-> 0, e |-> "D"], [g |-> <<1>>, l |-> 2, e |-> "none"],
                [g |-> <<>>, l |-> 3, e |-> "none"], [g |-> <<4>>, l |-> 5, e |-> "M"]>>
\* virgin_unswept: V materialized without fully_swept (its cells one dead run).
VItem == [g |-> <<12, 13>>, l |-> 0, e |-> "V"]
MC_InitBits == [y \in MC_Bytes |->
    CASE IsSweep /\ y = "M1" -> {2, 3}
      [] IsSweep /\ y = "M2" -> {5}
      [] (IsSweep \/ HasV) /\ y = "U1" -> {8, 9}
      [] (IsSweep \/ HasV) /\ y = "U2" -> {10}
      [] Scenario = "cycle" /\ y = "U1" -> {8}
      [] IsEpoch /\ ~CycleActive /\ y = "M1" -> {2}
      [] OTHER -> {}]
\* Cells of U the mutator's cursor allocated before the minor.
MC_PreAlloc == CASE IsSweep \/ HasV -> {8, 9, 10} [] Scenario = "cycle" -> {8} [] OTHER -> {}
MC_InitQ == CASE IsSweep -> SweepItems \o (IF "virgin_unswept" \in MUTANT THEN <<VItem>> ELSE <<>>)
              [] IsEpoch /\ ~CycleActive -> <<[g |-> <<>>, l |-> 2, e |-> "M"]>>
              [] OTHER -> <<>>
MC_InitFree == CASE Scenario = "cycle" -> <<1, 4>> [] IsEpoch -> <<1>> [] OTHER -> <<>>
MC_InitPhase == CASE IsSweep -> "Sweeping"
                  [] Scenario = "minor_virgin" -> "Idle"
                  [] Scenario = "cycle" -> "Marking"
                  [] CycleActive -> "Marking"
                  [] OTHER -> "Sweeping"
\* beginParallelPromotion (:1398-1405): U becomes the shared block from the unit
\* of its next cell. sweep: only cell 11 is free, so its claimer reaches the
\* lock too; cycle: cells 9-11.
MC_InitShared == CASE "cursor_on_t0" \in MUTANT -> [b |-> "Z", u |-> 0]
                   [] IsSweep \/ HasV -> [b |-> "U", u |-> 1]
                   [] Scenario = "cycle" -> [b |-> "U", u |-> 0]
                   [] OTHER -> [b |-> "none", u |-> 0]
\* sweep_virgin: the refill publishes V, whose live_bytes stays 0 until a
\* worker flushes a chunk of it (as for a virgin block).
MC_InitPartial == IF HasV THEN <<"V">> ELSE <<>>
MC_InitLive == [b \in MC_Blocks |-> CASE (IsSweep \/ HasV) /\ b \in {"M", "U"} -> 3
                                      [] Scenario = "cycle" /\ b = "U" -> 1
                                      [] IsEpoch /\ ~CycleActive /\ b = "M" -> 1
                                      [] b = "Z" -> 1
                                      [] OTHER -> 0]
MC_InitGrantOn == IsEpoch
\* No virgin block in these heaps: the ladder's virgin rung allocates outside the model.
MC_VirginQ == <<>>
\* reuse_released rows (2026-09-29): a FATAL ends the process, so nothing after it
\* is a behaviour of the code (their configurations list only NoDoubleAlloc).
MC_NoFatal == fatal = {}
=============================================================================
