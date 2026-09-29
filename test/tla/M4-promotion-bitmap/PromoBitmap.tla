----------------------------- MODULE PromoBitmap -----------------------------
(***************************************************************************)
(* M4: old-gen allocation and mark-bitmap BYTES under concurrency, with a  *)
(* vector-clock data-race detector.                                        *)
(*                                                                         *)
(* Plan: plans/threaded-gc-tla-M4-promotion-bitmap.md. Model <-> code:     *)
(* MAPPING.md; results and every difference from the plan: AUDIT.md.       *)
(*                                                                         *)
(* Processes:                                                              *)
(*  - Worker: a parallel-minor promotion worker (OldGenSpace::             *)
(*    allocatePromotion and its *W helpers), including the lazy / gap      *)
(*    sweep it runs inside promo_mu_ (sweep-on-demand);                    *)
(*  - Marker: a background marker (testAndSetMark<ParallelMark>);          *)
(*  - Merge: endParallelPromotion after the gang join;                     *)
(*  - Collector: 7c's tenure collector in its grant (grantAllocate, or     *)
(*    grantAllocateShared for two L3 members);                             *)
(*  - Mutator: the mutator between two minors (cursor, free-list pop with  *)
(*    allocate-black, a lazy-sweep slice, the next minor's tenure join).   *)
(*                                                                         *)
(* The miniature heap (blocks, cells, bytes, words, chunk units, starting  *)
(* state) is a set of constants; MC.tla defines one heap per scenario.     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    NAllocs,       \* [Workers -> Nat]: promotions per worker
    ClaimK,        \* chunk units one claim may take (the code doubles them: 1, 2, 4, ...)
    BatchMax,      \* cells one batch pop takes at most (1 + kStash = 17 in the code)
    Breadth,       \* deep only: promotions and ladder rungs with no modelled heap effect
    MUTANT,        \* a SET of control names (plan §5, AUDIT.md); {} = the code as it is
    \* ---- threads ----
    Workers, Markers, Collectors, Mutators, Mergers,
    TwoClasses,    \* workers also promote a second size class (the sweep scenarios)
    NGrant,        \* copies the tenure collector makes (shared by its members)
    \* ---- the miniature heap ----
    Cells, Blocks, Bytes,
    CellBlock,     \* [Cells -> Blocks]
    CellByte,      \* [Cells -> Bytes]: a mark byte covers 2-3 cells (8 slots in the code)
    ByteWord,      \* [Bytes -> SUBSET Bytes]: the 64-bit word a scan reads
    MixedBlocks,   \* gap-swept blocks; the others are uniform (bitmap = allocation map)
    Present,       \* the blocks that exist in the scenario (shrink / flip candidates)
    ChunkUnits,    \* [Blocks -> Seq(SUBSET Cells)]: the chunk units of a shared block
    PastEnd,       \* [Blocks -> SUBSET Cells]: what an unclamped claim past the end covers
    T0Blocks,      \* blocks that existed at t0 (empty outside a mark cycle)
    T0Live,        \* objects live at t0 that the background marker must mark
    GrantBlock,    \* the block granted to the tenure collector
    CursorBlock,   \* the mutator's cursor block during the epoch
    MarkerTodo,    \* the cells the background marker marks
    \* ---- the starting state ----
    InitBits, InitFree, InitQ, InitPhase, InitShared, InitPartial, InitLive, PreAlloc,
    InitGrantOn,
    VirginQ        \* blocks the ladder's virgin rung publishes, in order (<<>>: a cell outside the model)

Threads    == Workers \cup Markers \cup Collectors \cup Mutators \cup Mergers
BlkOf(c)   == CellBlock[c]
ByteOf(c)  == CellByte[c]
WordOf(y)  == ByteWord[y]
Units(b)   == ChunkUnits[b]
CellsOf(b) == {c \in Cells : BlkOf(c) = b}
Uniform    == Blocks \ MixedBlocks
T0Cells    == UNION {CellsOf(b) : b \in T0Blocks}
L3         == Cardinality(Collectors) > 1
GrantUnits == Units(GrantBlock)

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
MinOf(S)  == CHOOSE x \in S : \A y \in S : x <= y
Range(sq) == {sq[i] : i \in 1..Len(sq)}
AnyOf(S)  == CHOOSE x \in S : TRUE
RECURSIVE SetToSeqAny(_)
SetToSeqAny(S) == IF S = {} THEN <<>>
                  ELSE LET x == CHOOSE y \in S : TRUE IN <<x>> \o SetToSeqAny(S \ {x})
\* The pointwise maximum of the clocks of the threads in S (a join).
JoinVC(vcs, S) == [u \in Threads |-> LET vals == {vcs[t][u] : t \in S} IN
                                     CHOOSE m \in vals : \A x \in vals : x <= m]
\* The chunks' unflushed pending_live, per block (the merge's flushCursorW).
RECURSIVE FlushSum(_, _, _, _)
FlushSum(S, b, ch, cl) ==
    IF S = {} THEN 0
    ELSE LET w == CHOOSE x \in S : TRUE IN
         (IF ch[w] # {} /\ BlkOf(AnyOf(ch[w])) = b THEN cl[w] ELSE 0)
           + FlushSum(S \ {w}, b, ch, cl)

\* ---- the race detector (plan §4.4, primer §3.7) ----------------------------
\* Locations: the mark bytes, gc_phase_ and live_bytes (one location: the
\* shrink and the flip read every block's live_bytes).
Locs == Bytes \cup {"phase", "live"}
\* One access: location, plain (not atomic), writes.
Acc1(loc, p, w) == [l |-> loc, p |-> p, w |-> w]
\* A scan (nextFreeCell, nextSetBit) is a plain memcpy of a whole 64-bit word:
\* in C++ an access to every byte it covers.
WordRd(y) == {Acc1(z, TRUE, FALSE) : z \in WordOf(y)}
\* nextFreeCell's word reads over the cells [from, to] of a chunk.
ScanRd(ch, from, to) == UNION {WordRd(ByteOf(c)) : c \in {x \in ch : from <= x /\ x <= to}}
\* The free cells of a chunk at or after the cursor position p.
FreeIn(ch, p, bs) == {c \in ch : c >= p /\ c \notin bs[ByteOf(c)]}
\* The cursor's next_cell after c: the chunk's next cell (cell ids need not be
\* consecutive: a trace names cells by their first mark bit).
NextPos(ch, c) == IF \E x \in ch : x > c THEN MinOf({x \in ch : x > c}) ELSE c + 1

InitSwept == [b \in Blocks |-> ~\E i \in 1..Len(InitQ) : InitQ[i].e = b]
InitVC    == [t \in Threads |-> [u \in Threads |-> IF t = u THEN 1 ELSE 0]]
Zero      == [u \in Threads |-> 0]

(* --algorithm PromoBitmap
variables
    bits      = InitBits,                 \* mark bytes: the set bits (cells) of each byte
    freeList  = InitFree,                 \* the modelled class's free list, head first (LIFO)
    sweepQ    = InitQ,                    \* gap sweep: loop iterations [g, l, e] not yet run
    phase     = InitPhase,                \* gc_phase_ (a PLAIN field)
    liveBytes = InitLive,                 \* BufferMetadata::live_bytes, in cells
    swept     = InitSwept,                \* BufferMetadata::fully_swept
    deferred  = FALSE,                    \* sweep_complete_deferred_
    shared    = InitShared,               \* PromoCtx::shared[cls]: [b |-> block, u |-> next unit]
    partialQ  = InitPartial,              \* partial_[cls]: queued blocks for the refill
    virginQ   = VirginQ,                  \* virgin blocks startVirginBlockShared would publish
    lock      = 0,                        \* promo_mu_ (0 = free)
    chunk     = [w \in Threads |-> {}],   \* a worker's cursor: its chunk's cells ({} = none)
    chunkLive = [w \in Threads |-> 0],    \* the cursor's pending_live (unflushed)
    stash     = [w \in Threads |-> {}],   \* PromoWorker::stash, including the cell being finalized
    released  = {},                       \* blocks released by a shrink or flipped to large
    grantOn   = InitGrantOn,              \* TenureGrant::active
    grantLive = 0,                        \* the grant's pending_live, folded at the merge
    gclaim    = 0,                        \* L3: the grant claim word (next unit)
    gwork     = NGrant,                   \* the survivors the tenure collector still copies
    \* ---- ghosts ----
    fatal     = {},                       \* FATALs that fired: "detach", "grantAtT0"
    allocs    = [c \in Cells |-> IF c \in PreAlloc THEN 1 ELSE 0],   \* times c was handed out
    need      = {},                       \* allocate-black bits that must survive (IM4)
    marked    = {},                       \* bits the marker set
    claimed   = {},                       \* chunk units claimed: <<block, unit>>
    \* ---- the data-race detector ----
    vc        = InitVC,                   \* vc[t][u]: what t knows of u's clock
    lockvc    = Zero,                     \* the clock promo_mu_ carries
    sharedvc  = Zero,                     \* the clock the shared word's release sequence carries
    hist      = [loc \in Locs |-> {}],    \* per location: the latest access of each kind
    races     = {};                       \* locations with an unordered conflicting pair

define
    Allocated  == {c \in Cells : allocs[c] > 0}
    PhasePlain == "phase_atomic" \notin MUTANT     \* gc_phase_ is a plain field today
    SetBits    == UNION {bits[y] : y \in Bytes}
    CanClaim   == shared.b # "none" /\ shared.u < Len(Units(shared.b))
    \* A finalize counts the cell (allocate-black bit + live_bytes) when the
    \* phase it read is not Idle (initObjectHeaderWithSize :497, finalizePoppedCellW
    \* :1075); the fix candidate count_until_shrink also counts while deferred.
    Counts(p) == p # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred)
    \* maybeShrinkCapacity pass 1 (:5796-5810): fully swept, live_bytes 0, not
    \* large, not granted (unless shrink_ignores_tenure). Current blocks are NOT skipped.
    ShrinkCands(lb) == {b \in Present : swept[b] /\ lb[b] = 0 /\ b \notin released
                          /\ ~(b = GrantBlock /\ grantOn /\ "shrink_ignores_tenure" \notin MUTANT)}
    \* allocateFromEmptyRegularBlocks (:2665-2680): as pass 1, but it skips the
    \* Current (shared) block during a parallel minor and a granted block.
    FlipCands == {b \in Present : swept[b] /\ liveBytes[b] = 0 /\ b \notin released
                   /\ b # shared.b
                   /\ ~(b = GrantBlock /\ grantOn /\ "flip_ignores_tenure" \notin MUTANT)}
    \* ---- the race detector ----
    \* Access x by thread t (clock tv) races with a recorded access a of another
    \* thread if one is plain, one writes, and t has not heard of a's point of a.t.
    \* The clock is passed in: pcal does not prime variables inside define (primer rule 13).
    Conflicts(t, tv, x) == \E a \in hist[x.l] : a.t # t /\ (a.p \/ x.p) /\ (a.w \/ x.w)
                                                  /\ a.c > tv[a.t]
    \* Keep only the LATEST access of each (thread, plain, write) kind: an older
    \* one has a smaller clock, so it races only if the latest one does.
    Recorded(t, tv, loc, S) ==
        LET mine == {x \in S : x.l = loc} IN
        {a \in hist[loc] : ~\E x \in mine : a.t = t /\ a.p = x.p /\ a.w = x.w}
          \cup {[t |-> t, c |-> tv[t], p |-> x.p, w |-> x.w] : x \in mine}
    \* ---- properties (plan §4.7; ids in MAPPING.md §5) ----
    NoRaceBitmap == races \cap Bytes = {}
    NoRacePhase  == "phase" \notin races
    NoRaceLive   == "live" \notin races
    NoDoubleAlloc   == \A c \in Cells : allocs[c] <= 1
    NoOverwriteLive == \A c \in T0Live : allocs[c] = 0
    \* M7's release contract: nothing still refers to a released block.
    ReleasedSafe == \A b \in released :
                        /\ \A c \in Allocated : BlkOf(c) # b
                        /\ \A w \in Threads : \A c \in chunk[w] \cup stash[w] : BlkOf(c) # b
                        /\ ~(b = GrantBlock /\ grantOn)
    \* HEAP_055's premise: nothing allocates into an unswept block. No free,
    \* stashed or chunk cell lies ahead of the sweep cursor.
    FreeBehindCursor ==
        \A c \in Range(freeList) \cup UNION {stash[w] \cup chunk[w] : w \in Threads} :
            ~\E i \in 1..Len(sweepQ) : c \in Range(sweepQ[i].g) \/ c = sweepQ[i].l
    ClaimsInRange == \A x \in claimed : x[2] <= Len(Units(x[1]))
    IM13 == \A w \in Workers : chunk[w] \cap T0Cells = {}
    TV5  == grantOn => (GrantBlock # CursorBlock /\ GrantBlock \notin T0Blocks)
    \* The FATALs, as named invariants (never PlusCal asserts):
    DetachNotCurrent == "detach" \notin fatal       \* detachFromAllocation :712-717
    NoGrantAtT0      == "grantAtT0" \notin fatal    \* resetAllocCursors :684-689
end define;

\* The accesses in the set S, made by self in one step: record a race for each
\* one that conflicts with an unordered earlier access, then log them. Use at
\* most once per step, and textually BEFORE any assignment to vc in the step.
macro Acc(S) begin
    races := races \cup {ax.l : ax \in {ay \in S : Conflicts(self, vc[self], ay)}};
    hist := [loc \in Locs |-> Recorded(self, vc[self], loc, S)];
end macro;

\* promo_mu_ (a minorwork::SpinMutex): acquire joins the releaser's clock.
macro LockAcquire() begin
    await lock = 0;
    lock := self;
    vc[self] := [u \in Threads |-> Max(vc[self][u], lockvc[u])];
end macro;

macro LockRelease() begin
    lock := 0;
    lockvc := vc[self];
    vc[self][self] := vc[self][self] + 1;
end macro;

\* claimChunkW's successful compare_exchange on shared[cls] (acq_rel RMW).
macro SharedCAS() begin
    sharedvc := [u \in Threads |-> Max(vc[self][u], sharedvc[u])];
    vc[self] := [u \in Threads |-> IF u = self THEN vc[self][u] + 1
                                   ELSE Max(vc[self][u], sharedvc[u])];
end macro;

\* cursorAllocateW (:1146): the next free cell of my chunk, or its exhaustion.
\* The setBit's plain load is taken with the read that found the cell (A1:
\* the store is the next step).
macro Rung1() begin
    if chunk[self] # {} /\ pos \in chunk[self] /\ pos \notin bits[ByteOf(pos)] then
        \* fast path: the next cell's own byte (:1150)
        cell := pos;
        seen := bits[ByteOf(pos)];
        Acc({Acc1(ByteOf(pos), TRUE, FALSE)});
        goto W_R1Set;
    elsif FreeIn(chunk[self], pos, bits) # {} then
        \* bitscan::nextFreeCell (:1155): plain WORD reads from pos to the free cell
        with c = MinOf(FreeIn(chunk[self], pos, bits)) do
            cell := c;
            seen := bits[ByteOf(c)];
            Acc(ScanRd(chunk[self], pos, c));
        end with;
        goto W_R1Set;
    else
        \* exhausted (or no cursor): nextFreeCell's last scan, then flushCursorW
        \* (:1161, atomic fetch_add :1033) and the cursor emptied
        if chunk[self] # {} /\ chunkLive[self] > 0 then
            liveBytes[BlkOf(AnyOf(chunk[self]))] :=
                liveBytes[BlkOf(AnyOf(chunk[self]))] + chunkLive[self];
            Acc(ScanRd(chunk[self], pos, pos) \cup {Acc1("live", FALSE, TRUE)});
        elsif chunk[self] # {} then
            Acc(ScanRd(chunk[self], pos, pos));
        end if;
        chunk[self] := {};
        chunkLive[self] := 0;
        goto W_Claim;
    end if;
end macro;

\* ladderFrom2W (:1306) after advanceSharedW and the batch pop found nothing:
\* hasPendingSweepWork() reads gc_phase_ under the lock (:1336).
macro Ladder() begin
    Acc({Acc1("phase", PhasePlain, FALSE)});
    if phase = "Sweeping" /\ sweepQ # <<>> then
        either
            goto W_Sweep;                         \* sweepOnDemandAllocate (:2136)
        or
            await Breadth;                        \* a virgin block or a split first (:1326-1335)
            n := n + 1;
            other := FALSE;
            LockRelease();
            goto W_Loop;
        end either;
    elsif other then
        n := n + 1;                               \* the other class: virgin / bag rungs, outside the model
        other := FALSE;
        LockRelease();
        goto W_Loop;
    else
        goto W_Virgin;                            \* virgin (:1345), then bag and panic rungs
    end if;
end macro;

\* finalizePoppedCellW (:1069): the colour decision is a plain read of
\* gc_phase_ (:1075); the bit and live_bytes follow in the next step.
macro FinPhase(fc) begin
    Acc({Acc1("phase", PhasePlain, FALSE)});
    if Counts(phase) then
        cell := fc;
        ph := phase;
        fin := 0;
        goto W_StBit;
    else
        \* Idle: a White header, no bit, no live_bytes
        allocs[fc] := allocs[fc] + 1;
        stash[self] := stash[self] \ {fc};
        n := n + 1;
        fin := 0;
        if lock = self then goto W_StUnlock; else goto W_Loop; end if;
    end if;
end macro;

\* =========================================================================
\* Parallel-minor promotion worker (allocatePromotion, OldGenSpace.cpp:1536).
\* =========================================================================
fair process Worker \in Workers
variables n = 0,           \* promotions done
          cell = 0,        \* the cell being allocated, finalized or swept
          seen = {},       \* the byte value a plain RMW loaded
          ph = "Idle",     \* the phase a stash finalize read
          pos = 0,         \* the cursor's next_cell
          fin = 0,         \* the first popped cell, finalized right after the unlock
          other = FALSE,   \* this promotion is of the other size class
          lastE = "none";  \* the block the last sweep iteration finished ("none")
begin
  W_Loop:
    if n < NAllocs[self] then
        either
            Rung1();                              \* a promotion of the modelled size class
        or
            \* a promotion of the other size class: its cursor, chunks, stash and
            \* free list are outside the model
            await TwoClasses;
            either
                await Breadth;                    \* lock-free: its colour read of gc_phase_
                Acc({Acc1("phase", PhasePlain, FALSE)});
                n := n + 1;
                goto W_Loop;
            or
                await Breadth;                    \* the same with a flushCursorW on the way
                Acc({Acc1("phase", PhasePlain, FALSE), Acc1("live", FALSE, TRUE)});
                n := n + 1;
                goto W_Loop;
            or
                LockAcquire();                    \* its rungs 1-2 are exhausted: the ladder
                other := TRUE;
                goto W_LadderB;
            end either;
        or
            \* a promotion of exactly alloc_buffer_size bytes (CR-016's precondition)
            await "large_promo" \in MUTANT;
            LockAcquire();
            goto W_Large;
        end either;
    else
        goto Done;
    end if;
  W_R1:                                         \* cursorAllocateW after a successful claim
    Rung1();
  W_R1Set:                                      \* bitscan::setBit (:1131): the plain store (IM13)
    bits[ByteOf(cell)] := seen \cup {cell};
    Acc({Acc1(ByteOf(cell), TRUE, TRUE)});
    allocs[cell] := allocs[cell] + 1;
    chunkLive[self] := chunkLive[self] + 1;
    pos := NextPos(chunk[self], cell);
    seen := {};
  W_R1Ph:                                       \* finalizeBitmapCellW's colour (:1135): plain read
    Acc({Acc1("phase", PhasePlain, FALSE)});
    if phase = "Marking" then need := need \cup {cell}; end if;
    n := n + 1;
    cell := 0;
    if lock = self then LockRelease(); end if;    \* the refill's allocation ends the hold
    goto W_Loop;
  W_Claim:                                      \* claimChunkW (:1171), lock-free or inside the refill
    if CanClaim then
        \* one CAS takes k units; the chunk's end is clamped to the block
        with k \in ClaimK,
             ch = UNION {Units(shared.b)[j] : j \in (shared.u + 1)..Min(shared.u + k, Len(Units(shared.b)))} do
            SharedCAS();
            chunk[self] := ch;
            pos := MinOf(ch);
            claimed := claimed \cup {<<shared.b, shared.u + 1>>};
            shared.u := shared.u + k;
        end with;
        goto W_R1;
    elsif "claim_after_exhaustion" \in MUTANT /\ shared.b # "none" /\ PastEnd[shared.b] # {} then
        SharedCAS();
        chunk[self] := PastEnd[shared.b];
        pos := MinOf(PastEnd[shared.b]);
        claimed := claimed \cup {<<shared.b, shared.u + 1>>};
        shared.u := shared.u + 1;
        goto W_R1;
    else
        \* a failed claim: its acquire load of the shared word
        vc[self] := [u \in Threads |-> Max(vc[self][u], sharedvc[u])];
        if lock = self then goto W_Locked; else goto W_Stash; end if;
    end if;
  W_Stash:                                      \* rung 2 cached (:1580-1583): a stashed cell
    if stash[self] # {} /\ "finalize_in_lock" \notin MUTANT then
        with x \in stash[self] do                 \* the stash's LIFO order is abstracted
            FinPhase(x);
        end with;
    elsif stash[self] # {} then
        LockAcquire();                            \* fix candidate: finalize under promo_mu_
        goto W_StLk;
    else
        LockAcquire();                            \* :1587
        goto W_Locked;
    end if;
  W_StLk:
    with x \in stash[self] do
        FinPhase(x);
    end with;
  W_StBit:                                      \* setMarkBitAtomic (:1083) + live_bytes fetch_add (:1084)
    if "plain_stash_black" \in MUTANT then
        seen := bits[ByteOf(cell)];               \* a plain set: the load ...
        Acc({Acc1(ByteOf(cell), TRUE, FALSE)});
        goto W_StPlainSet;
    else
        bits[ByteOf(cell)] := bits[ByteOf(cell)] \cup {cell};
        liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
        Acc({Acc1(ByteOf(cell), FALSE, TRUE), Acc1("live", FALSE, TRUE)});
        if ph = "Marking" then need := need \cup {cell}; end if;
        allocs[cell] := allocs[cell] + 1;
        stash[self] := stash[self] \ {cell};
        n := n + 1;
        cell := 0;
        ph := "Idle";
        if lock = self then goto W_StUnlock; else goto W_Loop; end if;
    end if;
  W_StPlainSet:                                 \* ... then the plain store
    bits[ByteOf(cell)] := seen \cup {cell};
    liveBytes[BlkOf(cell)] := liveBytes[BlkOf(cell)] + 1;
    Acc({Acc1(ByteOf(cell), TRUE, TRUE), Acc1("live", FALSE, TRUE)});
    if ph = "Marking" then need := need \cup {cell}; end if;
    allocs[cell] := allocs[cell] + 1;
    stash[self] := stash[self] \ {cell};
    n := n + 1;
    cell := 0;
    seen := {};
    ph := "Idle";
    if lock = self then goto W_StUnlock; else goto W_Loop; end if;
  W_StUnlock:                                   \* finalize_in_lock only
    LockRelease();
    goto W_Loop;
  W_Locked:                                     \* under promo_mu_ (:1587-1631)
    if CanClaim then
        goto W_Claim;                             \* advanceSharedW: another worker advanced already
    elsif partialQ # <<>> then
        \* advanceSharedW (:1219): retire the exhausted block, publishShared (:1201,
        \* a release store) the next queued one; then claim inside the lock
        shared := [b |-> Head(partialQ), u |-> 0];
        partialQ := Tail(partialQ);
        sharedvc := vc[self];
        vc[self][self] := vc[self][self] + 1;
        goto W_Claim;
    elsif freeList # <<>> then
        \* retire the exhausted block (relaxed store 0, :1227); rung 2 in a batch
        \* (:1617-1624): 1 + up to BatchMax - 1 more cells (1 + 16 in the code)
        shared := [b |-> "none", u |-> 0];
        sharedvc := Zero;
        with h = Head(freeList), k = Min(BatchMax, Len(freeList)) do
            stash[self] := stash[self] \cup Range(SubSeq(freeList, 1, k));
            freeList := SubSeq(freeList, k + 1, Len(freeList));
            fin := h;
            if "finalize_in_lock" \in MUTANT then
                goto W_Fin;                       \* fix candidate: finalized before the unlock
            else
                LockRelease();                    \* finalized right after the unlock (:1634)
                goto W_Fin;
            end if;
        end with;
    else
        \* retire the exhausted block (relaxed store 0); ladderFrom2W
        shared := [b |-> "none", u |-> 0];
        sharedvc := Zero;
        Ladder();
    end if;
  W_LadderB:                                    \* the other class: its advance and rung 2 find nothing
    Ladder();
  W_Fin:                                        \* the first popped cell (finalizePoppedCellW)
    FinPhase(fin);
  W_Sweep:                                      \* lazySweep's gap sweep (:5331-5369): one iteration
    freeList := Head(sweepQ).g \o freeList;       \* flushRun (:5359): pushed at the HEAD
    if Head(sweepQ).l = 0 then                    \* a trailing run: the block boundary (:5423)
        swept[Head(sweepQ).e] := TRUE;            \* markBlockFullySwept
        lastE := Head(sweepQ).e;
        sweepQ := Tail(sweepQ);
        goto W_SweepEnd;
    else
        cell := Head(sweepQ).l;
        seen := bits[ByteOf(Head(sweepQ).l)];     \* (clearBit's load)
        Acc(WordRd(ByteOf(Head(sweepQ).l)));      \* nextSetBit (:5339): a plain WORD read
        sweepQ := <<[Head(sweepQ) EXCEPT !.g = <<>>]>> \o Tail(sweepQ);   \* the cursor passed the gap
    end if;
  W_SweepClr:                                   \* bitscan::clearBit (:5360): the plain store
    bits[ByteOf(cell)] := seen \ {cell};
    Acc({Acc1(ByteOf(cell), TRUE, TRUE)});
    if Head(sweepQ).e # "none" then swept[Head(sweepQ).e] := TRUE; end if;   \* markBlockFullySwept
    lastE := Head(sweepQ).e;
    sweepQ := Tail(sweepQ);
    cell := 0;
    seen := {};
  W_SweepEnd:
    \* After an iteration. Inside a block only the budget ends the slice (:5336).
    \* At a block boundary lazySweep returns early when the target class's list
    \* is non-empty (:5452-5460): for my class that is freeList, for the other
    \* class a list outside the model (either way). After the last block, with
    \* no early exit: the in-loop completion when budget is left (:5244-5255),
    \* the tail completion when it ran out (:5467-5472).
    with le = lastE do
        lastE := "none";
        if sweepQ = <<>> then
            if ~other /\ freeList # <<>> then
                skip;                             \* early exit: gc_phase_ stays Sweeping
            else
                either
                    await other;
                    skip;                         \* early exit (the other class's list)
                or
                    phase := "Idle";              \* completion: a plain write under the lock
                    Acc({Acc1("phase", PhasePlain, TRUE)});
                    either
                        deferred := TRUE;         \* in-loop path: sweepCompleteInPromotion (:1361)
                    or
                        await "tail_defers" \notin MUTANT;   \* tail path: onSweepComplete NOW
                        goto W_Shrink;
                    end either;
                end either;
            end if;
        elsif le # "none" /\ ~other /\ freeList # <<>> then
            skip;                                 \* a block boundary: early exit
        else
            either goto W_Sweep; or skip; end either;   \* the budget may end the slice here
        end if;
    end with;
  W_PopAfterSweep:                              \* tryAllocateFromFreeLists (:2039) after the slice
    if ~other /\ freeList # <<>> then
        \* finalizePoppedCell -> initObjectHeaderWithSize (:487), under the lock
        with c = Head(freeList) do
            freeList := Tail(freeList);
            if Counts(phase) then
                bits[ByteOf(c)] := bits[ByteOf(c)] \cup {c};
                liveBytes[BlkOf(c)] := liveBytes[BlkOf(c)] + 1;
                Acc({Acc1("phase", PhasePlain, FALSE), Acc1(ByteOf(c), FALSE, TRUE),
                     Acc1("live", FALSE, TRUE)});
                if phase = "Marking" then need := need \cup {c}; end if;
            else
                Acc({Acc1("phase", PhasePlain, FALSE)});
            end if;
            allocs[c] := allocs[c] + 1;
        end with;
        n := n + 1;
        other := FALSE;
        LockRelease();
        goto W_Loop;
    elsif other then
        \* the other class: the flushed cells are not its class; a cell of its
        \* own class (or its virgin / bag rungs), outside the model
        n := n + 1;
        other := FALSE;
        LockRelease();
        goto W_Loop;
    else
        goto W_Virgin;                            \* no cell of my class: the ladder goes on
    end if;
  W_Virgin:                                     \* virgin() (:1345): startVirginBlockShared, still locked
    if virginQ # <<>> then
        \* a fresh block (fully swept, live_bytes 0) becomes the shared block:
        \* publishShared's release store; the claim and the allocation follow
        \* inside the lock (:1316-1320)
        shared := [b |-> Head(virginQ), u |-> 0];
        virginQ := Tail(virginQ);
        sharedvc := vc[self];
        vc[self][self] := vc[self][self] + 1;
        goto W_Claim;
    else
        n := n + 1;                               \* the bag or panic rung: a cell outside the model
        LockRelease();
        goto W_Loop;
    end if;
  W_Shrink:                                     \* the tail path's onSweepComplete (:5488) on this worker
    with rel \in SUBSET ShrinkCands(liveBytes) do   \* the sizing picks any subset
        \* releaseBlockToAllocator -> detachFromAllocation: FATAL on a Current
        \* block during a parallel minor (:712-717, every build)
        if shared.b \in rel then fatal := fatal \cup {"detach"}; end if;
        released := released \cup rel;
        freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel);
        partialQ := SelectSeq(partialQ, LAMBDA b : b \notin rel);
    end with;
    Acc({Acc1("live", TRUE, FALSE)});             \* computeFragmentationStats :6378, pass 1 :5802
    goto W_PopAfterSweep;
  W_Large:                                      \* allocateLargeBlock (:2725) under the lock (:1542-1553)
    with f \in FlipCands \cup {"none"} do          \* "none": a free large block or a fresh one
        if f # "none" then
            released := released \cup {f};        \* flipped to large; its cells are dropped
            freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) # f);
            partialQ := SelectSeq(partialQ, LAMBDA x : x # f);
            Acc({Acc1("live", TRUE, TRUE)});      \* plain reads, then live_bytes = size
        else
            Acc({Acc1("live", TRUE, FALSE)});
        end if;
    end with;
    n := n + 1;
    LockRelease();
    goto W_Loop;
end process;

\* =========================================================================
\* Background marker (testAndSetMark<ParallelMark>, OldGenSpace.cpp:3039):
\* a relaxed fetch_or of the bits of t0 objects.
\* =========================================================================
fair process Marker \in Markers
variables todo = MarkerTodo;
begin
  K_Loop:
    while todo # {} do
        with c \in todo do
            bits[ByteOf(c)] := bits[ByteOf(c)] \cup {c};
            Acc({Acc1(ByteOf(c), FALSE, TRUE)});
            marked := marked \cup {c};
            todo := todo \ {c};
        end with;
    end while;
end process;

\* =========================================================================
\* The merge after the gang join (endParallelPromotion, OldGenSpace.cpp:1416).
\* The background markers keep running: they are not joined.
\* =========================================================================
fair process Merge \in Mergers
begin
  G_Join:                                       \* join; flushCursorW (:1422); stash return (:1440)
    await \A w \in Workers : pc[w] = "Done";
    vc[self] := JoinVC(vc, Workers \cup {self});
    liveBytes := [b \in Blocks |-> liveBytes[b] + FlushSum(Workers, b, chunk, chunkLive)];
    freeList := SetToSeqAny(UNION {stash[w] : w \in Workers}) \o freeList;
    stash := [w \in Threads |-> {}];
    chunk := [w \in Threads |-> {}];
    chunkLive := [w \in Threads |-> 0];
    shared := [b |-> "none", u |-> 0];
  G_Shrink:                                     \* the deferred onSweepComplete (:1530-1533)
    if deferred then
        with rel \in SUBSET ShrinkCands(liveBytes) do
            released := released \cup rel;
            freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel);
            partialQ := SelectSeq(partialQ, LAMBDA b : b \notin rel);
        end with;
        deferred := FALSE;
    end if;
end process;

\* =========================================================================
\* 7c tenure collector in its grant: grantAllocate (OldGenTenure.cpp:153)
\* with one member; grantAllocateShared (:197) with two (L3).
\* =========================================================================
fair process Collector \in Collectors
variables gcell = 0,     \* the cell being allocated
          gseen = {},    \* the byte value setBit loaded
          gpos = MinOf(CellsOf(GrantBlock)),   \* the cursor's next_cell
          gch = {},      \* L3: this member's chunk of the grant
          gk = 0;        \* L3 mutant grant_claim_plain: the claim word it loaded
begin
  C_Loop:
    while gwork > 0 do
        gwork := gwork - 1;                       \* take a survivor to copy (M5's domain)
        if ~L3 then
            if \E x \in CellsOf(GrantBlock) : x >= gpos /\ x \notin bits[ByteOf(x)] then
                with c = MinOf({x \in CellsOf(GrantBlock) : x >= gpos /\ x \notin bits[ByteOf(x)]}) do
                    gcell := c;
                    gseen := bits[ByteOf(c)];
                    if c = gpos then
                        Acc({Acc1(ByteOf(c), TRUE, FALSE)});   \* fast path: the next cell's byte
                    else
                        Acc(ScanRd(CellsOf(GrantBlock), gpos, c));   \* nextFreeCell: word reads
                    end if;
                end with;
            else
                goto Done;                        \* the grant is exhausted (sizing: grantFatal)
            end if;
        elsif FreeIn(gch, gpos, bits) # {} then
            with c = MinOf(FreeIn(gch, gpos, bits)) do
                gcell := c;
                gseen := bits[ByteOf(c)];
                Acc(ScanRd(gch, gpos, c));        \* grantAllocateShared's nextFreeCell
            end with;
        elsif gclaim < Len(GrantUnits) /\ "grant_claim_plain" \in MUTANT then
            gk := gclaim;                         \* mutant: a plain load of the claim word ...
            goto C_ClaimStore;
        elsif gclaim < Len(GrantUnits) then
            \* claim the next chunk: a RELAXED CAS on claim[cls] (:245-249), no sync
            gch := GrantUnits[gclaim + 1];
            gpos := MinOf(GrantUnits[gclaim + 1]);
            gclaim := gclaim + 1;
            goto C_Claimed;                       \* (the survivor is copied next step)
        else
            goto Done;
        end if;
      C_Set:                                    \* bitscan::setBit (:177, :214): the plain store
        bits[ByteOf(gcell)] := gseen \cup {gcell};
        Acc({Acc1(ByteOf(gcell), TRUE, TRUE)});
        allocs[gcell] := allocs[gcell] + 1;
        if T0Blocks # {} then need := need \cup {gcell}; end if;   \* a copy mid-cycle is black
        grantLive := grantLive + 1;
        gpos := gcell + 1;
        gcell := 0;
        gseen := {};
    end while;
    goto Done;
  C_ClaimStore:                                 \* ... and a plain store: two members can claim one unit
    gch := GrantUnits[gk + 1];
    gpos := MinOf(GrantUnits[gk + 1]);
    gclaim := gk + 1;
    gk := 0;
  C_Claimed:                                    \* L3: allocate in the chunk just claimed
    with c = MinOf(FreeIn(gch, gpos, bits)) do
        gcell := c;
        gseen := bits[ByteOf(c)];
        Acc(ScanRd(gch, gpos, c));
    end with;
    goto C_Set;
end process;

\* =========================================================================
\* The mutator between two minors (7c epoch), then the next minor's start.
\* =========================================================================
fair process Mutator \in Mutators
variables mcell = 0, mseen = {};
begin
  U_Cursor:                                     \* cursorAllocate -> finalizeBitmapCell (:802)
    if \E x \in CellsOf(CursorBlock) : x \notin bits[ByteOf(x)] then
        with c = MinOf({x \in CellsOf(CursorBlock) : x \notin bits[ByteOf(x)]}) do
            mcell := c;
            mseen := bits[ByteOf(c)];
            Acc(WordRd(ByteOf(c)));               \* nextFreeCell / the fast path's byte
        end with;
    else
        goto U_Pop;
    end if;
  U_CursorSet:                                  \* bitscan::setBit (:820): the plain store
    bits[ByteOf(mcell)] := mseen \cup {mcell};
    Acc({Acc1(ByteOf(mcell), TRUE, TRUE)});
    allocs[mcell] := allocs[mcell] + 1;
    if phase = "Marking" then need := need \cup {mcell}; end if;
    mcell := 0;
    mseen := {};
  U_Pop:                                        \* tryAllocateFromFreeLists -> initObjectHeaderWithSize
    if freeList # <<>> then
        with c = Head(freeList) do
            freeList := Tail(freeList);
            if phase # "Idle" /\ "plain_allocate_black" \in MUTANT then
                mcell := c;
                mseen := bits[ByteOf(c)];         \* test_plain_allocate_black_ (:515): the load ...
                Acc({Acc1(ByteOf(c), TRUE, FALSE)});
                goto U_PopPlainSet;
            elsif phase # "Idle" then
                bits[ByteOf(c)] := bits[ByteOf(c)] \cup {c};   \* setMarkBitAtomic (:518)
                liveBytes[BlkOf(c)] := liveBytes[BlkOf(c)] + 1;
                Acc({Acc1(ByteOf(c), FALSE, TRUE), Acc1("live", FALSE, TRUE)});
                if phase = "Marking" then need := need \cup {c}; end if;
                allocs[c] := allocs[c] + 1;
                goto U_Sweep;
            else
                allocs[c] := allocs[c] + 1;
                goto U_Sweep;
            end if;
        end with;
    else
        goto U_Sweep;
    end if;
  U_PopPlainSet:                                \* ... then the plain store
    bits[ByteOf(mcell)] := mseen \cup {mcell};
    liveBytes[BlkOf(mcell)] := liveBytes[BlkOf(mcell)] + 1;
    Acc({Acc1(ByteOf(mcell), TRUE, TRUE), Acc1("live", FALSE, TRUE)});
    if phase = "Marking" then need := need \cup {mcell}; end if;
    allocs[mcell] := allocs[mcell] + 1;
    mcell := 0;
    mseen := {};
  U_Sweep:                                      \* allocate()'s lazy-sweep slice: one iteration
    if phase = "Sweeping" /\ sweepQ # <<>> then
        freeList := Head(sweepQ).g \o freeList;
        mcell := Head(sweepQ).l;
        mseen := bits[ByteOf(Head(sweepQ).l)];
        Acc(WordRd(ByteOf(Head(sweepQ).l)));
        sweepQ := <<[Head(sweepQ) EXCEPT !.g = <<>>]>> \o Tail(sweepQ);
    else
        goto U_Large;
    end if;
  U_SweepClr:
    bits[ByteOf(mcell)] := mseen \ {mcell};
    Acc({Acc1(ByteOf(mcell), TRUE, TRUE)});
    if Head(sweepQ).e # "none" then swept[Head(sweepQ).e] := TRUE; end if;
    sweepQ := Tail(sweepQ);
    mcell := 0;
    mseen := {};
  U_SweepDone:                                  \* completion: onSweepComplete's light shrink
    phase := "Idle";
    \* syncCursorLiveBytes makes the cursor block's live_bytes exact (it holds a cell)
    with rel \in SUBSET (ShrinkCands(liveBytes) \ {CursorBlock}) do
        released := released \cup rel;
        freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel);
    end with;
    Acc({Acc1("live", TRUE, FALSE)});
  U_Large:                                      \* allocate() of exactly a block's size (:1931-1933)
    if "large_promo" \in MUTANT then
        with f \in (FlipCands \ {CursorBlock}) \cup {"none"} do
            if f # "none" then
                released := released \cup {f};
                freeList := SelectSeq(freeList, LAMBDA x : BlkOf(x) # f);
                Acc({Acc1("live", TRUE, TRUE)});
            else
                Acc({Acc1("live", TRUE, FALSE)});
            end if;
        end with;
    end if;
  U_Pause:                                      \* ThreadLocalHeap::minorGC (:706-743)
    if "launch_before_t0" \in MUTANT then goto U_T0; end if;
  U_Join:                                       \* tenureJoin + returnTenureGrant (OldGenTenure.cpp:288)
    await \A x \in Collectors : pc[x] = "Done";
    vc[self] := JoinVC(vc, Collectors \cup {self});
    liveBytes[GrantBlock] := liveBytes[GrantBlock] + grantLive;
    grantOn := FALSE;
  U_T0:                                         \* a cycle start: resetAllocCursors' FATAL (:684-689)
    if grantOn then fatal := fatal \cup {"grantAtT0"}; end if;
  U_After:                                      \* the returned block is an allocation map again
    if \E x \in CellsOf(GrantBlock) : x \notin bits[ByteOf(x)] then
        with x = MinOf({y \in CellsOf(GrantBlock) : y \notin bits[ByteOf(y)]}) do
            bits[ByteOf(x)] := bits[ByteOf(x)] \cup {x};
            allocs[x] := allocs[x] + 1;
        end with;
    end if;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, bits, freeList, sweepQ, phase, liveBytes, swept, deferred, 
          shared, partialQ, virginQ, lock, chunk, chunkLive, stash, released, 
          grantOn, grantLive, gclaim, gwork, fatal, allocs, need, marked, 
          claimed, vc, lockvc, sharedvc, hist, races

(* define statement *)
Allocated  == {c \in Cells : allocs[c] > 0}
PhasePlain == "phase_atomic" \notin MUTANT
SetBits    == UNION {bits[y] : y \in Bytes}
CanClaim   == shared.b # "none" /\ shared.u < Len(Units(shared.b))



Counts(p) == p # "Idle" \/ ("count_until_shrink" \in MUTANT /\ deferred)


ShrinkCands(lb) == {b \in Present : swept[b] /\ lb[b] = 0 /\ b \notin released
                      /\ ~(b = GrantBlock /\ grantOn /\ "shrink_ignores_tenure" \notin MUTANT)}


FlipCands == {b \in Present : swept[b] /\ liveBytes[b] = 0 /\ b \notin released
               /\ b # shared.b
               /\ ~(b = GrantBlock /\ grantOn /\ "flip_ignores_tenure" \notin MUTANT)}




Conflicts(t, tv, x) == \E a \in hist[x.l] : a.t # t /\ (a.p \/ x.p) /\ (a.w \/ x.w)
                                              /\ a.c > tv[a.t]


Recorded(t, tv, loc, S) ==
    LET mine == {x \in S : x.l = loc} IN
    {a \in hist[loc] : ~\E x \in mine : a.t = t /\ a.p = x.p /\ a.w = x.w}
      \cup {[t |-> t, c |-> tv[t], p |-> x.p, w |-> x.w] : x \in mine}

NoRaceBitmap == races \cap Bytes = {}
NoRacePhase  == "phase" \notin races
NoRaceLive   == "live" \notin races
NoDoubleAlloc   == \A c \in Cells : allocs[c] <= 1
NoOverwriteLive == \A c \in T0Live : allocs[c] = 0

ReleasedSafe == \A b \in released :
                    /\ \A c \in Allocated : BlkOf(c) # b
                    /\ \A w \in Threads : \A c \in chunk[w] \cup stash[w] : BlkOf(c) # b
                    /\ ~(b = GrantBlock /\ grantOn)


FreeBehindCursor ==
    \A c \in Range(freeList) \cup UNION {stash[w] \cup chunk[w] : w \in Threads} :
        ~\E i \in 1..Len(sweepQ) : c \in Range(sweepQ[i].g) \/ c = sweepQ[i].l
ClaimsInRange == \A x \in claimed : x[2] <= Len(Units(x[1]))
IM13 == \A w \in Workers : chunk[w] \cap T0Cells = {}
TV5  == grantOn => (GrantBlock # CursorBlock /\ GrantBlock \notin T0Blocks)

DetachNotCurrent == "detach" \notin fatal
NoGrantAtT0      == "grantAtT0" \notin fatal

VARIABLES n, cell, seen, ph, pos, fin, other, lastE, todo, gcell, gseen, gpos, 
          gch, gk, mcell, mseen

vars == << pc, bits, freeList, sweepQ, phase, liveBytes, swept, deferred, 
           shared, partialQ, virginQ, lock, chunk, chunkLive, stash, released, 
           grantOn, grantLive, gclaim, gwork, fatal, allocs, need, marked, 
           claimed, vc, lockvc, sharedvc, hist, races, n, cell, seen, ph, pos, 
           fin, other, lastE, todo, gcell, gseen, gpos, gch, gk, mcell, mseen
        >>

ProcSet == (Workers) \cup (Markers) \cup (Mergers) \cup (Collectors) \cup (Mutators)

Init == (* Global variables *)
        /\ bits = InitBits
        /\ freeList = InitFree
        /\ sweepQ = InitQ
        /\ phase = InitPhase
        /\ liveBytes = InitLive
        /\ swept = InitSwept
        /\ deferred = FALSE
        /\ shared = InitShared
        /\ partialQ = InitPartial
        /\ virginQ = VirginQ
        /\ lock = 0
        /\ chunk = [w \in Threads |-> {}]
        /\ chunkLive = [w \in Threads |-> 0]
        /\ stash = [w \in Threads |-> {}]
        /\ released = {}
        /\ grantOn = InitGrantOn
        /\ grantLive = 0
        /\ gclaim = 0
        /\ gwork = NGrant
        /\ fatal = {}
        /\ allocs = [c \in Cells |-> IF c \in PreAlloc THEN 1 ELSE 0]
        /\ need = {}
        /\ marked = {}
        /\ claimed = {}
        /\ vc = InitVC
        /\ lockvc = Zero
        /\ sharedvc = Zero
        /\ hist = [loc \in Locs |-> {}]
        /\ races = {}
        (* Process Worker *)
        /\ n = [self \in Workers |-> 0]
        /\ cell = [self \in Workers |-> 0]
        /\ seen = [self \in Workers |-> {}]
        /\ ph = [self \in Workers |-> "Idle"]
        /\ pos = [self \in Workers |-> 0]
        /\ fin = [self \in Workers |-> 0]
        /\ other = [self \in Workers |-> FALSE]
        /\ lastE = [self \in Workers |-> "none"]
        (* Process Marker *)
        /\ todo = [self \in Markers |-> MarkerTodo]
        (* Process Collector *)
        /\ gcell = [self \in Collectors |-> 0]
        /\ gseen = [self \in Collectors |-> {}]
        /\ gpos = [self \in Collectors |-> MinOf(CellsOf(GrantBlock))]
        /\ gch = [self \in Collectors |-> {}]
        /\ gk = [self \in Collectors |-> 0]
        (* Process Mutator *)
        /\ mcell = [self \in Mutators |-> 0]
        /\ mseen = [self \in Mutators |-> {}]
        /\ pc = [self \in ProcSet |-> CASE self \in Workers -> "W_Loop"
                                        [] self \in Markers -> "K_Loop"
                                        [] self \in Mergers -> "G_Join"
                                        [] self \in Collectors -> "C_Loop"
                                        [] self \in Mutators -> "U_Cursor"]

W_Loop(self) == /\ pc[self] = "W_Loop"
                /\ IF n[self] < NAllocs[self]
                      THEN /\ \/ /\ IF chunk[self] # {} /\ pos[self] \in chunk[self] /\ pos[self] \notin bits[ByteOf(pos[self])]
                                       THEN /\ cell' = [cell EXCEPT ![self] = pos[self]]
                                            /\ seen' = [seen EXCEPT ![self] = bits[ByteOf(pos[self])]]
                                            /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(pos[self]), TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                            /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(pos[self]), TRUE, FALSE)}))]
                                            /\ pc' = [pc EXCEPT ![self] = "W_R1Set"]
                                            /\ UNCHANGED << liveBytes, chunk, 
                                                            chunkLive >>
                                       ELSE /\ IF FreeIn(chunk[self], pos[self], bits) # {}
                                                  THEN /\ LET c == MinOf(FreeIn(chunk[self], pos[self], bits)) IN
                                                            /\ cell' = [cell EXCEPT ![self] = c]
                                                            /\ seen' = [seen EXCEPT ![self] = bits[ByteOf(c)]]
                                                            /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(chunk[self], pos[self], c)) : Conflicts(self, vc[self], ay)}})
                                                            /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(chunk[self], pos[self], c)))]
                                                       /\ pc' = [pc EXCEPT ![self] = "W_R1Set"]
                                                       /\ UNCHANGED << liveBytes, 
                                                                       chunk, 
                                                                       chunkLive >>
                                                  ELSE /\ IF chunk[self] # {} /\ chunkLive[self] > 0
                                                             THEN /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(AnyOf(chunk[self]))] = liveBytes[BlkOf(AnyOf(chunk[self]))] + chunkLive[self]]
                                                                  /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(chunk[self], pos[self], pos[self]) \cup {Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                                                  /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(chunk[self], pos[self], pos[self]) \cup {Acc1("live", FALSE, TRUE)}))]
                                                             ELSE /\ IF chunk[self] # {}
                                                                        THEN /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(chunk[self], pos[self], pos[self])) : Conflicts(self, vc[self], ay)}})
                                                                             /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(chunk[self], pos[self], pos[self])))]
                                                                        ELSE /\ TRUE
                                                                             /\ UNCHANGED << hist, 
                                                                                             races >>
                                                                  /\ UNCHANGED liveBytes
                                                       /\ chunk' = [chunk EXCEPT ![self] = {}]
                                                       /\ chunkLive' = [chunkLive EXCEPT ![self] = 0]
                                                       /\ pc' = [pc EXCEPT ![self] = "W_Claim"]
                                                       /\ UNCHANGED << cell, 
                                                                       seen >>
                                 /\ UNCHANGED <<lock, vc, n, other>>
                              \/ /\ TwoClasses
                                 /\ \/ /\ Breadth
                                       /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                       /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                                       /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                       /\ UNCHANGED <<lock, vc, other>>
                                    \/ /\ Breadth
                                       /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE), Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                       /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE), Acc1("live", FALSE, TRUE)}))]
                                       /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                       /\ UNCHANGED <<lock, vc, other>>
                                    \/ /\ lock = 0
                                       /\ lock' = self
                                       /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> Max(vc[self][u], lockvc[u])]]
                                       /\ other' = [other EXCEPT ![self] = TRUE]
                                       /\ pc' = [pc EXCEPT ![self] = "W_LadderB"]
                                       /\ UNCHANGED <<hist, races, n>>
                                 /\ UNCHANGED <<liveBytes, chunk, chunkLive, cell, seen>>
                              \/ /\ "large_promo" \in MUTANT
                                 /\ lock = 0
                                 /\ lock' = self
                                 /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> Max(vc[self][u], lockvc[u])]]
                                 /\ pc' = [pc EXCEPT ![self] = "W_Large"]
                                 /\ UNCHANGED <<liveBytes, chunk, chunkLive, hist, races, n, cell, seen, other>>
                      ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                           /\ UNCHANGED << liveBytes, lock, chunk, chunkLive, 
                                           vc, hist, races, n, cell, seen, 
                                           other >>
                /\ UNCHANGED << bits, freeList, sweepQ, phase, swept, deferred, 
                                shared, partialQ, virginQ, stash, released, 
                                grantOn, grantLive, gclaim, gwork, fatal, 
                                allocs, need, marked, claimed, lockvc, 
                                sharedvc, ph, pos, fin, lastE, todo, gcell, 
                                gseen, gpos, gch, gk, mcell, mseen >>

