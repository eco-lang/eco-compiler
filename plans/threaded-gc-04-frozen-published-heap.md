# Threaded GC 04 — Frozen published heap (P1)

**Status:** DONE (2026-09-25).
- **Snapshot and binaries:** `keep-TG4` (+ `extra-files.tar`), `bin/eco-opt-prev` =
  `eco-optTG4`, census binary `eco-optTG4census`; loop entry TG4.
- **Results:** P§10a.

(Originally PLANNED 2026-09-25, against the `keep-TG3` tree: `bin/eco-opt-prev` = `eco-optTG3`,
reference MLIR `ecoghash.mlir`.)

**Parent:** `plans/threaded-gc-master-plan.md`, phase 4 (renumbered 2026-09-25; formerly 7a).

**Background:**
- `design_docs/parallel-gc.md`:
  - §2.1 the snapshot-closure lemma;
  - §2.2 the mutation surface M1–M7;
  - §7.4.3 where P1 is defined;
  - §11.2 the draft HEAP_SNAPSHOT_001 and FORBID_HEAP_005;
- `benchmarks/threaded-gc-00-baseline.md` §5 (the phase 0 census and what it left owed);
- `plans/threaded-gc-00-measure-and-fix.md` Step 11 (the survivor-write census as built).

P§n points into this plan, 00-P§n into the phase 0 plan.

---

## 0. What this phase delivers, and why

**P1: no runtime or kernel code writes a field or header of a heap object after that object has
survived a GC, unless the object carries `builder == 1`.**

Every snapshot design in phases 5a, 5c, 7b and 7c rests on this. With P1, anything reachable at a
snapshot t0 stays reachable only through pointers that existed at t0. So a marker working on the
snapshot may let the mutator run, between incremental slices or concurrently, without a write
barrier. One kernel that stores into an already-scanned old object breaks it: the marker misses
the new target and the object is freed while live. The failure would be rare, silent and
catastrophic.

Compiled Elm code already obeys P0, which is stronger: it writes only fresh objects (HEAP_031).
So only C++ runtime and kernel code can violate P1.

Phase 0 checked this with a survivor-write census, compiled only into the `ECO_HEAP_VALIDATE`
tree, and found 0 violations on E2E. It left three gaps (baseline §5):

| gap | consequence |
|---|---|
| it runs only in the heap-validate build | a self-compile took 36 min for 72 % of the run and swapped at 14.6 GB, so it was stopped: **no full-scale count exists** |
| it watches each object for ONE inter-minor window, in the nursery | **promoted old-gen objects, the ones a snapshot marker scans, are never checked** |
| it reports `(tag, ctor, word)`, printed only at `atexit` | it cannot name the offending kernel function, and an interrupted run reports nothing |

**This phase closes the three gaps, fixes whatever the census and a static audit find, and turns
P1 into an enforced invariant.**

| # | Deliverable |
|---|---|
| D1 | `ECO_P1_CENSUS`: a CMake option giving a census build that is **not** heap-validate. Runtime mode `ECO_P1_CENSUS=0/1/2` (off / count / abort) |
| D2 | The nursery survivor census (phase 0) under the new guard, masking GC-owned header bits |
| D3 | **An old-gen census:** hash promoted objects (sampled) at the minor that promotes them, prune to live objects at each mark end, verify at every major start, periodically, and at exit |
| D4 | **A write-site census** in the heap helpers that mutate objects (`closureCapture`, `arrayPush*`, and whatever the audit adds), keyed by the caller's return address, symbolised with `dladdr` |
| D5 | Periodic and signal-path reports (`[p1-census]` lines every N minors, plus the existing crash handler) |
| D6 | A static audit of every write into a possibly-published object (`runtime/src`, `elm-kernel-cpp/src`, `eco-kernel-cpp/src`), recorded in P§2a |
| D7 | Fixes for the audit's hazards and every census hit: **S1** chunk-chain backings and views built as builders; **S2** a born-old pending list, so large pointer-bearing objects in the old gen are scanned by minor GCs until their children are old (HEAP_061) |
| D8 | FORBID_HEAP_005: delete or fix identity-negative comparisons (`ListOps::member`) |
| D9 | **The tripwire:** validate builds run the census in abort mode by default, so the validate-tree gates enforce P1 from now on |
| D10 | Full-scale census runs (self-compile, E2E, stress, elm-core packages), invariants HEAP_SNAPSHOT_001 + FORBID_HEAP_005, docs, tracking row |

**Out of scope:**
- any marker (phase 5);
- relaxing HEAP_031;
- the RC tier (master plan §1.4);
- off-heap mutable roots (M4). Those are HEAP_SNAPSHOT_002, owned by 5a.

---

## 1. Ground rules

1. **No behaviour change in production builds.** Every census line is compiled out unless
   `ENABLE_P1_CENSUS || ECO_HEAP_VALIDATE`. The default `build/` tree's lowered binary must give
   bit-identical counters and a byte-identical `out.mlir` against `eco-optTG3`. A fix under D7
   may change a kernel's allocation count: that is a deliberate, recorded counter change, judged
   on output identity.
2. **The census must be cheap enough to run on the whole self-compile in a normal-sized
   process.** Target: census build wall ≤ +25 % and RSS ≤ +600 MB against a stats build. Sampling
   (`ECO_P1_CENSUS_SAMPLE`, default 16) is the lever for the old-gen table.
3. **A census proves only what it executed.** P1 is a property of kernel code paths, not of
   workload volume. Coverage comes from running every suite (P§5), and the static audit (D6)
   covers what no test reaches. Neither alone is the gate.
