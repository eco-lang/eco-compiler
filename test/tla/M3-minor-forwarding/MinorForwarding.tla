--------------------------- MODULE MinorForwarding ---------------------------
(***************************************************************************)
(* M3: the parallel minor's claim -> BUSY -> publish protocol on from-space *)
(* header words (runtime/src/allocator/MinorWork.hpp, NurseryParallel.cpp,  *)
(* NurseryRegion.cpp). Plan: plans/threaded-gc-tla-M3-minor-forwarding.md. *)
(* MAPPING.md maps every label to its code.                                 *)
(*                                                                          *)
(* Work distribution is M2's Drain contract: a shared bag of grey entries   *)
(* with atomic take, and termination when the bag is empty and nobody is    *)
(* scanning. Two modes: "legacy" (phase 6, may promote) and "region" (7b,  *)
(* never promotes; Hand slots recorded, Retire slots resolved).            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Workers,          \* worker ids; W0 is the paused mutator (worker 0)
    W0,
    FromIds,          \* from-space (eden) objects, ids in 1..99: claimed and copied
    ConsIds,          \* the subset of FromIds that are Cons cells <<head, tail>>
    YlosIds,          \* young large objects: reached under ylos_mu_, scanned in place
    OldIds,           \* old-gen objects: leaves for this model (HEAP_005)
    HandIds,          \* region mode: objects of the Hand extent (recorded, not copied)
    RetireIds,        \* region mode: objects of the Retire extent (resolved via shadow)
    RetireFwd,        \* [RetireIds -> OldIds]: the tenured copy the shadow names
    InitFields,       \* [FromIds \cup YlosIds -> Seq(Values)]
    InitRoots,        \* Seq(Values): root slots (stack maps, RootSet, scanners)
    Age,              \* [FromIds \cup YlosIds -> Nat]: header age
    Builders,         \* never promoted (HEAP_BUILDER_001)
    PromoAge,         \* promotion_age
    Mode,             \* "legacy" (phase 6) or "region" (7b: never promotes)
    MaxRun,           \* MINOR_SPINE_RUN (512 in code)
    MUTANT,
    Unfwd,            \* model value: an unforwarded header word (the object's own header)
    Busy              \* model value: mw::kBusy (Tag_Forward, colour 0, address 0)

\* Nil stands for every slot value the filters drop before any header load:
\* null, an embedded constant (ptr_ind = 1: [], True, Unit, ...).
Nil == 0
\* Canonical copy ids: the k-th copy of o is 100 * k + o. At most one copy per
\* worker per object, even under the double-copy mutants, so ids never run out,
\* and the order in which workers allocate does not multiply the states.
MaxCopies == Cardinality(Workers)
CopySlots(o) == {100 * k + o : k \in 1..MaxCopies}
CopyIds == UNION {CopySlots(o) : o \in FromIds}
ObjIds == FromIds \cup YlosIds \cup CopyIds
IsFrom(v) == v \in FromIds
Promotes(v) == Mode = "legacy" /\ Age[v] >= PromoAge /\ v \notin Builders

(* --algorithm MinorForwarding
variables
    hdr     = [o \in FromIds |-> Unfwd],      \* header word: Unfwd | Busy | a copy id (FWD)
    fld     = [o \in ObjIds |-> IF o \in FromIds \cup YlosIds THEN InitFields[o] ELSE <<>>],
    roots   = InitRoots,                      \* root slots (worker 0 only, before the gang)
    origin  = [d \in CopyIds |-> Nil],        \* ghost: the original of each copy
    whole   = [d \in CopyIds |-> FALSE],      \* ghost: body and header copied
    promo   = [d \in CopyIds |-> FALSE],      \* the copy went to the old gen
    grey    = {},                             \* the grey set (M2's Drain contract)
    owner   = [o \in CopyIds \cup YlosIds |-> Nil],   \* ghost: who may write this object's slots
    busy    = [w \in Workers |-> FALSE],
    started = FALSE,                          \* the gang start (GCMarkGang::run)
    yReached = [y \in YlosIds |-> FALSE],     \* m->color == minor_color_ (and hand_ylos_reached)
    yPromoted = [y \in YlosIds |-> FALSE],    \* promoteYoungLarge
    yPushes = [y \in YlosIds |-> 0],          \* ghost: pushes of each YLOS this minor
    recorded = {},                            \* region: slots recorded into H / S
    res     = [w \in Workers |-> Nil];        \* procedure result (PlusCal has no return value)

define
    SlotVal(o, i) == IF o = Nil THEN roots[i] ELSE fld[o][i]
    Copies == {d \in CopyIds : origin[d] # Nil}
    \* PM1 / HEAP_067: a from-space object is copied at most once.
    CopyOnce == \A o \in FromIds : Cardinality({d \in Copies : origin[d] = o}) <= 1
    \* A published forward names a complete copy (the design rule behind the
    \* release store in mw::publish; no in-drain reader depends on it today).
    FwdComplete == \A o \in FromIds : hdr[o] \in CopyIds => whole[hdr[o]]
    \* HEAP_067: the copy holds every field of the original (sized from the SAVED header).
    SizeFaithful == \A d \in Copies : whole[d] => Len(fld[d]) = Len(fld[origin[d]])
    \* HEAP_062: each young large object is reached (and pushed) at most once per minor.
    YlosOnce == \A y \in YlosIds : yPushes[y] <= 1
    \* spineRunP's needs_heads: a copied cell whose head is a heap pointer
    \* (tupleFieldKind == 0 and ptr_ind == 0). Nil stands for a constant.
    HeadIsPtr(c) == fld[c][1] # Nil
end define;

\* Write a slot of object o (Nil = a root slot).
macro WriteSlot(o, i, val) begin
    if o = Nil then roots[i] := val; else fld[o][i] := val; end if;
end macro;

\* reachYoungLargeP / reachYoungLargeR: one ylos_mu_ critical section (colour
\* test-and-set, then age++ or promoteYoungLarge), then the push after unlocking.
procedure ReachYlos(yy)
begin
  Y_Lock:
    if MUTANT = "ylos_unlocked" then
        if yReached[yy] then return; end if;  \* the colour test outside the mutex ...
      Y_Set:
        yReached[yy] := TRUE;                 \* ... and the set in a later step
        yPromoted[yy] := Promotes(yy);
    elsif yReached[yy] then
        return;                              \* already reached this minor
    else
        yReached[yy] := TRUE;                 \* test-and-set under ylos_mu_
        yPromoted[yy] := Promotes(yy);        \* same critical section
    end if;
  Y_Push:                                    \* pushGreyP after unlocking
    grey := grey \cup {yy};
    owner[yy] := Nil;
    yPushes[yy] := yPushes[yy] + 1;
    return;
end procedure;

\* copyClaimed / copyClaimedR: the caller holds the claim (hdr[cv] = Busy).
\* Sets res[self].
procedure Copy(cv)
variables cd = Nil, csz = 0;
begin
  C_Alloc:                                   \* allocatePromotion / labAllocate
    cd := CHOOSE c \in CopySlots(cv) : origin[c] = Nil;
    origin[cd] := cv;
    promo[cd] := Promotes(cv);
    csz := IF MUTANT = "size_from_busy" /\ hdr[cv] = Busy THEN 0 ELSE Len(fld[cv]);
    if MUTANT = "publish_early" then hdr[cv] := cd; end if;
  C_Body:                                    \* memcpy of the body (from-space is immutable)
    fld[cd] := SubSeq(fld[cv], 1, csz);
  C_Hdr:                                     \* memcpy of the fixed-up header word
    whole[cd] := TRUE;
  C_Pub:                                     \* mw::publish: release store of FWD(cd)
    if MUTANT = "never_publish" then
        skip;                                \* a claimant that returns without publishing
    elsif MUTANT # "publish_early" then
        hdr[cv] := cd;
    end if;
    res[self] := cd;
    return;
end procedure;

\* evacuateP / evacuateR (slot = (eo, ei), eo = Nil for a root slot).
\* Invariant OwnerWrites (below) checks that only eo's owner gets here.
procedure Evacuate(eo, ei)
variables ev = Nil, ehw = Unfwd;
begin
  E_Read:
    ev := SlotVal(eo, ei);
  E_Kind:                                         \* (a separate step: `return` resets ev)
    if ev \in YlosIds then
        call ReachYlos(ev);                       \* mayBeYoungLarge -> reachYoungLarge*
        return;
    elsif Mode = "region" /\ ev \in HandIds then
        recorded := recorded \cup {<<eo, ei>>};   \* Role::Hand: rw.H / rw.S, no header load
        return;
    elsif Mode = "region" /\ ev \in RetireIds then
        WriteSlot(eo, ei, RetireFwd[ev]);          \* Role::Retire: resolveRetire via the shadow
        return;
    elsif ~IsFrom(ev) then
        return;                                   \* old, permanent, constant, Nil, a copy (Fill)
    end if;
  E_Load:
    ehw := hdr[ev];                                 \* mw::loadHeader (acquire)
  E_Loop:
    while TRUE do
        if ehw = Busy then
            if MUTANT = "no_wait" then
                WriteSlot(eo, ei, Nil);           \* fwdAddr(BUSY) = address 0
                return;
            end if;
          E_Wait:                                 \* waitPublishedP
            await hdr[ev] # Busy;
            ehw := hdr[ev];
        elsif ehw \in CopyIds then                 \* forwarded: take the copy
            WriteSlot(eo, ei, ehw);
            return;
        else
          E_Claim:                                \* mw::claim: CAS header -> BUSY
            if MUTANT = "copy_without_cas" \/ hdr[ev] = ehw then
                hdr[ev] := Busy;
                goto E_Copy;
            else
                ehw := hdr[ev];                     \* claim race: retry with the observed word
            end if;
        end if;
    end while;
  E_Copy:
    call Copy(ev);
  E_Slot:                                         \* slot = dst; push if it has children
    WriteSlot(eo, ei, res[self]);
    if fld[res[self]] # <<>> then
        grey := grey \cup {res[self]};
        owner[res[self]] := Nil;
    end if;
    res[self] := Nil;
    return;
end procedure;

\* spineRunP / spineRunR (w, prev): copy the tail spine cell by cell (no
\* pushes), then one heads pass over the COUNTED run (never "while still in
\* to-space"), and only if some copied cell has a pointer head (needs_heads).
procedure SpineRun(sp0)
variables sprev = Nil, st = Nil, shw = Unfwd, sk = 0, srun = <<>>, strunc = FALSE,
          sneeds = FALSE, sm = 0, sj = 0, swalk = Nil;
begin
  S_Init:
    sprev := sp0;
  S_Loop:
    while TRUE do
        st := fld[sprev][2];                        \* prev->tail (our own slot)
        if st = Nil then
            goto S_Heads;                          \* null / constant tail: the run ends
        elsif ~IsFrom(st) then
            call Evacuate(sprev, 2);               \* not from-space (not Eden): plain evacuate
            goto S_Heads;
        end if;
      S_Load:
        shw := hdr[st];                             \* mw::loadHeader
        if shw = Busy then
          S_Wait:
            await hdr[st] # Busy;
            fld[sprev][2] := hdr[st];               \* another worker's copy: end the run
            goto S_Heads;
        elsif shw \in CopyIds then
            fld[sprev][2] := shw;
            goto S_Heads;
        elsif st \notin ConsIds then
            call Evacuate(sprev, 2);               \* not a Cons: plain evacuate
            goto S_Heads;
        elsif sk = MaxRun then                     \* bounded run: push the last copy
            grey := grey \cup {sprev};
            owner[sprev] := Nil;
            strunc := TRUE;
            goto S_Heads;
        end if;
      S_Claim:                                    \* mw::claim on the tail cell
        if hdr[st] = shw then
            hdr[st] := Busy;
        else
            goto S_Loop;                          \* claim race: re-read the tail
        end if;
      S_Copy:
        call Copy(st);
      S_Link:
        fld[sprev][2] := res[self];                \* prev->tail = copy
        owner[res[self]] := self;                 \* an unpushed run cell: ours
        srun := Append(srun, res[self]);
        sneeds := sneeds \/ HeadIsPtr(res[self]);
        sprev := res[self];
        sk := sk + 1;
        res[self] := Nil;
    end while;
  S_Heads:
    if ~sneeds \/ sk = 0 then
        goto S_Done;                              \* `if (needs_heads && k > 0)`
    elsif MUTANT = "heads_walk" then
        \* rule 1 broken: follow tails while the cell is a copy (rule 2 kept:
        \* stop at a truncated run's pushed cell)
        swalk := srun[1];
      S_Walk:
        while swalk \in CopyIds /\ ~(strunc /\ swalk = sprev) do
            call Evacuate(swalk, 1);
          S_WalkNext:
            swalk := IF Len(fld[swalk]) >= 2 THEN fld[swalk][2] ELSE Nil;
        end while;
    else
        \* rule 2: a pushed last cell does its own head (mutant heads_all breaks it)
        sm := IF strunc /\ MUTANT # "heads_all" THEN sk - 1 ELSE sk;
        sj := 1;
      S_HeadLoop:
        while sj <= sm do
            call Evacuate(srun[sj], 1);
          S_HeadNext:
            sj := sj + 1;
        end while;
    end if;
  S_Done:
    return;
end procedure;

\* scanEntryP / scanEntryR: every boxed slot of the entry, in order; a Cons
\* entry's tail goes to the spine run (use_hybrid_dfs, on by default).
procedure Scan(se)
variables si = 1;
begin
  SC_Loop:
    while si <= Len(fld[se]) do
        if se \in CopyIds /\ origin[se] \in ConsIds /\ si = 2 then
            call SpineRun(se);
        else
            call Evacuate(se, si);
        end if;
      SC_Next:
        si := si + 1;
    end while;
  SC_Done:
    return;
end procedure;

fair process Worker \in Workers
variables wr = 1, we = Nil;
begin
  W_Roots:                                        \* (3) roots: serial on worker 0
    if self = W0 then
      W_RootLoop:
        while wr <= Len(roots) do
            call Evacuate(Nil, wr);
          W_RootNext:
            wr := wr + 1;
        end while;
      W_Start:                                    \* (4)-(5) distribute, start the gang
        started := TRUE;
        wr := 1;
    else
        await started;
    end if;
  W_Loop:                                         \* (5) the drain (M2's Drain contract)
    while TRUE do
        either
            with x \in grey do
                grey := grey \ {x};
                owner[x] := self;
                busy[self] := TRUE;
                we := x;
            end with;
          W_Scan:
            call Scan(we);
          W_Idle:
            busy[self] := FALSE;
            we := Nil;
        or
            await grey = {} /\ \A w \in Workers : ~busy[w];
            goto W_Exit;
        end either;
    end while;
  W_Exit:
    skip;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
CONSTANT defaultInitValue
VARIABLES pc, hdr, fld, roots, origin, whole, promo, grey, owner, busy, 
          started, yReached, yPromoted, yPushes, recorded, res, stack

(* define statement *)
SlotVal(o, i) == IF o = Nil THEN roots[i] ELSE fld[o][i]
Copies == {d \in CopyIds : origin[d] # Nil}

CopyOnce == \A o \in FromIds : Cardinality({d \in Copies : origin[d] = o}) <= 1


FwdComplete == \A o \in FromIds : hdr[o] \in CopyIds => whole[hdr[o]]

SizeFaithful == \A d \in Copies : whole[d] => Len(fld[d]) = Len(fld[origin[d]])

YlosOnce == \A y \in YlosIds : yPushes[y] <= 1


HeadIsPtr(c) == fld[c][1] # Nil

VARIABLES yy, cv, cd, csz, eo, ei, ev, ehw, sp0, sprev, st, shw, sk, srun, 
          strunc, sneeds, sm, sj, swalk, se, si, wr, we

vars == << pc, hdr, fld, roots, origin, whole, promo, grey, owner, busy, 
           started, yReached, yPromoted, yPushes, recorded, res, stack, yy, 
           cv, cd, csz, eo, ei, ev, ehw, sp0, sprev, st, shw, sk, srun, 
           strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

ProcSet == (Workers)

Init == (* Global variables *)
        /\ hdr = [o \in FromIds |-> Unfwd]
        /\ fld = [o \in ObjIds |-> IF o \in FromIds \cup YlosIds THEN InitFields[o] ELSE <<>>]
        /\ roots = InitRoots
        /\ origin = [d \in CopyIds |-> Nil]
        /\ whole = [d \in CopyIds |-> FALSE]
        /\ promo = [d \in CopyIds |-> FALSE]
        /\ grey = {}
        /\ owner = [o \in CopyIds \cup YlosIds |-> Nil]
        /\ busy = [w \in Workers |-> FALSE]
        /\ started = FALSE
        /\ yReached = [y \in YlosIds |-> FALSE]
        /\ yPromoted = [y \in YlosIds |-> FALSE]
        /\ yPushes = [y \in YlosIds |-> 0]
        /\ recorded = {}
        /\ res = [w \in Workers |-> Nil]
        (* Procedure ReachYlos *)
        /\ yy = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure Copy *)
        /\ cv = [ self \in ProcSet |-> defaultInitValue]
        /\ cd = [ self \in ProcSet |-> Nil]
        /\ csz = [ self \in ProcSet |-> 0]
        (* Procedure Evacuate *)
        /\ eo = [ self \in ProcSet |-> defaultInitValue]
        /\ ei = [ self \in ProcSet |-> defaultInitValue]
        /\ ev = [ self \in ProcSet |-> Nil]
        /\ ehw = [ self \in ProcSet |-> Unfwd]
        (* Procedure SpineRun *)
        /\ sp0 = [ self \in ProcSet |-> defaultInitValue]
        /\ sprev = [ self \in ProcSet |-> Nil]
        /\ st = [ self \in ProcSet |-> Nil]
        /\ shw = [ self \in ProcSet |-> Unfwd]
        /\ sk = [ self \in ProcSet |-> 0]
        /\ srun = [ self \in ProcSet |-> <<>>]
        /\ strunc = [ self \in ProcSet |-> FALSE]
        /\ sneeds = [ self \in ProcSet |-> FALSE]
        /\ sm = [ self \in ProcSet |-> 0]
        /\ sj = [ self \in ProcSet |-> 0]
        /\ swalk = [ self \in ProcSet |-> Nil]
        (* Procedure Scan *)
        /\ se = [ self \in ProcSet |-> defaultInitValue]
        /\ si = [ self \in ProcSet |-> 1]
        (* Process Worker *)
        /\ wr = [self \in Workers |-> 1]
        /\ we = [self \in Workers |-> Nil]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> "W_Roots"]

Y_Lock(self) == /\ pc[self] = "Y_Lock"
                /\ IF MUTANT = "ylos_unlocked"
                      THEN /\ IF yReached[yy[self]]
                                 THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ yy' = [yy EXCEPT ![self] = Head(stack[self]).yy]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "Y_Set"]
                                      /\ UNCHANGED << stack, yy >>
                           /\ UNCHANGED << yReached, yPromoted >>
                      ELSE /\ IF yReached[yy[self]]
                                 THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ yy' = [yy EXCEPT ![self] = Head(stack[self]).yy]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                      /\ UNCHANGED << yReached, yPromoted >>
                                 ELSE /\ yReached' = [yReached EXCEPT ![yy[self]] = TRUE]
                                      /\ yPromoted' = [yPromoted EXCEPT ![yy[self]] = Promotes(yy[self])]
                                      /\ pc' = [pc EXCEPT ![self] = "Y_Push"]
                                      /\ UNCHANGED << stack, yy >>
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yPushes, recorded, res, 
                                cv, cd, csz, eo, ei, ev, ehw, sp0, sprev, st, 
                                shw, sk, srun, strunc, sneeds, sm, sj, swalk, 
                                se, si, wr, we >>

Y_Set(self) == /\ pc[self] = "Y_Set"
               /\ yReached' = [yReached EXCEPT ![yy[self]] = TRUE]
               /\ yPromoted' = [yPromoted EXCEPT ![yy[self]] = Promotes(yy[self])]
               /\ pc' = [pc EXCEPT ![self] = "Y_Push"]
               /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                               owner, busy, started, yPushes, recorded, res, 
                               stack, yy, cv, cd, csz, eo, ei, ev, ehw, sp0, 
                               sprev, st, shw, sk, srun, strunc, sneeds, sm, 
                               sj, swalk, se, si, wr, we >>

Y_Push(self) == /\ pc[self] = "Y_Push"
                /\ grey' = (grey \cup {yy[self]})
                /\ owner' = [owner EXCEPT ![yy[self]] = Nil]
                /\ yPushes' = [yPushes EXCEPT ![yy[self]] = yPushes[yy[self]] + 1]
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ yy' = [yy EXCEPT ![self] = Head(stack[self]).yy]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, busy, 
                                started, yReached, yPromoted, recorded, res, 
                                cv, cd, csz, eo, ei, ev, ehw, sp0, sprev, st, 
                                shw, sk, srun, strunc, sneeds, sm, sj, swalk, 
                                se, si, wr, we >>

ReachYlos(self) == Y_Lock(self) \/ Y_Set(self) \/ Y_Push(self)

C_Alloc(self) == /\ pc[self] = "C_Alloc"
                 /\ cd' = [cd EXCEPT ![self] = CHOOSE c \in CopySlots(cv[self]) : origin[c] = Nil]
                 /\ origin' = [origin EXCEPT ![cd'[self]] = cv[self]]
                 /\ promo' = [promo EXCEPT ![cd'[self]] = Promotes(cv[self])]
                 /\ csz' = [csz EXCEPT ![self] = IF MUTANT = "size_from_busy" /\ hdr[cv[self]] = Busy THEN 0 ELSE Len(fld[cv[self]])]
                 /\ IF MUTANT = "publish_early"
                       THEN /\ hdr' = [hdr EXCEPT ![cv[self]] = cd'[self]]
                       ELSE /\ TRUE
                            /\ hdr' = hdr
                 /\ pc' = [pc EXCEPT ![self] = "C_Body"]
                 /\ UNCHANGED << fld, roots, whole, grey, owner, busy, started, 
                                 yReached, yPromoted, yPushes, recorded, res, 
                                 stack, yy, cv, eo, ei, ev, ehw, sp0, sprev, 
                                 st, shw, sk, srun, strunc, sneeds, sm, sj, 
                                 swalk, se, si, wr, we >>

C_Body(self) == /\ pc[self] = "C_Body"
                /\ fld' = [fld EXCEPT ![cd[self]] = SubSeq(fld[cv[self]], 1, csz[self])]
                /\ pc' = [pc EXCEPT ![self] = "C_Hdr"]
                /\ UNCHANGED << hdr, roots, origin, whole, promo, grey, owner, 
                                busy, started, yReached, yPromoted, yPushes, 
                                recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                                ev, ehw, sp0, sprev, st, shw, sk, srun, strunc, 
                                sneeds, sm, sj, swalk, se, si, wr, we >>

C_Hdr(self) == /\ pc[self] = "C_Hdr"
               /\ whole' = [whole EXCEPT ![cd[self]] = TRUE]
               /\ pc' = [pc EXCEPT ![self] = "C_Pub"]
               /\ UNCHANGED << hdr, fld, roots, origin, promo, grey, owner, 
                               busy, started, yReached, yPromoted, yPushes, 
                               recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                               ev, ehw, sp0, sprev, st, shw, sk, srun, strunc, 
                               sneeds, sm, sj, swalk, se, si, wr, we >>

C_Pub(self) == /\ pc[self] = "C_Pub"
               /\ IF MUTANT = "never_publish"
                     THEN /\ TRUE
                          /\ hdr' = hdr
                     ELSE /\ IF MUTANT # "publish_early"
                                THEN /\ hdr' = [hdr EXCEPT ![cv[self]] = cd[self]]
                                ELSE /\ TRUE
                                     /\ hdr' = hdr
               /\ res' = [res EXCEPT ![self] = cd[self]]
               /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
               /\ cd' = [cd EXCEPT ![self] = Head(stack[self]).cd]
               /\ csz' = [csz EXCEPT ![self] = Head(stack[self]).csz]
               /\ cv' = [cv EXCEPT ![self] = Head(stack[self]).cv]
               /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
               /\ UNCHANGED << fld, roots, origin, whole, promo, grey, owner, 
                               busy, started, yReached, yPromoted, yPushes, 
                               recorded, yy, eo, ei, ev, ehw, sp0, sprev, st, 
                               shw, sk, srun, strunc, sneeds, sm, sj, swalk, 
                               se, si, wr, we >>

Copy(self) == C_Alloc(self) \/ C_Body(self) \/ C_Hdr(self) \/ C_Pub(self)

E_Read(self) == /\ pc[self] = "E_Read"
                /\ ev' = [ev EXCEPT ![self] = SlotVal(eo[self], ei[self])]
                /\ pc' = [pc EXCEPT ![self] = "E_Kind"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, stack, yy, cv, cd, csz, 
                                eo, ei, ehw, sp0, sprev, st, shw, sk, srun, 
                                strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

E_Kind(self) == /\ pc[self] = "E_Kind"
                /\ IF ev[self] \in YlosIds
                      THEN /\ /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                              /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                              /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "ReachYlos",
                                                                       pc        |->  Head(stack[self]).pc,
                                                                       yy        |->  yy[self] ] >>
                                                                   \o Tail(stack[self])]
                              /\ yy' = [yy EXCEPT ![self] = ev[self]]
                           /\ pc' = [pc EXCEPT ![self] = "Y_Lock"]
                           /\ UNCHANGED << fld, roots, recorded, eo, ei >>
                      ELSE /\ IF Mode = "region" /\ ev[self] \in HandIds
                                 THEN /\ recorded' = (recorded \cup {<<eo[self], ei[self]>>})
                                      /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                                      /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                                      /\ eo' = [eo EXCEPT ![self] = Head(stack[self]).eo]
                                      /\ ei' = [ei EXCEPT ![self] = Head(stack[self]).ei]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                      /\ UNCHANGED << fld, roots >>
                                 ELSE /\ IF Mode = "region" /\ ev[self] \in RetireIds
                                            THEN /\ IF eo[self] = Nil
                                                       THEN /\ roots' = [roots EXCEPT ![ei[self]] = RetireFwd[ev[self]]]
                                                            /\ fld' = fld
                                                       ELSE /\ fld' = [fld EXCEPT ![eo[self]][ei[self]] = RetireFwd[ev[self]]]
                                                            /\ roots' = roots
                                                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                                 /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                                                 /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                                                 /\ eo' = [eo EXCEPT ![self] = Head(stack[self]).eo]
                                                 /\ ei' = [ei EXCEPT ![self] = Head(stack[self]).ei]
                                                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                            ELSE /\ IF ~IsFrom(ev[self])
                                                       THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                                            /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                                                            /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                                                            /\ eo' = [eo EXCEPT ![self] = Head(stack[self]).eo]
                                                            /\ ei' = [ei EXCEPT ![self] = Head(stack[self]).ei]
                                                            /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                                       ELSE /\ pc' = [pc EXCEPT ![self] = "E_Load"]
                                                            /\ UNCHANGED << stack, 
                                                                            eo, 
                                                                            ei, 
                                                                            ev, 
                                                                            ehw >>
                                                 /\ UNCHANGED << fld, roots >>
                                      /\ UNCHANGED recorded
                           /\ yy' = yy
                /\ UNCHANGED << hdr, origin, whole, promo, grey, owner, busy, 
                                started, yReached, yPromoted, yPushes, res, cv, 
                                cd, csz, sp0, sprev, st, shw, sk, srun, strunc, 
                                sneeds, sm, sj, swalk, se, si, wr, we >>

E_Load(self) == /\ pc[self] = "E_Load"
                /\ ehw' = [ehw EXCEPT ![self] = hdr[ev[self]]]
                /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, stack, yy, cv, cd, csz, 
                                eo, ei, ev, sp0, sprev, st, shw, sk, srun, 
                                strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

E_Loop(self) == /\ pc[self] = "E_Loop"
                /\ IF ehw[self] = Busy
                      THEN /\ IF MUTANT = "no_wait"
                                 THEN /\ IF eo[self] = Nil
                                            THEN /\ roots' = [roots EXCEPT ![ei[self]] = Nil]
                                                 /\ fld' = fld
                                            ELSE /\ fld' = [fld EXCEPT ![eo[self]][ei[self]] = Nil]
                                                 /\ roots' = roots
                                      /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                                      /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                                      /\ eo' = [eo EXCEPT ![self] = Head(stack[self]).eo]
                                      /\ ei' = [ei EXCEPT ![self] = Head(stack[self]).ei]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "E_Wait"]
                                      /\ UNCHANGED << fld, roots, stack, eo, 
                                                      ei, ev, ehw >>
                      ELSE /\ IF ehw[self] \in CopyIds
                                 THEN /\ IF eo[self] = Nil
                                            THEN /\ roots' = [roots EXCEPT ![ei[self]] = ehw[self]]
                                                 /\ fld' = fld
                                            ELSE /\ fld' = [fld EXCEPT ![eo[self]][ei[self]] = ehw[self]]
                                                 /\ roots' = roots
                                      /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                      /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                                      /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                                      /\ eo' = [eo EXCEPT ![self] = Head(stack[self]).eo]
                                      /\ ei' = [ei EXCEPT ![self] = Head(stack[self]).ei]
                                      /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "E_Claim"]
                                      /\ UNCHANGED << fld, roots, stack, eo, 
                                                      ei, ev, ehw >>
                /\ UNCHANGED << hdr, origin, whole, promo, grey, owner, busy, 
                                started, yReached, yPromoted, yPushes, 
                                recorded, res, yy, cv, cd, csz, sp0, sprev, st, 
                                shw, sk, srun, strunc, sneeds, sm, sj, swalk, 
                                se, si, wr, we >>

E_Wait(self) == /\ pc[self] = "E_Wait"
                /\ hdr[ev[self]] # Busy
                /\ ehw' = [ehw EXCEPT ![self] = hdr[ev[self]]]
                /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, stack, yy, cv, cd, csz, 
                                eo, ei, ev, sp0, sprev, st, shw, sk, srun, 
                                strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

E_Claim(self) == /\ pc[self] = "E_Claim"
                 /\ IF MUTANT = "copy_without_cas" \/ hdr[ev[self]] = ehw[self]
                       THEN /\ hdr' = [hdr EXCEPT ![ev[self]] = Busy]
                            /\ pc' = [pc EXCEPT ![self] = "E_Copy"]
                            /\ ehw' = ehw
                       ELSE /\ ehw' = [ehw EXCEPT ![self] = hdr[ev[self]]]
                            /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
                            /\ hdr' = hdr
                 /\ UNCHANGED << fld, roots, origin, whole, promo, grey, owner, 
                                 busy, started, yReached, yPromoted, yPushes, 
                                 recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                                 ev, sp0, sprev, st, shw, sk, srun, strunc, 
                                 sneeds, sm, sj, swalk, se, si, wr, we >>

E_Copy(self) == /\ pc[self] = "E_Copy"
                /\ /\ cv' = [cv EXCEPT ![self] = ev[self]]
                   /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Copy",
                                                            pc        |->  "E_Slot",
                                                            cd        |->  cd[self],
                                                            csz       |->  csz[self],
                                                            cv        |->  cv[self] ] >>
                                                        \o stack[self]]
                /\ cd' = [cd EXCEPT ![self] = Nil]
                /\ csz' = [csz EXCEPT ![self] = 0]
                /\ pc' = [pc EXCEPT ![self] = "C_Alloc"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, yy, eo, ei, ev, ehw, 
                                sp0, sprev, st, shw, sk, srun, strunc, sneeds, 
                                sm, sj, swalk, se, si, wr, we >>