W_R1(self) == /\ pc[self] = "W_R1"
              /\ IF chunk[self] # {} /\ pos[self] \in chunk[self] /\ pos[self] \notin bits[ByteOf(pos[self])]
                    THEN /\ cell' = [cell EXCEPT ![self] = pos[self]]
                         /\ seen' = [seen EXCEPT ![self] = bits[ByteOf(pos[self])]]
                         /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(pos[self]), TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                         /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(pos[self]), TRUE, FALSE)}))]
                         /\ pc' = [pc EXCEPT ![self] = "W_R1Set"]
                         /\ UNCHANGED << liveBytes, chunk, chunkLive >>
                    ELSE /\ IF FreeIn(chunk[self], pos[self], bits) # {}
                               THEN /\ LET c == MinOf(FreeIn(chunk[self], pos[self], bits)) IN
                                         /\ cell' = [cell EXCEPT ![self] = c]
                                         /\ seen' = [seen EXCEPT ![self] = bits[ByteOf(c)]]
                                         /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(chunk[self], pos[self], c)) : Conflicts(self, vc[self], ay)}})
                                         /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(chunk[self], pos[self], c)))]
                                    /\ pc' = [pc EXCEPT ![self] = "W_R1Set"]
                                    /\ UNCHANGED << liveBytes, chunk, 
                                                    chunkLive >>
                               ELSE /\ IF chunk[self] # {} /\ chunkLive[self] > 0
                                          THEN /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(AnyOf(chunk[self]))] = liveBytes[BlkOf(AnyOf(chunk[self]))] + chunkLive[self]]
                                               /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(chunk[self], pos[self], pos[self]) \cup {Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                               /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(chunk[self], pos[self], pos[self]) \cup {Acc1("live", FALSE, TRUE)}))]
                                          ELSE /\ IF chunk[self] # {}
                                                     THEN /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(chunk[self], pos[self], pos[self])) : Conflicts(self, vc[self], ay)}})
                                                          /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(chunk[self], pos[self], pos[self])))]
                                                     ELSE /\ TRUE
                                                          /\ UNCHANGED << hist, 
                                                                          races >>
                                               /\ UNCHANGED liveBytes
                                    /\ chunk' = [chunk EXCEPT ![self] = {}]
                                    /\ chunkLive' = [chunkLive EXCEPT ![self] = 0]
                                    /\ pc' = [pc EXCEPT ![self] = "W_Claim"]
                                    /\ UNCHANGED << cell, seen >>
              /\ UNCHANGED << bits, freeList, sweepQ, phase, swept, deferred, 
                              shared, partialQ, virginQ, lock, stash, released, 
                              grantOn, grantLive, gclaim, gwork, fatal, allocs, 
                              need, marked, claimed, vc, lockvc, sharedvc, n, 
                              ph, pos, fin, other, lastE, todo, gcell, gseen, 
                              gpos, gch, gk, mcell, mseen >>

