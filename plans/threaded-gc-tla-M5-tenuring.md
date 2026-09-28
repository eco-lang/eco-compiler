# Threaded GC — TLA+ model M5: the region nursery and concurrent tenuring (7b/7c)

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). The PlusCal sketch in §4.5 passes the translator
and SANY (tla2tools 1.8.0); TLC has not run. The model is built from the **merged** 7b/7c/07b code,
which has been default-on since TG7d (`nursery_regions = 2` auto, `tenure_mode = 2`,
`tenure_collector_threads = 1`).

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
- that the tenured set is exactly what the legacy nursery would have promoted.

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
- **S_m (start set):** *targets* reached from **roots** and **builder** slots. The next minor
  rescans roots and builder areas anyway, and resolves them through the shadow then.
- **H_m (heal list):** *slot addresses* in **Fill copies** (and in young non-builder YLOS objects)
  that point into Hand. Nobody rescans those slots, so the job's merge must rewrite ("heal") each
  one to the copy.

**Completeness argument** (7c P§3.6). Suppose an object of G_{m−1} is reachable at minor m. The
path from a root to it enters the Hand extent from a root, a builder, a Fill copy or a YLOS object
(recorded), or through other Hand objects (the job follows those itself). Old objects never point
young (HEAP_005). So "live at minor m" equals "reachable from S_m ∪ *H_m through Hand", and job m
tenures exactly the set the legacy nursery would have promoted at minor m. The model checks this
equality directly (§4.6, `liveHand`).

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
  3. promote reached generation YLOS in place;
  4. **heal** every H slot to its copy;
  5. stats;
  6. state `Merged`.

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
| `SerialEngine::run` (stop between items), `step`, `tenure`, `scanCopy`, `childOfCopy`, `spineRun`, `scanYlos` | `TenureWork.hpp:216-501` | procedure `Engine` (`E_Loop`, `E_Item`, `E_Load`, `E_Copy`, `E_Pub`, `E_Fix`) |
| the ageing phases: `markOrSweepStep`, `markTarget`, `sweepStep` | `TenureWork.hpp:323-420` | extension §8 (k = 2) |
| `TenureHeapEnv` (the exact engine's heap access, `copy` = `grantAllocate` + fixup) | `NurseryTenure.cpp:53-150` | `E_Copy` |
| `runJobExact`, `tenureEntry` | `NurseryTenure.cpp:403-423` | process `Collector` (`Collectors = 1`) |
| `tenureLaunch` (gen bump/discard, inputs, grant, launch) | `NurseryTenure.cpp:428-573` | `MN_Launch`, `MN_Sync` |
| `tenureJoin` (wait / stopAndJoin / help / orphan) | `NurseryTenure.cpp:575-667` | procedure `JoinMerge` (`J_Wait`, `J_Stop`, `J_Help`) |
| `mergeJob` (grant return, TV3/TV4, heal, final state) | `NurseryTenure.cpp:669-880` | `J_Merge` |
| `tenureTeardown` (exit: stats-only merge) | `NurseryTenure.cpp:900` | not modelled (exit path; §9 Q5) |
| `TenureParEnv::tenure` / `reachYlos` / `childOfCopy` / `spineRun` / `scan` | `NurseryTenure.cpp:969-1060` | `Engine` with `Collectors = 2` (claim branch) |
| `runJobParallel` (pause-only parallel engine) | `NurseryTenure.cpp:1168` | help with claims (the `Engine(FALSE)` call when `Collectors = 2`) |
| `tenureConcLaunch` / `tenureConcEntry` / `tenureConcFinish` (L3) | `NurseryTenure.cpp:1209-1270` | `MN_Launch` (`running := Collectors`), `Collector` processes, `J_Help` |
| `RegionState`, `Extent`, `TenureJob`, `roleOf` | `NurseryRegions.hpp:64-230` | `xstate`, `xtop`, `gen`, `job` |
| `minorGCRegion`: beginMinor, hand-over prep, roots, drain, merge of S/H, epilogue, endMinor | `NurseryRegion.cpp:699-1090` | `MN_Begin`, `MN_Slot`…`MN_Next`, `MN_Epilogue` |
| `evacuateR` (the role switch: copy / record S or H / resolve) | `NurseryRegion.cpp:429-490` | `MN_Classify`, `MN_Set`, `MN_Resolve` |
| `resolveRetire` (TV1, every build) | `NurseryRegion.cpp:352` | the `assert FwdOf(t) # Nil` in `MN_Classify` |
| `majorRedirect` | `NurseryRegion.cpp:217` | `Redir`, `MajorLive`, `MJ_Mark` |
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
| Phase 6's parallel eden copy in the pause | sequential (`MN_Slot` loop in the mutator process) | The pause is exclusive: the collector is joined first. The pause's own parallelism is M3's model |
| Exact engine item = one copy's whole scan | item = one child slot of a copy (`jstack` entries `<<copy, field>>`) | A finer grain: more stop points than the code has. Over-approximation, safe for safety |
| Exact engine: collector writes (copy, publish, fix) | separate labels | Faithful to A1. None of the written locations is readable by the mutator, so the split only adds stop and fork interleavings |
| L3 members' deques and termination | one shared `jstack` bag; `running` counts members still in the engine | The M2 contract **Drain** (a stop leaves all unscanned work where help finds it). M2 checks the real loop |
| Grant blocks, chunk claims, bitmap bytes | `grant` = the set of free old cells at launch; exact: `CHOOSE` (deterministic), L3: any | Placement determinism of the exact engine is kept. Byte-level bitmap races are M4's |
| 5c marking | abstract cycle: t0 greys (roots' and young objects' old targets), `black` copies, handoff frees `OldClose(grey) ∪ black` complement | The M1 contract **SnapshotCycle**. M5 checks only the interface: t0 walk coverage, black copies, the marker never in the grant (TV8) |
| Builders, YLOS generations, large bodies | not in the core sketch | Each adds a recording path (builder slots go to S; YLOS reached or unreached). Listed in §8 as the next extension |
| The ageing variant (k ≥ 2) | extension §8 | The mark/sweep/zap phases, with their own mutant |
| A fork | process `Env`: a stop at any time; mutant `fork_mid_item` removes the collector between any two of its steps | The prepare hook's stopAndJoin lands at an item boundary. A fork from a non-mutator thread can land anywhere (§7, finding F1) |

### 4.2 Constants

| Constant | Meaning | Code | Quick | Deep |
|---|---|---|---|---|
| `EC` | eden cells per epoch | eden capacity | 2 | 3 |
| `SC` | cells per survivor extent (≥ `EC`) | extent capacity | 2 | 3 |
| `OC` | old-gen cells (must cover live + copies) | old gen | 4 | 6 |
| `NF` | pointer fields per object | object fields | 1 | 2 |
| `Roots` | root slots | stack, RootSet, CellStore | `{1, 2}` | `{1, 2}` |
| `MaxLid` | allocations per behaviour | — | 4 | 6 |
| `MaxMinors`, `MaxMajors` | bounds | — | 4, 0–1 | 6, 1 |
| `TenureMode` | 1 = job in the hand-over pause, 2 = collector | `tenure_mode` | 2 (and 1) | 2 |
| `Collectors` | 1 = exact engine, 2 = L3 | `tenure_collector_threads` | 1 (and 2) | 2 |
| `HelpAllowed` | stop a late collector and help | `tenure_help` | TRUE | TRUE |
| `MajorAllowed` | STW majors between minors | allocation-failure / explicit majors | per config | TRUE |
| `CycleAllowed`, `CycleT` | mark cycles, t0 → handoff distance | `incremental_mark`, T | per config, 1 | TRUE, 2 |
| `GenMod` | generations 1..GenMod−1 then wrap | 2²¹ | 8 | 2 (`wrap`) |
| `StopAllowed` | fork prepare stops the collector | atfork | TRUE | TRUE |
| `MUTANT` | §5 | — | `"none"` | |

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
| `jstarts`, `jheal`, `jstack`, `ns`, `nh` | job inputs and progress | `SerialState` | pause (inputs), engine (progress) |
| `grant` | old cells owned by the job | `TenureGrant` | pause |
| `stop`, `running`, `calive`, `claunch` | stop flag, members in the engine, collector thread exists, launch count | `J.stop`, gang `finished_`, thread existence, gang `generation_` | pause / gang / fork |
| `S`, `H` | the minor's pending start set and heal list | `pend_S`, `pend_H` | pause |
| `cycle`, `grey`, `black`, `cage` | abstract mark cycle | `cycle_state_`, t0 greys, allocate-black bits, `cycle_k_` | pause, collector (black) |
| `liveHand` | **ghost**: legacy's promoted set at the hand-over | the legacy oracle (E1) | pause |
| `cw`, `ncopy` | **ghost**: cells the collector wrote; copies per object | TV8 range checks; TV3 | collector |

### 4.4 Steps: model labels to code

| Label | Code | What it stands for |
|---|---|---|
| `M_Epoch` | Elm code | allocate from held values, load a field into a root, drop a root |
| `MN_Join` → `J_Wait`/`J_Stop`/`J_Help`/`J_Merge` | `ThreadLocalHeap.cpp:726`; `tenureJoin`; `mergeJob` | join or stop+join; help; TV3/TV4 and the oracle; heal; `Merged` |
| `MN_Begin` | `minorGCRegion` beginMinor (`NurseryRegion.cpp:699-724`) | choose fill / hand / retire |
| `MN_Slot`, `MN_Classify`, `MN_Fwd`, `MN_Set`, `MN_Resolve`, `MN_Next` | the roots phase (`:817`) and the drain (`:853`) via `evacuateR` | one slot per step: eden → copy; Hand → S (root) or H (heap slot); Retire → resolve (TV1) |
| `MN_Epilogue` | epilogue and endMinor (`:1021-1090`) | Retire → Free (cells emptied, shadow kept), eden cleared, Fill → Young, Hand → Tenuring |
| `MN_Cycle` | `startMarkCycle` / `stepMarkCycle` (`ThreadLocalHeap.cpp:1065-1190`) | handoff at T; or t0 with the young walk |
| `MN_Launch`, `MN_Sync` | `TenureLaunchScope` → `tenureLaunch` | gen bump or discard; inputs; grant; launch (mode 2) or run now (mode 1) |
| `MJ_Join`, `MJ_Cycle`, `MJ_Mark` | `majorGC` | join and merge (final); finish a running cycle; STW mark with `majorRedirect`; free unmarked old |
| `C_Wait`, `C_Run`, `C_Fin` | `GCBackgroundGang::memberLoop` → `tenureEntry` / `tenureConcEntry` | wait for a launch, run the engine, finish |
| `E_Loop` | `SerialEngine::run` | stop check between items |
| `E_Item` | `SerialEngine::step` | take the next stack / start / heal item |
| `E_Load`, `E_Claim`, `E_WaitBusy` | `tenure` (exact: relaxed load, no claim); `TenureParEnv::tenure` (L3: acquire load, CAS, `waitPublished`) | the shadow protocol |
| `E_Copy`, `E_Pub`, `E_Fix` | `grantAllocate`/`grantAllocateShared` + `memcpy` + fixup; `publish`; `childOfCopy`'s `*s = word(tenure(t))` | copy, publish FWD, rewrite the copy's slot |
| `F_Maybe` | a fork on another thread: `atforkPrepare` → `stopAllForFork` | stop, or (mutant) the collector disappears mid-item |

### 4.5 The PlusCal sketch

File: `test/tla/M5-tenuring/Tenuring.tla`. This is the text that passed `pcal` and SANY; the
generated translation is omitted.

```tla
------------------------------ MODULE Tenuring ------------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    EC,             \* eden cells per epoch
    SC,             \* cells per survivor extent (>= EC: a fill never overflows)
    OC,             \* old-gen cells
    NF,             \* pointer fields per object
    Roots,          \* root slots (stack slots, RootSet, CellStore cells ...)
    MaxLid,         \* objects the mutator may allocate in a behaviour
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
RECURSIVE SetToSeq(_)
SetToSeq(S) == IF S = {} THEN <<>>
               ELSE LET e == CHOOSE y \in S : TRUE IN <<e>> \o SetToSeq(S \ {e})
Range(sq) == {sq[i] : i \in 1..Len(sq)}
NextGen(g) == IF g + 1 >= GenMod THEN 1 ELSE g + 1

(* --algorithm Tenuring
variables
    heap    = [a \in Addr |-> Empty],             \* every object cell: logical id + fields
    root    = [r \in Roots |-> Nil],
    lheap   = [l \in 1..MaxLid |-> [i \in Fields |-> 0]],   \* ghost: the logical graph
    lroot   = [r \in Roots |-> 0],                 \* ghost
    nextLid = 1,
    ebump   = 1,                                   \* eden bump (bump_.ptr)
    xstate  = [x \in X |-> "Free"],                \* Free | Young (Fresh) | Tenuring
    xtop    = [x \in X |-> 1],                     \* the fill's LAB top (surv_top)
    gen     = [x \in X |-> 0],                     \* Extent::gen
    shadow  = [x \in X |-> [c \in 1..SC |-> NoEntry]],   \* RegionState::shadow
    job     = [st |-> "None", x |-> 0],            \* TenureJob::state, x
    jstarts = <<>>, jheal = <<>>, jstack = <<>>,   \* SerialState: starts, heal, stack
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
    \* TV1 at a STW major: every reference into the merged extent has a copy.
    MajorTV1 ==
        \A t \in {root[r] : r \in Roots} \cup {heap[a].f[i] : a \in MajorLive \ {Nil}, i \in Fields} :
            (t # Nil /\ job.st = "Merged" /\ IsS(t, job.x) /\ xstate[job.x] = "Tenuring")
                => FwdOf(t) # Nil
    JobDone == jstack = <<>> /\ ns > Len(jstarts) /\ nh > Len(jheal)
    InEpoch == pc[MutId] = "M_Epoch"
    FreeGrant == {a \in grant : heap[a].lid = 0}
    \* ---- properties ----
    NoDangling ==                                  \* no reachable reference to freed memory
        InEpoch => \A a \in ReachAll : heap[a].lid # 0 /\ (a[1] = "S" => xstate[a[2]] # "Free")
    GraphPreserved ==                              \* GC never changes what the mutator sees
        InEpoch =>
            /\ \A r \in Roots : LidOf(root[r]) = lroot[r]
            /\ \A a \in ReachAll : \A i \in Fields : LidOf(heap[a].f[i]) = lheap[heap[a].lid][i]
    CollectorPrivate ==                            \* FORBID_HEAP_004
        (running > 0 \/ job.st = "Running") => cw \cap ReachAll = {}
    ExactlyOnce == \A a \in SAddr : ncopy[a] <= 1  \* TV3
    OldPointsOld ==                                \* HEAP_005 (amended: copies until the merge)
        \A a \in OAddr : (heap[a].lid # 0 /\ ~(job.st = "Running" /\ a \in grant)) =>
            \A i \in Fields : heap[a].f[i] = Nil \/ IsO(heap[a].f[i])
    MarkerNeverInGrant ==                          \* TV8
        cycle = "Marking" => OldClose(grey) \cap (grant \cup black) = {}
end define;

\* The engine (TenureWork.hpp SerialEngine; with Collectors > 1 the claim
\* protocol of TenureParEnv::tenure). One item = one stack entry (a copy's
\* field), one start, or one heal slot. `canStop`: the collector honours
\* stop between items; help (the pause) does not.
procedure Engine(canStop)
variables tgt = Nil, fix = Nil, e = NoEntry, res = Nil;
begin
  E_Loop:
    while ~JobDone do
        await ~canStop \/ calive;
        if canStop /\ stop then return; end if;
      E_Item:                                      \* SerialEngine::step
        await ~canStop \/ calive;
        if jstack # <<>> then                      \* a copy's child slot (scanCopy)
            with it = jstack[Len(jstack)] do
                tgt := heap[it[1]].f[it[2]];
                fix := it;
            end with;
            jstack := SubSeq(jstack, 1, Len(jstack) - 1);
        elsif ns <= Len(jstarts) then              \* a start (S_m)
            tgt := IF MUTANT = "skip_start" /\ ns = 1 THEN Nil ELSE jstarts[ns];
            ns := ns + 1;
        elsif nh <= Len(jheal) then                \* a heal slot: its value, immutable under P1
            tgt := heap[jheal[nh][1]].f[jheal[nh][2]];
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
                goto E_WaitBusy;                   \* another member is copying it
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
        await ~Busy(tgt);
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
            jstack := jstack \o SetToSeq({<<d, i>> : i \in Fields});
        end with;
      E_Pub:                                       \* publish: release store of FWD
        await ~canStop \/ calive;
        shadow[tgt[2]][tgt[3]] := [st |-> 2, dst |-> res, g |-> gen[tgt[2]]];
      E_Fix:                                       \* the copy's slot gets the child's copy
        await ~canStop \/ calive;
        if fix # Nil /\ IsS(tgt, job.x) then heap[fix[1]].f[fix[2]] := res; end if;
        tgt := Nil; fix := Nil; e := NoEntry; res := Nil;
    end while;
  E_Ret:
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
  J_Merge:
    if job.st = "Running" then
        \* TV3/TV4 and the legacy oracle: the tenured set is exactly the
        \* live part of the handed-over extent.
        assert {a \in XObjs(job.x) : FwdOf(a) # Nil} = liveHand;
        \* TV1: every heal slot that points into the extent finds FWD.
        assert \A s \in Range(jheal) :
                   IsS(heap[s[1]].f[s[2]], job.x) => FwdOf(heap[s[1]].f[s[2]]) # Nil;
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
                lroot[r] := lheap[lroot[q]][i];
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
      MN_Classify:
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
            assert FwdOf(t) # Nil;                 \* TV1 (every build)
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
            grey := ({root[r] : r \in Roots} \cap OAddr)
                    \cup ({heap[a].f[i] : a \in {y \in SAddr :
                              heap[y].lid # 0 /\ (xstate[y[2]] = "Young"
                              \/ (xstate[y[2]] = "Tenuring" /\ MUTANT # "t0_skips_tenuring"))},
                           i \in Fields} \cap OAddr);
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
        grant := {a \in OAddr : heap[a].lid = 0};   \* grantTenure (virgin / partial blocks)
        cw := {};
        ncopy := [a \in SAddr |-> 0];
        stop := FALSE;
        if TenureMode = 2 /\ calive then
            running := Collectors;
            claunch := claunch + 1;
        end if;
    end if;
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
  MJ_Mark:                                         \* STW mark with majorRedirect
    assert MajorTV1;                               \* TV1 (every build)
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
\* while the collector ran: CR-004's window).
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
=============================================================================
```

Notes on the sketch:
- **Stop in the pause.** In the exact engine, `stop` is only checked at `E_Loop`, so a stop always
  lands between items, as in `SerialEngine::run`. Help calls `Engine(FALSE)`, which ignores both
  `stop` and `calive`.
- **The two assertions in `J_Merge` are TV1 and the legacy oracle.** `liveHand` is computed at the
  hand-over as "objects of the extent reachable from the roots then". HEAP_005 guarantees that old
  objects never point into the extent, so that set is exactly what `evacuateR`'s S/H recording
  must lead the job to.
- **`MN_Slot` iterates roots first, then the field slots of each copy as it is made.** That is the
  code's roots-then-drain order, sequentialised.
- **The mutator writes only eden cells and roots.** That is P1 (HEAP_SNAPSHOT_001): survived
  objects are never written. Builders are the exception to P1 and are §8's first extension.

### 4.6 The properties, explained

| Property | Kind | What it says | A violation looks like |
|---|---|---|---|
| `NoDangling` | invariant (in the mutator's epoch) | every object reachable from the roots is allocated, and not in a Free (retired) extent | a heal slot skipped, so after retirement a Fresh object's field points into the Free extent (TV7); or a copy freed by a major that the next minor then resolves to |
| `GraphPreserved` | invariant (epoch) | the graph the mutator sees, compared by logical id, equals the ghost logical graph | a stale FWD entry believed (timeline c): a field now names a different object |
| `CollectorPrivate` | invariant | while a collector runs or its job is unmerged, no cell it wrote is reachable from the roots (FORBID_HEAP_004) | a merge while the collector still runs: healed slots now reach copies whose fields the collector is still rewriting |
| `ExactlyOnce` | invariant | at most one copy per tenuring object per job (TV3) | two L3 members copying one object without the claim |
| `OldPointsOld` | invariant | old objects point only to old objects, except a running job's grant cells (HEAP_005 as amended) | a copy whose child slot was never fixed survives the merge |
| `MarkerNeverInGrant` | invariant | a mark cycle's closure never reaches the grant or black copies (TV8) | only reachable through a bug that lets a pre-t0 old object point at a copy |
| `J_Merge` asserts | assertions | TV1 (every heal target forwarded) and the oracle (tenured set = `liveHand`) | a start entry skipped; a root into Hand not recorded in S |
| `MN_Classify` assert | assertion | TV1 at resolve: every reference into Retire finds FWD | the job missed an object that a root still holds |
| `MJ_Mark` assert (`MajorTV1`) | assertion | TV1 at the STW major's redirect | a merged job that missed an object a root still holds |

Liveness ("every launched job is eventually merged") holds by construction here: the mutator
decides when minors happen, and help finishes a late job. The loop's own termination is M2's
`AllExit`. Add `<>(job.st # "Running")` under fairness only if a configuration forces minors.

## 5. Negative controls (mutants)

| `MUTANT` | Code change it represents | Existing hook | Configuration | Must violate |
|---|---|---|---|---|
| `skip_start` | the engine skips a start entry | `test_tenure_skip_start_every_` | `quick_exact` | `J_Merge` oracle assert, or the TV1 assert at the next resolve |
| `skip_heal` | the merge skips one heal slot | `test_heal_skip_one_` | `quick_exact` | `NoDangling` (the slot points into the retired extent) |
| `no_root_starts` | roots into Hand are not recorded in S | — | `quick_exact` | `J_Merge` oracle assert / TV1 at resolve |
| `no_resolve` | references into Retire are not resolved | — | `quick_exact` | `NoDangling` |
| `gen_not_bumped` | `tenureLaunch` does not bump `gen` | — | `quick_exact`, `MaxMinors = 5` | `GraphPreserved` or the oracle (timeline c) |
| `wrap_no_discard` | gen wraps without `shadow.discard` | — | `wrap` | `GraphPreserved` |
| `merge_before_join` | the merge runs without waiting for the collector | — | `quick_exact` | `J_Merge` TV1 assert or `CollectorPrivate` |
| `major_greys_original` | the STW mark greys the original, not the copy | (`majorRedirect` disabled) | `quick_major` | `NoDangling` after the next minor (the copy was freed) |
| `t0_skips_tenuring` | `forEachYoung` skips the Tenuring extent | (`test_snapshot_skip_young_walk_` skips all young) | `quick_cycle` | `NoDangling` (an old child only a Tenuring object held is freed at the handoff, and the black copy is never scanned) |
| `copy_not_black` | job copies not allocated black mid-cycle | (`test_skip_allocate_black_`) | `quick_cycle` | `NoDangling` (the copy is freed at the handoff) |
| `l3_no_claim` | L3 members publish without the claim CAS | — | `quick_l3` | `ExactlyOnce` |
| `fork_mid_item` | a fork from a non-mutator thread snapshots the collector mid-item (§7 F1) | — | `fork` | **expected to fail** (oracle / TV1): documents finding F1 |
| `skip_zap` (k = 2) | the merge does not zap dead ageing objects | `test_skip_zap_` | `ageing_k2` (§8) | `YoungWalkValid` (§8) |

TV5's negative control (`test_grant_t0_block_`, a t0 block granted mid-cycle) is a **byte-level**
hazard: the grant's plain `setBit` and a background marker's `fetch_or` on one bitmap byte. It
belongs to M4's model, not M5's cell-level heap.

## 6. Configurations

`MC.tla` is just `EXTENDS Tenuring`, since every constant is a plain value.

| Config | Key constants | Tier | Expected |
|---|---|---|---|
| `quick_exact` | EC = SC = 2, OC = 4, NF = 1, 4 minors, mode 2, 1 collector, help, stops | quick | pass |
| `quick_sync` | as `quick_exact`, `TenureMode = 1` (the determinism reference) | quick | pass |
| `quick_major` | + `MajorAllowed`, `MaxMajors = 1` | quick | pass |
| `quick_cycle` | + `CycleAllowed`, `CycleT = 1` | quick | pass |
| `quick_l3` | `Collectors = 2` | quick | pass |
| `wrap` | `GenMod = 2` (every hand-over wraps and discards), 6 minors | deep | pass; with `wrap_no_discard` it fails |
| `deep` | EC = SC = 3, OC = 6, NF = 2, 6 minors, majors + cycles, `Collectors = 2` | deep | pass |
| `fork` | `quick_exact` + `MUTANT = "fork_mid_item"` | quick | **fails** (F1) until the fork window is closed |
| `ageing_k2` | the §8 extension, k = 2 (4 survivor extents) | deep | pass; with `skip_zap` it fails |

The invariants line of every configuration is:
`INVARIANTS NoDangling GraphPreserved CollectorPrivate ExactlyOnce OldPointsOld MarkerNeverInGrant`.
The assertions fire on their own.

**Sizing.** No TLC numbers exist yet. If `quick_exact` passes about 2 minutes, drop to NF = 1,
EC = SC = 2 and `MaxMinors = 3` before anything else: three minors are the fewest that include a
full hand-over, tenure and retire cycle. `deep` is expected to take hours. `OC` must cover the live
old objects plus one job's copies. If `E_Copy`'s `await FreeGrant # {}` deadlocks, `OC` is too
small; the code would `grantFatal`.

## 7. Accuracy notes (parent plan rules A1–A9) and a finding

| Rule | M5 |
|---|---|
| A1 | The collector's steps are one shadow load, one CAS (L3), one grant allocation plus copy, one publish, one slot fix. Pause steps are sequential and exclusive, so each pause label may do more. Stop is checked only between items (`E_Loop`). |
| A2 | Shadow entries are whole 64-bit words (state, dst and gen change together, as with `make`). Heal slots are whole pointer slots written only in the pause. Bitmap bytes are M4's. |
| A3 | The 7c plan's footprint table, row by row. **T1** tenuring objects: `heap` cells of `job.x`, collector-read-only. **T2** heal slots: `heap[jheal[·]]`, read by the collector, written only in `J_Merge`. **T3** generation YLOS: not in the core sketch (§8). **T4** shadow: `shadow[job.x]`, written by the collector, read by the pause after the join. **T5** grant cells: `grant`, `E_Copy`. **T6** `blocks_`/`partial_`/free lists: abstracted (the grant is fixed at launch, and the model's mutator never allocates old). **T7** job-private state: `jstarts`/`jheal`/`jstack`/`ns`/`nh`. **T8** eden, roots: mutator and pause only; `CollectorPrivate` checks the collector never reaches them. **T9** config: constants. **T10** helper jobs: M7. **T11** 5c markers: the abstract cycle and `MarkerNeverInGrant`. |
| A4 | **W5** covers the shadow's claim, copy and publish: L3 members read each other's entries with acquire loads, and the pause reads the exact engine's relaxed-published entries after the join's mutex. The gang launch and join publication is M6's LaunchJoin contract. |
| A5 | §9 lists the events and hooks. |
| A6 | §5. Each existing 7c test hook has a mutant. |
| A7 | `NoDangling` = TV7 plus HEAP_069's retirement premise; `GraphPreserved` = the legacy oracle (E1) at the level of graphs; `CollectorPrivate` = FORBID_HEAP_004; `ExactlyOnce` = TV3; `OldPointsOld` = HEAP_005 as amended; `MarkerNeverInGrant` = TV8; assertions = TV1 (every build) and the E1 promoted-set equality. |
| A8 | 3 survivor extents, 2–3 cells each, 1–2 fields, 4–6 minors. **Generations**: `GenMod = 2` in `wrap`, so every hand-over wraps. |
| A9 | `file`: `TenureWork.hpp`. `region`: `tenureLaunch`, `tenureJoin`, `mergeJob`, `runJobExact`, `tenureEntry`, `runJobParallel`, `TenureParEnv::tenure`/`reachYlos`/`childOfCopy`/`spineRun`, `tenureConcLaunch`/`tenureConcEntry`/`tenureConcFinish`; `evacuateR`, `resolveRetire`, `majorRedirect`, `minorGCRegion`'s beginMinor / epilogue / endMinor blocks; `forEachYoung`; `grantTenure`, `grantAllocate`, `grantAllocateShared`, `returnTenureGrant`; `ThreadLocalHeap::minorGC`'s join and `TenureLaunchScope`; `majorGC`'s join. `census`: `NurseryTenure.cpp`, `NurseryRegion.cpp`, `OldGenTenure.cpp`, `TenureWork.hpp`. `grep`: the T1–T11 greps from 7c Step 0. |

**Finding F1 (suspected, for the register; not yet reproduced).** This is the tenure analogue of
CR-004.

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
host. The `fork` configuration is the model-level reproduction.

## 8. Extensions (in order)

1. **Builders.** An eden object may be a builder, which a kernel may write while it is young (with
   held values). Builders are copied into the fill's builder area at every minor and never
   promoted. Their slots into Hand go to **S**, not H (`evacuateR` with `col == kColBuilder`).
   - **Delta:** a `builder` flag per object; a mutator action "write a held value into a young
     builder's field"; the pause copies builders again from the previous fill's builder area
     (Role `PrevBuilders`).
   - **Check:** the same invariants, plus HEAP_BUILDER_001 (a builder is never tenured).
2. **Generation YLOS.** A large young object is never copied. It belongs to the generation that
   first reached it, is snapshotted at hand-over, is scanned read-only by the job (with `reached[]`
   set by an atomic exchange in L3), and is promoted in place at the merge if reached, else freed.
   - **Delta:** YLOS cells in the old region with a `young` flag.
   - **Checks:** "a reached YLOS object is promoted and its tenured children resolved at the merge
     (TV1)"; "an unreached one is freed and unreferenced".
3. **Ageing, k = 2** (`plans/threaded-gc-07b-tenure-ageing.md`). Four survivor extents (fill, one
   Age extent, Hand, Retire).
   - **Delta, pause:** references into Age go to `SA` (targets).
   - **Delta, job:** a **mark** phase from `SA` over the Age extent (read-only; each marked
     object's slot into Hand joins `heal`); a **sweep** that lists the gaps between marked objects
     as `zap` spans.
   - **Delta, merge:** zaps (dead Age objects become fillers).
   - Age extents' states carry `age`.
   - **New invariant `YoungWalkValid`:** every object `forEachYoung` would visit has only fields
     that point to allocated, non-Free cells. Without the zap, a dead Age object keeps a field
     pointing into a retired extent, and the t0 walk and the validators read it.
   - **Mutant `skip_zap`** (`test_skip_zap_`).
   - k ≥ 2 forces the exact engine (`age_forced_exact`), so `Collectors = 1` there.
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
  (a)–(f), a concurrent reader (g) and a stop storm (h).
- `test/gc-heap-tsan/heap_driver.cpp`: region scenarios with 1 and 4 collectors and ages 1–3.

**Hooks.** Add `ECO_TLA_TRACE(...)` calls; they compile to nothing unless `ECO_TLA_TRACE` is
defined:

| Event | Where | Fields |
|---|---|---|
| `launch` | `tenureLaunch` before `R.collector->launch` (`NurseryTenure.cpp:572`, `:1234`) | `x`, `gen`, `|starts|`, `|heal|`, `mode`, `B` |
| `item` | `SerialEngine::step` after choosing an item (`TenureWork.hpp:277-320`) | `kind` (`stack`/`start`/`heal`/`ylos`), index, target cell |
| `load` | `tenure` / `TenureParEnv::tenure` after the shadow load | target cell, observed `(st, gen)` |
| `claim` | after the CAS (L3) | target cell, `ok` |
| `copy` | `TenureHeapEnv::copy` / the L3 allocation | target cell, destination |
| `publish` | after `tw::publish` | target cell, destination, `gen` |
| `fix` | `childOfCopy`'s slot write | copy, field |
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

## 10. Implementation steps

1. Create `test/tla/M5-tenuring/` with `Tenuring.tla` (§4.5), `MC.tla`, the configurations of §6,
   MAPPING.md (§4.4 plus the A3 rows) and AUDIT.md.
2. `pcal` + `sany`, then TLC on `quick_exact`, `quick_sync`, `quick_major`, `quick_cycle`,
   `quick_l3`. Tune the bounds (§6) until each quick configuration takes ≤ 2 minutes.
3. Run every §5 mutant and confirm the named violation. For `gen_not_bumped` and
   `wrap_no_discard`, confirm the counterexample is timeline (c).
4. Run `fork`. If it fails as expected, record finding F1 in the register (as a new entry linked to
   CR-004) with the trace.
5. `wrap` and `deep`.
6. Extensions §8.1 (builders) and §8.2 (generation YLOS), each with its mutant.
7. Extension §8.3 (ageing) and `ageing_k2` with `skip_zap`.
8. Trace validation (§9) on `gc-tenure-tsan`: start with the storm, since only the collector's
   events matter there. Then the heal/resolve projection on `gc-heap-tsan`'s region scenarios.
9. `models.txt` and `test/tla/manifest.txt` entries (A9). First AUDIT.md entry. Update the parent
   plan's §11 row.
10. Optional: refinement R1 (§8.5).

## 11. Open questions for the implementer

1. **Is modelling the item as "one child slot" rather than "one copy's whole scan" too fine?** It
   only adds stop points, so it cannot hide a bug. But it enlarges the state space. If quick
   configurations are too slow, merge `E_Item` … `E_Fix` for stack items into one item per copy,
   as the code does.
2. **Does the pause-only parallel engine (`runJobParallel`), which help uses for large extents,
   need its own configuration?** Its only difference from L3 is that it allocates from phase 6's
   `PromoCtx` after returning the unused grant. At the model's cell level that is the same as
   allocating from any free old cell.
3. **Can the grant be exhausted in a way the model misses?** In the code, exhaustion is a sizing
   bug (`grantFatal`). The model makes the grant "all free old cells", so it can only run out if
   `OC` is too small.
4. **The major inside the hand-over minor (§8.4).** Is it reachable with incremental marking on,
   the default? The code comment says no. Check `useMarkCycle()` before modelling it.
5. **Exit (`tenureTeardown`, `finishTenureForExit`).** They stop the collector, finish the job and
   do a stats-only merge. No mutator runs afterwards, so M5 does not model them. M6 owns the exit
   ordering (`stopAllAtExit` against the stats banner).
