# Threaded GC — TLA+ model M3: parallel minor forwarding (claim, copy, publish)

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). Had an adversarial review on 2026-09-28 against
the current tree (§12): the example heap, `MaxRun`, two mutants, the owner check and the copy ids
were corrected, and the revised sketch passes the translator and SANY. TLC has not run.

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

Which one runs today: `NURSERY_REGIONS = 2` (auto, `AllocatorCommon.hpp:263`) picks the region
minor whenever the config allows it, and `PROMOTION_AGE = 1` (`:152`) makes the tenure age k = 1.
So the **default** is the region minor with k = 1: Hand is the last minor's fill, PrevBuilders is
its builder area, and there is no Age role. The legacy minor runs when a config sets
`nursery_regions = 0` (as the legacy `gc-heap-tsan` scenarios do), or when auto finds the config
incompatible (`regionIncompatibility`, `AllocatorCommon.hpp:915`, resolved at `:950`).

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

**Transitions, and what a loser does.** Inside the drain the word has exactly two transitions:
unforwarded → BUSY (the claim CAS) and BUSY → forwarded (publish). Nothing writes it back. The
claim is `compare_exchange_strong`, so it fails only when the word really changed, and the
observed word is then BUSY or forwarded. A loser never retries the CAS against BUSY:
- `evacuateP` / `evacuateR` loop on the observed word: BUSY → `waitPublishedP` (spin with
  `markwork::backoff`), forwarded → store the address in the slot;
- `spineRunP` / `spineRunR` `continue`: they re-read their own `prev->tail` and re-load the header.

Nobody helps a claimant, and nobody reads a copy before its publish. Other workers learn the copy's
address only from the forward word, and they only store it. The copy's contents are read only by
its copier, or by whoever takes it as a grey entry after the copier pushed it.

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

Mutant `heads_walk` is row 3′ (rule 1 broken, rule 2 kept). Mutant `heads_all` breaks rule 2
only: it counts all `k` cells even when the run was truncated.

Each cell of a run is its own claim, copy and publish. A run never holds two BUSY words at once,
and the model has a label at every one of these steps (`S_Load` … `S_Link`), so no intermediate
state is hidden.

### 3.6 Young large objects (`reachYoungLargeP`, `NurseryParallel.cpp:359-391`)

A YLOS lives in an old-gen cell but counts as young (HEAP_062). It is never copied. The first
worker to reach it in a minor takes `ylos_mu_`, and inside that one critical section:
- tests and sets the object's colour to this minor's colour ("reached");
- then either promotes it in place (age ≥ promotion age, not a builder) or increments its age.

After unlocking, it pushes the object as an entry, so it is scanned in place. A second worker
reaching it sees the colour already set and does nothing. If the colour test and set were split
across the lock, two workers could both "reach" it: two promotions, two pushes, and two scanners
writing its slots. That is mutant `ylos_unlocked`.

The filter before the lock, `mayBeYoungLarge` (`OldGenSpace.hpp:1184-1186`), reads the bounding
box `ylo_lo_`/`ylo_hi_` without the lock. Nothing writes the box during the drain:
`promoteYoungLarge` leaves it conservative until the minor-end recompute (`OldGenSpace.cpp:7123-7124`).
Inside the lock, `youngLargeMeta` looks the object up in `large_body_index_`, and
`promoteYoungLarge` (`OldGenSpace.cpp:7107-7129`) erases from that index and from
`nursery_owned_bodies_`. So `ylos_mu_` protects the index only if nothing else writes it during the
drain. In the region minor nothing does. In the legacy minor it holds except on CR-014's path (§8, A3).

`reachYoungLargeR` (`NurseryRegion.cpp:492-532`) has three branches under the same lock:
- a hand-over member (`R.hand_ylos`): its own reached flag `hand_ylos_reached[k]`, then a push;
- an ageing member (07b, k ≥ 2 only): recorded in `SA`, not pushed;
- otherwise the colour test above, with age 1 instead of promotion (the region pause never
  promotes).

The model has one reached flag per YLOS. That flag stands for the colour and for
`hand_ylos_reached`, because both are a test-and-set in one `ylos_mu_` section.

### 3.7 The minor's outer shape (`minorGCParallel`, `NurseryParallel.cpp:621-889`)

1. The pre-drain sweep slice (`:644-658`); M4 covers that.
2. To-space and promotion context set up (`:663-667`).
3. **Roots, serially on worker 0** (`:669-725`): root sets, stack-map slots, JIT roots, root ranges
   and external scanners, all through `evacuateP`.
4. **Distribution** of worker 0's greys round-robin into every worker's deque (`:727-736`).
5. **The drain** (`:738-763`): `runMarkerLoop` with `MinorEnv` (M2) on the gang, or directly on
   the mutator when n = 1; then a fatal check that no work is left.
6. **LABs closed** (`:765-779`): single-threaded, after the join. The top LAB is trimmed and other
   tails become fillers.
7. Merge counters in worker order, then run the deferred large-body work (`:781-827`).
8. Validate builds run PM1/PM2/PM3 over to-space (`:844-875`).