W_R1Set(self) == /\ pc[self] = "W_R1Set"
                 /\ bits' = [bits EXCEPT ![ByteOf(cell[self])] = seen[self] \cup {cell[self]}]
                 /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(cell[self]), TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                 /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(cell[self]), TRUE, TRUE)}))]
                 /\ allocs' = [allocs EXCEPT ![cell[self]] = allocs[cell[self]] + 1]
                 /\ chunkLive' = [chunkLive EXCEPT ![self] = chunkLive[self] + 1]
                 /\ pos' = [pos EXCEPT ![self] = NextPos(chunk[self], cell[self])]
                 /\ seen' = [seen EXCEPT ![self] = {}]
                 /\ pc' = [pc EXCEPT ![self] = "W_R1Ph"]
                 /\ UNCHANGED << freeList, sweepQ, phase, liveBytes, swept, 
                                 deferred, shared, partialQ, virginQ, lock, 
                                 chunk, stash, released, grantOn, grantLive, 
                                 gclaim, gwork, fatal, need, marked, claimed, 
                                 vc, lockvc, sharedvc, n, cell, ph, fin, other, 
                                 lastE, todo, gcell, gseen, gpos, gch, gk, 
                                 mcell, mseen >>

W_R1Ph(self) == /\ pc[self] = "W_R1Ph"
                /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                /\ IF phase = "Marking"
                      THEN /\ need' = (need \cup {cell[self]})
                      ELSE /\ TRUE
                           /\ need' = need
                /\ n' = [n EXCEPT ![self] = n[self] + 1]
                /\ cell' = [cell EXCEPT ![self] = 0]
                /\ IF lock = self
                      THEN /\ lock' = 0
                           /\ lockvc' = vc[self]
                           /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                      ELSE /\ TRUE
                           /\ UNCHANGED << lock, vc, lockvc >>
                /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                swept, deferred, shared, partialQ, virginQ, 
                                chunk, chunkLive, stash, released, grantOn, 
                                grantLive, gclaim, gwork, fatal, allocs, 
                                marked, claimed, sharedvc, seen, ph, pos, fin, 
                                other, lastE, todo, gcell, gseen, gpos, gch, 
                                gk, mcell, mseen >>