E_Slot(self) == /\ pc[self] = "E_Slot"
                /\ IF eo[self] = Nil
                      THEN /\ roots' = [roots EXCEPT ![ei[self]] = res[self]]
                           /\ fld' = fld
                      ELSE /\ fld' = [fld EXCEPT ![eo[self]][ei[self]] = res[self]]
                           /\ roots' = roots
                /\ IF fld'[res[self]] # <<>>
                      THEN /\ grey' = (grey \cup {res[self]})
                           /\ owner' = [owner EXCEPT ![res[self]] = Nil]
                      ELSE /\ TRUE
                           /\ UNCHANGED << grey, owner >>
                /\ res' = [res EXCEPT ![self] = Nil]
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ ev' = [ev EXCEPT ![self] = Head(stack[self]).ev]
                /\ ehw' = [ehw EXCEPT ![self] = Head(stack[self]).ehw]
                /\ eo' = [eo EXCEPT ![self] = Head(stack[self]).eo]
                /\ ei' = [ei EXCEPT ![self] = Head(stack[self]).ei]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << hdr, origin, whole, promo, busy, started, 
                                yReached, yPromoted, yPushes, recorded, yy, cv, 
                                cd, csz, sp0, sprev, st, shw, sk, srun, strunc, 
                                sneeds, sm, sj, swalk, se, si, wr, we >>

