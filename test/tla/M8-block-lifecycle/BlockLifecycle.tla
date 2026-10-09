--------------------------- MODULE BlockLifecycle ---------------------------
(***************************************************************************)
(* M8: the old generation's block lifecycle, serially (one mutator, the    *)
(* serial minor GC, stop-the-world majors, bitmap allocation: the default  *)
(* old_gen_bitmap_alloc = true).                                           *)
(*                                                                         *)
(* Blocks live at page slots that are released and re-created at the SAME  *)
(* start (the Allocator's first-fit free extents), under BlockTable ids    *)
(* that are recycled LIFO; each block has its kind, alloc_state,           *)
(* live_bytes, fully_swept, a mark bit per 8-byte granule and the header   *)
(* written at each granule. Objects have ids, sizes and roots. The side    *)
(* tables keyed by address or id (large_body_index_, free_lists_,          *)
(* partial_, free_large_blocks_, the page-index owner, the free id and     *)
(* extent lists) are modelled as the code keeps them.                      *)
(*                                                                         *)
(* The code is serial, so a model step is one whole operation at the       *)
(* granularity where pauses and the mutator interleave: one allocate()     *)
(* call (its upfront sweep slice, the whole allocation ladder with its     *)
(* sweep-on-demand, bag and panic rungs, a completing sweep's shrink), a   *)
(* mutator drop, a minor's start / promotion / YLOS reach / end, a STW     *)
(* major. Inside a step every choice the code makes by a threshold the     *)
(* model cannot see (a sweep budget, the shrink's sizing, which free cell  *)
(* first fits) is a free choice: an over-approximation, so every          *)
(* counterexample is checked against the code (AUDIT.md).                  *)
(*                                                                         *)
(* One state variable `h` holds the heap; each C++ function is one         *)
(* operator from a heap to the SET of heaps it can end in (outcomes carry  *)
(* the returned address, or Fail). MAPPING.md maps every operator and     *)
(* field to the code; AUDIT.md holds the results.                          *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS
    G,           \* alloc_buffer_size in 8-byte granules: one page = one regular block
    NC,          \* num_size_classes_: classes 0..NC-1 have uniform (bitmap) blocks
    NCLS,        \* NUM_SIZE_CLASSES: classes NC..NCLS-1 are mixed-only
    CellSize,    \* classToSize in granules, ascending; CellSize[0] = 2 = MIN_FREE_CELL_SIZE
    NS,          \* page slots in the old-gen reservation (slot 1 = heap_base)
    InitPages,   \* initial_old_gen_size in pages: slots 1..InitPages start in the bag
    MinHeap,     \* max(initial_old_gen_size, alloc_buffer_size) in pages: the floor
    NIds,        \* BlockTable ids
    NMeta,       \* large_bodies_ slots (LargeBodyId)
    NObj,        \* object ids (each allocated at most once)
    MaxOps,      \* bound on counted operations
    PromoAge,    \* HeapConfig::promotion_age
    MutSizes,    \* sizes of the mutator's direct old-gen allocations (allocateLargePinned)
    YlosSizes,   \* sizes of young large objects (allocateYoungLarge)
    PromoSizes,  \* sizes of the objects a minor promotes
    BagFirst,    \* shouldPreferBagForSmallClass (TRUE under the default 1 GiB budget)
    DemoteMax,   \* demote a uniform block iff live_bytes <= DemoteMax granules (-1: off)
    Cov,         \* record the paths taken in h.ev (coverage runs only; FALSE in every row)
    Keep(_),     \* scenario filter on an allocation's outcomes (MC.tla; TRUE but in CR-035's rows)
    MUTANT,      \* the negative controls and fix candidates switched on (AUDIT.md)
    LOS,         \* plans/large-object-space.md (2026-10-09): pinned and young large objects
                 \* live in LOS blocks (TRUE: the code since then); FALSE: the earlier placement
                 \* (bag pages, large blocks), kept for the CR-018/CR-035 rows' history
    LosKeep      \* los_empty_keep: empty LOS blocks kept at the post-mark tail

ASSUME CellSize[0] = 2 /\ NC >= 1 /\ NCLS > NC /\ NIds >= NS + 1 /\ InitPages <= NS
ASSUME \A c \in 1..(NCLS - 1) : CellSize[c - 1] < CellSize[c] /\ CellSize[NCLS - 1] <= G

-----------------------------------------------------------------------------
(* Geometry and small helpers.                                             *)

Slots  == 1..NS
Offs   == 0..(G - 1)
Addrs  == Slots \X Offs
Null   == <<0, 0>>            \* nullptr; also Fail, the null allocation result
Fail   == Null
UCls   == 0..(NC - 1)
FLCls  == 0..(NCLS - 1)
Ids    == 1..NIds
Metas  == 1..NMeta
Objs   == 1..NObj
MinCell == CellSize[0]        \* MIN_FREE_CELL_SIZE (OGH:196, sizeof(FreeCell) = 16 B)
Mixed  == NCLS                \* BlockInfo::size_class of a mixed or large block
NCells(c) == G \div CellSize[c]

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y
Max2(a, b) == IF a >= b THEN a ELSE b
Sub0(a, b) == IF a >= b THEN a - b ELSE 0          \* the code's clamped subtraction
Range(sq) == {sq[i] : i \in 1..Len(sq)}
TruncLast(sq) == SubSeq(sq, 1, Len(sq) - 1)
\* vector swap-remove: v[i] = v.back(); v.pop_back()
SwapRemoveAt(sq, i) == IF i = Len(sq) THEN TruncLast(sq)
                       ELSE TruncLast([sq EXCEPT ![i] = sq[Len(sq)]])
FirstIdx(sq, e) == CHOOSE i \in 1..Len(sq) : sq[i] = e /\ \A k \in 1..(i - 1) : sq[k] # e
\* vector::erase of the first occurrence (order kept)
RemoveFirst(sq, e) == IF e \in Range(sq)
                      THEN LET i == FirstIdx(sq, e) IN SubSeq(sq, 1, i - 1) \o SubSeq(sq, i + 1, Len(sq))
                      ELSE sq
\* the swap-remove loop over every occurrence (releaseBlockToAllocator's free_large_blocks_ purge)
RECURSIVE SwapRemoveAll(_, _, _)
SwapRemoveAll(sq, e, k) == IF k > Len(sq) THEN sq
                           ELSE IF sq[k] = e THEN SwapRemoveAll(SwapRemoveAt(sq, k), e, k)
                           ELSE SwapRemoveAll(sq, e, k + 1)
Reverse(sq) == [i \in 1..Len(sq) |-> sq[Len(sq) + 1 - i]]

\* OldGenSpace::sizeClass (OGH:1310): the smallest class holding sz, else NUM_SIZE_CLASSES
SizeClass(sz) == IF \E c \in FLCls : CellSize[c] >= sz THEN Min({c \in FLCls : CellSize[c] >= sz}) ELSE NCLS
\* OldGenSpace::freeListClassFor (OGH:1340): the largest class whose cell fits span
FLClassFor(span) == IF span >= MinCell THEN Max({c \in FLCls : CellSize[c] <= span}) ELSE NCLS

\* Header words: never written for the current block ("j", garbage), an
\* object's header ("o", its id), a Tag_Free header ("f", its size).
J      == [t |-> "j", v |-> 0]
OH(o)  == [t |-> "o", v |-> o]
FH(n)  == [t |-> "f", v |-> n]

NoBlk  == [live |-> FALSE, s |-> 0, cls |-> 0, lg |-> FALSE, eoo |-> 0, st |-> "none",
           lb |-> 0, fs |-> FALSE, marks |-> {}, lmark |-> FALSE, los |-> FALSE]
NoObj  == [st |-> "N", s |-> 0, off |-> 0, sz |-> 0, root |-> FALSE, ylos |-> FALSE,
           pin |-> FALSE, age |-> 0]
NoMeta == [base |-> Null, cs |-> 0, lg |-> FALSE, color |-> FALSE, kind |-> 0, o |-> 0]
NoCur  == [id |-> 0, nx |-> 0, pend |-> 0]

\* The initial heap: OldGenSpace::initialize (OGS:325) slices the initial
\* region into pages 1..InitPages in the bag (unassigned_blocks_, back = last).
H0 == [blk |-> [i \in Ids |-> NoBlk], order |-> <<>>, owner |-> [s \in Slots |-> 0],
       hw |-> 0, freeIds |-> <<>>, mem |-> [s \in Slots |-> [g \in Offs |-> J]],
       bag |-> [i \in 1..InitPages |-> i], ext |-> <<>>, bump |-> InitPages + 1,
       fl |-> [c \in FLCls |-> {}], flarge |-> <<>>, part |-> [c \in UCls |-> <<>>],
       cur |-> [c \in UCls |-> NoCur], phase |-> "Idle", swIdx |-> 1, swCur |-> -1,
       index |-> [a \in Addrs |-> 0], meta |-> [m \in Metas |-> NoMeta], mhw |-> 0,
       owned |-> <<>>, freeMeta |-> <<>>, color |-> FALSE,
       objs |-> [o \in Objs |-> NoObj], minor |-> FALSE, toReach |-> {}, ops |-> 0,
       lie |-> FALSE, bad |-> FALSE, bagsc |-> FALSE, reissue |-> FALSE, ev |-> {}]

\* coverage ghost: which paths fired (Cov = FALSE leaves it empty)
Ev(h, e) == IF Cov THEN [h EXCEPT !.ev = @ \cup {e}] ELSE h

-----------------------------------------------------------------------------
(* Outcomes: [h |-> heap, r |-> the address returned, or Fail].             *)

Out(hh, r) == [h |-> hh, r |-> r]
Succ(S)  == {x \in S : x.r # Fail}
Fails(S) == {x \in S : x.r = Fail}
\* "if (void* r = F()) return r;" then the next rung on the heap F left behind
Then(S, Next(_)) == Succ(S) \cup UNION {Next(x.h) : x \in Fails(S)}

-----------------------------------------------------------------------------
(* Block table, page index, extents.                                       *)

\* blockIdFor (OGS:1937): the page-index owner, if its extent holds the address
BlockAt(h, s) == IF h.owner[s] # 0 /\ h.blk[h.owner[s]].live /\ h.blk[h.owner[s]].s = s
                 THEN h.owner[s] ELSE 0
PosOf(h, id) == FirstIdx(h.order, id)
\* hasPendingSweepWork (OGH:1522): gc_phase_ == Sweeping && sweep_pending_blocks_ > 0; the
\* counter equals the unswept live blocks during a sweep (recomputeSweepPendingBlocks,
\* markBlockFullySwept, the release decrement; mid-sweep blocks are born fully_swept)
Pending(h) == h.phase = "Sweeping" /\ \E i \in 1..Len(h.order) : ~h.blk[h.order[i]].fs
CurHeap(h) == Len(h.order) + Len(h.bag)     \* maybeShrinkCapacity's current_heap, in pages

\* Allocator::acquireOldGenBlock (Allocator.cpp:759) for one page: first fit over
\* old_gen_free_blocks_ (never the heap-base extent for a page request), swap-remove;
\* else the bump, while below the reservation.
ExtFit(h) == {i \in 1..Len(h.ext) : h.ext[i] # 1}
Acquire(h) ==
    IF ExtFit(h) # {} THEN LET i == Min(ExtFit(h)) IN
                           [h |-> [h EXCEPT !.ext = SwapRemoveAt(@, i)], s |-> h.ext[i]]
    ELSE IF h.bump <= NS THEN [h |-> [h EXCEPT !.bump = @ + 1], s |-> h.bump]
    ELSE [h |-> h, s |-> 0]

\* ensureBagPageAvailable (OGS:917) / allocateFromBagPage step 3 (OGS:2617-2622):
\* an empty bag takes a fresh page from the Allocator.
EnsureBag(h) == IF h.bag # <<>> THEN h
                ELSE LET a == Acquire(h) IN IF a.s # 0 THEN [a.h EXCEPT !.bag = <<a.s>>] ELSE a.h

\* materializeBlock (OGS:700): BlockTable::add takes the last released id (LIFO) or a
\* new one and appends it to the order; mark_.assign zeroes its bitmap; the page index
\* gets the owner. The page's old bytes mean nothing to the new block (J).
\* Ghost `reissue` (CR-036): the id comes back at the start it was released from.
Materialize(h, s, cls, lg, eoo, lb, fs) ==
    LET reuse == h.freeIds # <<>>
        id == IF reuse THEN h.freeIds[Len(h.freeIds)] ELSE h.hw + 1
    IN [h |-> [h EXCEPT !.freeIds = IF reuse THEN TruncLast(@) ELSE @,
                        !.hw = IF reuse THEN @ ELSE @ + 1,
                        !.reissue = @ \/ (reuse /\ h.blk[id].s = s),
                        !.ev = IF Cov /\ reuse /\ h.blk[id].s = s THEN @ \cup {"reissue"} ELSE @,
                        !.blk[id] = [live |-> TRUE, s |-> s, cls |-> cls, lg |-> lg, eoo |-> eoo,
                                     st |-> "none", lb |-> lb, fs |-> fs, marks |-> {}, lmark |-> FALSE,
                                     los |-> FALSE],
                        !.order = Append(@, id),
                        !.owner[s] = id,
                        !.mem[s] = [g \in Offs |-> J]],
        id |-> id]
\* syncCursorLiveBytes / flushCursor (OGS:785): fold each cursor's pending bytes
Sync(h) == [h EXCEPT !.blk = [i \in Ids |-> IF \E c \in UCls : h.cur[c].id = i
                                           THEN [h.blk[i] EXCEPT !.lb = @ + h.cur[h.blk[i].cls].pend]
                                           ELSE h.blk[i]],
                     !.cur = [c \in UCls |-> [h.cur[c] EXCEPT !.pend = 0]]]

\* A header walk of slot s from p to e (HEAP_024: the legacy sweep, V11): every step
\* lands on an object or Tag_Free header and the walk ends exactly at e.
RECURSIVE Walk(_, _, _, _)
Walk(h, s, p, e) ==
    IF p = e THEN TRUE
    ELSE IF p > e THEN FALSE
    ELSE LET hd == h.mem[s][p] IN
         CASE hd.t = "o" -> h.objs[hd.v].sz > 0 /\ Walk(h, s, p + h.objs[hd.v].sz, e)
           [] hd.t = "f" -> Walk(h, s, p + hd.v, e)
           [] OTHER -> FALSE

\* Objects whose start lies in [off, off + len) of slot s stop being allocated.
FreeObjsAt(objs, s, off, len) ==
    [o \in Objs |-> IF objs[o].st = "A" /\ objs[o].s = s /\ off <= objs[o].off /\ objs[o].off < off + len
                    THEN [objs[o] EXCEPT !.st = "F"] ELSE objs[o]]

-----------------------------------------------------------------------------
(* Free lists: pushSpanOnFreeLists (OGS:5212).                              *)

PlaceCell(h, s, off, c) == [h EXCEPT !.mem[s][off] = FH(CellSize[c]), !.fl[c] = @ \cup {<<s, off>>}]
\* the mixed any-class packer: largest fitting class first; a tail under
\* MIN_FREE_CELL_SIZE gets a non-linked Tag_Free header (OGS:5358-5378)
RECURSIVE Pack(_, _, _, _)
Pack(h, s, off, len) ==
    IF len >= MinCell THEN LET c == FLClassFor(len) IN
                           Pack(PlaceCell(h, s, off, c), s, off + CellSize[c], len - CellSize[c])
    ELSE IF len >= 1 /\ "no_trailing_header" \notin MUTANT THEN [h EXCEPT !.mem[s][off] = FH(len)]
    ELSE h
\* uniform branch (OGS:5337-5362): class-sized cells (never reached in bitmap mode)
RECURSIVE Slice(_, _, _, _, _)
Slice(h, s, off, len, c) ==
    IF len >= CellSize[c] THEN Slice(PlaceCell(h, s, off, c), s, off + CellSize[c], len - CellSize[c], c)
    ELSE h
Push(h, s, off, len, id) ==
    IF id # 0 /\ ~h.blk[id].lg /\ h.blk[id].cls < NCLS THEN Slice(h, s, off, len, h.blk[id].cls)
    ELSE Pack(h, s, off, len)

\* removeFreeCellsForBlock (OGS:6259): Tier-M cells (>= 24 B: classes >= 1) through the
\* per-block thread; Tier-S (class 0, 16 B) through a global walk, skipped inside a release
\* batch (the shrink pre-cleans class 0 first; reclaim runs right after the lists were wiped).
RemoveFreeCells(h, id, batch) ==
    IF "release_keeps_free_cells" \in MUTANT THEN h
    ELSE LET s == h.blk[id].s IN
         [h EXCEPT !.fl = [c \in FLCls |-> IF c = 0 /\ batch THEN h.fl[c]
                                           ELSE {a \in h.fl[c] : a[1] # s}]]

-----------------------------------------------------------------------------
(* Allocation state: detachFromAllocation, cursors, refill.                 *)

\* detachFromAllocation (OGS:741). (A tenure-granted block is not modelled: M4, M5.)
Detach(h, id) ==
    LET b == h.blk[id] IN
    CASE b.st = "current" ->
            IF h.cur[b.cls].id = id
            THEN [h EXCEPT !.blk[id].lb = @ + h.cur[b.cls].pend, !.cur[b.cls] = NoCur,
                           !.blk[id].st = "none"]
            ELSE [h EXCEPT !.blk[id].st = "none"]
      [] b.st = "queued" ->
            [h EXCEPT !.part[b.cls] = IF "detach_skips_queue" \in MUTANT THEN @ ELSE RemoveFirst(@, id),
                      !.blk[id].st = "none"]
      [] OTHER -> h

SetCursor(h, c, id) == [h EXCEPT !.cur[c] = [id |-> id, nx |-> 0, pend |-> 0], !.blk[id].st = "current"]

\* refillCursor (OGS:828): the FIFO partial_[cls] from its head, skipping stale entries
RECURSIVE Refill(_, _)
Refill(h, c) ==
    IF h.part[c] = <<>> THEN [h |-> h, ok |-> FALSE]
    ELSE LET id == Head(h.part[c])
             h1 == [h EXCEPT !.part[c] = Tail(@)]
         IN IF ~h.blk[id].live \/ h.blk[id].st # "queued" \/ h.blk[id].lg \/ h.blk[id].cls # c
            THEN Refill(h1, c)
            ELSE [h |-> Ev(SetCursor(h1, c, id), "refill"), ok |-> TRUE]

\* padCellSlack (OGS:2127): a Tag_Free header over the slack of a larger cell
Pad(h, a, req, cell) ==
    IF cell > req
    THEN [h EXCEPT !.mem[a[1]][a[2] + req] = FH(cell - req)] ELSE h

\* initObjectHeaderWithSize (OGS:512): only while marking_active || gc_phase_ != Idle
\* is the cell black (its mark bit set); cell_bytes is added to live_bytes in EVERY
\* phase (CR-018 fixed, HEAP_073). marking_active is TRUE only inside the atomic major.
\* idle_uncounted: the pre-fix code (live_bytes added only while not Idle).
Gate(h, a, cell) ==
    LET id == BlockAt(h, a[1]) IN
    IF id = 0 THEN h
    ELSE IF h.phase # "Idle"
    THEN [h EXCEPT !.blk[id].marks = IF h.blk[id].lg THEN @ ELSE @ \cup {a[2]},
                   !.blk[id].lmark = IF h.blk[id].lg THEN TRUE ELSE @,
                   !.blk[id].lb = @ + cell]
    ELSE IF "idle_uncounted" \notin MUTANT /\ ~h.blk[id].lg
    THEN [h EXCEPT !.blk[id].lb = @ + cell]
    ELSE IF cell > 0 /\ ~h.blk[id].lg THEN Ev(h, "idle_uncounted")
    ELSE h

\* finalizeBitmapCell (OGS:851): the bit is the allocation record; bytes go to the
\* cursor's pending_live, folded into live_bytes by flushCursor.
FinalizeBitmapCell(h, c, k, req, o) ==
    LET id == h.cur[c].id  s == h.blk[id].s  off == k * CellSize[c]
        h1 == [h EXCEPT !.blk[id].marks = @ \cup {off}, !.mem[s][off] = OH(o),
                        !.cur[c].pend = @ + CellSize[c]]
    IN Out(Pad(h1, <<s, off>>, req, CellSize[c]), <<s, off>>)

\* cursorAllocate (OGS:888): the fast path and bitscan::nextFreeCell are one choice:
\* the first clear cell at or after next_cell. Exhausted: flush, alloc_state None,
\* refill. cursor_ignores_bit: the fast path without its bit test.
RECURSIVE CursorAlloc(_, _, _, _)
RefillThen(h, c, req, o) ==
    LET rf == Refill(h, c) IN IF rf.ok THEN CursorAlloc(rf.h, c, req, o) ELSE {Out(rf.h, Fail)}
CursorAlloc(h, c, req, o) ==
    LET cu == h.cur[c] IN
    IF cu.id # 0
    THEN LET b == h.blk[cu.id]
             cand == {k \in cu.nx..(NCells(c) - 1) : k * CellSize[c] \notin b.marks}
             k0 == IF "cursor_ignores_bit" \in MUTANT /\ cu.nx < NCells(c) THEN cu.nx
                   ELSE IF cand = {} THEN -1 ELSE Min(cand)
         IN IF k0 >= 0
            THEN {FinalizeBitmapCell([h EXCEPT !.cur[c].nx = k0 + 1], c, k0, req, o)}
            ELSE RefillThen([h EXCEPT !.blk[cu.id].lb = @ + cu.pend, !.blk[cu.id].st = "none",
                                      !.cur[c] = NoCur], c, req, o)
    ELSE RefillThen(h, c, req, o)

\* materializeVirginBlock + startVirginBlock (OGS:936-969): a bag page as an unsliced
\* uniform block (all-clear bitmap), born fully_swept, then the class cursor.
VirginThenCursor(h, c, req, o) ==
    LET h1 == EnsureBag(h) IN
    IF h1.bag = <<>> THEN {Out(h1, Fail)}
    ELSE LET s == h1.bag[Len(h1.bag)]
             m == Materialize([h1 EXCEPT !.bag = TruncLast(@)], s, c, FALSE,
                              NCells(c) * CellSize[c], 0, TRUE)
         IN CursorAlloc(Ev(SetCursor(m.h, c, m.id), "virgin"), c, req, o)

-----------------------------------------------------------------------------
(* The lazy sweep: lazySweep (OGS:5546), the gap sweep (HEAP_055).          *)
(* A slice is a set of outcomes: the budget is tested at the loop heads     *)
(* (OGS:5570, :5667), so the slice may end at any of them once it has       *)
(* done some work; `inf` is prepareMark's drain (a budget of SIZE_MAX / 2). *)

\* flushRun (OGS:5555): push the run with the current block as context; the dead
\* objects in it stop being allocated.
FlushRun(h, run, rlen) ==
    IF run < 0 THEN h
    ELSE LET id == h.order[h.swIdx]  s == h.blk[id].s
             h1 == Push(h, s, run, rlen, id)
         IN [h1 EXCEPT !.objs = FreeObjsAt(h1.objs, s, run, rlen)]

\* One gap-sweep iteration (OGS:5669-5707): the gap up to the next set bit joins the
\* run; a live object flushes the run, clears its bit and is stepped over by the size
\* in ITS header (the only header the gap sweep reads). `bad`: a set bit whose word is
\* not an object header.
GapStep(h, run, rlen) ==
    LET id == h.order[h.swIdx]  b == h.blk[id]  c == h.swCur
        later == {m \in b.marks : m >= c /\ m < b.eoo}
        nb == IF later = {} THEN b.eoo ELSE Min(later)
        run1 == IF nb > c THEN (IF run < 0 THEN c ELSE run) ELSE run
        rlen1 == IF nb > c THEN rlen + (nb - c) ELSE rlen
    IN IF nb >= b.eoo
       THEN [h |-> [h EXCEPT !.swCur = b.eoo], run |-> run1, rlen |-> rlen1]
       ELSE LET h1 == FlushRun([h EXCEPT !.swCur = nb], run1, rlen1)
                hd == h1.mem[b.s][nb]
                ok == hd.t = "o"
                step == IF ok THEN h1.objs[hd.v].sz ELSE 1
            IN [h |-> [h1 EXCEPT !.blk[id].marks = @ \ {nb}, !.swCur = nb + step,
                                 !.bad = @ \/ ~ok],
                run |-> -1, rlen |-> 0]

\* onSweepComplete (OGS:5841): computeFragmentationStats syncs the cursors; the light
\* shrink. Declared below with the shrink.
RECURSIVE Complete(_)
\* after the loop (OGS:5807-5827): flush; the tail completion when the cursor is past the end
Finish(h, run, rlen) ==
    LET h1 == FlushRun(h, run, rlen) IN
    IF h1.swIdx > Len(h1.order) THEN Complete(Ev([h1 EXCEPT !.phase = "Idle"], "tail_complete")) ELSE {h1}
\* the early exit (OGS:5796-5805): the target class's list is non-empty
EarlyOr(h, run, rlen, t, Else) ==
    IF t < NCLS /\ h.fl[t] # {} THEN {Ev(FlushRun(h, run, rlen), "early_exit")} ELSE Else

RECURSIVE SweepLoop(_, _, _, _, _, _), Inner(_, _, _, _, _, _)
SweepLoop(h, run, rlen, t, w, inf) ==
    (IF w /\ ~inf THEN Finish(h, run, rlen) ELSE {})             \* budget spent at the head
    \cup
    (IF h.swCur < 0
     THEN IF h.swIdx > Len(h.order)
          THEN Complete(Ev([h EXCEPT !.phase = "Idle"], "loop_complete"))   \* in-loop completion (OGS:5573)
          ELSE IF h.blk[h.order[h.swIdx]].fs
          THEN SweepLoop([h EXCEPT !.swIdx = @ + 1], run, rlen, t, w, inf)   \* skip (OGS:5598)
          ELSE Inner([h EXCEPT !.swCur = 0], run, rlen, t, w, inf)
     ELSE Inner(h, run, rlen, t, w, inf))
Inner(h, run, rlen, t, w, inf) ==
    LET id == h.order[h.swIdx] IN
    IF h.swCur < h.blk[id].eoo
    THEN (IF w /\ ~inf THEN EarlyOr(h, run, rlen, t, Finish(h, run, rlen)) ELSE {})   \* budget spent mid-block
         \cup LET st == GapStep(h, run, rlen) IN Inner(st.h, st.run, st.rlen, t, TRUE, inf)
    ELSE LET h1 == FlushRun(h, run, rlen)                        \* block boundary (OGS:5762)
             h2 == [h1 EXCEPT !.blk[id].fs = TRUE, !.swIdx = @ + 1, !.swCur = -1]
         IN EarlyOr(h2, -1, 0, t, SweepLoop(h2, -1, 0, t, TRUE, inf))

\* a slice with a positive budget (the ladder's loops); `SweepSlice0` also allows a
\* slice that does nothing (allocate()'s upfront slice with a zero minor budget)
SweepSlice(h, t) == SweepLoop(h, -1, 0, t, FALSE, FALSE)
SweepSlice0(h, t) == IF h.phase = "Sweeping" THEN {h} \cup SweepSlice(h, t) ELSE {h}
Drain(h) == IF h.phase = "Sweeping" THEN SweepLoop(Ev(h, "drain"), -1, 0, NCLS, FALSE, TRUE) ELSE {h}

\* sweepWillReach (OGS:1783)
SweepWillReach(h, id, off) ==
    /\ h.phase = "Sweeping" /\ ~h.blk[id].fs
    /\ LET pos == PosOf(h, id) IN
       pos > h.swIdx \/ (pos = h.swIdx /\ (h.swCur < 0 \/ off >= h.swCur))

-----------------------------------------------------------------------------
(* Release and shrink: releaseBlockToAllocator (OGS:6357),                  *)
(* reclaimAllDeadBlocksFromMeta (OGS:6541), maybeShrinkCapacity (OGS:6059). *)

\* the large_body_index_ purge of a released range (OGS:6424-6440): body_base = nullptr,
\* the id recycled, the entry erased (unordered_map order: ascending offsets here)
RECURSIVE PurgeFrom(_, _, _)
PurgeFrom(h, s, off) ==
    IF off >= G THEN h
    ELSE LET m == h.index[<<s, off>>] IN
         PurgeFrom(IF m = 0 THEN h
                   ELSE [h EXCEPT !.meta[m].base = Null, !.freeMeta = Append(@, m),
                                  !.index[<<s, off>>] = 0], s, off + 1)
PurgeIndex(h, s) == PurgeFrom(h, s, 0)

\* `lie` (FlipTrustsTruth): a release trusts live_bytes == 0; a rooted object is in the block
Release(h, id, batch) ==
    LET s == h.blk[id].s
        lie == \E o \in Objs : h.objs[o].st = "A" /\ h.objs[o].s = s /\ h.objs[o].root
        h1 == Detach(h, id)
        h2 == RemoveFreeCells(h1, id, batch)
        h3 == [h2 EXCEPT !.flarge = SwapRemoveAll(@, id, 1)]
        h4 == IF "release_keeps_index" \in MUTANT THEN h3 ELSE PurgeIndex(h3, s)
        pos == PosOf(h4, id)
        last == Len(h4.order)
    IN [h4 EXCEPT !.owner[s] = 0,                                 \* clearPageIndexForBlock
                  !.ext = Append(@, s),                            \* releaseOldGenBlock
                  !.order = SwapRemoveAt(@, pos),                  \* BlockTable::swapRemove
                  !.swIdx = IF pos # last /\ @ = last THEN pos ELSE @,   \* fixupCursorsAfterOrderMove
                  !.blk[id] = [NoBlk EXCEPT !.s = s],
                  !.freeIds = Append(@, id),
                  !.objs = FreeObjsAt(h4.objs, s, 0, G),
                  !.lie = @ \/ lie]
RECURSIVE ReleaseSeq(_, _, _)
ReleaseSeq(h, ids, batch) == IF ids = <<>> THEN h ELSE ReleaseSeq(Release(h, Head(ids), batch), Tail(ids), batch)

\* reclaimAllDeadBlocksFromMeta: ascending positions, the min_heap floor, then release in
\* descending position order inside a batch (no class-0 pre-clean: the lists were wiped).
RECURSIVE ReclaimPick(_, _, _, _)
ReclaimPick(h, i, cur, acc) ==
    IF i > Len(h.order) THEN acc
    ELSE LET id == h.order[i]  b == h.blk[id]
             ok == ~b.lg /\ ~b.los /\ (b.lb = 0 \/ "reclaim_ignores_live" \in MUTANT) /\ cur - 1 >= MinHeap
         IN ReclaimPick(h, i + 1, IF ok THEN cur - 1 ELSE cur, IF ok THEN Append(acc, id) ELSE acc)
Reclaim(h) == LET ids == ReclaimPick(h, 1, CurHeap(h), <<>>) IN
              IF ids = <<>> THEN h ELSE Ev(ReleaseSeq(h, Reverse(ids), TRUE), "reclaim")

\* maybeShrinkCapacity's passes for a desired size d (pages): pass 1 fully-free regular
\* blocks, pass 2 fully-free large blocks (both back-to-front), then the releases in
\* descending position order after the class-0 pre-clean, then pass 3 (bag pages).
RECURSIVE ShrinkPick(_, _, _, _, _, _)
ShrinkPick(h, i, cur, d, acc, lg) ==
    IF i < 1 \/ cur <= d THEN [cur |-> cur, acc |-> acc]
    ELSE LET id == h.order[i]  b == h.blk[id]
             ok == b.fs /\ b.lb = 0 /\ b.lg = lg /\ ~b.los /\ cur - 1 >= d
         IN ShrinkPick(h, i - 1, IF ok THEN cur - 1 ELSE cur, d, IF ok THEN Append(acc, id) ELSE acc, lg)
\* releaseUnassignedBlockToAllocator (OGS:6500): never the heap-base extent (slot 1);
\* pass 3 still counts the page (OGS:6242-6251)
RECURSIVE BagPass(_, _, _, _)
BagPass(h, i, cur, d) ==
    IF i < 1 \/ cur <= d THEN h
    ELSE IF cur - 1 < d THEN BagPass(h, i - 1, cur, d)
    ELSE BagPass(IF h.bag[i] = 1 THEN h
                 ELSE [h EXCEPT !.ext = Append(@, h.bag[i]), !.bag = SwapRemoveAt(@, i)],
                 i - 1, cur - 1, d)
ShrinkPass(h, d) ==
    LET p1 == ShrinkPick(h, Len(h.order), CurHeap(h), d, <<>>, FALSE)
        p2 == ShrinkPick(h, Len(h.order), p1.cur, d, p1.acc, TRUE)
        slots == {h.blk[i].s : i \in Range(p2.acc)}
        h1 == IF "release_keeps_free_cells" \in MUTANT THEN h
              ELSE [h EXCEPT !.fl[0] = {a \in @ : a[1] \notin slots}]
        byPos == [k \in 1..Len(p2.acc) |->
                    CHOOSE i \in Range(p2.acc) :
                       Cardinality({j \in Range(p2.acc) : PosOf(h, j) > PosOf(h, i)}) = k - 1]
        h2 == IF byPos = <<>> THEN h1 ELSE Ev(ReleaseSeq(h1, byPos, TRUE), "shrink_release")
        h3 == BagPass(h2, Len(h2.bag), p2.cur, d)
    IN IF Len(h3.bag) < Len(h2.bag) THEN Ev(h3, "bag_release") ELSE h3
\* the hysteresis gates and desired_heap depend on live bytes and the target utilisation:
\* any desired size from the floor up (d >= current releases nothing)
Shrink(h) == LET hs == Sync(h) IN {ShrinkPass(hs, d) : d \in MinHeap..Max2(MinHeap, CurHeap(hs))}
Complete(h) == Shrink(h)

-----------------------------------------------------------------------------
(* The size-class ladder: allocateFromSizeClassBitmap (OGS:973).            *)

\* tryPopFromFreeList + finalizePoppedCell (OGS:2150, :2173): any cell of the list (the
\* code pops the head: LIFO is a subset)
PopFinalize(h, c, req, o) ==
    {LET h1 == Gate(Ev([h EXCEPT !.fl[c] = @ \ {a}], "pop"), a, CellSize[c])
         h2 == [h1 EXCEPT !.mem[a[1]][a[2]] = OH(o)]
     IN Out(Pad(h2, a, req, CellSize[c]), a) : a \in h.fl[c]}

\* tryAllocateBySplittingLarger (OGS:2409): classes from max(target, num_size_classes_),
\* a cell that fits with no remainder or one of at least MIN_FREE_CELL_SIZE (any such cell:
\* the code's first fit is a subset); the remainder goes back through the packer; the
\* header and live_bytes by initObjectHeaderWithSize(alloc_size); slack padded to req.
SplitCands(h, target, alloc) ==
    {ca \in (Max2(target, NC)..(NCLS - 1)) \X Addrs :
        /\ ca[2] \in h.fl[ca[1]] /\ CellSize[ca[1]] >= alloc
        /\ \/ CellSize[ca[1]] - alloc = 0
           \/ CellSize[ca[1]] - alloc >= MinCell}
Split(h, target, alloc, req, o) ==
    {LET c == ca[1]  a == ca[2]  rem == CellSize[c] - alloc
         h1 == [h EXCEPT !.fl[c] = IF "split_keeps_cell" \in MUTANT THEN @ ELSE @ \ {a}]
         h2 == IF rem > 0 THEN Push(h1, a[1], a[2] + alloc, rem, BlockAt(h1, a[1])) ELSE h1
         h3 == [Gate(Ev(h2, "split"), a, alloc) EXCEPT !.mem[a[1]][a[2]] = OH(o)]
     IN Out(Pad(h3, a, req, alloc), a) : ca \in SplitCands(h, target, alloc)}

\* tryAllocateFromFreeLists (OGS:2194)
TryFL(h, c, req, o) ==
    IF h.fl[c] # {} THEN PopFinalize(h, c, req, o)
    ELSE LET S == Split(h, c, CellSize[c], req, o) IN IF S # {} THEN S ELSE {Out(h, Fail)}

\* sweepOnDemandAllocate (OGS:2294): slices until a fit, the per-call cap (any
\* iteration), or no pending work
RECURSIVE SODIter(_, _, _, _)
SODIter(h, c, req, o) ==
    UNION {LET T == TryFL(h1, c, req, o) IN
           Succ(T) \cup UNION {{x} \cup (IF Pending(x.h) THEN SODIter(x.h, c, req, o) ELSE {})
                               : x \in Fails(T)}
           : h1 \in SweepSlice(h, c)}
SweepOnDemand(h, c, req, o) ==
    Then(TryFL(h, c, req, o), LAMBDA hh : IF Pending(hh) THEN SODIter(Ev(hh, "sod"), c, req, o) ELSE {Out(hh, Fail)})

\* panicSweepAndRetryAllocation (OGS:2326): while pending work remains
RECURSIVE PanicIter(_, _, _, _)
PanicIter(h, c, req, o) ==
    UNION {Then(TryFL(h1, c, req, o),
                LAMBDA hh : IF Pending(hh) THEN PanicIter(hh, c, req, o) ELSE {Out(hh, Fail)})
           : h1 \in SweepSlice(h, c)}
Panic(h, c, req, o) == IF Pending(h) THEN PanicIter(Ev(h, "panic"), c, req, o) ELSE {Out(h, Fail)}

-----------------------------------------------------------------------------
(* allocateFromBagPage (OGS:2528): the (LOT, alloc_buffer_size) band, and   *)
(* the ladder's bag rung with a size-classed request (CR-029).              *)

\* step 3: a fresh page, materialized mixed (fully_swept only mid-cycle), carved at
\* offset 0; any nonzero remainder goes through the packer, which gives a tail under
\* MIN_FREE_CELL_SIZE an unlinked Tag_Free header (CR-033 fixed, HEAP_024).
\* bag_tail_headerless: the pre-fix code (a remainder under MinCell gets no header).
FreshPage(h, req, o) ==
    LET h1 == EnsureBag(h) IN
    IF h1.bag = <<>> THEN {Out(h1, Fail)}
    ELSE LET s == h1.bag[Len(h1.bag)]
             m == Materialize([h1 EXCEPT !.bag = TruncLast(@)], s, Mixed, FALSE, G, 0,
                              h1.phase # "Idle")
             rem == G - req
             h3 == IF rem >= MinCell \/ ("bag_tail_headerless" \notin MUTANT /\ rem > 0)
                   THEN Push(m.h, s, req, rem, m.id) ELSE m.h
             h4 == IF rem > 0 /\ rem < MinCell THEN Ev(h3, "bagtail") ELSE h3
         IN {Out([Gate(Ev(h4, "bagfresh"), <<s, 0>>, req) EXCEPT !.mem[s][0] = OH(o)], <<s, 0>>)}

\* step 2: budgeted slices, each followed by a split retry; then step 3
RECURSIVE BagSweep(_, _, _, _)
BagSweep(h, rc, req, o) ==
    UNION {LET S == Split(h1, rc, req, req, o) IN
           IF S # {} THEN S
           ELSE FreshPage(h1, req, o) \cup (IF Pending(h1) THEN BagSweep(h1, rc, req, o) ELSE {})
           : h1 \in SweepSlice(h, rc)}
MarkSC(S, req) == {IF x.r # Fail /\ SizeClass(req) < NC THEN Out([x.h EXCEPT !.bagsc = TRUE], x.r) ELSE x
                   : x \in S}
BagPage(h, req, o) ==
    LET rc == SizeClass(req)
        S1 == Split(h, rc, req, req, o)                          \* step 1
    IN MarkSC(IF S1 # {} THEN S1
              ELSE IF Pending(h) THEN BagSweep(Ev(h, "bagsweep"), rc, req, o) ELSE FreshPage(h, req, o), req)

\* the eight rungs (OGS:973-1011)
Rung8(h, c, req, o) == Panic(h, c, req, o)
Rung7(h, c, req, o) == Then(BagPage(h, req, o), LAMBDA hh : Rung8(hh, c, req, o))
Rung6(h, c, req, o) == Then(VirginThenCursor(h, c, req, o), LAMBDA hh : Rung7(hh, c, req, o))
Rung5(h, c, req, o) == IF Pending(h) THEN Then(SweepOnDemand(h, c, req, o), LAMBDA hh : Rung6(hh, c, req, o))
                       ELSE Rung6(h, c, req, o)
Rung4(h, c, req, o) == LET S == Split(h, c, CellSize[c], req, o) IN IF S # {} THEN S ELSE Rung5(h, c, req, o)
Rung3(h, c, req, o) == IF BagFirst THEN Then(VirginThenCursor(h, c, req, o), LAMBDA hh : Rung4(hh, c, req, o))
                       ELSE Rung4(h, c, req, o)
Rung2(h, c, req, o) == IF h.fl[c] # {} THEN PopFinalize(h, c, req, o) ELSE Rung3(h, c, req, o)
Ladder(h, c, req, o) == Then(CursorAlloc(h, c, req, o), LAMBDA hh : Rung2(hh, c, req, o))

-----------------------------------------------------------------------------
(* allocateLargeBlock (OGS:2918): a free large block, the empty-block flip, *)
(* or a fresh block.                                                        *)

\* allocateFromFreeLargeBlocks (OGS:2813): first fit (every block here is one page), swap-remove
FromFreeLarge(h, req, o) ==
    LET id == h.flarge[1]  s == h.blk[id].s
        h1 == [h EXCEPT !.flarge = SwapRemoveAt(@, 1), !.blk[id].eoo = req, !.blk[id].lb = req,
                        !.blk[id].fs = TRUE, !.blk[id].marks = {}, !.blk[id].lmark = FALSE]
    IN Out([Gate(Ev(h1, "freelarge"), <<s, 0>>, 0) EXCEPT !.mem[s][0] = OH(o)], <<s, 0>>)

\* allocateFromEmptyRegularBlocks (OGS:2855): the first block by position that is
\* fully_swept with live_bytes == 0 (CR-018 / CR-016 / CR-035 trust these), not large.
\* `lie`: a rooted object, or a registered young large object, is in the block.
FlipOK(h, id, req) ==
    /\ h.blk[id].fs /\ (h.blk[id].lb = 0 \/ "flip_ignores_live" \in MUTANT)
    /\ ~h.blk[id].lg /\ ~h.blk[id].los /\ G >= req
Flip(h, id, req, o) ==
    LET s == h.blk[id].s
        lie == \/ \E x \in Objs : h.objs[x].st = "A" /\ h.objs[x].s = s /\ h.objs[x].root
               \/ \E m \in Range(h.owned) : h.meta[m].base # Null /\ h.meta[m].base[1] = s
        h1 == RemoveFreeCells(Detach(h, id), id, FALSE)
        h2 == IF "flip_keeps_index" \in MUTANT THEN h1 ELSE PurgeIndex(h1, s)   \* CR-035 fixed: retireIndexRange
        h3 == [h2 EXCEPT !.blk[id].lg = TRUE, !.blk[id].cls = Mixed, !.blk[id].eoo = req,
                         !.blk[id].lb = req, !.blk[id].fs = TRUE, !.blk[id].marks = {},
                         !.blk[id].lmark = FALSE, !.lie = @ \/ lie]
    IN Out([Gate(Ev(h3, "flip"), <<s, 0>>, 0) EXCEPT !.mem[s][0] = OH(o)], <<s, 0>>)

\* a fresh large block (OGS:2929-2975): the Allocator's page, born fully_swept only mid-cycle
FreshLarge(h, req, o) ==
    LET a == Acquire(h) IN
    IF a.s = 0 THEN {Out(a.h, Fail)}
    ELSE LET m == Materialize(a.h, a.s, Mixed, TRUE, req, req, a.h.phase # "Idle") IN
         {Out([Gate(Ev(m.h, "freshlarge"), <<a.s, 0>>, 0) EXCEPT !.mem[a.s][0] = OH(o)], <<a.s, 0>>)}

LargeBlock(h, req, o) ==
    IF h.flarge # <<>> THEN {FromFreeLarge(h, req, o)}
    ELSE LET hs == Sync(h)
             cands == {i \in 1..Len(hs.order) : FlipOK(hs, hs.order[i], req)}
         IN IF cands # {} THEN {Flip(hs, hs.order[Min(cands)], req, o)}
            ELSE FreshLarge(hs, req, o)

\* allocate (OGS:1971): the upfront slice while Sweeping, then the size dispatch
Allocate(h, req, o) ==
    UNION {IF req >= G THEN LargeBlock(h1, req, o)
           ELSE IF SizeClass(req) < NC THEN Ladder(h1, SizeClass(req), req, o)
           ELSE BagPage(h1, req, o)
           : h1 \in SweepSlice0(h, SizeClass(req))}

-----------------------------------------------------------------------------
(* plans/large-object-space.md D2 (HEAP_080): the LOS. allocateTrackedCell  *)
(* -> allocateLos: LargeObjectSpace::tryAllocate over the LOS blocks, else  *)
(* addLosBlock (a bag page materialized as an LOS block, born fully_swept,  *)
(* end_of_objects = the block) and retry. A model granule stands for an LOS *)
(* granule. A run is free iff no allocated object covers it: the code's     *)
(* bitmap is unit-tested against such a shadow (LargeObjectSpaceTest); the  *)
(* code's best fit is one of the runs chosen freely here.                  *)

LosRunFree(h, s, off, sz) ==
    /\ off + sz <= G
    /\ \A x \in Objs : ~(/\ h.objs[x].st = "A" /\ h.objs[x].s = s
                         /\ h.objs[x].off < off + sz /\ off < h.objs[x].off + h.objs[x].sz)
\* initObjectHeaderWithSize at the cell (Gate: black mid-sweep, live_bytes in every phase)
LosPlace(h, id, off, sz, o) ==
    LET s == h.blk[id].s IN
    Out([Gate(Ev(h, "los_alloc"), <<s, off>>, sz) EXCEPT !.mem[s][off] = OH(o)], <<s, off>>)
LosAlloc(h, sz, o) ==
    LET fits == {p \in Ids \X Offs : h.blk[p[1]].live /\ h.blk[p[1]].los
                                     /\ LosRunFree(h, h.blk[p[1]].s, p[2], sz)}
    IN IF fits # {} THEN {LosPlace(h, p[1], p[2], sz, o) : p \in fits}
       ELSE LET h1 == EnsureBag(h) IN
            IF h1.bag = <<>> THEN {Out(h1, Fail)}
            ELSE LET s == h1.bag[Len(h1.bag)]
                     m == Materialize([h1 EXCEPT !.bag = TruncLast(@)], s, Mixed, FALSE, G, 0, TRUE)
                 IN {LosPlace([Ev(m.h, "los_block") EXCEPT !.blk[m.id].los = TRUE], m.id, 0, sz, o)}

\* freeLargeBodyCell's LOS arm / freeLosCell: the granules return to the LOS (the
\* object stops being allocated), the bit clears, live_bytes drops
FreeLosCell(h, id, a, cs) ==
    [Ev(h, "los_free") EXCEPT !.blk[id].lb = Sub0(@, cs), !.blk[id].marks = @ \ {a[2]},
                              !.objs = FreeObjsAt(h.objs, a[1], a[2], cs)]

\* a set as a sequence in ascending order (unordered_map iteration: any order is a
\* free choice in the code; ascending here)
RECURSIVE SetToSeq(_)
SetToSeq(S) == IF S = {} THEN <<>> ELSE LET x == Min(S) IN <<x>> \o SetToSeq(S \ {x})

RECURSIVE SumSz(_, _)
SumSz(h, S) == IF S = {} THEN 0 ELSE LET o == CHOOSE x \in S : TRUE IN h.objs[o].sz + SumSz(h, S \ {o})

\* losSweepAtMarkEnd (inside finalizeMetaAfterMark, after the mark): every unmarked
\* tracked entry in an LOS block is freed and retired (retireIndexEntry: base =
\* nullptr; a kind-2 id is recycled, an owned id is dropped by the next minor);
\* then every LOS block's live_bytes = its used granules.
LosSweep(h) ==
    IF ~LOS THEN h
    ELSE LET dead == {a \in Addrs : h.index[a] # 0 /\ BlockAt(h, a[1]) # 0
                                    /\ h.blk[BlockAt(h, a[1])].los
                                    /\ a[2] \notin h.blk[BlockAt(h, a[1])].marks}
             h1 == [IF dead # {} THEN Ev(h, "los_sweep") ELSE h EXCEPT
                     !.objs = [o \in Objs |-> IF h.objs[o].st = "A" /\ <<h.objs[o].s, h.objs[o].off>> \in dead
                                              THEN [h.objs[o] EXCEPT !.st = "F"] ELSE h.objs[o]],
                     !.meta = [m \in Metas |-> IF \E a \in dead : h.index[a] = m
                                              THEN [h.meta[m] EXCEPT !.base = Null] ELSE h.meta[m]],
                     !.freeMeta = @ \o SetToSeq({m \in Metas : (\E a \in dead : h.index[a] = m)
                                                    /\ h.meta[m].kind = 2}),
                     !.index = [a \in Addrs |-> IF a \in dead THEN 0 ELSE h.index[a]]]
         IN [h1 EXCEPT !.blk = [i \in Ids |-> IF h1.blk[i].live /\ h1.blk[i].los
                     THEN [h1.blk[i] EXCEPT !.lb = SumSz(h1, {o \in Objs : h1.objs[o].st = "A"
                                                                        /\ h1.objs[o].s = h1.blk[i].s})]
                     ELSE h1.blk[i]]]

\* losReleaseEmptyBlocks (after the reclaim): empty LOS blocks beyond LosKeep, above
\* the floor, released (releaseBlockToAllocator), lowest position first
RECURSIVE LosReleaseFrom(_, _, _)
LosReleaseFrom(h, kept, i) ==
    IF i > Len(h.order) THEN h
    ELSE LET id == h.order[i]  b == h.blk[id]
             empty == b.los /\ ~\E o \in Objs : h.objs[o].st = "A" /\ h.objs[o].s = b.s
         IN IF ~empty THEN LosReleaseFrom(h, kept, i + 1)
            ELSE IF kept < LosKeep \/ CurHeap(h) - 1 < MinHeap THEN LosReleaseFrom(h, kept + 1, i + 1)
            ELSE LosReleaseFrom(Ev(Release(h, id, TRUE), "los_release"), kept, i)
LosReleaseEmpty(h) == IF LOS THEN LosReleaseFrom(h, 0, 1) ELSE h

-----------------------------------------------------------------------------
(* Young large objects and split-header bookkeeping (HEAP_026, HEAP_062).   *)

\* registerLargeBody (OGS:7526) from allocateYoungLarge (OGS:7445) via
\* allocateTrackedCell (OGS:7379): cell_size is the block for is_large, the class cell
\* for a uniform block, else the request; is_large is decided by the size alone.
Register(h, o) ==
    LET a == <<h.objs[o].s, h.objs[o].off>>  sz == h.objs[o].sz
        id == BlockAt(h, a[1])
        cs == IF h.blk[id].lg THEN G ELSE IF h.blk[id].cls < NC THEN CellSize[h.blk[id].cls] ELSE sz
        reuse == h.freeMeta # <<>>
        m == IF reuse THEN h.freeMeta[Len(h.freeMeta)] ELSE h.mhw + 1
    IN [h EXCEPT !.freeMeta = IF reuse THEN TruncLast(@) ELSE @,
                 !.mhw = IF reuse THEN @ ELSE @ + 1,
                 !.meta[m] = [base |-> a, cs |-> cs, lg |-> sz >= G /\ ~h.blk[id].los, color |-> h.color,
                              kind |-> 1, o |-> o],
                 !.index[a] = m,
                 !.owned = Append(@, m)]
\* plans/large-object-space.md D3: allocateOldLarge registers a pinned object as kind 2
\* (old, never nursery-owned)
RegisterOld(h, o) ==
    LET a == <<h.objs[o].s, h.objs[o].off>>
        reuse == h.freeMeta # <<>>
        m == IF reuse THEN h.freeMeta[Len(h.freeMeta)] ELSE h.mhw + 1
    IN [h EXCEPT !.freeMeta = IF reuse THEN TruncLast(@) ELSE @,
                 !.mhw = IF reuse THEN @ ELSE @ + 1,
                 !.meta[m] = [base |-> a, cs |-> h.objs[o].sz, lg |-> FALSE, color |-> h.color,
                              kind |-> 2, o |-> o],
                 !.index[a] = m]
MetaAvail(h) == h.freeMeta # <<>> \/ h.mhw < NMeta

\* freeUniformCell (OGS:1014)
FreeUniformCell(h, id, a) ==
    LET b == h.blk[id]  c == b.cls  k == a[2] \div CellSize[c]
        h1 == IF b.st = "current" /\ h.cur[c].id = id
              THEN [h EXCEPT !.blk[id].lb = @ + h.cur[c].pend, !.cur[c].pend = 0] ELSE h
        h2 == [h1 EXCEPT !.blk[id].marks = @ \ {a[2]},
                         !.objs = FreeObjsAt(h1.objs, a[1], a[2], CellSize[c])]
    IN IF b.st = "current"
       THEN [Ev(h2, "freeuniform") EXCEPT !.cur[c].nx = IF h2.cur[c].id = id /\ k < @ THEN k ELSE @]
       ELSE IF b.st = "none"
       THEN [Ev(h2, "freeuniform_queue") EXCEPT !.part[c] = Append(@, id), !.blk[id].st = "queued"]
       ELSE Ev(h2, "freeuniform")

\* freeLargeBodyCell (OGS:7686): erase(body_base) FIRST (whatever entry is at that
\* address now), then free what is at the address.
FreeLBC(h, m) ==
    LET mm == h.meta[m]  a == mm.base  s == a[1]
        h0 == [h EXCEPT !.index[a] = 0]
        id == BlockAt(h0, s)
        hN == [h0 EXCEPT !.meta[m].base = Null]
    IN IF ~mm.lg /\ id # 0 /\ h0.blk[id].los THEN FreeLosCell(hN, id, a, mm.cs)
       ELSE IF mm.lg
       THEN IF id = 0 \/ ~h0.blk[id].lg \/ id \in Range(h0.flarge) THEN Ev(hN, "freelbc_noop")
            ELSE [Ev(hN, "freelbc_large") EXCEPT !.blk[id].lb = 0, !.blk[id].fs = TRUE, !.blk[id].lmark = FALSE,
                            !.mem[s][0] = FH(G), !.flarge = Append(@, id),
                            !.objs = FreeObjsAt(hN.objs, s, 0, G)]
       ELSE IF id = 0 \/ h0.blk[id].lg THEN Ev(hN, "freelbc_noop")
       ELSE IF h0.blk[id].cls < NC
       THEN [FreeUniformCell(hN, id, a) EXCEPT !.blk[id].lb = Sub0(@, mm.cs)]
       ELSE IF SweepWillReach(h0, id, a[2])                         \* the gap sweep reclaims it
       THEN [Ev(hN, "freelbc_unswept") EXCEPT !.blk[id].marks = @ \ {a[2]}, !.blk[id].lb = Sub0(@, mm.cs)]
       ELSE LET h1 == Push([hN EXCEPT !.blk[id].marks = @ \ {a[2]}], s, a[2], mm.cs, id) IN
            [Ev(h1, "freelbc_mixed") EXCEPT !.blk[id].lb = Sub0(@, mm.cs), !.objs = FreeObjsAt(h1.objs, s, a[2], mm.cs)]

\* sweepNurseryLargeBodies (OGS:7581), no mark cycle: walk nursery_owned_bodies_ with
\* its swap-remove; free every entry the minor did not colour, recycle its id.
RECURSIVE SweepBodies(_, _)
SweepBodies(h, k) ==
    IF k > Len(h.owned) THEN h
    ELSE LET m == h.owned[k] IN
         IF h.meta[m].base = Null \/ h.meta[m].kind = 2 THEN SweepBodies([h EXCEPT !.owned = SwapRemoveAt(@, k)], k)
         ELSE IF h.meta[m].color = h.color THEN SweepBodies(h, k + 1)
         ELSE LET h1 == FreeLBC(h, m) IN
              SweepBodies([h1 EXCEPT !.freeMeta = Append(@, m), !.owned = SwapRemoveAt(@, k)], k)

\* promoteYoungLarge (OGS:7476)
PromoteYL(h, a, o) ==
    LET m == h.index[a] IN
    IF LOS /\ "promote_untracks" \notin MUTANT
    THEN [Ev(h, "promoteyl_los") EXCEPT !.owned = IF m \in Range(@) THEN SwapRemoveAt(@, FirstIdx(@, m)) ELSE @,
                    !.meta[m].kind = 2, !.objs[o].age = 0, !.objs[o].ylos = FALSE]
    ELSE
    [Ev(h, "promoteyl") EXCEPT !.owned = IF m \in Range(@) THEN SwapRemoveAt(@, FirstIdx(@, m)) ELSE @,
              !.index[a] = 0, !.meta[m].base = Null, !.meta[m].kind = 0,
              !.freeMeta = Append(@, m), !.objs[o].age = 0, !.objs[o].ylos = FALSE]

\* NurserySpace::reachYoungLarge (NurserySpace.cpp:1783): youngLargeMeta by address
\* (OGH:1217: a kind-1 entry whose body_base is the address); once per minor; promote
\* in place at promotion_age, else age.
Reach(h, o) ==
    LET a == <<h.objs[o].s, h.objs[o].off>>  m == h.index[a]
        h0 == [h EXCEPT !.toReach = @ \ {o}]
    IN IF m = 0 \/ h.meta[m].kind # 1 \/ h.meta[m].base # a THEN Ev(h0, "reach_miss")
       ELSE IF h.meta[m].color = h.color THEN h0
       ELSE LET h1 == [h0 EXCEPT !.meta[m].color = h.color] IN
            IF h.objs[o].age >= PromoAge THEN PromoteYL(h1, a, o)
            ELSE [h1 EXCEPT !.objs[o].age = @ + 1]

-----------------------------------------------------------------------------
(* The STW major: ThreadLocalHeap::majorGC (TLH:790) -> startMark ->        *)
(* prepareMark (OGS:2983) -> the mark -> runPostMarkTail (OGS:4191).        *)

\* prepareMark: clearForMark, resetAllocCursors (after a sync), resetBufferMetaForMark
ResetForMark(h) ==
    [h EXCEPT !.blk = [i \in Ids |-> IF h.blk[i].live
                                     THEN [h.blk[i] EXCEPT !.marks = {}, !.lmark = FALSE, !.lb = 0,
                                                           !.fs = h.blk[i].los, !.st = "none"]
                                     ELSE h.blk[i]],
              !.cur = [c \in UCls |-> NoCur], !.part = [c \in UCls |-> <<>>]]

\* the mark: every rooted object is reached (no object graph: roots are the live set);
\* markOneObject attributes the walk step (the class cell in a uniform block, the
\* object's size otherwise); a dead uniform cell is free once its bit is clear (HEAP_054).
RECURSIVE MarkFrom(_, _)
MarkFrom(h, o) ==
    IF o > NObj THEN h
    ELSE LET x == h.objs[o]  id == BlockAt(h, x.s) IN
         MarkFrom(
            IF x.st # "A" \/ id = 0 THEN h
            ELSE IF x.root
            THEN IF h.blk[id].lg THEN [h EXCEPT !.blk[id].lmark = TRUE, !.blk[id].lb = @ + x.sz]
                 ELSE IF h.blk[id].cls < NC
                 THEN [h EXCEPT !.blk[id].marks = @ \cup {x.off}, !.blk[id].lb = @ + CellSize[h.blk[id].cls]]
                 ELSE [h EXCEPT !.blk[id].marks = @ \cup {x.off}, !.blk[id].lb = @ + x.sz]
            ELSE IF ~h.blk[id].lg /\ h.blk[id].cls < NC THEN [h EXCEPT !.objs[o].st = "F"]
            ELSE h,
            o + 1)

\* finalizeMetaAfterMark: clamp live_bytes to the parseable span
Clamp(h) == [h EXCEPT !.blk = [i \in Ids |-> IF h.blk[i].lb > h.blk[i].eoo
                                             THEN [h.blk[i] EXCEPT !.lb = h.blk[i].eoo] ELSE h.blk[i]]]

\* demoteMostlyDeadUniformBlocks: live_bytes <= f * total -> mixed; never the block at
\* heap_base (slot 1)
Demotable(h, i) == h.blk[i].live /\ ~h.blk[i].lg /\ h.blk[i].cls < NC /\ h.blk[i].s # 1
                   /\ h.blk[i].lb <= DemoteMax
Demote(h) == IF DemoteMax < 0 THEN h
             ELSE [IF \E i \in Ids : Demotable(h, i) THEN Ev(h, "demote") ELSE h
                   EXCEPT !.blk = [i \in Ids |-> IF Demotable(h, i) THEN [h.blk[i] EXCEPT !.cls = Mixed]
                                                 ELSE h.blk[i]]]

\* transitionToSweeping (OGS:5451)
ToSweeping(h) == [h EXCEPT !.phase = "Sweeping", !.swIdx = 1, !.swCur = -1,
                           !.fl = [c \in FLCls |-> {}], !.flarge = <<>>]

\* adjustCapacityAfterMajorGC (OGS:5993): the heavy shrink (before classify every block
\* is unswept, so only bag pages can go), a grow (ensureOldGenCapacityFor: here one
\* page), or neither
Grow(h) == LET a == Acquire(h) IN IF a.s # 0 THEN {[Ev(a.h, "grow") EXCEPT !.bag = Append(@, a.s)]} ELSE {}
AdjustCap(h) == {h} \cup Shrink(h) \cup Grow(h)

\* retireDeadLargeBodies (OGS:1793): unmarked entries in non-large blocks
RetireDead(h) ==
    LET dead == {a \in Addrs : h.index[a] # 0 /\ BlockAt(h, a[1]) # 0 /\ ~h.blk[BlockAt(h, a[1])].lg
                               /\ a[2] \notin h.blk[BlockAt(h, a[1])].marks}
    IN [IF dead # {} THEN Ev(h, "retire") ELSE h EXCEPT !.meta = [m \in Metas |-> IF \E a \in dead : h.index[a] = m
                                           THEN [h.meta[m] EXCEPT !.base = Null] ELSE h.meta[m]],
                 !.index = [a \in Addrs |-> IF a \in dead THEN 0 ELSE h.index[a]]]

\* classifyBlocksAfterMark (OGS:1815)
RECURSIVE ClassifyFrom(_, _)
ClassifyFrom(h, i) ==
    IF i > Len(h.order) THEN h
    ELSE LET id == h.order[i]  b == h.blk[id]  s == b.s IN
         ClassifyFrom(
            IF b.lg
            THEN IF b.lmark THEN [h EXCEPT !.blk[id].lmark = FALSE, !.blk[id].fs = TRUE]
                 ELSE LET hd == h.mem[s][0]
                          m == h.index[<<s, 0>>]
                          h1 == IF hd.t = "o" /\ h.objs[hd.v].pin /\ m # 0
                                THEN [h EXCEPT !.meta[m].base = Null, !.index[<<s, 0>>] = 0] ELSE h
                      IN [Ev(h1, "classify_freelarge") EXCEPT !.flarge = Append(@, id), !.blk[id].fs = TRUE,
                                    !.objs = FreeObjsAt(h1.objs, s, 0, G)]
            ELSE IF b.cls < NC
            THEN LET q == b.lb < NCells(b.cls) * CellSize[b.cls] /\ b.st # "queued" IN
                 [h EXCEPT !.blk[id].fs = TRUE,
                           !.part[b.cls] = IF q THEN Append(@, id) ELSE @,
                           !.blk[id].st = IF q THEN "queued" ELSE @]
            ELSE h,
            i + 1)
Classify(h) == ClassifyFrom(RetireDead(h), 1)

PostDrain(h) ==
    LET h6 == ToSweeping(Demote(Clamp(LosSweep(MarkFrom(ResetForMark(Sync(h)), 1))))) IN
    UNION {SweepSlice0(Classify(h8), NCLS) : h8 \in AdjustCap(LosReleaseEmpty(Reclaim(h6)))}
Major(h) == UNION {PostDrain(h1) : h1 \in Drain(h)}

-----------------------------------------------------------------------------
(* Operations.                                                              *)

Tick(h) == [h EXCEPT !.ops = @ + 1]
\* a younger allocation overlaps an older rooted object (object ids are handed out in
\* allocation order and never reused): NoOverwriteLive's negation, also for Keep
OverwritesLive(h) ==
    \E o1, o2 \in Objs :
        /\ o1 < o2 /\ h.objs[o1].root /\ h.objs[o1].st = "A" /\ h.objs[o2].st = "A"
        /\ h.objs[o1].s = h.objs[o2].s
        /\ h.objs[o1].off < h.objs[o2].off + h.objs[o2].sz
        /\ h.objs[o2].off < h.objs[o1].off + h.objs[o1].sz
FreshObj(h) == {o \in Objs : h.objs[o].st = "N"}
NewObj(h) == Min(FreshObj(h))
Create(h, o, a, sz, ylos, pin) ==
    [h EXCEPT !.objs[o] = [st |-> "A", s |-> a[1], off |-> a[2], sz |-> sz, root |-> TRUE,
                           ylos |-> ylos, pin |-> pin, age |-> 0]]
\* ThreadLocalHeap::allocateLargePinned (pin) / allocateYoungLarge (pin, registered) /
\* a promotion (no pin). A failed allocation keeps what its sweeps did (the caller's
\* retry after a major is another operation).
AllocOp(h, sz, ylos, pin) ==
    LET o == NewObj(h)
        los == LOS /\ pin /\ sz <= G
        S == {IF x.r = Fail THEN Tick(x.h)
              ELSE LET h1 == Create(x.h, o, x.r, sz, ylos, pin) IN
                   Tick(IF ylos THEN Register(h1, o) ELSE IF los THEN RegisterOld(h1, o) ELSE h1)
              : x \in IF los THEN LosAlloc(h, sz, o) ELSE Allocate(h, sz, o)}
    IN {n \in S : Keep(n)}

Drop(h, o) == Tick([h EXCEPT !.objs[o].root = FALSE])

\* NurserySpace::minorGC: the colour flips at the start (NurserySpace.cpp:503); every
\* root is evacuated (a rooted YLOS object is reached); sweepNurseryLargeBodies at the end.
MinorStart(h) == Tick([h EXCEPT !.color = ~@, !.minor = TRUE,
                        !.toReach = {o \in Objs : h.objs[o].st = "A" /\ h.objs[o].root /\ h.objs[o].ylos}])
MinorEnd(h) == [SweepBodies(h, 1) EXCEPT !.minor = FALSE]

(* --algorithm BlockLifecycle
variables h = H0;

define
    \* ---- invariants (MAPPING.md §5) ----
    ObjAddr(o) == <<h.objs[o].s, h.objs[o].off>>
    InFreeCell(s, g) == \E c \in FLCls : \E a \in h.fl[c] :
                            a[1] = s /\ a[2] <= g /\ g < a[2] + CellSize[c]
    FreeLargeSlot(s) == \E i \in 1..Len(h.flarge) : h.blk[h.flarge[i]].s = s
    Unowned(s) == s \in Range(h.bag) \/ s \in Range(h.ext) \/ s >= h.bump
    Disjoint(o1, o2) == \/ h.objs[o1].s # h.objs[o2].s
                        \/ h.objs[o1].off + h.objs[o1].sz <= h.objs[o2].off
                        \/ h.objs[o2].off + h.objs[o2].sz <= h.objs[o1].off
    Allocated(o) == h.objs[o].st = "A"
    Rooted(o) == h.objs[o].root

    \* No rooted object is freed, released, covered by free space or has lost its header.
    NoLostObject ==
        \A o \in Objs : Rooted(o) =>
            LET s == h.objs[o].s  off == h.objs[o].off IN
            /\ Allocated(o)
            /\ BlockAt(h, s) # 0
            /\ h.mem[s][off] = OH(o)
            /\ ~FreeLargeSlot(s) /\ ~Unowned(s)
            /\ \A g \in off..(off + h.objs[o].sz - 1) : ~InFreeCell(s, g)
    \* No allocation lands on a rooted object (ids are handed out in allocation order).
    NoOverwriteLive == ~OverwritesLive(h)
    \* No cell is handed out twice: allocated objects never overlap each other or free
    \* space, and free cells never overlap each other.
    NoDoubleAlloc ==
        /\ \A o1, o2 \in Objs : o1 # o2 /\ Allocated(o1) /\ Allocated(o2) => Disjoint(o1, o2)
        /\ \A o \in Objs : Allocated(o) =>
              /\ ~FreeLargeSlot(h.objs[o].s) /\ ~Unowned(h.objs[o].s)
              /\ \A g \in h.objs[o].off..(h.objs[o].off + h.objs[o].sz - 1) : ~InFreeCell(h.objs[o].s, g)
        /\ \A c1, c2 \in FLCls : \A a1 \in h.fl[c1], a2 \in h.fl[c2] :
              <<c1, a1>> # <<c2, a2>> =>
                 a1[1] # a2[1] \/ a1[2] + CellSize[c1] <= a2[2] \/ a2[2] + CellSize[c2] <= a1[2]
    \* Every mixed or large block parses by header over [start, end_of_objects), except a
    \* mixed block the running sweep has still to walk (the gap sweep rewrites its dead
    \* space first); and the gap sweep never read a non-object header at a set bit.
    BlockParseable ==
        /\ ~h.bad
        /\ \A id \in Ids :
              LET b == h.blk[id] IN
              b.live /\ (b.lg \/ b.cls = Mixed) /\ ~b.los /\ ~(h.phase = "Sweeping" /\ ~b.fs)
                  => Walk(h, b.s, 0, b.eoo)
    \* Every large_body_index_ entry names the registered young object at that address;
    \* every registered entry is indexed; recycled ids are clean; every rooted young
    \* large object is registered.
    IndexFaithful ==
        /\ \A a \in Addrs : h.index[a] # 0 =>
              LET m == h.index[a]  o == h.meta[m].o IN
              /\ h.meta[m].base = a /\ o \in Objs /\ Allocated(o) /\ ObjAddr(o) = a
              /\ \/ h.meta[m].kind = 1 /\ m \in Range(h.owned) /\ h.objs[o].ylos
                 \/ LOS /\ h.meta[m].kind = 2 /\ m \notin Range(h.owned) /\ ~h.objs[o].ylos
              /\ h.mem[a[1]][a[2]] = OH(o)
        /\ \A m \in Range(h.owned) : h.meta[m].base # Null => h.index[h.meta[m].base] = m
        /\ \A i \in 1..Len(h.freeMeta) :
              /\ h.meta[h.freeMeta[i]].base = Null
              /\ \A j \in 1..Len(h.freeMeta) : j # i => h.freeMeta[j] # h.freeMeta[i]
        /\ \A o \in Objs : Allocated(o) /\ Rooted(o) /\ h.objs[o].ylos =>
              h.index[ObjAddr(o)] # 0 /\ h.meta[h.index[ObjAddr(o)]].o = o
    \* Every free-list cell lies in a live mixed block, inside end_of_objects, and carries
    \* its Tag_Free header of the class size.
    FreeListsInLiveBlocks ==
        \A c \in FLCls : \A a \in h.fl[c] :
            LET id == BlockAt(h, a[1]) IN
            /\ id # 0 /\ ~h.blk[id].lg /\ h.blk[id].cls = Mixed /\ ~h.blk[id].los
            /\ a[2] + CellSize[c] <= h.blk[id].eoo
            /\ h.mem[a[1]][a[2]] = FH(CellSize[c])
    \* What the flip and the releases trust (live_bytes == 0, fully_swept) was true.
    FlipTrustsTruth == ~h.lie
    \* plans/large-object-space.md (HEAP_080): every object in an LOS block is tracked
    \* (the LOS frees only through the index), and the spaces are separate: pinned and
    \* young large objects live in LOS blocks, promoted copies never do.
    LosTracked ==
        LOS => \A o \in Objs :
                  Allocated(o) /\ BlockAt(h, h.objs[o].s) # 0 /\ h.blk[BlockAt(h, h.objs[o].s)].los =>
                     h.index[ObjAddr(o)] # 0 /\ h.meta[h.index[ObjAddr(o)]].o = o
    LosSeparation ==
        LOS => \A o \in Objs :
                  Allocated(o) /\ BlockAt(h, h.objs[o].s) # 0 =>
                     (h.blk[BlockAt(h, h.objs[o].s)].los <=> (h.objs[o].pin /\ h.objs[o].sz <= G))
    \* The id- and address-keyed tables agree with the blocks.
    SideTablesFaithful ==
        /\ \A c \in UCls : \A i \in 1..Len(h.part[c]) :
              LET id == h.part[c][i] IN
              /\ h.blk[id].live /\ ~h.blk[id].lg /\ h.blk[id].cls = c /\ h.blk[id].st = "queued"
              /\ \A j \in 1..Len(h.part[c]) : j # i => h.part[c][j] # id
        /\ \A id \in Ids : h.blk[id].live /\ h.blk[id].st = "queued" => id \in Range(h.part[h.blk[id].cls])
        /\ \A c \in UCls : h.cur[c].id # 0 =>
              h.blk[h.cur[c].id].live /\ h.blk[h.cur[c].id].cls = c /\ h.blk[h.cur[c].id].st = "current"
        /\ \A id \in Ids : h.blk[id].live /\ h.blk[id].st = "current" => h.cur[h.blk[id].cls].id = id
        /\ \A i \in 1..Len(h.flarge) : h.blk[h.flarge[i]].live /\ h.blk[h.flarge[i]].lg
        /\ \A s \in Slots : h.owner[s] # 0 => h.blk[h.owner[s]].live /\ h.blk[h.owner[s]].s = s
        /\ \A id \in Ids : h.blk[id].live => h.owner[h.blk[id].s] = id /\ id \in Range(h.order)
        /\ \A i \in 1..Len(h.order) : h.blk[h.order[i]].live
        /\ \A i, j \in 1..Len(h.order) : i # j => h.order[i] # h.order[j]
        /\ \A i \in 1..Len(h.freeIds) : ~h.blk[h.freeIds[i]].live
        /\ \A i, j \in 1..Len(h.freeIds) : i # j => h.freeIds[i] # h.freeIds[j]
        /\ \A s \in Slots : ~(BlockAt(h, s) # 0 /\ Unowned(s))
    \* ---- witnesses (a violation shows the state is reachable) ----
    NoSizeClassedBagCarve == ~h.bagsc          \* CR-029: the bag rung carves a size-classed request
    NoSameIdSameStartReissue == ~h.reissue     \* CR-036: a released id comes back at its old start
end define;

process Mut = "mut"
begin
Top:
    while h.ops < MaxOps \/ h.minor do
        either      \* the mutator's direct old-gen allocation (allocateLargePinned)
            await ~h.minor /\ FreshObj(h) # {} /\ (~LOS \/ MetaAvail(h));
            with sz \in MutSizes, n \in AllocOp(h, sz, FALSE, TRUE) do h := n end with;
        or          \* a young large object (allocateYoungLarge)
            await ~h.minor /\ FreshObj(h) # {} /\ MetaAvail(h);
            with sz \in YlosSizes, n \in AllocOp(h, sz, TRUE, TRUE) do h := n end with;
        or          \* the mutator drops its reference
            await ~h.minor;
            with o \in {x \in Objs : h.objs[x].root} do h := Drop(h, o) end with;
        or          \* a stop-the-world major (a trigger, an allocation failure)
            await ~h.minor;
            with n \in Major(h) do h := Tick(n) end with;
        or          \* a minor GC starts
            await ~h.minor;
            h := MinorStart(h);
        or          \* a promotion (allocate() inside the minor)
            await h.minor /\ h.ops < MaxOps /\ FreshObj(h) # {};
            with sz \in PromoSizes, n \in AllocOp(h, sz, FALSE, FALSE) do h := n end with;
        or          \* the minor evacuates a root that holds a young large object
            await h.minor;
            with o \in h.toReach do h := Reach(h, o) end with;
        or          \* the minor's end: sweepNurseryLargeBodies
            await h.minor /\ h.toReach = {};
            h := MinorEnd(h);
        end either;
    end while;
end process;
end algorithm; *)

\* BEGIN TRANSLATION
VARIABLES pc, h

(* define statement *)
ObjAddr(o) == <<h.objs[o].s, h.objs[o].off>>
InFreeCell(s, g) == \E c \in FLCls : \E a \in h.fl[c] :
                        a[1] = s /\ a[2] <= g /\ g < a[2] + CellSize[c]
FreeLargeSlot(s) == \E i \in 1..Len(h.flarge) : h.blk[h.flarge[i]].s = s
Unowned(s) == s \in Range(h.bag) \/ s \in Range(h.ext) \/ s >= h.bump
Disjoint(o1, o2) == \/ h.objs[o1].s # h.objs[o2].s
                    \/ h.objs[o1].off + h.objs[o1].sz <= h.objs[o2].off
                    \/ h.objs[o2].off + h.objs[o2].sz <= h.objs[o1].off
Allocated(o) == h.objs[o].st = "A"
Rooted(o) == h.objs[o].root


NoLostObject ==
    \A o \in Objs : Rooted(o) =>
        LET s == h.objs[o].s  off == h.objs[o].off IN
        /\ Allocated(o)
        /\ BlockAt(h, s) # 0
        /\ h.mem[s][off] = OH(o)
        /\ ~FreeLargeSlot(s) /\ ~Unowned(s)
        /\ \A g \in off..(off + h.objs[o].sz - 1) : ~InFreeCell(s, g)

NoOverwriteLive == ~OverwritesLive(h)


NoDoubleAlloc ==
    /\ \A o1, o2 \in Objs : o1 # o2 /\ Allocated(o1) /\ Allocated(o2) => Disjoint(o1, o2)
    /\ \A o \in Objs : Allocated(o) =>
          /\ ~FreeLargeSlot(h.objs[o].s) /\ ~Unowned(h.objs[o].s)
          /\ \A g \in h.objs[o].off..(h.objs[o].off + h.objs[o].sz - 1) : ~InFreeCell(h.objs[o].s, g)
    /\ \A c1, c2 \in FLCls : \A a1 \in h.fl[c1], a2 \in h.fl[c2] :
          <<c1, a1>> # <<c2, a2>> =>
             a1[1] # a2[1] \/ a1[2] + CellSize[c1] <= a2[2] \/ a2[2] + CellSize[c2] <= a1[2]



BlockParseable ==
    /\ ~h.bad
    /\ \A id \in Ids :
          LET b == h.blk[id] IN
          b.live /\ (b.lg \/ b.cls = Mixed) /\ ~b.los /\ ~(h.phase = "Sweeping" /\ ~b.fs)
              => Walk(h, b.s, 0, b.eoo)



IndexFaithful ==
    /\ \A a \in Addrs : h.index[a] # 0 =>
          LET m == h.index[a]  o == h.meta[m].o IN
          /\ h.meta[m].base = a /\ o \in Objs /\ Allocated(o) /\ ObjAddr(o) = a
          /\ \/ h.meta[m].kind = 1 /\ m \in Range(h.owned) /\ h.objs[o].ylos
             \/ LOS /\ h.meta[m].kind = 2 /\ m \notin Range(h.owned) /\ ~h.objs[o].ylos
          /\ h.mem[a[1]][a[2]] = OH(o)
    /\ \A m \in Range(h.owned) : h.meta[m].base # Null => h.index[h.meta[m].base] = m
    /\ \A i \in 1..Len(h.freeMeta) :
          /\ h.meta[h.freeMeta[i]].base = Null
          /\ \A j \in 1..Len(h.freeMeta) : j # i => h.freeMeta[j] # h.freeMeta[i]
    /\ \A o \in Objs : Allocated(o) /\ Rooted(o) /\ h.objs[o].ylos =>
          h.index[ObjAddr(o)] # 0 /\ h.meta[h.index[ObjAddr(o)]].o = o


FreeListsInLiveBlocks ==
    \A c \in FLCls : \A a \in h.fl[c] :
        LET id == BlockAt(h, a[1]) IN
        /\ id # 0 /\ ~h.blk[id].lg /\ h.blk[id].cls = Mixed /\ ~h.blk[id].los
        /\ a[2] + CellSize[c] <= h.blk[id].eoo
        /\ h.mem[a[1]][a[2]] = FH(CellSize[c])

FlipTrustsTruth == ~h.lie



LosTracked ==
    LOS => \A o \in Objs :
              Allocated(o) /\ BlockAt(h, h.objs[o].s) # 0 /\ h.blk[BlockAt(h, h.objs[o].s)].los =>
                 h.index[ObjAddr(o)] # 0 /\ h.meta[h.index[ObjAddr(o)]].o = o
LosSeparation ==
    LOS => \A o \in Objs :
              Allocated(o) /\ BlockAt(h, h.objs[o].s) # 0 =>
                 (h.blk[BlockAt(h, h.objs[o].s)].los <=> (h.objs[o].pin /\ h.objs[o].sz <= G))

SideTablesFaithful ==
    /\ \A c \in UCls : \A i \in 1..Len(h.part[c]) :
          LET id == h.part[c][i] IN
          /\ h.blk[id].live /\ ~h.blk[id].lg /\ h.blk[id].cls = c /\ h.blk[id].st = "queued"
          /\ \A j \in 1..Len(h.part[c]) : j # i => h.part[c][j] # id
    /\ \A id \in Ids : h.blk[id].live /\ h.blk[id].st = "queued" => id \in Range(h.part[h.blk[id].cls])
    /\ \A c \in UCls : h.cur[c].id # 0 =>
          h.blk[h.cur[c].id].live /\ h.blk[h.cur[c].id].cls = c /\ h.blk[h.cur[c].id].st = "current"
    /\ \A id \in Ids : h.blk[id].live /\ h.blk[id].st = "current" => h.cur[h.blk[id].cls].id = id
    /\ \A i \in 1..Len(h.flarge) : h.blk[h.flarge[i]].live /\ h.blk[h.flarge[i]].lg
    /\ \A s \in Slots : h.owner[s] # 0 => h.blk[h.owner[s]].live /\ h.blk[h.owner[s]].s = s
    /\ \A id \in Ids : h.blk[id].live => h.owner[h.blk[id].s] = id /\ id \in Range(h.order)
    /\ \A i \in 1..Len(h.order) : h.blk[h.order[i]].live
    /\ \A i, j \in 1..Len(h.order) : i # j => h.order[i] # h.order[j]
    /\ \A i \in 1..Len(h.freeIds) : ~h.blk[h.freeIds[i]].live
    /\ \A i, j \in 1..Len(h.freeIds) : i # j => h.freeIds[i] # h.freeIds[j]
    /\ \A s \in Slots : ~(BlockAt(h, s) # 0 /\ Unowned(s))

NoSizeClassedBagCarve == ~h.bagsc
NoSameIdSameStartReissue == ~h.reissue


vars == << pc, h >>

ProcSet == {"mut"}

Init == (* Global variables *)
        /\ h = H0
        /\ pc = [self \in ProcSet |-> "Top"]

Top == /\ pc["mut"] = "Top"
       /\ IF h.ops < MaxOps \/ h.minor
             THEN /\ \/ /\ ~h.minor /\ FreshObj(h) # {} /\ (~LOS \/ MetaAvail(h))
                        /\ \E sz \in MutSizes:
                             \E n \in AllocOp(h, sz, FALSE, TRUE):
                               h' = n
                     \/ /\ ~h.minor /\ FreshObj(h) # {} /\ MetaAvail(h)
                        /\ \E sz \in YlosSizes:
                             \E n \in AllocOp(h, sz, TRUE, TRUE):
                               h' = n
                     \/ /\ ~h.minor
                        /\ \E o \in {x \in Objs : h.objs[x].root}:
                             h' = Drop(h, o)
                     \/ /\ ~h.minor
                        /\ \E n \in Major(h):
                             h' = Tick(n)
                     \/ /\ ~h.minor
                        /\ h' = MinorStart(h)
                     \/ /\ h.minor /\ h.ops < MaxOps /\ FreshObj(h) # {}
                        /\ \E sz \in PromoSizes:
                             \E n \in AllocOp(h, sz, FALSE, FALSE):
                               h' = n
                     \/ /\ h.minor
                        /\ \E o \in h.toReach:
                             h' = Reach(h, o)
                     \/ /\ h.minor /\ h.toReach = {}
                        /\ h' = MinorEnd(h)
                  /\ pc' = [pc EXCEPT !["mut"] = "Top"]
             ELSE /\ pc' = [pc EXCEPT !["mut"] = "Done"]
                  /\ h' = h

Mut == Top

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Mut
           \/ Terminating

Spec == Init /\ [][Next]_vars

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION
=============================================================================