4. **No false positives are tolerated in abort mode.** Everything the GC itself writes must be
   masked or excluded (P§3.3), or the tripwire becomes noise and gets switched off.
5. **Assert the invariant you rely on** (M§2). The census *is* the assertion. It lands in the
   validate tree, so the validate gates of every later phase re-check P1 for free.
6. **Environment is a program input** (TG3 rule 5). Census runs are correctness runs, not timed
   runs: their counters are compared among themselves, never against the control.

---

## 2. Verified facts the steps rely on

Verified 2026-09-25 against `keep-TG3`. Line numbers are in `runtime/src/allocator/` unless a
path is given.

| # | Fact | Where |
|---|---|---|
| F1 | The survivor census is compiled only under `ECO_HEAP_VALIDATE` and enabled by `ECO_SURVIVOR_WRITE_CENSUS=1`. `censusRecord()` hashes every object in `[fromBase, bump_.ptr)` at minor end; `censusCheck()` re-hashes at the next minor start. It hashes whole objects **including the header**, keeps byte copies of objects ≤ 128 B to find the first differing word, and skips `builder` objects. The report is `atexit` only. | `NurserySpace.cpp:2345-2556`, call sites `:457` (check), `:1047` (record); fields `NurserySpace.hpp:171-188` |
| F2 | Test access `NurserySpaceTestAccess::setSurvivorWriteCensus / survivorWriteCensusCounts / survivorWriteCensusHits / resetSurvivorWriteCensus` exists under `ECO_HEAP_VALIDATE`, and `testSurvivorWriteCensus` pins record/check/keying/builder-skip. | `NurserySpace.hpp:467-475`, `test/allocator/NurserySpaceTest.cpp:537-587` |
| F3 | Every promotion is pushed on `promoted_buf_` (`std::vector<void*>`), which holds the whole cycle's promoted objects after the drain loop and is cleared only at the next minor start. The three promotion sites push when `promoted_objects != nullptr`. | `NurserySpace.cpp:510-511`, `:1325`, `:1495`, `:2032` |
| F4 | Promotion copies with `memcpy`, then resets `age = 0` and `color = White` on the copy. Children of promoted objects are fixed up during the drain, so a promoted object's words are final only **after** the drain. | `NurserySpace.cpp:1325-1340` |
| F5 | After mark and before any sweep, liveness is `isMarkedInBlock(id, obj)` (private). The **gap sweep clears the mark bits of mixed blocks** as it walks them, so liveness must be read at mark end. `finalizeMetaAfterMark()` is the first post-mark statement of all four `finishMarkAndSweep` overloads. | `OldGenSpace.hpp:1193`, `OldGenSpace.cpp:3257`, `:2418` |
| F6 | Between two majors, the only old-gen cells freed or reused are cells **unmarked at the last mark** (cursor reuse of clear bits, gap-sweep runs, `freeLargeBodyCell` of dead nursery-owned bodies). Old-gen compaction moves objects, but only via `scheduleCompaction` (test-only in practice). | `OldGenSpace.cpp:4278`; HEAP_054/055/056 |
| F7 | Header bitfield: `tag`, `color:2`, `pin:1`, `age:2`, `unboxed:6`, `refcount:15`, `builder:1`, then `size:32`. The GC writes `color` and `age`, and `mark_as_builder`/`clear_builder` write `builder` and `age`. | `Heap.hpp:164-175`, `HeapHelpers.hpp:1676-1735` |
| F8 | `ListOps::member` compares boxed values by `hpBits` only (identity-negative) and has **no callers** anywhere in runtime, kernels or tests. | `ListOps.cpp:564-578`, `ListOps.hpp:331-333` |
| F9 | CMake options are global `add_compile_definitions` (e.g. `ECO_HEAP_VALIDATE` at `CMakeLists.txt:84-89`). Allocator sources are listed in four places (TG3 F14). | `CMakeLists.txt` |
| F10 | The crash/exit paths print GC stats from `eco_entry.cpp` (`printGCStatsOnce` from `atexitPrintStats` and `signalPrintStats`). | `runtime/src/codegen/eco_entry.cpp` |
| F11 | Mutating heap helpers: `arrayPush`/`arrayPushKind` (`HeapHelpers.hpp:1843-1888`, write `length` and a slot); `closureCapture` (`:1968-2020`, writes `n_values` and a value slot); `mark_as_builder`/`clear_builder` (`:1676-1700`). Compiled code writes only fresh objects (HEAP_031). | `HeapHelpers.hpp` |

### 2a. Static audit (D6), done 2026-09-25 before implementation

A read of every write into a possibly-published object in `runtime/src`, `elm-kernel-cpp/src` and
`eco-kernel-cpp/src`. The two hazards were then verified by hand.

