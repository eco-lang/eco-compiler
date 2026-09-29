------------------------------ MODULE Tenuring ------------------------------
\* M5: the region nursery and concurrent tenuring (threaded-gc 7b/7c), with the
\* plan's extensions: builders (BC > 0), generation YLOS (YC > 0) and 07b
\* ageing (K = 2). Plan: plans/threaded-gc-tla-M5-tenuring.md. Model <-> code:
\* MAPPING.md (this directory). Results and every deviation from the plan's
\* sketch: AUDIT.md.
\* Edit the PlusCal below, never the translation: re-translate in a scratch copy
\* (`pcal -nocfg Tenuring.tla`) and copy the result back.
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    K,              \* tenure age k (promotion_age): 1, or 2 (07b ageing; exact engine only)
    EC,             \* eden cells per epoch
    SC,             \* survivor-part cells per extent (>= EC + BC: a fill never overflows)
    BC,             \* builder-area cells per extent (0: no builders)
    OC,             \* old-gen cells (>= MaxLid: each object is tenured at most once)
    YC,             \* young large object (YLOS) cells (0: no YLOS)
    NF,             \* pointer fields per object
    Roots,          \* root slots (stack slots, RootSet, CellStore cells ...)
    MaxLid,         \* objects in a behaviour, the seeded old object included
    OldSeed,        \* 1: one old object exists at Init, held by a root
    MaxMinors, MaxMajors,
    MaxTotalOps,    \* mutator operations per behaviour (the state-space lever)
    Ops,            \* the mutator operation kinds explored (a subset of OpKinds)
    TenureMode,     \* 1 = the job runs in the hand-over pause; 2 = on the collector
    Collectors,     \* 1 = the exact engine (no claim); 2 = L3 members (claim CAS)
    HelpAllowed,    \* tenure_help = 1: a late collector is stopped and helped
    MajorAllowed,   \* STW majors between minors
    CycleAllowed,   \* incremental mark cycles (abstract: t0 greys, handoff)
    CycleT,         \* minors from t0 to the handoff
    GenMod,         \* shadow generations are 1 .. GenMod-1, then wrap (2^21 in code)
    StopAllowed,    \* a fork prepare hook may stop the collector at any time
    YlosGen,        \* how an extent's ylos_gen list names its generation's YLOS (CR-034):
                    \*   "identity": by object (a member a STW major frees leaves no entry; the
                    \*               model before 2026-09-29, and fix candidate 1's effect);
                    \*   "code": by address, as the code does: the major leaves the address, and the
                    \*           next prep takes whatever young YLOS sits there for a member
                    \*           (NurseryRegion.cpp:751-753, :773-775);
                    \*   fix controls (address-keyed + a check at the prep): "drop" (the major drops
                    \*   the address from every list = "identity"), "age1" (skip an entry whose
                    \*   YLOS has header age 0), "stamp" (a never-reused registration stamp), "lbid"
                    \*   (the LargeBodyId as the stamp; the release recycles it LIFO)
    Cr017Oracle,    \* model-only: the t0 walk skips dead survivor and builder objects, standing for
                    \* any CR-017 fix, so a configuration can look past CR-017 (not a fix design)
    LbKey,          \* the lb_bodies lists (large bodies, op "lalloc"), address-keyed in the code:
                    \*   "code": the prep's markLargeBodySeen colours whatever index entry sits at the
                    \*           address (NurseryRegion.cpp:749, :771), a young YLOS included;
                    \*   fix controls: "kind" (colour kind-0 bodies only), "drop" (the major drops a
                    \*   freed body from every list), "identity" (a never-reused stamp: a stale entry
                    \*   never matches; also the value for configurations without "lalloc")
    MUTANT

ASSUME K \in {1, 2} /\ (K = 2 => Collectors = 1)      \* age_forced_exact
ASSUME SC >= EC + BC /\ OC >= MaxLid
ASSUME YlosGen \in {"identity", "code", "drop", "age1", "stamp", "lbid"} /\ Cr017Oracle \in BOOLEAN
ASSUME LbKey \in {"identity", "code", "kind", "drop"}

OpKinds == {"alloc", "load", "drop", "balloc", "bwrite", "bclear", "yalloc", "lalloc"}
X == 1..(K + 2)                           \* survivor extents (k + 2)
EAddr == {<<"E", c>> : c \in 1..EC}
SAddr == {<<"S", x, c>> : x \in X, c \in 1..SC}     \* survivor parts
BAddr == {<<"B", x, c>> : x \in X, c \in 1..BC}     \* builder areas
OAddr == {<<"O", c>> : c \in 1..OC}
YAddr == {<<"Y", c>> : c \in 1..YC}                 \* YLOS cells (old-gen cells, young until promoted)
Addr == EAddr \cup SAddr \cup BAddr \cup OAddr \cup YAddr
Nil == <<"N">>
Fields == 1..NF
Empty == [lid |-> 0, f |-> [i \in Fields |-> Nil], b |-> FALSE]
NoEntry == [st |-> 0, dst |-> Nil, g |-> 0]           \* shadow: 0 unvisited, 1 BUSY, 2 FWD
IsE(a) == a # Nil /\ a[1] = "E"
IsS(a, x) == a # Nil /\ a[1] = "S" /\ a[2] = x
IsB(a, x) == a # Nil /\ a[1] = "B" /\ a[2] = x
IsO(a) == a # Nil /\ a[1] = "O"
IsY(a) == a # Nil /\ a[1] = "Y"
Gen(x) == <<"G", x>>                      \* a YLOS object's generation (the fill that first reached it)
YFree == <<"Free", 0>>                    \* YLOS states (one type, so TLC can compare them)
Y0 == <<"Y0", 0>>                         \* young, age 0: not reached by a minor yet
YOld == <<"Old", 0>>                      \* promoted in place
YDead == <<"Dead", 0>>                    \* unlinked by a minor mid-cycle; freed at the handoff
YBody == <<"Body", 0>>                    \* a nursery-owned large body (kind 0; its header is young)
YoungYS == {Y0} \cup {Gen(x) : x \in X}   \* YLOS states that are young (in the index)
MutId == 0
CollIds == 101..(100 + Collectors)
EnvId == 200
R0 == CHOOSE r \in Roots : TRUE           \* the root that holds the seeded old object
Seed == <<"O", 1>>
RECURSIVE SetToSeq(_)
SetToSeq(S) == IF S = {} THEN <<>>
               ELSE LET e == CHOOSE y \in S : TRUE IN <<e>> \o SetToSeq(S \ {e})
Range(sq) == {sq[i] : i \in 1..Len(sq)}
Remove(sq, k) == SubSeq(sq, 1, k - 1) \o SubSeq(sq, k + 1, Len(sq))
NextGen(g) == IF g + 1 >= GenMod THEN 1 ELSE g + 1
\* Reachability through heap h from the set G (a fixpoint that stops early).
RECURSIVE CloseIn(_, _)
CloseIn(G, h) ==
    LET N == G \cup {h[a].f[i] : a \in G \ {Nil}, i \in Fields}
    IN IF N = G THEN G ELSE CloseIn(N, h)
\* The minor's slot list: a root, or field i of a cell scanned with colour col
\* (surv: a fill copy; bld: a builder copy; yy: a young YLOS of generation m;
\* hy: a hand-over-generation YLOS).
FieldSlots(a, col) == [i \in Fields |-> <<"fld", a, i, col>>]

(* --algorithm Tenuring
variables
    heap    = [a \in Addr |-> IF OldSeed = 1 /\ a = Seed
                              THEN [Empty EXCEPT !.lid = 1] ELSE Empty],
    root    = [r \in Roots |-> IF OldSeed = 1 /\ r = R0 THEN Seed ELSE Nil],
    lheap   = [l \in 1..MaxLid |-> [i \in Fields |-> 0]],   \* ghost: the logical graph
    lroot   = [r \in Roots |-> IF OldSeed = 1 /\ r = R0 THEN 1 ELSE 0],   \* ghost
    nextLid = 1 + OldSeed,
    ops     = 0,                                   \* mutator operations so far (bound)
    ebump   = 1,                                   \* eden bump (bump_.ptr)
    xstate  = [x \in X |-> "Free"],                \* Extent::state: Free | Young | Tenuring
    xage    = [x \in X |-> 0],                     \* Extent::age (Young: 1 .. K)
    gen     = [x \in X |-> 0],                     \* Extent::gen
    shadow  = [x \in X |-> [c \in 1..SC |-> NoEntry]],   \* RegionState::shadow
    ys      = [c \in 1..YC |-> YFree],            \* YLOS: Free | Y0 (age 0) | Gen(x) | Old | Dead (unlinked, freed at the handoff)
    \* CR-034 (YlosGen address-keyed only; constant otherwise): ystale[c] = the Young
    \* extents whose ylos_gen still lists address c although ys[c] does not name that
    \* generation (its member was freed by a STW major, or the prep of another list
    \* claimed the occupant); yrec[c] = the occupant's LargeBodyId is the one its
    \* freed predecessor had ("lbid" only); yjoin[c] = ghost: the extent whose
    \* generation the occupant joined at its first reach (0: none).
    ystale  = [c \in 1..YC |-> {}],
    yrec    = [c \in 1..YC |-> FALSE],
    yjoin   = [c \in 1..YC |-> 0],
    \* Large bodies (op "lalloc"; constant otherwise): lbl[c] = the entries <<x, lid>> of
    \* the Young extents x whose lb_bodies list names address c (lid: the body listed);
    \* ycol = the Y cells whose index entry carries this minor's colour before the
    \* reach (the prep's markLargeBodySeen) or from a copied header (lb_seen);
    \* bodyLids = ghost: the lids that are bodies (Elm code never holds a body).
    lbl     = [c \in 1..YC |-> {}],
    ycol    = {},
    bodyLids = {},
    job     = [st |-> "None", x |-> 0],            \* TenureJob::state, x
    jstarts = <<>>, jheal = <<>>, jstack = <<>>,   \* SerialState: starts, heal, stack (of copies)
    ns = 1, nh = 1,                                \* next_start, next_heal
    jreached = {}, jylos = <<>>, ny = 1,           \* reached[], ylos_pending, ylos_next
    ageX = 0, jSA = <<>>, nsa = 1,                 \* 07b: the ageing extent, age_starts, next_age_start
    astack = <<>>, amark = {}, swept = TRUE, zap = {},   \* 07b: age_stack, mark bits, sweep done, zap spans
    grant   = {},                                  \* TenureGrant: old cells owned by the job
    stop    = FALSE,                               \* TenureJob::stop
    running = 0,                                   \* collector members still in the engine
    calive  = TRUE,                                \* FALSE: the collector thread is gone (fork child)
    go      = [c \in CollIds |-> FALSE],           \* a launch not yet seen (generation_ != seen)
    minors  = 0, majors = 0,
    S = {}, H = {}, SA = {}, ypr = {},             \* pend_S, pend_H, pend_SA, hand_ylos_reached
    cycle   = "Idle", grey = {}, black = {}, cage = 0,
    liveHand = {}, liveHandY = {}, liveAge = {},   \* ghosts: legacy's promoted / live sets at the hand-over
    cw      = {},                                  \* ghost: cells the collector wrote this job
    ncopy   = [a \in SAddr |-> 0];                 \* ghost: copies made per tenuring object

define
    LidOf(a) == IF a = Nil THEN 0 ELSE heap[a].lid
    FwdOf(a) == LET e == shadow[a[2]][a[3]]
                IN IF e.st = 2 /\ e.g = gen[a[2]] THEN e.dst ELSE Nil
    Busy(a)  == LET e == shadow[a[2]][a[3]] IN e.st = 1 /\ e.g = gen[a[2]]
    XObjs(x) == {a \in SAddr : a[2] = x /\ heap[a].lid # 0}
    YoungY(a) == IsY(a) /\ ys[a[2]] \in YoungYS
    HandY(x) == {y \in YAddr : ys[y[2]] = Gen(x)}   \* the generation of extent x (J.st.ylos)
    \* An old-gen address the t0 snapshot greys: an old cell, or a YLOS cell that
    \* is not young (promoted, unlinked or free).
    OldAddr(a) == IsO(a) \/ (IsY(a) /\ ys[a[2]] \notin YoungYS)
    OldObj(a) == heap[a].lid # 0 /\ (IsO(a) \/ (IsY(a) /\ ys[a[2]] = YOld))
    OldTarget(v) == v = Nil \/ IsO(v) \/ (IsY(v) /\ ys[v[2]] = YOld)
    \* A cell a reference may name: allocated, and not in a Free extent, a stale
    \* builder area, a free or unlinked YLOS cell (TV7's stale-pointer rules).
    Allocated(a) == /\ heap[a].lid # 0
                    /\ a[1] \in {"S", "B"} => xstate[a[2]] # "Free"
                    /\ a[1] = "B" => (xstate[a[2]] = "Young" /\ xage[a[2]] = 1)
                    /\ IsY(a) => ys[a[2]] \notin {YFree, YDead}
    IsBld(a) == a # Nil /\ heap[a].b
    PlainHeld == {root[q] : q \in {q2 \in Roots : ~IsBld(root[q2])}}   \* storable by Elm code (HEAP_BUILDER_003)
    HealVal(s) == IF s[1][1] = "R" THEN root[s[1][2]] ELSE heap[s[1]].f[s[2]]
    AgeCells == IF ageX = 0 THEN {}
                ELSE {a \in SAddr : a[2] = ageX} \cup {y \in YAddr : ys[y[2]] = Gen(ageX)}
    Close(G) == CloseIn(G, heap)
    ReachAll == Close({root[r] : r \in Roots}) \ {Nil}
    \* forEachYoung + snapshotYoungLarge: survivor parts of Young and Tenuring
    \* extents, the Fresh builder area, every young YLOS (non-free cells only).
    \* Cr017Oracle (model-only) drops the dead survivor and builder objects.
    Walk(skipTenuring) ==
        {a \in SAddr : heap[a].lid # 0 /\ (xstate[a[2]] = "Young"
                                           \/ (xstate[a[2]] = "Tenuring" /\ ~skipTenuring))
                       /\ (Cr017Oracle => a \in ReachAll)}
        \cup {a \in BAddr : heap[a].lid # 0 /\ xstate[a[2]] = "Young" /\ xage[a[2]] = 1
                            /\ (Cr017Oracle => a \in ReachAll)}
        \cup {y \in YAddr : YoungY(y)}
    \* CR-034: ylos_gen is keyed by address. The prep of a minor takes address
    \* entry c of extent x's list for a member if youngLargeMeta(c) finds a young
    \* YLOS there (NurseryRegion.cpp:751-753 hand-over, :773-775 ageing) and the
    \* fix control's check passes. Reads ys / ystale / yrec as they were at the
    \* start of the step (the prep runs before any reach).
    AddrKeyed == YlosGen \notin {"identity", "drop"}
    PrepOK(c) == CASE YlosGen = "age1"  -> ys[c] # Y0           \* header age >= 1
                   [] YlosGen = "stamp" -> FALSE                \* a never-reused stamp never matches a stale entry
                   [] YlosGen = "lbid"  -> yrec[c]              \* the LargeBodyId matches iff it was recycled
                   [] OTHER             -> TRUE                 \* "code": youngLargeMeta only
    PrepMatch(c, x) == x # 0 /\ x \in ystale[c] /\ ys[c] \in YoungYS /\ PrepOK(c)
    \* Large bodies. markLargeBodySeen (OldGenSpace.cpp:7542-7552) colours the index
    \* entry at the listed address, whatever its kind (a body or a young YLOS).
    IsBodyRef(v) == v # Nil /\ IsY(v) /\ heap[v].lid \in bodyLids
    LbMatch(c, en) == /\ ys[c] \in YoungYS \cup {YBody}          \* an index entry is there
                      /\ CASE LbKey = "kind"     -> ys[c] = YBody
                           [] LbKey = "identity" -> heap[<<"Y", c>>].lid = en[2]
                           [] OTHER              -> TRUE        \* "code", "drop"
    LbColoured(x) == {<<"Y", c>> : c \in {c2 \in 1..YC : \E en \in lbl[c2] : en[1] = x /\ LbMatch(c2, en)}}
    \* promoteLargeHeader at the merge: the bodies of the headers this job copied (J.lb_promoted).
    LbPromoted == {v \in YAddr : ys[v[2]] = YBody /\ \E a \in cw \cap OAddr, i \in Fields : heap[a].f[i] = v}
    OldClose(G) == Close(G) \ {Nil}
    \* majorRedirect: a merged job's extent is traversed through its copies.
    Redir(a) == IF a # Nil /\ job.st = "Merged" /\ IsS(a, job.x) /\ xstate[job.x] = "Tenuring"
                   /\ MUTANT # "major_greys_original"
                THEN FwdOf(a) ELSE a
    RECURSIVE CloseR(_)
    CloseR(G) ==
        LET N == G \cup {Redir(heap[a].f[i]) : a \in G \ {Nil}, i \in Fields}
        IN IF N = G THEN G ELSE CloseR(N)
    MajorLive == CloseR({Redir(root[r]) : r \in Roots})
    MarkDone == astack = <<>> /\ nsa > Len(jSA) /\ swept
    JobDone == MarkDone /\ jstack = <<>> /\ ns > Len(jstarts) /\ nh > Len(jheal) /\ ny > Len(jylos)
    InEpoch == pc[MutId] = "M_Epoch"
    FreeGrant == {a \in grant : heap[a].lid = 0}
    CanOp(kd) == kd \in Ops /\ ops < MaxTotalOps
    AtMerge == pc[MutId] = "J_Merge" /\ job.st = "Running"
    \* ---- properties (all invariants; no assert, so every mutant names one) ----
    NoDangling ==                                  \* TV7: no reachable reference to freed memory
        InEpoch => \A a \in ReachAll : Allocated(a)
    GraphPreserved ==                              \* GC never changes what the mutator sees
        InEpoch =>
            /\ \A r \in Roots : LidOf(root[r]) = lroot[r]
            /\ \A a \in ReachAll : heap[a].lid # 0 =>     \* a freed cell is NoDangling's
                   \A i \in Fields : LidOf(heap[a].f[i]) = lheap[heap[a].lid][i]
    CollectorPrivate ==                            \* FORBID_HEAP_004
        ((running > 0 /\ calive) \/ job.st = "Running") => cw \cap ReachAll = {}
    ExactlyOnce == \A a \in SAddr : ncopy[a] <= 1  \* TV3
    OldPointsOld ==                                \* HEAP_005 (amended: copies until the merge)
        \A a \in OAddr \cup YAddr : (OldObj(a) /\ ~(job.st = "Running" /\ a \in grant)) =>
            \A i \in Fields : OldTarget(heap[a].f[i])
    HealYoungOnly ==                               \* 07 T2, FORBID_HEAP_004: M1's open question 3
        job.st = "Running" =>
            \A s \in Range(jheal) :
                \/ s[1][1] = "S" /\ xstate[s[1][2]] = "Young"      \* a Fresh copy, or a marked ageing object
                \/ s[1][1] = "Y" /\ \E x \in X : xstate[x] = "Young" /\ ys[s[1][2]] = Gen(x)   \* a young YLOS
    MarkerDisjoint ==                              \* TV8 + IM3: the contract M1 assumes
        cycle = "Marking" =>
            /\ \A a \in OldClose(grey) : OldAddr(a) /\ a \notin grant /\ a \notin black
            /\ (job.st = "Running" => cw \cap OAddr \subseteq black)
    YoungWalkValid ==                              \* CR-017 (and 07b's TV2Y): a possible t0 walk reads only allocated cells
        (pc[MutId] = "MN_Cycle" /\ CycleAllowed /\ cycle = "Idle") =>
            \A a \in Walk(FALSE) : \A i \in Fields :
                heap[a].f[i] # Nil => Allocated(heap[a].f[i])
    T0GreyAllocated ==                             \* CR-017's half of YoungWalkValid: every cell a possible
        (pc[MutId] = "MN_Cycle" /\ CycleAllowed /\ cycle = "Idle") =>   \* t0 would grey is allocated (the t0
            \A a \in Walk(FALSE) : \A i \in Fields :                    \* snapshot drops young targets by range)
                (heap[a].f[i] # Nil /\ OldAddr(heap[a].f[i])) => Allocated(heap[a].f[i])
    TenuredEqualsLegacy ==                         \* E1 oracle / TV2, checked as the merge starts
        AtMerge =>
            /\ {a \in XObjs(job.x) : FwdOf(a) # Nil} = liveHand
            /\ jreached \cap HandY(job.x) = liveHandY   \* promoted generation YLOS
            /\ amark = liveAge                          \* 07b: the ageing mark
    TV1_Heal ==                                    \* TV1 (every build): each heal target has FWD
        AtMerge =>
            \A s \in Range(jheal) : IsS(HealVal(s), job.x) => FwdOf(HealVal(s)) # Nil
    TV1_Ylos ==                                    \* TV1 at the merge's generation-YLOS resolve
        AtMerge =>
            \A y \in jreached \cap HandY(job.x) : \A i \in Fields :
                IsS(heap[y].f[i], job.x) => FwdOf(heap[y].f[i]) # Nil
    TV1_Major ==                                   \* TV1 at the STW major's redirect
        pc[MutId] = "MJ_Mark" =>
            \A q \in {root[r] : r \in Roots} \cup {heap[a].f[i] : a \in MajorLive \ {Nil}, i \in Fields} :
                (q # Nil /\ job.st = "Merged" /\ IsS(q, job.x) /\ xstate[job.x] = "Tenuring")
                    => FwdOf(q) # Nil
    BuilderYoung ==                                \* HEAP_BUILDER_001, 07 trap 13
        \A a \in Addr : (heap[a].lid # 0 /\ heap[a].b) => (IsE(a) \/ a[1] = "B")
    YlosFreed ==                                   \* an unreached generation YLOS is freed with its extent
        InEpoch => \A c \in 1..YC : ys[c] \in {Gen(x) : x \in X} => xstate[ys[c][2]] # "Free"
    YlosGenIdentity ==                             \* CR-034 (HEAP_062/HEAP_070): a generation's YLOS
        \A c \in 1..YC :                           \* members are the objects that joined it
            ys[c] \in {Gen(x) : x \in X} => yjoin[c] = ys[c][2]
end define;

\* A minor's slot write (a root, or a field of a copy / YLOS the pause owns).
macro SetSlot(c, val) begin
    if c[1] = "root" then root[c[2]] := val; else heap[c[2]].f[c[3]] := val; end if;
end macro;

\* The engine (TenureWork.hpp SerialEngine; with Collectors > 1 the claim
\* protocol of TenureParEnv::tenure). One item = one ageing mark or sweep step,
\* one start, one heal slot, or one popped copy's (or reached YLOS object's)
\* whole scan (scanCopy / scanYlos: its NF child slots in order; `sc`, `si`,
\* `scy` are the C++ frame, not SerialState, so a thread that dies mid-scan
\* loses them). `canStop`: the collector honours stop between items; help (the
\* pause) does not.
procedure Engine(canStop)
variables tgt = Nil, fix = Nil, e = NoEntry, res = Nil, sc = Nil, si = 1, scy = FALSE;
begin
  E_Loop:                                          \* SerialEngine::run: the stop check, then step()
        await ~canStop \/ calive;
        if canStop /\ stop /\ sc = Nil then return;     \* stop only between items, even with no work left
        elsif JobDone /\ sc = Nil then goto E_Ret;       \* step() found no item: Done
        end if;
      E_Item:                                      \* SerialEngine::step / the next child of scanCopy
        await ~canStop \/ calive;
        if sc # Nil then                           \* child slot si of the copy / YLOS being scanned
            tgt := heap[sc].f[si];
            fix := IF scy THEN Nil ELSE <<sc, si>>;   \* scanYlos is read-only
            if si < NF then si := si + 1; else sc := Nil; si := 1; scy := FALSE; end if;
        elsif ~MarkDone then                       \* 07b markOrSweepStep: one item, job-private writes only
            if astack # <<>> then                  \* scanAge(o): mark, heal slots into Hand, reach YLOS
                with o = astack[Len(astack)],
                     kids = {heap[o].f[i] : i \in Fields},
                     newM = {t2 \in kids : t2 \in AgeCells /\ t2 \notin amark},
                     hy = {t2 \in kids : t2 \in HandY(job.x) /\ t2 \notin jreached} do
                    amark := amark \cup newM;
                    astack := SubSeq(astack, 1, Len(astack) - 1) \o SetToSeq(newM);
                    if MUTANT # "age_mark_no_heal" then
                        jheal := jheal \o SetToSeq({<<o, i>> : i \in {i2 \in Fields : IsS(heap[o].f[i2], job.x)}});
                    end if;
                    jreached := jreached \cup hy;
                    jylos := jylos \o SetToSeq(hy);
                end with;
            elsif nsa <= Len(jSA) then             \* markTarget(age_starts[i], nullptr)
                if jSA[nsa] \notin amark then
                    amark := amark \cup {jSA[nsa]};
                    astack := Append(astack, jSA[nsa]);
                end if;
                nsa := nsa + 1;
            else                                   \* sweepStep: the gaps between marked objects
                zap := {a \in SAddr : a[2] = ageX /\ heap[a].lid # 0 /\ a \notin amark};
                swept := TRUE;
            end if;
            goto E_Loop;
        elsif Collectors = 1 then                  \* the exact engine: stack, starts, heals, YLOS
            if jstack # <<>> then                  \* pop a copy (LIFO) and take its first child
                with c = jstack[Len(jstack)] do
                    tgt := heap[c].f[1];
                    fix := <<c, 1>>;
                    if NF > 1 then sc := c; si := 2; end if;
                end with;
                jstack := SubSeq(jstack, 1, Len(jstack) - 1);
            elsif ns <= Len(jstarts) then          \* a start (S_m)
                tgt := IF MUTANT = "skip_start" /\ ns = 1 THEN Nil ELSE jstarts[ns];
                ns := ns + 1;
            elsif nh <= Len(jheal) then            \* a heal slot: its value, immutable under P1
                tgt := HealVal(jheal[nh]);
                if MUTANT = "collector_heals" then fix := jheal[nh]; end if;   \* trap 1
                nh := nh + 1;
            elsif ny <= Len(jylos) then            \* scanYlos: a reached YLOS object, read-only
                with y = jylos[ny] do
                    tgt := IF MUTANT = "skip_scan_ylos" THEN Nil ELSE heap[y].f[1];
                    if NF > 1 /\ MUTANT # "skip_scan_ylos" then sc := y; si := 2; scy := TRUE; end if;
                end with;
                ny := ny + 1;
            end if;
        elsif jstack # <<>> \/ ns <= Len(jstarts) \/ nh <= Len(jheal) \/ ny <= Len(jylos) then
            \* L3 (and the pause's claiming help): members take entries from their
            \* deques and steal, so any pending entry may come next (M2's Drain).
            either
                await jstack # <<>>;
                with k \in 1..Len(jstack) do
                    tgt := heap[jstack[k]].f[1];
                    fix := <<jstack[k], 1>>;
                    if NF > 1 then sc := jstack[k]; si := 2; end if;
                    jstack := Remove(jstack, k);
                end with;
            or
                await ns <= Len(jstarts);
                tgt := IF MUTANT = "skip_start" /\ ns = 1 THEN Nil ELSE jstarts[ns];
                ns := ns + 1;
            or
                await nh <= Len(jheal);
                tgt := HealVal(jheal[nh]);
                nh := nh + 1;
            or
                await ny <= Len(jylos);
                with y = jylos[ny] do
                    tgt := heap[y].f[1];
                    if NF > 1 then sc := y; si := 2; scy := TRUE; end if;
                end with;
                ny := ny + 1;
            end either;
        end if;
      E_Load:                                      \* shadow load (relaxed / acquire); reachYlos
        await ~canStop \/ calive;
        if tgt \in HandY(job.x) then               \* a generation YLOS: reached, scanned later
            if tgt \notin jreached /\ MUTANT # "job_skips_ylos" then
                jreached := jreached \cup {tgt};
                jylos := Append(jylos, tgt);
            end if;
            goto E_Fix;
        elsif ~IsS(tgt, job.x) then
            goto E_Fix;                            \* not a tenuring object: nothing to do
        else
            e := shadow[tgt[2]][tgt[3]];
            if e.st = 2 /\ e.g = gen[tgt[2]] then
                res := e.dst; goto E_Fix;          \* already forwarded (this generation)
            elsif e.st = 1 /\ e.g = gen[tgt[2]] then
                goto E_WaitBusy;                   \* L3 only (the exact engine aborts on BUSY)
            elsif Collectors = 1 \/ MUTANT = "l3_no_claim" then
                goto E_Copy;                       \* the exact engine publishes without a claim
            end if;
        end if;
      E_Claim:                                     \* claim: CAS(observed -> BUSY)
        await ~canStop \/ calive;
        if shadow[tgt[2]][tgt[3]] = e then
            shadow[tgt[2]][tgt[3]] := [st |-> 1, dst |-> Nil, g |-> gen[tgt[2]]];
            goto E_Copy;
        else
            goto E_Load;
        end if;
      E_WaitBusy:                                  \* waitPublished
        await (~canStop \/ calive) /\ ~Busy(tgt);
        goto E_Load;
      E_Copy:                                      \* grantAllocate + memcpy (+ age/colour fixup)
        await ~canStop \/ calive;
        await FreeGrant # {};
        with d \in (IF Collectors = 1 THEN {CHOOSE y \in FreeGrant : TRUE} ELSE FreeGrant) do
            heap[d] := heap[tgt];
            res := d;
            cw := cw \cup {d};
            ncopy[tgt] := ncopy[tgt] + 1;
            if cycle = "Marking" /\ MUTANT # "copy_not_black" then black := black \cup {d}; end if;
        end with;
      E_Pub:                                       \* publish: release store of FWD, then push
        await ~canStop \/ calive;
        shadow[tgt[2]][tgt[3]] := [st |-> 2, dst |-> res, g |-> gen[tgt[2]]];
        jstack := Append(jstack, res);
      E_Fix:                                       \* the copy's slot gets the child's copy
        await ~canStop \/ calive;
        if fix # Nil /\ IsS(tgt, job.x) then
            if MUTANT = "copy_slot_in_heal" /\ IsO(fix[1]) then
                jheal := Append(jheal, fix);       \* the slot is left for the merge's heal
            elsif MUTANT # "skip_fix" then
                heap[fix[1]].f[fix[2]] := res;
                cw := cw \cup {fix[1]};
            end if;
        end if;
        tgt := Nil; fix := Nil; e := NoEntry; res := Nil;
        goto E_Loop;
  E_Ret:                                           \* a dead collector takes no step
    await ~canStop \/ calive;
    return;
end procedure;

\* tenureJoin + mergeJob (start of a minor, or of a STW major).
procedure JoinMerge()
begin
  J_Wait:
    if job.st = "Running" /\ MUTANT # "merge_before_join" then
        either
            await running = 0 \/ ~calive;          \* join(), or the orphan path: wait out the collector
        or
            await HelpAllowed /\ running > 0 /\ calive;
            stop := TRUE;                          \* stopAndJoin(): stop ...
          J_Stop:
            await running = 0 \/ ~calive;          \* ... and join
        end either;
      J_Help:
        if ~JobDone then call Engine(FALSE); end if;   \* help (runJobExact / runJobParallel)
    end if;
  J_Merge:                                         \* TV1_Heal, TV1_Ylos, TenuredEqualsLegacy hold here
    if job.st = "Running" then
        \* (4) generation YLOS: promote the reached, resolve their slots into the
        \* extent; (5) heal; (5b) zap the dead ageing objects (fillers).
        heap := [a \in Addr |->
                   IF a \in zap /\ MUTANT # "skip_zap" THEN Empty
                   ELSE [heap[a] EXCEPT !.f = [i \in Fields |->
                       IF /\ IsS(heap[a].f[i], job.x)
                          /\ \/ <<a, i>> \in Range(jheal) /\ ~(MUTANT = "skip_heal" /\ <<a, i>> = jheal[1])
                             \/ a \in jreached /\ a \in HandY(job.x) /\ MUTANT # "skip_ylos_resolve"
                       THEN FwdOf(heap[a].f[i]) ELSE heap[a].f[i]]]];
        root := [r \in Roots |->                   \* only with the mutant root_in_heal
                   IF <<<<"R", r>>, 1>> \in Range(jheal) /\ IsS(root[r], job.x)
                   THEN FwdOf(root[r]) ELSE root[r]];
        yjoin := [c \in 1..YC |-> IF <<"Y", c>> \in jreached /\ ys[c] = Gen(job.x) THEN 0 ELSE yjoin[c]];
        ys := [c \in 1..YC |-> IF \/ <<"Y", c>> \in jreached /\ ys[c] = Gen(job.x)
                                  \/ <<"Y", c>> \in LbPromoted       \* (3) promoteLargeHeader
                               THEN YOld ELSE ys[c]];
        job.st := "Merged";
        grant := {};
    end if;
  J_Ret:
    return;
end procedure;

\* The mutator: Elm code between pauses, the region minor, STW majors.
process Mutator = MutId
variables slots = <<>>, efwd = [a \in EAddr \cup BAddr |-> Nil],
          fill = 0, hand = 0, agex = 0, prev = 0, retire = 0, ftop = 1, fbot = 1,
          cur = Nil, t = Nil, v = Nil;
begin
  M_Epoch:
    while TRUE do
        either                                     \* allocate an eden object from held values
            await CanOp("alloc") /\ ebump <= EC /\ nextLid <= MaxLid;
            with r \in Roots, fv \in [Fields -> {Nil} \cup PlainHeld] do
                lheap[nextLid] := [i \in Fields |-> LidOf(fv[i])];
                heap[<<"E", ebump>>] := [lid |-> nextLid, f |-> fv, b |-> FALSE];
                root[r] := <<"E", ebump>>; lroot[r] := nextLid;
                ebump := ebump + 1; nextLid := nextLid + 1; ops := ops + 1;
            end with;
        or                                         \* a kernel allocates a builder (HEAP_BUILDER_001)
            await CanOp("balloc") /\ ebump <= EC /\ nextLid <= MaxLid
                  /\ Cardinality({a \in Addr : heap[a].lid # 0 /\ heap[a].b}) < BC;   \* a builder area never overflows
            with r \in Roots, fv \in [Fields -> {Nil} \cup PlainHeld] do
                lheap[nextLid] := [i \in Fields |-> LidOf(fv[i])];
                heap[<<"E", ebump>>] := [lid |-> nextLid, f |-> fv, b |-> TRUE];
                root[r] := <<"E", ebump>>; lroot[r] := nextLid;
                ebump := ebump + 1; nextLid := nextLid + 1; ops := ops + 1;
            end with;
        or                                         \* allocateYoungLarge: a YLOS cell (allocate-black mid-cycle)
            await CanOp("yalloc") /\ nextLid <= MaxLid /\ \E c \in 1..YC : ys[c] = YFree;
            with c = CHOOSE c2 \in 1..YC : ys[c2] = YFree, r \in Roots,
                 fv \in [Fields -> {Nil} \cup PlainHeld],
                 \* "lbid": registerLargeBody pops free_large_body_ids_ (LIFO), onto which
                 \* releaseBlockToAllocator pushed the freed member's id (OldGenSpace.cpp)
                 rec \in (IF YlosGen = "lbid" /\ ystale[c] # {} THEN BOOLEAN ELSE {FALSE}) do
                lheap[nextLid] := [i \in Fields |-> LidOf(fv[i])];
                heap[<<"Y", c>>] := [lid |-> nextLid, f |-> fv, b |-> FALSE];
                ys[c] := Y0;
                yrec[c] := rec;
                yjoin[c] := 0;
                if cycle = "Marking" then black := black \cup {<<"Y", c>>}; end if;
                root[r] := <<"Y", c>>; lroot[r] := nextLid;
                nextLid := nextLid + 1; ops := ops + 1;
            end with;
        or                                         \* a large string: allocateLargeBody (a kind-0 index entry,
            \* OldGenSpace.cpp:7415-7441) plus its header in eden, field 1 = the body
            await CanOp("lalloc") /\ ebump <= EC /\ nextLid + 1 <= MaxLid /\ \E c \in 1..YC : ys[c] = YFree;
            with c = CHOOSE c2 \in 1..YC : ys[c2] = YFree, r \in Roots do
                lheap := [lheap EXCEPT ![nextLid] = [i \in Fields |-> IF i = 1 THEN nextLid + 1 ELSE 0],
                                       ![nextLid + 1] = [i \in Fields |-> 0]];
                heap := [heap EXCEPT ![<<"E", ebump>>] = [lid |-> nextLid, b |-> FALSE,
                                                          f |-> [i \in Fields |-> IF i = 1 THEN <<"Y", c>> ELSE Nil]],
                                     ![<<"Y", c>>] = [Empty EXCEPT !.lid = nextLid + 1]];
                ys[c] := YBody;
                bodyLids := bodyLids \cup {nextLid + 1};
                if cycle = "Marking" then black := black \cup {<<"Y", c>>}; end if;
                root[r] := <<"E", ebump>>; lroot[r] := nextLid;
                ebump := ebump + 1; nextLid := nextLid + 2; ops := ops + 1;
            end with;
        or                                         \* load a field into a root (never a body pointer)
            await CanOp("load");
            with r \in Roots, q \in {q2 \in Roots : root[q2] # Nil},
                 i \in {i2 \in Fields : ~IsBodyRef(heap[root[q]].f[i2])} do
                root[r] := heap[root[q]].f[i];
                lroot[r] := IF lroot[q] = 0 THEN 0 ELSE lheap[lroot[q]][i];   \* 0 only in a broken state
                ops := ops + 1;
            end with;
        or                                         \* drop a root
            await CanOp("drop");
            with r \in {r2 \in Roots : root[r2] # Nil} do
                root[r] := Nil; lroot[r] := 0; ops := ops + 1;
            end with;
        or                                         \* a kernel writes a held value into its builder
            await CanOp("bwrite");
            with r \in {r2 \in Roots : IsBld(root[r2])}, i \in Fields, val \in {Nil} \cup PlainHeld do
                heap[root[r]].f[i] := val;
                if lroot[r] # 0 then lheap[lroot[r]][i] := LidOf(val); end if;
                ops := ops + 1;
            end with;
        or                                         \* clear_builder: the object is finished
            await CanOp("bclear");
            with r \in {r2 \in Roots : IsBld(root[r2])} do
                heap[root[r]].b := FALSE; ops := ops + 1;
            end with;
        or
            await minors < MaxMinors;
            goto MN_Join;
        or
            await MajorAllowed /\ majors < MaxMajors;
            goto MJ_Join;
        or                                         \* the run is over: the mutator idles (no deadlock)
            await minors >= MaxMinors;
            skip;
        end either;
    end while;

  \* ---- ThreadLocalHeap::minorGC -> tenureJoin, minorGCRegion, tenureLaunch ----
  MN_Join:
    call JoinMerge();
  MN_Begin:                                        \* beginMinor: roles
    minors := minors + 1;
    fill := CHOOSE x \in X : xstate[x] = "Free";
    hand := IF \E x \in X : xstate[x] = "Young" /\ xage[x] = K
            THEN CHOOSE x \in X : xstate[x] = "Young" /\ xage[x] = K ELSE 0;
    agex := IF \E x \in X : xstate[x] = "Young" /\ xage[x] < K
            THEN CHOOSE x \in X : xstate[x] = "Young" /\ xage[x] < K ELSE 0;
    prev := IF \E x \in X : xstate[x] = "Young" /\ xage[x] = 1       \* PrevBuilders: the last fill
            THEN CHOOSE x \in X : xstate[x] = "Young" /\ xage[x] = 1 ELSE 0;
    retire := IF \E x \in X : xstate[x] = "Tenuring" THEN CHOOSE x \in X : xstate[x] = "Tenuring" ELSE 0;
    \* Hand-over preparation (NurseryRegion.cpp:743-782): the hand-over and ageing
    \* extents' ylos_gen lists become this minor's YLOS snapshots (hand_ylos,
    \* age_ylos), which ys expresses as Gen(hand) / Gen(agex). Address-keyed
    \* (CR-034): an entry ys does not express (ystale) is claimed for its list
    \* when the prep's check passes; hand_ylos is searched first everywhere
    \* (reachYoungLargeR, markTarget), so the hand-over list wins. The occupant's
    \* own list keeps its entry, now one ys does not express.
    with mx = [c \in 1..YC |-> IF PrepMatch(c, hand) THEN hand
                               ELSE IF PrepMatch(c, agex) THEN agex ELSE 0] do
        ystale := [c \in 1..YC |->
                     IF mx[c] = 0 THEN ystale[c]
                     ELSE (ystale[c] \ {mx[c]})
                          \cup (IF ys[c] \in {Gen(x) : x \in X} /\ xstate[ys[c][2]] = "Young"
                                THEN {ys[c][2]} ELSE {})];
        ys := [c \in 1..YC |-> IF mx[c] = 0 THEN ys[c] ELSE Gen(mx[c])];
    end with;
    \* The same preps re-mark the extents' large bodies by address (Hx.lb_bodies,
    \* Ax.lb_bodies: markLargeBodySeen, NurseryRegion.cpp:749, :771), after the
    \* colour flip (:675): whatever index entry sits there now carries this minor's colour.
    ycol := LbColoured(hand) \cup LbColoured(agex);
    slots := SetToSeq({<<"root", r>> : r \in Roots});
  MN_Slot:                                         \* evacuateR, one slot per step
    while slots # <<>> do
        cur := Head(slots);
        t := IF Head(slots)[1] = "root" THEN root[Head(slots)[2]]
             ELSE heap[Head(slots)[2]].f[Head(slots)[3]];
        slots := Tail(slots);
      MN_Classify:                                 \* TV1_Resolve holds here
        if IsE(t) \/ (prev # 0 /\ IsB(t, prev)) then   \* Eden / PrevBuilders: claim, copy (once)
            if efwd[t] = Nil then
                \* a large header's body: lb_seen, and lb_bodies unless a builder (copyClaimedR, NR:421-426)
                with bs = {heap[t].f[i] : i \in Fields} \cap {y \in YAddr : ys[y[2]] = YBody} do
                    ycol := ycol \cup bs;
                    if heap[t].b /\ BC > 0 /\ MUTANT # "builder_in_survivor" then
                        heap[<<"B", fill, fbot>>] := heap[t];      \* the fill's builder area (age 0)
                        efwd[t] := <<"B", fill, fbot>>;
                        slots := slots \o FieldSlots(<<"B", fill, fbot>>, "bld");
                        fbot := fbot + 1;
                    else
                        heap[<<"S", fill, ftop>>] := heap[t];      \* the fill's survivor part (age 1)
                        efwd[t] := <<"S", fill, ftop>>;
                        slots := slots \o FieldSlots(<<"S", fill, ftop>>, "surv");
                        ftop := ftop + 1;
                        lbl := [c \in 1..YC |-> IF <<"Y", c>> \in bs
                                                THEN lbl[c] \cup {<<fill, heap[<<"Y", c>>].lid>>} ELSE lbl[c]];
                    end if;
                end with;
            end if;
          MN_Fwd:
            v := efwd[t];
          MN_Set:
            SetSlot(cur, v);
        elsif hand # 0 /\ IsS(t, hand) then        \* Hand: record, no header load (trap 8)
            if cur[1] = "fld" /\ (cur[4] = "surv" \/ (cur[4] = "yy" /\ MUTANT # "ylos_slot_in_starts")
                                  \/ (cur[4] = "bld" /\ MUTANT = "builder_in_heal")) then
                H := H \cup {<<cur[2], cur[3]>>};  \* a heap slot nobody rescans: the merge heals it
            elsif cur[1] = "root" /\ MUTANT = "root_in_heal" then
                H := H \cup {<<<<"R", cur[2]>>, 1>>};
            elsif ~(cur[1] = "root" /\ MUTANT = "no_root_starts") then
                S := S \cup {t};                   \* roots, builders, hand YLOS: a start
            end if;
        elsif agex # 0 /\ IsS(t, agex) then        \* 07b Age: a mark source, whatever holds it
            SA := SA \cup {t};
        elsif retire # 0 /\ IsS(t, retire) then    \* Retire: resolve through the shadow
            v := FwdOf(t);
          MN_Resolve:
            if MUTANT # "no_resolve" then SetSlot(cur, v); end if;
        elsif IsY(t) then                          \* reachYoungLargeR (never moved)
            if ys[t[2]] = Y0 /\ t \notin ycol then   \* first reach: joins generation m, scanned
                                                   \* (colour already this minor's: "already reached", NR:526)
                ys[t[2]] := Gen(fill);
                yjoin[t[2]] := fill;               \* (ghost) and its address joins fill's ylos_gen
                slots := slots \o FieldSlots(t, "yy");
            elsif hand # 0 /\ ys[t[2]] = Gen(hand) /\ t \notin ypr then   \* a hand-over member: reached
                ypr := ypr \cup {t};
                slots := slots \o FieldSlots(t, "hy");
            elsif agex # 0 /\ ys[t[2]] = Gen(agex) then
                SA := SA \cup {t};                 \* an ageing member: the job's mark scans it
            end if;
        end if;
      MN_Next:
        cur := Nil; t := Nil; v := Nil;
    end while;
  MN_Epilogue:                                     \* retire G_{m-k-1}, clear eden, sweep YLOS, endMinor
    heap := [a \in Addr |->
               IF \/ IsE(a)
                  \/ retire # 0 /\ (IsS(a, retire) \/ IsB(a, retire))
                  \/ prev # 0 /\ IsB(a, prev)       \* the previous builder area: every builder re-copied
                  \/ (IsY(a) /\ cycle # "Marking" /\ a \notin ycol
                      /\ (ys[a[2]] \in {Y0, YBody} \/ (retire # 0 /\ ys[a[2]] = Gen(retire) /\ MUTANT # "keep_unreached_ylos")))
               THEN Empty ELSE heap[a]];
    yjoin := [c \in 1..YC |->
                IF ys[c] = Y0 \/ (retire # 0 /\ ys[c] = Gen(retire) /\ MUTANT # "keep_unreached_ylos")
                THEN 0 ELSE yjoin[c]];
    ystale := [c \in 1..YC |-> {x \in ystale[c] : x # hand /\ x # retire}];   \* lists read only while Young
    lbl := [c \in 1..YC |-> {en \in lbl[c] : en[1] # hand /\ en[1] # retire}];
    ys := [c \in 1..YC |->                         \* sweepNurseryLargeBodies (deferred mid-cycle): colour
             IF <<"Y", c>> \notin ycol                 \* not this minor's
                /\ (ys[c] \in {Y0, YBody} \/ (retire # 0 /\ ys[c] = Gen(retire) /\ MUTANT # "keep_unreached_ylos"))
             THEN (IF cycle = "Marking" THEN YDead ELSE YFree) ELSE ys[c]];
    ycol := {};
    xstate := [x \in X |-> IF x = fill THEN "Young"
                           ELSE IF x = hand THEN "Tenuring"
                           ELSE IF x = retire THEN "Free" ELSE xstate[x]];
    xage := [x \in X |-> IF x = fill THEN 1
                         ELSE IF x = hand \/ x = retire THEN 0
                         ELSE IF xstate[x] = "Young" THEN xage[x] + 1 ELSE xage[x]];
    ebump := 1;
    efwd := [a \in EAddr \cup BAddr |-> Nil];      \* dead after the minor
    ftop := 1; fbot := 1;
  MN_Cycle:                                        \* stepMarkCycle / startMarkCycle (abstract)
    if cycle = "Marking" then
        if cage + 1 >= CycleT then                 \* handoff: free what was dead at t0, and deferred YLOS
            heap := [a \in Addr |-> IF (OldAddr(a) /\ a \notin (OldClose(grey) \cup black))
                                       \/ (IsY(a) /\ ys[a[2]] = YDead)
                                    THEN Empty ELSE heap[a]];
            ys := [c \in 1..YC |-> IF ys[c] = YDead \/ (ys[c] \in {YOld, YBody} /\ <<"Y", c>> \notin (OldClose(grey) \cup black))
                                   THEN YFree ELSE ys[c]];
            cycle := "Idle"; grey := {}; black := {}; cage := 0;
        else
            cage := cage + 1;                      \* noteCycleMinorEnd
        end if;
    elsif CycleAllowed then
        either
            skip;
        or                                         \* t0: roots, the young walk, snapshotYoungLarge
            with G = {root[r] : r \in Roots}
                     \cup {heap[a].f[i] : a \in Walk(MUTANT = "t0_skips_tenuring"), i \in Fields} do
                \* snapshot mode drops young targets (greyObject, OldGenSpace.cpp)
                grey := IF MUTANT = "t0_keeps_young" THEN G \ {Nil}
                        ELSE IF MUTANT = "t0_greys_ylos" THEN {a \in G : OldAddr(a) \/ YoungY(a)}
                        ELSE {a \in G : OldAddr(a)};
            end with;
            black := {y \in YAddr : YoungY(y)};    \* every young YLOS cell is marked, not greyed
            cycle := "Marking";
            cage := 0;
        end either;
    end if;
  MN_Launch:                                       \* tenureLaunch (the scope-exit object)
    if \E x \in X : xstate[x] = "Tenuring" then
        with x = CHOOSE y \in X : xstate[y] = "Tenuring",
             ax = IF \E y \in X : xstate[y] = "Young" /\ xage[y] >= 2
                  THEN CHOOSE y \in X : xstate[y] = "Young" /\ xage[y] >= 2 ELSE 0 do
            if MUTANT = "gen_not_bumped" then
                skip;
            elsif NextGen(gen[x]) = 1 /\ gen[x] # 0 /\ MUTANT # "wrap_no_discard" then
                shadow[x] := [c \in 1..SC |-> NoEntry];   \* shadow.discard on wrap
                gen[x] := 1;
            else
                gen[x] := NextGen(gen[x]);
            end if;
            job := [st |-> "Running", x |-> x];
            liveHand := {a \in ReachAll : IsS(a, x)};   \* legacy promotes exactly these
            liveHandY := ReachAll \cap HandY(x);
            ageX := ax;                            \* 07b: the ageing extent (now age 2), its mark cleared
            liveAge := IF ax = 0 THEN {}
                       ELSE ReachAll \cap ({a \in SAddr : a[2] = ax} \cup {y \in YAddr : ys[y[2]] = Gen(ax)});
            swept := (ax = 0);
        end with;
        jstarts := SetToSeq(S); jheal := SetToSeq(H); jstack := <<>>;
        ns := 1; nh := 1;
        jreached := ypr; jylos := <<>>; ny := 1;
        jSA := SetToSeq(SA); nsa := 1; astack := <<>>; amark := {}; zap := {};
        grant := IF MUTANT = "grant_t0_cells" /\ cycle = "Marking" THEN OAddr   \* TV5's control
                 ELSE {a \in OAddr : heap[a].lid = 0};   \* grantTenure (virgin / partial blocks)
        cw := {};
        ncopy := [a \in SAddr |-> 0];
        stop := FALSE;
        if TenureMode = 2 /\ calive then
            running := Collectors;
            go := [c \in CollIds |-> TRUE];
        end if;
    end if;
    S := {}; H := {}; SA := {}; ypr := {};         \* pend_S / pend_H / pend_SA moved into the job
  MN_Sync:
    if TenureMode = 1 /\ job.st = "Running" /\ ~JobDone then call Engine(FALSE); end if;
  MN_Done:
    goto M_Epoch;

  \* ---- ThreadLocalHeap::majorGC: tenureJoin(why = 1), then the STW mark ----
  MJ_Join:
    call JoinMerge();
  MJ_Cycle:                                        \* finishMarkCycleNow(Join)
    majors := majors + 1;
    if cycle = "Marking" then
        heap := [a \in Addr |-> IF (OldAddr(a) /\ a \notin (OldClose(grey) \cup black))
                                   \/ (IsY(a) /\ ys[a[2]] = YDead)
                                THEN Empty ELSE heap[a]];
        ys := [c \in 1..YC |-> IF ys[c] = YDead \/ (ys[c] \in {YOld, YBody} /\ <<"Y", c>> \notin (OldClose(grey) \cup black))
                               THEN YFree ELSE ys[c]];
        cycle := "Idle"; grey := {}; black := {}; cage := 0;
    end if;
  MJ_Mark:                                         \* STW mark with majorRedirect; TV1_Major holds here
    heap := [a \in Addr |-> IF (IsO(a) \/ IsY(a)) /\ a \notin MajorLive THEN Empty ELSE heap[a]];
    \* CR-034: the major erases a dead member's index entry (releaseBlockToAllocator /
    \* retireDeadLargeBodies) but not its address in the extent's ylos_gen.
    ystale := [c \in 1..YC |->
                 IF AddrKeyed /\ <<"Y", c>> \notin MajorLive /\ ys[c] \in {Gen(x) : x \in X}
                    /\ xstate[ys[c][2]] = "Young"
                 THEN ystale[c] \cup {ys[c][2]} ELSE ystale[c]];
    yjoin := [c \in 1..YC |-> IF <<"Y", c>> \notin MajorLive THEN 0 ELSE yjoin[c]];
    lbl := [c \in 1..YC |-> IF LbKey = "drop" /\ <<"Y", c>> \notin MajorLive THEN {} ELSE lbl[c]];
    ys := [c \in 1..YC |-> IF <<"Y", c>> \notin MajorLive THEN YFree ELSE ys[c]];
    goto M_Epoch;
end process;

\* The tenure collector (GCBackgroundGang "eco-tenure"): one member runs the
\* exact engine; with Collectors > 1 the members share the job (L3).
fair process Collector \in CollIds
begin
  C_Wait:
    await go[self] /\ calive;
    go[self] := FALSE;
  C_Run:
    call Engine(TRUE);
  C_Fin:
    running := running - 1;                        \* ++finished_ under m_; join sees it
    goto C_Wait;
end process;

\* A fork on another thread. Its prepare hook stops the collector at an
\* item boundary (StopAllowed). The mutant `fork_mid_item` instead lets the
\* collector thread vanish between any two engine steps (a child forked
\* while the collector ran: CR-013's window). The model then keeps running
\* the same mutator, i.e. it shows the child as if it had one.
process Env = EnvId
begin
  F_Maybe:
    either
        await StopAllowed;
        stop := TRUE;
    or
        await MUTANT = "fork_mid_item" /\ job.st = "Running";
        calive := FALSE;
    or
        skip;
    end either;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
CONSTANT defaultInitValue
VARIABLES pc, heap, root, lheap, lroot, nextLid, ops, ebump, xstate, xage, 
          gen, shadow, ys, ystale, yrec, yjoin, lbl, ycol, bodyLids, job, 
          jstarts, jheal, jstack, ns, nh, jreached, jylos, ny, ageX, jSA, nsa, 
          astack, amark, swept, zap, grant, stop, running, calive, go, minors, 
          majors, S, H, SA, ypr, cycle, grey, black, cage, liveHand, 
          liveHandY, liveAge, cw, ncopy, stack

(* define statement *)
LidOf(a) == IF a = Nil THEN 0 ELSE heap[a].lid
FwdOf(a) == LET e == shadow[a[2]][a[3]]
            IN IF e.st = 2 /\ e.g = gen[a[2]] THEN e.dst ELSE Nil
Busy(a)  == LET e == shadow[a[2]][a[3]] IN e.st = 1 /\ e.g = gen[a[2]]
XObjs(x) == {a \in SAddr : a[2] = x /\ heap[a].lid # 0}
YoungY(a) == IsY(a) /\ ys[a[2]] \in YoungYS
HandY(x) == {y \in YAddr : ys[y[2]] = Gen(x)}


OldAddr(a) == IsO(a) \/ (IsY(a) /\ ys[a[2]] \notin YoungYS)
OldObj(a) == heap[a].lid # 0 /\ (IsO(a) \/ (IsY(a) /\ ys[a[2]] = YOld))
OldTarget(v) == v = Nil \/ IsO(v) \/ (IsY(v) /\ ys[v[2]] = YOld)


Allocated(a) == /\ heap[a].lid # 0
                /\ a[1] \in {"S", "B"} => xstate[a[2]] # "Free"
                /\ a[1] = "B" => (xstate[a[2]] = "Young" /\ xage[a[2]] = 1)
                /\ IsY(a) => ys[a[2]] \notin {YFree, YDead}
IsBld(a) == a # Nil /\ heap[a].b
PlainHeld == {root[q] : q \in {q2 \in Roots : ~IsBld(root[q2])}}
HealVal(s) == IF s[1][1] = "R" THEN root[s[1][2]] ELSE heap[s[1]].f[s[2]]
AgeCells == IF ageX = 0 THEN {}
            ELSE {a \in SAddr : a[2] = ageX} \cup {y \in YAddr : ys[y[2]] = Gen(ageX)}
Close(G) == CloseIn(G, heap)
ReachAll == Close({root[r] : r \in Roots}) \ {Nil}



Walk(skipTenuring) ==
    {a \in SAddr : heap[a].lid # 0 /\ (xstate[a[2]] = "Young"
                                       \/ (xstate[a[2]] = "Tenuring" /\ ~skipTenuring))
                   /\ (Cr017Oracle => a \in ReachAll)}
    \cup {a \in BAddr : heap[a].lid # 0 /\ xstate[a[2]] = "Young" /\ xage[a[2]] = 1
                        /\ (Cr017Oracle => a \in ReachAll)}
    \cup {y \in YAddr : YoungY(y)}





AddrKeyed == YlosGen \notin {"identity", "drop"}
PrepOK(c) == CASE YlosGen = "age1"  -> ys[c] # Y0
               [] YlosGen = "stamp" -> FALSE
               [] YlosGen = "lbid"  -> yrec[c]
               [] OTHER             -> TRUE
PrepMatch(c, x) == x # 0 /\ x \in ystale[c] /\ ys[c] \in YoungYS /\ PrepOK(c)


IsBodyRef(v) == v # Nil /\ IsY(v) /\ heap[v].lid \in bodyLids
LbMatch(c, en) == /\ ys[c] \in YoungYS \cup {YBody}
                  /\ CASE LbKey = "kind"     -> ys[c] = YBody
                       [] LbKey = "identity" -> heap[<<"Y", c>>].lid = en[2]
                       [] OTHER              -> TRUE
LbColoured(x) == {<<"Y", c>> : c \in {c2 \in 1..YC : \E en \in lbl[c2] : en[1] = x /\ LbMatch(c2, en)}}

LbPromoted == {v \in YAddr : ys[v[2]] = YBody /\ \E a \in cw \cap OAddr, i \in Fields : heap[a].f[i] = v}
OldClose(G) == Close(G) \ {Nil}

Redir(a) == IF a # Nil /\ job.st = "Merged" /\ IsS(a, job.x) /\ xstate[job.x] = "Tenuring"
               /\ MUTANT # "major_greys_original"
            THEN FwdOf(a) ELSE a
RECURSIVE CloseR(_)
CloseR(G) ==
    LET N == G \cup {Redir(heap[a].f[i]) : a \in G \ {Nil}, i \in Fields}
    IN IF N = G THEN G ELSE CloseR(N)
MajorLive == CloseR({Redir(root[r]) : r \in Roots})
MarkDone == astack = <<>> /\ nsa > Len(jSA) /\ swept
JobDone == MarkDone /\ jstack = <<>> /\ ns > Len(jstarts) /\ nh > Len(jheal) /\ ny > Len(jylos)
InEpoch == pc[MutId] = "M_Epoch"
FreeGrant == {a \in grant : heap[a].lid = 0}
CanOp(kd) == kd \in Ops /\ ops < MaxTotalOps
AtMerge == pc[MutId] = "J_Merge" /\ job.st = "Running"

NoDangling ==
    InEpoch => \A a \in ReachAll : Allocated(a)
GraphPreserved ==
    InEpoch =>
        /\ \A r \in Roots : LidOf(root[r]) = lroot[r]
        /\ \A a \in ReachAll : heap[a].lid # 0 =>
               \A i \in Fields : LidOf(heap[a].f[i]) = lheap[heap[a].lid][i]
CollectorPrivate ==
    ((running > 0 /\ calive) \/ job.st = "Running") => cw \cap ReachAll = {}
ExactlyOnce == \A a \in SAddr : ncopy[a] <= 1
OldPointsOld ==
    \A a \in OAddr \cup YAddr : (OldObj(a) /\ ~(job.st = "Running" /\ a \in grant)) =>
        \A i \in Fields : OldTarget(heap[a].f[i])
HealYoungOnly ==
    job.st = "Running" =>
        \A s \in Range(jheal) :
            \/ s[1][1] = "S" /\ xstate[s[1][2]] = "Young"
            \/ s[1][1] = "Y" /\ \E x \in X : xstate[x] = "Young" /\ ys[s[1][2]] = Gen(x)
MarkerDisjoint ==
    cycle = "Marking" =>
        /\ \A a \in OldClose(grey) : OldAddr(a) /\ a \notin grant /\ a \notin black
        /\ (job.st = "Running" => cw \cap OAddr \subseteq black)
YoungWalkValid ==
    (pc[MutId] = "MN_Cycle" /\ CycleAllowed /\ cycle = "Idle") =>
        \A a \in Walk(FALSE) : \A i \in Fields :
            heap[a].f[i] # Nil => Allocated(heap[a].f[i])
T0GreyAllocated ==
    (pc[MutId] = "MN_Cycle" /\ CycleAllowed /\ cycle = "Idle") =>
        \A a \in Walk(FALSE) : \A i \in Fields :
            (heap[a].f[i] # Nil /\ OldAddr(heap[a].f[i])) => Allocated(heap[a].f[i])
TenuredEqualsLegacy ==
    AtMerge =>
        /\ {a \in XObjs(job.x) : FwdOf(a) # Nil} = liveHand
        /\ jreached \cap HandY(job.x) = liveHandY
        /\ amark = liveAge
TV1_Heal ==
    AtMerge =>
        \A s \in Range(jheal) : IsS(HealVal(s), job.x) => FwdOf(HealVal(s)) # Nil
TV1_Ylos ==
    AtMerge =>
        \A y \in jreached \cap HandY(job.x) : \A i \in Fields :
            IsS(heap[y].f[i], job.x) => FwdOf(heap[y].f[i]) # Nil
TV1_Major ==
    pc[MutId] = "MJ_Mark" =>
        \A q \in {root[r] : r \in Roots} \cup {heap[a].f[i] : a \in MajorLive \ {Nil}, i \in Fields} :
            (q # Nil /\ job.st = "Merged" /\ IsS(q, job.x) /\ xstate[job.x] = "Tenuring")
                => FwdOf(q) # Nil
BuilderYoung ==
    \A a \in Addr : (heap[a].lid # 0 /\ heap[a].b) => (IsE(a) \/ a[1] = "B")
YlosFreed ==
    InEpoch => \A c \in 1..YC : ys[c] \in {Gen(x) : x \in X} => xstate[ys[c][2]] # "Free"
YlosGenIdentity ==
    \A c \in 1..YC :
        ys[c] \in {Gen(x) : x \in X} => yjoin[c] = ys[c][2]

VARIABLES canStop, tgt, fix, e, res, sc, si, scy, slots, efwd, fill, hand, 
          agex, prev, retire, ftop, fbot, cur, t, v

vars == << pc, heap, root, lheap, lroot, nextLid, ops, ebump, xstate, xage, 
           gen, shadow, ys, ystale, yrec, yjoin, lbl, ycol, bodyLids, job, 
           jstarts, jheal, jstack, ns, nh, jreached, jylos, ny, ageX, jSA, 
           nsa, astack, amark, swept, zap, grant, stop, running, calive, go, 
           minors, majors, S, H, SA, ypr, cycle, grey, black, cage, liveHand, 
           liveHandY, liveAge, cw, ncopy, stack, canStop, tgt, fix, e, res, 
           sc, si, scy, slots, efwd, fill, hand, agex, prev, retire, ftop, 
           fbot, cur, t, v >>

ProcSet == {MutId} \cup (CollIds) \cup {EnvId}

Init == (* Global variables *)
        /\ heap = [a \in Addr |-> IF OldSeed = 1 /\ a = Seed
                                  THEN [Empty EXCEPT !.lid = 1] ELSE Empty]
        /\ root = [r \in Roots |-> IF OldSeed = 1 /\ r = R0 THEN Seed ELSE Nil]
        /\ lheap = [l \in 1..MaxLid |-> [i \in Fields |-> 0]]
        /\ lroot = [r \in Roots |-> IF OldSeed = 1 /\ r = R0 THEN 1 ELSE 0]
        /\ nextLid = 1 + OldSeed
        /\ ops = 0
        /\ ebump = 1
        /\ xstate = [x \in X |-> "Free"]
        /\ xage = [x \in X |-> 0]
        /\ gen = [x \in X |-> 0]
        /\ shadow = [x \in X |-> [c \in 1..SC |-> NoEntry]]
        /\ ys = [c \in 1..YC |-> YFree]
        /\ ystale = [c \in 1..YC |-> {}]
        /\ yrec = [c \in 1..YC |-> FALSE]
        /\ yjoin = [c \in 1..YC |-> 0]
        /\ lbl = [c \in 1..YC |-> {}]
        /\ ycol = {}
        /\ bodyLids = {}
        /\ job = [st |-> "None", x |-> 0]
        /\ jstarts = <<>>
        /\ jheal = <<>>
        /\ jstack = <<>>
        /\ ns = 1
        /\ nh = 1
        /\ jreached = {}
        /\ jylos = <<>>
        /\ ny = 1
        /\ ageX = 0
        /\ jSA = <<>>
        /\ nsa = 1
        /\ astack = <<>>
        /\ amark = {}
        /\ swept = TRUE
        /\ zap = {}
        /\ grant = {}
        /\ stop = FALSE
        /\ running = 0
        /\ calive = TRUE
        /\ go = [c \in CollIds |-> FALSE]
        /\ minors = 0
        /\ majors = 0
        /\ S = {}
        /\ H = {}
        /\ SA = {}
        /\ ypr = {}
        /\ cycle = "Idle"
        /\ grey = {}
        /\ black = {}
        /\ cage = 0
        /\ liveHand = {}
        /\ liveHandY = {}
        /\ liveAge = {}
        /\ cw = {}
        /\ ncopy = [a \in SAddr |-> 0]
        (* Procedure Engine *)
        /\ canStop = [ self \in ProcSet |-> defaultInitValue]
        /\ tgt = [ self \in ProcSet |-> Nil]
        /\ fix = [ self \in ProcSet |-> Nil]
        /\ e = [ self \in ProcSet |-> NoEntry]
        /\ res = [ self \in ProcSet |-> Nil]
        /\ sc = [ self \in ProcSet |-> Nil]
        /\ si = [ self \in ProcSet |-> 1]
        /\ scy = [ self \in ProcSet |-> FALSE]
        (* Process Mutator *)
        /\ slots = <<>>
        /\ efwd = [a \in EAddr \cup BAddr |-> Nil]
        /\ fill = 0
        /\ hand = 0
        /\ agex = 0
        /\ prev = 0
        /\ retire = 0
        /\ ftop = 1
        /\ fbot = 1
        /\ cur = Nil
        /\ t = Nil
        /\ v = Nil
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self = MutId -> "M_Epoch"
                                        [] self \in CollIds -> "C_Wait"
                                        [] self = EnvId -> "F_Maybe"]

E_Loop(self) == /\ pc[self] = "E_Loop"
                /\ ~canStop[self] \/ calive
                /\ IF canStop[self] /\ stop /\ sc[self] = Nil
                      THEN /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                           /\ tgt' = [tgt EXCEPT ![self] = Head(stack[self]).tgt]
                           /\ fix' = [fix EXCEPT ![self] = Head(stack[self]).fix]
                           /\ e' = [e EXCEPT ![self] = Head(stack[self]).e]
                           /\ res' = [res EXCEPT ![self] = Head(stack[self]).res]
                           /\ sc' = [sc EXCEPT ![self] = Head(stack[self]).sc]
                           /\ si' = [si EXCEPT ![self] = Head(stack[self]).si]
                           /\ scy' = [scy EXCEPT ![self] = Head(stack[self]).scy]
                           /\ canStop' = [canStop EXCEPT ![self] = Head(stack[self]).canStop]
                           /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                      ELSE /\ IF JobDone /\ sc[self] = Nil
                                 THEN /\ pc' = [pc EXCEPT ![self] = "E_Ret"]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "E_Item"]
                           /\ UNCHANGED << stack, canStop, tgt, fix, e, res, 
                                           sc, si, scy >>
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, jreached, jylos, ny, 
                                ageX, jSA, nsa, astack, amark, swept, zap, 
                                grant, stop, running, calive, go, minors, 
                                majors, S, H, SA, ypr, cycle, grey, black, 
                                cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                                slots, efwd, fill, hand, agex, prev, retire, 
                                ftop, fbot, cur, t, v >>

E_Item(self) == /\ pc[self] = "E_Item"
                /\ ~canStop[self] \/ calive
                /\ IF sc[self] # Nil
                      THEN /\ tgt' = [tgt EXCEPT ![self] = heap[sc[self]].f[si[self]]]
                           /\ fix' = [fix EXCEPT ![self] = IF scy[self] THEN Nil ELSE <<sc[self], si[self]>>]
                           /\ IF si[self] < NF
                                 THEN /\ si' = [si EXCEPT ![self] = si[self] + 1]
                                      /\ UNCHANGED << sc, scy >>
                                 ELSE /\ sc' = [sc EXCEPT ![self] = Nil]
                                      /\ si' = [si EXCEPT ![self] = 1]
                                      /\ scy' = [scy EXCEPT ![self] = FALSE]
                           /\ pc' = [pc EXCEPT ![self] = "E_Load"]
                           /\ UNCHANGED << jheal, jstack, ns, nh, jreached, 
                                           jylos, ny, nsa, astack, amark, 
                                           swept, zap >>
                      ELSE /\ IF ~MarkDone
                                 THEN /\ IF astack # <<>>
                                            THEN /\ LET o == astack[Len(astack)] IN
                                                      LET kids == {heap[o].f[i] : i \in Fields} IN
                                                        LET newM == {t2 \in kids : t2 \in AgeCells /\ t2 \notin amark} IN
                                                          LET hy == {t2 \in kids : t2 \in HandY(job.x) /\ t2 \notin jreached} IN
                                                            /\ amark' = (amark \cup newM)
                                                            /\ astack' = SubSeq(astack, 1, Len(astack) - 1) \o SetToSeq(newM)
                                                            /\ IF MUTANT # "age_mark_no_heal"
                                                                  THEN /\ jheal' = jheal \o SetToSeq({<<o, i>> : i \in {i2 \in Fields : IsS(heap[o].f[i2], job.x)}})
                                                                  ELSE /\ TRUE
                                                                       /\ jheal' = jheal
                                                            /\ jreached' = (jreached \cup hy)
                                                            /\ jylos' = jylos \o SetToSeq(hy)
                                                 /\ UNCHANGED << nsa, swept, 
                                                                 zap >>
                                            ELSE /\ IF nsa <= Len(jSA)
                                                       THEN /\ IF jSA[nsa] \notin amark
                                                                  THEN /\ amark' = (amark \cup {jSA[nsa]})
                                                                       /\ astack' = Append(astack, jSA[nsa])
                                                                  ELSE /\ TRUE
                                                                       /\ UNCHANGED << astack, 
                                                                                       amark >>
                                                            /\ nsa' = nsa + 1
                                                            /\ UNCHANGED << swept, 
                                                                            zap >>
                                                       ELSE /\ zap' = {a \in SAddr : a[2] = ageX /\ heap[a].lid # 0 /\ a \notin amark}
                                                            /\ swept' = TRUE
                                                            /\ UNCHANGED << nsa, 
                                                                            astack, 
                                                                            amark >>
                                                 /\ UNCHANGED << jheal, 
                                                                 jreached, 
                                                                 jylos >>
                                      /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
                                      /\ UNCHANGED << jstack, ns, nh, ny, tgt, 
                                                      fix, sc, si, scy >>
                                 ELSE /\ IF Collectors = 1
                                            THEN /\ IF jstack # <<>>
                                                       THEN /\ LET c == jstack[Len(jstack)] IN
                                                                 /\ tgt' = [tgt EXCEPT ![self] = heap[c].f[1]]
                                                                 /\ fix' = [fix EXCEPT ![self] = <<c, 1>>]
                                                                 /\ IF NF > 1
                                                                       THEN /\ sc' = [sc EXCEPT ![self] = c]
                                                                            /\ si' = [si EXCEPT ![self] = 2]
                                                                       ELSE /\ TRUE
                                                                            /\ UNCHANGED << sc, 
                                                                                            si >>
                                                            /\ jstack' = SubSeq(jstack, 1, Len(jstack) - 1)
                                                            /\ UNCHANGED << ns, 
                                                                            nh, 
                                                                            ny, 
                                                                            scy >>
                                                       ELSE /\ IF ns <= Len(jstarts)
                                                                  THEN /\ tgt' = [tgt EXCEPT ![self] = IF MUTANT = "skip_start" /\ ns = 1 THEN Nil ELSE jstarts[ns]]
                                                                       /\ ns' = ns + 1
                                                                       /\ UNCHANGED << nh, 
                                                                                       ny, 
                                                                                       fix, 
                                                                                       sc, 
                                                                                       si, 
                                                                                       scy >>
                                                                  ELSE /\ IF nh <= Len(jheal)
                                                                             THEN /\ tgt' = [tgt EXCEPT ![self] = HealVal(jheal[nh])]
                                                                                  /\ IF MUTANT = "collector_heals"
                                                                                        THEN /\ fix' = [fix EXCEPT ![self] = jheal[nh]]
                                                                                        ELSE /\ TRUE
                                                                                             /\ fix' = fix
                                                                                  /\ nh' = nh + 1
                                                                                  /\ UNCHANGED << ny, 
                                                                                                  sc, 
                                                                                                  si, 
                                                                                                  scy >>
                                                                             ELSE /\ IF ny <= Len(jylos)
                                                                                        THEN /\ LET y == jylos[ny] IN
                                                                                                  /\ tgt' = [tgt EXCEPT ![self] = IF MUTANT = "skip_scan_ylos" THEN Nil ELSE heap[y].f[1]]
                                                                                                  /\ IF NF > 1 /\ MUTANT # "skip_scan_ylos"
                                                                                                        THEN /\ sc' = [sc EXCEPT ![self] = y]
                                                                                                             /\ si' = [si EXCEPT ![self] = 2]
                                                                                                             /\ scy' = [scy EXCEPT ![self] = TRUE]
                                                                                                        ELSE /\ TRUE
                                                                                                             /\ UNCHANGED << sc, 
                                                                                                                             si, 
                                                                                                                             scy >>
                                                                                             /\ ny' = ny + 1
                                                                                        ELSE /\ TRUE
                                                                                             /\ UNCHANGED << ny, 
                                                                                                             tgt, 
                                                                                                             sc, 
                                                                                                             si, 
                                                                                                             scy >>
                                                                                  /\ UNCHANGED << nh, 
                                                                                                  fix >>
                                                                       /\ ns' = ns
                                                            /\ UNCHANGED jstack
                                            ELSE /\ IF jstack # <<>> \/ ns <= Len(jstarts) \/ nh <= Len(jheal) \/ ny <= Len(jylos)
                                                       THEN /\ \/ /\ jstack # <<>>
                                                                  /\ \E k \in 1..Len(jstack):
                                                                       /\ tgt' = [tgt EXCEPT ![self] = heap[jstack[k]].f[1]]
                                                                       /\ fix' = [fix EXCEPT ![self] = <<jstack[k], 1>>]
                                                                       /\ IF NF > 1
                                                                             THEN /\ sc' = [sc EXCEPT ![self] = jstack[k]]
                                                                                  /\ si' = [si EXCEPT ![self] = 2]
                                                                             ELSE /\ TRUE
                                                                                  /\ UNCHANGED << sc, 
                                                                                                  si >>
                                                                       /\ jstack' = Remove(jstack, k)
                                                                  /\ UNCHANGED <<ns, nh, ny, scy>>
                                                               \/ /\ ns <= Len(jstarts)
                                                                  /\ tgt' = [tgt EXCEPT ![self] = IF MUTANT = "skip_start" /\ ns = 1 THEN Nil ELSE jstarts[ns]]
                                                                  /\ ns' = ns + 1
                                                                  /\ UNCHANGED <<jstack, nh, ny, fix, sc, si, scy>>
                                                               \/ /\ nh <= Len(jheal)
                                                                  /\ tgt' = [tgt EXCEPT ![self] = HealVal(jheal[nh])]
                                                                  /\ nh' = nh + 1
                                                                  /\ UNCHANGED <<jstack, ns, ny, fix, sc, si, scy>>
                                                               \/ /\ ny <= Len(jylos)
                                                                  /\ LET y == jylos[ny] IN
                                                                       /\ tgt' = [tgt EXCEPT ![self] = heap[y].f[1]]
                                                                       /\ IF NF > 1
                                                                             THEN /\ sc' = [sc EXCEPT ![self] = y]
                                                                                  /\ si' = [si EXCEPT ![self] = 2]
                                                                                  /\ scy' = [scy EXCEPT ![self] = TRUE]
                                                                             ELSE /\ TRUE
                                                                                  /\ UNCHANGED << sc, 
                                                                                                  si, 
                                                                                                  scy >>
                                                                  /\ ny' = ny + 1
                                                                  /\ UNCHANGED <<jstack, ns, nh, fix>>
                                                       ELSE /\ TRUE
                                                            /\ UNCHANGED << jstack, 
                                                                            ns, 
                                                                            nh, 
                                                                            ny, 
                                                                            tgt, 
                                                                            fix, 
                                                                            sc, 
                                                                            si, 
                                                                            scy >>
                                      /\ pc' = [pc EXCEPT ![self] = "E_Load"]
                                      /\ UNCHANGED << jheal, jreached, jylos, 
                                                      nsa, astack, amark, 
                                                      swept, zap >>
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, ageX, 
                                jSA, grant, stop, running, calive, go, minors, 
                                majors, S, H, SA, ypr, cycle, grey, black, 
                                cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                                stack, canStop, e, res, slots, efwd, fill, 
                                hand, agex, prev, retire, ftop, fbot, cur, t, 
                                v >>

E_Load(self) == /\ pc[self] = "E_Load"
                /\ ~canStop[self] \/ calive
                /\ IF tgt[self] \in HandY(job.x)
                      THEN /\ IF tgt[self] \notin jreached /\ MUTANT # "job_skips_ylos"
                                 THEN /\ jreached' = (jreached \cup {tgt[self]})
                                      /\ jylos' = Append(jylos, tgt[self])
                                 ELSE /\ TRUE
                                      /\ UNCHANGED << jreached, jylos >>
                           /\ pc' = [pc EXCEPT ![self] = "E_Fix"]
                           /\ UNCHANGED << e, res >>
                      ELSE /\ IF ~IsS(tgt[self], job.x)
                                 THEN /\ pc' = [pc EXCEPT ![self] = "E_Fix"]
                                      /\ UNCHANGED << e, res >>
                                 ELSE /\ e' = [e EXCEPT ![self] = shadow[tgt[self][2]][tgt[self][3]]]
                                      /\ IF e'[self].st = 2 /\ e'[self].g = gen[tgt[self][2]]
                                            THEN /\ res' = [res EXCEPT ![self] = e'[self].dst]
                                                 /\ pc' = [pc EXCEPT ![self] = "E_Fix"]
                                            ELSE /\ IF e'[self].st = 1 /\ e'[self].g = gen[tgt[self][2]]
                                                       THEN /\ pc' = [pc EXCEPT ![self] = "E_WaitBusy"]
                                                       ELSE /\ IF Collectors = 1 \/ MUTANT = "l3_no_claim"
                                                                  THEN /\ pc' = [pc EXCEPT ![self] = "E_Copy"]
                                                                  ELSE /\ pc' = [pc EXCEPT ![self] = "E_Claim"]
                                                 /\ res' = res
                           /\ UNCHANGED << jreached, jylos >>
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, ny, ageX, jSA, nsa, 
                                astack, amark, swept, zap, grant, stop, 
                                running, calive, go, minors, majors, S, H, SA, 
                                ypr, cycle, grey, black, cage, liveHand, 
                                liveHandY, liveAge, cw, ncopy, stack, canStop, 
                                tgt, fix, sc, si, scy, slots, efwd, fill, hand, 
                                agex, prev, retire, ftop, fbot, cur, t, v >>

E_Claim(self) == /\ pc[self] = "E_Claim"
                 /\ ~canStop[self] \/ calive
                 /\ IF shadow[tgt[self][2]][tgt[self][3]] = e[self]
                       THEN /\ shadow' = [shadow EXCEPT ![tgt[self][2]][tgt[self][3]] = [st |-> 1, dst |-> Nil, g |-> gen[tgt[self][2]]]]
                            /\ pc' = [pc EXCEPT ![self] = "E_Copy"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "E_Load"]
                            /\ UNCHANGED shadow
                 /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                 xstate, xage, gen, ys, ystale, yrec, yjoin, 
                                 lbl, ycol, bodyLids, job, jstarts, jheal, 
                                 jstack, ns, nh, jreached, jylos, ny, ageX, 
                                 jSA, nsa, astack, amark, swept, zap, grant, 
                                 stop, running, calive, go, minors, majors, S, 
                                 H, SA, ypr, cycle, grey, black, cage, 
                                 liveHand, liveHandY, liveAge, cw, ncopy, 
                                 stack, canStop, tgt, fix, e, res, sc, si, scy, 
                                 slots, efwd, fill, hand, agex, prev, retire, 
                                 ftop, fbot, cur, t, v >>

E_WaitBusy(self) == /\ pc[self] = "E_WaitBusy"
                    /\ (~canStop[self] \/ calive) /\ ~Busy(tgt[self])
                    /\ pc' = [pc EXCEPT ![self] = "E_Load"]
                    /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, 
                                    ebump, xstate, xage, gen, shadow, ys, 
                                    ystale, yrec, yjoin, lbl, ycol, bodyLids, 
                                    job, jstarts, jheal, jstack, ns, nh, 
                                    jreached, jylos, ny, ageX, jSA, nsa, 
                                    astack, amark, swept, zap, grant, stop, 
                                    running, calive, go, minors, majors, S, H, 
                                    SA, ypr, cycle, grey, black, cage, 
                                    liveHand, liveHandY, liveAge, cw, ncopy, 
                                    stack, canStop, tgt, fix, e, res, sc, si, 
                                    scy, slots, efwd, fill, hand, agex, prev, 
                                    retire, ftop, fbot, cur, t, v >>

E_Copy(self) == /\ pc[self] = "E_Copy"
                /\ ~canStop[self] \/ calive
                /\ FreeGrant # {}
                /\ \E d \in (IF Collectors = 1 THEN {CHOOSE y \in FreeGrant : TRUE} ELSE FreeGrant):
                     /\ heap' = [heap EXCEPT ![d] = heap[tgt[self]]]
                     /\ res' = [res EXCEPT ![self] = d]
                     /\ cw' = (cw \cup {d})
                     /\ ncopy' = [ncopy EXCEPT ![tgt[self]] = ncopy[tgt[self]] + 1]
                     /\ IF cycle = "Marking" /\ MUTANT # "copy_not_black"
                           THEN /\ black' = (black \cup {d})
                           ELSE /\ TRUE
                                /\ black' = black
                /\ pc' = [pc EXCEPT ![self] = "E_Pub"]
                /\ UNCHANGED << root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, jreached, jylos, ny, 
                                ageX, jSA, nsa, astack, amark, swept, zap, 
                                grant, stop, running, calive, go, minors, 
                                majors, S, H, SA, ypr, cycle, grey, cage, 
                                liveHand, liveHandY, liveAge, stack, canStop, 
                                tgt, fix, e, sc, si, scy, slots, efwd, fill, 
                                hand, agex, prev, retire, ftop, fbot, cur, t, 
                                v >>

E_Pub(self) == /\ pc[self] = "E_Pub"
               /\ ~canStop[self] \/ calive
               /\ shadow' = [shadow EXCEPT ![tgt[self][2]][tgt[self][3]] = [st |-> 2, dst |-> res[self], g |-> gen[tgt[self][2]]]]
               /\ jstack' = Append(jstack, res[self])
               /\ pc' = [pc EXCEPT ![self] = "E_Fix"]
               /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                               xstate, xage, gen, ys, ystale, yrec, yjoin, lbl, 
                               ycol, bodyLids, job, jstarts, jheal, ns, nh, 
                               jreached, jylos, ny, ageX, jSA, nsa, astack, 
                               amark, swept, zap, grant, stop, running, calive, 
                               go, minors, majors, S, H, SA, ypr, cycle, grey, 
                               black, cage, liveHand, liveHandY, liveAge, cw, 
                               ncopy, stack, canStop, tgt, fix, e, res, sc, si, 
                               scy, slots, efwd, fill, hand, agex, prev, 
                               retire, ftop, fbot, cur, t, v >>

E_Fix(self) == /\ pc[self] = "E_Fix"
               /\ ~canStop[self] \/ calive
               /\ IF fix[self] # Nil /\ IsS(tgt[self], job.x)
                     THEN /\ IF MUTANT = "copy_slot_in_heal" /\ IsO(fix[self][1])
                                THEN /\ jheal' = Append(jheal, fix[self])
                                     /\ UNCHANGED << heap, cw >>
                                ELSE /\ IF MUTANT # "skip_fix"
                                           THEN /\ heap' = [heap EXCEPT ![fix[self][1]].f[fix[self][2]] = res[self]]
                                                /\ cw' = (cw \cup {fix[self][1]})
                                           ELSE /\ TRUE
                                                /\ UNCHANGED << heap, cw >>
                                     /\ jheal' = jheal
                     ELSE /\ TRUE
                          /\ UNCHANGED << heap, jheal, cw >>
               /\ tgt' = [tgt EXCEPT ![self] = Nil]
               /\ fix' = [fix EXCEPT ![self] = Nil]
               /\ e' = [e EXCEPT ![self] = NoEntry]
               /\ res' = [res EXCEPT ![self] = Nil]
               /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
               /\ UNCHANGED << root, lheap, lroot, nextLid, ops, ebump, xstate, 
                               xage, gen, shadow, ys, ystale, yrec, yjoin, lbl, 
                               ycol, bodyLids, job, jstarts, jstack, ns, nh, 
                               jreached, jylos, ny, ageX, jSA, nsa, astack, 
                               amark, swept, zap, grant, stop, running, calive, 
                               go, minors, majors, S, H, SA, ypr, cycle, grey, 
                               black, cage, liveHand, liveHandY, liveAge, 
                               ncopy, stack, canStop, sc, si, scy, slots, efwd, 
                               fill, hand, agex, prev, retire, ftop, fbot, cur, 
                               t, v >>

E_Ret(self) == /\ pc[self] = "E_Ret"
               /\ ~canStop[self] \/ calive
               /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
               /\ tgt' = [tgt EXCEPT ![self] = Head(stack[self]).tgt]
               /\ fix' = [fix EXCEPT ![self] = Head(stack[self]).fix]
               /\ e' = [e EXCEPT ![self] = Head(stack[self]).e]
               /\ res' = [res EXCEPT ![self] = Head(stack[self]).res]
               /\ sc' = [sc EXCEPT ![self] = Head(stack[self]).sc]
               /\ si' = [si EXCEPT ![self] = Head(stack[self]).si]
               /\ scy' = [scy EXCEPT ![self] = Head(stack[self]).scy]
               /\ canStop' = [canStop EXCEPT ![self] = Head(stack[self]).canStop]
               /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
               /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                               xstate, xage, gen, shadow, ys, ystale, yrec, 
                               yjoin, lbl, ycol, bodyLids, job, jstarts, jheal, 
                               jstack, ns, nh, jreached, jylos, ny, ageX, jSA, 
                               nsa, astack, amark, swept, zap, grant, stop, 
                               running, calive, go, minors, majors, S, H, SA, 
                               ypr, cycle, grey, black, cage, liveHand, 
                               liveHandY, liveAge, cw, ncopy, slots, efwd, 
                               fill, hand, agex, prev, retire, ftop, fbot, cur, 
                               t, v >>

Engine(self) == E_Loop(self) \/ E_Item(self) \/ E_Load(self)
                   \/ E_Claim(self) \/ E_WaitBusy(self) \/ E_Copy(self)
                   \/ E_Pub(self) \/ E_Fix(self) \/ E_Ret(self)

J_Wait(self) == /\ pc[self] = "J_Wait"
                /\ IF job.st = "Running" /\ MUTANT # "merge_before_join"
                      THEN /\ \/ /\ running = 0 \/ ~calive
                                 /\ pc' = [pc EXCEPT ![self] = "J_Help"]
                                 /\ stop' = stop
                              \/ /\ HelpAllowed /\ running > 0 /\ calive
                                 /\ stop' = TRUE
                                 /\ pc' = [pc EXCEPT ![self] = "J_Stop"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "J_Merge"]
                           /\ stop' = stop
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, jreached, jylos, ny, 
                                ageX, jSA, nsa, astack, amark, swept, zap, 
                                grant, running, calive, go, minors, majors, S, 
                                H, SA, ypr, cycle, grey, black, cage, liveHand, 
                                liveHandY, liveAge, cw, ncopy, stack, canStop, 
                                tgt, fix, e, res, sc, si, scy, slots, efwd, 
                                fill, hand, agex, prev, retire, ftop, fbot, 
                                cur, t, v >>

J_Help(self) == /\ pc[self] = "J_Help"
                /\ IF ~JobDone
                      THEN /\ /\ canStop' = [canStop EXCEPT ![self] = FALSE]
                              /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Engine",
                                                                       pc        |->  "J_Merge",
                                                                       tgt       |->  tgt[self],
                                                                       fix       |->  fix[self],
                                                                       e         |->  e[self],
                                                                       res       |->  res[self],
                                                                       sc        |->  sc[self],
                                                                       si        |->  si[self],
                                                                       scy       |->  scy[self],
                                                                       canStop   |->  canStop[self] ] >>
                                                                   \o stack[self]]
                           /\ tgt' = [tgt EXCEPT ![self] = Nil]
                           /\ fix' = [fix EXCEPT ![self] = Nil]
                           /\ e' = [e EXCEPT ![self] = NoEntry]
                           /\ res' = [res EXCEPT ![self] = Nil]
                           /\ sc' = [sc EXCEPT ![self] = Nil]
                           /\ si' = [si EXCEPT ![self] = 1]
                           /\ scy' = [scy EXCEPT ![self] = FALSE]
                           /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "J_Merge"]
                           /\ UNCHANGED << stack, canStop, tgt, fix, e, res, 
                                           sc, si, scy >>
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, jreached, jylos, ny, 
                                ageX, jSA, nsa, astack, amark, swept, zap, 
                                grant, stop, running, calive, go, minors, 
                                majors, S, H, SA, ypr, cycle, grey, black, 
                                cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                                slots, efwd, fill, hand, agex, prev, retire, 
                                ftop, fbot, cur, t, v >>

J_Stop(self) == /\ pc[self] = "J_Stop"
                /\ running = 0 \/ ~calive
                /\ pc' = [pc EXCEPT ![self] = "J_Help"]
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, jreached, jylos, ny, 
                                ageX, jSA, nsa, astack, amark, swept, zap, 
                                grant, stop, running, calive, go, minors, 
                                majors, S, H, SA, ypr, cycle, grey, black, 
                                cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                                stack, canStop, tgt, fix, e, res, sc, si, scy, 
                                slots, efwd, fill, hand, agex, prev, retire, 
                                ftop, fbot, cur, t, v >>

J_Merge(self) == /\ pc[self] = "J_Merge"
                 /\ IF job.st = "Running"
                       THEN /\ heap' = [a \in Addr |->
                                          IF a \in zap /\ MUTANT # "skip_zap" THEN Empty
                                          ELSE [heap[a] EXCEPT !.f = [i \in Fields |->
                                              IF /\ IsS(heap[a].f[i], job.x)
                                                 /\ \/ <<a, i>> \in Range(jheal) /\ ~(MUTANT = "skip_heal" /\ <<a, i>> = jheal[1])
                                                    \/ a \in jreached /\ a \in HandY(job.x) /\ MUTANT # "skip_ylos_resolve"
                                              THEN FwdOf(heap[a].f[i]) ELSE heap[a].f[i]]]]
                            /\ root' = [r \in Roots |->
                                          IF <<<<"R", r>>, 1>> \in Range(jheal) /\ IsS(root[r], job.x)
                                          THEN FwdOf(root[r]) ELSE root[r]]
                            /\ yjoin' = [c \in 1..YC |-> IF <<"Y", c>> \in jreached /\ ys[c] = Gen(job.x) THEN 0 ELSE yjoin[c]]
                            /\ ys' = [c \in 1..YC |-> IF \/ <<"Y", c>> \in jreached /\ ys[c] = Gen(job.x)
                                                         \/ <<"Y", c>> \in LbPromoted
                                                      THEN YOld ELSE ys[c]]
                            /\ job' = [job EXCEPT !.st = "Merged"]
                            /\ grant' = {}
                       ELSE /\ TRUE
                            /\ UNCHANGED << heap, root, ys, yjoin, job, grant >>
                 /\ pc' = [pc EXCEPT ![self] = "J_Ret"]
                 /\ UNCHANGED << lheap, lroot, nextLid, ops, ebump, xstate, 
                                 xage, gen, shadow, ystale, yrec, lbl, ycol, 
                                 bodyLids, jstarts, jheal, jstack, ns, nh, 
                                 jreached, jylos, ny, ageX, jSA, nsa, astack, 
                                 amark, swept, zap, stop, running, calive, go, 
                                 minors, majors, S, H, SA, ypr, cycle, grey, 
                                 black, cage, liveHand, liveHandY, liveAge, cw, 
                                 ncopy, stack, canStop, tgt, fix, e, res, sc, 
                                 si, scy, slots, efwd, fill, hand, agex, prev, 
                                 retire, ftop, fbot, cur, t, v >>

J_Ret(self) == /\ pc[self] = "J_Ret"
               /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
               /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
               /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                               xstate, xage, gen, shadow, ys, ystale, yrec, 
                               yjoin, lbl, ycol, bodyLids, job, jstarts, jheal, 
                               jstack, ns, nh, jreached, jylos, ny, ageX, jSA, 
                               nsa, astack, amark, swept, zap, grant, stop, 
                               running, calive, go, minors, majors, S, H, SA, 
                               ypr, cycle, grey, black, cage, liveHand, 
                               liveHandY, liveAge, cw, ncopy, canStop, tgt, 
                               fix, e, res, sc, si, scy, slots, efwd, fill, 
                               hand, agex, prev, retire, ftop, fbot, cur, t, v >>

JoinMerge(self) == J_Wait(self) \/ J_Help(self) \/ J_Stop(self)
                      \/ J_Merge(self) \/ J_Ret(self)

M_Epoch == /\ pc[MutId] = "M_Epoch"
           /\ \/ /\ CanOp("alloc") /\ ebump <= EC /\ nextLid <= MaxLid
                 /\ \E r \in Roots:
                      \E fv \in [Fields -> {Nil} \cup PlainHeld]:
                        /\ lheap' = [lheap EXCEPT ![nextLid] = [i \in Fields |-> LidOf(fv[i])]]
                        /\ heap' = [heap EXCEPT ![<<"E", ebump>>] = [lid |-> nextLid, f |-> fv, b |-> FALSE]]
                        /\ root' = [root EXCEPT ![r] = <<"E", ebump>>]
                        /\ lroot' = [lroot EXCEPT ![r] = nextLid]
                        /\ ebump' = ebump + 1
                        /\ nextLid' = nextLid + 1
                        /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<ys, yrec, yjoin, bodyLids, black>>
              \/ /\ CanOp("balloc") /\ ebump <= EC /\ nextLid <= MaxLid
                    /\ Cardinality({a \in Addr : heap[a].lid # 0 /\ heap[a].b}) < BC
                 /\ \E r \in Roots:
                      \E fv \in [Fields -> {Nil} \cup PlainHeld]:
                        /\ lheap' = [lheap EXCEPT ![nextLid] = [i \in Fields |-> LidOf(fv[i])]]
                        /\ heap' = [heap EXCEPT ![<<"E", ebump>>] = [lid |-> nextLid, f |-> fv, b |-> TRUE]]
                        /\ root' = [root EXCEPT ![r] = <<"E", ebump>>]
                        /\ lroot' = [lroot EXCEPT ![r] = nextLid]
                        /\ ebump' = ebump + 1
                        /\ nextLid' = nextLid + 1
                        /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<ys, yrec, yjoin, bodyLids, black>>
              \/ /\ CanOp("yalloc") /\ nextLid <= MaxLid /\ \E c \in 1..YC : ys[c] = YFree
                 /\ LET c == CHOOSE c2 \in 1..YC : ys[c2] = YFree IN
                      \E r \in Roots:
                        \E fv \in [Fields -> {Nil} \cup PlainHeld]:
                          \E rec \in (IF YlosGen = "lbid" /\ ystale[c] # {} THEN BOOLEAN ELSE {FALSE}):
                            /\ lheap' = [lheap EXCEPT ![nextLid] = [i \in Fields |-> LidOf(fv[i])]]
                            /\ heap' = [heap EXCEPT ![<<"Y", c>>] = [lid |-> nextLid, f |-> fv, b |-> FALSE]]
                            /\ ys' = [ys EXCEPT ![c] = Y0]
                            /\ yrec' = [yrec EXCEPT ![c] = rec]
                            /\ yjoin' = [yjoin EXCEPT ![c] = 0]
                            /\ IF cycle = "Marking"
                                  THEN /\ black' = (black \cup {<<"Y", c>>})
                                  ELSE /\ TRUE
                                       /\ black' = black
                            /\ root' = [root EXCEPT ![r] = <<"Y", c>>]
                            /\ lroot' = [lroot EXCEPT ![r] = nextLid]
                            /\ nextLid' = nextLid + 1
                            /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<ebump, bodyLids>>
              \/ /\ CanOp("lalloc") /\ ebump <= EC /\ nextLid + 1 <= MaxLid /\ \E c \in 1..YC : ys[c] = YFree
                 /\ LET c == CHOOSE c2 \in 1..YC : ys[c2] = YFree IN
                      \E r \in Roots:
                        /\ lheap' = [lheap EXCEPT ![nextLid] = [i \in Fields |-> IF i = 1 THEN nextLid + 1 ELSE 0],
                                                  ![nextLid + 1] = [i \in Fields |-> 0]]
                        /\ heap' = [heap EXCEPT ![<<"E", ebump>>] = [lid |-> nextLid, b |-> FALSE,
                                                                     f |-> [i \in Fields |-> IF i = 1 THEN <<"Y", c>> ELSE Nil]],
                                                ![<<"Y", c>>] = [Empty EXCEPT !.lid = nextLid + 1]]
                        /\ ys' = [ys EXCEPT ![c] = YBody]
                        /\ bodyLids' = (bodyLids \cup {nextLid + 1})
                        /\ IF cycle = "Marking"
                              THEN /\ black' = (black \cup {<<"Y", c>>})
                              ELSE /\ TRUE
                                   /\ black' = black
                        /\ root' = [root EXCEPT ![r] = <<"E", ebump>>]
                        /\ lroot' = [lroot EXCEPT ![r] = nextLid]
                        /\ ebump' = ebump + 1
                        /\ nextLid' = nextLid + 2
                        /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<yrec, yjoin>>
              \/ /\ CanOp("load")
                 /\ \E r \in Roots:
                      \E q \in {q2 \in Roots : root[q2] # Nil}:
                        \E i \in {i2 \in Fields : ~IsBodyRef(heap[root[q]].f[i2])}:
                          /\ root' = [root EXCEPT ![r] = heap[root[q]].f[i]]
                          /\ lroot' = [lroot EXCEPT ![r] = IF lroot[q] = 0 THEN 0 ELSE lheap[lroot[q]][i]]
                          /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<heap, lheap, nextLid, ebump, ys, yrec, yjoin, bodyLids, black>>
              \/ /\ CanOp("drop")
                 /\ \E r \in {r2 \in Roots : root[r2] # Nil}:
                      /\ root' = [root EXCEPT ![r] = Nil]
                      /\ lroot' = [lroot EXCEPT ![r] = 0]
                      /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<heap, lheap, nextLid, ebump, ys, yrec, yjoin, bodyLids, black>>
              \/ /\ CanOp("bwrite")
                 /\ \E r \in {r2 \in Roots : IsBld(root[r2])}:
                      \E i \in Fields:
                        \E val \in {Nil} \cup PlainHeld:
                          /\ heap' = [heap EXCEPT ![root[r]].f[i] = val]
                          /\ IF lroot[r] # 0
                                THEN /\ lheap' = [lheap EXCEPT ![lroot[r]][i] = LidOf(val)]
                                ELSE /\ TRUE
                                     /\ lheap' = lheap
                          /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<root, lroot, nextLid, ebump, ys, yrec, yjoin, bodyLids, black>>
              \/ /\ CanOp("bclear")
                 /\ \E r \in {r2 \in Roots : IsBld(root[r2])}:
                      /\ heap' = [heap EXCEPT ![root[r]].b = FALSE]
                      /\ ops' = ops + 1
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<root, lheap, lroot, nextLid, ebump, ys, yrec, yjoin, bodyLids, black>>
              \/ /\ minors < MaxMinors
                 /\ pc' = [pc EXCEPT ![MutId] = "MN_Join"]
                 /\ UNCHANGED <<heap, root, lheap, lroot, nextLid, ops, ebump, ys, yrec, yjoin, bodyLids, black>>
              \/ /\ MajorAllowed /\ majors < MaxMajors
                 /\ pc' = [pc EXCEPT ![MutId] = "MJ_Join"]
                 /\ UNCHANGED <<heap, root, lheap, lroot, nextLid, ops, ebump, ys, yrec, yjoin, bodyLids, black>>
              \/ /\ minors >= MaxMinors
                 /\ TRUE
                 /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
                 /\ UNCHANGED <<heap, root, lheap, lroot, nextLid, ops, ebump, ys, yrec, yjoin, bodyLids, black>>
           /\ UNCHANGED << xstate, xage, gen, shadow, ystale, lbl, ycol, job, 
                           jstarts, jheal, jstack, ns, nh, jreached, jylos, ny, 
                           ageX, jSA, nsa, astack, amark, swept, zap, grant, 
                           stop, running, calive, go, minors, majors, S, H, SA, 
                           ypr, cycle, grey, cage, liveHand, liveHandY, 
                           liveAge, cw, ncopy, stack, canStop, tgt, fix, e, 
                           res, sc, si, scy, slots, efwd, fill, hand, agex, 
                           prev, retire, ftop, fbot, cur, t, v >>

MN_Join == /\ pc[MutId] = "MN_Join"
           /\ stack' = [stack EXCEPT ![MutId] = << [ procedure |->  "JoinMerge",
                                                     pc        |->  "MN_Begin" ] >>
                                                 \o stack[MutId]]
           /\ pc' = [pc EXCEPT ![MutId] = "J_Wait"]
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, stop, running, calive, go, 
                           minors, majors, S, H, SA, ypr, cycle, grey, black, 
                           cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                           canStop, tgt, fix, e, res, sc, si, scy, slots, efwd, 
                           fill, hand, agex, prev, retire, ftop, fbot, cur, t, 
                           v >>

MN_Begin == /\ pc[MutId] = "MN_Begin"
            /\ minors' = minors + 1
            /\ fill' = (CHOOSE x \in X : xstate[x] = "Free")
            /\ hand' = (IF \E x \in X : xstate[x] = "Young" /\ xage[x] = K
                        THEN CHOOSE x \in X : xstate[x] = "Young" /\ xage[x] = K ELSE 0)
            /\ agex' = (IF \E x \in X : xstate[x] = "Young" /\ xage[x] < K
                        THEN CHOOSE x \in X : xstate[x] = "Young" /\ xage[x] < K ELSE 0)
            /\ prev' = (IF \E x \in X : xstate[x] = "Young" /\ xage[x] = 1
                        THEN CHOOSE x \in X : xstate[x] = "Young" /\ xage[x] = 1 ELSE 0)
            /\ retire' = (IF \E x \in X : xstate[x] = "Tenuring" THEN CHOOSE x \in X : xstate[x] = "Tenuring" ELSE 0)
            /\ LET mx == [c \in 1..YC |-> IF PrepMatch(c, hand') THEN hand'
                                          ELSE IF PrepMatch(c, agex') THEN agex' ELSE 0] IN
                 /\ ystale' = [c \in 1..YC |->
                                 IF mx[c] = 0 THEN ystale[c]
                                 ELSE (ystale[c] \ {mx[c]})
                                      \cup (IF ys[c] \in {Gen(x) : x \in X} /\ xstate[ys[c][2]] = "Young"
                                            THEN {ys[c][2]} ELSE {})]
                 /\ ys' = [c \in 1..YC |-> IF mx[c] = 0 THEN ys[c] ELSE Gen(mx[c])]
            /\ ycol' = (LbColoured(hand') \cup LbColoured(agex'))
            /\ slots' = SetToSeq({<<"root", r>> : r \in Roots})
            /\ pc' = [pc EXCEPT ![MutId] = "MN_Slot"]
            /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                            xstate, xage, gen, shadow, yrec, yjoin, lbl, 
                            bodyLids, job, jstarts, jheal, jstack, ns, nh, 
                            jreached, jylos, ny, ageX, jSA, nsa, astack, amark, 
                            swept, zap, grant, stop, running, calive, go, 
                            majors, S, H, SA, ypr, cycle, grey, black, cage, 
                            liveHand, liveHandY, liveAge, cw, ncopy, stack, 
                            canStop, tgt, fix, e, res, sc, si, scy, efwd, ftop, 
                            fbot, cur, t, v >>

MN_Slot == /\ pc[MutId] = "MN_Slot"
           /\ IF slots # <<>>
                 THEN /\ cur' = Head(slots)
                      /\ t' = (IF Head(slots)[1] = "root" THEN root[Head(slots)[2]]
                               ELSE heap[Head(slots)[2]].f[Head(slots)[3]])
                      /\ slots' = Tail(slots)
                      /\ pc' = [pc EXCEPT ![MutId] = "MN_Classify"]
                 ELSE /\ pc' = [pc EXCEPT ![MutId] = "MN_Epilogue"]
                      /\ UNCHANGED << slots, cur, t >>
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, stop, running, calive, go, 
                           minors, majors, S, H, SA, ypr, cycle, grey, black, 
                           cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                           stack, canStop, tgt, fix, e, res, sc, si, scy, efwd, 
                           fill, hand, agex, prev, retire, ftop, fbot, v >>

MN_Classify == /\ pc[MutId] = "MN_Classify"
               /\ IF IsE(t) \/ (prev # 0 /\ IsB(t, prev))
                     THEN /\ IF efwd[t] = Nil
                                THEN /\ LET bs == {heap[t].f[i] : i \in Fields} \cap {y \in YAddr : ys[y[2]] = YBody} IN
                                          /\ ycol' = (ycol \cup bs)
                                          /\ IF heap[t].b /\ BC > 0 /\ MUTANT # "builder_in_survivor"
                                                THEN /\ heap' = [heap EXCEPT ![<<"B", fill, fbot>>] = heap[t]]
                                                     /\ efwd' = [efwd EXCEPT ![t] = <<"B", fill, fbot>>]
                                                     /\ slots' = slots \o FieldSlots(<<"B", fill, fbot>>, "bld")
                                                     /\ fbot' = fbot + 1
                                                     /\ UNCHANGED << lbl, ftop >>
                                                ELSE /\ heap' = [heap EXCEPT ![<<"S", fill, ftop>>] = heap[t]]
                                                     /\ efwd' = [efwd EXCEPT ![t] = <<"S", fill, ftop>>]
                                                     /\ slots' = slots \o FieldSlots(<<"S", fill, ftop>>, "surv")
                                                     /\ ftop' = ftop + 1
                                                     /\ lbl' = [c \in 1..YC |-> IF <<"Y", c>> \in bs
                                                                                THEN lbl[c] \cup {<<fill, heap'[<<"Y", c>>].lid>>} ELSE lbl[c]]
                                                     /\ fbot' = fbot
                                ELSE /\ TRUE
                                     /\ UNCHANGED << heap, lbl, ycol, slots, 
                                                     efwd, ftop, fbot >>
                          /\ pc' = [pc EXCEPT ![MutId] = "MN_Fwd"]
                          /\ UNCHANGED << ys, yjoin, S, H, SA, ypr, v >>
                     ELSE /\ IF hand # 0 /\ IsS(t, hand)
                                THEN /\ IF cur[1] = "fld" /\ (cur[4] = "surv" \/ (cur[4] = "yy" /\ MUTANT # "ylos_slot_in_starts")
                                                              \/ (cur[4] = "bld" /\ MUTANT = "builder_in_heal"))
                                           THEN /\ H' = (H \cup {<<cur[2], cur[3]>>})
                                                /\ S' = S
                                           ELSE /\ IF cur[1] = "root" /\ MUTANT = "root_in_heal"
                                                      THEN /\ H' = (H \cup {<<<<"R", cur[2]>>, 1>>})
                                                           /\ S' = S
                                                      ELSE /\ IF ~(cur[1] = "root" /\ MUTANT = "no_root_starts")
                                                                 THEN /\ S' = (S \cup {t})
                                                                 ELSE /\ TRUE
                                                                      /\ S' = S
                                                           /\ H' = H
                                     /\ pc' = [pc EXCEPT ![MutId] = "MN_Next"]
                                     /\ UNCHANGED << ys, yjoin, SA, ypr, slots, 
                                                     v >>
                                ELSE /\ IF agex # 0 /\ IsS(t, agex)
                                           THEN /\ SA' = (SA \cup {t})
                                                /\ pc' = [pc EXCEPT ![MutId] = "MN_Next"]
                                                /\ UNCHANGED << ys, yjoin, ypr, 
                                                                slots, v >>
                                           ELSE /\ IF retire # 0 /\ IsS(t, retire)
                                                      THEN /\ v' = FwdOf(t)
                                                           /\ pc' = [pc EXCEPT ![MutId] = "MN_Resolve"]
                                                           /\ UNCHANGED << ys, 
                                                                           yjoin, 
                                                                           SA, 
                                                                           ypr, 
                                                                           slots >>
                                                      ELSE /\ IF IsY(t)
                                                                 THEN /\ IF ys[t[2]] = Y0 /\ t \notin ycol
                                                                            THEN /\ ys' = [ys EXCEPT ![t[2]] = Gen(fill)]
                                                                                 /\ yjoin' = [yjoin EXCEPT ![t[2]] = fill]
                                                                                 /\ slots' = slots \o FieldSlots(t, "yy")
                                                                                 /\ UNCHANGED << SA, 
                                                                                                 ypr >>
                                                                            ELSE /\ IF hand # 0 /\ ys[t[2]] = Gen(hand) /\ t \notin ypr
                                                                                       THEN /\ ypr' = (ypr \cup {t})
                                                                                            /\ slots' = slots \o FieldSlots(t, "hy")
                                                                                            /\ SA' = SA
                                                                                       ELSE /\ IF agex # 0 /\ ys[t[2]] = Gen(agex)
                                                                                                  THEN /\ SA' = (SA \cup {t})
                                                                                                  ELSE /\ TRUE
                                                                                                       /\ SA' = SA
                                                                                            /\ UNCHANGED << ypr, 
                                                                                                            slots >>
                                                                                 /\ UNCHANGED << ys, 
                                                                                                 yjoin >>
                                                                 ELSE /\ TRUE
                                                                      /\ UNCHANGED << ys, 
                                                                                      yjoin, 
                                                                                      SA, 
                                                                                      ypr, 
                                                                                      slots >>
                                                           /\ pc' = [pc EXCEPT ![MutId] = "MN_Next"]
                                                           /\ v' = v
                                     /\ UNCHANGED << S, H >>
                          /\ UNCHANGED << heap, lbl, ycol, efwd, ftop, fbot >>
               /\ UNCHANGED << root, lheap, lroot, nextLid, ops, ebump, xstate, 
                               xage, gen, shadow, ystale, yrec, bodyLids, job, 
                               jstarts, jheal, jstack, ns, nh, jreached, jylos, 
                               ny, ageX, jSA, nsa, astack, amark, swept, zap, 
                               grant, stop, running, calive, go, minors, 
                               majors, cycle, grey, black, cage, liveHand, 
                               liveHandY, liveAge, cw, ncopy, stack, canStop, 
                               tgt, fix, e, res, sc, si, scy, fill, hand, agex, 
                               prev, retire, cur, t >>

MN_Fwd == /\ pc[MutId] = "MN_Fwd"
          /\ v' = efwd[t]
          /\ pc' = [pc EXCEPT ![MutId] = "MN_Set"]
          /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                          xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                          lbl, ycol, bodyLids, job, jstarts, jheal, jstack, ns, 
                          nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                          amark, swept, zap, grant, stop, running, calive, go, 
                          minors, majors, S, H, SA, ypr, cycle, grey, black, 
                          cage, liveHand, liveHandY, liveAge, cw, ncopy, stack, 
                          canStop, tgt, fix, e, res, sc, si, scy, slots, efwd, 
                          fill, hand, agex, prev, retire, ftop, fbot, cur, t >>

MN_Set == /\ pc[MutId] = "MN_Set"
          /\ IF cur[1] = "root"
                THEN /\ root' = [root EXCEPT ![cur[2]] = v]
                     /\ heap' = heap
                ELSE /\ heap' = [heap EXCEPT ![cur[2]].f[cur[3]] = v]
                     /\ root' = root
          /\ pc' = [pc EXCEPT ![MutId] = "MN_Next"]
          /\ UNCHANGED << lheap, lroot, nextLid, ops, ebump, xstate, xage, gen, 
                          shadow, ys, ystale, yrec, yjoin, lbl, ycol, bodyLids, 
                          job, jstarts, jheal, jstack, ns, nh, jreached, jylos, 
                          ny, ageX, jSA, nsa, astack, amark, swept, zap, grant, 
                          stop, running, calive, go, minors, majors, S, H, SA, 
                          ypr, cycle, grey, black, cage, liveHand, liveHandY, 
                          liveAge, cw, ncopy, stack, canStop, tgt, fix, e, res, 
                          sc, si, scy, slots, efwd, fill, hand, agex, prev, 
                          retire, ftop, fbot, cur, t, v >>

MN_Resolve == /\ pc[MutId] = "MN_Resolve"
              /\ IF MUTANT # "no_resolve"
                    THEN /\ IF cur[1] = "root"
                               THEN /\ root' = [root EXCEPT ![cur[2]] = v]
                                    /\ heap' = heap
                               ELSE /\ heap' = [heap EXCEPT ![cur[2]].f[cur[3]] = v]
                                    /\ root' = root
                    ELSE /\ TRUE
                         /\ UNCHANGED << heap, root >>
              /\ pc' = [pc EXCEPT ![MutId] = "MN_Next"]
              /\ UNCHANGED << lheap, lroot, nextLid, ops, ebump, xstate, xage, 
                              gen, shadow, ys, ystale, yrec, yjoin, lbl, ycol, 
                              bodyLids, job, jstarts, jheal, jstack, ns, nh, 
                              jreached, jylos, ny, ageX, jSA, nsa, astack, 
                              amark, swept, zap, grant, stop, running, calive, 
                              go, minors, majors, S, H, SA, ypr, cycle, grey, 
                              black, cage, liveHand, liveHandY, liveAge, cw, 
                              ncopy, stack, canStop, tgt, fix, e, res, sc, si, 
                              scy, slots, efwd, fill, hand, agex, prev, retire, 
                              ftop, fbot, cur, t, v >>

MN_Next == /\ pc[MutId] = "MN_Next"
           /\ cur' = Nil
           /\ t' = Nil
           /\ v' = Nil
           /\ pc' = [pc EXCEPT ![MutId] = "MN_Slot"]
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, stop, running, calive, go, 
                           minors, majors, S, H, SA, ypr, cycle, grey, black, 
                           cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                           stack, canStop, tgt, fix, e, res, sc, si, scy, 
                           slots, efwd, fill, hand, agex, prev, retire, ftop, 
                           fbot >>

MN_Epilogue == /\ pc[MutId] = "MN_Epilogue"
               /\ heap' = [a \in Addr |->
                             IF \/ IsE(a)
                                \/ retire # 0 /\ (IsS(a, retire) \/ IsB(a, retire))
                                \/ prev # 0 /\ IsB(a, prev)
                                \/ (IsY(a) /\ cycle # "Marking" /\ a \notin ycol
                                    /\ (ys[a[2]] \in {Y0, YBody} \/ (retire # 0 /\ ys[a[2]] = Gen(retire) /\ MUTANT # "keep_unreached_ylos")))
                             THEN Empty ELSE heap[a]]
               /\ yjoin' = [c \in 1..YC |->
                              IF ys[c] = Y0 \/ (retire # 0 /\ ys[c] = Gen(retire) /\ MUTANT # "keep_unreached_ylos")
                              THEN 0 ELSE yjoin[c]]
               /\ ystale' = [c \in 1..YC |-> {x \in ystale[c] : x # hand /\ x # retire}]
               /\ lbl' = [c \in 1..YC |-> {en \in lbl[c] : en[1] # hand /\ en[1] # retire}]
               /\ ys' = [c \in 1..YC |->
                           IF <<"Y", c>> \notin ycol
                              /\ (ys[c] \in {Y0, YBody} \/ (retire # 0 /\ ys[c] = Gen(retire) /\ MUTANT # "keep_unreached_ylos"))
                           THEN (IF cycle = "Marking" THEN YDead ELSE YFree) ELSE ys[c]]
               /\ ycol' = {}
               /\ xstate' = [x \in X |-> IF x = fill THEN "Young"
                                         ELSE IF x = hand THEN "Tenuring"
                                         ELSE IF x = retire THEN "Free" ELSE xstate[x]]
               /\ xage' = [x \in X |-> IF x = fill THEN 1
                                       ELSE IF x = hand \/ x = retire THEN 0
                                       ELSE IF xstate'[x] = "Young" THEN xage[x] + 1 ELSE xage[x]]
               /\ ebump' = 1
               /\ efwd' = [a \in EAddr \cup BAddr |-> Nil]
               /\ ftop' = 1
               /\ fbot' = 1
               /\ pc' = [pc EXCEPT ![MutId] = "MN_Cycle"]
               /\ UNCHANGED << root, lheap, lroot, nextLid, ops, gen, shadow, 
                               yrec, bodyLids, job, jstarts, jheal, jstack, ns, 
                               nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                               amark, swept, zap, grant, stop, running, calive, 
                               go, minors, majors, S, H, SA, ypr, cycle, grey, 
                               black, cage, liveHand, liveHandY, liveAge, cw, 
                               ncopy, stack, canStop, tgt, fix, e, res, sc, si, 
                               scy, slots, fill, hand, agex, prev, retire, cur, 
                               t, v >>

MN_Cycle == /\ pc[MutId] = "MN_Cycle"
            /\ IF cycle = "Marking"
                  THEN /\ IF cage + 1 >= CycleT
                             THEN /\ heap' = [a \in Addr |-> IF (OldAddr(a) /\ a \notin (OldClose(grey) \cup black))
                                                                \/ (IsY(a) /\ ys[a[2]] = YDead)
                                                             THEN Empty ELSE heap[a]]
                                  /\ ys' = [c \in 1..YC |-> IF ys[c] = YDead \/ (ys[c] \in {YOld, YBody} /\ <<"Y", c>> \notin (OldClose(grey) \cup black))
                                                            THEN YFree ELSE ys[c]]
                                  /\ cycle' = "Idle"
                                  /\ grey' = {}
                                  /\ black' = {}
                                  /\ cage' = 0
                             ELSE /\ cage' = cage + 1
                                  /\ UNCHANGED << heap, ys, cycle, grey, black >>
                  ELSE /\ IF CycleAllowed
                             THEN /\ \/ /\ TRUE
                                        /\ UNCHANGED <<cycle, grey, black, cage>>
                                     \/ /\ LET G == {root[r] : r \in Roots}
                                                    \cup {heap[a].f[i] : a \in Walk(MUTANT = "t0_skips_tenuring"), i \in Fields} IN
                                             grey' = (IF MUTANT = "t0_keeps_young" THEN G \ {Nil}
                                                      ELSE IF MUTANT = "t0_greys_ylos" THEN {a \in G : OldAddr(a) \/ YoungY(a)}
                                                      ELSE {a \in G : OldAddr(a)})
                                        /\ black' = {y \in YAddr : YoungY(y)}
                                        /\ cycle' = "Marking"
                                        /\ cage' = 0
                             ELSE /\ TRUE
                                  /\ UNCHANGED << cycle, grey, black, cage >>
                       /\ UNCHANGED << heap, ys >>
            /\ pc' = [pc EXCEPT ![MutId] = "MN_Launch"]
            /\ UNCHANGED << root, lheap, lroot, nextLid, ops, ebump, xstate, 
                            xage, gen, shadow, ystale, yrec, yjoin, lbl, ycol, 
                            bodyLids, job, jstarts, jheal, jstack, ns, nh, 
                            jreached, jylos, ny, ageX, jSA, nsa, astack, amark, 
                            swept, zap, grant, stop, running, calive, go, 
                            minors, majors, S, H, SA, ypr, liveHand, liveHandY, 
                            liveAge, cw, ncopy, stack, canStop, tgt, fix, e, 
                            res, sc, si, scy, slots, efwd, fill, hand, agex, 
                            prev, retire, ftop, fbot, cur, t, v >>

MN_Launch == /\ pc[MutId] = "MN_Launch"
             /\ IF \E x \in X : xstate[x] = "Tenuring"
                   THEN /\ LET x == CHOOSE y \in X : xstate[y] = "Tenuring" IN
                             LET ax == IF \E y \in X : xstate[y] = "Young" /\ xage[y] >= 2
                                       THEN CHOOSE y \in X : xstate[y] = "Young" /\ xage[y] >= 2 ELSE 0 IN
                               /\ IF MUTANT = "gen_not_bumped"
                                     THEN /\ TRUE
                                          /\ UNCHANGED << gen, shadow >>
                                     ELSE /\ IF NextGen(gen[x]) = 1 /\ gen[x] # 0 /\ MUTANT # "wrap_no_discard"
                                                THEN /\ shadow' = [shadow EXCEPT ![x] = [c \in 1..SC |-> NoEntry]]
                                                     /\ gen' = [gen EXCEPT ![x] = 1]
                                                ELSE /\ gen' = [gen EXCEPT ![x] = NextGen(gen[x])]
                                                     /\ UNCHANGED shadow
                               /\ job' = [st |-> "Running", x |-> x]
                               /\ liveHand' = {a \in ReachAll : IsS(a, x)}
                               /\ liveHandY' = (ReachAll \cap HandY(x))
                               /\ ageX' = ax
                               /\ liveAge' = (IF ax = 0 THEN {}
                                              ELSE ReachAll \cap ({a \in SAddr : a[2] = ax} \cup {y \in YAddr : ys[y[2]] = Gen(ax)}))
                               /\ swept' = (ax = 0)
                        /\ jstarts' = SetToSeq(S)
                        /\ jheal' = SetToSeq(H)
                        /\ jstack' = <<>>
                        /\ ns' = 1
                        /\ nh' = 1
                        /\ jreached' = ypr
                        /\ jylos' = <<>>
                        /\ ny' = 1
                        /\ jSA' = SetToSeq(SA)
                        /\ nsa' = 1
                        /\ astack' = <<>>
                        /\ amark' = {}
                        /\ zap' = {}
                        /\ grant' = (IF MUTANT = "grant_t0_cells" /\ cycle = "Marking" THEN OAddr
                                     ELSE {a \in OAddr : heap[a].lid = 0})
                        /\ cw' = {}
                        /\ ncopy' = [a \in SAddr |-> 0]
                        /\ stop' = FALSE
                        /\ IF TenureMode = 2 /\ calive
                              THEN /\ running' = Collectors
                                   /\ go' = [c \in CollIds |-> TRUE]
                              ELSE /\ TRUE
                                   /\ UNCHANGED << running, go >>
                   ELSE /\ TRUE
                        /\ UNCHANGED << gen, shadow, job, jstarts, jheal, 
                                        jstack, ns, nh, jreached, jylos, ny, 
                                        ageX, jSA, nsa, astack, amark, swept, 
                                        zap, grant, stop, running, go, 
                                        liveHand, liveHandY, liveAge, cw, 
                                        ncopy >>
             /\ S' = {}
             /\ H' = {}
             /\ SA' = {}
             /\ ypr' = {}
             /\ pc' = [pc EXCEPT ![MutId] = "MN_Sync"]
             /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                             xstate, xage, ys, ystale, yrec, yjoin, lbl, ycol, 
                             bodyLids, calive, minors, majors, cycle, grey, 
                             black, cage, stack, canStop, tgt, fix, e, res, sc, 
                             si, scy, slots, efwd, fill, hand, agex, prev, 
                             retire, ftop, fbot, cur, t, v >>

MN_Sync == /\ pc[MutId] = "MN_Sync"
           /\ IF TenureMode = 1 /\ job.st = "Running" /\ ~JobDone
                 THEN /\ /\ canStop' = [canStop EXCEPT ![MutId] = FALSE]
                         /\ stack' = [stack EXCEPT ![MutId] = << [ procedure |->  "Engine",
                                                                   pc        |->  "MN_Done",
                                                                   tgt       |->  tgt[MutId],
                                                                   fix       |->  fix[MutId],
                                                                   e         |->  e[MutId],
                                                                   res       |->  res[MutId],
                                                                   sc        |->  sc[MutId],
                                                                   si        |->  si[MutId],
                                                                   scy       |->  scy[MutId],
                                                                   canStop   |->  canStop[MutId] ] >>
                                                               \o stack[MutId]]
                      /\ tgt' = [tgt EXCEPT ![MutId] = Nil]
                      /\ fix' = [fix EXCEPT ![MutId] = Nil]
                      /\ e' = [e EXCEPT ![MutId] = NoEntry]
                      /\ res' = [res EXCEPT ![MutId] = Nil]
                      /\ sc' = [sc EXCEPT ![MutId] = Nil]
                      /\ si' = [si EXCEPT ![MutId] = 1]
                      /\ scy' = [scy EXCEPT ![MutId] = FALSE]
                      /\ pc' = [pc EXCEPT ![MutId] = "E_Loop"]
                 ELSE /\ pc' = [pc EXCEPT ![MutId] = "MN_Done"]
                      /\ UNCHANGED << stack, canStop, tgt, fix, e, res, sc, si, 
                                      scy >>
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, stop, running, calive, go, 
                           minors, majors, S, H, SA, ypr, cycle, grey, black, 
                           cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                           slots, efwd, fill, hand, agex, prev, retire, ftop, 
                           fbot, cur, t, v >>

MN_Done == /\ pc[MutId] = "MN_Done"
           /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, stop, running, calive, go, 
                           minors, majors, S, H, SA, ypr, cycle, grey, black, 
                           cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                           stack, canStop, tgt, fix, e, res, sc, si, scy, 
                           slots, efwd, fill, hand, agex, prev, retire, ftop, 
                           fbot, cur, t, v >>

MJ_Join == /\ pc[MutId] = "MJ_Join"
           /\ stack' = [stack EXCEPT ![MutId] = << [ procedure |->  "JoinMerge",
                                                     pc        |->  "MJ_Cycle" ] >>
                                                 \o stack[MutId]]
           /\ pc' = [pc EXCEPT ![MutId] = "J_Wait"]
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, stop, running, calive, go, 
                           minors, majors, S, H, SA, ypr, cycle, grey, black, 
                           cage, liveHand, liveHandY, liveAge, cw, ncopy, 
                           canStop, tgt, fix, e, res, sc, si, scy, slots, efwd, 
                           fill, hand, agex, prev, retire, ftop, fbot, cur, t, 
                           v >>

MJ_Cycle == /\ pc[MutId] = "MJ_Cycle"
            /\ majors' = majors + 1
            /\ IF cycle = "Marking"
                  THEN /\ heap' = [a \in Addr |-> IF (OldAddr(a) /\ a \notin (OldClose(grey) \cup black))
                                                     \/ (IsY(a) /\ ys[a[2]] = YDead)
                                                  THEN Empty ELSE heap[a]]
                       /\ ys' = [c \in 1..YC |-> IF ys[c] = YDead \/ (ys[c] \in {YOld, YBody} /\ <<"Y", c>> \notin (OldClose(grey) \cup black))
                                                 THEN YFree ELSE ys[c]]
                       /\ cycle' = "Idle"
                       /\ grey' = {}
                       /\ black' = {}
                       /\ cage' = 0
                  ELSE /\ TRUE
                       /\ UNCHANGED << heap, ys, cycle, grey, black, cage >>
            /\ pc' = [pc EXCEPT ![MutId] = "MJ_Mark"]
            /\ UNCHANGED << root, lheap, lroot, nextLid, ops, ebump, xstate, 
                            xage, gen, shadow, ystale, yrec, yjoin, lbl, ycol, 
                            bodyLids, job, jstarts, jheal, jstack, ns, nh, 
                            jreached, jylos, ny, ageX, jSA, nsa, astack, amark, 
                            swept, zap, grant, stop, running, calive, go, 
                            minors, S, H, SA, ypr, liveHand, liveHandY, 
                            liveAge, cw, ncopy, stack, canStop, tgt, fix, e, 
                            res, sc, si, scy, slots, efwd, fill, hand, agex, 
                            prev, retire, ftop, fbot, cur, t, v >>

MJ_Mark == /\ pc[MutId] = "MJ_Mark"
           /\ heap' = [a \in Addr |-> IF (IsO(a) \/ IsY(a)) /\ a \notin MajorLive THEN Empty ELSE heap[a]]
           /\ ystale' = [c \in 1..YC |->
                           IF AddrKeyed /\ <<"Y", c>> \notin MajorLive /\ ys[c] \in {Gen(x) : x \in X}
                              /\ xstate[ys[c][2]] = "Young"
                           THEN ystale[c] \cup {ys[c][2]} ELSE ystale[c]]
           /\ yjoin' = [c \in 1..YC |-> IF <<"Y", c>> \notin MajorLive THEN 0 ELSE yjoin[c]]
           /\ lbl' = [c \in 1..YC |-> IF LbKey = "drop" /\ <<"Y", c>> \notin MajorLive THEN {} ELSE lbl[c]]
           /\ ys' = [c \in 1..YC |-> IF <<"Y", c>> \notin MajorLive THEN YFree ELSE ys[c]]
           /\ pc' = [pc EXCEPT ![MutId] = "M_Epoch"]
           /\ UNCHANGED << root, lheap, lroot, nextLid, ops, ebump, xstate, 
                           xage, gen, shadow, yrec, ycol, bodyLids, job, 
                           jstarts, jheal, jstack, ns, nh, jreached, jylos, ny, 
                           ageX, jSA, nsa, astack, amark, swept, zap, grant, 
                           stop, running, calive, go, minors, majors, S, H, SA, 
                           ypr, cycle, grey, black, cage, liveHand, liveHandY, 
                           liveAge, cw, ncopy, stack, canStop, tgt, fix, e, 
                           res, sc, si, scy, slots, efwd, fill, hand, agex, 
                           prev, retire, ftop, fbot, cur, t, v >>

Mutator == M_Epoch \/ MN_Join \/ MN_Begin \/ MN_Slot \/ MN_Classify
              \/ MN_Fwd \/ MN_Set \/ MN_Resolve \/ MN_Next \/ MN_Epilogue
              \/ MN_Cycle \/ MN_Launch \/ MN_Sync \/ MN_Done \/ MJ_Join
              \/ MJ_Cycle \/ MJ_Mark

C_Wait(self) == /\ pc[self] = "C_Wait"
                /\ go[self] /\ calive
                /\ go' = [go EXCEPT ![self] = FALSE]
                /\ pc' = [pc EXCEPT ![self] = "C_Run"]
                /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                                xstate, xage, gen, shadow, ys, ystale, yrec, 
                                yjoin, lbl, ycol, bodyLids, job, jstarts, 
                                jheal, jstack, ns, nh, jreached, jylos, ny, 
                                ageX, jSA, nsa, astack, amark, swept, zap, 
                                grant, stop, running, calive, minors, majors, 
                                S, H, SA, ypr, cycle, grey, black, cage, 
                                liveHand, liveHandY, liveAge, cw, ncopy, stack, 
                                canStop, tgt, fix, e, res, sc, si, scy, slots, 
                                efwd, fill, hand, agex, prev, retire, ftop, 
                                fbot, cur, t, v >>

C_Run(self) == /\ pc[self] = "C_Run"
               /\ /\ canStop' = [canStop EXCEPT ![self] = TRUE]
                  /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "Engine",
                                                           pc        |->  "C_Fin",
                                                           tgt       |->  tgt[self],
                                                           fix       |->  fix[self],
                                                           e         |->  e[self],
                                                           res       |->  res[self],
                                                           sc        |->  sc[self],
                                                           si        |->  si[self],
                                                           scy       |->  scy[self],
                                                           canStop   |->  canStop[self] ] >>
                                                       \o stack[self]]
               /\ tgt' = [tgt EXCEPT ![self] = Nil]
               /\ fix' = [fix EXCEPT ![self] = Nil]
               /\ e' = [e EXCEPT ![self] = NoEntry]
               /\ res' = [res EXCEPT ![self] = Nil]
               /\ sc' = [sc EXCEPT ![self] = Nil]
               /\ si' = [si EXCEPT ![self] = 1]
               /\ scy' = [scy EXCEPT ![self] = FALSE]
               /\ pc' = [pc EXCEPT ![self] = "E_Loop"]
               /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                               xstate, xage, gen, shadow, ys, ystale, yrec, 
                               yjoin, lbl, ycol, bodyLids, job, jstarts, jheal, 
                               jstack, ns, nh, jreached, jylos, ny, ageX, jSA, 
                               nsa, astack, amark, swept, zap, grant, stop, 
                               running, calive, go, minors, majors, S, H, SA, 
                               ypr, cycle, grey, black, cage, liveHand, 
                               liveHandY, liveAge, cw, ncopy, slots, efwd, 
                               fill, hand, agex, prev, retire, ftop, fbot, cur, 
                               t, v >>

C_Fin(self) == /\ pc[self] = "C_Fin"
               /\ running' = running - 1
               /\ pc' = [pc EXCEPT ![self] = "C_Wait"]
               /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                               xstate, xage, gen, shadow, ys, ystale, yrec, 
                               yjoin, lbl, ycol, bodyLids, job, jstarts, jheal, 
                               jstack, ns, nh, jreached, jylos, ny, ageX, jSA, 
                               nsa, astack, amark, swept, zap, grant, stop, 
                               calive, go, minors, majors, S, H, SA, ypr, 
                               cycle, grey, black, cage, liveHand, liveHandY, 
                               liveAge, cw, ncopy, stack, canStop, tgt, fix, e, 
                               res, sc, si, scy, slots, efwd, fill, hand, agex, 
                               prev, retire, ftop, fbot, cur, t, v >>

Collector(self) == C_Wait(self) \/ C_Run(self) \/ C_Fin(self)

F_Maybe == /\ pc[EnvId] = "F_Maybe"
           /\ \/ /\ StopAllowed
                 /\ stop' = TRUE
                 /\ UNCHANGED calive
              \/ /\ MUTANT = "fork_mid_item" /\ job.st = "Running"
                 /\ calive' = FALSE
                 /\ stop' = stop
              \/ /\ TRUE
                 /\ UNCHANGED <<stop, calive>>
           /\ pc' = [pc EXCEPT ![EnvId] = "Done"]
           /\ UNCHANGED << heap, root, lheap, lroot, nextLid, ops, ebump, 
                           xstate, xage, gen, shadow, ys, ystale, yrec, yjoin, 
                           lbl, ycol, bodyLids, job, jstarts, jheal, jstack, 
                           ns, nh, jreached, jylos, ny, ageX, jSA, nsa, astack, 
                           amark, swept, zap, grant, running, go, minors, 
                           majors, S, H, SA, ypr, cycle, grey, black, cage, 
                           liveHand, liveHandY, liveAge, cw, ncopy, stack, 
                           canStop, tgt, fix, e, res, sc, si, scy, slots, efwd, 
                           fill, hand, agex, prev, retire, ftop, fbot, cur, t, 
                           v >>

Env == F_Maybe

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Mutator \/ Env
           \/ (\E self \in ProcSet: Engine(self) \/ JoinMerge(self))
           \/ (\E self \in CollIds: Collector(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in CollIds : WF_vars(Collector(self)) /\ WF_vars(Engine(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

\* Properties over the mutator's process variables (after the translation,
\* where they are declared).
TV1_Resolve ==                                     \* TV1 at resolveRetire (every build)
    (pc[MutId] = "MN_Classify" /\ retire # 0 /\ IsS(t, retire)) => FwdOf(t) # Nil
=============================================================================