Evacuate(self) == E_Read(self) \/ E_Kind(self) \/ E_Load(self)
                     \/ E_Loop(self) \/ E_Wait(self) \/ E_Claim(self)
                     \/ E_Copy(self) \/ E_Slot(self)

S_Init(self) == /\ pc[self] = "S_Init"
                /\ sprev' = [sprev EXCEPT ![self] = sp0[self]]
                /\ pc' = [pc EXCEPT ![self] = "S_Loop"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, stack, yy, cv, cd, csz, 
                                eo, ei, ev, ehw, sp0, st, shw, sk, srun, 
                                strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

S_Loop(self) == /\ pc[self] = "S_Loop"
                /\ st' = [st EXCEPT ![self] = fld[sprev[self]][2]]
                /\ IF st'[self] = Nil
                      THEN /\ pc' = [pc EXCEPT ![self] = "S_Heads"]
                           /\ UNCHANGED << stack, eo, ei, ev, ehw >>
                      ELSE /\ IF ~IsFrom(st'[self])
                                 THEN /\ /\ ei' = [ei EXCEPT ![self] = 2]
                                         /\ eo' = [eo EXCEPT ![self] = sprev[self]]
                                         /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Evacuate",
                                                                                  pc        |->  "S_Heads",
                                                                                  ev        |->  ev[self],
                                                                                  ehw       |->  ehw[self],
                                                                                  eo        |->  eo[self],
                                                                                  ei        |->  ei[self] ] >>
                                                                              \o stack[self]]
                                      /\ ev' = [ev EXCEPT ![self] = Nil]
                                      /\ ehw' = [ehw EXCEPT ![self] = Unfwd]
                                      /\ pc' = [pc EXCEPT ![self] = "E_Read"]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "S_Load"]
                                      /\ UNCHANGED << stack, eo, ei, ev, ehw >>
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, yy, cv, cd, csz, sp0, 
                                sprev, shw, sk, srun, strunc, sneeds, sm, sj, 
                                swalk, se, si, wr, we >>