| class | sites | notes |
|---|---|---|
| SAFE-FRESH (allocate, then fill with no allocation in between) | ~60 functions, 200+ write lines | every `allocClosure → resolve → closureCapture` (30 sites); non-builder `arrayPush` fills; copy-then-set array ops; blank string/bytes fills; the constructor helpers; closure groups (`RuntimeExports.cpp:1766-1801`); `papExtend`. **The scheduler updates `Process` by allocating a new one** (`procWithRoot`/`procWithStack`/`procWithMailbox`, `Scheduler.cpp:224-263`), never in place |
| SAFE-BUILDER | 5 functions | `JsArrayExports.cpp` initialize / map / indexedMap / `initialize_Int` / `indexedMap_Int` (`allocArrayBuilder` + `BuilderGuard`) |
| codegen store ABI (fresh by contract, HEAP_031) | 20 exports | `eco_store_*`, `eco_set_unboxed`, `eco_array_set_fix_kind` (clone → fix_kind → store, `EcoToLLVMHeap.cpp:1420-1470`) |
| **S1: chunk-chain backings filled after later allocations** | 8 call sites | see below: a **real P1 violation, live in production** |
| **S2: large pointer-bearing objects born in the old gen** | ~6 sites | see below: a **latent GC-correctness bug** (unremembered old→young edges) |
| identity-negative comparisons | 1 real (dead code) | `ListOps::member` (F8). The `Utils.cpp`/`UtilsExports.cpp` constant-vs-heap "unequal" paths conclude inequality only against embedded constants. Their one inconsistent case, a zero-length heap string vs `""`, is an equality bug, not a snapshot hazard (P§10) |

**S1 (verified).** `listChunkChain` (`HeapHelpers.hpp:981`) allocates each backing (`listBacking`)
and then its view (`consChunkView`), link by link. Its callers fill the backings *afterwards*
through `ListChainWriter` / `ListChainReverseWriter` (raw pointers, no allocation during the
fill).
- A minor GC during chain construction ages an earlier backing to `age 1`, and the later fill
  writes into it: a write into a survived object.
- A second minor during the same construction promotes the backing (`promotion_age` = 1), and the
  fill then writes nursery pointers into an old-gen object: an **unremembered old→young edge**.
- Chunks are on in production: `list.chunks = True` is the default (`Compiler/Eco/Config.elm:704`)
  and `ecoghash.mlir` carries `eco.list_chunks`.
- Callers: `ListOps.cpp:275` (append), `:321` (concat), `:542` (reverse); `HeapHelpers.hpp:1163`
  (`listFromPointers`), `:1191` (`listFromInts`), `:1276` (`listFromUnboxables`);
  `RuntimeExports.cpp:4608`, `:4652` (`eco_scratch_finish*`).

**S2 (verified).**
- `ThreadLocalHeap::allocate` sends every object of `size >= large_object_threshold` (8 KiB) to
  `allocateLargePinned`, i.e. to the old gen, **whatever its tag** (`ThreadLocalHeap.cpp:194`).
  `allocateRegionSlow` does the same for large closure-group regions (`:343`).
- Strings and byte buffers are safe: they use split headers with a nursery-owned body.
- A pointer-bearing object (an `ElmArray` of more than ~1,021 boxed elements, a large region)
  filled afterwards holds nursery pointers that **no minor GC scans**. Sites:
  - `arrayFromPointers` (`HeapHelpers.hpp:1764`), reached from `JsonExports.cpp:358` and
    `JsArrayExports.cpp:200`;
  - `ListExports.cpp:396-403`;
  - `allocArrayBuilder` for large sizes, which also sets `builder` on an old-gen object against
    HEAP_BUILDER_001;
  - `eco_alloc_closure_group_slow` (`RuntimeExports.cpp:1717`).
- The comment in `ThreadLocalHeap::allocate`'s fallback states this very hazard.
- **Checked, not the cause of the 5 pre-existing validate-stress `JsonRoundtrip*` aborts:**
  routing large pointer-bearing allocations to the nursery leaves the same 5 aborts. Those are a
  stale closure pointer resolved in `eco_apply_closure_eval` ("PTR IN TO-SPACE", P§10).

---

## 3. Design

### 3.1 Build and modes

- CMake `option(ECO_P1_CENSUS ... OFF)` → `ENABLE_P1_CENSUS=1/0` (global definition, like
  `ECO_HEAP_VALIDATE`).
- `P1_CENSUS_COMPILED = ENABLE_P1_CENSUS || ECO_HEAP_VALIDATE` (a macro in the new
  `P1Census.hpp`). Production and stats builds compile none of it.
- Runtime mode, from `ECO_P1_CENSUS` (read once):

  | value | meaning |
  |---|---|
  | `0` | off |
  | `1` | count: tally and report, never abort (the census) |
  | `2` | abort: the first violation prints its record and calls `abort()` (the tripwire) |

  The default is `2` in validate builds (D9) and `1` in census builds. `ECO_SURVIVOR_WRITE_CENSUS=1`
  stays as an alias for `1`.
- `ECO_P1_CENSUS_SAMPLE=<n>` (a power of two, default 16; 1 = every object) samples the old-gen
  table by `hash(address) & (n−1) == 0`. It is deterministic per run.
- `ECO_P1_CENSUS_EVERY=<n>` (default 64): verify the old-gen table and print a `[p1-census]`
  summary line every n minors.

### 3.2 One module, three detectors

New `P1Census.{hpp,cpp}` (namespace `Elm::p1`). It is a process singleton, leaked on purpose
like the existing census, guarded by one mutex. Heaps are per-thread, so tables are keyed by the
owning `OldGenSpace*` / `NurserySpace*`.

