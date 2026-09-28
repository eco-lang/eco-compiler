# Threaded GC — TLA+ model M3: parallel minor forwarding (claim, copy, publish)

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). The PlusCal sketch passes the translator and
SANY; TLC has not run.

**Parents:** `plans/threaded-gc-tla-verification.md` (§2 rules A1–A9, §5.1 index), and
`plans/threaded-gc-tla-primer.md` (read it first if TLA+ or the GC terms are new). The structure
follows the M2 plan (`plans/threaded-gc-tla-M2-slice-control.md`), and M3 relies on M2's **Drain**
contract.

**Scope.** M3 models the protocol by which several threads copy the nursery's live objects at
once, without copying any object twice:
- the header word goes from its original value, to **BUSY**, to a **forward** word;
- the copy is made between those two changes.

The same protocol runs in two places:

| Where | Code | What is copied |
|---|---|---|
| Phase 6 parallel minor (legacy nursery) | `NurseryParallel.cpp` (`evacuateP`, `copyClaimed`, `spineRunP`, `reachYoungLargeP`) | from-space survivors into to-space LABs, or promoted into the old gen |
| 7b region minor (the default since TG7d) | `NurseryRegion.cpp` (`evacuateR`, `copyClaimedR`, `spineRunR`, `reachYoungLargeR`) | eden (and the previous builder area) into the Fill extent. It never promotes: tenuring is the 7c job, modelled in M5 |

---

## 1. Why this model

A minor GC copies every live young object and rewrites every pointer to it. Phase 6 does that
with N threads. The dangers are specific:
- two threads copying one object: two copies, pointers split between them, and a program that
  sees two different "identical" values;
- a thread using a forward before the copy exists;
- a thread computing an object's size from a header that another thread has already overwritten;
- two threads writing the same pointer slot.

These happen only under particular interleavings. `gc-minor-tsan` runs the real protocol under
ThreadSanitizer, but TSan sees only the schedules that happen to run. M3 checks every interleaving
of 2–3 workers over a small heap that contains a shared object, a list spine, a promoted parent
and a young large object.

The protocol is textbook (HB 14.4, claim-then-copy), so M3 is expected to find nothing. Its value
is threefold:
- it pins down the exact **contract** M4 and M5 rely on (CopyOnce: each young object has at most
  one copy, and every slot ends up at that copy);
- it gives the historical and plausible mistakes a provable counterexample;
- its trace spec checks that the running code still follows the protocol after later edits.

## 2. What the model checks, in one paragraph

