---------------------------- MODULE SnapshotMark ----------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Obj,            \* object ids; an id not in alloc is a free cell
    Nil,            \* model value: a null / constant slot
    RootSlots,      \* stack slots and RootSet roots (read at t0 only)
    CellSlots,      \* off-heap mutable stores: CellStore, MVar (external roots)
    Fields,         \* pointer fields per object, e.g. {1}
    YlosIds,        \* ids that are young LARGE objects while young (old-gen cell)
    InitAlloc, InitGen, InitAge, InitFld, InitRoot, InitCell,
    T,              \* incremental_mark_slices
    MaxMinors,      \* minor GCs explored
    MaxMajors,      \* emergency / explicit STW majors explored
    MaxOps,         \* mutator operations between two minors
    MaxTotalOps,    \* mutator operations in the whole run (the state-space lever)
    Ops,            \* the mutator operation kinds explored (subset of OpKinds)
    AssistMax,      \* entries one assist may scan in the pause
    MaxStops,       \* fork-hook stops of the background episode
    SyncMark,       \* conc_mark = 1: the whole mark inside the t0 pause
    RegionMode,     \* nursery_regions = 1: dead hand-over objects live on until the next minor
    MUTANT

OpKinds == {"load", "drop", "cellw", "cellr", "alloc", "balloc", "bwrite", "bclear"}

\* Reachability through a field map f, stopping at the fixpoint. It is defined
\* before the algorithm (it reads no variable), because a RECURSIVE operator is
\* simplest there; TLC only (SnapshotLemma.tla uses a fold for Apalache).
RECURSIVE ReachIn(_, _)
ReachIn(S, f) == LET S2 == S \cup ({f[o][i] : o \in S, i \in Fields} \ {Nil})
                 IN IF S2 = S THEN S ELSE ReachIn(S2, f)

MutId == "mut"
MkId  == "mk"
FkId  == "fk"

(* --algorithm SnapshotMark
variables
    alloc    = InitAlloc,                 \* allocated objects
    gen      = InitGen,                   \* [Obj -> {"young", "old"}]
    age      = InitAge,                   \* [Obj -> 0..1]: minors survived (young)
    builder  = [o \in Obj |-> FALSE],     \* Header.builder
    fld      = InitFld,                   \* [Obj -> [Fields -> Obj \cup {Nil}]]
    root     = InitRoot,                  \* [RootSlots -> Obj \cup {Nil}]
    cell     = InitCell,                  \* [CellSlots -> Obj \cup {Nil}]
    mark     = [o \in Obj |-> FALSE],     \* mark bit of an old-gen cell (old object or YLOS)
    grey     = {},                        \* the grey set (all slots' stacks + deques)
    cycle    = "idle",                    \* "idle" | "marking" | "handoffDue"
    k        = 0,                         \* cycle_k_: minor ends since t0
    episode  = "none",                    \* bg_ep_ with the gang's running(): "none" | "running" | "finished"
    deferred = {},                        \* deferred_frees_ (dead young large objects)
    zombie   = {},                        \* region mode: dead objects of the extent handed over at the last minor
    minors   = 0,
    majors   = 0,
    ops      = 0,
    opsTotal = 0,
    \* ghosts, recorded in the t0 pause
    t0Old    = {},                        \* old objects that existed at t0
    t0Ylos   = {},                        \* young large objects (old-gen cells) at t0
    t0Reach  = {},                        \* IM1: old-gen cells reachable at t0
    tSH      = {},                        \* S_H: everything reachable at t0
    tNH      = {};                        \* N_H: allocated after t0

define
    Succ(S)  == {fld[o][i] : o \in S, i \in Fields} \ {Nil}
    Reach(S) == ReachIn(S, fld)
    Held     == ({root[r] : r \in RootSlots} \cup {cell[c] : c \in CellSlots}) \ {Nil}
    Live     == Reach(Held)
    OldObjs  == {o \in alloc : gen[o] = "old"}
    YoungObjs == {o \in alloc : gen[o] = "young"} \ (deferred \cup zombie)
    \* Old-gen cells: old objects and young large objects. The tail sweep frees
    \* every unmarked one (retireDeadLargeBodies retires an unmarked YLOS).
    CellObjs == OldObjs \cup {o \in alloc : gen[o] = "young" /\ o \in YlosIds}
    Marked   == {o \in Obj : mark[o]}
    Survived(o) == gen[o] = "old" \/ age[o] >= 1
    \* A slot value that is a builder. Nil-safe: TLC evaluates BOTH sides of a
    \* disjunction in an action, so `v = Nil \/ ~builder[v]` would apply builder to Nil.
    IsBuilder(v) == v # Nil /\ builder[v]
    \* State-space hygiene (primer 4.2): a freed id's fields, age, builder flag and
    \* mark are dead (nothing on a correct path reads them), so every free resets
    \* them. Its gen is kept: a freed old cell is still an old-gen address, and
    \* the region-mode t0 walk (CR-017) reads it through a dangling slot.
    NoFields     == [i \in Fields |-> Nil]
    NoMarks      == [o \in Obj |-> FALSE]
    ScrubFld(S)  == [o \in Obj |-> IF o \in S THEN NoFields ELSE fld[o]]
    ScrubAge(S)  == [o \in Obj |-> IF o \in S THEN 0 ELSE age[o]]
    ScrubBld(S)  == [o \in Obj |-> builder[o] /\ o \notin S]
    CycleOn  == cycle # "idle"
    OldKids(S) == {c \in Succ(S) : gen[c] = "old"}
    \* MUTANT lazy_external: a marker that runs out of work reads the off-heap
    \* stores then, instead of at t0.
    LazyGreys == IF MUTANT = "lazy_external"
                 THEN {v \in {cell[c] : c \in CellSlots} \ {Nil} : gen[v] = "old" /\ ~mark[v]}
                 ELSE {}

    \* MODEL_M1_1: no reachable object is ever freed.
    NoLostObject == Live \subseteq alloc
    \* IM3 (and the footprint argument of the one-step minor GC): markers only
    \* ever hold objects that were old at t0, and never reach a young object.
    MarkerFootprint == CycleOn => /\ grey \subseteq t0Old
                                  /\ \A o \in grey \cap alloc :
                                        \A i \in Fields : fld[o][i] = Nil \/ gen[fld[o][i]] = "old"
    \* IM5: nothing that existed at t0 is freed or reused during the cycle.
    NoReleaseInCycle == CycleOn => (t0Old \cup t0Ylos) \subseteq alloc
    \* HEAP_005: no old -> young pointer.
    NoOldToYoung == \A o \in OldObjs : \A i \in Fields :
                        fld[o][i] = Nil \/ fld[o][i] \notin alloc \/ gen[fld[o][i]] = "old"
    \* The snapshot-closure lemma (parallel-gc.md 2.1): every reference held
    \* anywhere points into S_H \cup N_H.
    SnapshotClosure == CycleOn => Live \subseteq (tSH \cup tNH)
    \* IM8 (model form): deferred frees are still allocated and really dead.
    DeferredOK == deferred \subseteq alloc /\ deferred \cap Live = {}
end define;

\* One grey entry scanned: its old children are test-and-set marked and greyed.
\* A freed object's entry is skipped (scanObject's Tag_Free check).
macro ScanOne(o) begin
    if o \in alloc then
        grey := (grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]};
        mark := [x \in Obj |-> mark[x] \/ x \in OldKids({o})];
    else
        grey := grey \ {o};
    end if;