S_Load(self) == /\ pc[self] = "S_Load"
                /\ shw' = [shw EXCEPT ![self] = hdr[st[self]]]
                /\ IF shw'[self] = Busy
                      THEN /\ pc' = [pc EXCEPT ![self] = "S_Wait"]
                           /\ UNCHANGED << fld, grey, owner, stack, eo, ei, ev, 
                                           ehw, strunc >>
                      ELSE /\ IF shw'[self] \in CopyIds
                                 THEN /\ fld' = [fld EXCEPT ![sprev[self]][2] = shw'[self]]
                                      /\ pc' = [pc EXCEPT ![self] = "S_Heads"]
                                      /\ UNCHANGED << grey, owner, stack, eo, 
                                                      ei, ev, ehw, strunc >>
                                 ELSE /\ IF st[self] \notin ConsIds
                                            THEN /\ /\ ei' = [ei EXCEPT ![self] = 2]
                                                    /\ eo' = [eo EXCEPT ![self] = sprev[self]]
                                                    /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Evacuate",
                                                                                             pc        |->  "S_Heads",
                                                                                             ev        |->  ev[self],
                                                                                             ehw       |->  ehw[self],
                                                                                             eo        |->  eo[self],
                                                                                             ei        |->  ei[self] ] >>
                                                                                         \o stack[self]]
                                                 /\ ev' = [ev EXCEPT ![self] = Nil]
                                                 /\ ehw' = [ehw EXCEPT ![self] = Unfwd]
                                                 /\ pc' = [pc EXCEPT ![self] = "E_Read"]
                                                 /\ UNCHANGED << grey, owner, 
                                                                 strunc >>
                                            ELSE /\ IF sk[self] = MaxRun
                                                       THEN /\ grey' = (grey \cup {sprev[self]})
                                                            /\ owner' = [owner EXCEPT ![sprev[self]] = Nil]
                                                            /\ strunc' = [strunc EXCEPT ![self] = TRUE]
                                                            /\ pc' = [pc EXCEPT ![self] = "S_Heads"]
                                                       ELSE /\ pc' = [pc EXCEPT ![self] = "S_Claim"]
                                                            /\ UNCHANGED << grey, 
                                                                            owner, 
                                                                            strunc >>
                                                 /\ UNCHANGED << stack, eo, ei, 
                                                                 ev, ehw >>
                                      /\ fld' = fld
                /\ UNCHANGED << hdr, roots, origin, whole, promo, busy, 
                                started, yReached, yPromoted, yPushes, 
                                recorded, res, yy, cv, cd, csz, sp0, sprev, st, 
                                sk, srun, sneeds, sm, sj, swalk, se, si, wr, 
                                we >>