W_Claim(self) == /\ pc[self] = "W_Claim"
                 /\ IF CanClaim
                       THEN /\ \E k \in ClaimK:
                                 LET ch == UNION {Units(shared.b)[j] : j \in (shared.u + 1)..Min(shared.u + k, Len(Units(shared.b)))} IN
                                   /\ sharedvc' = [u \in Threads |-> Max(vc[self][u], sharedvc[u])]
                                   /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> IF u = self THEN vc[self][u] + 1
                                                                                    ELSE Max(vc[self][u], sharedvc'[u])]]
                                   /\ chunk' = [chunk EXCEPT ![self] = ch]
                                   /\ pos' = [pos EXCEPT ![self] = MinOf(ch)]
                                   /\ claimed' = (claimed \cup {<<shared.b, shared.u + 1>>})
                                   /\ shared' = [shared EXCEPT !.u = shared.u + k]
                            /\ pc' = [pc EXCEPT ![self] = "W_R1"]
                       ELSE /\ IF "claim_after_exhaustion" \in MUTANT /\ shared.b # "none" /\ PastEnd[shared.b] # {}
                                  THEN /\ sharedvc' = [u \in Threads |-> Max(vc[self][u], sharedvc[u])]
                                       /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> IF u = self THEN vc[self][u] + 1
                                                                                        ELSE Max(vc[self][u], sharedvc'[u])]]
                                       /\ chunk' = [chunk EXCEPT ![self] = PastEnd[shared.b]]
                                       /\ pos' = [pos EXCEPT ![self] = MinOf(PastEnd[shared.b])]
                                       /\ claimed' = (claimed \cup {<<shared.b, shared.u + 1>>})
                                       /\ shared' = [shared EXCEPT !.u = shared.u + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "W_R1"]
                                  ELSE /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> Max(vc[self][u], sharedvc[u])]]
                                       /\ IF lock = self
                                             THEN /\ pc' = [pc EXCEPT ![self] = "W_Locked"]
                                             ELSE /\ pc' = [pc EXCEPT ![self] = "W_Stash"]
                                       /\ UNCHANGED << shared, chunk, claimed, 
                                                       sharedvc, pos >>
                 /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                 swept, deferred, partialQ, virginQ, lock, 
                                 chunkLive, stash, released, grantOn, 
                                 grantLive, gclaim, gwork, fatal, allocs, need, 
                                 marked, lockvc, hist, races, n, cell, seen, 
                                 ph, fin, other, lastE, todo, gcell, gseen, 
                                 gpos, gch, gk, mcell, mseen >>