end macro;

\* The closing join / pressure finish / join drain (closingFinish, drainCycleMark):
\* the pause scans until the grey set is empty, racing the background markers.
procedure DrainAll()
begin
  D_Loop:
    while grey # {} \/ LazyGreys # {} do
        if grey # {} then
            with o \in grey do ScanOne(o); end with;
        else                                   \* MUTANT lazy_external only
            grey := LazyGreys;
            mark := [x \in Obj |-> mark[x] \/ x \in grey];
        end if;
    end while;
  D_Done:
    episode := "none";                         \* closingFinish ends with bg_ep_ = None
    return;
end procedure;

\* A paced assist (assistEpisode) or a 5b slice: at most AssistMax scans in the pause.
\* It may stop early, grey entries left: an Assist leaves as soon as it finds no work
\* it can take (the rest is private to background members, or stolen first), and one
\* joined to a stopped control scans nothing (runMarkerLoop, MarkWork.hpp: "never
\* idles: leave"). Found by trace validation (AUDIT.md, 2026-09-28 trace entry).
procedure Assist()
variables n = 0;
begin
  A_Loop:
    while n < AssistMax /\ grey # {} do
        either
            with o \in grey do ScanOne(o); end with;
            n := n + 1;
        or
            goto A_Done;
        end either;
    end while;
  A_Done:
    return;
end procedure;

\* completeMarkCycle + handoffMarkCycle: the checks (IM1, IM2, IM9, IM14) are
\* invariants on the state at H_Free; then every unmarked old-gen cell is freed
\* together with the deferred frees.
procedure Handoff()
begin
  H_Free:
    with freed = {o \in CellObjs : ~mark[o]} \cup deferred do
        alloc := alloc \ freed;
        fld := ScrubFld(freed);
        age := ScrubAge(freed);
        builder := ScrubBld(freed);
    end with;
    mark := NoMarks;                         \* marks and greys are dead outside a cycle
    grey := {};
    deferred := {};
    cycle := "idle";
    episode := "none";
    k := 0;
    t0Old := {}; t0Ylos := {}; t0Reach := {}; tSH := {}; tNH := {};
    return;
end procedure;

\* One minor-GC pause (ThreadLocalHeap::minorGC + stepMarkCycle / trigger).
procedure MinorPause()
begin
  P_Minor:                                 \* the minor GC itself: ONE step (see M1 plan 4.1)
    with ly = Live \cap YoungObjs,
         dead = YoungObjs \ Live,
         hand = IF RegionMode THEN {o \in YoungObjs \ Live : age[o] = 1 /\ o \notin YlosIds}
                ELSE {},
         promote = {o \in Live \cap YoungObjs :
                        age[o] = 1 /\ (~builder[o] \/ MUTANT = "promote_ignores_builder")},
         \* region mode: the extent handed over now keeps its dead objects until the
         \* next minor retires it (the previous one's zombies are freed here);
         \* during a cycle a dead young large object is deferred (sweepNurseryLargeBodies)
         defer = IF CycleOn /\ MUTANT # "free_ylos_in_cycle"
                 THEN (dead \cap YlosIds)
                      \cup (IF MUTANT = "defer_live_ylos" THEN ly \cap YlosIds ELSE {})
                 ELSE {},
         freed = ((dead \ hand) \ defer) \cup zombie do
        alloc := alloc \ freed;
        deferred := deferred \cup defer;
        zombie := hand;
        gen := [o \in Obj |-> IF o \in promote THEN "old" ELSE gen[o]];
        age := [o \in Obj |-> IF o \in freed THEN 0
                              ELSE IF o \in ly /\ (~builder[o] \/ MUTANT = "promote_ignores_builder")
                              THEN 1 ELSE age[o]];
        builder := ScrubBld(freed);
        fld := ScrubFld(freed);
        \* allocate-black: a promotion during a cycle gets its mark bit at once
        \* (young large objects are promoted in place and were marked already)
        mark := [o \in Obj |-> IF o \in freed THEN FALSE
                               ELSE IF o \in promote /\ o \notin YlosIds /\ CycleOn
                                       /\ MUTANT # "no_alloc_black"
                               THEN TRUE ELSE mark[o]];
    end with;
    minors := minors + 1;
    ops := 0;
    if cycle = "handoffDue" then goto P_Handoff;
    elsif cycle = "marking" then goto P_Marking;
    else goto P_Trigger;
    end if;
  P_Handoff:                               \* stepMarkCycle: HandoffDue -> completeMarkCycle
    call Handoff();
    return;
  P_Marking:                               \* stepMarkCycle: k++, pressure check, then the step's reap / relaunch
    k := k + 1;
    either
        goto P_Pressure;                   \* cyclePressureFinishDue: before the step, at any k
    or
        if ~SyncMark then                  \* runCycleStepConcurrent: reapBackground, relaunch
            if episode = "none" /\ grey # {} then episode := "running";
            elsif episode = "none" then episode := "finished";
            end if;
        end if;
    end either;
  P_Decide:
    if k >= T /\ MUTANT # "closing_never" then
        goto P_Closing;
    else
        either
            return;                        \* on schedule: a plain minor pause
        or
            call Assist();                 \* behind schedule: a paced assist (or a 5b slice)
            return;
        end either;
    end if;
  P_Closing:                               \* k == T: closingFinish, then HandoffDue
    if MUTANT # "handoff_skips_drain" then
        call DrainAll();
    end if;
  P_Closing2:
    cycle := "handoffDue";
    return;
  P_Pressure:                              \* finishMarkCycleNow(Pressure)
    call DrainAll();
  P_Pressure2:
    call Handoff();
    return;
  P_Trigger:                               \* evaluateMajorGCTrigger
    either
        return;
    or
        goto P_T0;
    end either;
  P_T0:                                    \* startMarkCycle: the snapshot, ONE step
    with rootOld = {v \in {root[r] : r \in RootSlots} \ {Nil} : gen[v] = "old"},
         cellOld = IF MUTANT \in {"skip_external", "lazy_external"} THEN {}
                   ELSE {v \in {cell[c] : c \in CellSlots} \ {Nil} : gen[v] = "old"},
         ylos    = IF MUTANT = "skip_ylos" THEN {} ELSE YoungObjs \cap YlosIds,
         ylosOld = OldKids(IF MUTANT = "skip_ylos" THEN {} ELSE YoungObjs \cap YlosIds),
         youngOld = IF MUTANT = "skip_young_walk" THEN {}
                    ELSE OldKids((YoungObjs \cup zombie) \ YlosIds) do
        mark := [o \in Obj |-> o \in (rootOld \cup cellOld \cup ylos \cup ylosOld \cup youngOld)];
        grey := rootOld \cup cellOld \cup ylosOld \cup youngOld;
        t0Old := OldObjs;
        t0Ylos := ylos;
        t0Reach := Live \cap CellObjs;
        tSH := Live;
        tNH := {};
    end with;
    cycle := "marking";
    k := 0;
    if SyncMark then goto P_Sync;
    else
        episode := "running";              \* afterSnapshot -> launchBackground
        return;
    end if;
  P_Sync:                                  \* conc_mark = 1: everything now
    call DrainAll();
    return;
end procedure;

\* An emergency or explicit STW major (ThreadLocalHeap::majorGC): it JOINS a
\* running cycle (drain + handoff) and then runs its own full mark and sweep.
procedure MajorPause()
begin
  J_Join:
    if CycleOn /\ MUTANT # "major_no_join" then
        call DrainAll();
    end if;
  J_Handoff:
    if CycleOn /\ MUTANT # "major_no_join" then
        call Handoff();
    end if;
  J_STW:                                   \* frees every unreachable old-gen cell (YLOS too)
    with freed = CellObjs \ Live do
        alloc := alloc \ freed;
        fld := ScrubFld(freed);
        age := ScrubAge(freed);
        builder := ScrubBld(freed);
        \* its own marks are dead once it ends, unless a cycle is still running
        \* (only under major_no_join)
        mark := IF CycleOn THEN [o \in Obj |-> o \in (Live \cap CellObjs)] ELSE NoMarks;
    end with;
    majors := majors + 1;
    return;
end procedure;

\* The mutator: Elm code and C++ kernels, interleaved with pauses.
process Mutator = MutId
begin
  M_Loop:
    while minors < MaxMinors do
      M_Choose:
        either
            await ops < MaxOps /\ opsTotal < MaxTotalOps;
            ops := ops + 1;
            opsTotal := opsTotal + 1;
            either      \* load a field of a held object into a root
                await "load" \in Ops;
                with r \in RootSlots, r2 \in RootSlots, i \in Fields do
                    await root[r2] # Nil;
                    root[r] := fld[root[r2]][i];
                end with;
            or          \* drop a root
                await "drop" \in Ops;
                with r \in RootSlots do root[r] := Nil; end with;
            or          \* CellStore / MVar write (off-heap, may be overwritten any time)
                await "cellw" \in Ops;
                with c \in CellSlots, r \in RootSlots do cell[c] := root[r]; end with;
            or          \* CellStore / MVar read
                await "cellr" \in Ops;
                with r \in RootSlots, c \in CellSlots do root[r] := cell[c]; end with;
            or          \* allocate a young object whose fields are values the mutator holds
                await "alloc" \in Ops;
                with o \in Obj \ alloc, r \in RootSlots,
                     v \in [Fields -> ({root[x] : x \in RootSlots} \ {b \in Obj : builder[b]}) \cup {Nil}] do
                    alloc := alloc \cup {o};
                    gen := [gen EXCEPT ![o] = "young"];
                    age := [age EXCEPT ![o] = 0];
                    builder := [builder EXCEPT ![o] = FALSE];
                    fld := [fld EXCEPT ![o] = v];
                    root := [root EXCEPT ![r] = o];
                    \* a young LARGE object lives in an old-gen cell: allocate-black
                    mark := [mark EXCEPT ![o] = o \in YlosIds /\ CycleOn
                                                /\ MUTANT # "no_alloc_black"];
                    tNH := IF CycleOn THEN tNH \cup {o} ELSE tNH;
                end with;
            or          \* a kernel allocates a builder (fields filled later)
                await "balloc" \in Ops;
                with o \in (Obj \ alloc) \ YlosIds, r \in RootSlots do
                    alloc := alloc \cup {o};
                    gen := [gen EXCEPT ![o] = "young"];
                    age := [age EXCEPT ![o] = 0];
                    builder := [builder EXCEPT ![o] = TRUE];
                    fld := [fld EXCEPT ![o] = [i \in Fields |-> Nil]];
                    root := [root EXCEPT ![r] = o];
                    mark := [mark EXCEPT ![o] = FALSE];
                    tNH := IF CycleOn THEN tNH \cup {o} ELSE tNH;
                end with;
            or          \* a kernel writes a builder (HEAP_BUILDER_*: allowed)
                await "bwrite" \in Ops;
                with r \in RootSlots, r2 \in RootSlots, i \in Fields do
                    await IsBuilder(root[r]);
                    await ~IsBuilder(root[r2]);
                    fld := [fld EXCEPT ![root[r]][i] = root[r2]];
                end with;
            or          \* clear_builder: the object becomes an ordinary young object
                await "bclear" \in Ops;
                with r \in RootSlots do
                    await root[r] # Nil /\ builder[root[r]];
                    builder := [builder EXCEPT ![root[r]] = FALSE];
                end with;
            or          \* P1 VIOLATION: a kernel overwrites a field of a survived object
                await MUTANT = "p1_violation";
                with r \in RootSlots, i \in Fields,
                     v \in {Nil} \cup {x \in Held : gen[x] = "old"} do
                    await root[r] # Nil /\ Survived(root[r]) /\ ~builder[root[r]];
                    fld := [fld EXCEPT ![root[r]][i] = v];
                end with;
            or          \* a runtime free of a now-unreachable OLD object during a cycle
                await MUTANT = "release_during_cycle" /\ CycleOn;
                with o \in OldObjs \ Live do
                    alloc := alloc \ {o};
                    fld := ScrubFld({o});
                    mark := [mark EXCEPT ![o] = FALSE];
                end with;
            or          \* a ROOTING BUG: a C++ local the GC does not know about
                        \* resurfaces a pointer to an object that is not reachable
                await MUTANT = "hidden_root";
                with r \in RootSlots, o \in alloc \ Live do
                    root := [root EXCEPT ![r] = o];
                end with;
            end either;
        or
            call MinorPause();
        or
            await majors < MaxMajors;
            call MajorPause();
        end either;
    end while;
end process;

\* The background markers (GCBackgroundGang members running 5b's loop). Under
\* M2's Drain contract they behave as one consumer of the shared grey set.
fair process Marker = MkId
begin
  K_Loop:
    while TRUE do
        await episode = "running";
        if grey # {} then
            with o \in grey do ScanOne(o); end with;
        elsif LazyGreys # {} then                \* MUTANT lazy_external: the stores, read late
            grey := LazyGreys;
            mark := [x \in Obj |-> mark[x] \/ x \in grey];
        else
            episode := "finished";              \* termination (the done-CAS), then the reap
        end if;
    end while;
end process;

\* A fork hook on another thread: stopAllForFork() stops the running episode.
process Forker = FkId
variables stops = 0;
begin
  F_Loop:
    while stops < MaxStops do
        await episode = "running";
        episode := "none";                      \* stopped: the work stays in the grey set
        stops := stops + 1;
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, alloc, gen, age, builder, fld, root, cell, mark, grey, cycle, k, 
          episode, deferred, zombie, minors, majors, ops, opsTotal, t0Old, 
          t0Ylos, t0Reach, tSH, tNH, stack

(* define statement *)
Succ(S)  == {fld[o][i] : o \in S, i \in Fields} \ {Nil}
Reach(S) == ReachIn(S, fld)
Held     == ({root[r] : r \in RootSlots} \cup {cell[c] : c \in CellSlots}) \ {Nil}
Live     == Reach(Held)
OldObjs  == {o \in alloc : gen[o] = "old"}
YoungObjs == {o \in alloc : gen[o] = "young"} \ (deferred \cup zombie)


CellObjs == OldObjs \cup {o \in alloc : gen[o] = "young" /\ o \in YlosIds}
Marked   == {o \in Obj : mark[o]}
Survived(o) == gen[o] = "old" \/ age[o] >= 1


IsBuilder(v) == v # Nil /\ builder[v]




NoFields     == [i \in Fields |-> Nil]
NoMarks      == [o \in Obj |-> FALSE]
ScrubFld(S)  == [o \in Obj |-> IF o \in S THEN NoFields ELSE fld[o]]
ScrubAge(S)  == [o \in Obj |-> IF o \in S THEN 0 ELSE age[o]]
ScrubBld(S)  == [o \in Obj |-> builder[o] /\ o \notin S]
CycleOn  == cycle # "idle"
OldKids(S) == {c \in Succ(S) : gen[c] = "old"}


LazyGreys == IF MUTANT = "lazy_external"
             THEN {v \in {cell[c] : c \in CellSlots} \ {Nil} : gen[v] = "old" /\ ~mark[v]}
             ELSE {}


NoLostObject == Live \subseteq alloc


MarkerFootprint == CycleOn => /\ grey \subseteq t0Old
                              /\ \A o \in grey \cap alloc :
                                    \A i \in Fields : fld[o][i] = Nil \/ gen[fld[o][i]] = "old"

NoReleaseInCycle == CycleOn => (t0Old \cup t0Ylos) \subseteq alloc

NoOldToYoung == \A o \in OldObjs : \A i \in Fields :
                    fld[o][i] = Nil \/ fld[o][i] \notin alloc \/ gen[fld[o][i]] = "old"


SnapshotClosure == CycleOn => Live \subseteq (tSH \cup tNH)

DeferredOK == deferred \subseteq alloc /\ deferred \cap Live = {}

VARIABLES n, stops

vars == << pc, alloc, gen, age, builder, fld, root, cell, mark, grey, cycle, 
           k, episode, deferred, zombie, minors, majors, ops, opsTotal, t0Old, 
           t0Ylos, t0Reach, tSH, tNH, stack, n, stops >>

ProcSet == {MutId} \cup {MkId} \cup {FkId}

Init == (* Global variables *)
        /\ alloc = InitAlloc
        /\ gen = InitGen
        /\ age = InitAge
        /\ builder = [o \in Obj |-> FALSE]
        /\ fld = InitFld
        /\ root = InitRoot
        /\ cell = InitCell
        /\ mark = [o \in Obj |-> FALSE]
        /\ grey = {}
        /\ cycle = "idle"
        /\ k = 0
        /\ episode = "none"
        /\ deferred = {}
        /\ zombie = {}
        /\ minors = 0
        /\ majors = 0
        /\ ops = 0
        /\ opsTotal = 0
        /\ t0Old = {}
        /\ t0Ylos = {}
        /\ t0Reach = {}
        /\ tSH = {}
        /\ tNH = {}
        (* Procedure Assist *)
        /\ n = [ self \in ProcSet |-> 0]
        (* Process Forker *)
        /\ stops = 0
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self = MutId -> "M_Loop"
                                        [] self = MkId -> "K_Loop"
                                        [] self = FkId -> "F_Loop"]

D_Loop(self) == /\ pc[self] = "D_Loop"
                /\ IF grey # {} \/ LazyGreys # {}
                      THEN /\ IF grey # {}
                                 THEN /\ \E o \in grey:
                                           IF o \in alloc
                                              THEN /\ grey' = ((grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]})
                                                   /\ mark' = [x \in Obj |-> mark[x] \/ x \in OldKids({o})]
                                              ELSE /\ grey' = grey \ {o}
                                                   /\ mark' = mark
                                 ELSE /\ grey' = LazyGreys
                                      /\ mark' = [x \in Obj |-> mark[x] \/ x \in grey']
                           /\ pc' = [pc EXCEPT ![self] = "D_Loop"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "D_Done"]
                           /\ UNCHANGED << mark, grey >>
                /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                cycle, k, episode, deferred, zombie, minors, 
                                majors, ops, opsTotal, t0Old, t0Ylos, t0Reach, 
                                tSH, tNH, stack, n, stops >>

D_Done(self) == /\ pc[self] = "D_Done"
                /\ episode' = "none"
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                mark, grey, cycle, k, deferred, zombie, minors, 
                                majors, ops, opsTotal, t0Old, t0Ylos, t0Reach, 
                                tSH, tNH, n, stops >>

DrainAll(self) == D_Loop(self) \/ D_Done(self)

A_Loop(self) == /\ pc[self] = "A_Loop"
                /\ IF n[self] < AssistMax /\ grey # {}
                      THEN /\ \/ /\ \E o \in grey:
                                      IF o \in alloc
                                         THEN /\ grey' = ((grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]})
                                              /\ mark' = [x \in Obj |-> mark[x] \/ x \in OldKids({o})]
                                         ELSE /\ grey' = grey \ {o}
                                              /\ mark' = mark
                                 /\ n' = [n EXCEPT ![self] = n[self] + 1]
                                 /\ pc' = [pc EXCEPT ![self] = "A_Loop"]
                              \/ /\ pc' = [pc EXCEPT ![self] = "A_Done"]
                                 /\ UNCHANGED <<mark, grey, n>>
                      ELSE /\ pc' = [pc EXCEPT ![self] = "A_Done"]
                           /\ UNCHANGED << mark, grey, n >>
                /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                cycle, k, episode, deferred, zombie, minors, 
                                majors, ops, opsTotal, t0Old, t0Ylos, t0Reach, 
                                tSH, tNH, stack, stops >>

A_Done(self) == /\ pc[self] = "A_Done"
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ n' = [n EXCEPT ![self] = Head(stack[self]).n]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                mark, grey, cycle, k, episode, deferred, 
                                zombie, minors, majors, ops, opsTotal, t0Old, 
                                t0Ylos, t0Reach, tSH, tNH, stops >>

Assist(self) == A_Loop(self) \/ A_Done(self)

H_Free(self) == /\ pc[self] = "H_Free"
                /\ LET freed == {o \in CellObjs : ~mark[o]} \cup deferred IN
                     /\ alloc' = alloc \ freed
                     /\ fld' = ScrubFld(freed)
                     /\ age' = ScrubAge(freed)
                     /\ builder' = ScrubBld(freed)
                /\ mark' = NoMarks
                /\ grey' = {}
                /\ deferred' = {}
                /\ cycle' = "idle"
                /\ episode' = "none"
                /\ k' = 0
                /\ t0Old' = {}
                /\ t0Ylos' = {}
                /\ t0Reach' = {}
                /\ tSH' = {}
                /\ tNH' = {}
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << gen, root, cell, zombie, minors, majors, ops, 
                                opsTotal, n, stops >>

Handoff(self) == H_Free(self)

P_Minor(self) == /\ pc[self] = "P_Minor"
                 /\ LET ly == Live \cap YoungObjs IN
                      LET dead == YoungObjs \ Live IN
                        LET hand == IF RegionMode THEN {o \in YoungObjs \ Live : age[o] = 1 /\ o \notin YlosIds}
                                    ELSE {} IN
                          LET promote == {o \in Live \cap YoungObjs :
                                              age[o] = 1 /\ (~builder[o] \/ MUTANT = "promote_ignores_builder")} IN
                            LET defer == IF CycleOn /\ MUTANT # "free_ylos_in_cycle"
                                         THEN (dead \cap YlosIds)
                                              \cup (IF MUTANT = "defer_live_ylos" THEN ly \cap YlosIds ELSE {})
                                         ELSE {} IN
                              LET freed == ((dead \ hand) \ defer) \cup zombie IN
                                /\ alloc' = alloc \ freed
                                /\ deferred' = (deferred \cup defer)
                                /\ zombie' = hand
                                /\ gen' = [o \in Obj |-> IF o \in promote THEN "old" ELSE gen[o]]
                                /\ age' = [o \in Obj |-> IF o \in freed THEN 0
                                                         ELSE IF o \in ly /\ (~builder[o] \/ MUTANT = "promote_ignores_builder")
                                                         THEN 1 ELSE age[o]]
                                /\ builder' = ScrubBld(freed)
                                /\ fld' = ScrubFld(freed)
                                /\ mark' = [o \in Obj |-> IF o \in freed THEN FALSE
                                                          ELSE IF o \in promote /\ o \notin YlosIds /\ CycleOn
                                                                  /\ MUTANT # "no_alloc_black"
                                                          THEN TRUE ELSE mark[o]]
                 /\ minors' = minors + 1
                 /\ ops' = 0
                 /\ IF cycle = "handoffDue"
                       THEN /\ pc' = [pc EXCEPT ![self] = "P_Handoff"]
                       ELSE /\ IF cycle = "marking"
                                  THEN /\ pc' = [pc EXCEPT ![self] = "P_Marking"]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "P_Trigger"]
                 /\ UNCHANGED << root, cell, grey, cycle, k, episode, majors, 
                                 opsTotal, t0Old, t0Ylos, t0Reach, tSH, tNH, 
                                 stack, n, stops >>

