------------------------- MODULE TracePromoBitmap -------------------------
(***************************************************************************)
(* M4 trace validation (plans/threaded-gc-tla-M4-promotion-bitmap.md §8;  *)
(* MAPPING.md §8; test/tla/README.md, "Trace validation").                *)
(*                                                                         *)
(* The log comes from test/gc-heap-tsan/promo_sweep.cpp (trace build,     *)
(* `gc-heap-trace promo <seed> <workers> <trees> [jitter]`): one parallel  *)
(* minor of the real allocator promotes young trees of Tuple2s (the        *)
(* modelled size class, 24 B) while a lazy sweep is pending over a mixed  *)
(* block of alternating live and dead Tuple2s, and a queued uniform block  *)
(* of the class has a few free cells. Workers claim that block's chunks,   *)
(* then take promo_mu_, sweep on demand, pop, batch-pop into their stashes *)
(* and finalize stashed cells outside the lock.                            *)
(*                                                                         *)
(* The header is the heap just before the minor, in the model's terms:     *)
(* cells are "block * 10000 + first mark bit", blocks "b<id>", bytes       *)
(* "y<block>.<byte>"; the sweep's remaining iterations (the harness        *)
(* replays pushSpanOnFreeLists' packer to find the class's gap cells); the *)
(* class's free list, partial_ queue and uniform blocks' set bits. The     *)
(* runtime's m4.* hooks (OldGenSpace.cpp, compiled out elsewhere) log      *)
(* every protocol step, with the merger's ordering fields: promo_mu_'s     *)
(* ticks, the shared word's modification order (rmw) and the reads of it   *)
(* (rd), and gc_phase_'s writes (rmw) and reads (rd).                      *)
(*                                                                         *)
(* Every event is one model step, or a check on the state (a lock release  *)
(* the model folded into the step before, a failed pop, the end of a       *)
(* slice). So the code's choices must be the model's: the cell a cursor    *)
(* scan finds, the fast path, the chunk a claim gets, the batch's first    *)
(* cell and size, the sweep's iterations in address order with their gaps, *)
(* the early exit, the head a pop takes, and each finalize's colour (the   *)
(* phase it read). The race detector runs on the replay (TraceRace.cfg).   *)
(* m4.split, m4.large, m4.rel and m4.shrink are logged but not matched yet: *)
(* a log with one is rejected (no registered log has one).                 *)
(*                                                                         *)
(* Hidden: a promotion with no cursor (cursorAllocateW returns at once),   *)
(* a worker's exit, advanceSharedW finding a block another worker         *)
(* published, W_SweepEnd when it is not a completion, the merge's shrink   *)
(* when nothing was deferred. Events are matched in the merged order       *)
(* (TraceInOrder): every cross-thread dependency the model reads has an    *)
(* ordering field.                                                         *)
(***************************************************************************)
EXTENDS TracePromoBitmapData, PromoBitmap, TraceInOrder

\* ---- matching -----------------------------------------------------------
WOf(t) == CHOOSE w \in TP_Workers : TP_Threads[w] = t
IsA(e) == e.cb = H.cb                                  \* the modelled size class
C(e) == Cid(e.blk, e.c)
PhaseVal(p) == CASE p = "Idle" -> 0 [] p = "Marking" -> 1 [] OTHER -> 2

Matched(e) ==
  LET w == WOf(e.t) IN
  CASE e.ev = "m4.begin" ->                             \* beginParallelPromotion's shared word
          shared = [b |-> Blk(e.blk), u |-> e.u] /\ UNCHANGED vars
    [] e.ev = "m4.cur" /\ IsA(e) ->                     \* cursorAllocateW found a cell
          /\ W_Loop(w) \/ W_R1(w)
          /\ pc'[w] = "W_R1Set" /\ cell'[w] = C(e)
          /\ e.fast = (C(e) = pos[w])
    [] e.ev = "m4.set" /\ IsA(e) ->                     \* setBit
          W_R1Set(w) /\ cell[w] = C(e)
    [] e.ev = "m4.rph" /\ IsA(e) ->                     \* finalizeBitmapCellW's colour
          W_R1Ph(w) /\ e.val = PhaseVal(phase)
    [] e.ev = "m4.exh" /\ IsA(e) ->                     \* the chunk is used up: flush
          /\ W_Loop(w) \/ W_R1(w)
          /\ pc'[w] = "W_Claim" /\ chunk[w] # {} /\ chunkLive[w] = e.flush
    [] e.ev = "m4.claim" /\ IsA(e) ->                   \* claimChunkW's CAS: e.units units
          /\ W_Claim(w) /\ pc'[w] = "W_R1"
          /\ shared.b = Blk(e.blk) /\ shared.u = e.u /\ shared'.u = e.u + e.units
    [] e.ev = "m4.nclaim" /\ IsA(e) ->                  \* a failed claim
          W_Claim(w) /\ pc'[w] \in {"W_Stash", "W_Locked"}
    [] e.ev = "m4.lock" /\ IsA(e) /\ ~e.large ->         \* promo_mu_, after the stash check
          W_Stash(w) /\ pc'[w] = "W_Locked"
    [] e.ev = "m4.unlock" ->                            \* the model released in the step before
          lock # w /\ UNCHANGED vars
    [] e.ev = "m4.pub" /\ IsA(e) ->                     \* a queued block (advanceSharedW) or a virgin one
          (W_Locked(w) \/ W_Virgin(w)) /\ shared'.b = Blk(e.blk) /\ pc'[w] = "W_Claim"
    [] e.ev = "m4.retire" /\ IsA(e) ->                  \* advanceSharedW retires the exhausted block
          pc[w] = "W_Locked" /\ shared.b = Blk(e.blk) /\ ~CanClaim /\ UNCHANGED vars
    [] e.ev = "m4.batch" /\ IsA(e) ->                   \* rung 2 in a batch
          /\ W_Locked(w) /\ pc'[w] = "W_Fin"
          /\ fin'[w] = C(e) /\ Len(freeList) - Len(freeList') = e.cnt
    [] e.ev = "m4.ladder" /\ IsA(e) ->                  \* ladderFrom2W: hasPendingSweepWork()
          /\ W_Locked(w) /\ e.val = PhaseVal(phase)
          /\ IF e.pend THEN pc'[w] = "W_Sweep" ELSE pc'[w] = "W_Virgin"
    [] e.ev = "m4.npop" ->                              \* a failed pop between slices
          (other[w] \/ freeList = <<>>) /\ UNCHANGED vars
    [] e.ev = "m4.sw" ->                                \* one gap-sweep iteration
          /\ W_Sweep(w)
          /\ Head(sweepQ).l = (IF e.l < 0 THEN 0 ELSE Cid(e.blk, e.l))
          /\ Head(sweepQ).rs = e.rs /\ Head(sweepQ).rb = e.rb
          /\ (Head(sweepQ).e # "none") = e.end
    [] e.ev = "m4.clr" ->                               \* clearBit
          W_SweepClr(w) /\ cell[w] = Cid(e.blk, e.l)
    [] e.ev = "m4.swend" /\ e.path = 2 ->               \* the in-loop completion: deferred
          W_SweepEnd(w) /\ phase' = "Idle" /\ deferred' /\ pc'[w] = "W_PopAfterSweep"
    [] e.ev = "m4.swend" /\ e.path = 3 ->               \* the tail completion: the shrink now
          W_SweepEnd(w) /\ phase' = "Idle" /\ pc'[w] = "W_Shrink"
    [] e.ev = "m4.swend" ->                             \* the slice ended (budget, early exit)
          UNCHANGED vars
    [] e.ev = "m4.pop" /\ IsA(e) ->                     \* the in-lock pop after the slice
          /\ W_PopAfterSweep(w) /\ ~other[w]
          /\ freeList # <<>> /\ Head(freeList) = C(e)
          /\ e.val = PhaseVal(phase) /\ e.black = Counts(phase)
    [] e.ev = "m4.fin" /\ IsA(e) ->                     \* finalizePoppedCellW's colour
          /\ W_Stash(w) \/ W_StLk(w) \/ W_Fin(w)
          /\ C(e) \in stash[w] /\ e.val = PhaseVal(phase)
          /\ IF e.black THEN pc'[w] = "W_StBit" /\ cell'[w] = C(e)
                        ELSE pc'[w] \in {"W_Loop", "W_StUnlock"} /\ stash'[w] = stash[w] \ {C(e)}
    [] e.ev = "m4.finb" ->                              \* setMarkBitAtomic + live_bytes fetch_add
          W_StBit(w) /\ cell[w] = Cid(e.blk, e.c)
    [] e.ev = "m4.merge" ->                             \* endParallelPromotion after the join
          G_Join(TP_MergeId) /\ deferred = e.deferred
    [] e.ev = "m4.shreset" ->
          UNCHANGED vars
    [] OTHER -> FALSE

Hidden ==
  \/ \E w \in TP_Workers :
        \/ W_Loop(w) /\ pc'[w] = "Done"                                  \* its promotions are done
        \/ W_Loop(w) /\ chunk[w] = {} /\ pc'[w] = "W_Claim"              \* no cursor
        \/ W_Locked(w) /\ CanClaim                                       \* another worker advanced
        \/ W_SweepEnd(w) /\ phase' = phase                               \* not a completion
        \/ W_PopAfterSweep(w) /\ pc'[w] = "W_Virgin"                    \* no cell of the class: on to virgin()
  \/ G_Shrink(TP_MergeId) /\ ~deferred

TraceInit == Init /\ TLInit
TraceNext == TLMatch(Matched) \/ (Hidden /\ UNCHANGED tl)
=============================================================================