A set of workers drains a shared pool of grey entries (M2's Drain contract). Scanning an entry
visits each of its pointer slots. If a slot points into from-space, the worker loads that object's
header word:
- **BUSY** (another worker is copying it): the worker waits;
- a **forward** word: the worker writes the forward address into the slot;
- the original header: the worker tries to **claim** the object with a CAS to BUSY, **copies**
  body and header, **publishes** the forward word with a release store, writes the new address into
  its slot, and pushes the copy if it has children.

List tails are copied in bounded **spine runs** without pushing each cell. A **young large object
(YLOS)** is never copied: it is reached once, under a mutex, and scanned in place.

M3 checks, for every interleaving:
- each object is copied at most once;
- every slot ends up holding exactly the copy that its original's header forwards to;
- no BUSY word survives the drain;
- no size is read from a BUSY word;
- a promoted object never points at a young copy (PM5 / HEAP_005);
- nobody writes a slot of an object another worker is responsible for;
- each YLOS is reached once.

## 3. The protocol in plain words

### 3.1 The header word as a lock

Every heap object starts with a 64-bit header (`Header`, `Heap.hpp:164-175`). During a minor GC
its first word doubles as a tiny state machine (`MinorWork.hpp:33-75`):

| State | Word | Meaning |
|---|---|---|
| unforwarded | the object's normal header (tag ≠ 26) | nobody has copied it yet |
| **BUSY** | `kTagForward` alone (tag 26, colour 0, address 0) (`MinorWork.hpp:38`) | a worker has claimed it and is copying it right now |
| forwarded | `kTagForward | colour<<5 | (addr>>3)<<7` (`fwdWord`, `:43-46`) | copied; the address of the copy is in the word |

The operations, all on that one word through `std::atomic_ref<uint64_t>`:

| Operation | Code | Memory order |
|---|---|---|
| `loadHeader(obj)` | `MinorWork.hpp:54-56` | acquire |
| `claim(obj, h)`: CAS from the observed header `h` to BUSY; on failure `h` gets the current word | `:58-61` | acq_rel / acquire |
| `publish(obj, dst, colour)`: store the forward word | `:63-65` | release ("orders the copy before the address") |
| `waitPublished(obj, pause)`: re-load until the word is no longer BUSY | `:68-75` | acquire, with backoff |

### 3.2 One slot, step by step (`evacuateP`, `NurseryParallel.cpp:315-345`)

```
slot holds p
filters: constant / null / permanent space -> nothing to do;
         not in from-space -> maybe a young large object (reachYoungLargeP), else nothing
hw = loadHeader(p)
loop:
  if hw is a forward word:
      if hw == BUSY: hw = waitPublished(p); continue
      slot = forward address; return
  if claim(p, hw): break              // we own the copy
  // else: hw now holds what beat us; loop
dst = copyClaimed(p, hw)              // size from the SAVED hw, never from p's header
slot = dst
if dst has children: push dst         // our private grey stack
```

`copyClaimed` (`NurseryParallel.cpp:250-313`):
- size comes from the **saved** header: `getObjectSizeFromHeader(&hd)` at `:255`, with the comment
  "never getObjectSize(obj): it reads BUSY";
- promote or survive is decided by age, pin and builder (`shouldPromote`);
- memory comes from `allocatePromotion` (old gen) or `labAllocate` (to-space);
- the body is copied with a plain `memcpy`, then the fixed-up header (`:301-304`);
- finally `publish` (`:311`).

### 3.3 Example: two workers race for one object

Object `S` (a shared leaf) is referenced by two entries, scanned by workers A and B at the same
time.

| # | A | B | `hdr[S]` |
|---|---|---|---|
| 1 | `loadHeader(S)` → H | | H |
| 2 | | `loadHeader(S)` → H | H |
| 3 | `claim(S, H)` succeeds | | BUSY |
| 4 | | `claim(S, H)` fails, `hw` := BUSY | BUSY |
| 5 | allocates `S'`, copies body and header | `waitPublished(S)` spins | BUSY |
| 6 | `publish(S, S')` | | FWD(S') |
| 7 | writes `S'` into its slot | wait ends, `hw` = FWD(S'); writes `S'` into its slot | FWD(S') |

One copy, and both slots name it. Every other ordering must end the same way. M3 proves that for
all orderings.

### 3.4 Example: sizing from the wrong word

If step 5 computed the size with `getObjectSize(S)`, it would read S's current header: BUSY. A
Tag_Forward "object" is 8 bytes, the header only. The copy would lose every field. Mutant
`size_from_busy` (§6) makes exactly that change, and `SizeFaithful` must fail.

### 3.5 List spines and the counted heads pass (`spineRunP`, `NurseryParallel.cpp:397-442`)

A long Elm list is a chain of Cons cells, each `(head, tail)`. Pushing every copied cell as an
entry would cost a deque operation per cell and scatter the copies. So when a worker scans a Cons,
it copies the **tail chain itself**, cell after cell:
- claim, copy and publish each cell;
- write it into the previous copy's tail;
- stop at `MINOR_SPINE_RUN = 512` cells (`AllocatorCommon.hpp:248`), at a non-Cons, at a cell
  another worker already forwarded (or is copying), or at the end.

Then it does a **heads pass**: it evacuates the head of each cell it copied. Two rules make the
heads pass safe, and the code comment at `:432-434` states them:
1. **Count cells; never test "still in to-space".** The run's last tail may point at a cell that
   *another* worker copied (the run met that worker's copy and stopped). That cell is also in
   to-space. A pass that kept walking while cells were in to-space would evacuate the heads of the
   other worker's cells, and two workers would write the same slot.
2. **A truncated run's last cell is excluded.** When the run stops at 512 cells, the last copy is
   *pushed* as an entry, and whoever takes it scans its head. The pass covers `k − 1` cells.

**Example (rule 1).** List `3 → 4 → 5`, with worker B already holding a copy of 5 from another
path.

| # | A (scanning copy 3') | B | effect |
|---|---|---|---|
| 1 | tail of 3' is 4: claim, copy → 4', link `3'.tail = 4'` | | run = [4'] |
| 2 | tail of 4' is 5: `loadHeader(5)` = FWD(5'') | (B copied 5 → 5'' earlier; B owns 5''s slots) | link `4'.tail = 5''`; run ends |
| 3 | heads pass, **counted** (k = 1): evacuate `4'.head` | B scans 5'': evacuates `5''.head` | correct |
| 3′ | heads pass, **walking while in to-space**: evacuates `4'.head`, then follows `4'.tail` to `5''` and evacuates `5''.head` | B evacuates `5''.head` at the same time | **two writers on one slot** |

Mutant `heads_walk` is row 3′.

### 3.6 Young large objects (`reachYoungLargeP`, `NurseryParallel.cpp:359-391`)

A YLOS lives in an old-gen cell but counts as young (HEAP_062). It is never copied. The first
worker to reach it in a minor takes `ylos_mu_`, and inside that one critical section:
- tests and sets the object's colour to this minor's colour ("reached");
- then either promotes it in place (age ≥ promotion age, not a builder) or increments its age.

After unlocking, it pushes the object as an entry, so it is scanned in place. A second worker
reaching it sees the colour already set and does nothing. If the colour test and set were split
across the lock, two workers could both "reach" it: two promotions, two pushes, and two scanners
writing its slots. That is mutant `ylos_unlocked`.

### 3.7 The minor's outer shape (`minorGCParallel`, `NurseryParallel.cpp:621-873`)

1. The pre-drain sweep slice (`:644`); M4 covers that.
2. To-space and promotion context set up (`:663`).
3. **Roots, serially on worker 0** (`:669-725`): root sets, stack-map slots, JIT roots, root ranges
   and external scanners, all through `evacuateP`.
4. **Distribution** of worker 0's greys round-robin into every worker's deque (`:727-736`).
5. **The drain** on the gang (`:738-763`): `runMarkerLoop` with `MinorEnv` (M2), then a fatal
   check that no work is left.
6. **LABs closed** (`:765-779`): single-threaded, after the join. The top LAB is trimmed and other
   tails become fillers.
7. Merge counters in worker order, then run the deferred large-body work (`:781-830`).
8. Validate builds run PM1/PM2/PM3 over to-space (`:845-873`).

Steps 1, 2 and 6–8 are single-threaded. M3 models steps 3–5. The gang start between step 4 and
step 5 is a mutex release/acquire (M6's LaunchJoin contract).

### 3.8 The region minor (7b), and what differs

`evacuateR` (`NurseryRegion.cpp:429-490`) classifies every target by its **role** (primer
glossary):
- **Eden / PrevBuilders:** the same claim / copy / publish loop as `evacuateP`
  (`NurseryRegion.cpp:450-464`). `copyClaimedR` (`:372-427`) never promotes: an object with
  `age != 0` is fatal (TV9), survivors get age 1, builders go to the fill's top-down builder area.
- **Hand** (last minor's fill, being handed over): **not copied and not loaded**. The slot is
  *recorded*: into the heal list H when the parent is a survivor copy or a young YLOS, otherwise
  into the start set S. That is the 7c job's input, and M5 checks its completeness.
- **Retire** (the extent tenured last epoch): the slot is **resolved** through the extent's shadow
  table (`resolveRetire`, `:352-370`). The 7c job has been joined and merged by then, so the shadow
  is immutable.
- **Age** (07b ageing): recorded as a mark source (M5).
- **Fill:** already a copy.

M3's `Mode = "region"` configuration covers the parts that concern the claim protocol and the
pause's own writes:
- the claim / copy / publish loop with no promotion;
- Hand slots recorded rather than copied;
- Retire slots resolved to their tenured copy.

Recording *completeness* against the job, and the Age role, belong to M5.

## 4. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| header word constants, `fwdWord` | `MinorWork.hpp:33-46` | `hdr[o] ∈ {"H", "BUSY"} ∪ CopyIds` |
| `loadHeader` / `claim` / `publish` / `waitPublished` | `MinorWork.hpp:51-75` | `E_Load`, `E_Claim` / `S_Claim`, `C_Pub`, `E_Wait` / `S_Wait` |
| `tospaceClaim` / `tospaceClaimLab` / `labAllocate` | `MinorWork.hpp:152-207` | `C_Alloc` (`nextCopy`: a fresh, disjoint address) |
| `closeLabs`, fillers (`writeFiller`) | `MinorWork.hpp:215-239`, `NurseryParallel.cpp:103-108` | not modelled (single-threaded, after the join; PM3 checks it) |
| `evacuateP` | `NurseryParallel.cpp:315-345` | procedure `Evacuate` |
| `copyClaimed` | `NurseryParallel.cpp:250-313` | procedure `Copy` |
| `reachYoungLargeP` | `NurseryParallel.cpp:359-391` | procedure `ReachYlos` |
| `spineRunP` | `NurseryParallel.cpp:397-442` | procedure `SpineRun` |
| `scanEntryP` (per-tag slot walk; chunk entries) | `NurseryParallel.cpp:444-591` | procedure `Scan` (chunk entries not modelled; §5.1) |
| `minorGCParallel` steps 3–5 | `NurseryParallel.cpp:669-763` | `W_Roots`, `W_Start`, `W_Loop` |
| `pushGreyP` / `publishHalfP` / `publishAllP`, `MinorEnv` | `NurseryParallel.cpp:114-188` | the `grey` set (M2 models these) |
| `evacuateR`, `copyClaimedR`, `spineRunR`, `reachYoungLargeR`, `resolveRetire` | `NurseryRegion.cpp:352-578` | `Mode = "region"` branches of `Evacuate` / `Copy` |
| PM1 / PM2 / PM3 (legacy), region PM1–PM3 | `NurseryParallel.cpp:845-873`, `NurseryRegion.cpp:967-1004` | `CopyOnce`, `AtJoin` |
| PM5 (old parent → promoted child) | `NurseryParallel.cpp:276-283, 373-374` | `AtJoin` (the PM5 conjunct) |
| negative-control hooks `test_minor_double_copy_every_`, `test_minor_skip_filler_` | `NurseryParallel.cpp:305-310, 770-772` | cf. mutants `copy_without_cas` (a real double copy) and PM3 (fillers, out of scope) |

**Deliberately outside M3:**
- the grey-set machinery (deques, stealing, tickets, termination): M2, assumed here as the Drain
  contract;
- promotion allocation, the chunked shared blocks, the stash and the sweep inside the ladder: M4;
- the 7c job and the recording completeness of H and S: M5;
- the gang's start and join: M6;
- the release/acquire reasoning of publish and loadHeader under C11: W5.

## 5. The model

### 5.1 Abstractions, and why each is sound

| Real thing | Model | Why it is sound (or where it over-approximates) |
|---|---|---|
| Heap memory, tags, byte sizes | Object ids with a sequence of fields; "size" = number of fields | M3 is about which object is copied where, not bytes |
| Pointer values | Integers in disjoint ranges: from-space `FromIds`, copies `101..`, YLOS, old, Hand, Retire; `Nil = 0` | Membership tests (`isInFromSpace`, `mayBeYoungLarge`, `roleOf`) become set membership |
| The header word | `hdr[o] ∈ {"H", "BUSY"} ∪ CopyIds` | "H" stands for any unforwarded header. Colour is carried but irrelevant to the protocol |
| `labAllocate` / `allocatePromotion` | `C_Alloc` takes the next fresh id (one atomic step) | Only disjointness matters (`tospaceClaim` is a relaxed CAS on `top`). LAB internals are owner-only |
| The copy: `memcpy` body, then header | Two steps, `C_Body` and `C_Hdr`, before `C_Pub` | Faithful: the copy is private memory until published and pushed |
| The grey set: private stacks, deques, stealing, termination | One shared set `grey`; a worker takes any entry atomically and sets `busy`; the drain ends when `grey = {}` and nobody is busy | M2's **Drain** contract: every pushed entry is scanned exactly once, and the run ends only when no work is left |
| Chunk entries for arrays over 1,024 elements | Not modelled | A chunk entry is an entry over a disjoint slot range of one object. Ownership is per range and nothing else changes. Add a two-chunk object if the implementer wants it (§11) |
| Promotion (age, pin, builder) | `promo[d] := Mode = "legacy" /\ Age[v] >= PromoAge /\ v \notin Builders` | Age is read from the saved header, which is immutable |
| The PM5 premise (a promoted parent's children are at least as old) | Built into the example heap's ages | The premise comes from generational ageing plus HEAP_005 and P1 (M1's territory). M3 checks that the protocol keeps it |
| `ylos_mu_` critical section | One step (`Y_Lock`), plus a separate promotion step and a push step | Only the colour test-and-set must be indivisible. Promotion touches only the winner's object |
| Region `resolveRetire` | `RetireFwd` constant map | The shadow is immutable in the pause (the job was merged at this minor's start) |

**Slot ownership (a ghost rule).** `owner[o]` is the worker allowed to write `o`'s slots:
- the worker that took `o` from the grey set;
- for an unpushed spine-run cell, the worker whose run copied it;
- for a pushed object, nobody (`Nil`) until someone takes it.

`Evacuate` asserts `owner[eo] = self` before touching a slot. That is the model's form of
"slots written are owner-only" (the phase 6 plan's premise that makes plain slot stores race-free).

### 5.2 Constants

| Constant | Meaning | Code value | Model values |
|---|---|---|---|
| `Workers`, `W0` | worker ids; `W0` is the paused mutator | 1..N, worker 0 | `{1, 2}` (deep: `{1, 2, 3}`), `W0 = 1` |
| `FromIds`, `ConsIds` | from-space objects; the Cons subset | eden / from-space | `1..6`, `{3, 4, 5}` |
| `YlosIds`, `OldIds` | young large objects; old-gen leaves | YLOS index; old gen | `{7}`, `{9}` |
| `HandIds`, `RetireIds`, `RetireFwd` | region roles | 7b extents | `{}` (legacy); `{11}`, `{12}`, `12 → 9` (region) |
| `InitFields`, `InitRoots` | the heap before the minor | — | §7 |
| `Age`, `Builders`, `PromoAge` | promotion inputs | header age, builder bit, `promotion_age` | §7 |
| `Mode` | `"legacy"` or `"region"` | `nursery_regions` | both |
| `MaxRun` | spine run length | `MINOR_SPINE_RUN = 512` | 2 (so a 3-cell spine is truncated once) |
| `MUTANT` | negative-control selector | — | `"none"` or a §6 name |

### 5.3 Variables

| Variable | Meaning | Code counterpart | Written by |
|---|---|---|---|
| `hdr[o]` | from-space header word | the object's first word (`headerRef`) | claim (CAS), publish (store) |
| `fld[o]` | an object's slots | the object's fields | copies: the owner; from-space: never (immutable) |
| `roots` | root slots | stack maps, RootSet, external scanners | worker 0, before the gang |
| `origin[d]`, `whole[d]` | ghost: a copy's original; body and header copied | — | the copier |
| `promo[d]` | the copy went to the old gen | `shouldPromote` | the copier |
| `nextCopy` | allocation frontier | to-space `top` / promotion cursors | the copier (atomic) |
| `grey`, `busy[w]`, `started` | Drain contract; gang start | deques and private stacks; `GCMarkGang::run` | workers; worker 0 |
| `owner[o]` | ghost: who may write `o`'s slots | the owner-only discipline | taking an entry, run links, pushes |
| `yReached`, `yPromoted`, `yPushes` | YLOS colour, promotion, ghost push count | `LargeBodyMeta::color`, `promoteYoungLarge` | under `ylos_mu_` |
| `recorded` | region: slots recorded into H / S | `rw.H`, `rw.S` | the pause (per-worker lists, merged later) |
| `res[w]` | procedure result | the return value of `copyClaimed` | `Copy` |

### 5.4 Steps: model labels to code lines

| Label | Code | Atomic operation it stands for |
|---|---|---|
| `W_Roots`, `W_RootLoop` | `NurseryParallel.cpp:669-725` | worker 0 evacuates each root slot, alone |
| `W_Start` | `GCMarkGang::run` (`GCHelperPool.cpp:407`) | the gang start (mutex release/acquire) |
| `W_Loop` (take) | `takeOwn` / `steal` (M2) | atomic removal of one grey entry |
| `SC_Loop` | `scanEntryP` `:444-591` | one slot per iteration |
| `E_Read`, `E_Kind` | `evacuateP` `:316-331` (filters) | read the owner's own slot; classify the target |
| `E_Load` | `:332` | `loadHeader` (acquire) |
| `E_Wait` | `:335`, `waitPublishedP` `:245` | re-load until not BUSY |
| `E_Claim` | `:339` | `claim`: CAS header → BUSY |
| `C_Alloc` | `copyClaimed` `:255-298` | size from the saved header; promote/survive; `allocatePromotion` or `labAllocate` |
| `C_Body`, `C_Hdr` | `:301-304` | `memcpy` body; `memcpy` fixed-up header |
| `C_Pub` | `:311` | `publish` (release store of the forward word) |
| `E_Slot` | `:343-344` | `slot = dst`; push if it has children |
| `S_Loop` … `S_Link` | `spineRunP` `:401-429` | per cell: load, maybe wait, claim, copy, link |
| `S_HeadLoop` | `:431-441` | the counted heads pass |
| `Y_Lock`, `Y_Promote`, `Y_Push` | `reachYoungLargeP` `:361-390` | the `ylos_mu_` section; the push after unlocking |

### 5.5 The PlusCal sketch

File: `test/tla/M3-minor-forwarding/MinorForwarding.tla`. This is the text that passed the
translator and SANY; the generated translation is omitted.

```tla
--------------------------- MODULE MinorForwarding ---------------------------
(***************************************************************************)
(* M3: the parallel minor's claim -> BUSY -> publish protocol on from-space *)
(* header words (runtime/src/allocator/MinorWork.hpp, NurseryParallel.cpp,  *)
(* NurseryRegion.cpp). Work distribution is M2's Drain contract: a shared  *)
(* bag of grey entries with atomic take, and termination when the bag is   *)
(* empty and nobody is scanning.                                            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Workers,          \* worker ids; W0 is the paused mutator (worker 0)
    W0,
    FromIds,          \* from-space (eden) objects: claimed and copied
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
    MUTANT

Nil == 0
NCopy == 2 * Cardinality(FromIds)          \* room for double copies (mutants)
CopyIds == 101..(100 + NCopy)
ObjIds == FromIds \cup YlosIds \cup CopyIds
IsFrom(v) == v \in FromIds

(* --algorithm MinorForwarding
variables
    hdr     = [o \in FromIds |-> "H"],        \* header word: "H" | "BUSY" | a copy id (FWD)
    fld     = [o \in ObjIds |-> IF o \in FromIds \cup YlosIds THEN InitFields[o] ELSE <<>>],
    roots   = InitRoots,                      \* root slots (worker 0 only, before the gang)
    origin  = [d \in CopyIds |-> Nil],        \* ghost: the original of each copy
    whole   = [d \in CopyIds |-> FALSE],      \* ghost: body and header copied
    promo   = [d \in CopyIds |-> FALSE],      \* the copy went to the old gen
    nextCopy = 101,                           \* to-space / promotion allocation (atomic claim)
    grey    = {},                             \* the grey set (M2's Drain contract)
    owner   = [o \in CopyIds \cup YlosIds |-> Nil],   \* who may write this object's slots
    busy    = [w \in Workers |-> FALSE],
    started = FALSE,                          \* the gang start (GCMarkGang::run)
    yReached = [y \in YlosIds |-> FALSE],     \* m->color == minor_color_
    yPromoted = [y \in YlosIds |-> FALSE],    \* promoteYoungLarge
    yPushes = [y \in YlosIds |-> 0],          \* ghost
    recorded = {},                            \* region: slots recorded into H / S
    res     = [w \in Workers |-> Nil];        \* procedure result (PlusCal has no return value)

define
    SlotVal(o, i) == IF o = Nil THEN roots[i] ELSE fld[o][i]
    Copies == {d \in CopyIds : origin[d] # Nil}
    \* PM1: a from-space object is copied at most once.
    CopyOnce == \A o \in FromIds : Cardinality({d \in Copies : origin[d] = o}) <= 1
    \* A published forward names a complete copy (the design rule behind the
    \* release store in mw::publish; no in-drain reader depends on it today).
    FwdComplete == \A o \in FromIds : hdr[o] \in CopyIds => whole[hdr[o]]
    \* The copy holds every field of the original (sized from the SAVED header).
    SizeFaithful == \A d \in Copies : whole[d] => Len(fld[d]) = Len(fld[origin[d]])
    \* Each young large object is reached (and pushed) at most once per minor.
    YlosOnce == \A y \in YlosIds : yPushes[y] <= 1
end define;

\* Write a slot of object o (Nil = a root slot).
macro WriteSlot(o, i, val) begin
    if o = Nil then roots[i] := val; else fld[o][i] := val; end if;
end macro;

\* reachYoungLargeP: one ylos_mu_ critical section, then the push.
procedure ReachYlos(yy)
begin
  Y_Lock:
    if MUTANT = "ylos_unlocked" then
        if yReached[yy] then return; end if;  \* the colour test outside the mutex ...
      Y_Set:
        yReached[yy] := TRUE;                 \* ... and the set in a later step
    elsif yReached[yy] then
        return;                              \* already reached this minor
    else
        yReached[yy] := TRUE;                 \* test-and-set under ylos_mu_
    end if;
  Y_Promote:
    yPromoted[yy] := (Mode = "legacy" /\ Age[yy] >= PromoAge /\ yy \notin Builders);
  Y_Push:
    grey := grey \cup {yy};
    owner[yy] := Nil;
    yPushes[yy] := yPushes[yy] + 1;
    return;
end procedure;

\* copyClaimed: the caller holds the claim (hdr[cv] = "BUSY"). Sets res[self].
procedure Copy(cv)
variables cd = Nil, csz = 0;
begin
  C_Alloc:                                   \* allocatePromotion / labAllocate
    cd := nextCopy;
    nextCopy := nextCopy + 1;
    origin[cd] := cv;
    promo[cd] := (Mode = "legacy" /\ Age[cv] >= PromoAge /\ cv \notin Builders);
    csz := IF MUTANT = "size_from_busy" /\ hdr[cv] = "BUSY" THEN 0 ELSE Len(fld[cv]);
    if MUTANT = "publish_early" then hdr[cv] := cd; end if;
  C_Body:                                    \* memcpy of the body (from-space is immutable)
    fld[cd] := SubSeq(fld[cv], 1, csz);
  C_Hdr:                                     \* memcpy of the fixed-up header word
    whole[cd] := TRUE;
  C_Pub:                                     \* mw::publish: release store of FWD(cd)
    if MUTANT # "publish_early" then hdr[cv] := cd; end if;
    res[self] := cd;
    return;
end procedure;

\* evacuateP(w, slot): slot = (eo, ei), eo = Nil for a root slot.
procedure Evacuate(eo, ei)
variables ev = Nil, ehw = "H";
begin
  E_Read:
    assert eo = Nil \/ owner[eo] = self;     \* slot writes are owner-only
    ev := SlotVal(eo, ei);
  E_Kind:                                         \* (a separate step: `return` resets ev)
    if ev \in YlosIds then
        call ReachYlos(ev);
        return;
    elsif Mode = "region" /\ ev \in HandIds then
        recorded := recorded \cup {<<eo, ei>>};   \* rw.H / rw.S: no header load
        return;
    elsif Mode = "region" /\ ev \in RetireIds then
        WriteSlot(eo, ei, RetireFwd[ev]);          \* resolveRetire via the shadow
        return;
    elsif ~IsFrom(ev) then
        return;                                   \* old, permanent, constant, Nil
    end if;
  E_Load:
    ehw := hdr[ev];                                 \* mw::loadHeader (acquire)
  E_Loop:
    while TRUE do
        if ehw = "BUSY" then
            if MUTANT = "no_wait" then
                WriteSlot(eo, ei, Nil);           \* fwdAddr(BUSY) = address 0
                return;
            end if;
          E_Wait:                                 \* waitPublishedP
            await hdr[ev] # "BUSY";
            ehw := hdr[ev];
        elsif ehw \in CopyIds then                 \* forwarded: take the copy
            WriteSlot(eo, ei, ehw);
            return;
        else
          E_Claim:                                \* mw::claim: CAS header -> BUSY
            if MUTANT = "copy_without_cas" \/ hdr[ev] = ehw then
                hdr[ev] := "BUSY";
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
    return;
end procedure;

\* spineRunP(w, prev): tenure the tail spine cell by cell (no pushes), then
\* one heads pass over the COUNTED run (never "while still in to-space").
procedure SpineRun(sp0)
variables sprev = Nil, st = Nil, shw = "H", sk = 0, srun = <<>>, strunc = FALSE,
          sm = 0, sj = 0, swalk = Nil;
begin
  S_Init:
    sprev := sp0;
  S_Loop:
    while TRUE do
        st := fld[sprev][2];                        \* sprev->tail
        if ~IsFrom(st) \/ st \notin ConsIds then
            call Evacuate(sprev, 2);               \* not a from-space Cons: plain evacuate
            goto S_Heads;
        end if;
      S_Load:
        shw := hdr[st];
        if shw = "BUSY" then
          S_Wait:
            await hdr[st] # "BUSY";
            fld[sprev][2] := hdr[st];               \* another worker's copy: end the run
            goto S_Heads;
        elsif shw \in CopyIds then
            fld[sprev][2] := shw;
            goto S_Heads;
        elsif sk = MaxRun then                     \* bounded run: push the last copy
            grey := grey \cup {sprev};
            owner[sprev] := Nil;
            strunc := TRUE;
            goto S_Heads;
        end if;
      S_Claim:                                    \* mw::claim on the tail cell
        if hdr[st] = shw then
            hdr[st] := "BUSY";
        else
            goto S_Loop;                          \* claim race: re-read the tail
        end if;
      S_Copy:
        call Copy(st);
      S_Link:
        fld[sprev][2] := res[self];                \* sprev->tail = copy
        owner[res[self]] := self;                 \* an unpushed run cell: ours
        srun := Append(srun, res[self]);
        sprev := res[self];
        sk := sk + 1;
    end while;
  S_Heads:
    if MUTANT = "heads_walk" then
        \* the rejected form: follow tails while the cell is a copy
        if srun # <<>> then swalk := srun[1]; end if;
      S_Walk:
        while swalk \in CopyIds do
            call Evacuate(swalk, 1);
          S_WalkNext:
            swalk := IF Len(fld[swalk]) >= 2 THEN fld[swalk][2] ELSE Nil;
        end while;
    else
        sm := IF strunc THEN sk - 1 ELSE sk;          \* a pushed last cell does its own head
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

\* scanEntryP: every boxed slot of the entry; a Cons tail goes to the spine run.
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
\* END TRANSLATION

-----------------------------------------------------------------------------
AllDone == \A w \in Workers : pc[w] = "Done"
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

\* At the join (every worker exited):
\*  - no BUSY word is left (HEAP_006 / HEAP_067);
\*  - every reachable from-space object was forwarded;
\*  - CopyOnce contract + PM2: every live slot holds exactly the copy its old
\*    target's header forwards to (never a from-space address, never 0 from BUSY);
\*  - PM5: no promoted object points at a young (surviving) copy;
\*  - region: every slot pointing into Hand was recorded.
AtJoin ==
    AllDone =>
        /\ \A o \in FromIds : hdr[o] # "BUSY"
        /\ \A o \in Reachable \cap FromIds : hdr[o] \in CopyIds
        /\ \A sl \in LiveSlots : SlotVal(sl[1], sl[2]) = Expected(OrigVal(sl[1], sl[2]))
        /\ \A sl \in LiveSlots :
               (sl[1] # Nil /\ Old(sl[1]) /\ SlotVal(sl[1], sl[2]) \in CopyIds)
                   => promo[SlotVal(sl[1], sl[2])]
        /\ \A sl \in LiveSlots : (SlotVal(sl[1], sl[2]) \in HandIds) => sl \in recorded
=============================================================================
```

`MC.tla` (the example heap):

```tla
---- MODULE MC ----
EXTENDS MinorForwarding
\* From-space: 1 = Tuple(2, 7)   (promotes; its children must promote too)
\*             2 = leaf -> old 9 (promotes; shared by 1, 3 and 5)
\*             3 = Cons(2, 4), 4 = Cons(Nil, 5), 5 = Cons(1, Nil)  (a 3-cell spine)
\*             6 = garbage
\* YLOS 7 = [2]; old 9.  Roots: <<1, 3>>.
MC_FromIds == 1..6
MC_ConsIds == {3, 4, 5}
MC_YlosIds == {7}
MC_OldIds == {9}
MC_Fields == (1 :> <<2, 7>>) @@ (2 :> <<9>>) @@ (3 :> <<2, 4>>) @@ (4 :> <<0, 5>>)
             @@ (5 :> <<1, 0>>) @@ (6 :> <<3>>) @@ (7 :> <<2>>)
MC_Roots == <<1, 3>>
MC_Age == (1 :> 1) @@ (2 :> 1) @@ (3 :> 0) @@ (4 :> 0) @@ (5 :> 0) @@ (6 :> 0) @@ (7 :> 1)
\* region variant: 11 in Hand, 12 in Retire (tenured to old 9)
MC_RegionFields == (1 :> <<2, 11>>) @@ (2 :> <<12>>) @@ (3 :> <<2, 4>>) @@ (4 :> <<0, 5>>)
                   @@ (5 :> <<1, 0>>) @@ (6 :> <<3>>) @@ (7 :> <<2>>)
MC_RetireFwd == (12 :> 9)
====
```

The example heap exercises, with two workers:
- a shared leaf (`2`, reached from `1`, `3` and `7`);
- a 3-cell spine (`3 → 4 → 5`) that `MaxRun = 2` truncates once;
- a back-pointer from young to old (`5.head → 1`, promoted);
- a promoted parent whose children must promote (`1 → 2`, `1 → 7`);
- a YLOS reached from a promoted parent and pointing back into from-space;
- an old leaf (`9`) and a garbage object (`6`).

### 5.6 The properties, explained

| Property | Kind | What it says | What a violation looks like |
|---|---|---|---|
| `CopyOnce` | invariant | no from-space object has two copies (PM1) | two workers both think they claimed `S` (mutant `copy_without_cas`) |
| `FwdComplete` | invariant | a forward word names a complete copy | forward published before the body or header was copied (mutant `publish_early`) |
| `SizeFaithful` | invariant | a complete copy has all the original's fields | size read from BUSY (mutant `size_from_busy`) |
| `YlosOnce` | invariant | each YLOS is pushed at most once | colour test outside the mutex (mutant `ylos_unlocked`) |
| owner assertion in `E_Read` | assertion | only an object's owner writes its slots | the heads pass walking into another worker's cells (mutant `heads_walk`) |
| `AtJoin` | invariant (checked once all workers exited) | no BUSY left; every reachable from-space object forwarded; **every live slot holds exactly `Expected(OrigVal(slot))`**, i.e. the copy its old target's header names (the CopyOnce contract, PM2) or the tenured copy of a Retire object; PM5; region Hand slots recorded | a slot left at 0 because BUSY was read as an address (mutant `no_wait`); a slot still pointing into from-space |

**About `FwdComplete`.** No reader *during* the drain reads through a forward word. Readers only
store the address; a copy's contents are read only by its scanner, after the copier pushed it (the
06 plan's trap 2). So `publish_early` would do no visible harm in today's code. `FwdComplete`
records the design rule that the release store exists to support. It makes any future reader that
follows a forward during the drain safe by construction. The plan keeps it as a model invariant and
a mutant, and MAPPING.md says plainly that it guards a rule, not an observed reader.

**No liveness property.** Liveness of the drain is M2's (`AllExit`). M3 adds only the BUSY wait,
which ends because a claimant always publishes. Weak fairness on workers suffices, and the
implementer may add `<>AllDone` as a `PROPERTY` in a deep configuration.

## 6. Negative controls (mutants)

All are implemented in the sketch.

| `MUTANT` | Code change it represents | Must violate | Story |
|---|---|---|---|
| `copy_without_cas` | claim by plain store instead of CAS | `CopyOnce` | A and B both read H, both "claim", both copy: two copies of `S`, and slots split between them. The code's own hook `test_minor_double_copy_every_` makes an uncounted second copy for PM1; this mutant is the protocol-level form |
| `size_from_busy` | `getObjectSize(obj)` instead of the saved header (`:255`) | `SizeFaithful` | §3.4 |
| `publish_early` | `publish` before the `memcpy`s | `FwdComplete` | a forward names a copy with no fields yet |
| `no_wait` | treat BUSY like a forward word (skip `waitPublished`) | `AtJoin` | `fwdAddr(BUSY)` is address 0: the slot becomes null and the live object is lost from that slot |
| `heads_walk` | heads pass that follows tails "while in to-space" instead of counting | owner assertion | §3.5, row 3′; also double-scans a truncated run's pushed last cell |
| `ylos_unlocked` | YLOS colour test and set in separate critical sections | `YlosOnce` | two workers both reach the YLOS: two promotions, two pushes, two scanners |

**Not a mutant: fillers.** `test_minor_skip_filler_` skips one filler write in `closeLabs` and PM3
must fire. That is single-threaded, after the join, so it is out of M3's scope, and the PM3
validator already guards it.

## 7. Configurations

| Config | What it models | Key constants | Tier | Expected |
|---|---|---|---|---|
| `legacy` | phase 6, two workers | `Workers = {1,2}`, `Mode = "legacy"`, `MaxRun = 2`, the §5.5 heap | quick | pass |
| `region` | 7b region minor | `Mode = "region"`, `InitFields <- MC_RegionFields`, `HandIds = {11}`, `RetireIds = {12}`, `RetireFwd <- MC_RetireFwd`, promotion off by mode | quick | pass |
| `legacy3` | three workers | `Workers = {1,2,3}` | deep | pass |
| `mut_<name>` | each §6 mutant | `legacy` + `MUTANT = "<name>"` | quick | the named property fails |

Every configuration sets `defaultInitValue = defaultInitValue` (primer §2 rule 3) and checks
`INVARIANTS CopyOnce FwdComplete SizeFaithful YlosOnce AtJoin`. The owner assertion is always
active.

**Size guidance.** No run yet; this is an estimate. The heap has six from-space objects, and the
root phase is serial, so interleavings start only at the drain. Expect the `legacy` quick
configuration to be in the low millions of states. If it is larger:
1. first drop the YLOS (`YlosIds = {}`, change `1`'s fields to `<<2>>`);
2. then shorten the spine to two cells with `MaxRun = 1`.

Do not raise worker counts in the quick tier.

## 8. Accuracy notes (parent plan rules A1–A9)

| Rule | M3 |
|---|---|
| A1 | Each label is one atomic operation on shared memory, or one owner-only change (§5.4). The claim is a CAS step that compares the observed word. The copy is split into allocation, body, header and publish. The YLOS test-and-set is one mutex step. |
| A2 | The header is one 64-bit word updated only by the CAS and the release store. The model has no sub-word writes to it (colour lives inside the forward word). Slots are whole 8-byte words, written only by their owner. |
| A3 | 06 P§3.11 rows for the drain: from-space headers (CAS / store), to-space `top` (relaxed CAS), LABs (owner), grey stacks and deques (Drain contract), `ylos_mu_` + YLOS index/colour, per-worker `lb_promoted`/`lb_seen` (owner, merged after the join: not modelled), the YLOS bounding box (read-only during the drain). Region: `rw.S`/`rw.H` (per-worker, merged after the join), `bld_bottom` (atomic `fetch_sub`, a separate disjointness question not modelled; see §11), the shadow (read-only in the pause). |
| A4 | W5 checks that publish (release) / loadHeader (acquire) and the deque's release/acquire element transfer make a copy's contents visible to its scanner. M3 assumes it. |
| A5 | `gc-minor-tsan` trace (§9). |
| A6 | §6. |
| A7 | `CopyOnce` = PM1 / HEAP_067 "copied exactly once"; `AtJoin` = PM2 + HEAP_006 (no BUSY after the pause) + PM5 (HEAP_005); `SizeFaithful` = HEAP_067 "sizes the object from the SAVED header"; region conjuncts = HEAP_069 recording and resolution. |
| A8 | 2 workers (3 deep), 6 from-space objects, a 3-cell spine with `MaxRun = 2` (so both a normal and a truncated run occur), one YLOS. Copy ids are capped at twice the from-space size so double-copy mutants can run. |
| A9 | `file`: `MinorWork.hpp`. `region`: `evacuateP`, `copyClaimed`, `spineRunP`, `reachYoungLargeP`, `scanEntryP`, `minorGCParallel` steps 3–5 (`NurseryParallel.cpp:250-763`); `evacuateR`, `copyClaimedR`, `spineRunR`, `reachYoungLargeR`, `resolveRetire` (`NurseryRegion.cpp:352-578`). `census`: `NurseryParallel.cpp`, `NurseryRegion.cpp`. |

**Relation to CR-011** (register). `MinorWork.hpp` builds forward and BUSY words from its own bit
constants. Only the tag is pinned against `Heap.hpp`'s bitfields (`static_assert`,
`NurseryParallel.cpp:39`), and the runtime layout test its comment promises does not exist. M3
models the header word **abstractly** (`"H"`, `"BUSY"`, a copy id), so it cannot catch a layout
mismatch. A wrong bit position is a C++ encoding bug, not an interleaving. **M3 does not replace
that test.** CR-011's fix (compose with `mw::fwdWord`, decode through `Heap.hpp`'s `Forward`) is
still needed. M3's trace validation (§9) logs decoded addresses, so a layout mismatch would show up
there only as a rejected trace with a wrong address, which is a weak signal.

## 9. Trace validation

**Harness:** `test/gc-helper-tsan/minor_harness.cpp` (target `gc-minor-tsan`). It already runs the
real `MinorWork.hpp` claim/publish and LABs with the real `runMarkerLoop` over a synthetic heap:
count-based heads pass, chunks, a mutex-guarded promotion arena. Its objects map one-to-one onto
M3's ids (word 1 is the object id).

**Hooks.** `ECO_TLA_TRACE(...)` in `MinorWork.hpp`, compiled out unless `ECO_TLA_TRACE` is defined
(only the trace build of the harness). The harness's own evacuate and spine code carries the
remaining hooks. Each event records `{t: worker, ev, obj, ...}`, with object ids, not addresses:

| Event | Where | Extra fields |
|---|---|---|
| `load` | `loadHeader` (`MinorWork.hpp:54`) | `word` (`H`/`BUSY`/`FWD:<id>`) |
| `claim` | `claim` (`:58`) | `ok`, `observed` |
| `wait` | `waitPublished` exit (`:72`) | `word` |
| `copy` | harness `copyClaimed` analogue, after the allocation | `dst`, `promote` |
| `publish` | `publish` (`:63`) | `dst` |
| `slot` | after the slot store in evacuate | `parent`, `idx`, `value` |
| `run` / `heads` | spine run link; heads-pass entry | `prev`, `cell`, `k`; `m` |
| `ylos` | inside the mutex section | `obj`, `won`, `promoted` |
| `take` | M2's `take`/`steal` events (shared hook) | `e` |

**Ordering.** Each header word's events (load, claim, wait, publish) are totally ordered per object
by the values they observe: a successful claim reads H and writes BUSY, and publish writes
FWD:<id>. The merger orders events per object, then interleaves objects consistently with each
thread's sequence numbers.

**Trace spec.** `TraceMinorForwarding.tla` extends `MinorForwarding`. `TraceNext` matches event *i*
to the step with the same worker and label and the same observed values, and allows unlogged
owner-only steps in between. As in M2 §8, a rejected trace is either a code bug (register) or a
model error (AUDIT.md).

Production code is untouched: the hooks compile to nothing, and `out.mlir` and all counters are
unchanged.

## 10. Implementation steps

1. Create `test/tla/M3-minor-forwarding/` with `MinorForwarding.tla` (§5.5), `MC.tla`, the §7
   configurations, MAPPING.md (§5.4 table plus A3's rows) and AUDIT.md.
2. `pcal` + `sany` (already clean in the sketch), then TLC on `legacy` and `region`. Apply §7's
   size guidance if a quick configuration exceeds about 2 minutes.
3. Run every mutant. Confirm each fails with its named property; for `heads_walk`, the named
   assertion. Record the counterexample traces in MAPPING.md.
4. Wire into `models.txt` and `test/tla/manifest.txt` (A9's lines).
5. Trace validation (§9) on `gc-minor-tsan`: hooks, merger, trace spec, one CI-sized run.
6. Close-out: AUDIT.md first entry; the parent plan's §11 row.

## 11. Open questions for the implementer

1. **Chunk entries.** Arrays and ListBackings over 1,024 elements are scanned as chunk entries by
   different workers (`scanEntryP` `:521-563`). Each chunk writes only its own slot range, so
   "owner" becomes per range. Worth a two-chunk object in a deep configuration if the owner rule is
   to cover it.
2. **The region builder area.** Builders are bump-allocated *downwards* from the fill's end with an
   atomic `fetch_sub` on `bld_bottom` (`NurseryRegion.cpp:384-386`), while survivors come up from
   the base through LABs. The two must not meet ("the fill's builder area overflowed" is fatal).
   That is a space bound, not an interleaving question, and is not in M3. If it ever matters, model
   the two frontiers as integers.
3. **PM5 in region mode.** The region minor never promotes, so PM5 is vacuous there. Its
   counterpart (a tenured copy never points young) is TV6, checked by M5.