S_Wait(self) == /\ pc[self] = "S_Wait"
                /\ hdr[st[self]] # Busy
                /\ fld' = [fld EXCEPT ![sprev[self]][2] = hdr[st[self]]]
                /\ pc' = [pc EXCEPT ![self] = "S_Heads"]
                /\ UNCHANGED << hdr, roots, origin, whole, promo, grey, owner, 
                                busy, started, yReached, yPromoted, yPushes, 
                                recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                                ev, ehw, sp0, sprev, st, shw, sk, srun, strunc, 
                                sneeds, sm, sj, swalk, se, si, wr, we >>

S_Claim(self) == /\ pc[self] = "S_Claim"
                 /\ IF hdr[st[self]] = shw[self]
                       THEN /\ hdr' = [hdr EXCEPT ![st[self]] = Busy]
                            /\ pc' = [pc EXCEPT ![self] = "S_Copy"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "S_Loop"]
                            /\ hdr' = hdr
                 /\ UNCHANGED << fld, roots, origin, whole, promo, grey, owner, 
                                 busy, started, yReached, yPromoted, yPushes, 
                                 recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                                 ev, ehw, sp0, sprev, st, shw, sk, srun, 
                                 strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

S_Copy(self) == /\ pc[self] = "S_Copy"
                /\ /\ cv' = [cv EXCEPT ![self] = st[self]]
                   /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Copy",
                                                            pc        |->  "S_Link",
                                                            cd        |->  cd[self],
                                                            csz       |->  csz[self],
                                                            cv        |->  cv[self] ] >>
                                                        \o stack[self]]
                /\ cd' = [cd EXCEPT ![self] = Nil]
                /\ csz' = [csz EXCEPT ![self] = 0]
                /\ pc' = [pc EXCEPT ![self] = "C_Alloc"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, yy, eo, ei, ev, ehw, 
                                sp0, sprev, st, shw, sk, srun, strunc, sneeds, 
                                sm, sj, swalk, se, si, wr, we >>