W_Stash(self) == /\ pc[self] = "W_Stash"
                 /\ IF stash[self] # {} /\ "finalize_in_lock" \notin MUTANT
                       THEN /\ \E x \in stash[self]:
                                 /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                 /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                                 /\ IF Counts(phase)
                                       THEN /\ cell' = [cell EXCEPT ![self] = x]
                                            /\ ph' = [ph EXCEPT ![self] = phase]
                                            /\ fin' = [fin EXCEPT ![self] = 0]
                                            /\ pc' = [pc EXCEPT ![self] = "W_StBit"]
                                            /\ UNCHANGED << stash, allocs, n >>
                                       ELSE /\ allocs' = [allocs EXCEPT ![x] = allocs[x] + 1]
                                            /\ stash' = [stash EXCEPT ![self] = stash[self] \ {x}]
                                            /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                            /\ fin' = [fin EXCEPT ![self] = 0]
                                            /\ IF lock = self
                                                  THEN /\ pc' = [pc EXCEPT ![self] = "W_StUnlock"]
                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                            /\ UNCHANGED << cell, ph >>
                            /\ UNCHANGED << lock, vc >>
                       ELSE /\ IF stash[self] # {}
                                  THEN /\ lock = 0
                                       /\ lock' = self
                                       /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> Max(vc[self][u], lockvc[u])]]
                                       /\ pc' = [pc EXCEPT ![self] = "W_StLk"]
                                  ELSE /\ lock = 0
                                       /\ lock' = self
                                       /\ vc' = [vc EXCEPT ![self] = [u \in Threads |-> Max(vc[self][u], lockvc[u])]]
                                       /\ pc' = [pc EXCEPT ![self] = "W_Locked"]
                            /\ UNCHANGED << stash, allocs, hist, races, n, 
                                            cell, ph, fin >>
                 /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                 swept, deferred, shared, partialQ, virginQ, 
                                 chunk, chunkLive, released, grantOn, 
                                 grantLive, gclaim, gwork, fatal, need, marked, 
                                 claimed, lockvc, sharedvc, seen, pos, other, 
                                 lastE, todo, gcell, gseen, gpos, gch, gk, 
                                 mcell, mseen >>

W_StLk(self) == /\ pc[self] = "W_StLk"
                /\ \E x \in stash[self]:
                     /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                     /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                     /\ IF Counts(phase)
                           THEN /\ cell' = [cell EXCEPT ![self] = x]
                                /\ ph' = [ph EXCEPT ![self] = phase]
                                /\ fin' = [fin EXCEPT ![self] = 0]
                                /\ pc' = [pc EXCEPT ![self] = "W_StBit"]
                                /\ UNCHANGED << stash, allocs, n >>
                           ELSE /\ allocs' = [allocs EXCEPT ![x] = allocs[x] + 1]
                                /\ stash' = [stash EXCEPT ![self] = stash[self] \ {x}]
                                /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                /\ fin' = [fin EXCEPT ![self] = 0]
                                /\ IF lock = self
                                      THEN /\ pc' = [pc EXCEPT ![self] = "W_StUnlock"]
                                      ELSE /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                /\ UNCHANGED << cell, ph >>
                /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                swept, deferred, shared, partialQ, virginQ, 
                                lock, chunk, chunkLive, released, grantOn, 
                                grantLive, gclaim, gwork, fatal, need, marked, 
                                claimed, vc, lockvc, sharedvc, seen, pos, 
                                other, lastE, todo, gcell, gseen, gpos, gch, 
                                gk, mcell, mseen >>

W_StBit(self) == /\ pc[self] = "W_StBit"
                 /\ IF "plain_stash_black" \in MUTANT
                       THEN /\ seen' = [seen EXCEPT ![self] = bits[ByteOf(cell[self])]]
                            /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(cell[self]), TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                            /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(cell[self]), TRUE, FALSE)}))]
                            /\ pc' = [pc EXCEPT ![self] = "W_StPlainSet"]
                            /\ UNCHANGED << bits, liveBytes, stash, allocs, 
                                            need, n, cell, ph >>
                       ELSE /\ bits' = [bits EXCEPT ![ByteOf(cell[self])] = bits[ByteOf(cell[self])] \cup {cell[self]}]
                            /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(cell[self])] = liveBytes[BlkOf(cell[self])] + 1]
                            /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(cell[self]), FALSE, TRUE), Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                            /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(cell[self]), FALSE, TRUE), Acc1("live", FALSE, TRUE)}))]
                            /\ IF ph[self] = "Marking"
                                  THEN /\ need' = (need \cup {cell[self]})
                                  ELSE /\ TRUE
                                       /\ need' = need
                            /\ allocs' = [allocs EXCEPT ![cell[self]] = allocs[cell[self]] + 1]
                            /\ stash' = [stash EXCEPT ![self] = stash[self] \ {cell[self]}]
                            /\ n' = [n EXCEPT ![self] = n[self] + 1]
                            /\ cell' = [cell EXCEPT ![self] = 0]
                            /\ ph' = [ph EXCEPT ![self] = "Idle"]
                            /\ IF lock = self
                                  THEN /\ pc' = [pc EXCEPT ![self] = "W_StUnlock"]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                            /\ seen' = seen
                 /\ UNCHANGED << freeList, sweepQ, phase, swept, deferred, 
                                 shared, partialQ, virginQ, lock, chunk, 
                                 chunkLive, released, grantOn, grantLive, 
                                 gclaim, gwork, fatal, marked, claimed, vc, 
                                 lockvc, sharedvc, pos, fin, other, lastE, 
                                 todo, gcell, gseen, gpos, gch, gk, mcell, 
                                 mseen >>

W_StPlainSet(self) == /\ pc[self] = "W_StPlainSet"
                      /\ bits' = [bits EXCEPT ![ByteOf(cell[self])] = seen[self] \cup {cell[self]}]
                      /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(cell[self])] = liveBytes[BlkOf(cell[self])] + 1]
                      /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(cell[self]), TRUE, TRUE), Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                      /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(cell[self]), TRUE, TRUE), Acc1("live", FALSE, TRUE)}))]
                      /\ IF ph[self] = "Marking"
                            THEN /\ need' = (need \cup {cell[self]})
                            ELSE /\ TRUE
                                 /\ need' = need
                      /\ allocs' = [allocs EXCEPT ![cell[self]] = allocs[cell[self]] + 1]
                      /\ stash' = [stash EXCEPT ![self] = stash[self] \ {cell[self]}]
                      /\ n' = [n EXCEPT ![self] = n[self] + 1]
                      /\ cell' = [cell EXCEPT ![self] = 0]
                      /\ seen' = [seen EXCEPT ![self] = {}]
                      /\ ph' = [ph EXCEPT ![self] = "Idle"]
                      /\ IF lock = self
                            THEN /\ pc' = [pc EXCEPT ![self] = "W_StUnlock"]
                            ELSE /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                      /\ UNCHANGED << freeList, sweepQ, phase, swept, deferred, 
                                      shared, partialQ, virginQ, lock, chunk, 
                                      chunkLive, released, grantOn, grantLive, 
                                      gclaim, gwork, fatal, marked, claimed, 
                                      vc, lockvc, sharedvc, pos, fin, other, 
                                      lastE, todo, gcell, gseen, gpos, gch, gk, 
                                      mcell, mseen >>

W_StUnlock(self) == /\ pc[self] = "W_StUnlock"
                    /\ lock' = 0
                    /\ lockvc' = vc[self]
                    /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                    /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                    /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                    swept, deferred, shared, partialQ, virginQ, 
                                    chunk, chunkLive, stash, released, grantOn, 
                                    grantLive, gclaim, gwork, fatal, allocs, 
                                    need, marked, claimed, sharedvc, hist, 
                                    races, n, cell, seen, ph, pos, fin, other, 
                                    lastE, todo, gcell, gseen, gpos, gch, gk, 
                                    mcell, mseen >>

W_Locked(self) == /\ pc[self] = "W_Locked"
                  /\ IF CanClaim
                        THEN /\ pc' = [pc EXCEPT ![self] = "W_Claim"]
                             /\ UNCHANGED << freeList, shared, partialQ, lock, 
                                             stash, vc, lockvc, sharedvc, hist, 
                                             races, n, fin, other >>
                        ELSE /\ IF partialQ # <<>>
                                   THEN /\ shared' = [b |-> Head(partialQ), u |-> 0]
                                        /\ partialQ' = Tail(partialQ)
                                        /\ sharedvc' = vc[self]
                                        /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                        /\ pc' = [pc EXCEPT ![self] = "W_Claim"]
                                        /\ UNCHANGED << freeList, lock, stash, 
                                                        lockvc, hist, races, n, 
                                                        fin, other >>
                                   ELSE /\ IF freeList # <<>>
                                              THEN /\ shared' = [b |-> "none", u |-> 0]
                                                   /\ sharedvc' = Zero
                                                   /\ LET h == Head(freeList) IN
                                                        LET k == Min(BatchMax, Len(freeList)) IN
                                                          /\ stash' = [stash EXCEPT ![self] = stash[self] \cup Range(SubSeq(freeList, 1, k))]
                                                          /\ freeList' = SubSeq(freeList, k + 1, Len(freeList))
                                                          /\ fin' = [fin EXCEPT ![self] = h]
                                                          /\ IF "finalize_in_lock" \in MUTANT
                                                                THEN /\ pc' = [pc EXCEPT ![self] = "W_Fin"]
                                                                     /\ UNCHANGED << lock, 
                                                                                     vc, 
                                                                                     lockvc >>
                                                                ELSE /\ lock' = 0
                                                                     /\ lockvc' = vc[self]
                                                                     /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                                                     /\ pc' = [pc EXCEPT ![self] = "W_Fin"]
                                                   /\ UNCHANGED << hist, races, 
                                                                   n, other >>
                                              ELSE /\ shared' = [b |-> "none", u |-> 0]
                                                   /\ sharedvc' = Zero
                                                   /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                                   /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                                                   /\ IF phase = "Sweeping" /\ sweepQ # <<>>
                                                         THEN /\ \/ /\ pc' = [pc EXCEPT ![self] = "W_Sweep"]
                                                                    /\ UNCHANGED <<lock, vc, lockvc, n, other>>
                                                                 \/ /\ Breadth
                                                                    /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                                                    /\ other' = [other EXCEPT ![self] = FALSE]
                                                                    /\ lock' = 0
                                                                    /\ lockvc' = vc[self]
                                                                    /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                                                    /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                                         ELSE /\ IF other[self]
                                                                    THEN /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                                                         /\ other' = [other EXCEPT ![self] = FALSE]
                                                                         /\ lock' = 0
                                                                         /\ lockvc' = vc[self]
                                                                         /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                                                         /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                                                    ELSE /\ pc' = [pc EXCEPT ![self] = "W_Virgin"]
                                                                         /\ UNCHANGED << lock, 
                                                                                         vc, 
                                                                                         lockvc, 
                                                                                         n, 
                                                                                         other >>
                                                   /\ UNCHANGED << freeList, 
                                                                   stash, fin >>
                                        /\ UNCHANGED partialQ
                  /\ UNCHANGED << bits, sweepQ, phase, liveBytes, swept, 
                                  deferred, virginQ, chunk, chunkLive, 
                                  released, grantOn, grantLive, gclaim, gwork, 
                                  fatal, allocs, need, marked, claimed, cell, 
                                  seen, ph, pos, lastE, todo, gcell, gseen, 
                                  gpos, gch, gk, mcell, mseen >>