| detector | records | checks | catches |
|---|---|---|---|
| **N: nursery survivors** (phase 0's, moved) | every survivor at minor end | at the next minor start | a write in an object's first post-survival window |
| **O: old-gen promoted objects** (new) | a sample of `promoted_buf_` at minor end (after the drain, F4) | at every major start, every `EVERY` minors, and at exit | a write into a promoted object at any later time while it is live |
| **W: write sites** (new) | — | on every call of a mutating heap helper | the exact **caller** of a write into an aged or old-gen non-builder object |

Detectors N and O find *that* a write happened, whatever path did it (raw pointers, `memcpy`).
Detector W names *who* did it, for the writes that go through helpers.

### 3.3 Hashing without false positives

- The hash covers all object words, except that header bits the GC or the builder protocol own
  are masked to zero: `color`, `age` and `builder`. For O, the stored hash is taken after the
  drain, so drain-time child fixups (F4) are not writes.
- Builder objects (`builder == 1` at record time) are skipped (counted as `skipped_builder`).
- **O-table validity (F6).** An entry is valid until the object could be freed. That happens
  only if it was unmarked at a mark.
  - At every mark end, P1Census walks the table and **drops entries whose object is not marked**
    (the post-mark hook, P§3.4).
  - Entries recorded after the last mark are for objects promoted since, which cannot be freed
    before the next mark.
  - So at any sync point every remaining entry names a live, unmoved object, and the table can be
    verified at any minor start, not only at a major.
- **Compaction** (`scheduleCompaction`) calls `p1::invalidate(oldgen)`: the table is cleared and
  `invalidations` is counted.
- **Nursery-owned large bodies** are never promoted by copy, so they never enter O. The
  split-header *headers* do, and they are immutable.

### 3.4 Hook points (all behind `P1_CENSUS_COMPILED`)

| hook | file | call |
|---|---|---|
| minor start, before evacuation | `NurserySpace::minorGC` (replaces `censusCheck` at `:457`) | `nursery.censusCheck()` (N) then `p1::onMinorStart(oldgen, minor_count)` (O; verifies every `EVERY` minors) |
| minor end, after the swap | `NurserySpace::minorGC` (replaces `censusRecord` at `:1047`) | `nursery.censusRecord()` (N) then `p1::recordPromoted(oldgen, promoted_buf_)` (O) |
| mark end | `OldGenSpace::finalizeMetaAfterMark` (first statement after the accumulator merge) | `p1::onMarkEnd(*this)`: prune by `isMarkedInBlock` |
| major start | `ThreadLocalHeap::majorGC`, before `startMark` | `p1::verifyOldGen(oldgen, "major-start")` |
| compaction | `OldGenSpace::scheduleCompaction` | `p1::invalidate(*this)` |
| heap destroyed | `~OldGenSpace` / `Allocator::reset` | `p1::forget(oldgen)` (verify first, then drop the table) |
| exit | `atexit` from the first registration | final verify of every table + full report |
| write sites | `alloc::arrayPush`, `arrayPushKind`, `closureCapture` (+ audit additions) | `p1::noteWrite(obj, "arrayPush", __builtin_return_address(0))` |

`P1Census` needs `OldGenSpace::isMarkedInBlock` and `blockIdFor`: add `friend class
p1::P1CensusAccess;` to `OldGenSpace`. **`OldGenSpace.cpp` gets exactly two one-line hook calls**
(the alignment trap, 01-P§9a.13: `-falign-loops=64` is pinned, but check the mark loop address
if mark time moves).

### 3.5 Detector W: the write-site check

`noteWrite(void* obj, const char* helper, void* ret)` is a violation when the object is not
`builder` and either:
- it is outside the nursery (old gen or large body), or
- it is in the nursery with `age >= 1` (it has survived a minor).

Fresh objects (age 0, in the nursery) are the legal case. The violation key is `(helper, ret)`.
The report symbolises `ret` with `dladdr` (plus the `eco_alloc_custom` anchor the phase 0 report
used for `nm` lookup when `dladdr` returns no symbol).

Mode 2 aborts on the first violation, after printing `helper`, the symbol, the object's tag and
age, and whether it is old-gen.

### 3.6 Reporting

- `[p1-census] minors=… N:checked/mismatched/skipped O:entries/checked/mismatched/dropped/invalidations W:calls/violations`
  every `EVERY` minors (count mode).
- At exit, the full tables: the top 50 N and O keys (`tag`, ctor or evaluator symbol, first
  differing word) and every W key with its symbol.
- The signal path (`signalPrintStats`) calls `p1::reportNow()`. That is best-effort, like the GC
  banner there, and is the fix for phase 0's lost table.

### 3.7 The tripwire (D9)

In validate builds the default mode is 2, so every validate gate (unit, E2E, stress) enforces P1:
- **N** aborts on a changed survivor;
- **O** aborts at the next verification;
- **W** aborts at the write.

Tests that *deliberately* write into a survived object (the census's own tests) force mode 1
through test access.

---

## 4. Steps

Every step ends with `cmake --build build --target check` green. Steps 2–6 also build the
validate tree's `test` target and run the new tests there.

**Before you start:**
- `benchmarks/lss-loop-snap.sh verify keep-TG3` (the phase-3 `BlockTable.hpp` comment change is
  the one known difference; re-snapshot it as `try-TG4-pre`);
- take the snapshot `try-TG4-pre`.

### Step 1 — D6: static audit → P§2a

1. Grep `runtime/src`, `elm-kernel-cpp/src`, `eco-kernel-cpp/src` for writes into heap objects:
   - member stores (`->values[`, `->head =`, `->tail =`, `->a =`, `->n_values`, `->length =`,
     `->value =`, `hdr->…`);
   - `memcpy`/`memmove` into resolved objects;
   - the mutating helpers (F11).
2. Classify each site:
   - **SAFE-FRESH**: allocated in the same function, written before any further allocation;
   - **SAFE-BUILDER**: builder set at the write;
   - **SUSPECT**: written after an intervening allocation or safepoint, or into an object that
     arrived as an argument, a root or a global.
3. Record the table in P§2a with file:line, object type, "can it be old?" and the proposed fix.
   Identity-negative comparisons go in the same table (D8).

### Step 2 — D1: the build option, `P1Census` skeleton and modes

1. `CMakeLists.txt`: after `ECO_HEAP_VALIDATE`, add:
   ```cmake
   option(ECO_P1_CENSUS "Compile in the P1 survivor-write census (threaded-gc-04); cheap, not heap-validate" OFF)
   if(ECO_P1_CENSUS)
       add_compile_definitions(ENABLE_P1_CENSUS=1)
   else()
       add_compile_definitions(ENABLE_P1_CENSUS=0)
   endif()
   ```
2. New `runtime/src/allocator/P1Census.hpp`:
   - `#define P1_CENSUS_COMPILED (ENABLE_P1_CENSUS || ECO_HEAP_VALIDATE)`, with `#ifndef`
     defaults of 0 for both macros;
   - the API of P§3.4 as inline no-ops when not compiled.

   New `P1Census.cpp` holds the implementation. Add the `.cpp` to the four source lists.
3. `p1::mode()`: parse `ECO_P1_CENSUS` (`0`, `1`, `2`; else abort with a message) and the
   `ECO_SURVIVOR_WRITE_CENSUS` alias; parse `SAMPLE` (a power of two in [1, 65536]) and `EVERY`
   (≥ 1). Add a test override `p1::setModeForTesting(int)`.
4. Unit test `testP1CensusModeParsing`, built only where the census is compiled.

### Step 3 — D2: detector N under the new guard

1. In `NurserySpace.{hpp,cpp}`, change the guards around the census members, `censusRecord`,
   `censusCheck`, the report and the test access from `ECO_HEAP_VALIDATE` to
   `P1_CENSUS_COMPILED`. The call sites at `:457` / `:1047` move out of the surrounding
   `#if ECO_HEAP_VALIDATE` blocks into their own `#if P1_CENSUS_COMPILED`.
2. `censusEnabled()` returns `p1::mode() != 0` (the test override `census_forced_` stays).
3. The hash masks the header's `color`, `age` and `builder` bits (P§3.3). Share the function
   `p1::hashObject(const char*, size_t)` between N and O.
4. Mode 2: on a mismatch, `censusCheck` prints the record line and aborts.
5. Tests:
   - extend `testSurvivorWriteCensus` so it runs in census builds too;
   - add a case where only `age`/`color` change: no mismatch.

### Step 4 — D3: detector O

1. `p1::recordPromoted(const OldGenSpace*, const std::vector<void*>&)`: for each object with
   `sampled(addr)` and `!builder`, append `{addr, size, hash}` to the heap's table (a
   `std::vector<OEntry>`, 16 B each).
2. `p1::onMarkEnd(const OldGenSpace&)`: compact the table in place, keeping only
   `isMarkedInBlock(blockIdFor(obj), obj)`. Count `dropped`.
3. `p1::verifyOldGen(const OldGenSpace&, const char* where)`: re-hash every entry. On a mismatch:
   - count it under `(tag, ctor/evaluator, first differing word)`; the word comes from re-reading
     against a byte copy kept for objects ≤ 128 B, as in N;
   - update the stored hash, so one write is counted once;
   - in mode 2, abort.
4. `p1::onMinorStart(oldgen, minors)`: verify when `minors % EVERY == 0`, and print the summary
   line.
5. `p1::invalidate`, `p1::forget`, and the `atexit` final verify (P§3.4).
6. Hook calls exactly as in P§3.4, with the two one-line calls in `OldGenSpace.cpp`. Add `friend
   class p1::P1CensusAccess;` to `OldGenSpace.hpp`.
7. Tests (`test/allocator/P1CensusTest.cpp`, registered per TG3 F14), with a small heap config
   and `SAMPLE=1`:
   - `testP1OldGenCatchesWriteAfterPromotion`: a rooted `Custom` survives, is promoted, then a
     test write into `values[1]` is caught at the next major-start verify, keyed by
     `(Custom, ctor, word 3)`;
   - `testP1OldGenNoFalsePositiveAcrossMajors`: churn with rooted and unrooted objects through
     ≥ 5 majors, with cell reuse after each. There must be 0 mismatches (proves the prune);
   - `testP1OldGenPruneDropsDead`: an unrooted promoted object is dropped at the next mark end;
   - `testP1OldGenCompactionInvalidates`: forcing `scheduleCompaction` clears the table.

### Step 5 — D4: detector W

1. `p1::noteWrite` per P§3.5. Call it from `arrayPush`, `arrayPushKind`, `closureCapture`, and
   every helper the audit lists as a mutation entry point. The calls are inline code in
   `HeapHelpers.hpp` guarded by `#if P1_CENSUS_COMPILED`.
2. Tests:
   - `testP1WriteSiteFreshIsLegal` (capture into a fresh closure: 0 violations);
   - `testP1WriteSiteAgedCaught` (push into a non-builder array after a minor: 1 violation whose
     `ret` symbolises to the test function);
   - `testP1WriteSiteBuilderExempt`.

### Step 6 — D5: reporting

1. `p1::report(FILE*, bool full)`. The periodic line goes to stderr in count mode.
2. `eco_entry.cpp` `signalPrintStats` and `atexitPrintStats`: call `p1::reportNow()` under
   `#if P1_CENSUS_COMPILED`.
3. Test: `p1::reportNow()` output contains the counters (capture via a temp `FILE*`).

### Step 7 — D7/D8: fixes

**7a — S1: chunk chains are built as builders.**
1. `listChunkChain` calls `mark_as_builder` on every backing **and** every view it allocates.
   - Backings, so that a mid-construction minor never ages or promotes them.
   - Views too, because a builder child under a promoted parent is forbidden: the `in_phase3_`
     assertion, HEAP_BUILDER_001.

   Both are nursery-born: backings are capped below the large-object threshold
   (`listBackingMaxElems`).
2. New `finishChunkChain(HPointer head, u32 n)`: walks the first ⌈n / max⌉ views from `head` and
   `clear_builder`s each view and its backing. Every one of the 8 callers calls it after its
   writer finishes and before the list escapes (HEAP_BUILDER_003). A RAII `ChunkChainGuard {head,
   n}` wraps it for the early-return paths.
3. `ListChainWriter::put` / `ListChainReverseWriter` call `p1::noteWrite(lb, "listChainFill")` when
   they switch to a new backing (detector W). This compiles out in production.
4. Test `testP1ChunkChainSurvivesMidConstructionGC`:
   - set `eco_g_list_chunks = true`;
   - park the nursery bump near its threshold (`NurserySpaceTestAccess::bumpBy`), so the chain's
     allocations trigger ≥ 2 minors;
   - build `listFromPointers` of 5,000 boxed Ints;
   - assert every element's value, no builder bit left on any backing or view, and census N and
     W at 0.

   Run it pre-fix first: it must show a nonzero N mismatch or a crash, proving the test sees the
   bug.

**7b — S2: born-old pending list (a remembered set for born-old objects).**

Keep large objects pinned in the old gen (kernels hold raw pointers across allocation), but make
their old→young edges visible:
1. `OldGenSpace` gains `std::vector<BornOld> born_old_` with `struct BornOld { char* obj; uint32_t
   size; uint8_t region; uint8_t quiet_minors; }` and:
   - `noteBornOld(void*, size_t, bool region)`;
   - `isBornOldPending(const void*) const` (a linear range check; the list is tiny);
   - `bornOld()` accessors for `NurserySpace`.
2. Registration:
   - `ThreadLocalHeap::allocateLargePinned`, when `tagMayHoldPointers(tag)`, i.e. every tag except
     `Tag_String`, `Tag_ByteBuffer`, `Tag_Int`, `Tag_Float`, `Tag_Char`;
   - both large-region branches of `allocateRegionSlow` (`region = 1`).
3. **Minor GC** (`NurserySpace::minorGC`, after the root phases and before the drain loop), for
   each entry:
   - scan the object with `in_phase3_ = false`: `scanObject(obj, oldgen, &promoted_objects)`;
   - for a region, walk its objects by `getObjectSize` and stop at a zero header.

   Young children are evacuated and the object's slots updated, exactly as for a promoted parent.
4. **Retirement** (after the drain): an entry whose object has `builder == 0` increments
   `quiet_minors`. At `quiet_minors > promotion_age` it is dropped, because by then every child
   has been promoted (it is copied at most `promotion_age` times before promotion). A dropped
   non-region entry is handed to `p1::recordPromoted` (detector O), since it is frozen from here
   on.
5. **Mark end** (`finalizeMetaAfterMark`, next to the P1 hook): drop entries whose object is
   unmarked. **Split a region entry into per-object entries for its marked objects**, because
   the gap sweep may free the dead parts of a region.
6. **Builder on a born-old object** (`allocArrayBuilder` for a large capacity) is legal while it
   is pending:
   - `OldGenSpace::markOneObject`'s `!hdr->builder` validate assertion accepts `builder` on a
     pending born-old object;
   - HEAP_BUILDER_001 is amended;
   - `clear_builder` on such an object is legal.
7. Detector W treats a pending born-old object as fresh (a legal write).
8. Tests:
   - `testBornOldArrayChildrenSurviveMinors`: `arrayFromPointers` of 2,000 fresh boxed Ints (≥ 8
     KiB, so born old), rooted, then 3 minors with nursery churn in between. Every element keeps
     its value. Pre-fix this must fail, since the elements are left dangling.
   - `testBornOldEntryRetires`: the entry is dropped after `promotion_age + 1` quiet minors.
   - `testBornOldDeadEntryPrunedAtMark`.
   - `testBornOldRegionSplitAtMark`.

**7c — D8.** Delete `ListOps::member` (F8: no callers) and its declaration.

Each fix's regression test also runs in the validate tree (tripwire on).

### Step 8 — full-scale census runs (the owed count)

1. A census tree: `cmake --preset build -B build-census -DECO_P1_CENSUS=ON`, then build
   `eco-boot-native`, `test` and `stress-test`.
2. Lower `ecoghash.mlir` → `eco-optTG4census`. Self-compile with `ECO_P1_CENSUS=1` (sample 16).
   Record wall, RSS and the final report. Then repeat with `SAMPLE=1` if RSS allows (criterion
   R2).
3. Census-tree `build-census/test/test` (unit + E2E) and `stress-test` under
   `benchmarks/heap-config-gc-pressure.json`, all with `ECO_P1_CENSUS=1`.
4. The elm-core and other Elm test packages through the E2E runner (they are part of
   `test/test`).
5. **Pass:** N, O and W mismatches/violations are all 0 after the Step 7 fixes. Otherwise, fix
   and repeat.

### Step 9 — D9: the tripwire, gates, invariants, docs

1. Validate-tree default mode 2 (P§3.7); rebuild the validate tree.
2. Gates (P§6).
3. Invariants (P§8), and THEORY.md's GC section gets one paragraph on P1.
4. Snapshot `keep-TG4`, loop entry TG4 (a correctness phase: counters identical), master plan
   row 4.

---

## 5. Measurement

This is a correctness phase. The production binary must not move, so:
- **Candidate:** `ecoghash.mlir` lowered against this phase's runtime (default tree) =
  `eco-optTG4`, one self-compile in mode 2 of phase 3. Counters and `out.mlir` must be identical
  to the same-session `eco-optTG3`, unless a D7 fix changed a kernel's allocation. In that case
  record the delta and the reason.
- **Census cost** (criterion R2): `eco-optTG4census` vs `eco-optTG4`, wall and max RSS, at
  sample 16 and (if run) 1.

---

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` (unit + E2E), main tree | all pass |
| G2 | elm-tests | the reference set (13,565 / 12) |
| G3 | `--target full` | all pass |
| G4 | stress under the GC-pressure config | 100/100, ≳1,000 minors |
| G5 | validate tree **with the tripwire on by default**: unit + E2E, and stress | unit/E2E all pass with zero `[heap-validate]` and zero `[p1-census] VIOLATION` lines; stress shows only the 5 pre-existing `JsonRoundtrip*` aborts |
| G6 | stats-off `ecoc` builds | builds |
| G7 | census tree: self-compile + unit/E2E + stress with `ECO_P1_CENSUS=1` | 0 violations in N, O, W |
| G8 | production counters and `out.mlir` vs same-session `eco-optTG3` | identical (or a recorded D7 delta) |
| G9 | static check: `grep -n 'P1_CENSUS_COMPILED\|p1::' runtime/src/allocator/{NurserySpace,OldGenSpace}.cpp` shows only guarded hook lines; no census symbol in the production `ecoc` (`nm` shows no `p1::`) | as stated |

## 7. Traps

1. **The gap sweep clears mark bits** (F5). Pruning O anywhere after `finalizeMetaAfterMark`
   reads cleared bits for live objects in mixed blocks, drops them, and loses coverage silently.
2. **Hashing a promoted object before the drain** (F4) records pre-fixup words. Every object
   would then read as "written".
3. **GC-owned header bits** (`age`, `color`, `builder`) must be masked, or every object reads as
   written.
4. **A census that is itself a program input:** census runs set environment variables, so their
   counters are compared only among census runs.
5. **Tests that write on purpose** must force mode 1, or the validate tree's tripwire aborts them.
6. **`ECO_HEAP_VALIDATE` tree slowness** is not this phase's census. Never judge census cost in
   the validate tree.
7. **The 15 GB box:** `SAMPLE=1` on the self-compile may cost ~2 GB. Check free memory first.

## 8. Invariants (land in Step 9)

- **HEAP_SNAPSHOT_001 FrozenPublishedHeap (new).**
  - No runtime or kernel code writes a field or header of a heap object after the object has
    survived a GC, unless `builder == 1`. Surviving a GC means `age ≥ 1` in the nursery, or
    being in the old gen.
  - The GC's own writes (`age`, `color`, forwarding during a collection, drain-time child
    fixups) are excluded.
  - Enforced in validate builds by the P1 census tripwire (detectors N, O, W). Measured in census
    builds (`-DECO_P1_CENSUS=ON`, `ECO_P1_CENSUS=1`).
  - Licenses the snapshot-closure lemma used by phases 5a, 5c, 7b and 7c.
- **HEAP_061 BornOldPending (new), and amendments to HEAP_005 and HEAP_BUILDER_001.**
  - A pointer-bearing object allocated directly in the old gen (`allocateLargePinned` for any tag
    except string, bytes and boxed scalars; large `allocateRegionSlow` regions) is registered in
    `OldGenSpace::born_old_`.
  - Every minor GC scans it as a root until it has had `promotion_age + 1` minors with `builder ==
    0`. Mark end prunes dead entries and splits regions into their live objects.
  - It is the only permitted holder of old→young pointers (amends HEAP_005). While pending it may
    be written, and may carry `builder` in the old gen (amends HEAP_BUILDER_001).
- **FORBID_HEAP_005 NoIdentityNegativeComparison (new).** No code may conclude that two values
  are *different* from differing HPointer words. `a == b ⇒ equal` fast paths are allowed.

## 9. As-built deviations

Recorded during implementation (2026-09-25).

1. **S1's builder fix needed a size bound.**
   - Builder objects are never promoted, so a chain built as builders must fit in the nursery.
     The first test, a 160 KiB chain in a 64 KiB nursery, died with "Failed to allocate after GC".
     Before the fix, such chains simply promoted their backings mid-construction.
   - New `alloc::chunkChainFits(n)` takes the chunk path only when backings plus views fit in a
     quarter of the current per-side nursery (`Allocator::nurseryCapacityBytes()`). Larger
     batches take each caller's existing cons-cell path.
   - All 8 chunk-path conditions (`chunkEligible`, three in `HeapHelpers.hpp`, two
     `eco_scratch_finish*`) carry the bound.
   - With production nursery caps (up to 256 MiB per side), chains of up to ~8 M elements keep
     the chunk path.
2. **S2 is intermittent on the kernel paths that go through `eco_alloc_with_roots`.** Its
   bump fast path ignores the large-object threshold, so a large array lands in the nursery
   whenever it fits, and only the slow path sends it to the old gen. `ThreadLocalHeap::allocate`
   (e.g. `Allocator::allocate`, `allocateRegionSlow`) is deterministic, and that is what the
   regression test uses. Pre-fix the test fails with `element 0 lost`.
3. **S2 did not cause the 5 validate-stress `JsonRoundtrip*` aborts** (P§10). Routing large
   pointer objects to the nursery left all 5, with a stale closure resolved in
   `eco_apply_closure_eval`.
4. **Detector O's first-differing-word signature** is 8 bits × the first 8 words, not 4 bits ×
   16. The keying test collided at 1/16.
5. **`OldGenSpace.cpp` got four hook sites, not two:**
   - `p1::onMarkEnd` and `pruneBornOldAtMarkEnd` in `finalizeMetaAfterMark`;
   - `p1::invalidate` and the born-old compaction guard in `scheduleCompaction`;
   - the HEAP_BUILDER_001 assertion in `markOneObject` now accepts pending born-old objects.

   The born-old maintenance code itself is in the new `OldGenBornOld.cpp` (the mark-loop
   alignment trap).
6. **Compaction is skipped while any born-old entry is pending.** Compaction is reachable right
   after a major (TG2), and a born-old region in a size-class cell is not pinned.
7. **Negative controls.**
   - With `listChunkChain`'s builder marking removed, the S1 test fails in the validate tree
     with N = 1 and W = 1.
   - With the born-old list absent (the pre-fix tree), the S2 test fails in the main tree.
8. **Test-writing trap:** allocating elements into an *unrooted* `std::vector` and rooting it
   afterwards leaves stale pointers and produced a spurious "to-space overflow". The tests
   pre-fill with Nil and root the whole range first.

## 10a. Results (2026-09-25)

**The owed full-scale count.** Self-compile, census build `eco-optTG4census`, `ECO_P1_CENSUS=1`,
sample 16. Output identical. Wall 195.4 s and max RSS 10.34 GB, against 172.8 s / 9.78 GB for
the production binary: +13 % / +570 MB, inside criterion R2.

| detector | checked | violations |
|---|---|---|
| N (nursery survivors) | 744,021,406 survivor re-hashes over 1,924 minors | **0** (42 builder objects skipped) |
| O (promoted, 1 in 16) | 42,234,411 recorded; 264,970,501 re-hashes; 33,548,806 pruned as dead | **0** |
| W (helper write sites) | 18,800,426 writes through `arrayPush*` / `closureCapture` / chunk fills | **0** |

**Census tree in abort mode:**
- unit + E2E 1,792 / 1,792;
- stress 100/100 at 1,263 minors under GC pressure;
- 0 violations.

**The two hazards the audit found were real, and are fixed:**
- **S1** (live in production, since chunks are the default). The negative control, builder
  marking removed, makes the S1 test fail with N = 1, W = 1.
- **S2** (latent). Pre-fix the regression test loses `element 0`.

**Production candidate `eco-optTG4` vs same-session `eco-optTG3` (G8):**
- `out.mlir` is identical;
- minors, majors, promoted and allocated are identical;
- **copied-in-nursery is +1** (744,329,942 → 744,329,943, one 1-field Custom): the recorded D7
  delta. A young element held by a builder chunk backing during a mid-construction minor is
  copied once more instead of riding a promoted backing.
- Wall 172.8 vs 174.7 s, minor GC 47.31 vs 47.53 s: flat.

**Gates:**
- G1 1,792 / 1,792;
- G2 13,565 / 12 (the reference set);
- G3 `full` 1,792 / 1,792;
- G4 100/100 at 1,263 minors;
- G5 validate (tripwire on by default): 1,793 / 1,793, zero `[heap-validate]`, zero P1
  violations. Validate stress 95/100, with only the 5 pre-existing `JsonRoundtrip*` aborts (the
  P§10 stale-closure signature), zero P1 violations;
- G6 stats-off `ecoc` builds;
- G7 as above;
- G8 as above;
- G9: production `ecoc` has 0 `p1::` symbols (census `ecoc`: 20).

## 10. Out of scope (found on the way, recorded)

| finding | where it goes |
|---|---|
| The 5 validate-stress `JsonRoundtrip*` aborts: a stale closure HPointer resolved in `eco_apply_closure_eval` ("PTR IN TO-SPACE") | its own investigation (a rooting bug, not P1) |
| Stack-root ranges longer than 64 slots with `mask = ~0` (`arrayFromPointers`, `ListExports.cpp:390`): `1ULL << i` for i ≥ 64 is undefined behaviour and works only by x86 shift masking | a small RootSet fix, separate |
| `""` vs a zero-length heap string: `compare` says EQ, `==` says False (`Utils.cpp:166-190` vs `eqHelp`) | an equality fix, separate |
| Snapshot treatment of builder objects that exist at t0 (they are written after t0 by design) | phase 5a (grey buffer / builder roots) |
| Remove the `chunkChainFits` bound (¼ nursery) by building the spine and the data separately: tail-first builder-free for vector and `reverse` sources, head-first with builder views only for `append` and `concat` | `plans/chunked-list-spine-data-split.md` (planned, deferred) |

## 11. Done means

- Every gate G1–G9 is green, and the census counts are recorded (self-compile, E2E, stress).
- P§2a is complete, and every SUSPECT is fixed or shown not to reach old objects.
- HEAP_SNAPSHOT_001 and FORBID_HEAP_005 are in `invariants.csv`.
- Snapshot `keep-TG4` is taken, loop entry TG4 is written, and master plan row 4 is filled in.