S_Link(self) == /\ pc[self] = "S_Link"
                /\ fld' = [fld EXCEPT ![sprev[self]][2] = res[self]]
                /\ owner' = [owner EXCEPT ![res[self]] = self]
                /\ srun' = [srun EXCEPT ![self] = Append(srun[self], res[self])]
                /\ sneeds' = [sneeds EXCEPT ![self] = sneeds[self] \/ HeadIsPtr(res[self])]
                /\ sprev' = [sprev EXCEPT ![self] = res[self]]
                /\ sk' = [sk EXCEPT ![self] = sk[self] + 1]
                /\ res' = [res EXCEPT ![self] = Nil]
                /\ pc' = [pc EXCEPT ![self] = "S_Loop"]
                /\ UNCHANGED << hdr, roots, origin, whole, promo, grey, busy, 
                                started, yReached, yPromoted, yPushes, 
                                recorded, stack, yy, cv, cd, csz, eo, ei, ev, 
                                ehw, sp0, st, shw, strunc, sm, sj, swalk, se, 
                                si, wr, we >>

S_Heads(self) == /\ pc[self] = "S_Heads"
                 /\ IF ~sneeds[self] \/ sk[self] = 0
                       THEN /\ pc' = [pc EXCEPT ![self] = "S_Done"]
                            /\ UNCHANGED << sm, sj, swalk >>
                       ELSE /\ IF MUTANT = "heads_walk"
                                  THEN /\ swalk' = [swalk EXCEPT ![self] = srun[self][1]]
                                       /\ pc' = [pc EXCEPT ![self] = "S_Walk"]
                                       /\ UNCHANGED << sm, sj >>
                                  ELSE /\ sm' = [sm EXCEPT ![self] = IF strunc[self] /\ MUTANT # "heads_all" THEN sk[self] - 1 ELSE sk[self]]
                                       /\ sj' = [sj EXCEPT ![self] = 1]
                                       /\ pc' = [pc EXCEPT ![self] = "S_HeadLoop"]
                                       /\ swalk' = swalk
                 /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                 owner, busy, started, yReached, yPromoted, 
                                 yPushes, recorded, res, stack, yy, cv, cd, 
                                 csz, eo, ei, ev, ehw, sp0, sprev, st, shw, sk, 
                                 srun, strunc, sneeds, se, si, wr, we >>

S_Walk(self) == /\ pc[self] = "S_Walk"
                /\ IF swalk[self] \in CopyIds /\ ~(strunc[self] /\ swalk[self] = sprev[self])
                      THEN /\ /\ ei' = [ei EXCEPT ![self] = 1]
                              /\ eo' = [eo EXCEPT ![self] = swalk[self]]
                              /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Evacuate",
                                                                       pc        |->  "S_WalkNext",
                                                                       ev        |->  ev[self],
                                                                       ehw       |->  ehw[self],
                                                                       eo        |->  eo[self],
                                                                       ei        |->  ei[self] ] >>
                                                                   \o stack[self]]
                           /\ ev' = [ev EXCEPT ![self] = Nil]
                           /\ ehw' = [ehw EXCEPT ![self] = Unfwd]
                           /\ pc' = [pc EXCEPT ![self] = "E_Read"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "S_Done"]
                           /\ UNCHANGED << stack, eo, ei, ev, ehw >>
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, yy, cv, cd, csz, sp0, 
                                sprev, st, shw, sk, srun, strunc, sneeds, sm, 
                                sj, swalk, se, si, wr, we >>

S_WalkNext(self) == /\ pc[self] = "S_WalkNext"
                    /\ swalk' = [swalk EXCEPT ![self] = IF Len(fld[swalk[self]]) >= 2 THEN fld[swalk[self]][2] ELSE Nil]
                    /\ pc' = [pc EXCEPT ![self] = "S_Walk"]
                    /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, 
                                    grey, owner, busy, started, yReached, 
                                    yPromoted, yPushes, recorded, res, stack, 
                                    yy, cv, cd, csz, eo, ei, ev, ehw, sp0, 
                                    sprev, st, shw, sk, srun, strunc, sneeds, 
                                    sm, sj, se, si, wr, we >>

S_HeadLoop(self) == /\ pc[self] = "S_HeadLoop"
                    /\ IF sj[self] <= sm[self]
                          THEN /\ /\ ei' = [ei EXCEPT ![self] = 1]
                                  /\ eo' = [eo EXCEPT ![self] = srun[self][sj[self]]]
                                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Evacuate",
                                                                           pc        |->  "S_HeadNext",
                                                                           ev        |->  ev[self],
                                                                           ehw       |->  ehw[self],
                                                                           eo        |->  eo[self],
                                                                           ei        |->  ei[self] ] >>
                                                                       \o stack[self]]
                               /\ ev' = [ev EXCEPT ![self] = Nil]
                               /\ ehw' = [ehw EXCEPT ![self] = Unfwd]
                               /\ pc' = [pc EXCEPT ![self] = "E_Read"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "S_Done"]
                               /\ UNCHANGED << stack, eo, ei, ev, ehw >>
                    /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, 
                                    grey, owner, busy, started, yReached, 
                                    yPromoted, yPushes, recorded, res, yy, cv, 
                                    cd, csz, sp0, sprev, st, shw, sk, srun, 
                                    strunc, sneeds, sm, sj, swalk, se, si, wr, 
                                    we >>

S_HeadNext(self) == /\ pc[self] = "S_HeadNext"
                    /\ sj' = [sj EXCEPT ![self] = sj[self] + 1]
                    /\ pc' = [pc EXCEPT ![self] = "S_HeadLoop"]
                    /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, 
                                    grey, owner, busy, started, yReached, 
                                    yPromoted, yPushes, recorded, res, stack, 
                                    yy, cv, cd, csz, eo, ei, ev, ehw, sp0, 
                                    sprev, st, shw, sk, srun, strunc, sneeds, 
                                    sm, swalk, se, si, wr, we >>