W_LadderB(self) == /\ pc[self] = "W_LadderB"
                   /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                   /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                   /\ IF phase = "Sweeping" /\ sweepQ # <<>>
                         THEN /\ \/ /\ pc' = [pc EXCEPT ![self] = "W_Sweep"]
                                    /\ UNCHANGED <<lock, vc, lockvc, n, other>>
                                 \/ /\ Breadth
                                    /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                    /\ other' = [other EXCEPT ![self] = FALSE]
                                    /\ lock' = 0
                                    /\ lockvc' = vc[self]
                                    /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                    /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                         ELSE /\ IF other[self]
                                    THEN /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                         /\ other' = [other EXCEPT ![self] = FALSE]
                                         /\ lock' = 0
                                         /\ lockvc' = vc[self]
                                         /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                         /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                    ELSE /\ pc' = [pc EXCEPT ![self] = "W_Virgin"]
                                         /\ UNCHANGED << lock, vc, lockvc, n, 
                                                         other >>
                   /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                   swept, deferred, shared, partialQ, virginQ, 
                                   chunk, chunkLive, stash, released, grantOn, 
                                   grantLive, gclaim, gwork, fatal, allocs, 
                                   need, marked, claimed, sharedvc, cell, seen, 
                                   ph, pos, fin, lastE, todo, gcell, gseen, 
                                   gpos, gch, gk, mcell, mseen >>

W_Fin(self) == /\ pc[self] = "W_Fin"
               /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
               /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
               /\ IF Counts(phase)
                     THEN /\ cell' = [cell EXCEPT ![self] = fin[self]]
                          /\ ph' = [ph EXCEPT ![self] = phase]
                          /\ fin' = [fin EXCEPT ![self] = 0]
                          /\ pc' = [pc EXCEPT ![self] = "W_StBit"]
                          /\ UNCHANGED << stash, allocs, n >>
                     ELSE /\ allocs' = [allocs EXCEPT ![fin[self]] = allocs[fin[self]] + 1]
                          /\ stash' = [stash EXCEPT ![self] = stash[self] \ {fin[self]}]
                          /\ n' = [n EXCEPT ![self] = n[self] + 1]
                          /\ fin' = [fin EXCEPT ![self] = 0]
                          /\ IF lock = self
                                THEN /\ pc' = [pc EXCEPT ![self] = "W_StUnlock"]
                                ELSE /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                          /\ UNCHANGED << cell, ph >>
               /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, swept, 
                               deferred, shared, partialQ, virginQ, lock, 
                               chunk, chunkLive, released, grantOn, grantLive, 
                               gclaim, gwork, fatal, need, marked, claimed, vc, 
                               lockvc, sharedvc, seen, pos, other, lastE, todo, 
                               gcell, gseen, gpos, gch, gk, mcell, mseen >>

W_Sweep(self) == /\ pc[self] = "W_Sweep"
                 /\ freeList' = Head(sweepQ).g \o freeList
                 /\ IF Head(sweepQ).l = 0
                       THEN /\ swept' = [swept EXCEPT ![Head(sweepQ).e] = TRUE]
                            /\ lastE' = [lastE EXCEPT ![self] = Head(sweepQ).e]
                            /\ sweepQ' = Tail(sweepQ)
                            /\ pc' = [pc EXCEPT ![self] = "W_SweepEnd"]
                            /\ UNCHANGED << hist, races, cell, seen >>
                       ELSE /\ cell' = [cell EXCEPT ![self] = Head(sweepQ).l]
                            /\ seen' = [seen EXCEPT ![self] = bits[ByteOf(Head(sweepQ).l)]]
                            /\ races' = (races \cup {ax.l : ax \in {ay \in (WordRd(ByteOf(Head(sweepQ).l))) : Conflicts(self, vc[self], ay)}})
                            /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (WordRd(ByteOf(Head(sweepQ).l))))]
                            /\ sweepQ' = <<[Head(sweepQ) EXCEPT !.g = <<>>]>> \o Tail(sweepQ)
                            /\ pc' = [pc EXCEPT ![self] = "W_SweepClr"]
                            /\ UNCHANGED << swept, lastE >>
                 /\ UNCHANGED << bits, phase, liveBytes, deferred, shared, 
                                 partialQ, virginQ, lock, chunk, chunkLive, 
                                 stash, released, grantOn, grantLive, gclaim, 
                                 gwork, fatal, allocs, need, marked, claimed, 
                                 vc, lockvc, sharedvc, n, ph, pos, fin, other, 
                                 todo, gcell, gseen, gpos, gch, gk, mcell, 
                                 mseen >>

W_SweepClr(self) == /\ pc[self] = "W_SweepClr"
                    /\ bits' = [bits EXCEPT ![ByteOf(cell[self])] = seen[self] \ {cell[self]}]
                    /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(cell[self]), TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                    /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(cell[self]), TRUE, TRUE)}))]
                    /\ IF Head(sweepQ).e # "none"
                          THEN /\ swept' = [swept EXCEPT ![Head(sweepQ).e] = TRUE]
                          ELSE /\ TRUE
                               /\ swept' = swept
                    /\ lastE' = [lastE EXCEPT ![self] = Head(sweepQ).e]
                    /\ sweepQ' = Tail(sweepQ)
                    /\ cell' = [cell EXCEPT ![self] = 0]
                    /\ seen' = [seen EXCEPT ![self] = {}]
                    /\ pc' = [pc EXCEPT ![self] = "W_SweepEnd"]
                    /\ UNCHANGED << freeList, phase, liveBytes, deferred, 
                                    shared, partialQ, virginQ, lock, chunk, 
                                    chunkLive, stash, released, grantOn, 
                                    grantLive, gclaim, gwork, fatal, allocs, 
                                    need, marked, claimed, vc, lockvc, 
                                    sharedvc, n, ph, pos, fin, other, todo, 
                                    gcell, gseen, gpos, gch, gk, mcell, mseen >>

W_SweepEnd(self) == /\ pc[self] = "W_SweepEnd"
                    /\ LET le == lastE[self] IN
                         /\ lastE' = [lastE EXCEPT ![self] = "none"]
                         /\ IF sweepQ = <<>>
                               THEN /\ IF ~other[self] /\ freeList # <<>>
                                          THEN /\ TRUE
                                               /\ pc' = [pc EXCEPT ![self] = "W_PopAfterSweep"]
                                               /\ UNCHANGED << phase, deferred, 
                                                               hist, races >>
                                          ELSE /\ \/ /\ other[self]
                                                     /\ TRUE
                                                     /\ pc' = [pc EXCEPT ![self] = "W_PopAfterSweep"]
                                                     /\ UNCHANGED <<phase, deferred, hist, races>>
                                                  \/ /\ phase' = "Idle"
                                                     /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                                     /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, TRUE)}))]
                                                     /\ \/ /\ deferred' = TRUE
                                                           /\ pc' = [pc EXCEPT ![self] = "W_PopAfterSweep"]
                                                        \/ /\ "tail_defers" \notin MUTANT
                                                           /\ pc' = [pc EXCEPT ![self] = "W_Shrink"]
                                                           /\ UNCHANGED deferred
                               ELSE /\ IF le # "none" /\ ~other[self] /\ freeList # <<>>
                                          THEN /\ TRUE
                                               /\ pc' = [pc EXCEPT ![self] = "W_PopAfterSweep"]
                                          ELSE /\ \/ /\ pc' = [pc EXCEPT ![self] = "W_Sweep"]
                                                  \/ /\ TRUE
                                                     /\ pc' = [pc EXCEPT ![self] = "W_PopAfterSweep"]
                                    /\ UNCHANGED << phase, deferred, hist, 
                                                    races >>
                    /\ UNCHANGED << bits, freeList, sweepQ, liveBytes, swept, 
                                    shared, partialQ, virginQ, lock, chunk, 
                                    chunkLive, stash, released, grantOn, 
                                    grantLive, gclaim, gwork, fatal, allocs, 
                                    need, marked, claimed, vc, lockvc, 
                                    sharedvc, n, cell, seen, ph, pos, fin, 
                                    other, todo, gcell, gseen, gpos, gch, gk, 
                                    mcell, mseen >>

W_PopAfterSweep(self) == /\ pc[self] = "W_PopAfterSweep"
                         /\ IF ~other[self] /\ freeList # <<>>
                               THEN /\ LET c == Head(freeList) IN
                                         /\ freeList' = Tail(freeList)
                                         /\ IF Counts(phase)
                                               THEN /\ bits' = [bits EXCEPT ![ByteOf(c)] = bits[ByteOf(c)] \cup {c}]
                                                    /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(c)] = liveBytes[BlkOf(c)] + 1]
                                                    /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE), Acc1(ByteOf(c), FALSE, TRUE),
                                                                                                     Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                                    /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE), Acc1(ByteOf(c), FALSE, TRUE),
                                                                                                                 Acc1("live", FALSE, TRUE)}))]
                                                    /\ IF phase = "Marking"
                                                          THEN /\ need' = (need \cup {c})
                                                          ELSE /\ TRUE
                                                               /\ need' = need
                                               ELSE /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("phase", PhasePlain, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                                    /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("phase", PhasePlain, FALSE)}))]
                                                    /\ UNCHANGED << bits, 
                                                                    liveBytes, 
                                                                    need >>
                                         /\ allocs' = [allocs EXCEPT ![c] = allocs[c] + 1]
                                    /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                    /\ other' = [other EXCEPT ![self] = FALSE]
                                    /\ lock' = 0
                                    /\ lockvc' = vc[self]
                                    /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                    /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                               ELSE /\ IF other[self]
                                          THEN /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                               /\ other' = [other EXCEPT ![self] = FALSE]
                                               /\ lock' = 0
                                               /\ lockvc' = vc[self]
                                               /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                                               /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                                          ELSE /\ pc' = [pc EXCEPT ![self] = "W_Virgin"]
                                               /\ UNCHANGED << lock, vc, 
                                                               lockvc, n, 
                                                               other >>
                                    /\ UNCHANGED << bits, freeList, liveBytes, 
                                                    allocs, need, hist, races >>
                         /\ UNCHANGED << sweepQ, phase, swept, deferred, 
                                         shared, partialQ, virginQ, chunk, 
                                         chunkLive, stash, released, grantOn, 
                                         grantLive, gclaim, gwork, fatal, 
                                         marked, claimed, sharedvc, cell, seen, 
                                         ph, pos, fin, lastE, todo, gcell, 
                                         gseen, gpos, gch, gk, mcell, mseen >>

W_Virgin(self) == /\ pc[self] = "W_Virgin"
                  /\ IF virginQ # <<>>
                        THEN /\ shared' = [b |-> Head(virginQ), u |-> 0]
                             /\ virginQ' = Tail(virginQ)
                             /\ sharedvc' = vc[self]
                             /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                             /\ pc' = [pc EXCEPT ![self] = "W_Claim"]
                             /\ UNCHANGED << lock, lockvc, n >>
                        ELSE /\ n' = [n EXCEPT ![self] = n[self] + 1]
                             /\ lock' = 0
                             /\ lockvc' = vc[self]
                             /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                             /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                             /\ UNCHANGED << shared, virginQ, sharedvc >>
                  /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                  swept, deferred, partialQ, chunk, chunkLive, 
                                  stash, released, grantOn, grantLive, gclaim, 
                                  gwork, fatal, allocs, need, marked, claimed, 
                                  hist, races, cell, seen, ph, pos, fin, other, 
                                  lastE, todo, gcell, gseen, gpos, gch, gk, 
                                  mcell, mseen >>

W_Shrink(self) == /\ pc[self] = "W_Shrink"
                  /\ \E rel \in SUBSET ShrinkCands(liveBytes):
                       /\ IF shared.b \in rel
                             THEN /\ fatal' = (fatal \cup {"detach"})
                             ELSE /\ TRUE
                                  /\ fatal' = fatal
                       /\ released' = (released \cup rel)
                       /\ freeList' = SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel)
                       /\ partialQ' = SelectSeq(partialQ, LAMBDA b : b \notin rel)
                  /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("live", TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                  /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("live", TRUE, FALSE)}))]
                  /\ pc' = [pc EXCEPT ![self] = "W_PopAfterSweep"]
                  /\ UNCHANGED << bits, sweepQ, phase, liveBytes, swept, 
                                  deferred, shared, virginQ, lock, chunk, 
                                  chunkLive, stash, grantOn, grantLive, gclaim, 
                                  gwork, allocs, need, marked, claimed, vc, 
                                  lockvc, sharedvc, n, cell, seen, ph, pos, 
                                  fin, other, lastE, todo, gcell, gseen, gpos, 
                                  gch, gk, mcell, mseen >>

W_Large(self) == /\ pc[self] = "W_Large"
                 /\ \E f \in FlipCands \cup {"none"}:
                      IF f # "none"
                         THEN /\ released' = (released \cup {f})
                              /\ freeList' = SelectSeq(freeList, LAMBDA x : BlkOf(x) # f)
                              /\ partialQ' = SelectSeq(partialQ, LAMBDA x : x # f)
                              /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("live", TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                              /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("live", TRUE, TRUE)}))]
                         ELSE /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("live", TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                              /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("live", TRUE, FALSE)}))]
                              /\ UNCHANGED << freeList, partialQ, released >>
                 /\ n' = [n EXCEPT ![self] = n[self] + 1]
                 /\ lock' = 0
                 /\ lockvc' = vc[self]
                 /\ vc' = [vc EXCEPT ![self][self] = vc[self][self] + 1]
                 /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                 /\ UNCHANGED << bits, sweepQ, phase, liveBytes, swept, 
                                 deferred, shared, virginQ, chunk, chunkLive, 
                                 stash, grantOn, grantLive, gclaim, gwork, 
                                 fatal, allocs, need, marked, claimed, 
                                 sharedvc, cell, seen, ph, pos, fin, other, 
                                 lastE, todo, gcell, gseen, gpos, gch, gk, 
                                 mcell, mseen >>

