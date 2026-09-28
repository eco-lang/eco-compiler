# Threaded GC — TLA+ model M5: the region nursery and concurrent tenuring (7b/7c)

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). **Adversarial review on 2026-09-28 against the
current tree** (§12): the sketch, properties, mutants and configurations were corrected, and the
corrected sketch in §4.5 passes the translator and SANY (tla2tools 1.8.0); TLC has not run. The
model is built from the **merged** 7b/7c/07b code, which has been default-on since TG7d
(`nursery_regions = 2` auto, `tenure_mode = 2`, `tenure_collector_threads = 1`).

**Parents:**
- `plans/threaded-gc-tla-verification.md`: §5.1 (index), the accuracy rules A1–A9 (§2), and the contracts in
  §5.0;
- `plans/threaded-gc-tla-primer.md`: read it first if TLA+, PlusCal or the GC terms are new;
- `plans/threaded-gc-tla-M2-slice-control.md`: the template this plan follows, and the model of
  the marker loop the L3 collectors reuse.

**Design documents:**
- `plans/threaded-gc-07-concurrent-tenuring.md`: P§3.3–3.19 for the design, §10.18 for the
  as-built deviations;
- `plans/threaded-gc-07b-tenure-ageing.md`: tenure age k > 1.

---

## 0. Why M5 matters

Phase 7c is the first design in which a GC thread **copies objects while the mutator runs**. Every
earlier concurrent phase either only *read* the heap concurrently (5c marking) or copied inside a
pause (phase 6).

A mistake here has several possible shapes, and all of them are silent until much later:
- an object is not copied, and a reference to it is left pointing into memory that is recycled at
  the next minor;
- an object is copied twice;
- a stale forwarding entry is believed;
- the collector writes something the mutator is reading.

The design leans on several independent arguments:
- the frozen-heap rule P1;
- the completeness of the start set and heal list;
- shadow generations;
- the join barrier;
- the resumable exact engine;
- the STW major's redirect;
- the t0 young walk.

M5 puts all of them in one small model, with a logical-heap oracle that says "the mutator must see
the same object graph as if no GC had run".

## 1. What the model checks, in one paragraph

The mutator allocates small objects, moves references between roots, and drops them. At each minor
GC:
1. the previous tenure job is joined and merged;
2. eden is copied into a free survivor extent;
3. references into the previous minor's survivors are *recorded*, not followed;
4. references into the extent tenured last epoch are *resolved* through its shadow;
5. roles rotate;
6. a new tenure job is launched.

Between minors, a collector thread (or two, for L3) copies the live objects of the handed-over
extent into old-gen cells, recording forwarding only in the shadow. The pause may stop a late
collector and finish its work ("help"). STW majors and incremental mark cycles may happen between
minors. A fork on another thread may stop the collector.

TLC checks every interleaving. It checks:
- that no reachable reference ever points at freed or recycled memory;
- that the object graph the mutator sees is unchanged by any of this;
- that the collector never writes memory the mutator can reach;
- that every live object of the extent is tenured exactly once;
- that the tenured set is exactly what the legacy nursery would have promoted;
- the two things M1 assumes of this protocol: the heal writes only slots of young objects, and a
  mark cycle's markers never reach a young object, the grant or the job's copies, which are black
  (`HealYoungOnly`, `MarkerDisjoint`).

## 2. The protocol in plain words

### 2.1 The region nursery (7b)

A heap's nursery is:
- one **eden**, where the mutator bump-allocates;
- **k + 2 survivor extents**, all with the same capacity. With the default tenure age k = 1 that
  is three extents.

Each survivor extent has a state (`XState`, `NurseryRegions.hpp:35`): **Free**, **Young** (with
an `age`), or **Tenuring**.

Inside a minor GC, each extent plays a role (`Role`, `NurseryRegions.hpp:45`):

| Role in minor m | What it is (k = 1) | What the minor does with references into it | State after minor m |
|---|---|---|---|
| **Fill** | the Free extent | eden's live objects are copied into it; its copies are scanned | Young, age 1 (**Fresh**, holding G_m) |
| **Hand** | the Young extent (filled at minor m−1, G_{m−1}) | nothing is copied; the reference is **recorded** | **Tenuring**: its live objects are tenured by job m during the next epoch |
| **Retire** | the Tenuring extent (G_{m−2}, tenured by job m−1) | the reference is **resolved** to the copy through the extent's shadow | **Free** (poisoned 0xDD in validate builds) |
| Eden | eden | claim, copy into the Fill (phase 6's header protocol, pause-only) | emptied |

So an object copied out of eden at minor m sits in the Fresh extent during epoch m. At minor m+1
its extent is handed over. During epoch m+1 the collector copies it to the old generation if it is
still live. At minor m+2 references to it are resolved to the copy, and its extent is freed. There
is **one epoch of lag** between hand-over and tenuring. That lag is what lets the copying happen
outside a pause.

### 2.2 What the pause records: the start set S and the heal list H

When the minor meets a reference into the **Hand** extent it does not follow it: no header load,
just a range test (`evacuateR`, `NurseryRegion.cpp:429`, case `Role::Hand`). It records:
- **S_m (start set):** *targets* reached from **roots**, **builder** slots and hand-over-generation
  YLOS objects (`kColHandYlos`, promoted in place at the merge). The next minor rescans roots and
  builder areas anyway, and resolves them through the shadow then.
- **H_m (heal list):** *slot addresses* in **Fill copies** (and in young non-builder YLOS objects)
  that point into Hand. Nobody rescans those slots, so the job's merge must rewrite ("heal") each
  one to the copy.

**Completeness argument** (7c P§3.6). Suppose an object of G_{m−1} is reachable at minor m. The
path from a root to it enters the Hand extent from a root, a builder, a Fill copy or a YLOS object
(recorded), or through other Hand objects (the job follows those itself). Old objects never point
young (HEAP_005). So "live at minor m" equals "reachable from S_m ∪ *H_m through Hand", and job m
tenures exactly the set the legacy nursery would have promoted at minor m. The model checks this
equality directly (§4.6, `TenuredEqualsLegacy` against the ghost `liveHand`).

### 2.3 The shadow entry and the job

Every survivor extent has a **shadow**: an array of 64-bit words, one per 8-byte granule of the
extent (`RegionState::shadow`). It is the extent's forwarding table, kept *off* the objects.
Layout (`TenureWork.hpp:48-95`):

```
bits 0..2   state: 0 unvisited, 1 BUSY (being copied), 2 FWD (copied)
bits 3..42  destination address (valid only when FWD)
bits 43..63 gen: the extent's generation at its hand-over
```

An entry counts only if its `gen` equals the extent's current `gen`, which `tenureLaunch` bumps at
every hand-over. Anything else reads as unvisited. So the shadow never needs clearing between uses:
the bump makes every old entry stale at once.

**The tenure job** (`TenureJob`, `NurseryRegions.hpp:120`; engine in `TenureWork.hpp`):
- **Inputs, fixed in the hand-over pause:** `starts` = S_m, `heal` = H_m, a snapshot of the
  generation's YLOS objects, and a **grant** (uniform old-gen blocks in state `kAllocTenure`,
  sized from the extent's per-class object counts).
- **The exact engine** (`SerialEngine`, `TenureWork.hpp:212`). An item loop (`step`, line 277):
  - pop a copy and scan it (`scanCopy`, 446): for each child in the tenuring extent, `tenure` it
    and rewrite **the copy's own** slot;
  - else take the next start and `tenure` it;
  - else read the next heal slot's *value* and `tenure` its target (the slot itself is not
    written);
  - else scan reached YLOS.
- **`tenure(obj)`** (248) loads the shadow entry. If it is FWD this generation, it returns the
  copy. Otherwise it allocates from the grant, `memcpy`s, fixes age and colour, publishes FWD with
  a release store, and pushes the copy. The exact engine is the **only** writer while it runs, so
  it publishes **without a claim** (as-built deviation 2).
- **Stop** is honoured only between items (`run`, 216). All progress lives in `SerialState`
  (line 113), so a stopped job continued on another thread produces the same copies at the same
  addresses. That is the "exact" in exact engine (P§3.18, and the stop/resume storm in
  `tenure_harness.cpp`).
- **Outputs, merged at the next join** (`mergeJob`, `NurseryTenure.cpp:669`):
  1. return the grant;
  2. transfer large bodies;
  3. promote reached generation YLOS in place, then resolve **their own** child slots into the
     extent (`:723-744`: `promoteYoungLarge(y)` at `:736`, then `hp = resolveT(c)` at `:741`);
  4. **heal** every H slot to its copy (`:745-800`, serial or on the gang);
  5. stats;
  6. state `Merged`.

  **What the heal writes (checked against the code).** `st.heal` receives only slots of young
  objects: `evacuateR`'s Hand case pushes a slot only for `col == kColSurv` (a fill copy) or
  `kColYoungYlos` (a young YLOS of generation m) (`NurseryRegion.cpp:470`); with k ≥ 2 the ageing
  mark adds slots of marked ageing objects (`TenureWork.hpp:363`, `NurseryTenure.cpp:225`). Step 3
  writes slots of a YLOS object in the same pause, just after promoting it; that object was young
  at any t0 and only black copies point at it, so no marker reaches it. No old object's field is
  ever healed. M5 checks the heal-list half as `HealYoungOnly`; the step-3 half needs the YLOS
  extension (§8.2).

### 2.4 Why the collector writes nothing the mutator reads (FORBID_HEAP_004)

During the epoch the mutator freely reads the Tenuring objects (it still holds references to them)
and the Fresh objects, whose H slots point into Tenuring. Phase 6 forwards eden objects by
overwriting their **headers**, but that is safe only inside a pause. If the collector wrote a
forward word into a Tenuring object's header, a mutator reading that header's tag or size at the
same moment would get a forward word instead (the TOCTOU race of `parallel-gc.md` §2.4). So:
- forwarding lives in the shadow, which the mutator never reads;
- heal writes happen in the next pause, after the join;
- the collector writes only three things: shadow entries of the extent it tenures, cells and bitmap
  bytes of its own grant, and its private job state.

Its copies (including the child slots it rewrites) are unreachable by the mutator until the merge
heals slots to them.