P_Handoff(self) == /\ pc[self] = "P_Handoff"
                   /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Handoff",
                                                            pc        |->  Head(stack[self]).pc ] >>
                                                        \o Tail(stack[self])]
                   /\ pc' = [pc EXCEPT ![self] = "H_Free"]
                   /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                   mark, grey, cycle, k, episode, deferred, 
                                   zombie, minors, majors, ops, opsTotal, 
                                   t0Old, t0Ylos, t0Reach, tSH, tNH, n, stops >>

P_Marking(self) == /\ pc[self] = "P_Marking"
                   /\ k' = k + 1
                   /\ \/ /\ pc' = [pc EXCEPT ![self] = "P_Pressure"]
                         /\ UNCHANGED episode
                      \/ /\ IF ~SyncMark
                               THEN /\ IF episode = "none" /\ grey # {}
                                          THEN /\ episode' = "running"
                                          ELSE /\ IF episode = "none"
                                                     THEN /\ episode' = "finished"
                                                     ELSE /\ TRUE
                                                          /\ UNCHANGED episode
                               ELSE /\ TRUE
                                    /\ UNCHANGED episode
                         /\ pc' = [pc EXCEPT ![self] = "P_Decide"]
                   /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                   mark, grey, cycle, deferred, zombie, minors, 
                                   majors, ops, opsTotal, t0Old, t0Ylos, 
                                   t0Reach, tSH, tNH, stack, n, stops >>