Worker(self) == W_Loop(self) \/ W_R1(self) \/ W_R1Set(self) \/ W_R1Ph(self)
                   \/ W_Claim(self) \/ W_Stash(self) \/ W_StLk(self)
                   \/ W_StBit(self) \/ W_StPlainSet(self)
                   \/ W_StUnlock(self) \/ W_Locked(self) \/ W_LadderB(self)
                   \/ W_Fin(self) \/ W_Sweep(self) \/ W_SweepClr(self)
                   \/ W_SweepEnd(self) \/ W_PopAfterSweep(self)
                   \/ W_Virgin(self) \/ W_Shrink(self) \/ W_Large(self)

K_Loop(self) == /\ pc[self] = "K_Loop"
                /\ IF todo[self] # {}
                      THEN /\ \E c \in todo[self]:
                                /\ bits' = [bits EXCEPT ![ByteOf(c)] = bits[ByteOf(c)] \cup {c}]
                                /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(c), FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(c), FALSE, TRUE)}))]
                                /\ marked' = (marked \cup {c})
                                /\ todo' = [todo EXCEPT ![self] = todo[self] \ {c}]
                           /\ pc' = [pc EXCEPT ![self] = "K_Loop"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                           /\ UNCHANGED << bits, marked, hist, races, todo >>
                /\ UNCHANGED << freeList, sweepQ, phase, liveBytes, swept, 
                                deferred, shared, partialQ, virginQ, lock, 
                                chunk, chunkLive, stash, released, grantOn, 
                                grantLive, gclaim, gwork, fatal, allocs, need, 
                                claimed, vc, lockvc, sharedvc, n, cell, seen, 
                                ph, pos, fin, other, lastE, gcell, gseen, gpos, 
                                gch, gk, mcell, mseen >>

Marker(self) == K_Loop(self)

G_Join(self) == /\ pc[self] = "G_Join"
                /\ \A w \in Workers : pc[w] = "Done"
                /\ vc' = [vc EXCEPT ![self] = JoinVC(vc, Workers \cup {self})]
                /\ liveBytes' = [b \in Blocks |-> liveBytes[b] + FlushSum(Workers, b, chunk, chunkLive)]
                /\ freeList' = SetToSeqAny(UNION {stash[w] : w \in Workers}) \o freeList
                /\ stash' = [w \in Threads |-> {}]
                /\ chunk' = [w \in Threads |-> {}]
                /\ chunkLive' = [w \in Threads |-> 0]
                /\ shared' = [b |-> "none", u |-> 0]
                /\ pc' = [pc EXCEPT ![self] = "G_Shrink"]
                /\ UNCHANGED << bits, sweepQ, phase, swept, deferred, partialQ, 
                                virginQ, lock, released, grantOn, grantLive, 
                                gclaim, gwork, fatal, allocs, need, marked, 
                                claimed, lockvc, sharedvc, hist, races, n, 
                                cell, seen, ph, pos, fin, other, lastE, todo, 
                                gcell, gseen, gpos, gch, gk, mcell, mseen >>

G_Shrink(self) == /\ pc[self] = "G_Shrink"
                  /\ IF deferred
                        THEN /\ \E rel \in SUBSET ShrinkCands(liveBytes):
                                  /\ released' = (released \cup rel)
                                  /\ freeList' = SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel)
                                  /\ partialQ' = SelectSeq(partialQ, LAMBDA b : b \notin rel)
                             /\ deferred' = FALSE
                        ELSE /\ TRUE
                             /\ UNCHANGED << freeList, deferred, partialQ, 
                                             released >>
                  /\ pc' = [pc EXCEPT ![self] = "Done"]
                  /\ UNCHANGED << bits, sweepQ, phase, liveBytes, swept, 
                                  shared, virginQ, lock, chunk, chunkLive, 
                                  stash, grantOn, grantLive, gclaim, gwork, 
                                  fatal, allocs, need, marked, claimed, vc, 
                                  lockvc, sharedvc, hist, races, n, cell, seen, 
                                  ph, pos, fin, other, lastE, todo, gcell, 
                                  gseen, gpos, gch, gk, mcell, mseen >>

Merge(self) == G_Join(self) \/ G_Shrink(self)

C_Loop(self) == /\ pc[self] = "C_Loop"
                /\ IF gwork > 0
                      THEN /\ gwork' = gwork - 1
                           /\ IF ~L3
                                 THEN /\ IF \E x \in CellsOf(GrantBlock) : x >= gpos[self] /\ x \notin bits[ByteOf(x)]
                                            THEN /\ LET c == MinOf({x \in CellsOf(GrantBlock) : x >= gpos[self] /\ x \notin bits[ByteOf(x)]}) IN
                                                      /\ gcell' = [gcell EXCEPT ![self] = c]
                                                      /\ gseen' = [gseen EXCEPT ![self] = bits[ByteOf(c)]]
                                                      /\ IF c = gpos[self]
                                                            THEN /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(c), TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                                                 /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(c), TRUE, FALSE)}))]
                                                            ELSE /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(CellsOf(GrantBlock), gpos[self], c)) : Conflicts(self, vc[self], ay)}})
                                                                 /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(CellsOf(GrantBlock), gpos[self], c)))]
                                                 /\ pc' = [pc EXCEPT ![self] = "C_Set"]
                                            ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                                                 /\ UNCHANGED << hist, races, 
                                                                 gcell, gseen >>
                                      /\ UNCHANGED << gclaim, gpos, gch, gk >>
                                 ELSE /\ IF FreeIn(gch[self], gpos[self], bits) # {}
                                            THEN /\ LET c == MinOf(FreeIn(gch[self], gpos[self], bits)) IN
                                                      /\ gcell' = [gcell EXCEPT ![self] = c]
                                                      /\ gseen' = [gseen EXCEPT ![self] = bits[ByteOf(c)]]
                                                      /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(gch[self], gpos[self], c)) : Conflicts(self, vc[self], ay)}})
                                                      /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(gch[self], gpos[self], c)))]
                                                 /\ pc' = [pc EXCEPT ![self] = "C_Set"]
                                                 /\ UNCHANGED << gclaim, gpos, 
                                                                 gch, gk >>
                                            ELSE /\ IF gclaim < Len(GrantUnits) /\ "grant_claim_plain" \in MUTANT
                                                       THEN /\ gk' = [gk EXCEPT ![self] = gclaim]
                                                            /\ pc' = [pc EXCEPT ![self] = "C_ClaimStore"]
                                                            /\ UNCHANGED << gclaim, 
                                                                            gpos, 
                                                                            gch >>
                                                       ELSE /\ IF gclaim < Len(GrantUnits)
                                                                  THEN /\ gch' = [gch EXCEPT ![self] = GrantUnits[gclaim + 1]]
                                                                       /\ gpos' = [gpos EXCEPT ![self] = MinOf(GrantUnits[gclaim + 1])]
                                                                       /\ gclaim' = gclaim + 1
                                                                       /\ pc' = [pc EXCEPT ![self] = "C_Claimed"]
                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                                                                       /\ UNCHANGED << gclaim, 
                                                                                       gpos, 
                                                                                       gch >>
                                                            /\ gk' = gk
                                                 /\ UNCHANGED << hist, races, 
                                                                 gcell, gseen >>
                      ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                           /\ UNCHANGED << gclaim, gwork, hist, races, gcell, 
                                           gseen, gpos, gch, gk >>
                /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                swept, deferred, shared, partialQ, virginQ, 
                                lock, chunk, chunkLive, stash, released, 
                                grantOn, grantLive, fatal, allocs, need, 
                                marked, claimed, vc, lockvc, sharedvc, n, cell, 
                                seen, ph, pos, fin, other, lastE, todo, mcell, 
                                mseen >>

C_Set(self) == /\ pc[self] = "C_Set"
               /\ bits' = [bits EXCEPT ![ByteOf(gcell[self])] = gseen[self] \cup {gcell[self]}]
               /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(gcell[self]), TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
               /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(gcell[self]), TRUE, TRUE)}))]
               /\ allocs' = [allocs EXCEPT ![gcell[self]] = allocs[gcell[self]] + 1]
               /\ IF T0Blocks # {}
                     THEN /\ need' = (need \cup {gcell[self]})
                     ELSE /\ TRUE
                          /\ need' = need
               /\ grantLive' = grantLive + 1
               /\ gpos' = [gpos EXCEPT ![self] = gcell[self] + 1]
               /\ gcell' = [gcell EXCEPT ![self] = 0]
               /\ gseen' = [gseen EXCEPT ![self] = {}]
               /\ pc' = [pc EXCEPT ![self] = "C_Loop"]
               /\ UNCHANGED << freeList, sweepQ, phase, liveBytes, swept, 
                               deferred, shared, partialQ, virginQ, lock, 
                               chunk, chunkLive, stash, released, grantOn, 
                               gclaim, gwork, fatal, marked, claimed, vc, 
                               lockvc, sharedvc, n, cell, seen, ph, pos, fin, 
                               other, lastE, todo, gch, gk, mcell, mseen >>

C_ClaimStore(self) == /\ pc[self] = "C_ClaimStore"
                      /\ gch' = [gch EXCEPT ![self] = GrantUnits[gk[self] + 1]]
                      /\ gpos' = [gpos EXCEPT ![self] = MinOf(GrantUnits[gk[self] + 1])]
                      /\ gclaim' = gk[self] + 1
                      /\ gk' = [gk EXCEPT ![self] = 0]
                      /\ pc' = [pc EXCEPT ![self] = "C_Claimed"]
                      /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                      swept, deferred, shared, partialQ, 
                                      virginQ, lock, chunk, chunkLive, stash, 
                                      released, grantOn, grantLive, gwork, 
                                      fatal, allocs, need, marked, claimed, vc, 
                                      lockvc, sharedvc, hist, races, n, cell, 
                                      seen, ph, pos, fin, other, lastE, todo, 
                                      gcell, gseen, mcell, mseen >>

C_Claimed(self) == /\ pc[self] = "C_Claimed"
                   /\ LET c == MinOf(FreeIn(gch[self], gpos[self], bits)) IN
                        /\ gcell' = [gcell EXCEPT ![self] = c]
                        /\ gseen' = [gseen EXCEPT ![self] = bits[ByteOf(c)]]
                        /\ races' = (races \cup {ax.l : ax \in {ay \in (ScanRd(gch[self], gpos[self], c)) : Conflicts(self, vc[self], ay)}})
                        /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (ScanRd(gch[self], gpos[self], c)))]
                   /\ pc' = [pc EXCEPT ![self] = "C_Set"]
                   /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                   swept, deferred, shared, partialQ, virginQ, 
                                   lock, chunk, chunkLive, stash, released, 
                                   grantOn, grantLive, gclaim, gwork, fatal, 
                                   allocs, need, marked, claimed, vc, lockvc, 
                                   sharedvc, n, cell, seen, ph, pos, fin, 
                                   other, lastE, todo, gpos, gch, gk, mcell, 
                                   mseen >>

Collector(self) == C_Loop(self) \/ C_Set(self) \/ C_ClaimStore(self)
                      \/ C_Claimed(self)

U_Cursor(self) == /\ pc[self] = "U_Cursor"
                  /\ IF \E x \in CellsOf(CursorBlock) : x \notin bits[ByteOf(x)]
                        THEN /\ LET c == MinOf({x \in CellsOf(CursorBlock) : x \notin bits[ByteOf(x)]}) IN
                                  /\ mcell' = [mcell EXCEPT ![self] = c]
                                  /\ mseen' = [mseen EXCEPT ![self] = bits[ByteOf(c)]]
                                  /\ races' = (races \cup {ax.l : ax \in {ay \in (WordRd(ByteOf(c))) : Conflicts(self, vc[self], ay)}})
                                  /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (WordRd(ByteOf(c))))]
                             /\ pc' = [pc EXCEPT ![self] = "U_CursorSet"]
                        ELSE /\ pc' = [pc EXCEPT ![self] = "U_Pop"]
                             /\ UNCHANGED << hist, races, mcell, mseen >>
                  /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                  swept, deferred, shared, partialQ, virginQ, 
                                  lock, chunk, chunkLive, stash, released, 
                                  grantOn, grantLive, gclaim, gwork, fatal, 
                                  allocs, need, marked, claimed, vc, lockvc, 
                                  sharedvc, n, cell, seen, ph, pos, fin, other, 
                                  lastE, todo, gcell, gseen, gpos, gch, gk >>

U_CursorSet(self) == /\ pc[self] = "U_CursorSet"
                     /\ bits' = [bits EXCEPT ![ByteOf(mcell[self])] = mseen[self] \cup {mcell[self]}]
                     /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(mcell[self]), TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                     /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(mcell[self]), TRUE, TRUE)}))]
                     /\ allocs' = [allocs EXCEPT ![mcell[self]] = allocs[mcell[self]] + 1]
                     /\ IF phase = "Marking"
                           THEN /\ need' = (need \cup {mcell[self]})
                           ELSE /\ TRUE
                                /\ need' = need
                     /\ mcell' = [mcell EXCEPT ![self] = 0]
                     /\ mseen' = [mseen EXCEPT ![self] = {}]
                     /\ pc' = [pc EXCEPT ![self] = "U_Pop"]
                     /\ UNCHANGED << freeList, sweepQ, phase, liveBytes, swept, 
                                     deferred, shared, partialQ, virginQ, lock, 
                                     chunk, chunkLive, stash, released, 
                                     grantOn, grantLive, gclaim, gwork, fatal, 
                                     marked, claimed, vc, lockvc, sharedvc, n, 
                                     cell, seen, ph, pos, fin, other, lastE, 
                                     todo, gcell, gseen, gpos, gch, gk >>