**What the mutator may do during the epoch** (checked against the code; the model's mutator does
all of it):
- read a Tenuring object's fields and headers (kernels included), and copy its references into
  roots and cells (`M_Epoch`'s "load a field");
- allocate eden objects that point at Tenuring objects (they are resolved at the next minor);
- store any held reference into a root or a cell.

It never writes a Tenuring object or a copy:
- P1 (HEAP_SNAPSHOT_001) forbids writes to survived objects;
- builders live only in builder areas. The Tenuring extent's old builder area is dead after the
  hand-over minor re-copied its builders (PrevBuilders), and the job's range `[base, surv_top)`
  excludes it;
- header words (`age`, `color`) are written only by the pause and by `copy()` on the job's own
  copy.

The mutator first reaches a copy through a slot the merge healed, and later through a root the
next minor resolved. After a STW major's merge it holds both at once: originals through roots and
eden objects, and copies through healed Fresh slots, until that next minor. That is legal only
because no code compares identities negatively (FORBID_HEAP_005); `GraphPreserved` compares by
logical id for the same reason.

### 2.5 The join, a late collector, and help (`tenureJoin`, `NurseryTenure.cpp:575`)

At the start of minor m+1 (`ThreadLocalHeap::minorGC`, `ThreadLocalHeap.cpp:726/732`), and at the
start of a STW major (`:791`, `why = 1`):
- If `tenure_help == 0`, or the collector has finished (`finishedApprox()`): **join** (block until
  it returns; the gang mutex publishes its writes).
- Otherwise: **stopAndJoin**, which sets `J.stop` and joins. The collector returns at its next
  item boundary, and the pause **helps**: it finishes the job itself, with `runJobExact` or, for a
  large extent, the pause-only parallel engine `runJobParallel`.
- A collector that is not running although the job is (a fork stopped it, or a child process
  inherited the job: "trap 25") is treated as stopped and finished the same way.
- Then **merge**.

Help details from the code (`tenureJoin`, `:633-650`): help uses the exact engine unless the help
width `hn` is above 1 and `why != 2`. With `tenure_help_threads = 0` (the default) `hn` is 1 for
an extent under `minor_parallel_min_bytes` (4 MiB). So the default help of a small extent is
`runJobExact`, and a large one uses the claiming engine `runJobParallel`.

**No half-copied object in the parent.** The exact engine checks `stop` only between items
(`run`, `TenureWork.hpp:218`), and an L3 member finishes its claim, copy and publish before
`runMarkerLoop` looks at `stop` again. So a stop always leaves whole items: every copy published
and pushed, no BUSY entry. Only a thread that dies mid-item leaves a half-done one, and only a
fork child can see that (§7, F1 / CR-013).

A **STW major's merge is final**: the next minor finds the job `Merged` (deviation 4). Until that
next minor resolves them, roots still hold the Tenuring originals. So the STW mark greys **the copy
the shadow names** instead of the original (`majorRedirect`, `NurseryRegion.cpp:217`, used from
the mark at `OldGenSpace.cpp:3126`).

### 2.6 L3: several collectors (`tenure_collector_threads` > 1)

For a large extent (and k = 1), B collector members run M2's marker loop over their own worker
slots (`TenureParEnv`, `NurseryTenure.cpp:931`). There are now several writers, so `tenure`
(`:969`) uses the full **claim** protocol:
1. acquire-load the entry;
2. if FWD, use it; if BUSY, wait (`waitPublished`);
3. otherwise CAS the *observed* word, which may be a stale entry from an earlier generation, to
   BUSY (trap 11);
4. copy, then publish FWD with a release store.

Members allocate from the grant by CAS-claiming chunks (`grantAllocateShared`,
`OldGenTenure.cpp:197`). A stop leaves unscanned work in the deques (M2's stop semantics), and
`tenureConcFinish` (`NurseryTenure.cpp:1239`) drains it in the pause.

### 2.7 Worked timelines

Three survivor extents **A**, **B**, **C**, k = 1.

**(a) One full epoch.**

| When | Extents | What happens |
|---|---|---|
| after minor m−1 | A Tenuring (job m−1 running), B Fresh, C Free | |
| epoch m−1 | | job m−1 copies A's live objects into old-gen cells; the mutator reads A and B objects but writes neither |
| minor m, join | | job m−1 joined; **heal**: slots in B objects that pointed into A now point at A's copies |
| minor m, roles | fill C, hand B, retire A | |
| minor m, copy | | eden → C. Root r2 points at b2 in B: recorded in S_m. Copy c1's field points at b1 in B: slot `c1.f` recorded in H_m. A root pointing into A: resolved to its copy via A's shadow (TV1 if missing) |
| minor m, end | A Free, B Tenuring, C Fresh | job m launched on B: `gen[B]`++, starts = {b2}, heal = {`c1.f`} |
| epoch m | | collector: start b2 → copy b2′, publish FWD; scan b2′: its field → b3 in B → tenure b3 → b3′, set `b2′.f := b3′` (the copy's own slot). Heal item `c1.f`: value b1 → tenure b1 → b1′. **`c1.f` itself is untouched** (the mutator may be reading it) |
| minor m+1, join/merge | | heal `c1.f := b1′` |
| minor m+1, copy | | r2 still points at b2 in B (now Retire): resolved to b2′. B is freed at the end of this minor |

**(b) The collector is late.** At minor m+1, `finishedApprox()` is false.
1. `stopAndJoin`: the collector finishes its current item (say the scan of b2′) and returns.
2. `next_heal` still points at `c1.f`.
3. The pause runs `runJobExact(nullptr)`, which picks up at `c1.f`, tenures b1 into the next grant
   cell, and completes.

The copies land exactly where the uninterrupted run would have put them, because the item order
and the grant cursor are both in `SerialState`. The E2 experiment shows mode 2 equals mode 1 bit
for bit.

**(c) Stale shadow entries, and generations.** Three minors earlier, B was Tenuring with gen 5.
Its shadow cell 0 still holds `FWD(dst = x, gen 5)`, where x is the copy of an object that lived
at cell 0 back then (x may even have been freed by a major since). Now a new object b1 sits at
cell 0, and B is handed over with gen 6.
- The engine reads the entry, sees gen 5 ≠ 6, treats it as unvisited, and copies b1. Correct.
- **If gen were not bumped**, the entry would look like "b1 is already forwarded to x". The heal
  would write x into `c1.f`: a wrong object, possibly freed.
- **Wrap:** gen is 21 bits. After 2²¹ hand-overs of B, gen returns to 5, and the stale entry would
  look valid again. The code therefore **discards the whole shadow when gen wraps** (`tenureLaunch`:
  `X.gen = (X.gen + 1) & mask; if (X.gen == 0) { discard; X.gen = 1; }`). The model shrinks the
  field so the wrap is reachable (§6).

## 3. The code the model covers

Line numbers are as of 2026-09-28, post-7c.

| Code | Where | Model element |
|---|---|---|
| shadow entry: `make`/`fwdOf`/`lookup`/`claim`/`publish`/`waitPublished` | `TenureWork.hpp:58-95` | `shadow`, `FwdOf`, `Busy`, `E_Load`/`E_Claim`/`E_WaitBusy`/`E_Pub` |
| `SerialState` (starts, heal, stack, next_start, next_heal) | `TenureWork.hpp:113` | `jstarts`, `jheal`, `jstack`, `ns`, `nh` |
| `SerialEngine::run` (stop between items), `step`, `tenure`, `scanCopy`, `childOfCopy`, `spineRun`, `scanYlos` | `TenureWork.hpp:212-510` (`run` 216, `tenure` 248, `step` 277, `childOfCopy` 431, `scanCopy` 446, `spineRun` 470) | procedure `Engine` (`E_Loop`, `E_Item`, `E_Load`, `E_Copy`, `E_Pub`, `E_Fix`); `sc`/`si` = `scanCopy`'s frame |
| the ageing phases: `markOrSweepStep`, `markTarget`, `sweepStep` | `TenureWork.hpp:323-420` | extension §8 (k = 2) |
| `TenureHeapEnv` (the exact engine's heap access, `copy` = `grantAllocate` + fixup) | `NurseryTenure.cpp:53-152` | `E_Copy` |
| `runJobExact`, `tenureEntry` | `NurseryTenure.cpp:403-423` | process `Collector` (`Collectors = 1`) |
| `tenureLaunch` (gen bump/discard, inputs, grant, launch) | `NurseryTenure.cpp:428-573` | `MN_Launch`, `MN_Sync` |
| `tenureJoin` (wait / stopAndJoin / help / orphan) | `NurseryTenure.cpp:575-667` | procedure `JoinMerge` (`J_Wait`, `J_Stop`, `J_Help`) |
| `mergeJob` (grant return, TV3/TV4, generation-YLOS promotion and child resolve `:723-744`, heal `:745-800`, final state) | `NurseryTenure.cpp:669-880` | `J_Merge`; the YLOS step is §8.2 |
| `tenureTeardown` (exit: stats-only merge) | `NurseryTenure.cpp:900` | not modelled (exit path; §9 Q5) |
| `TenureParEnv::tenure` / `reachYlos` / `childOfCopy` / `spineRun` / `scan` | `NurseryTenure.cpp:969-1060` | `Engine` with `Collectors = 2` (claim branch) |
| `runJobParallel` (pause-only parallel engine) | `NurseryTenure.cpp:1168` | help with claims (the `Engine(FALSE)` call when `Collectors = 2`) |
| `tenureConcLaunch` / `tenureConcEntry` / `tenureConcFinish` (L3) | `NurseryTenure.cpp:1209-1270` | `MN_Launch` (`running := Collectors`), `Collector` processes, `J_Help` |
| `RegionState`, `Extent`, `TenureJob`, `roleOf` | `NurseryRegions.hpp:64-230` | `xstate`, `xtop`, `gen`, `job` |
| `minorGCRegion` (`NurseryRegion.cpp:650`): beginMinor `:699-724`, hand-over prep `:726`, roots `:817`, drain `:853`, merge of S/H `:899-953`, epilogue and endMinor `:1021-1091` | `NurseryRegion.cpp:650-1100` | `MN_Begin`, `MN_Slot`…`MN_Next`, `MN_Epilogue` |
| `evacuateR` (the role switch: copy / record S or H / resolve; H only for `kColSurv` / `kColYoungYlos`, `:470`) | `NurseryRegion.cpp:429-490` | `MN_Classify`, `MN_Set`, `MN_Resolve` |
| `resolveRetire` (TV1, every build) | `NurseryRegion.cpp:352` | invariant `TV1_Resolve` (at `MN_Classify`) |
| `majorRedirect`, and its call in `greyObject`'s nursery branch | `NurseryRegion.cpp:217`; `OldGenSpace.cpp:3122-3133` | `Redir`, `MajorLive`, `MJ_Mark`, `TV1_Major` |
| `forEachYoung` (t0 young walk: Young extents + Tenuring) | `NurserySpace.hpp:800` | the t0 branch of `MN_Cycle` |
| `grantTenure` / `grantAllocate` / `grantAllocateShared` / `returnTenureGrant` | `OldGenTenure.cpp:44-340` | `grant`, `FreeGrant`, `E_Copy` |
| `ThreadLocalHeap::minorGC` (`tenureJoin` first, `TenureLaunchScope` on every return) | `ThreadLocalHeap.cpp:706-760` | `MN_Join` … `MN_Launch` order |
| `ThreadLocalHeap::majorGC` (`tenureJoin(…, 1)`, then cycle join, then mark) | `ThreadLocalHeap.cpp:783-800` | `MJ_Join`, `MJ_Cycle`, `MJ_Mark` |
| `GCBackgroundGang` launch / join / stopAndJoin / finishedApprox, fork hooks | `GCHelperPool.cpp:599-690` | `claunch`, `running`, `stop`, process `Env` (M6 models the gang itself) |

## 4. The model

### 4.1 Abstractions, and why each is sound

| Real thing | Model | Why it is sound (or where it over-approximates) |
|---|---|---|
| Objects at byte addresses, headers, tags | **cells**: eden cells, survivor cells `<<"S", x, c>>`, old cells; an object = a logical id plus `NF` pointer fields | Only pointer structure matters to forwarding. Cell reuse is kept, which is what makes stale shadow entries (timeline c) reachable |
| The shadow indexed by granule | `shadow[x][c]` indexed by cell | One entry per object start, exactly as the code's granule index gives |
| A tenuring object's header and size | not modelled (`heap[t]` is copied whole) | Headers of tenuring objects are never written (FORBID_HEAP_004), so reading them races with nothing |
| Phase 6's parallel eden copy in the pause | sequential (`MN_Slot` loop in the mutator process) | The pause is exclusive: the collector is joined first (`ThreadLocalHeap.cpp:722-733`), so the Retire shadow the drain reads is immutable. The pause's own parallelism is M3's model: M5 assumes M3's **`CopyOnceContract`** (PM1: one copy per eden object; at the join every slot, root and YLOS slot at that copy) |
| Exact engine item = one copy's whole scan | the same: `jstack` holds copies; popping one starts an item that runs its `NF` child slots in order, with `stop` checked only between items; the scan position `sc`/`si` is a procedure local (`scanCopy`'s C++ frame, not `SerialState`) | Exact. The review replaced a per-(copy, field) stack: its LIFO order differed from `scanCopy`'s at `NF > 1` (so traces of the real engine would be rejected), and a fork mid-scan could not lose the rest of a copy's scan as the code does |
| Exact engine: collector writes (copy, publish, fix) | separate labels | Faithful to A1. None of the written locations is readable by the mutator, so the split only adds stop and fork interleavings |
| L3 members' deques and termination | one shared `jstack` bag; `running` counts members still in the engine | The M2 contract **Drain** (a stop leaves all unscanned work where help finds it). M2 checks the real loop |
| Grant blocks, chunk claims, bitmap bytes | `grant` = the set of free old cells at launch; exact: `CHOOSE` (deterministic), L3: any | Placement determinism of the exact engine is kept. Byte-level bitmap races and the skip rule (no mutator path selects, frees or releases a `kAllocTenure` block: T6) are M4's (its mutants `grant_t0_block`, `grant_includes_cursor`, `shrink_ignores_tenure`). `OC >= MaxLid` makes exhaustion impossible, since an object is tenured at most once |
| 5c marking | abstract cycle: t0 greys (roots' and young objects' old targets), `black` copies, handoff frees `OldClose(grey) ∪ black` complement | The M1 contract **SnapshotCycle**. M5 checks the interface M1 assumes: t0 walk coverage, and `MarkerDisjoint` (the markers' closure holds no young cell, no grant cell and no black copy; mid-cycle every job copy is black). `black` is set only mid-cycle; the code's `grantAllocate` sets the bit always (it is the allocation record, `OldGenTenure.cpp:175-177`), which differs only outside cycles, where the bit means nothing to a marker |
| Builders, YLOS generations, large bodies | not in the core sketch | Each adds a recording path (builder slots go to S; YLOS reached or unreached). Listed in §8 as the next extension |
| Old objects that predate the model | `OldSeed = 1`: one old object at Init, held by a root | Every behaviour from it is a real one (an old object exists). Without it the first old object is a copy merged at minor 3, and the cycle mutants would need 6 minors |
| The ageing variant (k ≥ 2) | extension §8 | The mark/sweep/zap phases, with their own mutant |
| A fork | process `Env`: a stop at any time; mutant `fork_mid_item` removes the collector between any two of its steps | The prepare hook's stopAndJoin lands at an item boundary. A fork from a non-mutator thread can land anywhere (§7, finding F1). After `calive := FALSE` the model keeps the same mutator, i.e. it shows the child as if it had one, and launches no new collector (the code would start fresh threads in the child: `atforkChild` resets `started_`) |

### 4.2 Constants

| Constant | Meaning | Code | Quick | Deep |
|---|---|---|---|---|
| `EC` | eden cells per epoch | eden capacity | 2 (1 in `gen`, `wrap`) | 3 |
| `SC` | cells per survivor extent (≥ `EC`) | extent capacity | 2 (1 in `gen`, `wrap`) | 3 |
| `OC` | old-gen cells (`>= MaxLid`: an object is tenured at most once) | old gen | 4 (3 in `gen`, `wrap`) | 6 |
| `NF` | pointer fields per object | object fields | 1 | 2 |
| `Roots` | root slots | stack, RootSet, CellStore | `{1, 2}` | `{1, 2}` |
| `MaxLid` | objects per behaviour, the seeded old object included | — | 4 (3 in `gen`, `wrap`) | 6 |
| `OldSeed` | one old object at Init, held by a root | a program that ran before | 0 (1 in `quick_major`, `quick_cycle`) | 1 |
| `MaxMinors`, `MaxMajors` | bounds | — | 3–4 (6 in `gen`, `wrap`), 0–1 | 6, 1 |
| `TenureMode` | 1 = job in the hand-over pause, 2 = collector | `tenure_mode` | 2 (1 in `quick_sync`, `quick_major`, `quick_cycle`) | 2 |
| `Collectors` | 1 = exact engine, 2 = L3 | `tenure_collector_threads` | 1 (and 2) | 2 |
| `HelpAllowed` | stop a late collector and help | `tenure_help` | TRUE | TRUE |
| `MajorAllowed` | STW majors between minors | allocation-failure / explicit majors | per config | TRUE |
| `CycleAllowed`, `CycleT` | mark cycles, t0 → handoff distance | `incremental_mark`, T | per config, 1 | TRUE, 2 |
| `GenMod` | generations 1..GenMod−1 then wrap | 2²¹ | 8 (2 in `wrap`) | 8 |
| `StopAllowed` | fork prepare stops the collector | atfork | TRUE in `quick_exact`, `quick_sync`, `quick_l3`, `fork`; FALSE elsewhere | TRUE |
| `MUTANT` | §5 | — | `"none"` | `"none"` |

Every configuration also sets `defaultInitValue = defaultInitValue` (primer §2, rule 3).

### 4.3 Variables

| Variable | Meaning | Code counterpart | Written by |
|---|---|---|---|
| `heap[a]` | cell a: `lid` (0 = empty) and fields | the objects | mutator (alloc, eden only), pause (copy, heal, resolve, frees), collector (its grant cells only) |
| `root[r]` | root slots | stack/RootSet/external roots | mutator; pause (copy fix-up, resolve) |
| `lheap`, `lroot` | **ghost** logical graph: what the mutator would see with no GC | — | mutator |
| `ebump`, `xtop` | eden bump, fill top | `bump_.ptr`, `Extent::surv_top` | pause |
| `xstate`, `gen` | extent states, shadow generations | `Extent::state`, `Extent::gen` | pause |
| `shadow[x][c]` | forwarding table | `RegionState::shadow[x]` | collector / help (the tenuring extent only) |
| `job` | state (`None`/`Running`/`Merged`) and extent | `TenureJob::state`, `x` | pause |
| `jstarts`, `jheal`, `jstack`, `ns`, `nh` | job inputs and progress; `jstack` holds copies to scan | `SerialState` (`starts`, `heal`, `stack`, `next_start`, `next_heal`) | pause (inputs), engine (progress) |
| `sc`, `si` (Engine locals) | the copy being scanned and its next field | `scanCopy`'s C++ frame (lost if the thread dies) | engine |
| `grant` | old cells owned by the job | `TenureGrant` | pause |
| `stop`, `running`, `calive`, `claunch` | stop flag, members in the engine, collector thread exists, launch count | `J.stop`, gang `finished_`, thread existence, gang `generation_` | pause / gang / fork |
| `S`, `H` | the minor's pending start set and heal list; emptied when `MN_Launch` moves them into the job | `pend_S`, `pend_H` | pause |
| `cycle`, `grey`, `black`, `cage` | abstract mark cycle | `cycle_state_`, t0 greys, allocate-black bits, `cycle_k_` | pause, collector (black) |
| `liveHand` | **ghost**: legacy's promoted set at the hand-over | the legacy oracle (E1) | pause |
| `cw`, `ncopy` | **ghost**: cells the collector wrote (copies at `E_Copy`, and every slot `E_Fix` writes); copies per object | TV8 range checks; TV3 | collector |

### 4.4 Steps: model labels to code

| Label | Code | What it stands for |
|---|---|---|
| `M_Epoch` | Elm code | allocate from held values, load a field into a root, drop a root |
| `MN_Join` → `J_Wait`/`J_Stop`/`J_Help`/`J_Merge` | `ThreadLocalHeap.cpp:726`; `tenureJoin`; `mergeJob` | join or stop+join; help; heal; `Merged` (`TV1_Heal` and `TenuredEqualsLegacy` are checked in the state at `J_Merge`) |
| `MN_Begin` | `minorGCRegion` beginMinor (`NurseryRegion.cpp:699-724`) | choose fill / hand / retire |
| `MN_Slot`, `MN_Classify`, `MN_Fwd`, `MN_Set`, `MN_Resolve`, `MN_Next` | the roots phase (`:817`) and the drain (`:853`) via `evacuateR` | one slot per step: eden → copy; Hand → S (root) or H (heap slot); Retire → resolve (TV1) |
| `MN_Epilogue` | epilogue and endMinor (`:1021-1091`) | Retire → Free (cells emptied, shadow kept), eden cleared, Fill → Young, Hand → Tenuring; the dead `efwd` map is cleared |
| `MN_Cycle` | `startMarkCycle` / `stepMarkCycle` (`ThreadLocalHeap.cpp:1065-1190`) | handoff at T; or t0 with the young walk |
| `MN_Launch`, `MN_Sync` | `TenureLaunchScope` → `tenureLaunch` | gen bump or discard; inputs (`S`/`H` moved and emptied, as `pend_S.clear()`); grant; launch (mode 2) or run now (mode 1) |
| `MJ_Join`, `MJ_Cycle`, `MJ_Mark` | `majorGC` | join and merge (final); finish a running cycle; STW mark with `majorRedirect`; free unmarked old |
| `C_Wait`, `C_Run`, `C_Fin` | `GCBackgroundGang::memberLoop` → `tenureEntry` / `tenureConcEntry` | wait for a launch, run the engine, finish |
| `E_Loop` | `SerialEngine::run` | stop check between items (never inside a copy's scan) |
| `E_Item` | `SerialEngine::step`; `scanCopy`'s child loop | pop a copy and take its first child, or take the copy's next child, a start or a heal slot |
| `E_Load`, `E_Claim`, `E_WaitBusy` | `tenure` (exact: relaxed load, no claim); `TenureParEnv::tenure` (L3: acquire load, CAS, `waitPublished`) | the shadow protocol |
| `E_Copy`, `E_Pub`, `E_Fix` | `grantAllocate`/`grantAllocateShared` + `memcpy` + fixup; `publish` then `stack.push_back` (`TenureWork.hpp:265-266`); `childOfCopy`'s `*s = word(tenure(t))` | copy; publish FWD and push the copy; rewrite the copy's slot |
| `E_Ret` | `run` returning | guarded by `calive`, so a dead collector takes no step |
| `F_Maybe` | a fork on another thread: `atforkPrepare` → `stopAllForFork` | stop, or (mutant) the collector disappears mid-item |

### 4.5 The PlusCal sketch

File: `test/tla/M5-tenuring/Tenuring.tla`. This is the text that passed `pcal` and SANY
(tla2tools 1.8.0) on 2026-09-28, after the adversarial review's corrections (§12); SANY reports no
errors, only the translator's usual lint notes about the `pc` field of call-stack records. The
generated translation is omitted.

```tla
------------------------------ MODULE Tenuring ------------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    EC,             \* eden cells per epoch
    SC,             \* cells per survivor extent (>= EC: a fill never overflows)
    OC,             \* old-gen cells (>= MaxLid: each object is tenured at most once)
    NF,             \* pointer fields per object
    Roots,          \* root slots (stack slots, RootSet, CellStore cells ...)
    MaxLid,         \* objects in a behaviour, the seeded old object included
    OldSeed,        \* 1: one old object exists at Init, held by a root
    MaxMinors, MaxMajors,
    TenureMode,     \* 1 = the job runs in the hand-over pause; 2 = on the collector
    Collectors,     \* 1 = the exact engine (no claim); 2 = L3 members (claim CAS)
    HelpAllowed,    \* tenure_help = 1: a late collector is stopped and helped
    MajorAllowed,   \* STW majors between minors
    CycleAllowed,   \* incremental mark cycles (abstract: t0 greys, handoff)
    CycleT,         \* minors from t0 to the handoff
    GenMod,         \* shadow generations are 1 .. GenMod-1, then wrap (2^21 in code)
    StopAllowed,    \* a fork prepare hook may stop the collector at any time
    MUTANT

X == 1..3                                 \* survivor extents (k + 2, k = 1)
EAddr == {<<"E", c>> : c \in 1..EC}
SAddr == {<<"S", x, c>> : x \in X, c \in 1..SC}
OAddr == {<<"O", c>> : c \in 1..OC}
Addr == EAddr \cup SAddr \cup OAddr
Nil == <<"N">>
Fields == 1..NF
Empty == [lid |-> 0, f |-> [i \in Fields |-> Nil]]
NoEntry == [st |-> 0, dst |-> Nil, g |-> 0]           \* shadow: 0 unvisited, 1 BUSY, 2 FWD
IsE(a) == a # Nil /\ a[1] = "E"
IsS(a, x) == a # Nil /\ a[1] = "S" /\ a[2] = x
IsO(a) == a # Nil /\ a[1] = "O"
MutId == 0
CollIds == 101..(100 + Collectors)
EnvId == 200
R0 == CHOOSE r \in Roots : TRUE           \* the root that holds the seeded old object
Seed == <<"O", 1>>
RECURSIVE SetToSeq(_)
SetToSeq(S) == IF S = {} THEN <<>>
               ELSE LET e == CHOOSE y \in S : TRUE IN <<e>> \o SetToSeq(S \ {e})
Range(sq) == {sq[i] : i \in 1..Len(sq)}
NextGen(g) == IF g + 1 >= GenMod THEN 1 ELSE g + 1

(* --algorithm Tenuring
variables
    heap    = [a \in Addr |-> IF OldSeed = 1 /\ a = Seed
                              THEN [lid |-> 1, f |-> [i \in Fields |-> Nil]] ELSE Empty],
    root    = [r \in Roots |-> IF OldSeed = 1 /\ r = R0 THEN Seed ELSE Nil],
    lheap   = [l \in 1..MaxLid |-> [i \in Fields |-> 0]],   \* ghost: the logical graph
    lroot   = [r \in Roots |-> IF OldSeed = 1 /\ r = R0 THEN 1 ELSE 0],   \* ghost
    nextLid = 1 + OldSeed,
    ebump   = 1,                                   \* eden bump (bump_.ptr)
    xstate  = [x \in X |-> "Free"],                \* Free | Young (Fresh) | Tenuring
    xtop    = [x \in X |-> 1],                     \* the fill's LAB top (surv_top)
    gen     = [x \in X |-> 0],                     \* Extent::gen
    shadow  = [x \in X |-> [c \in 1..SC |-> NoEntry]],   \* RegionState::shadow
    job     = [st |-> "None", x |-> 0],            \* TenureJob::state, x
    jstarts = <<>>, jheal = <<>>, jstack = <<>>,   \* SerialState: starts, heal, stack (of copies)
    ns = 1, nh = 1,                                \* next_start, next_heal
    grant   = {},                                  \* TenureGrant: old cells owned by the job
    stop    = FALSE,                               \* TenureJob::stop
    running = 0,                                   \* collector members still in the engine
    calive  = TRUE,                                \* FALSE: the collector thread is gone (fork child)
    claunch = 0,                                   \* launch counter (GCBackgroundGang generation)
    minors  = 0, majors = 0,
    S = {}, H = {},                                \* pend_S, pend_H of the minor in progress
    cycle   = "Idle", grey = {}, black = {}, cage = 0,
    liveHand = {},                                 \* ghost: legacy's promoted set at the hand-over
    cw      = {},                                  \* ghost: cells the collector wrote this job
    ncopy   = [a \in SAddr |-> 0];                 \* ghost: copies made per tenuring object

define
    LidOf(a) == IF a = Nil THEN 0 ELSE heap[a].lid
    FwdOf(a) == LET e == shadow[a[2]][a[3]]
                IN IF e.st = 2 /\ e.g = gen[a[2]] THEN e.dst ELSE Nil
    Busy(a)  == LET e == shadow[a[2]][a[3]] IN e.st = 1 /\ e.g = gen[a[2]]
    XObjs(x) == {a \in SAddr : a[2] = x /\ heap[a].lid # 0}
    \* Reachability (fixpoints; no higher-order RECURSIVE operators in TLA+).
    RECURSIVE Close(_)
    Close(Sset) ==
        LET N == Sset \cup {heap[a].f[i] : a \in Sset \ {Nil}, i \in Fields}
        IN IF N = Sset THEN Sset ELSE Close(N)
    ReachAll == Close({root[r] : r \in Roots}) \ {Nil}
    OldClose(G) == Close(G) \ {Nil}
    \* majorRedirect: a merged job's extent is traversed through its copies.
    Redir(a) == IF a # Nil /\ job.st = "Merged" /\ IsS(a, job.x) /\ xstate[job.x] = "Tenuring"
                   /\ MUTANT # "major_greys_original"
                THEN FwdOf(a) ELSE a
    RECURSIVE CloseR(_)
    CloseR(Sset) ==
        LET N == Sset \cup {Redir(heap[a].f[i]) : a \in Sset \ {Nil}, i \in Fields}
        IN IF N = Sset THEN Sset ELSE CloseR(N)
    MajorLive == CloseR({Redir(root[r]) : r \in Roots})
    JobDone == jstack = <<>> /\ ns > Len(jstarts) /\ nh > Len(jheal)
    InEpoch == pc[MutId] = "M_Epoch"
    FreeGrant == {a \in grant : heap[a].lid = 0}
    \* ---- properties (all invariants; no assert, so every mutant names one) ----
    NoDangling ==                                  \* no reachable reference to freed memory
        InEpoch => \A a \in ReachAll : heap[a].lid # 0 /\ (a[1] = "S" => xstate[a[2]] # "Free")
    GraphPreserved ==                              \* GC never changes what the mutator sees
        InEpoch =>
            /\ \A r \in Roots : LidOf(root[r]) = lroot[r]
            /\ \A a \in ReachAll : heap[a].lid # 0 =>     \* a freed cell is NoDangling's
                   \A i \in Fields : LidOf(heap[a].f[i]) = lheap[heap[a].lid][i]
    CollectorPrivate ==                            \* FORBID_HEAP_004
        (running > 0 \/ job.st = "Running") => cw \cap ReachAll = {}
    ExactlyOnce == \A a \in SAddr : ncopy[a] <= 1  \* TV3
    OldPointsOld ==                                \* HEAP_005 (amended: copies until the merge)
        \A a \in OAddr : (heap[a].lid # 0 /\ ~(job.st = "Running" /\ a \in grant)) =>
            \A i \in Fields : heap[a].f[i] = Nil \/ IsO(heap[a].f[i])
    HealYoungOnly ==                               \* 07 T2, FORBID_HEAP_004: M1's open question 3
        job.st = "Running" =>
            \A s \in Range(jheal) : s[1] # Nil /\ s[1][1] = "S" /\ xstate[s[1][2]] = "Young"
    MarkerDisjoint ==                              \* TV8 + IM3: the contract M1 assumes
        cycle = "Marking" =>
            /\ OldClose(grey) \subseteq OAddr \ (grant \cup black)
            /\ (job.st = "Running" => cw \cap OAddr \subseteq black)
    YoungWalkValid ==                              \* CR-017: a possible t0 walk greys only allocated cells
        (pc[MutId] = "MN_Cycle" /\ CycleAllowed /\ cycle = "Idle") =>
            \A a \in {y \in SAddr : heap[y].lid # 0 /\ xstate[y[2]] \in {"Young", "Tenuring"}} :
                \A i \in Fields : IsO(heap[a].f[i]) => heap[heap[a].f[i]].lid # 0
    TenuredEqualsLegacy ==                         \* E1 oracle / TV2, checked as the merge starts
        (pc[MutId] = "J_Merge" /\ job.st = "Running") =>
            {a \in XObjs(job.x) : FwdOf(a) # Nil} = liveHand
    TV1_Heal ==                                    \* TV1 (every build): each heal target has FWD
        (pc[MutId] = "J_Merge" /\ job.st = "Running") =>
            \A s \in Range(jheal) :
                IsS(heap[s[1]].f[s[2]], job.x) => FwdOf(heap[s[1]].f[s[2]]) # Nil
    TV1_Major ==                                   \* TV1 at the STW major's redirect
        pc[MutId] = "MJ_Mark" =>
            \A q \in {root[r] : r \in Roots} \cup {heap[a].f[i] : a \in MajorLive \ {Nil}, i \in Fields} :
                (q # Nil /\ job.st = "Merged" /\ IsS(q, job.x) /\ xstate[job.x] = "Tenuring")
                    => FwdOf(q) # Nil
end define;

\* The engine (TenureWork.hpp SerialEngine; with Collectors > 1 the claim
\* protocol of TenureParEnv::tenure). One item = one start, one heal slot, or
\* one popped copy's whole scan (scanCopy: its NF child slots in order; `sc`
\* and `si` are scanCopy's C++ frame, not SerialState, so a thread that dies
\* mid-scan loses them). `canStop`: the collector honours stop between items;
\* help (the pause) does not.
procedure Engine(canStop)
variables tgt = Nil, fix = Nil, e = NoEntry, res = Nil, sc = Nil, si = 1;
begin
  E_Loop:
    while ~JobDone \/ sc # Nil do
        await ~canStop \/ calive;
        if canStop /\ stop /\ sc = Nil then return; end if;   \* run(): stop only between items
      E_Item:                                      \* SerialEngine::step / the next child of scanCopy
        await ~canStop \/ calive;
        if sc # Nil then                           \* child slot si of the copy being scanned
            tgt := heap[sc].f[si];
            fix := <<sc, si>>;
            if si < NF then si := si + 1; else sc := Nil; si := 1; end if;
        elsif jstack # <<>> then                   \* pop a copy (LIFO) and take its first child
            with c = jstack[Len(jstack)] do
                tgt := heap[c].f[1];
                fix := <<c, 1>>;
                if NF > 1 then sc := c; si := 2; end if;
            end with;
            jstack := SubSeq(jstack, 1, Len(jstack) - 1);
        elsif ns <= Len(jstarts) then              \* a start (S_m)
            tgt := IF MUTANT = "skip_start" /\ ns = 1 THEN Nil ELSE jstarts[ns];
            ns := ns + 1;
        elsif nh <= Len(jheal) then                \* a heal slot: its value, immutable under P1
            tgt := heap[jheal[nh][1]].f[jheal[nh][2]];
            if MUTANT = "collector_heals" then fix := jheal[nh]; end if;   \* trap 1
            nh := nh + 1;
        end if;
      E_Load:                                      \* shadow load (relaxed / acquire)
        await ~canStop \/ calive;
        if ~IsS(tgt, job.x) then
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
    end while;
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
            await running = 0 \/ ~calive;          \* join(): wait out the collector
        or
            await HelpAllowed /\ running > 0 /\ calive;
            stop := TRUE;                          \* stopAndJoin(): stop ...
          J_Stop:
            await running = 0 \/ ~calive;          \* ... and join
        end either;
      J_Help:
        if ~JobDone then call Engine(FALSE); end if;   \* help (runJobExact / runJobParallel)
    end if;
  J_Merge:                                         \* TV1_Heal, TenuredEqualsLegacy hold here
    if job.st = "Running" then
        heap := [a \in Addr |->
                   [heap[a] EXCEPT !.f = [i \in Fields |->
                       IF <<a, i>> \in Range(jheal) /\ IsS(heap[a].f[i], job.x)
                          /\ ~(MUTANT = "skip_heal" /\ <<a, i>> = jheal[1])
                       THEN FwdOf(heap[a].f[i]) ELSE heap[a].f[i]]]];
        job.st := "Merged";
        grant := {};
    end if;
  J_Ret:
    return;
end procedure;

\* The mutator: Elm code between pauses, the region minor, STW majors.
process Mutator = MutId
variables slots = <<>>, efwd = [a \in EAddr |-> Nil], fill = 0, hand = 0, retire = 0,
          cur = Nil, t = Nil, v = Nil;
begin
  M_Epoch:
    while TRUE do
        either                                     \* allocate from held values
            await ebump <= EC /\ nextLid <= MaxLid;
            with r \in Roots, fv \in [Fields -> {Nil} \cup {root[q] : q \in Roots}] do
                lheap[nextLid] := [i \in Fields |-> LidOf(fv[i])];
                heap[<<"E", ebump>>] := [lid |-> nextLid, f |-> fv];
                root[r] := <<"E", ebump>>;
                lroot[r] := nextLid;
                ebump := ebump + 1;
                nextLid := nextLid + 1;
            end with;
        or                                         \* load a field into a root
            with r \in Roots, q \in {q2 \in Roots : root[q2] # Nil}, i \in Fields do
                root[r] := heap[root[q]].f[i];
                lroot[r] := IF lroot[q] = 0 THEN 0 ELSE lheap[lroot[q]][i];   \* 0 only in a broken state
            end with;
        or                                         \* drop a root
            with r \in Roots do root[r] := Nil; lroot[r] := 0; end with;
        or
            await minors < MaxMinors;
            goto MN_Join;
        or
            await MajorAllowed /\ majors < MaxMajors;
            goto MJ_Join;
        end either;
    end while;

  \* ---- ThreadLocalHeap::minorGC -> tenureJoin, minorGCRegion, tenureLaunch ----
  MN_Join:
    call JoinMerge();
  MN_Begin:                                        \* beginMinor: roles
    minors := minors + 1;
    fill := CHOOSE x \in X : xstate[x] = "Free";
    hand := IF \E x \in X : xstate[x] = "Young" THEN CHOOSE x \in X : xstate[x] = "Young" ELSE 0;
    retire := IF \E x \in X : xstate[x] = "Tenuring" THEN CHOOSE x \in X : xstate[x] = "Tenuring" ELSE 0;
    xtop[fill] := 1;
    efwd := [a \in EAddr |-> Nil];
    S := {}; H := {};
    slots := SetToSeq({<<"root", r>> : r \in Roots});
  MN_Slot:                                         \* evacuateR, one slot per step
    while slots # <<>> do
        cur := Head(slots);
        t := IF Head(slots)[1] = "root" THEN root[Head(slots)[2]]
             ELSE heap[Head(slots)[2]].f[Head(slots)[3]];
        slots := Tail(slots);
      MN_Classify:                                 \* TV1_Resolve holds here
        if IsE(t) then                             \* Eden: claim/copy into the fill (once)
            if efwd[t] = Nil then
                heap[<<"S", fill, xtop[fill]>>] := heap[t];
                efwd[t] := <<"S", fill, xtop[fill]>>;
                slots := slots \o SetToSeq({<<"fld", <<"S", fill, xtop[fill]>>, i>> : i \in Fields});
                xtop[fill] := xtop[fill] + 1;
            end if;
          MN_Fwd:
            v := efwd[t];
          MN_Set:
            if cur[1] = "root" then root[cur[2]] := v;
            else heap[cur[2]].f[cur[3]] := v; end if;
        elsif hand # 0 /\ IsS(t, hand) then        \* Hand: record, no header load
            if cur[1] = "root" /\ MUTANT # "no_root_starts" then S := S \cup {t};
            elsif cur[1] = "fld" then H := H \cup {<<cur[2], cur[3]>>}; end if;
        elsif retire # 0 /\ IsS(t, retire) then    \* Retire: resolve through the shadow
            v := FwdOf(t);
          MN_Resolve:
            if MUTANT # "no_resolve" then
                if cur[1] = "root" then root[cur[2]] := v;
                else heap[cur[2]].f[cur[3]] := v; end if;
            end if;
        end if;
      MN_Next:
        cur := Nil; t := Nil; v := Nil;
    end while;
  MN_Epilogue:                                     \* retire G_{m-2}, clear eden, endMinor
    heap := [a \in Addr |-> IF IsE(a) \/ (retire # 0 /\ IsS(a, retire)) THEN Empty ELSE heap[a]];
    xstate := [x \in X |-> IF x = fill THEN "Young"
                           ELSE IF x = hand THEN "Tenuring"
                           ELSE IF x = retire THEN "Free" ELSE xstate[x]];
    ebump := 1;
    efwd := [a \in EAddr |-> Nil];                 \* dead after the minor
  MN_Cycle:                                        \* stepMarkCycle / startMarkCycle (abstract)
    if cycle = "Marking" then
        cage := cage + 1;
        if cage >= CycleT then                     \* handoff: free what was dead at t0
            heap := [a \in Addr |-> IF IsO(a) /\ a \notin (OldClose(grey) \cup black)
                                    THEN Empty ELSE heap[a]];
            cycle := "Idle"; grey := {}; black := {};
        end if;
    elsif CycleAllowed then
        either
            skip;
        or                                         \* t0: roots and the young walk (forEachYoung)
            with G = {root[r] : r \in Roots}
                     \cup {heap[a].f[i] : a \in {y \in SAddr :
                              heap[y].lid # 0 /\ (xstate[y[2]] = "Young"
                              \/ (xstate[y[2]] = "Tenuring" /\ MUTANT # "t0_skips_tenuring"))},
                           i \in Fields} do
                \* snapshot mode drops young targets (greyObject, OldGenSpace.cpp)
                grey := IF MUTANT = "t0_keeps_young" THEN G \ {Nil} ELSE G \cap OAddr;
            end with;
            black := {};
            cycle := "Marking";
            cage := 0;
        end either;
    end if;
  MN_Launch:                                       \* tenureLaunch (the scope-exit object)
    if \E x \in X : xstate[x] = "Tenuring" then
        with x = CHOOSE y \in X : xstate[y] = "Tenuring" do
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
        end with;
        jstarts := SetToSeq(S); jheal := SetToSeq(H); jstack := <<>>;
        ns := 1; nh := 1;
        grant := IF MUTANT = "grant_t0_block" /\ cycle = "Marking" THEN OAddr   \* TV5's control
                 ELSE {a \in OAddr : heap[a].lid = 0};   \* grantTenure (virgin / partial blocks)
        cw := {};
        ncopy := [a \in SAddr |-> 0];
        stop := FALSE;
        if TenureMode = 2 /\ calive then
            running := Collectors;
            claunch := claunch + 1;
        end if;
    end if;
    S := {}; H := {};                              \* pend_S / pend_H moved into the job
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
        heap := [a \in Addr |-> IF IsO(a) /\ a \notin (OldClose(grey) \cup black)
                                THEN Empty ELSE heap[a]];
        cycle := "Idle"; grey := {}; black := {};
    end if;
  MJ_Mark:                                         \* STW mark with majorRedirect; TV1_Major holds here
    heap := [a \in Addr |-> IF IsO(a) /\ a \notin MajorLive THEN Empty ELSE heap[a]];
    goto M_Epoch;
end process;

\* The tenure collector (GCBackgroundGang "eco-tenure"): one member runs the
\* exact engine; with Collectors > 1 the members share the job (L3).
fair process Collector \in CollIds
variables seen = 0;
begin
  C_Wait:
    await claunch > seen /\ calive;
    seen := claunch;
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
\* END TRANSLATION

\* Properties over the mutator's process variables (after the translation,
\* where they are declared).
TV1_Resolve ==                                     \* TV1 at resolveRetire (every build)
    (pc[MutId] = "MN_Classify" /\ retire # 0 /\ IsS(t, retire)) => FwdOf(t) # Nil
=============================================================================
```

Notes on the sketch:
- **Stop in the pause.** `stop` is only checked at `E_Loop`, and only when no copy is being
  scanned (`sc = Nil`), so a stop always lands between items, as in `SerialEngine::run`. Help calls
  `Engine(FALSE)`, which ignores both `stop` and `calive`.
- **No `assert`s.** TV1 and the legacy oracle are named invariants over `pc` (`TenuredEqualsLegacy`
  and `TV1_Heal` at `J_Merge`, `TV1_Resolve` at `MN_Classify`, `TV1_Major` at `MJ_Mark`). A TLC
  assertion failure has no invariant name for the runner to match (parent plan §6.1), and it fires
  whatever the configuration lists, so it would pre-empt a mutant's named target. `TV1_Resolve`
  reads the mutator's process variables `t` and `retire`, so it sits after the translation, where
  they are declared.
- **`liveHand`** is computed at the hand-over as "objects of the extent reachable from the roots
  then". HEAP_005 guarantees that old objects never point into the extent, so that set is exactly
  what `evacuateR`'s S/H recording must lead the job to.
- **`MN_Slot` iterates roots first, then the field slots of each copy as it is made.** That is the
  code's roots-then-drain order, sequentialised.
- **The mutator writes only eden cells and roots.** That is P1 (HEAP_SNAPSHOT_001): survived
  objects are never written. Builders are the exception to P1 and are §8's first extension.
- **`E_Pub` publishes and then pushes in one step.** In the code the push is a separate plain
  write after the release store (`TenureWork.hpp:265-266`). Merging them hides one fork-kill state
  (a copy published but never scanned); it matters only for a fix of CR-013 that makes items
  restartable (§7).
- **Dead state is cleared** (primer §4.2): `efwd` at `MN_Epilogue`, `S`/`H` at `MN_Launch`, the
  engine's locals at `E_Fix`.
- **`E_WaitBusy` is unreachable with `Collectors = 1`.** The exact engine aborts on a BUSY entry of
  its generation (`TenureWork.hpp:257-260`); no claim ever creates one there.

### 4.6 The properties, explained

| Property | Kind | What it says | A violation looks like |
|---|---|---|---|
| `NoDangling` | invariant (in the mutator's epoch) | every object reachable from the roots is allocated, and not in a Free (retired) extent | a heal slot skipped, so after retirement a Fresh object's field points into the Free extent (TV7); or a copy freed by a major that the next minor then resolves to |
| `GraphPreserved` | invariant (epoch) | the graph the mutator sees, compared by logical id, equals the ghost logical graph | a stale FWD entry believed (timeline c): a field now names a different object |
| `CollectorPrivate` | invariant | while a collector runs or its job is unmerged, no cell it wrote (copies, and every slot `E_Fix` stored) is reachable from the roots (FORBID_HEAP_004) | a merge while the collector still runs; the collector writing a heal slot itself (07 trap 1) |
| `ExactlyOnce` | invariant | at most one copy per tenuring object per job (TV3) | two L3 members copying one object without the claim |
| `OldPointsOld` | invariant | old objects point only to old objects, except a running job's grant cells (HEAP_005 as amended) | a copy whose child slot was never fixed survives the merge |
| `HealYoungOnly` | invariant | while a job is unmerged, every heal slot is a field of an object in the Fresh (Young) extent: the merge never writes an old object's field (07 T2; M1's open question 3) | a copy's child slot handed to the heal instead of fixed by the engine |
| `MarkerDisjoint` | invariant | during a cycle, the markers' closure `OldClose(grey)` holds only old cells, none in the grant and none black; and every copy the running job made is black (TV8 + IM3: the contract M1 assumes) | young targets kept at t0; a t0 cell granted; a copy not allocated black |
| `YoungWalkValid` | invariant (at `MN_Cycle`, when a t0 is possible) | every old target of every object the t0 walk would visit (all non-empty cells of the Young and Tenuring extents, dead ones included) is an allocated cell, so the t0 greys are allocated old cells (CR-017; M1 §10 Q4) | **expected to fail today** with a STW major and cycles both on: a Tenuring object that died in the last epoch keeps its only reference to an old object; the major, marking from roots only, frees that object; the next t0 walk greys the freed cell |
| `TenuredEqualsLegacy` | invariant (at `J_Merge`) | the forwarded objects of the extent are exactly `liveHand`, legacy's promoted set (E1; TV2) | a start skipped; a root into Hand not recorded in S; a start taken by a collector that then died (CR-013) |
| `TV1_Heal` | invariant (at `J_Merge`) | every heal target in the extent has FWD (TV1) | a merge before the join |
| `TV1_Resolve` | invariant (at `MN_Classify`) | every reference into Retire finds FWD (TV1, every build) | the job missed an object that a root still holds |
| `TV1_Major` | invariant (at `MJ_Mark`) | TV1 at the STW major's redirect | a merged job that missed an object a root still holds |

Liveness ("every launched job is eventually merged") holds by construction here: the mutator
decides when minors happen, and help finishes a late job. The loop's own termination is M2's
`AllExit`. Add `<>(job.st # "Running")` under fairness only if a configuration forces minors.

## 5. Negative controls (mutants)

Each mutant configuration is its host configuration plus `MUTANT`, with **only the target
invariant** on its `INVARIANTS` line (parent plan §6.1). The sketch has no `assert`, so nothing
else can stop TLC first. "Shortest" is a hand-derived behaviour within the host's bounds (lids
count the seeded object).

| `MUTANT` | Code change it represents | Existing hook | Host | Must violate | Shortest behaviour |
|---|---|---|---|---|---|
| `skip_start` | the engine skips a start entry | `test_tenure_skip_start_every_` | `quick_exact` | `TenuredEqualsLegacy`; also `TV1_Resolve` (same host), `TV1_Major` (`quick_major`) | root → o; minor 1 copies o into A; minor 2 hands A over (S = {o}); the job skips it; minor 3 at `J_Merge` (3 minors, 1 lid; with a major after minor 2 for `TV1_Major`) |
| `skip_heal` | the merge skips one heal slot | `test_heal_skip_one_` | `quick_exact` | `NoDangling` | o in A; e → o allocated in epoch 1; minor 2 records `e'.f` in H; minor 3 skips the heal and frees A; the epoch after it reads `e'.f` (3 minors, 2 lids) |
| `no_root_starts` | roots into Hand are not recorded in S | — | `quick_exact` | `TenuredEqualsLegacy` | as `skip_start` |
| `no_resolve` | references into Retire are not resolved | — | `quick_exact` | `NoDangling` | root → o; minor 3 frees A with the root still in it (3 minors, 1 lid) |
| `merge_before_join` | the merge runs without waiting for the collector | — | `quick_exact` | `CollectorPrivate`; also `TV1_Heal` | as `skip_heal`, the collector publishes o's copy, minor 3 merges while it still runs (3 minors, 2 lids); for `TV1_Heal`, minor 3 merges before it publishes |
| `collector_heals` | the collector writes the heal slot itself (07 trap 1) | — | `quick_exact` | `CollectorPrivate` | as `skip_heal`, up to the heal item in epoch 2 (2 minors, 2 lids) |
| `skip_fix` | `childOfCopy` does not store the child's copy into the copy's slot | — | `quick_exact` | `OldPointsOld` | o1 → o2 both copied into A at minor 1; job 2 copies both; minor 3's merge leaves `o1''.f` in A (3 minors, 2 lids) |
| `copy_slot_in_heal` | a copy's child slot is handed to the heal instead of being fixed (as if the 07b mark's `markTarget` were fed a copy) | — | `quick_exact` | `HealYoungOnly` | as `skip_fix`, up to the scan of `o1''` in epoch 2 (2 minors, 2 lids) |
| `gen_not_bumped` | `tenureLaunch` does not bump `gen` | — | `gen` | `GraphPreserved` | a in A, tenured by job 2 (FWD in cell A.1); b copied into A.1 at minor 4; c → b copied at minor 5 (H = {`c'.f`}); job 5 believes the stale FWD; minor 6 heals `c'.f` to a's copy (6 minors, 3 lids) |
| `wrap_no_discard` | gen wraps without `shadow.discard` | — | `wrap` | `GraphPreserved` | as `gen_not_bumped`: with `GenMod = 2` the second hand-over of A wraps back to gen 1 |
| `major_greys_original` | the STW mark greys the original, not the copy | (`majorRedirect` disabled) | `quick_major` | `NoDangling` | root → o; job 2 copies it; a STW major frees the copy; minor 3 resolves the root to it (3 minors, 1 major, 2 lids) |
| `t0_skips_tenuring` | `forEachYoung` skips the Tenuring extent | (`test_snapshot_skip_young_walk_` skips all young) | `quick_cycle` | `NoDangling` | the seed held only by t in A; t0 at minor 2 misses it; job 2's black copy of t is never scanned; minor 3's handoff frees the seed (3 minors, 2 lids) |
| `copy_not_black` | job copies not allocated black mid-cycle | (`test_skip_allocate_black_`) | `quick_cycle` | `MarkerDisjoint` (at the copy); a second configuration targets `NoDangling` (the handoff frees the copy) | t0 at minor 2, job 2 copies (2 minors; 3 for `NoDangling`) |
| `t0_keeps_young` | the t0 snapshot keeps young targets (no snapshot-mode drop in `greyObject`) | — | `quick_cycle` | `MarkerDisjoint` | t0 at minor 1 with a root on a fill copy (1 minor, 2 lids) |
| `grant_t0_cells` | the grant takes a block holding t0-live cells (cell form of `test_grant_t0_block_`; the byte form is M4's `grant_t0_block`) | (`test_grant_t0_block_`) | `quick_cycle` | `MarkerDisjoint` | the seed greyed at a t0 in minor 2; job 2's grant contains it (2 minors) |
| `l3_no_claim` | L3 members publish without the claim CAS | — | `quick_l3` | `ExactlyOnce` | o is both a start and a heal target; the two members take one each and both copy (2 minors, 2 lids) |
| `fork_mid_item` | a fork from a non-mutator thread snapshots the collector mid-item (§7 F1) | — | `fork` | **expected to fail**: `TenuredEqualsLegacy` (CR-013) | the collector takes o's start and dies; minor 3 finds the job done and merges without o (3 minors, 1 lid) |
| `skip_zap` (k = 2) | the merge does not zap dead ageing objects | `test_skip_zap_` | `ageing_k2` (§8) | `YoungWalkValid` (§8) | §8.3 |

**CR-017 is an expected violation today, not a mutant.** The model keeps dead Tenuring objects
(k = 1 has no zap: `mergeJob` zaps only 07b's ageing extents, `NurseryTenure.cpp:816-825`), and
`MJ_Mark` frees every old cell outside `MajorLive`, which is computed from the roots only, as
`OldGenSpace::startMark` does (`OldGenSpace.cpp:2881-2889`). So configuration `cycle_major` fails
`YoungWalkValid`. Shortest behaviour (2 minors, 1 major, 2 lids): y → seed allocated in epoch 0
and the seed's root dropped; minor 1 copies y into A; y's root is dropped; the STW major frees the
seed; minor 2 hands A over (Tenuring), and at `MN_Cycle` y's field names the freed seed. A step
later `MarkerDisjoint` also fails, because the next launch grants the freed cell. Once CR-017 is
fixed, the unfixed behaviour becomes the negative control (mutant `no_cr017_fix`), and
`cycle_major` flips to "pass".

Traps with no mutant, and why:
- **07 trap 6** (launch before the cycle decision) needs a second launch site before `MN_Cycle`.
  Its effect, white copies freed at the handoff, is `copy_not_black`'s.
- **07 trap 11** (a claim CAS against zero instead of the observed stale word) only livelocks an
  L3 member. No safety invariant sees it; it needs a liveness property (`<>JobDone` under
  fairness), which is not planned.
- **07 trap 8** (a root recorded in H) needs root slots in the heal list. Add it with the builders
  extension (§8.1), which already touches recording.

## 6. Configurations

`MC.tla` is just `EXTENDS Tenuring`, since every constant is a plain value.

| Config | Key constants | Tier | Expected |
|---|---|---|---|
| `quick_exact` | EC = SC = 2, OC = 4, NF = 1, `Roots = {1, 2}`, MaxLid = 4, OldSeed = 0, 4 minors, no majors or cycles, mode 2, 1 collector, help, stops, GenMod = 8 | quick | pass |
| `quick_sync` | as `quick_exact`, `TenureMode = 1` (the determinism reference) | quick | pass |
| `quick_major` | as `quick_exact` with OldSeed = 1, 3 minors, `MajorAllowed`, `MaxMajors = 1`, `TenureMode = 1`, no stops | quick | pass |
| `quick_cycle` | as `quick_exact` with OldSeed = 1, 3 minors, `CycleAllowed`, `CycleT = 1`, `TenureMode = 1`, no stops | quick | pass |
| `quick_l3` | as `quick_exact` with `Collectors = 2`, 3 minors | quick | pass |
| `gen` | as `quick_exact` with EC = SC = 1, OC = 3, MaxLid = 3, 6 minors, no stops | quick | pass. The only quick configuration that reaches an extent's second hand-over (minor 5, merged at minor 6), where timeline (c)'s stale entry exists |
| `wrap` | as `gen` with GenMod = 2: every hand-over after the first wraps and discards | quick | pass |
| `cycle_major` | `quick_cycle` + `MajorAllowed`, `MaxMajors = 1`; only `YoungWalkValid` | quick | **expected: violates `YoungWalkValid`** (CR-017, M1 §10 Q4) until it is fixed |
| `deep` | EC = SC = 3, OC = 6, NF = 2, MaxLid = 6, OldSeed = 1, 6 minors, majors + cycles (`CycleT = 2`), mode 2, `Collectors = 2` | deep | **expected: violates `YoungWalkValid`** (CR-017) until it is fixed; majors and cycles together reach it |
| `deep_major`, `deep_cycle` | `deep` without cycles, and `deep` without majors | deep | pass. They are the passing deep runs until CR-017 is fixed |
| `fork` | `quick_exact` + `MUTANT = "fork_mid_item"`, target `TenuredEqualsLegacy` | quick | **fails** (CR-013) until the fork window is closed or CR-013 exits with CR-004 |
| `ageing_k2` | the §8 extension, k = 2 (4 survivor extents) | deep | pass; with `skip_zap` it fails |

Mutant configurations (§5) are named `mut_<mutant>` (plus a suffix for a second target) and list
one invariant. The invariants line of every passing configuration is:
`INVARIANTS NoDangling GraphPreserved CollectorPrivate ExactlyOnce OldPointsOld HealYoungOnly
MarkerDisjoint YoungWalkValid TenuredEqualsLegacy TV1_Heal TV1_Resolve TV1_Major`.
`YoungWalkValid` can fail only where `MajorAllowed` and `CycleAllowed` are both on. Without a STW
major, a handoff frees only cells that no object alive at t0 referenced, and the next t0 walk
sees only objects copied after that t0.

**Why `quick_major` and `quick_cycle` run the job in the pause (`TenureMode = 1`).** This is the
split along the one real seam, inside one module. A STW major meets a running collector only in
`JoinMerge`, the same procedure every minor runs, and `quick_exact` checks it against a concurrent
collector. A mark cycle's t0 and handoff happen in pauses in which no job runs: the previous job
is merged at the pause's start and the next is launched at its end. So the redirect, the t0 walk
and allocate-black depend only on a merged job's state, and mode 1 produces that state with far
fewer interleavings. `deep` runs both in mode 2. If the one module still exceeds the budget, make
the split physical: a second module for majors and cycles with the job as one atomic pause step.

**Sizing.** No TLC numbers exist yet. The mutants were chosen so that every quick one needs at most
3 minors, except `gen_not_bumped` and `wrap_no_discard`: with three extents, the second hand-over
of an extent is at minor 5 and its merge at minor 6, so those two need 6 minors. That is why they
have their own one-cell configurations. The levers, in order:
1. `MaxLid = 3`;
2. `MaxMinors = 3` in `quick_exact` (three minors are the fewest that include a full hand-over,
   tenure and retire cycle);
3. the physical split above.

`OC >= MaxLid` rules out grant exhaustion, since each object is tenured at most once. So a
passing configuration that blocks in `E_Copy`'s `await FreeGrant # {}` has a model bug (the code
would `grantFatal`).

## 7. Accuracy notes (parent plan rules A1–A9) and a finding

| Rule | M5 |
|---|---|
| A1 | The collector's steps are one shadow load, one CAS (L3), one grant allocation plus copy, one publish (merged with the private push that follows it), one slot fix. An item is one start, one heal slot or one popped copy's whole scan, as in the code, and stop is checked only between items (`E_Loop` with `sc = Nil`). Everything the exact engine reads is immutable or job-private, and nothing it writes is mutator-readable, so its fine split adds only stop and fork-kill points. Pause steps are sequential and exclusive, so each pause label may do more. |
| A2 | Shadow entries are whole 64-bit words (state, dst and gen change together, as with `make`). Heal slots are whole pointer slots written only in the pause. Bitmap bytes are M4's. |
| A3 | The 7c plan's footprint table, row by row. **T1** tenuring objects: `heap` cells of `job.x`, collector-read-only. **T2** heal slots: `heap[jheal[·]]`, read by the collector, written only in `J_Merge`. **T3** generation YLOS: not in the core sketch (§8). **T4** shadow: `shadow[job.x]`, written by the collector, read by the pause after the join. **T5** grant cells: `grant`, `E_Copy`. **T6** `blocks_`/`partial_`/free lists: abstracted (the grant is fixed at launch, and the model's mutator never allocates old); the skip rule that keeps every mutator path off granted blocks is M4's (`grant_t0_block`, `grant_includes_cursor`, `shrink_ignores_tenure`). **T7** job-private state: `jstarts`/`jheal`/`jstack`/`ns`/`nh`. **T8** eden, roots: mutator and pause only; `CollectorPrivate` checks the collector never reaches them. **T9** config: constants. **T10** helper jobs: M7. **T11** 5c markers: the abstract cycle and `MarkerDisjoint`. Census (2026-09-28) of `TenureWork.hpp`, `NurseryTenure.cpp`, `OldGenTenure.cpp`, `NurseryRegions.hpp`: every atomic is a shadow word (T4), `J.stop`, a grant chunk-claim word (`OldGenTenure.cpp:234-249`, M4), a `reached[]`/`age_ylos_marked[]` byte (T3, §8), an ageing-mark bitmap word (pause-only gang, §8.3), `bld_bottom` (pause-only), a worker's `priv`, or a stats counter (`J.cpu_ns`). None is missing from T1–T11. |
| A4 | **W5** covers the shadow's claim, copy and publish: L3 members read each other's entries with acquire loads. The exact engine loads entries relaxed (`TenureWork.hpp:255`) and publishes them with release (`publish`, `:85`); the pause reads them after the join. **W1** covers the Chase–Lev deque that the L3 and age engines use. The gang launch and join publication is M6's LaunchJoin contract. |
| A5 | §9 lists the events and hooks. |
| A6 | §5. Every invariant has at least one mutant, each with a hand-derived shortest behaviour inside its host's bounds, and each existing 7c test hook has one. The exception is `YoungWalkValid`: the current code violates it (CR-017, `cycle_major`), and its mutant `no_cr017_fix` arrives with the fix. |
| A7 | `NoDangling` = TV7 plus HEAP_069's retirement premise; `GraphPreserved` = the legacy oracle (E1) at the level of graphs; `CollectorPrivate` = FORBID_HEAP_004; `ExactlyOnce` = TV3; `OldPointsOld` = HEAP_005 as amended; `HealYoungOnly` = 07 row T2 and FORBID_HEAP_004 (M1's open question 3); `MarkerDisjoint` = TV8 + IM3; `YoungWalkValid` = CR-017 (the k = 1 form of 07b's TV2Y); `TenuredEqualsLegacy` = E1's promoted-set equality (TV2); `TV1_Heal`, `TV1_Resolve`, `TV1_Major` = TV1 (every build). |
| A8 | 3 survivor extents, 1–3 cells each, 1–2 fields, 3–6 minors. **Generations**: the 21-bit field shrinks to a 1-bit one (`GenMod = 2`, gens {1}) in `wrap`, so every hand-over after the first wraps and must discard. `gen` keeps `GenMod = 8` and reaches the normal stale-generation case of timeline (c). Neither is reachable in 4 minors, since an extent's second hand-over is at minor 5. |
| A9 | `file`: `TenureWork.hpp`. `region`: `tenureLaunch`, `tenureJoin`, `mergeJob`, `runJobExact`, `tenureEntry`, `runJobParallel`, `TenureParEnv::tenure`/`reachYlos`/`childOfCopy`/`spineRun`, `tenureConcLaunch`/`tenureConcEntry`/`tenureConcFinish`; `evacuateR`, `resolveRetire`, `majorRedirect` and its call in `greyObject` (`OldGenSpace.cpp:3122-3133`), `minorGCRegion`'s beginMinor / epilogue / endMinor blocks; `forEachYoung` and its call in `startMarkCycle`; `grantTenure`, `grantAllocate`, `grantAllocateShared`, `returnTenureGrant`; `ThreadLocalHeap::minorGC`'s join and `TenureLaunchScope`; `majorGC`'s join. `census`: `NurseryTenure.cpp`, `NurseryRegion.cpp`, `OldGenTenure.cpp`, `TenureWork.hpp`. `grep`: the T1–T11 greps from 7c Step 0. |

**Finding F1 (register entry CR-013, Suspected; not yet reproduced).** This is the tenure
analogue of CR-004.

1. `GCBackgroundGang::atforkPrepare` (`GCHelperPool.cpp:664-669`) runs `stopAllForFork` and only
   then locks each gang's mutex.
2. If the fork comes from a thread other than the mutator, the mutator can reach `tenureLaunch` in
   that window and launch the collector (`NurseryTenure.cpp:572`, or `:1234` for L3).
3. The fork then snapshots a collector **mid-item**. `SerialEngine::step` (`TenureWork.hpp:277-320`)
   advances `next_start` / `next_heal`, or pops `stack`, before the item's copy and publish finish.
4. In the child, `tenureJoin`'s orphan path finishes the job from `SerialState`, and that item is
   skipped. The object is never tenured, and TV1 aborts at the child's next resolve (every build).
   For L3, the dead members' ring entries are lost the same way.

The precondition is the same as CR-003/004: a fork from a non-mutator thread, such as an embedding
host. The `fork` configuration is the model-level reproduction. Step 2's window is real in the
code: a member that reacquired `m_` in `cv_start_.wait` and left the scoped block
(`GCHelperPool.cpp:575-588`, `memberLoop`) runs `fn` outside `m_`, so prepare's later `m_.lock()` does not stop
it. (A member still waiting for `m_` when prepare takes it never starts in the parent's image.)

**The half-done items a dying exact collector can leave** (review, 2026-09-28). The model reaches
the first three; the fourth is merged away by `E_Pub` (§4.5 notes):
1. item taken, nothing copied: a start or heal target skipped (`TenuredEqualsLegacy`, then TV1);
2. copied, not published: an orphan grant cell, and help copies the object again (`ExactlyOnce`;
   in the code TV3/TV4 abort in validate builds);
3. a copy's scan cut short (`NF > 1`): the rest of its slots keep pointing into the extent, which
   is retired at the next minor (`OldPointsOld`, then `NoDangling`; TV6 at the merge in validate
   builds);
4. published, not pushed: the copy is never scanned, with the same effect as 3.

For **L3** the child also inherits any BUSY entry a dying member held. Help's `waitPublished`
then spins forever. A model run of `fork_mid_item` with `Collectors = 2` would report a
**deadlock** (the mutator blocked in `E_WaitBusy`), not an invariant violation. Such a
configuration must expect that outcome explicitly.

**The model's child keeps a mutator.** Whether any real child runs this heap again is CR-004's
open question: a child forked by another thread has no thread that owns the heap. If CR-013 exits
with CR-004, the `fork` configuration becomes a documented "would be S1 if the child used the heap"
result, not a gate.

## 8. Extensions (in order)

1. **Builders.** An eden object may be a builder, which a kernel may write while it is young (with
   held values). Builders are copied into the fill's builder area at every minor and never
   promoted. Their slots into Hand go to **S**, not H (`evacuateR` with `col == kColBuilder`).
   - **Delta:** a `builder` flag per object; a mutator action "write a held value into a young
     builder's field"; the pause copies builders again from the previous fill's builder area
     (Role `PrevBuilders`).
   - **Check:** the same invariants, plus HEAP_BUILDER_001 (a builder is never tenured).
   - **Mutants:** `builder_in_survivor` (07 trap 13: a builder copied into the fill's survivor
     part, so the job reads it while a kernel writes it; must violate `GraphPreserved`), and
     `root_in_heal` (07 trap 8: a root or builder slot recorded in H, so the heal writes a slot
     the mutator has since reused; needs heal entries for root slots; must violate
     `GraphPreserved`).
2. **Generation YLOS.** A large young object is never copied. It belongs to the generation that
   first reached it, is snapshotted at hand-over, is scanned read-only by the job (with `reached[]`
   set by an atomic exchange in L3), and is promoted in place at the merge if reached, else freed.
   - **Delta:** YLOS cells in the old region with a `young` flag.
   - **Checks:** "a reached YLOS object is promoted and its tenured children resolved at the merge
     (TV1)"; "an unreached one is freed and unreferenced".
   - **Widen `HealYoungOnly`** to "a Fresh object or a young YLOS of generation m". Add the merge's
     step 3 to the pause-write check: it writes the child slots of a generation-(m−1) YLOS right
     after promoting it (`NurseryTenure.cpp:736-741`). `MarkerDisjoint` must then show that no
     marker reaches that object. This is the half of M1's open question 3 the core cannot
     express.
3. **Ageing, k = 2** (`plans/threaded-gc-07b-tenure-ageing.md`). Four survivor extents (fill, one
   Age extent, Hand, Retire).
   - **Delta, pause:** references into Age go to `SA` (targets).
   - **Delta, job:** a **mark** phase from `SA` over the Age extent (read-only; each marked
     object's slot into Hand joins `heal`); a **sweep** that lists the gaps between marked objects
     as `zap` spans.
   - **Delta, merge:** zaps (dead Age objects become fillers).
   - Age extents' states carry `age`.
   - **Extend `YoungWalkValid`** (already in the core for old targets, CR-017) to Age extents and
     to young targets: every object `forEachYoung` would visit has only fields that point to
     allocated, non-Free cells. Without the zap, a dead Age object keeps a field pointing into a
     retired extent, and the t0 walk and the validators read it.
   - **Mutant `skip_zap`** (`test_skip_zap_`).
   - k ≥ 2 forces the exact engine (`age_forced_exact`), so `Collectors = 1` there.
   - The ageing mark runs **on the collector** and appends slots of marked Age objects to `heal`
     (`TenureWork.hpp:363`). `HealYoungOnly` must accept Age-extent slots and still reject a
     copy's slot.
   - **Deep tier only.** k > 1 is opt-in (`promotion_age` defaults to 1, `PROMOTION_AGE`,
     `AllocatorCommon.hpp:152`), and it needs four extents. The first zap hazard needs an object
     that is Fresh, then Age, then dead while it still points into an extent that is retired
     later. That takes at least 5 minors. Keep it out of the quick tier until k > 1 becomes a
     candidate default.
4. **A STW major inside the hand-over minor** (incremental marking off). The major runs before the
   launch, so it traverses the Tenuring extent as young. Model it as an optional `MJ_*` call from
   `MN_Cycle`.
5. **Refinement R1: mode 2 refines mode 1 (optional, deep).** This makes GC_DET_001's "mode 2 =
   mode 1 bit for bit at one worker" checkable.
   - Write `TenuringSync.tla`, in which the whole job runs atomically **at the merge**.
   - Map the concrete state to the abstract by hiding the job's progress: grant cells written by an
     unmerged job read as empty, and the shadow of the tenuring extent reads as its pre-job value.
   - Check `Spec => TenuringSync!Spec` with TLC.
   - The exact engine allocates deterministically (`CHOOSE` over the grant, in item order), so the
     abstract merge produces the same placement.

   Until then, "mode 1 = mode 2" remains the E2 experiment plus `tenure_harness.cpp`'s stop/resume
   identity test.

## 9. Trace validation

**Harnesses:**
- `test/gc-helper-tsan/tenure_harness.cpp` (`gc-tenure-tsan`). It runs the real `SerialEngine` on
  the real `GCBackgroundGang` over a synthetic heap, and includes the stop/resume identity storm
  (a)–(f), a concurrent reader (g), a stop storm (h), and on even seeds the ageing checks (i)–(k).
  It exercises the exact engine only: `TenureParEnv` (L3) is not std-only and is traced through
  the heap driver.
- `test/gc-heap-tsan/heap_driver.cpp`: region scenarios with 1 and 4 collectors and ages 1–3.

**Hooks.** Add `ECO_TLA_TRACE(...)` calls; they compile to nothing unless `ECO_TLA_TRACE` is
defined:

| Event | Where | Fields |
|---|---|---|
| `launch` | `tenureLaunch` before `R.collector->launch` (`NurseryTenure.cpp:572`, `:1234`) | `x`, `gen`, `|starts|`, `|heal|`, `mode`, `B` |
| `item` | `SerialEngine::step` after choosing an item (`TenureWork.hpp:277-320`) | `kind` (`stack`/`start`/`heal`/`ylos`), index, target cell |
| `load` | `tenure` / `TenureParEnv::tenure` after the shadow load | target cell, observed `(st, gen)` |
| `claim` | after the CAS (L3) | target cell, `ok` |
| `copy` | `SerialEngine::tenure` after `env_.copy` returns (`TenureWork.hpp:262`), so the harness's synthetic `Env` logs it too; the L3 allocation in `TenureParEnv::tenure` (`NurseryTenure.cpp:983-985`) | target cell, destination |
| `publish` | after `tw::publish` | target cell, destination, `gen` |
| `fix` | `childOfCopy`'s slot write (`TenureWork.hpp:434`) and `spineRun`'s tail writes (`:480`, `:488`) | copy, field |
| `stopSeen` / `exit` | `SerialEngine::run` return; `runMarkerLoop` exits (L3) | `why` |
| `join` | `tenureJoin`: `finishedApprox`, and `join` vs `stopAndJoin` | `late` |
| `help` | before `runJobExact` / `runJobParallel` in `tenureJoin` | engine, `n` |
| `merge` | `mergeJob` after the heal | healed slots, tenured count |
| `resolve` | `resolveRetire` | source cell, destination |

**Mapping to the model.** Map addresses to model cells by rank within their extent (the harness's
synthetic heaps are small; the heap driver's are not, so validate only a projection there: launch,
join, stop, help, merge, resolve).

**Ordering.** Collector events are totally ordered within one member. Across members, and between
the collector and the pause, order comes from the shadow words (claim before publish, publish
before any load that sees FWD) and from the gang's launch/join (every collector event lies between
its launch and its join).

**Trace spec.** `TraceTenuring.tla` constrains `Next` so that event *i* matches its label and
observed values, and allows the unlogged mutator epoch steps in between.

**Three things the trace spec must do differently from the model** (review, 2026-09-28):
- **Placement.** The model's exact engine allocates with `CHOOSE` over the free grant cells, and
  TLC's `CHOOSE` order need not be the grant's block and cell order. The trace spec takes the
  destination from the `copy` event instead (the L3 branch's `with d \in FreeGrant`, constrained
  by the log).
- **Spine runs.** The harness builds cons cells (`kCons`, `tenure_harness.cpp:59`). `scanCopy` on a
  cons runs `spineRun`: it tenures the tail chain without pushing, then does one heads pass. The
  model has no cons cells, so its item order cannot match. Start with node-only seeds (a harness
  flag), or add a spine extension first.
- **Item order.** The model's item is one copy's whole scan in field order, as `scanCopy` is, so
  `NF >= 2` traces of node objects match. (The pre-review sketch stacked `(copy, field)` pairs, and
  would have rejected them.)

## 10. Implementation steps

1. Create `test/tla/M5-tenuring/` with `Tenuring.tla` (§4.5), `MC.tla`, the configurations of §6,
   MAPPING.md (§4.4 plus the A3 rows) and AUDIT.md.
2. `pcal` + `sany`, then TLC on `quick_exact`, `quick_sync`, `quick_major`, `quick_cycle`,
   `quick_l3`, `gen` and `wrap`. Tune the bounds (§6) until each quick configuration takes ≤ 2
   minutes.
3. Run every §5 mutant configuration (one target invariant each) and confirm the named violation
   and a counterexample no longer than the §5 "shortest behaviour". For `gen_not_bumped` and
   `wrap_no_discard`, confirm the counterexample is timeline (c).
4. Run `fork` and `cycle_major`. If they fail as expected, attach the traces to CR-013 and CR-017
   (Suspected → Reproduced, at model level).
5. `deep_major`, `deep_cycle`, and `deep` (expected to fail `YoungWalkValid` until CR-017 is
   fixed).
6. Extensions §8.1 (builders) and §8.2 (generation YLOS), each with its mutant.
7. Extension §8.3 (ageing) and `ageing_k2` with `skip_zap`.
8. Trace validation (§9) on `gc-tenure-tsan`: start with the storm, since only the collector's
   events matter there. Then the heal/resolve projection on `gc-heap-tsan`'s region scenarios.
9. `models.txt` and `test/tla/manifest.txt` entries (A9). First AUDIT.md entry. Update the parent
   plan's §11 row.
10. Optional: refinement R1 (§8.5).

## 11. Open questions for the implementer

1. **Item granularity: answered by the review.** The item is now one copy's whole scan, as in the
   code (§4.1). The per-slot version added stop points the code does not have. It also changed the
   copy order at `NF > 1`, which trace validation would have rejected.
2. **Does the pause-only parallel engine (`runJobParallel`), which help uses for large extents,
   need its own configuration?** Its only difference from L3 is that it allocates from phase 6's
   `PromoCtx` after returning the unused grant. At the model's cell level that is the same as
   allocating from any free old cell. Its allocate-black decision is phase 6's
   (`finalizePoppedCellW` and friends, keyed on `marking_active || gc_phase_ != Idle`), which is
   CR-001's subject and M4's model: help of a large extent mid-cycle inherits CR-001.
3. **Can the grant be exhausted in a way the model misses?** In the code, exhaustion is a sizing
   bug (`grantFatal`). The model makes the grant "all free old cells", and `OC >= MaxLid` means it
   cannot run out, because each object is tenured at most once. The code's `!granted` fallback
   (`tenureLaunch`, `NurseryTenure.cpp:544-552`: the job runs in the pause on `runJobParallel`) is pause-only and
   not modelled.
4. **The major inside the hand-over minor (§8.4): answered.** `useMarkCycle()` is
   `incremental_mark || markThreads() > 1` (`ThreadLocalHeap.hpp:311-313`) and `INCREMENTAL_MARK`
   is `true` (`AllocatorCommon.hpp:315`). So a trigger inside `minorGC` (`ThreadLocalHeap.cpp:765-779`)
   starts a cycle, and the STW major there is reachable only with `incremental_mark` off and one
   mark thread. Low priority.
5. **Exit (`tenureTeardown`, `finishTenureForExit`).** They stop the collector, finish the job and
   do a stats-only merge. No mutator runs afterwards, so M5 does not model them. M6 owns the exit
   ordering (`stopAllAtExit` against the stats banner).

## 12. Adversarial review (2026-09-28)

Against the current tree. The corrected sketch in §4.5 passes `pcal` and SANY (0 errors); TLC was
not run, so every "shortest behaviour" in §5 is hand-derived.

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | `gen_not_bumped` could not reach its target: with three extents an extent's second hand-over is at minor 5, and the stale entry is used at minor 6, but its host allowed 5 minors. The mutant would have passed | new quick configuration `gen` (6 minors, one-cell extents); `wrap` moved to quick with the same shape |
| R2 | Blocker | `t0_skips_tenuring` needs an old object held only by a Tenuring object at t0. Old objects existed only as copies merged at minor 3, so the earliest violation was at minor 6, and `quick_cycle` allowed 4 | constant `OldSeed` (one old object at Init); now 3 minors |
| R3 | Major | TV1 and the oracle were `assert`s. An assertion failure carries no invariant name for the runner, fires whatever the configuration lists, and so pre-empted named targets (`merge_before_join`, `gen_not_bumped`, and others were listed as "assert or X") | named invariants `TenuredEqualsLegacy`, `TV1_Heal`, `TV1_Resolve`, `TV1_Major`; each mutant configuration lists one target |
| R4 | Major | What M1 assumes was unchecked: no property that the heal writes only young slots (M1's open question 3), and `MarkerNeverInGrant` omitted the young half and had no mutant | `HealYoungOnly`, `MarkerDisjoint`; mutants `copy_slot_in_heal`, `t0_keeps_young`, `grant_t0_cells`, `copy_not_black` (§5). The code was verified: heal slots are young only (§2.3) |
| R5 | Major | `cw` recorded only `E_Copy` cells, so `CollectorPrivate` could not see the collector writing a non-copy slot (07 trap 1) | `E_Fix` adds the slot it writes; mutant `collector_heals` |
| R6 | Major | `OldPointsOld` had no mutant (A6) | mutant `skip_fix` |
| R7 | Major | The stack held `(copy, field)` pairs. At `NF > 1` the LIFO order differed from `scanCopy`'s, so trace validation would reject real traces; it added stop points the code lacks; and a fork could not cut a copy's scan short | the stack holds copies; one item is one copy's whole scan, with `scanCopy`'s frame as locals `sc`/`si` |
| R8 | Minor | `E_Copy` pushed the copy before the publish (the code publishes, then pushes) | push moved into `E_Pub`; the merged state is noted in §4.5 |
| R9 | Major | Dead state survived into the epoch (`efwd`, `S`, `H`) and multiplied states | cleared at `MN_Epilogue` / `MN_Launch` |
| R10 | Minor | A dead collector (fork) could still leave the loop and decrement `running` | `E_Ret` and `E_WaitBusy` wait on `calive` |
| R11 | Minor | In states that are already broken, `GraphPreserved` and "load a field" could apply `lheap` to 0, a TLC evaluation error that could pre-empt a mutant's target | guards |
| R12 | Minor | Tiering | `quick_major` and `quick_cycle` run the job in the pause (the seam is `JoinMerge`, §6), with 3 minors; `quick_l3` has 3 minors; the split and the sizing levers are written down |
| R13 | Minor | Code-map drift: `minorGCRegion` starts at `:650` (its phases at `:699`–`:1091`); `TenureHeapEnv` ends at `:152`; the `greyObject` redirect site and `startMarkCycle`'s walk were missing from A9 | fixed in §3 and §7 |
| R14 | Minor | Trace hooks: a `copy` hook in `TenureHeapEnv::copy` never fires in the harness; `spineRun`'s tail writes were missing; the harness's cons cells and the model's `CHOOSE` placement cannot match the model as written | §9 |
| R15 | Minor | CR-013 details: which half-done states the model reaches; an L3 child spins on a dead member's BUSY entry (a deadlock report, not an invariant violation); the model keeps a mutator in the child | §7 |
| R16 | Minor | Contracts: M3's `CopyOnceContract` was not named; the T6 skip rule is M4's; help of a large extent mid-cycle allocates black through phase 6's paths (CR-001) | §4.1, §7 A3, §11 Q2 |
| R17 | Major | CR-017 (M1 §10 Q4, found by the M1 review). With k = 1 a dead Tenuring object is never zapped (`NurseryTenure.cpp:816-825`). A STW major marks from roots only (`OldGenSpace.cpp:2881-2889`), so it can free the object's only old child, and the next t0 walk (`NurserySpace.hpp:800-830`) greys the freed cell. `MarkerDisjoint` caught this only indirectly, through the grant, and the review had wrongly expected `deep` to pass | new invariant `YoungWalkValid`; config `cycle_major` is **expected to fail** it today (2 minors, 1 major); `deep` is expected to fail until the fix, and `deep_major` / `deep_cycle` are the passing deep runs |
| R18 | Minor | (From the W review.) The A4 row said the exact engine's entries are "relaxed-published"; the exact engine loads relaxed (`TenureWork.hpp:255`) and publishes release (`:85`). The A4 row also omitted W1, although the L3 and age engines use the Chase–Lev deque | A4 row corrected |

Checked and found right: the shadow-word layout and orders (`make`, relaxed load, acquire lookup,
acq_rel claim CAS against the **observed** word, release publish); the exact engine's claim-free
publish and its BUSY abort; the gen bump and wrap discard in `tenureLaunch` (`NextGen` matches
`(g + 1) & mask`, with 0 mapped to 1); `majorRedirect`'s three conditions; `forEachYoung` covering
Young and Tenuring; every `tenureJoin` path (wait, stop and join, orphan, fork-stopped, L3); and
the collector's footprint (census in §7 A3).