P_Decide(self) == /\ pc[self] = "P_Decide"
                  /\ IF k >= T /\ MUTANT # "closing_never"
                        THEN /\ pc' = [pc EXCEPT ![self] = "P_Closing"]
                             /\ UNCHANGED << stack, n >>
                        ELSE /\ \/ /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                   /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                   /\ n' = n
                                \/ /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Assist",
                                                                            pc        |->  Head(stack[self]).pc,
                                                                            n         |->  n[self] ] >>
                                                                        \o Tail(stack[self])]
                                   /\ n' = [n EXCEPT ![self] = 0]
                                   /\ pc' = [pc EXCEPT ![self] = "A_Loop"]
                  /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                  mark, grey, cycle, k, episode, deferred, 
                                  zombie, minors, majors, ops, opsTotal, t0Old, 
                                  t0Ylos, t0Reach, tSH, tNH, stops >>

P_Closing(self) == /\ pc[self] = "P_Closing"
                   /\ IF MUTANT # "handoff_skips_drain"
                         THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "DrainAll",
                                                                       pc        |->  "P_Closing2" ] >>
                                                                   \o stack[self]]
                              /\ pc' = [pc EXCEPT ![self] = "D_Loop"]
                         ELSE /\ pc' = [pc EXCEPT ![self] = "P_Closing2"]
                              /\ stack' = stack
                   /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                   mark, grey, cycle, k, episode, deferred, 
                                   zombie, minors, majors, ops, opsTotal, 
                                   t0Old, t0Ylos, t0Reach, tSH, tNH, n, stops >>

