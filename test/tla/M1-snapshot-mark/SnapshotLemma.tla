---------------------------- MODULE SnapshotLemma ----------------------------
(***************************************************************************)
(* The snapshot-closure lemma and the tri-colour invariant of M1, as an    *)
(* INDUCTIVE invariant (plans/threaded-gc-tla-M1-snapshot-mark.md §4.7).   *)
(*                                                                         *)
(* A plain-TLA+ restatement of SnapshotMark.tla's heap actions, for        *)
(* Apalache: no pc, legacy nursery mode (region mode has CR-017), no       *)
(* mutants. The t0 snapshot is fused with its minor, as in the code. The   *)
(* pause's inner steps (the closing drain, the handoff, a major's join)    *)
(* are separate actions, so the mutator may run between them. That is a   *)
(* superset of the model's behaviours, which is sound for an inductive     *)
(* invariant. Episodes, the fork stop and the step counter k are left out: *)
(* they only decide WHO scans and WHEN the handoff comes, and the handoff  *)
(* here may come at any moment the grey set is empty.                      *)
(*                                                                         *)
(* Inductive means: LemmaInv holds in the starting heap, and every step   *)
(* from ANY state satisfying it leads to a state satisfying it. Together   *)
(* they prove LemmaInv in every reachable state, for the heap size N, with *)
(* no bound on time. Apalache checks it as models.txt's deep-tier rows     *)
(* (lemma/*.args), one action per run so the SMT queries stay small:       *)
(*   base:  --init=Init    --inv=LemmaInv        --length=0                *)
(*   step:  --init=IndInit --next=<A> --inv=LemmaStep --length=1, each A   *)
(*   IM2:   --init=IndInit --inv=LemmaImpliesIM2 --length=0                *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Apalache

CONSTANTS
    \* @type: Int;
    N,              \* objects are 1..N; 0 is Nil
    \* @type: Set(Int);
    Fields,         \* pointer fields per object
    \* @type: Set(Str);
    RootSlots,      \* stack slots and RootSet roots
    \* @type: Set(Str);
    CellSlots,      \* off-heap mutable stores
    \* @type: Set(Int);
    YlosIds         \* ids that are young LARGE objects while young

Nil == 0
Obj == 1..N

VARIABLES
    \* @type: Set(Int);
    alloc,
    \* @type: Int -> Str;
    gen,
    \* @type: Int -> Int;
    age,
    \* @type: Int -> Bool;
    builder,
    \* @type: Int -> (Int -> Int);
    fld,
    \* @type: Str -> Int;
    root,
    \* @type: Str -> Int;
    cell,
    \* @type: Int -> Bool;
    mark,
    \* @type: Set(Int);
    grey,
    \* @type: Str;
    cycle,
    \* @type: Set(Int);
    deferred,
    \* @type: Set(Int);
    t0Old,          \* ghost: old objects at t0
    \* @type: Set(Int);
    t0Ylos,         \* ghost: young large objects at t0
    \* @type: Set(Int);
    tSH,            \* ghost: S_H, everything reachable at t0
    \* @type: Set(Int);
    tNH,            \* ghost: N_H, everything allocated since t0
    \* @type: Int -> (Int -> Int);
    fld0            \* ghost: every object's fields at t0

vars == <<alloc, gen, age, builder, fld, root, cell, mark, grey, cycle, deferred,
          t0Old, t0Ylos, tSH, tNH, fld0>>
ghosts == <<t0Old, t0Ylos, tSH, tNH, fld0>>

CInit5 == N = 5 /\ Fields = {1} /\ RootSlots = {"r1", "r2"} /\ CellSlots = {"c1"} /\ YlosIds = {5}
CInit6 == N = 6 /\ Fields = {1} /\ RootSlots = {"r1", "r2"} /\ CellSlots = {"c1"} /\ YlosIds = {5}
CInit8 == N = 8 /\ Fields = {1} /\ RootSlots = {"r1", "r2"} /\ CellSlots = {"c1"} /\ YlosIds = {5}
CInit6f2 == N = 6 /\ Fields = {1, 2} /\ RootSlots = {"r1", "r2"} /\ CellSlots = {"c1"} /\ YlosIds = {5}

-----------------------------------------------------------------------------
\* Heap operators, parameterised by a field map f so that a fused step can apply
\* them to its intermediate heap. Written for the SMT encoding: filters over the
\* CONCRETE set Obj, never maps over a symbolic set, and reachability as a boolean
\* vector iterated N times. (A fold of set comprehensions stalled Z3 for tens of
\* minutes on a single step at N = 5.)
\* @type: (Set(Int), Int -> (Int -> Int)) => Set(Int);
SuccIn(S, f) == {c \in Obj : \E p \in Obj : p \in S /\ \E i \in Fields : f[p][i] = c}
\* v[o] iff o is reachable from S by a path (length 0 or more) whose nodes after
\* the first are all in A. N rounds suffice: a simple path has fewer than N edges.
\* A fold, not recursion: Apalache rejects recursive operators and functions.
\* @type: (Set(Int), Set(Int), Int -> (Int -> Int)) => Int -> Bool;
ReachVec(S, A, f) ==
    LET \* @type: (Int -> Bool, Int) => Int -> Bool;
        Step(v, j) == [o \in Obj |-> v[o] \/ (o \in A /\ \E p \in Obj : v[p] /\ \E i \in Fields : f[p][i] = o)]
    IN ApaFoldSet(Step, [o \in Obj |-> o \in S], Obj)
\* @type: (Set(Int), Set(Int), Int -> (Int -> Int)) => Set(Int);
ReachWithinIn(S, A, f) == LET v == ReachVec(S, A, f) IN {o \in Obj : v[o]}
\* @type: (Set(Int), Int -> (Int -> Int)) => Set(Int);
ReachIn(S, f) == ReachWithinIn(S, Obj, f)

NoFields  == [i \in Fields |-> Nil]
Held      == {o \in Obj : (\E r \in RootSlots : root[r] = o) \/ (\E c \in CellSlots : cell[c] = o)}
Live      == ReachIn(Held, fld)
OldObjs   == {o \in alloc : gen[o] = "old"}
YoungSet  == {o \in alloc : gen[o] = "young"}
YoungObjs == YoungSet \ deferred
CellObjs  == OldObjs \cup (YoungSet \cap YlosIds)
Marked    == {o \in Obj : mark[o]}
CycleOn   == cycle # "idle"
\* @type: Set(Int) => Set(Int);
OldKids(S) == {c \in SuccIn(S, fld) : gen[c] = "old"}

-----------------------------------------------------------------------------
\* The starting heap of M1's MC.tla: old 1 -> 2, old 4, young 3 -> 4;
\* r1 -> 1, r2 -> 3; c1 empty.
Init ==
    /\ alloc = {1, 2, 3, 4}
    /\ gen = [o \in Obj |-> IF o \in {1, 2, 4} THEN "old" ELSE "young"]
    /\ age = [o \in Obj |-> 0]
    /\ builder = [o \in Obj |-> FALSE]
    /\ fld = [o \in Obj |-> [i \in Fields |->
                 IF i = 1 /\ o = 1 THEN 2 ELSE IF i = 1 /\ o = 3 THEN 4 ELSE Nil]]
    /\ root = [r \in RootSlots |-> IF r = "r1" THEN 1 ELSE 3]
    /\ cell = [c \in CellSlots |-> Nil]
    /\ mark = [o \in Obj |-> FALSE]
    /\ grey = {}
    /\ cycle = "idle"
    /\ deferred = {}
    /\ t0Old = {}
    /\ t0Ylos = {}
    /\ tSH = {}
    /\ tNH = {}
    /\ fld0 = [o \in Obj |-> NoFields]

-----------------------------------------------------------------------------
\* The mutator (Elm code and kernels). Every store writes a value it holds.
Load == \E r \in RootSlots, r2 \in RootSlots, i \in Fields :
          /\ root[r2] # Nil
          /\ root' = [root EXCEPT ![r] = fld[root[r2]][i]]
          /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, grey, cycle, deferred>>
          /\ UNCHANGED ghosts

Drop == \E r \in RootSlots :
          /\ root' = [root EXCEPT ![r] = Nil]
          /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, grey, cycle, deferred>>
          /\ UNCHANGED ghosts

CellW == \E c \in CellSlots, r \in RootSlots :
           /\ cell' = [cell EXCEPT ![c] = root[r]]
           /\ UNCHANGED <<alloc, gen, age, builder, fld, root, mark, grey, cycle, deferred>>
           /\ UNCHANGED ghosts

CellR == \E r \in RootSlots, c \in CellSlots :
           /\ root' = [root EXCEPT ![r] = cell[c]]
           /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, grey, cycle, deferred>>
           /\ UNCHANGED ghosts

\* A young object whose fields are values the mutator holds (never a builder);
\* a young LARGE object lives in an old-gen cell and is allocated black.
Alloc == \E o \in Obj \ alloc, r \in RootSlots :
         \E v \in [Fields -> ({root[x] : x \in RootSlots} \ {b \in Obj : builder[b]}) \cup {Nil}] :
            /\ alloc' = alloc \cup {o}
            /\ gen' = [gen EXCEPT ![o] = "young"]
            /\ age' = [age EXCEPT ![o] = 0]
            /\ builder' = [builder EXCEPT ![o] = FALSE]
            /\ fld' = [fld EXCEPT ![o] = v]
            /\ root' = [root EXCEPT ![r] = o]
            /\ mark' = [mark EXCEPT ![o] = (o \in YlosIds /\ CycleOn)]
            /\ tNH' = IF CycleOn THEN tNH \cup {o} ELSE tNH
            /\ UNCHANGED <<cell, grey, cycle, deferred, t0Old, t0Ylos, tSH, fld0>>

BAlloc == \E o \in (Obj \ alloc) \ YlosIds, r \in RootSlots :
            /\ alloc' = alloc \cup {o}
            /\ gen' = [gen EXCEPT ![o] = "young"]
            /\ age' = [age EXCEPT ![o] = 0]
            /\ builder' = [builder EXCEPT ![o] = TRUE]
            /\ fld' = [fld EXCEPT ![o] = NoFields]
            /\ root' = [root EXCEPT ![r] = o]
            /\ mark' = [mark EXCEPT ![o] = FALSE]
            /\ tNH' = IF CycleOn THEN tNH \cup {o} ELSE tNH
            /\ UNCHANGED <<cell, grey, cycle, deferred, t0Old, t0Ylos, tSH, fld0>>

BWrite == \E r \in RootSlots, r2 \in RootSlots, i \in Fields :
            /\ root[r] # Nil
            /\ builder[root[r]]
            /\ root[r2] = Nil \/ (root[r2] # Nil /\ ~builder[root[r2]])
            /\ fld' = [fld EXCEPT ![root[r]][i] = root[r2]]
            /\ UNCHANGED <<alloc, gen, age, builder, root, cell, mark, grey, cycle, deferred>>
            /\ UNCHANGED ghosts

BClear == \E r \in RootSlots :
            /\ root[r] # Nil
            /\ builder[root[r]]
            /\ builder' = [builder EXCEPT ![root[r]] = FALSE]
            /\ UNCHANGED <<alloc, gen, age, fld, root, cell, mark, grey, cycle, deferred>>
            /\ UNCHANGED ghosts

-----------------------------------------------------------------------------
\* The minor GC (legacy mode), as the values it leaves: dead young objects are
\* freed (a dead young LARGE object is deferred while a cycle runs), live
\* ones age, and live age-1 non-builders are promoted, black while a cycle runs.
\* @type: Bool => { alloc: Set(Int), deferred: Set(Int), gen: Int -> Str, age: Int -> Int, builder: Int -> Bool, fld: Int -> (Int -> Int), mark: Int -> Bool };
MinorVals(on) ==
    LET ly      == Live \cap YoungObjs
        dead    == YoungObjs \ Live
        promote == {o \in ly : age[o] = 1 /\ ~builder[o]}
        defer   == IF on THEN dead \cap YlosIds ELSE {}
        freed   == dead \ defer
    IN [alloc    |-> alloc \ freed,
        deferred |-> deferred \cup defer,
        gen      |-> [o \in Obj |-> IF o \in promote THEN "old" ELSE gen[o]],
        age      |-> [o \in Obj |-> IF o \in freed THEN 0
                                    ELSE IF o \in ly /\ ~builder[o] THEN 1 ELSE age[o]],
        builder  |-> [o \in Obj |-> builder[o] /\ o \notin freed],
        fld      |-> [o \in Obj |-> IF o \in freed THEN NoFields ELSE fld[o]],
        mark     |-> [o \in Obj |-> IF o \in freed THEN FALSE
                                    ELSE IF o \in promote /\ o \notin YlosIds /\ on THEN TRUE
                                    ELSE mark[o]]]

MinorIdle == /\ cycle = "idle"
             /\ LET m == MinorVals(FALSE)
                IN /\ alloc' = m.alloc /\ deferred' = m.deferred /\ gen' = m.gen
                   /\ age' = m.age /\ builder' = m.builder /\ fld' = m.fld /\ mark' = m.mark
             /\ UNCHANGED <<root, cell, grey, cycle>>
             /\ UNCHANGED ghosts

MinorCycle == /\ CycleOn
              /\ LET m == MinorVals(TRUE)
                 IN /\ alloc' = m.alloc /\ deferred' = m.deferred /\ gen' = m.gen
                    /\ age' = m.age /\ builder' = m.builder /\ fld' = m.fld /\ mark' = m.mark
              /\ UNCHANGED <<root, cell, grey, cycle>>
              /\ UNCHANGED ghosts

\* The minor whose trigger fires, and the t0 snapshot at its end (startMarkCycle):
\* clear every mark; grey the old targets of roots and stores, the old children of
\* every young object, and of every young large object, which is marked itself.
MinorT0 ==
    /\ cycle = "idle"
    /\ LET m       == MinorVals(FALSE)
           young1  == {o \in m.alloc : m.gen[o] = "young"} \ m.deferred
           old1    == {o \in m.alloc : m.gen[o] = "old"}
           rootOld == {v \in {root[r] : r \in RootSlots} \ {Nil} : m.gen[v] = "old"}
           cellOld == {v \in {cell[c] : c \in CellSlots} \ {Nil} : m.gen[v] = "old"}
           ylos    == young1 \cap YlosIds
           kidsY   == {c \in SuccIn(ylos, m.fld) : m.gen[c] = "old"}
           kidsW   == {c \in SuccIn(young1 \ YlosIds, m.fld) : m.gen[c] = "old"}
           greys   == rootOld \cup cellOld \cup kidsY \cup kidsW
       IN /\ alloc' = m.alloc /\ deferred' = m.deferred /\ gen' = m.gen
          /\ age' = m.age /\ builder' = m.builder /\ fld' = m.fld
          /\ mark' = [o \in Obj |-> o \in greys \cup ylos]
          /\ grey' = greys
          /\ cycle' = "marking"
          /\ t0Old' = old1
          /\ t0Ylos' = ylos
          /\ tSH' = ReachIn(Held, m.fld)
          /\ tNH' = {}
          /\ fld0' = m.fld
    /\ UNCHANGED <<root, cell>>

\* One grey entry scanned (any marker: background member, assist, closing).
Scan == \E o \in grey :
          /\ grey' = IF o \in alloc THEN (grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]}
                     ELSE grey \ {o}
          /\ mark' = IF o \in alloc THEN [x \in Obj |-> mark[x] \/ x \in OldKids({o})]
                     ELSE mark
          /\ UNCHANGED <<alloc, gen, age, builder, fld, root, cell, cycle, deferred>>
          /\ UNCHANGED ghosts

\* The closing join has drained the grey set: HandoffDue.
Closing == /\ cycle = "marking"
           /\ grey = {}
           /\ cycle' = "handoffDue"
           /\ UNCHANGED <<alloc, gen, age, builder, fld, root, cell, mark, grey, deferred>>
           /\ UNCHANGED ghosts

\* The handoff (at the minor after the closing, at a pressure finish, or at a
\* major's join): free every unmarked old-gen cell and every deferred free.
Handoff == /\ CycleOn
           /\ grey = {}
           /\ LET freed == {o \in CellObjs : ~mark[o]} \cup deferred
              IN /\ alloc' = alloc \ freed
                 /\ fld' = [o \in Obj |-> IF o \in freed THEN NoFields ELSE fld[o]]
                 /\ age' = [o \in Obj |-> IF o \in freed THEN 0 ELSE age[o]]
                 /\ builder' = [o \in Obj |-> builder[o] /\ o \notin freed]
           /\ mark' = [o \in Obj |-> FALSE]
           /\ deferred' = {}
           /\ cycle' = "idle"
           /\ t0Old' = {} /\ t0Ylos' = {} /\ tSH' = {} /\ tNH' = {}
           /\ UNCHANGED <<gen, root, cell, grey, fld0>>

\* A STW major outside a cycle (inside one it first joins: drain, then Handoff).
MajorIdle == /\ cycle = "idle"
             /\ LET freed == CellObjs \ Live
                IN /\ alloc' = alloc \ freed
                   /\ fld' = [o \in Obj |-> IF o \in freed THEN NoFields ELSE fld[o]]
                   /\ age' = [o \in Obj |-> IF o \in freed THEN 0 ELSE age[o]]
                   /\ builder' = [o \in Obj |-> builder[o] /\ o \notin freed]
             /\ UNCHANGED <<gen, root, cell, mark, grey, cycle, deferred>>
             /\ UNCHANGED ghosts

Next == \/ Load \/ Drop \/ CellW \/ CellR \/ Alloc \/ BAlloc \/ BWrite \/ BClear
        \/ MinorIdle \/ MinorT0 \/ MinorCycle \/ Scan \/ Closing \/ Handoff \/ MajorIdle

-----------------------------------------------------------------------------
\* Types, twice. TypeGen generates every candidate state for IndInit (Apalache
\* treats `x \in S` as a choice). TypeInv is the same predicate in the form that is
\* cheap to CHECK: membership in SUBSET Obj or in a function set makes Apalache
\* expand the whole set, so the checked form uses \subseteq and pointwise ranges.
\* (Function domains never change: every update is an EXCEPT or [o \in Obj |-> ..].)
TypeGen ==
    /\ alloc \in SUBSET Obj
    /\ gen \in [Obj -> {"young", "old"}]
    /\ age \in [Obj -> {0, 1}]
    /\ builder \in [Obj -> BOOLEAN]
    /\ fld \in [Obj -> [Fields -> Obj \cup {Nil}]]
    /\ root \in [RootSlots -> Obj \cup {Nil}]
    /\ cell \in [CellSlots -> Obj \cup {Nil}]
    /\ mark \in [Obj -> BOOLEAN]
    /\ grey \in SUBSET Obj
    /\ cycle \in {"idle", "marking", "handoffDue"}
    /\ deferred \in SUBSET Obj
    /\ t0Old \in SUBSET Obj
    /\ t0Ylos \in SUBSET Obj
    /\ tSH \in SUBSET Obj
    /\ tNH \in SUBSET Obj
    /\ fld0 \in [Obj -> [Fields -> Obj \cup {Nil}]]

TypeInv ==
    /\ alloc \subseteq Obj /\ grey \subseteq Obj /\ deferred \subseteq Obj
    /\ t0Old \subseteq Obj /\ t0Ylos \subseteq Obj /\ tSH \subseteq Obj /\ tNH \subseteq Obj
    /\ cycle \in {"idle", "marking", "handoffDue"}
    /\ \A o \in Obj : /\ gen[o] \in {"young", "old"}
                     /\ age[o] \in {0, 1}
                     /\ \A i \in Fields : fld[o][i] \in Obj \cup {Nil} /\ fld0[o][i] \in Obj \cup {Nil}
    /\ \A r \in RootSlots : root[r] \in Obj \cup {Nil}
    /\ \A c \in CellSlots : cell[c] \in Obj \cup {Nil}

\* The model's invariants (SnapshotMark.tla).
NoLostObject    == Live \subseteq alloc                                  \* MODEL_M1_1
SnapshotClosure == CycleOn => Live \subseteq (tSH \cup tNH)              \* the lemma
DeferredOK      == deferred \subseteq alloc /\ deferred \cap Live = {}  \* IM8

\* The strengthening that makes the conjunction inductive.
OldSH          == tSH \cap t0Old                  \* the t0 old graph the marker must cover
White          == OldSH \ Marked
IdleClean      == cycle = "idle" => (grey = {} /\ deferred = {} /\ \A o \in Obj : ~mark[o])
BuilderYoung   == \A o \in alloc : builder[o] => (gen[o] = "young" /\ age[o] = 0)
\* Deferred frees and the t0 YLOS record hold young LARGE objects only; a
\* deferred cell is never promoted (the minor promotes only non-deferred objects).
YlosShapes     == /\ deferred \subseteq YoungSet \cap YlosIds
                  /\ t0Ylos \subseteq YlosIds
\* Promotion keeps HEAP_005: a live young object's young children are no younger
\* and never builders (PM5). Only LIVE objects: a dead one can point at a freed
\* id that a later allocation reuses.
AgeOrder       == \A o \in YoungObjs \cap Live, i \in Fields :
                     fld[o][i] \in YoungSet => (~builder[fld[o][i]] /\ age[fld[o][i]] >= age[o])
OldClosed      == \A o \in OldObjs, i \in Fields : fld[o][i] \in OldObjs \cup {Nil}  \* HEAP_005, no dangling
FieldsFrozen   == CycleOn => \A o \in t0Old : fld[o] = fld0[o]            \* P1 on the old gen
T0OldStays     == CycleOn => /\ (t0Old \cup t0Ylos) \subseteq alloc      \* IM5
                             /\ t0Old \subseteq OldObjs
                             /\ tNH \cap t0Old = {}
OldSHClosed    == CycleOn => \A o \in OldSH, i \in Fields : fld[o][i] \in OldSH \cup {Nil}
GreyInSH       == CycleOn => grey \subseteq OldSH
GreysMarked    == grey \subseteq Marked
HandoffEmpty   == cycle = "handoffDue" => grey = {}
NewOldBlack    == CycleOn => (OldObjs \ t0Old) \subseteq Marked           \* allocate-black
YlosBlack      == CycleOn => (YoungObjs \cap YlosIds) \subseteq Marked     \* t0 snapshot + allocate-black
KidsCovered    == CycleOn => \A o \in (Marked \cup (YoungObjs \cap Live)) \cap (alloc \ deferred),
                                   i \in Fields :
                                 fld[o][i] \in Marked \cup OldSH \cup YoungSet \cup {Nil}
\* The classic tri-colour invariant: every WHITE old object of S_H is reachable
\* from some grey object through white objects, so the marker will still find it.
\* (Reachable from SOME grey object through White = reachable from the grey set through White.)
WhiteReachable == CycleOn => LET v == ReachVec(grey, White, fld) IN \A o \in White : v[o]

LemmaInv == /\ TypeInv
            /\ NoLostObject /\ SnapshotClosure /\ DeferredOK
            /\ IdleClean /\ BuilderYoung /\ YlosShapes /\ AgeOrder /\ OldClosed /\ FieldsFrozen
            /\ T0OldStays /\ OldSHClosed /\ GreyInSH /\ GreysMarked /\ HandoffEmpty
            /\ NewOldBlack /\ YlosBlack /\ KidsCovered /\ WhiteReachable

\* Any state satisfying the invariant (Apalache's --init for the inductive step).
IndInit == TypeGen /\ LemmaInv

\* The inductive step as an ACTION invariant: checked on the transition only, so
\* Apalache does not re-check LemmaInv on the IndInit state (true by construction,
\* and the expensive part of the query).
LemmaStep == LemmaInv'

\* ---- Negative control (rule A6; plan §4.7 item 3, "the necessity of P1") ----
\* NOT part of Next: a kernel overwrites a field of a survived (old) object,
\* breaking HEAP_SNAPSHOT_001. Its inductive step must FAIL, and must fail in the
\* tri-colour argument, not merely in FieldsFrozen (which states P1 itself). So it
\* is checked against LemmaCore, which is LemmaInv without FieldsFrozen.
P1Write == \E o \in OldObjs, i \in Fields :
             \E v \in {Nil} \cup {x \in Held : gen[x] = "old"} :
               /\ fld' = [fld EXCEPT ![o][i] = v]
               /\ UNCHANGED <<alloc, gen, age, builder, root, cell, mark, grey, cycle, deferred>>
               /\ UNCHANGED ghosts
LemmaCore == /\ TypeInv
             /\ NoLostObject /\ SnapshotClosure /\ DeferredOK
             /\ IdleClean /\ BuilderYoung /\ YlosShapes /\ AgeOrder /\ OldClosed
             /\ T0OldStays /\ OldSHClosed /\ GreyInSH /\ GreysMarked /\ HandoffEmpty
             /\ NewOldBlack /\ YlosBlack /\ KidsCovered /\ WhiteReachable
LemmaCoreStep == LemmaCore'

\* The consequence the handoff needs: with the grey set empty, every reachable
\* old-gen cell is marked, so the sweep frees only garbage (IM2).
LemmaImpliesIM2 == (CycleOn /\ grey = {}) => (Live \cap CellObjs) \subseteq Marked
=============================================================================