Steps 1, 2 and 6–8 are single-threaded. M3 models steps 3–5. The gang start between step 4 and
step 5 is a mutex release/acquire (M6's LaunchJoin contract): `GCMarkGang::run` publishes under
`m_` and runs the mutator as member 0 (`GCHelperPool.cpp:407-431`).

**Nothing minor-specific runs outside the loop while workers run.** The roots are done before the
gang starts; the mutator's share is member 0's `runMarkerLoop`; every overflow is a fatal abort
(`tospaceOverflow`, a null `allocatePromotion`, the fill's builder overflow), not a recovery path.
So M2's **Drain** contract covers the whole concurrent part: M2's `minor` configuration is
`MinorEnv`/`RegionEnv` (deques-only `anyWork`, drain budget, no stop).

**Fillers during the drain.** `labAllocate` also writes fillers inside the drain: when a worker
retires a LAB with a short tail (`MinorWork.hpp:194-197`). The tail is in the worker's own LAB,
and no thread walks to-space or the fill until after the join (PM3, `regionEndMinorValidate`, the
next tenure job). So the filler is owner-only memory until the join publishes it, and the model
does not need it.

`minorGCRegion` (`NurseryRegion.cpp:650-1147`) has the same shape: beginMinor and the role table
(`:699-724`), hand-over preparation (`:726-765`), the worker count (`:767-779`), the pre-drain
sweep (`:797-802`), the fill's LABs (`:806-812`), roots (`:817-845`), distribution and drain
(`:853-884`), LABs closed (`:886-897`), then the merge. Before it, `ThreadLocalHeap::minorGC` joins
and merges the previous tenure job (`ThreadLocalHeap.cpp:722-733`, `tenureJoin`). That is why the
Retire extent's shadow is immutable during the drain.

### 3.8 The region minor (7b), and what differs

`evacuateR` (`NurseryRegion.cpp:429-490`) classifies every target by its **role** (primer
glossary):
- **Eden / PrevBuilders:** the same claim / copy / publish loop as `evacuateP`
  (`NurseryRegion.cpp:448-466`). `copyClaimedR` (`:372-427`) never promotes: an object with
  `age != 0` is fatal (TV9), survivors get age 1, builders go to the fill's top-down builder area.
- **Hand** (last minor's fill, being handed over): **not copied and not loaded**. The slot is
  *recorded*: into the heal list H when the parent is a survivor copy or a young YLOS, otherwise
  into the start set S. That is the 7c job's input, and M5 checks its completeness.
- **Retire** (the extent tenured last epoch): the slot is **resolved** through the extent's shadow
  table (`resolveRetire`, `:352-370`). The 7c job has been joined and merged by then, so the shadow
  is immutable.
- **Age** (07b ageing, k ≥ 2 only): recorded as a mark source (M5).
- **Fill:** already a copy. Only a root slot listed twice lands here (its second visit).
- **Stale** (and the between-minor roles): TV7, fatal in every build.

Other differences from phase 6 that touch forwarding:
- `spineRunR` (`:534-578`) also ends a run at a **builder** Cons, which `evacuateR` then copies
  into the builder area; run copies are always survivors.
- Allocation: survivors come up from the fill's base through LABs (`tospace_` reset to
  `[fill_base, fill_end)`, `:806-812`); builders come down from `fill_end` through
  `bld_bottom.fetch_sub` (`:385`). Each is a disjoint claim. That the two never meet is a space
  bound, checked after the join (`:894-896`); see §11.
- **The colour test.** `R.roleOf` (`NurseryRegions.hpp:215-224`) reads `role_of_k`, `prev_k`,
  `prev_bld_off`, the stride and `set.capacity`. They are plain fields, written by
  `rebuildRoles(true)` (`NurseryRegion.cpp:724`) before the drain and next by `checkAndGrow` and
  `rebuildRoles(false)` after it (`:1022`, `:1090`). The gang start publishes them. The legacy test
  `isInFromSpace` (`NurserySpace.hpp:387-394`) reads bounds that change only in `checkAndGrow`
  after the drain. Neither test reads the old gen's `region_base_`/`region_end_` (CR-009, W4), so
  M3 needs no W4 assumption: a stale or relaxed read cannot misclassify a pointer in either mode.

M3's `Mode = "region"` configuration covers the parts that concern the claim protocol and the
pause's own writes:
- the claim / copy / publish loop with no promotion;
- the YLOS colour branch, with age 1 instead of promotion (the example heap reaches YLOS `7`);
- Hand slots recorded rather than copied;
- Retire slots resolved to their tenured copy.

Not in the region configuration: PrevBuilders and builders (the same claim loop; only the
allocator differs), the hand-over YLOS branch (the same test-and-set shape, §3.6), and the split
of Hand slots between H and S (a per-entry colour, owner-only). Recording *completeness* against
the job, the H/S split, and the Age role belong to M5.

## 4. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| header word constants, `fwdWord` | `MinorWork.hpp:33-46` | `hdr[o] ∈ {"H", "BUSY"} ∪ CopyIds` |
| `loadHeader` / `claim` / `publish` / `waitPublished` | `MinorWork.hpp:51-75` | `E_Load`, `E_Claim` / `S_Claim`, `C_Pub`, `E_Wait` / `S_Wait` |
| `tospaceClaim` / `tospaceClaimLab` / `labAllocate` | `MinorWork.hpp:152-207` | `C_Alloc` (a fresh, canonical copy id: disjointness is all that matters) |
| LAB-retirement fillers inside the drain (`labAllocate`), `closeLabs`, `writeFiller` | `MinorWork.hpp:194-197`, `:215-239`, `NurseryParallel.cpp:103-108` | not modelled: owner-only until the join, and nothing walks to-space or the fill before it (§3.7); PM3 checks the result |
| `evacuateP` | `NurseryParallel.cpp:315-345` | procedure `Evacuate` |
| `copyClaimed` | `NurseryParallel.cpp:250-313` | procedure `Copy` |
| `reachYoungLargeP` | `NurseryParallel.cpp:359-391` | procedure `ReachYlos` |
| `spineRunP` | `NurseryParallel.cpp:397-442` | procedure `SpineRun` |
| `scanEntryP` (per-tag slot walk; chunk entries) | `NurseryParallel.cpp:444-587` | procedure `Scan` (chunk entries not modelled; §5.1) |
| `minorGCParallel` steps 3–5 | `NurseryParallel.cpp:669-763` | `W_Roots`, `W_Start`, `W_Loop` |
| `pushGreyP` / `publishHalfP` / `publishAllP`, `MinorEnv` | `NurseryParallel.cpp:114-226` | the `grey` set (M2 models these) |
| `evacuateR`, `copyClaimedR`, `spineRunR`, `reachYoungLargeR`, `resolveRetire` | `NurseryRegion.cpp:352-578` | `Mode = "region"` branches of `Evacuate` / `Copy` / `ReachYlos` |
| `RegionEnv` | `NurseryRegion.cpp:280-337` | the `grey` set (M2) |
| `minorGCRegion`: role table, roots, distribution, drain, LABs closed | `NurseryRegion.cpp:699-897` | `W_Roots`, `W_Start`, `W_Loop` (`Mode = "region"`) |
| `RegionState::roleOf`; `isInFromSpace`; `mayBeYoungLarge` | `NurseryRegions.hpp:215-224`; `NurserySpace.hpp:387-394`; `OldGenSpace.hpp:1184-1186` | set membership in `E_Kind` (pause-immutable state, §3.8) |
| `youngLargeMeta`, `promoteYoungLarge` (under `ylos_mu_`) | `OldGenSpace.hpp:1188-1194`; `OldGenSpace.cpp:7107-7129` | inside `Y_Lock` |
| `ThreadLocalHeap::minorGC`: `tenureJoin` before the region minor | `ThreadLocalHeap.cpp:722-733` | premise of `RetireFwd` being a constant |
| PM1 / PM2 / PM3 (legacy), region PM1–PM3 | `NurseryParallel.cpp:844-875`, `NurseryRegion.cpp:966-1006` | `CopyOnce`, `CopyOnceContract`, `AtJoin` |
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
| Pointer values | Integers in disjoint ranges: from-space `FromIds` (in 1..99), copies `100 * k + o`, YLOS, old, Hand, Retire; `Nil = 0` | Membership tests (`isInFromSpace`, `mayBeYoungLarge`, `roleOf`) become set membership. Sound because every state they read is immutable during the drain (§3.6, §3.8) |
| The header word | `hdr[o] ∈ {"H", "BUSY"} ∪ CopyIds` | "H" stands for any unforwarded header. Colour is carried but irrelevant to the protocol. The three kinds are distinct by construction, so the model **assumes** the encodings never collide; CR-011's unit test must check that (§8) |
| `labAllocate` / `allocatePromotion` | `C_Alloc` takes a canonical fresh id: the k-th copy of `o` is `100 * k + o` (one atomic step) | Only disjointness matters (`tospaceClaim` is a relaxed CAS on `top`). LAB internals are owner-only. A global "next address" counter would add no bug-finding power and would multiply the states by the allocation orders. At most one copy per worker per object exists, even under the double-copy mutants (a worker copies only after loading the unforwarded word, which never comes back), so `k ≤ |Workers|` |
| The copy: `memcpy` body, then header | Two steps, `C_Body` and `C_Hdr`, before `C_Pub` | Faithful: the copy is private memory until published and pushed |
| The grey set: private stacks, deques, stealing, termination | One shared set `grey`; a worker takes any entry atomically and sets `busy`; the drain ends when `grey = {}` and nobody is busy | M2's **Drain** contract: every pushed entry is scanned exactly once, and the run ends only when no work is left |
| Chunk entries for arrays over 1,024 elements | Not modelled | A chunk entry is an entry over a disjoint slot range of one object. Ownership is per range and nothing else changes. Add a two-chunk object if the implementer wants it (§11) |
| Promotion (age, pin, builder) | `Promotes(v) == Mode = "legacy" /\ Age[v] >= PromoAge /\ v \notin Builders` (`Builders` stands for pinned objects too) | Age is read from the saved header, which is immutable |
| The PM5 premise (a promoted parent's children are at least as old) | Built into the example heap's ages | The premise comes from generational ageing plus HEAP_005 and P1 (M1's territory). M3 checks that the protocol keeps it |
| `ylos_mu_` critical section | One step (`Y_Lock`: test-and-set, then age or promote), then the push (`Y_Push`) after unlocking | Faithful (A1: one critical section is one step). One reached flag stands for `m->color` and the region's `hand_ylos_reached` (§3.6). Sound only while nothing outside `ylos_mu_` writes the YLOS index or the YLOS header during the drain: true in region mode; in legacy mode see A3 (CR-014) |
| Region `resolveRetire` | `RetireFwd` constant map | The shadow is immutable in the pause: `ThreadLocalHeap::minorGC` joins and merges the job before `minorGCRegion`, which checks `Merged` (TV1, `NurseryRegion.cpp:716-718`) |
| LAB fillers (in-drain retirement and `closeLabs`) | Not modelled | Owner-only until the join; no walker during the drain (§3.7). None of M3's properties reads them |

**Slot ownership (a ghost rule).** `owner[o]` is the worker allowed to write `o`'s slots:
- the worker that took `o` from the grey set;
- for an unpushed spine-run cell, the worker whose run copied it;
- for a pushed object, nobody (`Nil`) until someone takes it.

The invariant `OwnerWrites` checks, at every `E_Read`, that the caller owns `eo`. That is the
model's form of "slots written are owner-only" (the phase 6 plan's premise that makes plain slot
stores race-free). It is an invariant rather than an `assert`, so the runner can match the
`heads_walk` and `heads_all` mutants by name (primer §5).

### 5.2 Constants

| Constant | Meaning | Code value | Model values |
|---|---|---|---|
| `Workers`, `W0` | worker ids; `W0` is the paused mutator | 1..N, worker 0 | `{1, 2}` (deep: `{1, 2, 3}`), `W0 = 1` |
| `FromIds`, `ConsIds` | from-space objects (ids in 1..99); the Cons subset | eden / from-space | `1..6`, `{3, 4, 5}` |
| `YlosIds`, `OldIds` | young large objects; old-gen leaves | YLOS index; old gen | `{7}`, `{9}` |
| `HandIds`, `RetireIds`, `RetireFwd` | region roles | 7b extents | `{}` (legacy); `{11}`, `{12}`, `12 → 9` (region) |
| `InitFields`, `InitRoots` | the heap before the minor | — | §7 |
| `Age`, `Builders`, `PromoAge` | promotion inputs | header age, builder/pin bits, `promotion_age` | §5.5 `MC.tla`: `PromoAge = 1` (the default), `Builders = {}` |
| `Mode` | `"legacy"` or `"region"` | `nursery_regions` | both |
| `MaxRun` | spine run length | `MINOR_SPINE_RUN = 512` | 1. The run starts at a scanned copy and counts only the cells it copies, so the 3-cell spine `3 → 4 → 5` gives runs of at most 2 cells: with 2 the run ends at Nil and is never truncated; with 1 it is truncated at `5` |
| `MUTANT` | negative-control selector | — | `"none"` or a §6 name |

### 5.3 Variables

| Variable | Meaning | Code counterpart | Written by |
|---|---|---|---|
| `hdr[o]` | from-space header word | the object's first word (`headerRef`) | claim (CAS), publish (store) |
| `fld[o]` | an object's slots | the object's fields | copies: the owner; from-space: never (immutable) |
| `roots` | root slots | stack maps, RootSet, external scanners | worker 0, before the gang |
| `origin[d]`, `whole[d]` | ghost: a copy's original; body and header copied | — | the copier |
| `promo[d]` | the copy went to the old gen | `shouldPromote` | the copier |
| `grey`, `busy[w]`, `started` | Drain contract; gang start | deques and private stacks; `GCMarkGang::run` | workers; worker 0 |
| `owner[o]` | ghost: who may write `o`'s slots (checked by `OwnerWrites`) | the owner-only discipline | taking an entry, run links, pushes |
| `yReached`, `yPromoted`, `yPushes` | YLOS colour, promotion, ghost push count | `LargeBodyMeta::color`, `promoteYoungLarge` | under `ylos_mu_` |
| `recorded` | region: slots recorded into H / S | `rw.H`, `rw.S` | the pause (per-worker lists, merged later) |
| `res[w]` | procedure result | the return value of `copyClaimed` | `Copy` |

### 5.4 Steps: model labels to code lines

| Label | Code | Atomic operation it stands for |
|---|---|---|
| `W_Roots`, `W_RootLoop` | `NurseryParallel.cpp:669-725` | worker 0 evacuates each root slot, alone |
| `W_Start` | `GCMarkGang::run` (`GCHelperPool.cpp:407`) | the gang start (mutex release/acquire) |
| `W_Loop` (take) | `takeOwn` / `steal` (M2) | atomic removal of one grey entry |
| `SC_Loop` | `scanEntryP` `:444-587` | one slot per iteration |
| `E_Read`, `E_Kind` | `evacuateP` `:316-331` (filters) | read the owner's own slot (`OwnerWrites` holds here); classify the target |
| `E_Load` | `:332` | `loadHeader` (acquire) |
| `E_Wait` | `:335`, `waitPublishedP` `:245` | re-load until not BUSY |
| `E_Claim` | `:339` | `claim`: CAS header → BUSY |
| `C_Alloc` | `copyClaimed` `:251-300` | size from the saved header; promote/survive; `allocatePromotion` or `labAllocate` (a canonical fresh copy id) |
| `C_Body`, `C_Hdr` | `:301-304` | `memcpy` body; `memcpy` fixed-up header |
| `C_Pub` | `:311` | `publish` (release store of the forward word) |
| `E_Slot` | `:343-344` | `slot = dst`; push if it has children |
| `S_Loop` … `S_Link` | `spineRunP` `:401-429` | per cell: load, maybe wait, claim, copy, link |
| `S_HeadLoop` | `:431-441` | the counted heads pass |
| `Y_Lock`, `Y_Push` | `reachYoungLargeP` `:361-390`; `reachYoungLargeR` `NurseryRegion.cpp:495-531` | the whole `ylos_mu_` section (test-and-set, age or promote); the push after unlocking. Mutant `ylos_unlocked` splits it at `Y_Set` |

### 5.5 The PlusCal sketch

File: `test/tla/M3-minor-forwarding/MinorForwarding.tla`. This is the text that passed the
translator and SANY (`pcal -nocfg` 1.12 and SANY from tla2tools 1.8.0, re-run on this revised text
at the 2026-09-28 review, with `MC.tla` below also parsed); the generated translation is omitted.

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
    MUTANT

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
    hdr     = [o \in FromIds |-> "H"],        \* header word: "H" | "BUSY" | a copy id (FWD)
    fld     = [o \in ObjIds |-> IF o \in FromIds \cup YlosIds THEN InitFields[o] ELSE <<>>],
    roots   = InitRoots,                      \* root slots (worker 0 only, before the gang)
    origin  = [d \in CopyIds |-> Nil],        \* ghost: the original of each copy
    whole   = [d \in CopyIds |-> FALSE],      \* ghost: body and header copied
    promo   = [d \in CopyIds |-> FALSE],      \* the copy went to the old gen
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

\* reachYoungLargeP: one ylos_mu_ critical section (colour test-and-set, then
\* age++ or promoteYoungLarge), then the push after unlocking.
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
    cd := CHOOSE c \in CopySlots(cv) : origin[c] = Nil;
    origin[cd] := cv;
    promo[cd] := Promotes(cv);
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
\* Invariant OwnerWrites (below) checks that only eo's owner gets here.
procedure Evacuate(eo, ei)
variables ev = Nil, ehw = "H";
begin
  E_Read:
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
        \* rule 1 broken: follow tails while the cell is a copy (rule 2 kept:
        \* stop at a truncated run's pushed cell)
        if srun # <<>> then swalk := srun[1]; end if;
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
\* Slot writes are owner-only: a worker about to evacuate a slot of object
\* eo owns eo (roots: eo = Nil, worker 0 before the gang). An invariant, not
\* an assert, so the runner can match mutant heads_walk by name.
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
\* Every live slot holds exactly the copy its old target's header forwards to
\* (never a from-space address, never 0 from BUSY), or the tenured copy of a
\* Retire object, or its old value (old, YLOS, Hand, constant).
SlotsAtCopy == \A sl \in LiveSlots : SlotVal(sl[1], sl[2]) = Expected(OrigVal(sl[1], sl[2]))
\* The CopyOnce contract (parent plan 5.0) that M4 and M5 consume.
CopyOnceContract == CopyOnce /\ (AllDone => SlotsAtCopy)

\* At the join (every worker exited):
\*  - no BUSY word is left (HEAP_006 / HEAP_067);
\*  - every reachable from-space object was forwarded;
\*  - PM2 / the slot half of CopyOnce (SlotsAtCopy);
\*  - PM5: no promoted object points at a young (surviving) copy;
\*  - region: every slot pointing into Hand was recorded.
AtJoin ==
    AllDone =>
        /\ \A o \in FromIds : hdr[o] # "BUSY"
        /\ \A o \in Reachable \cap FromIds : hdr[o] \in CopyIds
        /\ SlotsAtCopy
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
\* From-space: 1 = Tuple(2, 7)   age 1 (promotes; its children must promote too)
\*             2 = leaf -> old 9 age 1 (promotes; shared by 1 and 5's head)
\*             3 = Cons(7, 4)    age 0 (its head is the YLOS: 7's second parent)
\*             4 = Cons(Nil, 5)  age 0
\*             5 = Cons(2, Nil)  age 1 (promotes; shared by 4's tail and 7)
\*             6 = garbage
\* YLOS 7 = [5] age 1 (promoted in place); old 9. Roots: <<1, 3>>.
\* Acyclic, and every edge goes to an object at least as old (Elm's allocation order).
MC_FromIds == 1..6
MC_ConsIds == {3, 4, 5}
MC_YlosIds == {7}
MC_OldIds == {9}
MC_Fields == (1 :> <<2, 7>>) @@ (2 :> <<9>>) @@ (3 :> <<7, 4>>) @@ (4 :> <<0, 5>>)
             @@ (5 :> <<2, 0>>) @@ (6 :> <<3>>) @@ (7 :> <<5>>)
MC_Roots == <<1, 3>>
MC_Age == (1 :> 1) @@ (2 :> 1) @@ (3 :> 0) @@ (4 :> 0) @@ (5 :> 1) @@ (6 :> 0) @@ (7 :> 1)
MC_PromoAge == 1
MC_Builders == {}
MC_NoRetire == [x \in {} |-> 0]
\* region variant: 11 in Hand, 12 in Retire (tenured to old 9)
MC_RegionFields == (1 :> <<2, 11>>) @@ (2 :> <<12>>) @@ (3 :> <<7, 4>>) @@ (4 :> <<0, 5>>)
                   @@ (5 :> <<2, 0>>) @@ (6 :> <<3>>) @@ (7 :> <<5>>)
MC_RetireFwd == (12 :> 9)
====
```

The example heap exercises, with two workers (every target named here is reachable by a two-worker
interleaving; §6 gives each mutant's shortest one):
- a leaf shared by two entries that different workers scan (`2`, from `1'` and `5'`'s head): the
  plain claim race;
- a 3-cell spine (`3 → 4 → 5`) that `MaxRun = 1` truncates once (rule 2);
- a spine cell with a second parent (`5`, also the YLOS's slot): a run can meet another worker's
  copy of `5` (rule 1), and the claim race runs between `S_Claim` and `E_Claim`;
- a YLOS with two parents (`7`, from `1` and `3`'s head), so two workers can reach it at once;
- promoted parents whose children must promote (`1 → 2`, `1 → 7`, `7 → 5`, `5 → 2`), and
  survivors pointing at promoted copies (`4' → 5'`);
- a YLOS reached from a promoted parent and pointing back into from-space;
- an old leaf (`9`) and a garbage object (`6`).

The previous heap (`3 = Cons(2, 4)`, `5 = Cons(1, Nil)`, `7 = [2]`, `MaxRun = 2`) gave `7` and `5`
one parent each and never truncated a run, so `ylos_unlocked` and `heads_walk` could not fail.

### 5.6 The properties, explained

| Property | Kind | What it says | What a violation looks like |
|---|---|---|---|
| `CopyOnce` | invariant | no from-space object has two copies (PM1) | two workers both think they claimed `S` (mutant `copy_without_cas`) |
| `FwdComplete` | invariant | a forward word names a complete copy | forward published before the body or header was copied (mutant `publish_early`) |
| `SizeFaithful` | invariant | a complete copy has all the original's fields | size read from BUSY (mutant `size_from_busy`) |
| `YlosOnce` | invariant | each YLOS is pushed at most once | colour test outside the mutex (mutant `ylos_unlocked`) |
| `OwnerWrites` | invariant (at every `E_Read`) | only an object's owner evacuates its slots | the heads pass walking into another worker's cell (mutant `heads_walk`), or into a truncated run's pushed cell (mutant `heads_all`) |
| `AtJoin` | invariant (checked once all workers exited) | no BUSY left; every reachable from-space object forwarded; `SlotsAtCopy`: **every live slot holds exactly `Expected(OrigVal(slot))`**, i.e. the copy its old target's header names (PM2) or the tenured copy of a Retire object; PM5; region Hand slots recorded | a slot left at 0 because BUSY was read as an address (mutant `no_wait`); a slot still pointing into from-space |
| `CopyOnceContract` | invariant | `CopyOnce`, and at the join `SlotsAtCopy`: the **CopyOnce** contract of parent plan §5.0, in the form M4 and M5 use it (one copy per young object; every slot, root and YLOS slot included, at that copy) | either half failing (mutants `copy_without_cas`, `no_wait`) |

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
| `copy_without_cas` | claim by plain store instead of CAS | `CopyOnce` | A scans YLOS `7` and loads H from `5`; B's second run (from `4'`) claims `5` at `S_Claim`; A's claim ignores the BUSY word and copies again. The code's own hook `test_minor_double_copy_every_` makes an uncounted second copy for PM1; this mutant is the protocol-level form |
| `size_from_busy` | `getObjectSize(obj)` instead of the saved header (`:255`) | `SizeFaithful` | §3.4; the first copy of the root phase already fails |
| `publish_early` | `publish` before the `memcpy`s | `FwdComplete` | a forward names a copy with no fields yet; the first `C_Alloc` already fails |
| `no_wait` | treat BUSY like a forward word (skip `waitPublished`) | `AtJoin` (config `mut_no_wait`); `CopyOnceContract` (config `mut_no_wait_contract`) | A scans `7` and loads `5` while B's run holds it BUSY: `7`'s slot becomes 0 and `5'` is lost from it |
| `heads_walk` | heads pass that follows tails "while in to-space" instead of counting (rule 1 broken; it still stops at a truncated run's pushed cell) | `OwnerWrites` | B reaches `7` from `3'`'s head and pushes it; A scans `7` and copies `5` to `105` (pushed); B's run from `3'` copies `4`, finds `5` forwarded and links `104 → 105`; the walk goes on from `104` to `105`, a cell B does not own (§3.5, row 3′) |
| `heads_all` | heads pass counts all `k` cells even when truncated (rule 2 broken) | `OwnerWrites` | B's run from `3'` copies `4`, finds `5` unforwarded at `k = MaxRun = 1`, pushes `104`, then evacuates `104`'s head, a cell it has just given away |
| `ylos_unlocked` | YLOS colour test and set in separate critical sections | `YlosOnce` | A scans `1'`, B scans `3'`; both reach `7` and pass the test before either sets it: two promotions, two pushes, two scanners |

Every mutant's target is reached after the serial root phase (A copies `1` and `3`) plus at most
two entries per worker. **Each `mut_*` configuration lists only its target invariant** (primer §5:
a mutant that breaks a different invariant first does not count). This matters here: `no_wait`
breaks `AtJoin` and `CopyOnceContract` in the same state, and `ylos_unlocked` can break
`OwnerWrites` in the state that breaks `YlosOnce`.

**Not a mutant: fillers.** `test_minor_skip_filler_` skips one filler write in `closeLabs` and PM3
must fire. That is single-threaded, after the join, so it is out of M3's scope, and the PM3
validator already guards it.

## 7. Configurations

| Config | What it models | Key constants | Tier | Expected |
|---|---|---|---|---|
| `legacy` | phase 6, two workers | `Workers = {1,2}`, `W0 = 1`, `Mode = "legacy"`, `MaxRun = 1`, the §5.5 heap (`InitFields <- MC_Fields`, `Age <- MC_Age`, `PromoAge <- MC_PromoAge`, `Builders <- MC_Builders`), `HandIds = {}`, `RetireIds = {}`, `RetireFwd <- MC_NoRetire` | quick | pass |
| `region` | 7b region minor (the default mode) | `legacy` but `Mode = "region"`, `InitFields <- MC_RegionFields`, `HandIds = {11}`, `RetireIds = {12}`, `RetireFwd <- MC_RetireFwd`; promotion off by mode | quick | pass |
| `legacy3` | three workers | `Workers = {1,2,3}` | deep | pass |
| `mut_<name>` | each §6 mutant | `legacy` + `MUTANT = "<name>"`; `INVARIANT` = the §6 target only | quick | the named property fails |

Every configuration sets `defaultInitValue = defaultInitValue` (primer §2 rule 3) and
`MUTANT = "none"` unless it is a mutant. The pass configurations check
`INVARIANTS CopyOnce FwdComplete SizeFaithful YlosOnce OwnerWrites AtJoin CopyOnceContract`. The
spec terminates (every worker reaches `Done`), so deadlock checking stays on: a stuck `E_Wait` or
`S_Wait` would be reported as a deadlock.

**Size guidance.** No run yet; this is an estimate. The heap has six from-space objects, and the
root phase is serial, so interleavings start only at the drain. Canonical copy ids remove the
allocation-order factor that a global "next copy" counter would add. Expect the `legacy` quick
configuration to be in the hundreds of thousands to low millions of states. If it is larger, cut
without losing a mutant's target:
1. make `2` fieldless (`2 :> <<>>` in `MC_Fields`): `2'` is then never pushed or scanned, and the
   claim race on `2` stays;
2. in `region` only, drop the YLOS (`3 :> <<0, 4>>` in `MC_RegionFields`): the colour branch keeps
   its legacy coverage, and `5` keeps its race between the run and the YLOS scan only in legacy.

Do not drop the YLOS or the second parent of `5` in `legacy`: `ylos_unlocked` and `heads_walk`
need them. Do not raise worker counts in the quick tier.

## 8. Accuracy notes (parent plan rules A1–A9)

| Rule | M3 |
|---|---|
| A1 | Each label is one atomic operation on shared memory, or one owner-only change (§5.4). The claim is a CAS step that compares the observed word. The copy is split into allocation, body, header and publish. The whole `ylos_mu_` section (test-and-set, then age or promote) is one step. A spine run's cells are claimed one at a time, each with its own labels. The owner-only slot and `prev->tail` writes are folded into the preceding atomic step. |
| A2 | A from-space header is one 64-bit word updated only by the CAS and the release store. The model has no sub-word writes to it (colour lives inside the forward word). The body `memcpy` is not atomic, and it needs no finer model: the source body is immutable and read only by the claim winner, and nobody reads the destination before the publish and the push (§3.1). Slots are whole 8-byte words, written only by their owner. |
| A3 | 06 P§3.11 rows for the drain: from-space headers (CAS / store), to-space `top` (relaxed CAS), LABs and their retirement fillers (owner), grey stacks and deques (Drain contract), `ylos_mu_` + YLOS index/colour (`large_body_index_`, `large_bodies_[id].color`, `nursery_owned_bodies_`, `free_large_body_ids_`) and the YLOS header's age bits (a plain write under the lock), per-worker `lb_promoted`/`lb_seen`/`ylos_young` (owner, merged after the join: not modelled), the YLOS bounding box and the from-space bounds (read-only during the drain). Region: the role table (`role_of_k`, `prev_k`, `prev_bld_off`: read-only during the drain), `hand_ylos` (read-only) and `hand_ylos_reached` (under `ylos_mu_`), `rw.S`/`rw.H`/`rw.SA` (per-worker, merged after the join), `bld_bottom` (atomic `fetch_sub`, a separate disjointness question not modelled; see §11), the shadow (read-only in the pause). **Cross-model footprint (legacy mode only):** `ylos_mu_` is not the only lock around the YLOS state. On CR-014's path, `onSweepComplete` runs inside the drain under `promo_mu_` and can reach `maybeShrinkCapacity` → `releaseBlockToAllocator`, which iterates and erases `large_body_index_` (`OldGenSpace.cpp:6040-6073`) while another worker holds `ylos_mu_` in `youngLargeMeta`. And a sweep slice inside `allocatePromotion` reads the header of any marked cell it steps over (`getObjectSize`, gap sweep, `:5361`); if a young YLOS can be such a cell, that read races `reachYoungLargeP`'s `h->age++`. Neither is visible to M3 (it has no sweep) or to M4 (it has no YLOS); both are reported to the register (§12). |
| A4 | W5 checks that publish (release) / loadHeader (acquire) and the deque's release/acquire element transfer make a copy's contents visible to its scanner. M3 assumes it. The colour tests read only state written before the gang start, so M3 needs nothing from W4 (§3.8). |
| A5 | `gc-minor-tsan` trace (§9). |
| A6 | §6: seven mutants, one or more per invariant. `CopyOnceContract` is covered by `mut_no_wait_contract` (and `copy_without_cas` breaks its other half). The region-only conjuncts of `AtJoin` (Hand recorded, Retire resolved) have no M3 mutant; they are sequential logic, and M5's recording mutants cover them. |
| A7 | `CopyOnce` = PM1 / HEAP_067 "copied exactly once"; `AtJoin` = PM2 + HEAP_006 (no BUSY after the pause) + PM5 (HEAP_005); `SizeFaithful` = HEAP_067 "sizes the object from the SAVED header"; `OwnerWrites` = the 06 plan's owner-only slot premise (model-only); `CopyOnceContract` = the parent plan's §5.0 contract; region conjuncts = HEAP_069 recording and resolution. |
| A8 | 2 workers (3 deep), 6 from-space objects, a 3-cell spine with `MaxRun = 1` (the first run is truncated, the second is not; a run can also end at another worker's copy), one YLOS with two parents. Copy ids are canonical, `100 * k + o` with `k ≤ |Workers|`, which is enough for every double-copy mutant. Nothing wraps and nothing is unbounded: each slot is evacuated at most once per scan, so no state constraint is needed. |
| A9 | `file`: `MinorWork.hpp`. `region`: `evacuateP`, `copyClaimed`, `spineRunP`, `reachYoungLargeP`, `scanEntryP`, `minorGCParallel` steps 3–5 (`NurseryParallel.cpp:250-763`); `evacuateR`, `copyClaimedR`, `spineRunR`, `reachYoungLargeR`, `resolveRetire`, `scanEntryR` (`NurseryRegion.cpp:352-644`); `minorGCRegion` from beginMinor to the LAB close (`NurseryRegion.cpp:699-897`); `RegionState::roleOf` (`NurseryRegions.hpp:215-224`); `youngLargeMeta`/`mayBeYoungLarge` (`OldGenSpace.hpp:1184-1194`) and `promoteYoungLarge` (`OldGenSpace.cpp:7107-7129`). `census`: `NurseryParallel.cpp`, `NurseryRegion.cpp`, `NurseryRegions.hpp`. `grep`: `role_of_k\[`, `ylo_(lo|hi)_ =` (an ERE: `grep -E`), `large_body_index_\.erase`. |

**Relation to CR-011** (register). `MinorWork.hpp` builds forward and BUSY words from its own bit
constants. Only the tag is pinned against `Heap.hpp`'s bitfields (`static_assert`,
`NurseryParallel.cpp:39`), and the runtime layout test its comment promises does not exist. M3
models the header word **abstractly** (`"H"`, `"BUSY"`, a copy id), so it cannot catch a layout
mismatch. A wrong bit position is a C++ encoding bug, not an interleaving. **M3 does not replace
that test.** CR-011's fix (compose with `mw::fwdWord`, decode through `Heap.hpp`'s `Forward`) is
still needed. M3's trace validation (§9) cannot see a mismatch either: the harness includes only
`MinorWork.hpp` and decodes with `mw::fwdAddr`, which always agrees with `mw::fwdWord`.

What the unit test should cover, because the model assumes it (§5.1):
- `mw::fwdWord(dst, c)` decodes through `Heap.hpp`'s `Forward` to `dst` and `c`, for `dst = 8`,
  `dst = HPOINTER_ADDRESS_LIMIT - 8` and every colour;
- `mw::fwdWord(dst, c) != mw::kBusy` for every 8-aligned `dst` in `[8, HPOINTER_ADDRESS_LIMIT)`
  (the masked address is never 0). A `dst` at or above 2^43 would mask to 0 and publish BUSY, and
  its waiters would spin forever. `Allocator.cpp:258-277` keeps the heap below that limit;
- no live tag equals `Tag_Forward`, so an unforwarded header never looks forwarded (the tag
  `static_assert` plus "Forward is last" in `Heap.hpp`).

## 9. Trace validation

**Harness:** `test/gc-helper-tsan/minor_harness.cpp` (target `gc-minor-tsan`). It already runs the
real `MinorWork.hpp` claim/publish and LABs with the real `runMarkerLoop` over a synthetic heap:
count-based heads pass, chunks, a mutex-guarded promotion arena, and shared list tails (so rule 1
of §3.5 happens). Word 1 of each object is its id.

**What this harness can and cannot validate.** Its `evacuate`, `spine` and `copyClaimed`
(`minor_harness.cpp:253-335`) are a **replica** of `evacuateP` / `spineRunP` / `copyClaimed`, not
the production functions. It has no YLOS, no region roles and no builders. So a trace from it
checks `MinorWork.hpp` plus the replica against the model; it says nothing about
`NurseryParallel.cpp` or `NurseryRegion.cpp` drifting from the replica (the canary covers that
direction), and the `ylos` event below has no source in it. Two changes are needed for L4:
1. a **tiny-heap mode** (about ten objects, the shape of `MC.tla`) that writes the heap into the
   trace header (`InitFields`, `InitRoots`, `Age`, `ConsIds`), so the trace spec takes its
   constants from the trace. The harness's random heaps (20,000–40,000 objects,
   `minor_harness.cpp:126-196`) are far too large for TLC;
2. a **YLOS object kind** in the harness: a mutex-guarded reached flag, then a push and an
   in-place scan, the shape of `reachYoungLargeP`. Without it `ReachYlos` has no trace coverage
   (and no TSan coverage anywhere: `gc-heap-tsan`'s driver allocates no pointer-bearing large
   object, `heap_driver.cpp:78-111`).

Validating the production functions themselves would need hooks in `NurseryParallel.cpp` /
`NurseryRegion.cpp` and a tiny-heap scenario in `gc-heap-tsan`. That is optional, and left to the
implementer (§11).

**Hooks.** `ECO_TLA_TRACE(...)` in `MinorWork.hpp`, compiled out unless `ECO_TLA_TRACE` is defined
(only the trace build of the harness). The harness's own evacuate and spine code carries the
remaining hooks. Each event records `{t: worker, ev, obj, ...}`, with object ids, not addresses:

| Event | Where | Extra fields |
|---|---|---|
| `load` | `loadHeader` (`MinorWork.hpp:54`) | `word` (`H`/`BUSY`/`FWD:<id>`) |
| `claim` | `claim` (`:58`) | `ok`, `observed` |
| `wait` | `waitPublished` exit (`:72`) | `word` |
| `copy` | harness `copyClaimed` analogue, after the allocation | `dst` (logged as the model's canonical id `100 * k + id`), `promote` |
| `publish` | `publish` (`:63`) | `dst` |
| `slot` | after the slot store in evacuate | `parent`, `idx`, `value` |
| `run` / `heads` | spine run link; heads-pass entry | `prev`, `cell`, `k`; `m` |
| `ylos` | inside the mutex section (needs the harness's YLOS kind, above) | `obj`, `won`, `promoted` |
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
2. `pcal` + `sany` (already clean in the sketch; grep SANY's output for `*** Errors`, since it
   exits 0 either way), then TLC on `legacy` and `region`. Apply §7's size guidance if a quick
   configuration exceeds about 2 minutes.
3. Run every mutant, each with only its target invariant. Confirm each fails with its named
   property (`OwnerWrites` for `heads_walk` and `heads_all`), and that the counterexample is the
   §6 story (for `heads_walk`: the run ends at a forwarded `5`, not at a truncation). Record the
   traces in MAPPING.md.
4. Wire into `models.txt` and `test/tla/manifest.txt` (A9's lines).
5. Trace validation (§9) on `gc-minor-tsan`: the tiny-heap mode and the YLOS kind in the harness,
   hooks, merger, trace spec, one CI-sized run.
6. Close-out: AUDIT.md first entry; the parent plan's §11 row.

## 11. Open questions for the implementer

1. **Chunk entries.** Arrays and ListBackings over 1,024 elements are scanned as chunk entries by
   different workers (`scanEntryP` `:521-563`). Each chunk writes only its own slot range, so
   "owner" becomes per range. Worth a two-chunk object in a deep configuration if the owner rule is
   to cover it.
2. **The region builder area.** Builders are bump-allocated *downwards* from the fill's end with an
   atomic `fetch_sub` on `bld_bottom` (`NurseryRegion.cpp:385-386`), while survivors come up from
   the base through LABs. The LAB claims are bounded by `fill_end`, not by `bld_bottom`, so during
   the drain nothing stops a LAB from overlapping builder copies; the overlap is caught only after
   the join (`top > bld_lo` is fatal, `:894-896`), after both copies were written. It is fatal in
   every build, so never silent, and the worker-count space test (`:775-779`) should make it
   unreachable. That is a space bound, not an interleaving question, and is not in M3. If it ever
   matters, model the two frontiers as integers.
3. **PM5 in region mode.** The region minor never promotes, so PM5 is vacuous there. Its
   counterpart (a tenured copy never points young) is TV6, checked by M5.
4. **Tracing the production functions** (§9). Hooks in `evacuateP`/`spineRunP`/`reachYoungLargeP`
   and their region twins, plus a tiny-heap region scenario in `gc-heap-tsan`, would make L4 cover
   the default mode's real code rather than the harness replica. Worth it if the canary ever
   fires on those functions without a matching harness change.

## 12. Adversarial review (2026-09-28)

Reviewed against the current tree. The revised §5.5 sketch and `MC.tla` pass `pcal` and SANY; TLC
was not run, so reachability below was checked by hand.

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | `ylos_unlocked` could not fail: YLOS `7` had one parent (`1`), so `ReachYlos(7)` ran once in every behaviour | `3 = Cons(7, 4)`: `7` has two parents that different workers scan (§5.5, §6) |
| R2 | Blocker | `heads_walk` could not fail: a run starts at a scanned copy and counts only the cells it copies, so with `MaxRun = 2` the spine `3 → 4 → 5` ends at Nil and is never truncated; and `5` had one parent, so no run met another worker's copy. The walk visited only its own cells | `MaxRun = 1`; `7 = [5]` gives `5` a second parent; `heads_walk` now breaks rule 1 only, and new `heads_all` breaks rule 2 only |
| R3 | Major | The owner rule was an `assert`; the runner matches mutants by invariant name (primer §5) | invariant `OwnerWrites` at every `E_Read` |
| R4 | Major | Mutant configs listed every invariant; `no_wait` breaks `AtJoin` and the contract in one state, and `ylos_unlocked` can break `OwnerWrites` in the state that breaks `YlosOnce` | each `mut_*` config lists only its target (§6, §7) |
| R5 | Major | The **CopyOnce** contract was not one property: `CopyOnce` was PM1 only, and the slot half was a conjunct of `AtJoin` | `SlotsAtCopy` and `CopyOnceContract`, with `mut_no_wait_contract` |
| R6 | Major | A global `nextCopy` counter multiplied the states by allocation orders and added no bug-finding power | canonical copy ids `100 * k + o` |
| R7 | Major | §9: the harness is a replica of `evacuateP`/`spineRunP`, has no YLOS, and builds 20k–40k-object heaps; the `ylos` event had no source | §9: tiny-heap mode and a YLOS kind are required; production tracing is §11 Q4 |
| R8 | Minor | The default mode (region, k = 1) was not stated, and the region config never reached a YLOS | §1, §3.8; the new heap reaches `7` in both modes |
| R9 | Minor (drift) | "Fillers: single-threaded, after the join": `labAllocate` also writes retirement fillers during the drain (`MinorWork.hpp:194-197`) | §3.7, §4, §5.1: still owner-only until the join, so still not modelled |
| R10 | Minor | CR-011 note said a layout mismatch would show as a rejected trace; the harness decodes with `mw::fwdAddr`, so it never can | §8: corrected, with the unit test's cases (including the 2^43 mask edge) |
| R11 | Minor | `Y_Promote` split one `ylos_mu_` section into two steps (A1) | merged into `Y_Lock` |
| R12 | Minor | `PromoAge`, `Builders` and the legacy `RetireFwd` had no values | `MC.tla`, §7 |
| R13 | Minor | Line drift: `minorGCParallel` ends at `:889`; PM checks `:844-875` / region `:966-1006`; `MinorEnv` to `:226`; `scanEntryP` to `:587`; Eden arm `:448-466` | §3–§5 |
| R14 | Minor (A3) | The YLOS state is also touched outside `ylos_mu_` in legacy mode: CR-014's path erases `large_body_index_` under `promo_mu_`, and a sweep slice may read a young YLOS header | A3 note; reported for the register |

Checked and right as written: the claim/publish/wait code map; the loser paths (§3.1); each spine
cell is its own claim, copy and publish; the colour tests read only pause-immutable state (no W4
or CR-009 dependence); the Retire shadow is immutable (`tenureJoin` runs first); the minor's
concurrent part is exactly `runMarkerLoop` with `MinorEnv`/`RegionEnv`, so M2's Drain contract
applies.