P_Closing2(self) == /\ pc[self] = "P_Closing2"
                    /\ cycle' = "handoffDue"
                    /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                    /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                    /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                    mark, grey, k, episode, deferred, zombie, 
                                    minors, majors, ops, opsTotal, t0Old, 
                                    t0Ylos, t0Reach, tSH, tNH, n, stops >>

P_Pressure(self) == /\ pc[self] = "P_Pressure"
                    /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "DrainAll",
                                                             pc        |->  "P_Pressure2" ] >>
                                                         \o stack[self]]
                    /\ pc' = [pc EXCEPT ![self] = "D_Loop"]
                    /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                    mark, grey, cycle, k, episode, deferred, 
                                    zombie, minors, majors, ops, opsTotal, 
                                    t0Old, t0Ylos, t0Reach, tSH, tNH, n, stops >>

P_Pressure2(self) == /\ pc[self] = "P_Pressure2"
                     /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Handoff",
                                                              pc        |->  Head(stack[self]).pc ] >>
                                                          \o Tail(stack[self])]
                     /\ pc' = [pc EXCEPT ![self] = "H_Free"]
                     /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                     mark, grey, cycle, k, episode, deferred, 
                                     zombie, minors, majors, ops, opsTotal, 
                                     t0Old, t0Ylos, t0Reach, tSH, tNH, n, 
                                     stops >>