U_Pop(self) == /\ pc[self] = "U_Pop"
               /\ IF freeList # <<>>
                     THEN /\ LET c == Head(freeList) IN
                               /\ freeList' = Tail(freeList)
                               /\ IF phase # "Idle" /\ "plain_allocate_black" \in MUTANT
                                     THEN /\ mcell' = [mcell EXCEPT ![self] = c]
                                          /\ mseen' = [mseen EXCEPT ![self] = bits[ByteOf(c)]]
                                          /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(c), TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                          /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(c), TRUE, FALSE)}))]
                                          /\ pc' = [pc EXCEPT ![self] = "U_PopPlainSet"]
                                          /\ UNCHANGED << bits, liveBytes, 
                                                          allocs, need >>
                                     ELSE /\ IF phase # "Idle"
                                                THEN /\ bits' = [bits EXCEPT ![ByteOf(c)] = bits[ByteOf(c)] \cup {c}]
                                                     /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(c)] = liveBytes[BlkOf(c)] + 1]
                                                     /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(c), FALSE, TRUE), Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                                     /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(c), FALSE, TRUE), Acc1("live", FALSE, TRUE)}))]
                                                     /\ IF phase = "Marking"
                                                           THEN /\ need' = (need \cup {c})
                                                           ELSE /\ TRUE
                                                                /\ need' = need
                                                     /\ allocs' = [allocs EXCEPT ![c] = allocs[c] + 1]
                                                     /\ pc' = [pc EXCEPT ![self] = "U_Sweep"]
                                                ELSE /\ allocs' = [allocs EXCEPT ![c] = allocs[c] + 1]
                                                     /\ pc' = [pc EXCEPT ![self] = "U_Sweep"]
                                                     /\ UNCHANGED << bits, 
                                                                     liveBytes, 
                                                                     need, 
                                                                     hist, 
                                                                     races >>
                                          /\ UNCHANGED << mcell, mseen >>
                     ELSE /\ pc' = [pc EXCEPT ![self] = "U_Sweep"]
                          /\ UNCHANGED << bits, freeList, liveBytes, allocs, 
                                          need, hist, races, mcell, mseen >>
               /\ UNCHANGED << sweepQ, phase, swept, deferred, shared, 
                               partialQ, virginQ, lock, chunk, chunkLive, 
                               stash, released, grantOn, grantLive, gclaim, 
                               gwork, fatal, marked, claimed, vc, lockvc, 
                               sharedvc, n, cell, seen, ph, pos, fin, other, 
                               lastE, todo, gcell, gseen, gpos, gch, gk >>

U_PopPlainSet(self) == /\ pc[self] = "U_PopPlainSet"
                       /\ bits' = [bits EXCEPT ![ByteOf(mcell[self])] = mseen[self] \cup {mcell[self]}]
                       /\ liveBytes' = [liveBytes EXCEPT ![BlkOf(mcell[self])] = liveBytes[BlkOf(mcell[self])] + 1]
                       /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(mcell[self]), TRUE, TRUE), Acc1("live", FALSE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                       /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(mcell[self]), TRUE, TRUE), Acc1("live", FALSE, TRUE)}))]
                       /\ IF phase = "Marking"
                             THEN /\ need' = (need \cup {mcell[self]})
                             ELSE /\ TRUE
                                  /\ need' = need
                       /\ allocs' = [allocs EXCEPT ![mcell[self]] = allocs[mcell[self]] + 1]
                       /\ mcell' = [mcell EXCEPT ![self] = 0]
                       /\ mseen' = [mseen EXCEPT ![self] = {}]
                       /\ pc' = [pc EXCEPT ![self] = "U_Sweep"]
                       /\ UNCHANGED << freeList, sweepQ, phase, swept, 
                                       deferred, shared, partialQ, virginQ, 
                                       lock, chunk, chunkLive, stash, released, 
                                       grantOn, grantLive, gclaim, gwork, 
                                       fatal, marked, claimed, vc, lockvc, 
                                       sharedvc, n, cell, seen, ph, pos, fin, 
                                       other, lastE, todo, gcell, gseen, gpos, 
                                       gch, gk >>

U_Sweep(self) == /\ pc[self] = "U_Sweep"
                 /\ IF phase = "Sweeping" /\ sweepQ # <<>>
                       THEN /\ freeList' = Head(sweepQ).g \o freeList
                            /\ mcell' = [mcell EXCEPT ![self] = Head(sweepQ).l]
                            /\ mseen' = [mseen EXCEPT ![self] = bits[ByteOf(Head(sweepQ).l)]]
                            /\ races' = (races \cup {ax.l : ax \in {ay \in (WordRd(ByteOf(Head(sweepQ).l))) : Conflicts(self, vc[self], ay)}})
                            /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, (WordRd(ByteOf(Head(sweepQ).l))))]
                            /\ sweepQ' = <<[Head(sweepQ) EXCEPT !.g = <<>>]>> \o Tail(sweepQ)
                            /\ pc' = [pc EXCEPT ![self] = "U_SweepClr"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "U_Large"]
                            /\ UNCHANGED << freeList, sweepQ, hist, races, 
                                            mcell, mseen >>
                 /\ UNCHANGED << bits, phase, liveBytes, swept, deferred, 
                                 shared, partialQ, virginQ, lock, chunk, 
                                 chunkLive, stash, released, grantOn, 
                                 grantLive, gclaim, gwork, fatal, allocs, need, 
                                 marked, claimed, vc, lockvc, sharedvc, n, 
                                 cell, seen, ph, pos, fin, other, lastE, todo, 
                                 gcell, gseen, gpos, gch, gk >>

U_SweepClr(self) == /\ pc[self] = "U_SweepClr"
                    /\ bits' = [bits EXCEPT ![ByteOf(mcell[self])] = mseen[self] \ {mcell[self]}]
                    /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1(ByteOf(mcell[self]), TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                    /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1(ByteOf(mcell[self]), TRUE, TRUE)}))]
                    /\ IF Head(sweepQ).e # "none"
                          THEN /\ swept' = [swept EXCEPT ![Head(sweepQ).e] = TRUE]
                          ELSE /\ TRUE
                               /\ swept' = swept
                    /\ sweepQ' = Tail(sweepQ)
                    /\ mcell' = [mcell EXCEPT ![self] = 0]
                    /\ mseen' = [mseen EXCEPT ![self] = {}]
                    /\ pc' = [pc EXCEPT ![self] = "U_SweepDone"]
                    /\ UNCHANGED << freeList, phase, liveBytes, deferred, 
                                    shared, partialQ, virginQ, lock, chunk, 
                                    chunkLive, stash, released, grantOn, 
                                    grantLive, gclaim, gwork, fatal, allocs, 
                                    need, marked, claimed, vc, lockvc, 
                                    sharedvc, n, cell, seen, ph, pos, fin, 
                                    other, lastE, todo, gcell, gseen, gpos, 
                                    gch, gk >>

U_SweepDone(self) == /\ pc[self] = "U_SweepDone"
                     /\ phase' = "Idle"
                     /\ \E rel \in SUBSET (ShrinkCands(liveBytes) \ {CursorBlock}):
                          /\ released' = (released \cup rel)
                          /\ freeList' = SelectSeq(freeList, LAMBDA x : BlkOf(x) \notin rel)
                     /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("live", TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                     /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("live", TRUE, FALSE)}))]
                     /\ pc' = [pc EXCEPT ![self] = "U_Large"]
                     /\ UNCHANGED << bits, sweepQ, liveBytes, swept, deferred, 
                                     shared, partialQ, virginQ, lock, chunk, 
                                     chunkLive, stash, grantOn, grantLive, 
                                     gclaim, gwork, fatal, allocs, need, 
                                     marked, claimed, vc, lockvc, sharedvc, n, 
                                     cell, seen, ph, pos, fin, other, lastE, 
                                     todo, gcell, gseen, gpos, gch, gk, mcell, 
                                     mseen >>

U_Large(self) == /\ pc[self] = "U_Large"
                 /\ IF "large_promo" \in MUTANT
                       THEN /\ \E f \in (FlipCands \ {CursorBlock}) \cup {"none"}:
                                 IF f # "none"
                                    THEN /\ released' = (released \cup {f})
                                         /\ freeList' = SelectSeq(freeList, LAMBDA x : BlkOf(x) # f)
                                         /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("live", TRUE, TRUE)}) : Conflicts(self, vc[self], ay)}})
                                         /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("live", TRUE, TRUE)}))]
                                    ELSE /\ races' = (races \cup {ax.l : ax \in {ay \in ({Acc1("live", TRUE, FALSE)}) : Conflicts(self, vc[self], ay)}})
                                         /\ hist' = [loc \in Locs |-> Recorded(self, vc[self], loc, ({Acc1("live", TRUE, FALSE)}))]
                                         /\ UNCHANGED << freeList, released >>
                       ELSE /\ TRUE
                            /\ UNCHANGED << freeList, released, hist, races >>
                 /\ pc' = [pc EXCEPT ![self] = "U_Pause"]
                 /\ UNCHANGED << bits, sweepQ, phase, liveBytes, swept, 
                                 deferred, shared, partialQ, virginQ, lock, 
                                 chunk, chunkLive, stash, grantOn, grantLive, 
                                 gclaim, gwork, fatal, allocs, need, marked, 
                                 claimed, vc, lockvc, sharedvc, n, cell, seen, 
                                 ph, pos, fin, other, lastE, todo, gcell, 
                                 gseen, gpos, gch, gk, mcell, mseen >>

U_Pause(self) == /\ pc[self] = "U_Pause"
                 /\ IF "launch_before_t0" \in MUTANT
                       THEN /\ pc' = [pc EXCEPT ![self] = "U_T0"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "U_Join"]
                 /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, 
                                 swept, deferred, shared, partialQ, virginQ, 
                                 lock, chunk, chunkLive, stash, released, 
                                 grantOn, grantLive, gclaim, gwork, fatal, 
                                 allocs, need, marked, claimed, vc, lockvc, 
                                 sharedvc, hist, races, n, cell, seen, ph, pos, 
                                 fin, other, lastE, todo, gcell, gseen, gpos, 
                                 gch, gk, mcell, mseen >>

U_Join(self) == /\ pc[self] = "U_Join"
                /\ \A x \in Collectors : pc[x] = "Done"
                /\ vc' = [vc EXCEPT ![self] = JoinVC(vc, Collectors \cup {self})]
                /\ liveBytes' = [liveBytes EXCEPT ![GrantBlock] = liveBytes[GrantBlock] + grantLive]
                /\ grantOn' = FALSE
                /\ pc' = [pc EXCEPT ![self] = "U_T0"]
                /\ UNCHANGED << bits, freeList, sweepQ, phase, swept, deferred, 
                                shared, partialQ, virginQ, lock, chunk, 
                                chunkLive, stash, released, grantLive, gclaim, 
                                gwork, fatal, allocs, need, marked, claimed, 
                                lockvc, sharedvc, hist, races, n, cell, seen, 
                                ph, pos, fin, other, lastE, todo, gcell, gseen, 
                                gpos, gch, gk, mcell, mseen >>

U_T0(self) == /\ pc[self] = "U_T0"
              /\ IF grantOn
                    THEN /\ fatal' = (fatal \cup {"grantAtT0"})
                    ELSE /\ TRUE
                         /\ fatal' = fatal
              /\ pc' = [pc EXCEPT ![self] = "U_After"]
              /\ UNCHANGED << bits, freeList, sweepQ, phase, liveBytes, swept, 
                              deferred, shared, partialQ, virginQ, lock, chunk, 
                              chunkLive, stash, released, grantOn, grantLive, 
                              gclaim, gwork, allocs, need, marked, claimed, vc, 
                              lockvc, sharedvc, hist, races, n, cell, seen, ph, 
                              pos, fin, other, lastE, todo, gcell, gseen, gpos, 
                              gch, gk, mcell, mseen >>

U_After(self) == /\ pc[self] = "U_After"
                 /\ IF \E x \in CellsOf(GrantBlock) : x \notin bits[ByteOf(x)]
                       THEN /\ LET x == MinOf({y \in CellsOf(GrantBlock) : y \notin bits[ByteOf(y)]}) IN
                                 /\ bits' = [bits EXCEPT ![ByteOf(x)] = bits[ByteOf(x)] \cup {x}]
                                 /\ allocs' = [allocs EXCEPT ![x] = allocs[x] + 1]
                       ELSE /\ TRUE
                            /\ UNCHANGED << bits, allocs >>
                 /\ pc' = [pc EXCEPT ![self] = "Done"]
                 /\ UNCHANGED << freeList, sweepQ, phase, liveBytes, swept, 
                                 deferred, shared, partialQ, virginQ, lock, 
                                 chunk, chunkLive, stash, released, grantOn, 
                                 grantLive, gclaim, gwork, fatal, need, marked, 
                                 claimed, vc, lockvc, sharedvc, hist, races, n, 
                                 cell, seen, ph, pos, fin, other, lastE, todo, 
                                 gcell, gseen, gpos, gch, gk, mcell, mseen >>

Mutator(self) == U_Cursor(self) \/ U_CursorSet(self) \/ U_Pop(self)
                    \/ U_PopPlainSet(self) \/ U_Sweep(self)
                    \/ U_SweepClr(self) \/ U_SweepDone(self)
                    \/ U_Large(self) \/ U_Pause(self) \/ U_Join(self)
                    \/ U_T0(self) \/ U_After(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == (\E self \in Workers: Worker(self))
           \/ (\E self \in Markers: Marker(self))
           \/ (\E self \in Mergers: Merge(self))
           \/ (\E self \in Collectors: Collector(self))
           \/ (\E self \in Mutators: Mutator(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Workers : WF_vars(Worker(self))
        /\ \A self \in Markers : WF_vars(Marker(self))
        /\ \A self \in Mergers : WF_vars(Merge(self))
        /\ \A self \in Collectors : WF_vars(Collector(self))
        /\ \A self \in Mutators : WF_vars(Mutator(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

-----------------------------------------------------------------------------
AllDone == \A p \in DOMAIN pc : pc[p] = "Done"
\* End-state checks: every allocate-black bit and every bit the marker set
\* survived (IM4; no lost update); post-t0 uniform bitmaps are exact
\* allocation maps (HEAP_054).
NoLostRequiredBit == AllDone => (need \cup marked) \subseteq SetBits
PostT0Uniform == UNION {CellsOf(b) : b \in Uniform \ T0Blocks}
AllocMapExact == AllDone => \A c \in PostT0Uniform : (c \in SetBits) <=> (allocs[c] > 0)
=============================================================================