S_Done(self) == /\ pc[self] = "S_Done"
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ sprev' = [sprev EXCEPT ![self] = Head(stack[self]).sprev]
                /\ st' = [st EXCEPT ![self] = Head(stack[self]).st]
                /\ shw' = [shw EXCEPT ![self] = Head(stack[self]).shw]
                /\ sk' = [sk EXCEPT ![self] = Head(stack[self]).sk]
                /\ srun' = [srun EXCEPT ![self] = Head(stack[self]).srun]
                /\ strunc' = [strunc EXCEPT ![self] = Head(stack[self]).strunc]
                /\ sneeds' = [sneeds EXCEPT ![self] = Head(stack[self]).sneeds]
                /\ sm' = [sm EXCEPT ![self] = Head(stack[self]).sm]
                /\ sj' = [sj EXCEPT ![self] = Head(stack[self]).sj]
                /\ swalk' = [swalk EXCEPT ![self] = Head(stack[self]).swalk]
                /\ sp0' = [sp0 EXCEPT ![self] = Head(stack[self]).sp0]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, yy, cv, cd, csz, eo, 
                                ei, ev, ehw, se, si, wr, we >>

SpineRun(self) == S_Init(self) \/ S_Loop(self) \/ S_Load(self)
                     \/ S_Wait(self) \/ S_Claim(self) \/ S_Copy(self)
                     \/ S_Link(self) \/ S_Heads(self) \/ S_Walk(self)
                     \/ S_WalkNext(self) \/ S_HeadLoop(self)
                     \/ S_HeadNext(self) \/ S_Done(self)

SC_Loop(self) == /\ pc[self] = "SC_Loop"
                 /\ IF si[self] <= Len(fld[se[self]])
                       THEN /\ IF se[self] \in CopyIds /\ origin[se[self]] \in ConsIds /\ si[self] = 2
                                  THEN /\ /\ sp0' = [sp0 EXCEPT ![self] = se[self]]
                                          /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "SpineRun",
                                                                                   pc        |->  "SC_Next",
                                                                                   sprev     |->  sprev[self],
                                                                                   st        |->  st[self],
                                                                                   shw       |->  shw[self],
                                                                                   sk        |->  sk[self],
                                                                                   srun      |->  srun[self],
                                                                                   strunc    |->  strunc[self],
                                                                                   sneeds    |->  sneeds[self],
                                                                                   sm        |->  sm[self],
                                                                                   sj        |->  sj[self],
                                                                                   swalk     |->  swalk[self],
                                                                                   sp0       |->  sp0[self] ] >>
                                                                               \o stack[self]]
                                       /\ sprev' = [sprev EXCEPT ![self] = Nil]
                                       /\ st' = [st EXCEPT ![self] = Nil]
                                       /\ shw' = [shw EXCEPT ![self] = Unfwd]
                                       /\ sk' = [sk EXCEPT ![self] = 0]
                                       /\ srun' = [srun EXCEPT ![self] = <<>>]
                                       /\ strunc' = [strunc EXCEPT ![self] = FALSE]
                                       /\ sneeds' = [sneeds EXCEPT ![self] = FALSE]
                                       /\ sm' = [sm EXCEPT ![self] = 0]
                                       /\ sj' = [sj EXCEPT ![self] = 0]
                                       /\ swalk' = [swalk EXCEPT ![self] = Nil]
                                       /\ pc' = [pc EXCEPT ![self] = "S_Init"]
                                       /\ UNCHANGED << eo, ei, ev, ehw >>
                                  ELSE /\ /\ ei' = [ei EXCEPT ![self] = si[self]]
                                          /\ eo' = [eo EXCEPT ![self] = se[self]]
                                          /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Evacuate",
                                                                                   pc        |->  "SC_Next",
                                                                                   ev        |->  ev[self],
                                                                                   ehw       |->  ehw[self],
                                                                                   eo        |->  eo[self],
                                                                                   ei        |->  ei[self] ] >>
                                                                               \o stack[self]]
                                       /\ ev' = [ev EXCEPT ![self] = Nil]
                                       /\ ehw' = [ehw EXCEPT ![self] = Unfwd]
                                       /\ pc' = [pc EXCEPT ![self] = "E_Read"]
                                       /\ UNCHANGED << sp0, sprev, st, shw, sk, 
                                                       srun, strunc, sneeds, 
                                                       sm, sj, swalk >>
                       ELSE /\ pc' = [pc EXCEPT ![self] = "SC_Done"]
                            /\ UNCHANGED << stack, eo, ei, ev, ehw, sp0, sprev, 
                                            st, shw, sk, srun, strunc, sneeds, 
                                            sm, sj, swalk >>
                 /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                 owner, busy, started, yReached, yPromoted, 
                                 yPushes, recorded, res, yy, cv, cd, csz, se, 
                                 si, wr, we >>

SC_Next(self) == /\ pc[self] = "SC_Next"
                 /\ si' = [si EXCEPT ![self] = si[self] + 1]
                 /\ pc' = [pc EXCEPT ![self] = "SC_Loop"]
                 /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                 owner, busy, started, yReached, yPromoted, 
                                 yPushes, recorded, res, stack, yy, cv, cd, 
                                 csz, eo, ei, ev, ehw, sp0, sprev, st, shw, sk, 
                                 srun, strunc, sneeds, sm, sj, swalk, se, wr, 
                                 we >>

SC_Done(self) == /\ pc[self] = "SC_Done"
                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                 /\ si' = [si EXCEPT ![self] = Head(stack[self]).si]
                 /\ se' = [se EXCEPT ![self] = Head(stack[self]).se]
                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                 /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                 owner, busy, started, yReached, yPromoted, 
                                 yPushes, recorded, res, yy, cv, cd, csz, eo, 
                                 ei, ev, ehw, sp0, sprev, st, shw, sk, srun, 
                                 strunc, sneeds, sm, sj, swalk, wr, we >>

Scan(self) == SC_Loop(self) \/ SC_Next(self) \/ SC_Done(self)

W_Roots(self) == /\ pc[self] = "W_Roots"
                 /\ IF self = W0
                       THEN /\ pc' = [pc EXCEPT ![self] = "W_RootLoop"]
                       ELSE /\ started
                            /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                 /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                 owner, busy, started, yReached, yPromoted, 
                                 yPushes, recorded, res, stack, yy, cv, cd, 
                                 csz, eo, ei, ev, ehw, sp0, sprev, st, shw, sk, 
                                 srun, strunc, sneeds, sm, sj, swalk, se, si, 
                                 wr, we >>

W_RootLoop(self) == /\ pc[self] = "W_RootLoop"
                    /\ IF wr[self] <= Len(roots)
                          THEN /\ /\ ei' = [ei EXCEPT ![self] = wr[self]]
                                  /\ eo' = [eo EXCEPT ![self] = Nil]
                                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Evacuate",
                                                                           pc        |->  "W_RootNext",
                                                                           ev        |->  ev[self],
                                                                           ehw       |->  ehw[self],
                                                                           eo        |->  eo[self],
                                                                           ei        |->  ei[self] ] >>
                                                                       \o stack[self]]
                               /\ ev' = [ev EXCEPT ![self] = Nil]
                               /\ ehw' = [ehw EXCEPT ![self] = Unfwd]
                               /\ pc' = [pc EXCEPT ![self] = "E_Read"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "W_Start"]
                               /\ UNCHANGED << stack, eo, ei, ev, ehw >>
                    /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, 
                                    grey, owner, busy, started, yReached, 
                                    yPromoted, yPushes, recorded, res, yy, cv, 
                                    cd, csz, sp0, sprev, st, shw, sk, srun, 
                                    strunc, sneeds, sm, sj, swalk, se, si, wr, 
                                    we >>