P_Trigger(self) == /\ pc[self] = "P_Trigger"
                   /\ \/ /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                         /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                      \/ /\ pc' = [pc EXCEPT ![self] = "P_T0"]
                         /\ stack' = stack
                   /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                   mark, grey, cycle, k, episode, deferred, 
                                   zombie, minors, majors, ops, opsTotal, 
                                   t0Old, t0Ylos, t0Reach, tSH, tNH, n, stops >>

P_T0(self) == /\ pc[self] = "P_T0"
              /\ LET rootOld == {v \in {root[r] : r \in RootSlots} \ {Nil} : gen[v] = "old"} IN
                   LET cellOld == IF MUTANT \in {"skip_external", "lazy_external"} THEN {}
                                  ELSE {v \in {cell[c] : c \in CellSlots} \ {Nil} : gen[v] = "old"} IN
                     LET ylos == IF MUTANT = "skip_ylos" THEN {} ELSE YoungObjs \cap YlosIds IN
                       LET ylosOld == OldKids(IF MUTANT = "skip_ylos" THEN {} ELSE YoungObjs \cap YlosIds) IN
                         LET youngOld == IF MUTANT = "skip_young_walk" THEN {}
                                         ELSE OldKids((YoungObjs \cup zombie) \ YlosIds) IN
                           /\ mark' = [o \in Obj |-> o \in (rootOld \cup cellOld \cup ylos \cup ylosOld \cup youngOld)]
                           /\ grey' = (rootOld \cup cellOld \cup ylosOld \cup youngOld)
                           /\ t0Old' = OldObjs
                           /\ t0Ylos' = ylos
                           /\ t0Reach' = (Live \cap CellObjs)
                           /\ tSH' = Live
                           /\ tNH' = {}
              /\ cycle' = "marking"
              /\ k' = 0
              /\ IF SyncMark
                    THEN /\ pc' = [pc EXCEPT ![self] = "P_Sync"]
                         /\ UNCHANGED << episode, stack >>
                    ELSE /\ episode' = "running"
                         /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                         /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
              /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                              deferred, zombie, minors, majors, ops, opsTotal, 
                              n, stops >>

P_Sync(self) == /\ pc[self] = "P_Sync"
                /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "DrainAll",
                                                         pc        |->  Head(stack[self]).pc ] >>
                                                     \o Tail(stack[self])]
                /\ pc' = [pc EXCEPT ![self] = "D_Loop"]
                /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                mark, grey, cycle, k, episode, deferred, 
                                zombie, minors, majors, ops, opsTotal, t0Old, 
                                t0Ylos, t0Reach, tSH, tNH, n, stops >>

MinorPause(self) == P_Minor(self) \/ P_Handoff(self) \/ P_Marking(self)
                       \/ P_Decide(self) \/ P_Closing(self)
                       \/ P_Closing2(self) \/ P_Pressure(self)
                       \/ P_Pressure2(self) \/ P_Trigger(self)
                       \/ P_T0(self) \/ P_Sync(self)

J_Join(self) == /\ pc[self] = "J_Join"
                /\ IF CycleOn /\ MUTANT # "major_no_join"
                      THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "DrainAll",
                                                                    pc        |->  "J_Handoff" ] >>
                                                                \o stack[self]]
                           /\ pc' = [pc EXCEPT ![self] = "D_Loop"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "J_Handoff"]
                           /\ stack' = stack
                /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                mark, grey, cycle, k, episode, deferred, 
                                zombie, minors, majors, ops, opsTotal, t0Old, 
                                t0Ylos, t0Reach, tSH, tNH, n, stops >>

J_Handoff(self) == /\ pc[self] = "J_Handoff"
                   /\ IF CycleOn /\ MUTANT # "major_no_join"
                         THEN /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Handoff",
                                                                       pc        |->  "J_STW" ] >>
                                                                   \o stack[self]]
                              /\ pc' = [pc EXCEPT ![self] = "H_Free"]
                         ELSE /\ pc' = [pc EXCEPT ![self] = "J_STW"]
                              /\ stack' = stack
                   /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, 
                                   mark, grey, cycle, k, episode, deferred, 
                                   zombie, minors, majors, ops, opsTotal, 
                                   t0Old, t0Ylos, t0Reach, tSH, tNH, n, stops >>

J_STW(self) == /\ pc[self] = "J_STW"
               /\ LET freed == CellObjs \ Live IN
                    /\ alloc' = alloc \ freed
                    /\ fld' = ScrubFld(freed)
                    /\ age' = ScrubAge(freed)
                    /\ builder' = ScrubBld(freed)
                    /\ mark' = IF CycleOn THEN [o \in Obj |-> o \in (Live \cap CellObjs)] ELSE NoMarks
               /\ majors' = majors + 1
               /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
               /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
               /\ UNCHANGED << gen, root, cell, grey, cycle, k, episode, 
                               deferred, zombie, minors, ops, opsTotal, t0Old, 
                               t0Ylos, t0Reach, tSH, tNH, n, stops >>

MajorPause(self) == J_Join(self) \/ J_Handoff(self) \/ J_STW(self)

M_Loop == /\ pc[MutId] = "M_Loop"
          /\ IF minors < MaxMinors
                THEN /\ pc' = [pc EXCEPT ![MutId] = "M_Choose"]
                ELSE /\ pc' = [pc EXCEPT ![MutId] = "Done"]
          /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, mark, 
                          grey, cycle, k, episode, deferred, zombie, minors, 
                          majors, ops, opsTotal, t0Old, t0Ylos, t0Reach, tSH, 
                          tNH, stack, n, stops >>

M_Choose == /\ pc[MutId] = "M_Choose"
            /\ \/ /\ ops < MaxOps /\ opsTotal < MaxTotalOps
                  /\ ops' = ops + 1
                  /\ opsTotal' = opsTotal + 1
                  /\ \/ /\ "load" \in Ops
                        /\ \E r \in RootSlots:
                             \E r2 \in RootSlots:
                               \E i \in Fields:
                                 /\ root[r2] # Nil
                                 /\ root' = [root EXCEPT ![r] = fld[root[r2]][i]]
                        /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, tNH>>
                     \/ /\ "drop" \in Ops
                        /\ \E r \in RootSlots:
                             root' = [root EXCEPT ![r] = Nil]
                        /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, tNH>>
                     \/ /\ "cellw" \in Ops
                        /\ \E c \in CellSlots:
                             \E r \in RootSlots:
                               cell' = [cell EXCEPT ![c] = root[r]]
                        /\ UNCHANGED <<alloc, gen, age, builder, fld, root, mark, tNH>>
                     \/ /\ "cellr" \in Ops
                        /\ \E r \in RootSlots:
                             \E c \in CellSlots:
                               root' = [root EXCEPT ![r] = cell[c]]
                        /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, tNH>>
                     \/ /\ "alloc" \in Ops
                        /\ \E o \in Obj \ alloc:
                             \E r \in RootSlots:
                               \E v \in [Fields -> ({root[x] : x \in RootSlots} \ {b \in Obj : builder[b]}) \cup {Nil}]:
                                 /\ alloc' = (alloc \cup {o})
                                 /\ gen' = [gen EXCEPT ![o] = "young"]
                                 /\ age' = [age EXCEPT ![o] = 0]
                                 /\ builder' = [builder EXCEPT ![o] = FALSE]
                                 /\ fld' = [fld EXCEPT ![o] = v]
                                 /\ root' = [root EXCEPT ![r] = o]
                                 /\ mark' = [mark EXCEPT ![o] = o \in YlosIds /\ CycleOn
                                                                /\ MUTANT # "no_alloc_black"]
                                 /\ tNH' = (IF CycleOn THEN tNH \cup {o} ELSE tNH)
                        /\ cell' = cell
                     \/ /\ "balloc" \in Ops
                        /\ \E o \in (Obj \ alloc) \ YlosIds:
                             \E r \in RootSlots:
                               /\ alloc' = (alloc \cup {o})
                               /\ gen' = [gen EXCEPT ![o] = "young"]
                               /\ age' = [age EXCEPT ![o] = 0]
                               /\ builder' = [builder EXCEPT ![o] = TRUE]
                               /\ fld' = [fld EXCEPT ![o] = [i \in Fields |-> Nil]]
                               /\ root' = [root EXCEPT ![r] = o]
                               /\ mark' = [mark EXCEPT ![o] = FALSE]
                               /\ tNH' = (IF CycleOn THEN tNH \cup {o} ELSE tNH)
                        /\ cell' = cell
                     \/ /\ "bwrite" \in Ops
                        /\ \E r \in RootSlots:
                             \E r2 \in RootSlots:
                               \E i \in Fields:
                                 /\ IsBuilder(root[r])
                                 /\ ~IsBuilder(root[r2])
                                 /\ fld' = [fld EXCEPT ![root[r]][i] = root[r2]]
                        /\ UNCHANGED <<alloc, gen, age, builder, root, cell, mark, tNH>>
                     \/ /\ "bclear" \in Ops
                        /\ \E r \in RootSlots:
                             /\ root[r] # Nil /\ builder[root[r]]
                             /\ builder' = [builder EXCEPT ![root[r]] = FALSE]
                        /\ UNCHANGED <<alloc, gen, age, fld, root, cell, mark, tNH>>
                     \/ /\ MUTANT = "p1_violation"
                        /\ \E r \in RootSlots:
                             \E i \in Fields:
                               \E v \in {Nil} \cup {x \in Held : gen[x] = "old"}:
                                 /\ root[r] # Nil /\ Survived(root[r]) /\ ~builder[root[r]]
                                 /\ fld' = [fld EXCEPT ![root[r]][i] = v]
                        /\ UNCHANGED <<alloc, gen, age, builder, root, cell, mark, tNH>>
                     \/ /\ MUTANT = "release_during_cycle" /\ CycleOn
                        /\ \E o \in OldObjs \ Live:
                             /\ alloc' = alloc \ {o}
                             /\ fld' = ScrubFld({o})
                             /\ mark' = [mark EXCEPT ![o] = FALSE]
                        /\ UNCHANGED <<gen, age, builder, root, cell, tNH>>
                     \/ /\ MUTANT = "hidden_root"
                        /\ \E r \in RootSlots:
                             \E o \in alloc \ Live:
                               root' = [root EXCEPT ![r] = o]
                        /\ UNCHANGED <<alloc, gen, age, builder, fld, cell, mark, tNH>>
                  /\ pc' = [pc EXCEPT ![MutId] = "M_Loop"]
                  /\ stack' = stack
               \/ /\ stack' = [stack EXCEPT ![MutId] = << [ procedure |->  "MinorPause",
                                                            pc        |->  "M_Loop" ] >>
                                                        \o stack[MutId]]
                  /\ pc' = [pc EXCEPT ![MutId] = "P_Minor"]
                  /\ UNCHANGED <<alloc, gen, age, builder, fld, root, cell, mark, ops, opsTotal, tNH>>
               \/ /\ majors < MaxMajors
                  /\ stack' = [stack EXCEPT ![MutId] = << [ procedure |->  "MajorPause",
                                                            pc        |->  "M_Loop" ] >>
                                                        \o stack[MutId]]
                  /\ pc' = [pc EXCEPT ![MutId] = "J_Join"]
                  /\ UNCHANGED <<alloc, gen, age, builder, fld, root, cell, mark, ops, opsTotal, tNH>>
            /\ UNCHANGED << grey, cycle, k, episode, deferred, zombie, minors, 
                            majors, t0Old, t0Ylos, t0Reach, tSH, n, stops >>