W_RootNext(self) == /\ pc[self] = "W_RootNext"
                    /\ wr' = [wr EXCEPT ![self] = wr[self] + 1]
                    /\ pc' = [pc EXCEPT ![self] = "W_RootLoop"]
                    /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, 
                                    grey, owner, busy, started, yReached, 
                                    yPromoted, yPushes, recorded, res, stack, 
                                    yy, cv, cd, csz, eo, ei, ev, ehw, sp0, 
                                    sprev, st, shw, sk, srun, strunc, sneeds, 
                                    sm, sj, swalk, se, si, we >>

W_Start(self) == /\ pc[self] = "W_Start"
                 /\ started' = TRUE
                 /\ wr' = [wr EXCEPT ![self] = 1]
                 /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                 /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                 owner, busy, yReached, yPromoted, yPushes, 
                                 recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                                 ev, ehw, sp0, sprev, st, shw, sk, srun, 
                                 strunc, sneeds, sm, sj, swalk, se, si, we >>

W_Loop(self) == /\ pc[self] = "W_Loop"
                /\ \/ /\ \E x \in grey:
                           /\ grey' = grey \ {x}
                           /\ owner' = [owner EXCEPT ![x] = self]
                           /\ busy' = [busy EXCEPT ![self] = TRUE]
                           /\ we' = [we EXCEPT ![self] = x]
                      /\ pc' = [pc EXCEPT ![self] = "W_Scan"]
                   \/ /\ grey = {} /\ \A w \in Workers : ~busy[w]
                      /\ pc' = [pc EXCEPT ![self] = "W_Exit"]
                      /\ UNCHANGED <<grey, owner, busy, we>>
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, started, 
                                yReached, yPromoted, yPushes, recorded, res, 
                                stack, yy, cv, cd, csz, eo, ei, ev, ehw, sp0, 
                                sprev, st, shw, sk, srun, strunc, sneeds, sm, 
                                sj, swalk, se, si, wr >>

W_Scan(self) == /\ pc[self] = "W_Scan"
                /\ /\ se' = [se EXCEPT ![self] = we[self]]
                   /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Scan",
                                                            pc        |->  "W_Idle",
                                                            si        |->  si[self],
                                                            se        |->  se[self] ] >>
                                                        \o stack[self]]
                /\ si' = [si EXCEPT ![self] = 1]
                /\ pc' = [pc EXCEPT ![self] = "SC_Loop"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, yy, cv, cd, csz, eo, 
                                ei, ev, ehw, sp0, sprev, st, shw, sk, srun, 
                                strunc, sneeds, sm, sj, swalk, wr, we >>

W_Idle(self) == /\ pc[self] = "W_Idle"
                /\ busy' = [busy EXCEPT ![self] = FALSE]
                /\ we' = [we EXCEPT ![self] = Nil]
                /\ pc' = [pc EXCEPT ![self] = "W_Loop"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, started, yReached, yPromoted, yPushes, 
                                recorded, res, stack, yy, cv, cd, csz, eo, ei, 
                                ev, ehw, sp0, sprev, st, shw, sk, srun, strunc, 
                                sneeds, sm, sj, swalk, se, si, wr >>

W_Exit(self) == /\ pc[self] = "W_Exit"
                /\ TRUE
                /\ pc' = [pc EXCEPT ![self] = "Done"]
                /\ UNCHANGED << hdr, fld, roots, origin, whole, promo, grey, 
                                owner, busy, started, yReached, yPromoted, 
                                yPushes, recorded, res, stack, yy, cv, cd, csz, 
                                eo, ei, ev, ehw, sp0, sprev, st, shw, sk, srun, 
                                strunc, sneeds, sm, sj, swalk, se, si, wr, we >>

Worker(self) == W_Roots(self) \/ W_RootLoop(self) \/ W_RootNext(self)
                   \/ W_Start(self) \/ W_Loop(self) \/ W_Scan(self)
                   \/ W_Idle(self) \/ W_Exit(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == (\E self \in ProcSet:  \/ ReachYlos(self) \/ Copy(self)
                               \/ Evacuate(self) \/ SpineRun(self)
                               \/ Scan(self))
           \/ (\E self \in Workers: Worker(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Workers : /\ WF_vars(Worker(self))
                                 /\ WF_vars(Evacuate(self))
                                 /\ WF_vars(Scan(self))
                                 /\ WF_vars(ReachYlos(self))
                                 /\ WF_vars(Copy(self))
                                 /\ WF_vars(SpineRun(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

-----------------------------------------------------------------------------
AllDone == \A w \in Workers : pc[w] = "Done"
\* MODEL_M3_1: slot writes are owner-only. A worker about to evacuate a slot of
\* object eo owns eo (roots: eo = Nil, worker 0 before the gang). An invariant,
\* not an assert, so the runner can match mutants heads_walk and heads_all by name.
OwnerWrites == \A w \in Workers : pc[w] = "E_Read" => (eo[w] = Nil \/ owner[eo[w]] = w)
RECURSIVE ReachFrom(_)
Succ(S) == UNION {{InitFields[o][i] : i \in 1..Len(InitFields[o])} : o \in S \cap (FromIds \cup YlosIds)}
ReachFrom(S) == LET N == S \cup Succ(S) IN IF N = S THEN S ELSE ReachFrom(N)
Reachable == ReachFrom({InitRoots[i] : i \in 1..Len(InitRoots)})
ReachedYlos == {q \in YlosIds : yReached[q]}
SlotsOf(o) == {<<o, x>> : x \in 1..Len(fld[o])}
LiveSlots == {<<Nil, x>> : x \in 1..Len(roots)} \cup UNION {SlotsOf(o) : o \in Copies \cup ReachedYlos}
Old(o) == (o \in Copies /\ promo[o]) \/ (o \in YlosIds /\ yPromoted[o]) \/ o \in OldIds
\* The value a slot held before the minor (from-space objects are immutable).
OrigVal(o, x) == IF o = Nil THEN InitRoots[x]
                 ELSE IF o \in CopyIds THEN InitFields[origin[o]][x]
                 ELSE InitFields[o][x]
\* The value it must hold after the minor.
Expected(val) == IF val \in FromIds THEN hdr[val]
                 ELSE IF val \in RetireIds THEN RetireFwd[val]
                 ELSE val
\* PM2: every live slot holds exactly the copy its old target's header forwards
\* to (never a from-space address, never 0 from BUSY), or the tenured copy of a
\* Retire object, or its old value (old, YLOS, Hand, constant).
SlotsAtCopy == \A sl \in LiveSlots : SlotVal(sl[1], sl[2]) = Expected(OrigVal(sl[1], sl[2]))
\* The CopyOnce contract (parent plan 5.0) that M5 consumes.
CopyOnceContract == CopyOnce /\ (AllDone => SlotsAtCopy)

\* At the join (every worker exited):
\*  - no BUSY word is left (HEAP_006 / HEAP_067);
\*  - every reachable from-space object was forwarded;
\*  - PM2 / the slot half of CopyOnce (SlotsAtCopy);
\*  - PM5 (HEAP_005): no promoted object points at a young (surviving) copy;
\*  - region (HEAP_069): every slot pointing into Hand was recorded.
AtJoin ==
    AllDone =>
        /\ \A o \in FromIds : hdr[o] # Busy
        /\ \A o \in Reachable \cap FromIds : hdr[o] \in CopyIds
        /\ SlotsAtCopy
        /\ \A sl \in LiveSlots :
               (sl[1] # Nil /\ Old(sl[1]) /\ SlotVal(sl[1], sl[2]) \in CopyIds)
                   => promo[SlotVal(sl[1], sl[2])]
        /\ \A sl \in LiveSlots : (SlotVal(sl[1], sl[2]) \in HandIds) => sl \in recorded
=============================================================================