Mutator == M_Loop \/ M_Choose

K_Loop == /\ pc[MkId] = "K_Loop"
          /\ episode = "running"
          /\ IF grey # {}
                THEN /\ \E o \in grey:
                          IF o \in alloc
                             THEN /\ grey' = ((grey \ {o}) \cup {c \in OldKids({o}) : ~mark[c]})
                                  /\ mark' = [x \in Obj |-> mark[x] \/ x \in OldKids({o})]
                             ELSE /\ grey' = grey \ {o}
                                  /\ mark' = mark
                     /\ UNCHANGED episode
                ELSE /\ IF LazyGreys # {}
                           THEN /\ grey' = LazyGreys
                                /\ mark' = [x \in Obj |-> mark[x] \/ x \in grey']
                                /\ UNCHANGED episode
                           ELSE /\ episode' = "finished"
                                /\ UNCHANGED << mark, grey >>
          /\ pc' = [pc EXCEPT ![MkId] = "K_Loop"]
          /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, cycle, k, 
                          deferred, zombie, minors, majors, ops, opsTotal, 
                          t0Old, t0Ylos, t0Reach, tSH, tNH, stack, n, stops >>

Marker == K_Loop

F_Loop == /\ pc[FkId] = "F_Loop"
          /\ IF stops < MaxStops
                THEN /\ episode = "running"
                     /\ episode' = "none"
                     /\ stops' = stops + 1
                     /\ pc' = [pc EXCEPT ![FkId] = "F_Loop"]
                ELSE /\ pc' = [pc EXCEPT ![FkId] = "Done"]
                     /\ UNCHANGED << episode, stops >>
          /\ UNCHANGED << alloc, gen, age, builder, fld, root, cell, mark, 
                          grey, cycle, k, deferred, zombie, minors, majors, 
                          ops, opsTotal, t0Old, t0Ylos, t0Reach, tSH, tNH, 
                          stack, n >>

Forker == F_Loop

Next == Mutator \/ Marker \/ Forker
           \/ (\E self \in ProcSet:  \/ DrainAll(self) \/ Assist(self)
                                     \/ Handoff(self) \/ MinorPause(self)
                                     \/ MajorPause(self))

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(Marker)

\* END TRANSLATION
-----------------------------------------------------------------------------
\* Handoff-time checks (the state in which H_Free is about to run).
AtHandoff == pc[MutId] = "H_Free"
\* IM1: every old-gen cell reachable at t0 is marked.
IM1 == AtHandoff => t0Reach \subseteq Marked
\* IM2: every old-gen cell reachable now is marked.
IM2 == AtHandoff => (Live \cap CellObjs) \subseteq Marked
\* IM9 / IM14: the mark stack is empty and no background episode runs.
IM9 == AtHandoff => (grey = {} /\ episode # "running")

\* Optional liveness (deep tier): with a fair mutator, a cycle that has room to
\* reach its handoff within MaxMinors ends. The guard matters: without it the
\* property fails whenever t0 falls within T minors of MaxMinors, because the
\* bounded mutator stops first. The mutator's steps include its procedures'.
MutatorAll == \/ Mutator
              \/ MinorPause(MutId) \/ MajorPause(MutId) \/ DrainAll(MutId)
              \/ Assist(MutId) \/ Handoff(MutId)
LiveSpec  == Spec /\ WF_vars(MutatorAll)
CycleEnds == (CycleOn /\ minors + T + 1 <= MaxMinors) ~> ~CycleOn
=============================================================================
