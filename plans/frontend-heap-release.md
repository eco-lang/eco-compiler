# Front-end heap release: `Eco.GC` tasks, phase-boundary drops, and a release before the back end

**Status:** ready to implement, 2026-10-01. Nothing is built yet.

**Sources:**
- Read-only investigations of 2026-10-01 covering five pipeline boundaries plus the runtime.
- The Stage 9b memory trace: `scratchpad/stage9b_samples.tsv`, `stage9b.time`, `stage9b.stdout`.
- Line numbers are for the tree of 2026-10-01. Functions are named too.

---

## 0. Why, what, and what must not change

### 0.1 The measurement

Stage 9b (`bin/eco make --optimize … --output=bin/eco-2`, the unified binary with its in-process back end) succeeded, but only just:

| measure | value |
|---|---|
| wall time | 11:54 |
| peak RSS | **15.27 GB** (on a 15 GB box) |
| minimum MemAvailable | 238 MB |
| major page faults | 21,768 |
| swap used | 2.6 GB |

A first attempt, made inside the `bootstrap` target, was killed by the low-memory reaper.

Trace timeline (≈1.15 s per sample, warm `eco-stuff`):

| t (s) | phase | RSS |
|---|---|---|
| 0-57 | Elm front end | rises to 8.7 GB. GC threads stop doing work at about 57 s, so nothing overlaps with the back end. |
| ~60 | back end creates its MLIR context | threads 23 → 47 (24 `llvm-worker`) |
| 60-600 | single-threaded lowering | 9.0 → 13.0 GB |
| **600-605** | parallel object code generation | threads 71, about 10 cores; **peak 14.85 GB** sampled (15.27 GB per `time -v`) |
| afterwards | threads exit, then link | falls to 10.9 GB |

### 0.2 Root causes

1. **Most of the front-end heap is garbage, and it is never returned to the OS.**
   - The run's banner shows an old-gen in-use peak of 10.35 GB against an average live set of 1.62 GB per major.
   - Released old-gen blocks are only discarded at the end of the *next* major's pause (`DECOMMIT_DELAY_MAJORS = 1`, `DECOMMIT_DELAY_SYNCS = UINT32_MAX`; `PageWork::syncPoint`).
   - The back end makes no Elm allocations, so that pause never comes.
2. **The Elm side pins large dead data:**
   - the whole `Build.Artifacts` is held in a progress `Chan` that is never drained;
   - the crawl-status MVars, which hold source text and parsed ASTs, are never dropped;
   - during bytecode codegen, the scheduler root holds the whole MonoGraph.
3. **The MLIR is not streamed into the back end.** `Make.handleElfOutput` streams it to a temp file under `eco-stuff`, and `lowerAndLink` receives three path strings and re-reads the file. Once the call starts, no Elm value is needed.

### 0.3 Goals

1. **A new kernel module `Eco.GC`, with identical APIs** in `eco-kernel-cpp` (native) and `compiler/src-xhr` (JS bootstrap), plus a JS kernel (`eco-kernel-cpp/src/Eco/Kernel/GC.js`) for bootstrap stages 2-5:
   ```elm
   minorGC : Task Never GCReport
   majorGC : Task Never GCReport
   ```
   **`GCReport` (§4.1) answers the request to return information.** It reports time taken, memory before and after, bytes released and RSS. `majorGC` is a **full release**: a STW major, the sweep run to completion, a forced shrink, an immediate discard of released pages, and a `malloc_trim`.
2. **The Elm front end calls these explicitly.**
   - `majorGC` always runs immediately before `Eco.NativeDriver.lowerAndLink`. `ECO_GC_PRE_LINK=0` is an opt-out kept only for A/B runs.
   - Further GC points are config-selectable (`ECO_GC_POINTS`) and off by default until §8's experiments justify them.
   - `lowerAndLink` itself never collects.
3. **Each pipeline stage drops its dead data** (Part E), so that the GCs actually free it.
4. **Measure every step,** with a reusable tool and an experiment protocol (§8).

### 0.4 Invariants that must hold

- **Emitted output stays byte-identical:** the self-compile MLIR, `eco-2`, the E2E corpus, and stage 5's `eco-compiler.mlir`, including with `ECO_GC_POINTS=all`. The one exception is row 13 (§7). It cannot be made identical and needs a separately approved re-baseline.
- **GC_DET_001 holds.** An explicit collection is a mutator-chosen sync point, and modes 0, 1 and 2 must still agree (§3.6).
- **Elm code never branches on `GCReport` fields;** it only logs them. GC configuration is excluded from `Config.hash`.

### 0.5 Prerequisite — DONE 2026-10-01 (`keep-REGFIX` taken, `eco-opt-prev -> eco-optREGFIX`)

Close REGFIX (`benchmarks/gc-opt-loop.md` §6) first.
- Its E2E gate is now met: `--target full` 2003/2003 on 2026-10-01.
- Promote `eco-opt-prev` to `eco-optREGFIX` and take the `keep-REGFIX` snapshot.
- This plan's loop entry (FHR, §9.2) is then judged against REGFIX.

---

## 1. Common procedure (every step)

1. **Snapshots for local rollback.** The project is in git, but this container's worktree cannot run it, so the user commits from outside, using `commit.txt`. Use `benchmarks/lss-loop-snap.sh` as a working rollback:
   - `snap try-FHR-<step>` after each step builds and passes its gates;
   - `restore <last good>` followed by `verify` to roll back a failed attempt.

   The old snapshots (up to `try-FHR-E1`) were deleted on 2026-10-01 to free disk. The first new one is `try-FHR-E2`, taken after batch 2. Re-create `build-validate` and `build-heap-tsan` on demand.
2. **Runtime changes** (`runtime/src/allocator`):
   - re-read the `design_docs/invariants.csv` rows the part names (a CLAUDE.md rule);
   - run the TLA canary (`bash test/scripts/check-tla-manifest.sh .`): AUDIT.md entries in every named model before `--update` (GC_MODEL_001).
3. **New source files and libraries** need `cmake --preset build` and deletion of the stale `eco-kernel-cpp/{typed-,}artifacts.dat`.
4. **Tests:** always under `ulimit -c 0`; full suites run once, with output to a file (CLAUDE.md).
5. **Output identity:** after every compiler-source change, `cmp` the self-compile MLIR with the previous one, and the E2E corpus via `--target full`.
6. **Measure the effect after each Part E row,** at the pre-link `GCReport` and the matching optional point (§8).

---

## 2. Order

| phase | content | sections |
|---|---|---|
| P0 | measurement tool, plus the baseline Stage 9b trace with the fixed sampler | §8.1 |
| P1 | runtime API: `GCReport`, `collectMinor`, `collectMajorAndRelease`, HEAP_076 | §3 |
| P2 | native kernel and the shared Elm module | §4 |
| P3 | JS paths: XHR module, IO handler, `GC.js`, `--expose-gc` | §5 |
| P4 | compiler wiring: config, `Builder.GcPoints`, the pre-link call, optional points | §6 |
| — | **measure** Stage 9b (§8.3, configuration C1) | |
| P5 | Elm-side drops in the order of §7.0, measuring after each | §7 |
| P6 | optional-point experiments and the decision about defaults | §8.3 |
| P7 | gates, loop entry, full clean bootstrap with Stage 9b traced | §9 |

---

## 3. Part A: runtime API (`runtime/src/allocator`)

### 3.1 New header `GCReport.hpp`

It is a plain struct with no allocator includes. Every input is always compiled in, including in Release builds where `ENABLE_GC_STATS = 0`.

```cpp
namespace Elm {
struct GCReport {
  enum class Kind : uint8_t { Minor, Major } kind = Kind::Minor;
  uint64_t total_ns=0, gc_ns=0, sweep_ns=0, shrink_ns=0, discard_ns=0, trim_ns=0;
  uint64_t old_in_use_before=0, old_in_use_after=0;      // getOldGenCommittedBytes (acquired - released)
  uint64_t old_pending_before=0, old_pending_after=0;    // PageWork pending_bytes (released, still resident); 0 in mode 0
  uint64_t old_high_water=0;                             // old_gen_committed (bump; never falls)
  uint64_t live_after_mark=0;                            // OldGenSpace::major_live_ (0 if no major ran)
  uint64_t released_bytes=0, shrink_released_bytes=0, discarded_bytes=0;
  uint64_t nursery_committed=0;
  uint64_t rss_before=0, rss_after_discard=0, rss_after=0;  // 0 = unavailable
  int64_t  trim_result=-1;                               // malloc_trim rc; -1 = not run
  uint64_t minor_count=0, major_count=0, majors_run=0;
};
}
```

Where each field comes from:
- `released_bytes` is the change in `page_supply_.released_bytes` (`Allocator.hpp:409`).
- `discarded_bytes` is the change in `PageWork counters().discard_posted_bytes` in modes 1 and 2, and in `page_supply_.discarded_bytes` in mode 0.
- `major_count` is `OldGenSpace::majorEpoch()` (`OldGenSpace.hpp:1295`).
- `minor_count` comes from a new getter `NurserySpace::minorSeq()` that returns `census_minor_seq_`.
- Add the public getter `size_t majorLiveBytes() const { return major_live_; }` (`OldGenSpace.hpp:488`). Do **not** use `frag_stats_`.

### 3.2 RSS helper

Add `size_t processResidentBytes()` to `PlatformVirtualMemory.hpp`. On Linux it returns field 2 of `/proc/self/statm` × `sysconf(_SC_PAGESIZE)`. On other platforms it returns 0 (the win32 stub).

### 3.3 Forced shrink (`OldGenSpace`)

- In `maybeShrinkCapacity` (`OldGenSpace.cpp:6267`), replace `bool light_pass` with `enum class ShrinkPass : uint8_t { Heavy, Light, Forced }`.
- Update the callers: `:6064` (Light), the heavy call in `adjustCapacityAfterMajorGC` (`:6236`), and `OldGenSpaceTestAccess::lightShrink` (`OldGenSpace.hpp:2348`).
- In **Forced** mode:
  - skip the hysteresis block (`:6326-6352`);
  - keep the floor `max(initial_old_gen_size, alloc_buffer_size)` (`:6296`);
  - abort if `compact_phase_ != Idle`, `gc_phase_ != Idle` or `cycleActive()`;
  - bill the time to a new `total_maybe_shrink_forced_ns`.
- Passes 1-3 are unchanged, including the `kAllocTenure` skip.
- Add the wrappers:
  ```cpp
  void OldGenSpace::finishSweepForRelease() {             // pattern: OldGenSpaceTestAccess::driveSweepToCompletion
    while (gc_phase_ != GCPhase::Idle)                      // "!=" keeps grep F.gc_phase quiet
      lazySweep(NUM_SIZE_CLASSES, std::numeric_limits<size_t>::max() / 2);
  }
  void OldGenSpace::shrinkToFloorForRelease() { maybeShrinkCapacity(0, ShrinkPass::Forced); }
  ```
- **Expectation:** the shrink adds little, because `reclaimAllDeadBlocksFromMeta` already releases all-dead blocks. Partly-live blocks stay; there is no production compaction. **The RSS gain comes from the discard (§3.5).**

### 3.4 `ThreadLocalHeap::majorGCAndShrink()`: one pause, one sync point

Define it after `PauseEndHook` (`ThreadLocalHeap.cpp:701`), in a new `TLA-REGION(TLH.majorGCAndShrink)` region.

```cpp
ThreadLocalHeap::ReleaseTimings ThreadLocalHeap::majorGCAndShrink() {
#if ECO_HEAP_VALIDATE
  assertOwner("majorGCAndShrink");
#endif
  if (pause_depth_ != 0) fatal("explicit release inside a GC pause (HEAP_076)");
#if ENABLE_GC_PHASE_TIMERS
  GCPauseScope pause_scope(*this, true);
#endif
  PauseEndHook pause_end(*this, parent_);         // outermost: ONE onGCPauseEnd, had_major = true
  ReleaseTimings t{}; uint64_t s = nowNs();
  majorGC(GCStats::MajorReason::Explicit);         // nested (depth 2): joins tenure job, finishes a live cycle by Join
  t.gc_ns = nowNs() - s; s = nowNs();
  old_gen_.finishSweepForRelease(); t.sweep_ns = nowNs() - s; s = nowNs();
  const size_t u0 = parent_->getOldGenCommittedBytes();
  old_gen_.shrinkToFloorForRelease();
  t.shrink_released = u0 - parent_->getOldGenCommittedBytes(); t.shrink_ns = nowNs() - s;
  return t;
}
```

Add `MajorReason::Explicit = 8` (`GCStats.hpp:1091`) and its `"explicit"` entry in `majorReasonName` (`GCStats.cpp:737`).

### 3.5 `Allocator::collectMajorAndRelease()` and `collectMinor()` (`Allocator.cpp`)

```cpp
GCReport Allocator::collectMajorAndRelease() {
  ThreadLocalHeap* h = tl_heap_; if (!h || h->inPause()) fatal("...");
  GCReport r; r.kind = GCReport::Kind::Major; const uint64_t t0 = nowNs();
  r.rss_before = platform::processResidentBytes();
  uint64_t rel0, dis0;
  { std::lock_guard<std::recursive_mutex> l(thread_mutex_);              // snapshot only
    rel0 = page_supply_.released_bytes;
    dis0 = page_work_ ? page_work_->counters().discard_posted_bytes : page_supply_.discarded_bytes;
    r.old_pending_before = page_work_ ? page_work_->counters().pending_bytes : 0; }
  r.old_in_use_before = getOldGenCommittedBytes();
  const uint64_t ep0 = h->getOldGen().majorEpoch();
  auto t = h->majorGCAndShrink();                    // NO lock held (HEAP_075)
  const uint64_t td = nowNs();
  // TLA-REGION(AL.releaseDiscard) begin
  { std::lock_guard<std::recursive_mutex> l(thread_mutex_);
    if (page_work_) page_work_->drainAll(/*discard_pending=*/true);    // waits for slots, then madvises Pending
#if ECO_HEAP_VALIDATE
    validatePageWork("collectMajorAndRelease");
#endif
    r.released_bytes = page_supply_.released_bytes - rel0;
    r.discarded_bytes = (page_work_ ? page_work_->counters().discard_posted_bytes
                                    : page_supply_.discarded_bytes) - dis0;
    r.old_pending_after = page_work_ ? page_work_->counters().pending_bytes : 0;
    r.nursery_committed = nursery_low_committed_ + nursery_high_committed_;
    r.old_high_water = old_gen_committed; }
  // TLA-REGION(AL.releaseDiscard) end
  r.discard_ns = nowNs() - td; r.rss_after_discard = platform::processResidentBytes();
#if defined(__GLIBC__)
  { const uint64_t tt = nowNs(); r.trim_result = malloc_trim(0); r.trim_ns = nowNs() - tt; }
#endif
  r.gc_ns = t.gc_ns; r.sweep_ns = t.sweep_ns; r.shrink_ns = t.shrink_ns;
  r.shrink_released_bytes = t.shrink_released;
  r.old_in_use_after = getOldGenCommittedBytes();
  r.major_count = h->getOldGen().majorEpoch(); r.majors_run = r.major_count - ep0;
  if (r.majors_run > 0) r.live_after_mark = h->getOldGen().majorLiveBytes();
  r.minor_count = h->getNursery().minorSeq();
  r.rss_after = platform::processResidentBytes(); r.total_ns = nowNs() - t0;
  return r;
}
```

- **`drainAll` is a public wrapper.** It is needed because, with `DECOMMIT_DELAY_MAJORS = 1`, the sync point at the end of our own pause does not age this major's releases. In mode 0, releases are already discarded inline (`Allocator.cpp:1041`). With decommit off, the config is respected and nothing is discarded.
- **`collectMinor()`** takes the same before and after snapshots around `h->minorGC()`. That call may chain into a major (`majors_run` reports it). The sweep, shrink, discard and trim fields stay 0.
- **The nursery is not decommitted in v1.** Eden, Fresh and Tenuring hold live young objects. Free is at most 192 MiB and is the next copy target; the M3 and M5 model premises for decommitting it have not been re-verified. `nursery_committed` is reported instead. If the trace shows the nursery is ≥ 10 % of RSS at the pre-link point, add `NurserySpace::discardFreeExtent()` (assert `role == Free` and the job is `Merged`) together with M3 and M5 audits.

### 3.6 Safety and determinism

**Safety:**
- `pause_depth_ == 0` is checked first. It implies no minor and no parallel promotion, so the CR-014 tripwire cannot fire.
- `majorGC` joins the tenure job and finishes any cycle (`:822`, `:828`), so the shrink runs with no `kAllocTenure` blocks and outside any cycle (IM5).
- `thread_mutex_` is held only for the snapshot and the drain, never across collection or shrink (HEAP_075). Pool workers never take it (HEAP_058).
- The binding runs on the single owning mutator (HEAP_007), and fork's prepare waits for the short lock.

**GC_DET_001:**
- Each call adds exactly one sync epoch and one major epoch, even when it joins a cycle.
- Ageing reads only epochs and `pending_` membership, both of which are job-blind.
- `drainAll(true)` empties `pending_` identically in modes 1 and 2.
- Only `rss_*`, `*_ns` and `trim_result` differ between modes. These are observations that no decision may read.

### 3.7 Invariants

**New HEAP_076 ExplicitRelease** (HEAP_075 is the last id):

> "AN EXPLICIT COLLECTION IS A MUTATOR SYNC POINT (plans/frontend-heap-release.md §3). Allocator::collectMajorAndRelease runs only from a kernel Task binding on the owning mutator with pause_depth_ == 0 (so no minor, parallel promotion or CR-014 path is active). ThreadLocalHeap::majorGCAndShrink is ONE pause and ONE sync point: a STW major (MajorReason::Explicit; joins the tenure job and finishes any cycle by Join), the lazy sweep driven to Idle, then maybeShrinkCapacity(ShrinkPass::Forced), which releases every fully-swept live_bytes == 0 block and unassigned page down to max(initial_old_gen_size, alloc_buffer_size) with no hysteresis, never during a cycle or compaction. After the pause, under thread_mutex_ only, PageWork::drainAll(true) waits for every slot and discards every Pending extent; in mode 0 releases were already discarded inline. No collection or shrink step holds thread_mutex_ (HEAP_075). Modes 1 and 2 agree in every decision counter (GC_DET_001): the call adds one sync epoch and one major epoch, and drainAll empties pending_ identically. GCReport rss_*, *_ns and trim_result are observations; no GC policy or Elm control flow may read them."

Its sources column: `runtime/src/allocator/Allocator.cpp|ThreadLocalHeap.cpp|OldGenSpace.cpp|eco-kernel-cpp/src/eco/GC.cpp|GC_DET_001|HEAP_058|HEAP_059|HEAP_075`.

**Amend GC_DET_001:** "explicit collections (HEAP_076) are mutator-chosen sync points; report observations never feed decisions."

### 3.8 TLA canary

| pin | kind | models |
|---|---|---|
| `OGS.maybeShrinkCapacity` | region | M4, M8 |
| `OGS.onSweepComplete` | region | M4, M8 |
| `Allocator.cpp` | census (new `lock_guard`) | M6, M7 |
| `F.threadMutex` | grep | M6, M7 |
| new `TLH.majorGCAndShrink` | region | M1, M4, M8 |
| new `AL.releaseDiscard` | region | M6, M7 |

**M7:** `MAPPING.md:124` lists `drainAll` as being used only at reset and teardown. Either add a `DiscardAllPending` mutator step under Tm to `PageWork.tla` (preferred; run `pw_*` quick and deep), or write an AUDIT argument that no extent is reused while the mutator is inside the call, so HEAP_059 holds.

Pins that stay quiet if the code is written as above: `F.gc_phase` (use `!=`), `F.allocTenure`, `TLH.majorGC`, `TLH.minorGC`, `F.pageWorkCalls`.

### 3.9 Unit tests (`test/allocator/GCHelperTest.cpp`, registered in `test/main.cpp`)

**`testExplicitReleaseModesAgree`:** "GC_DET_001: collectMajorAndRelease makes identical decisions in modes 0, 1, 2 and 2+jitter".
- Give `runModeWorkload` an `explicitEvery` parameter: at `r % 6 == 5` it calls `collectMinor()` then `collectMajorAndRelease()`.
- Fold `live_after_mark`, `old_in_use_after` and `released_bytes` into `ModeRun`.
- Assert:
  - `m0 == m1 == m2 == m2j`, using `sameObjects` when the CR-007 no-wait rule ran;
  - `released > 0`;
  - pending bytes are 0 immediately after the call;
  - the next majors still agree across modes.

**`testExplicitReleaseReturnsMemory`** (Linux only):
- Build a dead 256 MB old-gen heap.
- After the call, `/proc/self/statm` resident memory must drop by at least 128 MB, and `rss_after_discard < rss_before`.

---

## 4. Part B: native kernel and the shared `Eco.GC` API

### 4.1 Report contract: the kernel returns JSON, and Elm decodes it into one record

All three implementations (C++, `GC.js` and the XHR handler) return the same JSON object. That avoids kernel-record layout conventions, which are fragile. Keys equal the Elm field names, every value is an integer, and `kind` is `"minor"` or `"major"`. Both `Eco/GC.elm` variants carry this identical code:

```elm
module Eco.GC exposing (GCReport, minorGC, majorGC)

type alias GCReport =
    { kind : String          -- "minor" | "major" | "error" (undecodable kernel reply)
    , collected : Int        -- 1 = a collection ran; 0 = none (JS without --expose-gc)
    , totalNs : Int, gcNs : Int, sweepNs : Int, shrinkNs : Int, discardNs : Int, trimNs : Int
    , rssBefore : Int, rssAfterDiscard : Int, rssAfter : Int
    , oldInUseBefore : Int, oldInUseAfter : Int        -- JS: heapUsed before/after
    , oldPendingBefore : Int, oldPendingAfter : Int
    , oldHighWater : Int                               -- JS: heapTotal after
    , liveAfterMark : Int                              -- JS: heapUsed after a major
    , releasedBytes : Int, shrinkReleasedBytes : Int, discardedBytes : Int
    , nurseryCommitted : Int
    , minorCount : Int, majorCount : Int, majorsRun : Int, trimResult : Int
    }
```

- **Decoder:** `D.succeed GCReport |> andMap (D.field "kind" D.string) |> andMap (D.field "collected" D.int) |> …`, with `andMap = D.map2 (|>)`. The record has more than eight fields, so `map8` is not enough.
- **On a decode failure,** return a zero record with `kind = "error"`. A GC report must never crash the compile.

### 4.2 `eco-kernel-cpp/src/Eco/GC.elm`

```elm
import Eco.Kernel.GC
import Json.Decode as D
import Task exposing (Task)

minorGC : Task Never GCReport
minorGC = Task.map decode minorRaw
majorGC : Task Never GCReport
majorGC = Task.map decode majorRaw

minorRaw : Task Never String
minorRaw = Eco.Kernel.GC.minorGC         -- annotated eta-free alias (as Eco.Runtime.random)
majorRaw : Task Never String
majorRaw = Eco.Kernel.GC.majorGC
-- decode / decoder / zero: §4.1
```

### 4.3 C++ (`eco-kernel-cpp/src/eco/`), following `Runtime.cpp:30-79`

- **`GC.hpp`:** `namespace Eco::Kernel::GC { uint64_t minorGC(); uint64_t majorGC(); }`
- **`GC.cpp`:**
  ```cpp
  static std::string toJson(const Elm::GCReport& r);   // snprintf with PRIu64/PRId64; keys = §4.1 names
  static HPointer majorBody(HPointer) {                // scheduler step, mutator thread; captured/resume rooted
    Elm::GCReport r = Elm::Allocator::instance().collectMajorAndRelease();
    return succeedString(toJson(r));                   // allocate the result AFTER the collection
  }
  static HPointer minorBody(HPointer) { /* collectMinor(), same shape */ }
  uint64_t majorGC() { return Export::encode(makeBinding<majorBody>(Elm::alloc::unit())); }
  uint64_t minorGC() { return Export::encode(makeBinding<minorBody>(Elm::alloc::unit())); }
  ```
  Keep `makeBinding` (KERNEL_TASK_IO_001): the value is a CAF, and the body runs on every step. `collected = 1` always.
- **`GCExports.cpp`:** `HPtr Eco_Kernel_GC_minorGC()` and `HPtr Eco_Kernel_GC_majorGC()`, wrapped in `ECO_KERNEL_GUARD`.
- **`KernelExports.h`:** add both declarations inside `extern "C"` (`:55-312`).

### 4.4 Build lists

| file | change |
|---|---|
| `eco-kernel-cpp/CMakeLists.txt` | new `EcoKernel_GC` library; add it to the `EcoKernel` aggregate (`:273`) and to the asserts `foreach` (`:288`) |
| `runtime/src/codegen/CMakeLists.txt:926` | add `GC` to `ECO_KERNEL_MODS`. This one list drives `ecoKernelLibs()` (`:1342`, `:1537`), the `eco-boot-native` deps (`:1620`) and the bundle installs (`CMakeLists.txt:569, 703, 776, 920`) |
| `compiler/CMakeLists.txt:753, 813, 848` | add `EcoKernel_GC` to the explicit link lists |
| `eco-kernel-cpp/elm.json` | add `"Eco.GC"` to `exposed-modules` |
| `eco-kernel-cpp/{typed-,}artifacts.dat` | delete (stale caches) |

### 4.5 Compiler registration: none needed

- `KernelAbi` treats every kernel as `ElmDerived`.
- `KernelIntrinsics` rows are opt-in; the alias annotation bounds the type.
- **No `KernelSetFacts` row:** `Task Never String` has no arrows for LSS_004 to poison, and a row would pin allocator C++ in `kernel-license-manifest.txt`.
- **Never give these kernels a `GlobalOpt/KernelFacts` `gcLeafEligible` row.** A GC kernel must not be stamped as a GC leaf.

---

## 5. Part C: the JS paths

### 5.1 `compiler/src-xhr/Eco/GC.elm` (stage 1)

The same exposing list, the same `GCReport` and the same decoder as §4.1, using the transport in `src-xhr/Eco/Runtime.elm`:

```elm
import Eco.XHR
import Json.Decode as D
import Json.Encode as Encode
minorGC = Eco.XHR.jsonTask "GC.minor" Encode.null reportDecoder |> Eco.XHR.orCrash
majorGC = Eco.XHR.jsonTask "GC.major" Encode.null reportDecoder |> Eco.XHR.orCrash
```

Here the XHR handler returns the JSON object itself as `value`, so `reportDecoder` is the §4.1 decoder applied directly (no string step). Stage 1 is stock `elm make` without `--optimize`, so there must be no `Debug`, and stock elm/json APIs only. `ELM_SOURCES` already globs `src-xhr` (`compiler/CMakeLists.txt:124-127`).

### 5.2 `compiler/bin/eco-io-handler.js`

Add a helper above `handleEcoIO` (~`:118`), and the cases after `Runtime.loadState` (`:501-504`):

```js
function runGc(major) {
  const g = typeof globalThis.gc === "function" ? globalThis.gc : null;
  const b = process.memoryUsage(); const t0 = process.hrtime.bigint();
  if (g) {
    try { g(major ? { type: "major", execution: "sync", flavor: "last-resort" }
                  : { type: "minor", execution: "sync" }); }
    catch (_) { g(); }                       // older V8: options unsupported -> full GC
  }
  const ns = g ? Number(process.hrtime.bigint() - t0) : 0; const a = process.memoryUsage();
  return { kind: major ? "major" : "minor", collected: g ? 1 : 0,
    totalNs: ns, gcNs: ns, sweepNs: 0, shrinkNs: 0, discardNs: 0, trimNs: 0,
    rssBefore: b.rss, rssAfterDiscard: a.rss, rssAfter: a.rss,
    oldInUseBefore: b.heapUsed, oldInUseAfter: a.heapUsed,
    oldPendingBefore: 0, oldPendingAfter: 0, oldHighWater: a.heapTotal,
    liveAfterMark: g && major ? a.heapUsed : 0,
    releasedBytes: 0, shrinkReleasedBytes: 0, discardedBytes: 0, nurseryCommitted: 0,
    minorCount: 0, majorCount: 0, majorsRun: g && major ? 1 : 0, trimResult: -1 };
}
// switch:
    case "GC.minor":
    case "GC.major":
      respond(200, JSON.stringify({ value: runGc(op === "GC.major") }));
      break;
```

Checked on this box's Node v22.23.3 with `--expose-gc`: both option forms work, and `last-resort` cut RSS from 262 MB to 53 MB. Without the flag, `globalThis.gc` is `undefined`, which gives `collected = 0`. `compiler/bin/index.js` and `eco-boot-runner.js` both route to `handleEcoIO`, so neither needs a change.

### 5.3 `eco-kernel-cpp/src/Eco/Kernel/GC.js` (stages 2-5)

Stages 2-5 run `eco-boot*.js`, which embeds the kernel JS; `--local-package eco/kernel` is at `compiler/CMakeLists.txt:299`. The kernel returns the JSON **string**, as the C++ kernel does (§4.2 decodes it):

```js
/*
import Eco.Kernel.Scheduler exposing (binding, succeed)
*/
function _GC_run(major) { /* the body of runGc above */ return JSON.stringify(report); }
var _GC_minorGC = __Scheduler_binding(function (cb) { cb(__Scheduler_succeed(_GC_run(false))); });
var _GC_majorGC = __Scheduler_binding(function (cb) { cb(__Scheduler_succeed(_GC_run(true))); });
```

Returning a string means `--optimize`'s field-name mangling never touches the kernel, so no `__$` names are needed. `KERNEL_SOURCES` picks the file up automatically (`compiler/CMakeLists.txt:255-258`).

### 5.4 `--expose-gc`

Add it to the four Node invocations at `compiler/CMakeLists.txt:295, 324, 355, 425`.
- It only defines `globalThis.gc`; V8's heuristics and the `--max-old-space-size=16384` cap are unchanged.
- Every GC point is a no-op unless configured, and the pre-link point is unreachable in JS (`NativeDriver.js:6-11` fails by design), so artifacts are unchanged.
- It lets stage 5 run the `ECO_GC_POINTS` experiments.

### 5.5 `compiler/elm-application.json`

Nothing to add for the XHR build: `Eco.GC` comes from the `src-xhr` source directory. If the file lists kernel modules explicitly (check around `:230`), add `Eco.GC` there.

---

## 6. Part D: compiler wiring

### 6.1 Config (`compiler/src/Compiler/Eco/Config.elm`)

```elm
type GcPoint = GcPostBuild | GcPostMerge | GcPostAssign | GcPostMono | GcPostInline | GcPostGlobalOpt | GcPostCodegenNodes
type alias GcConfig = { points : List GcPoint, preLink : Bool, report : Bool }
gcPointFromString : String -> Maybe GcPoint  -- "post-build" | "post-merge" | "post-assign" | "post-mono" | "post-inline" | "post-globalopt" | "post-codegen-nodes"
gcPointToString : GcPoint -> String
```

- **Placement:** add `, gc : GcConfig` as the **last** field of `EcoConfig` (after `cse`, `:52`). The decoder is positional, so the new field also needs a last `|> D.apply (D.optionalField "gc" gcDecoder default.gc)` after `:753`.
- **Default:** `{ points = [], preLink = True, report = False }`. Update the exposing list.
- **Keep it out of `hash` (`:991`),** with a comment saying GC never changes output.
- **Environment overrides,** appended to `Builder/Eco/Config.elm` `applyEnvOverrides` after `ECO_CALL_PURITY` (`:457-461`):
  - `ECO_GC_POINTS`: comma-separated names; empty gives `[]`; `all` gives every point; an unknown name prints a stderr warning and is skipped (same handling as `applyEngineOverride`, `:1124-1145`);
  - `ECO_GC_PRE_LINK=0|1`;
  - `ECO_GC_REPORT=1`.

### 6.2 New `compiler/src/Builder/GcPoints.elm`

```elm
module Builder.GcPoints exposing (at, passThrough, preLink)
import Compiler.Eco.Config as Config
import Eco.GC
import System.IO as IO
import Task exposing (Task)

at : Config.GcConfig -> Config.GcPoint -> Task x ()
at cfg point =
    if List.member point cfg.points then collect cfg.report (Config.gcPointToString point) else Task.succeed ()

passThrough : Config.GcConfig -> Config.GcPoint -> a -> Task x a
passThrough cfg point value = at cfg point |> Task.map (\_ -> value)

preLink : Config.GcConfig -> Task x ()
preLink cfg = if cfg.preLink then collect cfg.report "pre-link" else Task.succeed ()

collect : Bool -> String -> Task x ()
collect report label =
    Eco.GC.majorGC
        |> Task.andThen (\r -> if report then IO.writeLn IO.stderr (render label r) else Task.succeed ())
        |> Task.mapError never
```

`render` produces the single-line format of §8.2.

**`passThrough` passes the value as the step's result; it never captures it.** Combined with the scheduler rule (a callback's argument stays rooted until the callback returns), this means only the value the next step needs survives the GC.

### 6.3 The pre-link call (`compiler/src/Terminal/Make.elm` `handleElfOutput`, `:384-474`)

Add to the `let`:

```elm
style = ctx.style
gcCfg = ctx.ecoConfig.gc
```

Then replace the chain at `:446-470`:

```elm
|> Task.andThen (\_ -> writeMlirTask)
|> Task.andThen (\_ -> GcPoints.preLink gcCfg)               -- its own step: codegen's values are gone
|> Task.andThen (\_ -> Eco.NativeDriver.lowerAndLink tempMlirPath target rootModuleName
                        |> Task.mapError (Exit.MakeBadGenerate << Exit.GenerateNativeDriverError))
|> Task.andThen (\_ -> Task.io (Utils.dirRemoveFile tempMlirPath))
|> Task.andThen (\_ -> Task.io (Reporting.reportGenerate style rootNames target))  -- was ctx.style (row 16)
```

During the collection, the only pending continuations are the last three closures. They capture strings, `rootNames` and `style`. The callback that captured `writeMlirTask`, and with it `artifacts`, was popped before this step.

### 6.4 Optional points (`compiler/src/Builder/Generate.elm`)

Each point is a separate `andThen` step, inserted **after** the step that consumed the dead value has returned.

| point | site | insertion | collectable after Part E |
|---|---|---|---|
| post-build | `buildMonoGraph` `:707` (first step) | `GcPoints.at cfg GcPostBuild \|> Task.andThen (\_ -> loadTypedObjects …)` | untyped `Opt` graphs, crawl data, interfaces (after rows 1-4) |
| post-merge | after `finalizeAndMergeTypedObjects` (`:596`) returns | `\|> Task.andThen (GcPoints.passThrough cfg GcPostMerge)` | per-module typed objects (only the merged data is live) |
| post-assign | `buildMonoGraphFromMerged`, after row 5's split | `passThrough … GcPostAssign` | the Name-typed graph (after rows 5 and 6) |
| post-mono | `runMonoOptPipeline` between `validateMinted` and `monoPipelineFrom` (`:879-883`), or after mono returns | `passThrough … GcPostMono` | pre-mono rewrite intermediates; solver state |
| post-inline | `runInlineSimplifyPhase` → `runGlobalOptPhase` (`:1173-1174`) | `passThrough … GcPostInline` | `monoGraph0` and `inlinedGraph` (after E-a) |
| post-globalopt | `writeMonoMlirStreaming*` (`:2214`, ~`:2243`) after `buildMonoGraph …` | `passThrough … GcPostGlobalOpt` | GlobalOpt/CSE/CAF intermediates (after E-b) |
| post-codegen-nodes | inside `streamMlirBytecode` after the node loop (row 12) | `passThrough … GcPostCodegenNodes` | the MonoGraph's nodes (after row 12) |

**Placement and the phase timers:**
- `withPhase` wrappers (made lazy by E0) close before the inserted steps, so collection time falls outside the phase timers.
- Thread `ecoConfig.gc` to the sites that don't have it yet. Every site listed already receives `ecoConfig`.

---

## 7. Part E: Elm-side drops, by stage

**Ground rules (verified):**
- **Stack roots are liveness-precise** (RS4GC statepoints, `THEORY.md:328-333`): a dead local is not a root.
- **The scheduler root is the leak.** While an `andThen` callback runs, the process root is that step's `Task_Succeed` value. A value only dies once a later step's callback returns.
- **Use `case`/destructuring or a function boundary** when a value must die early. Do not rely on `let` order.
- **Off-heap MVars and CellStores are GC roots** until taken, dropped or disposed (HEAP_005, HEAP_047).

**How to verify each row:** compare `liveAfterMark` (and `rssAfterDiscard`) at the pre-link point and at the row's optional point, before and after the change, with `ECO_GC_REPORT=1`.

### 7.0 Order

1. E0.
2. Row 2 → rows 1 and 3, with the `finalizePathBuild` reorder → row 4.
3. Row 12 → row 16 → row 15.
4. Rows 6 and 5 → E-a and E-b.
5. Rows 9, 10 and 11 → row 7 → row 8 (SCC-restricted) → row 14 (the fusion-off arm only).
6. Row 13 only if a re-baseline of the output is approved.

### 7.1 E0: a lazy `withPhase` (infrastructure, plus a stats-attribution fix)

**Problem.** `FEStats.withPhase` (`Builder/Eco/FEStats.elm:219-246`) receives its task argument already evaluated.
- In `Generate.elm:1006-1010`, `case selectMonomorphizer … of` is evaluated as `withPhase`'s argument. All of monomorphization therefore runs before "Starting PhaseMono", and its time and allocation are billed to no phase.
- The same pattern appears in `runInlineSimplifyPhase` (`:1076`), `runGlobalOptPhase` (`:1684`) and both `writeMonoMlirStreaming*` (`:2217`, `:2247`).

**Add:**
```elm
withPhaseLazy : Handle -> PhaseName -> (() -> Task x a) -> Task x a
withPhaseLazy handle phase thunk =
    case handle of
        Disabled -> Task.succeed () |> Task.andThen thunk          -- a step boundary even with stats off
        Enabled mvar -> {- as withPhase, but call thunk () inside the timing step -}
```

Switch the five call sites to `withPhaseLazy stats P (\() -> …)`.
- **Output:** unchanged. **Risk:** low.
- **Check:** with stats on, PhaseMono is non-zero and the phase times sum to the wall time.

### 7.2 Build end

**Row 2: the progress `Chan` pins all of `Build.Artifacts` (impact rank 1).**
- `Reporting.signalBuildComplete` (`Builder/Reporting.elm:524-527`) writes `Ok result` into a channel hole.
- `Utils.readChan` (`Utils/Main.elm:1213-1224`) reads it with `readMVar` and never drops the hole.
- With the default `Terminal` style, every Fresh module's `TOpt.LocalGraph`, type env, `Opt.LocalGraph` and interface, plus `deps`, therefore stay live until exit. The comment at `Generate.elm:592-597` puts this at about 1.4 GB.

Make both changes:
1. **Reporting.** Make the channel `Chan (Result BMsg (BResult ()))` and write `Ok (Result.map (\_ -> ()) result)`.
   - `chanEncoder` becomes `BE.result bMsgEncoder (bResultEncoder (\_ -> BE.unit))`.
   - `buildLoop` and `handleBuildMessage` decode `BResult ()`.
   - `toFinalMessage` (`:578`) is already polymorphic.
   - Drop the now-unused `decoder`/`encoder` parameters of `trackBuild` (callers at `Build.elm:225, 365`).
2. **`readChan`** (no `dupChan` exists; it is mentioned only in the comment at `:1221`):
   ```elm
   readChan decoder (Chan readVar _) =
       modifyMVar mVarDecoder mVarEncoder readVar <| \readEnd ->
           takeMVar (chItemDecoder decoder) readEnd
               |> Task.andThen (\(ChItem val newReadEnd) ->
                   dropMVar readEnd |> Task.map (\_ -> ( newReadEnd, val )))
   ```
   This is safe because, after its single `putMVar`, the writer never touches `old_hole` again (`:1228-1238`). It also fixes the per-`BDone` hole leak and the `trackDetails` chan.

**Row 1: crawl-status MVars (impact rank 3).**
- `Status.SChanged` (`Build.elm:525`) holds the source `String` and the parsed `Src.Module`.
- None of these MVars are dropped: the per-module MVars from `fork` (`:542-544`), `smvar` (`:407`) and the root-status MVars (`:413-414`). Reads happen at `:262-264, 414, 420-421`.
- **Why dropping is safe:** each module is forked by exactly one crawler, and each crawler waits for its forks before its `put` (`:558-561`). So once every root is done, every crawl has finished.
- **In `collectPathStatuses` (`:418`):**
  ```elm
  Utils.takeMVar statusDictDecoder smvar
    |> Task.andThen (\sdict -> Utils.dictTraverse (Utils.readMVar statusDecoder) sdict
    |> Task.andThen (\statuses -> Utils.dictMapM__ Utils.dropMVar sdict
    |> Task.andThen (\_ -> Utils.dropMVar smvar)
    |> Task.map (\_ -> { dmvar = dmvar, statuses = statuses, sroots = sroots }))))
  ```
- Drop the root-status MVars in `crawlRootsAndCollect` (`:414`) after reading them.
- Make the same change in `waitForCrawlResults` (`:259-264`); a drop is idempotent (`MVar.cpp:313`).

**Row 3: `dmvar`, `rmvar` and `rrootMVars`.**
- `dmvar` has a single reader, `checkMidpoint` / `checkMidpointAndRoots` (`:1211-1253`). Use `takeMVar` then `dropMVar` on all five read paths.
- In `writeDetailsAndCollectRoots` (`:482-486`), drop `rmvar` and the `rrootMVars` after reading them.
- **Fix in the same change.** `finalizePathBuild` (`:476`) drops `resultsMVars` *before* `rrootMVars` are read. A forked `checkRoot` for an `Outside` root that hasn't yet run `checkDeps` would then fail with "MVar not found". Move that drop to after the `rroots` read.

**Row 4: cached-interface MVars.** `RCached … (MVar CachedInterface)` (`:879`, filled at `:1179-1201`) is never read on the MLIR path. Add this as the first step of `Generate.buildMonoGraph` (`:697`):

```elm
Task.io (Utils.listTraverse_ (\m -> case m of
    Build.Cached _ _ mv -> Utils.dropMVar mv
    _ -> Task.succeed ()) artifacts.modules)
```

Never drop them inside Build: `checkRoot`'s `loadInterfaces` (`:2356`) takes them.

### 7.3 Pre-mono

**Row 5: split `EntryPrep.assign` into its own step.** In `buildMonoGraphFromMerged` (`:727`), compute `assigned = EntryPrep.assign (assignFlagsFor ecoConfig) "main" typedGraph`, then:

```elm
Task.succeed ( assigned, globalTypeEnv )
  |> Task.andThen (\( a, env ) -> runMonoOptPipeline ecoConfig stats env a)
```

`runMonoOptPipeline` now takes an `Assigned`. The Name-typed graph dies before the pre-mono rewrites. Output is unchanged.

**Row 6: `assignIds` dead outputs** (`AssignMVarIds.elm:253`).
- `allSchemeRoots` and `varSupers` are matched as `_` by every later consumer (`MonoSolver/Monomorphize.elm:105`, `Monomorphize/Monomorphize.elm:110`).
- `rootEnv` and `arrowRootEnv` are read only by the `ensure*Root` helpers (`:185, 351`). Keep `lamLabels`, which is still read.
- Emit:
  ```elm
  ( TOpt.GlobalGraph newNodes fields newAnnotations Data.Map.empty Dict.empty
  , { state2 | rootEnv = Dict.empty, arrowRootEnv = Dict.empty } )
  ```
- Grep the tests that consume `assignIds` first.

### 7.4 Mono

**Row 7: dispose the final CellStore.** At `MonoSolver/Monomorphize.elm:201`: `Ok (CellStore.disposeThen sFinal.store.ioRefsPoint ( graph, report ))`. Strict evaluation computes `graph` and `report` first, and `disposeThen` is idempotent.

**E-a: split the inline phase.** `runInlineSimplifyPhase` (`:1075`) keeps `monoGraph0` as the root through `Prune.pruneAfterInline` and the census. Return `Task.succeed inlinedGraph`, then `andThen` the prune.

### 7.5 GlobalOpt

**E-b: split GlobalOpt into steps.** `simplifiedGraph` is the root for the whole eager `let` (`Generate.elm:1686-1730`).
- Make `globalOptimizeWithStats`, `MonoCse.run`, `CafDedupe.run` and `CafHoist.run` separate `andThen` steps.
- Hoist each census `if flag` out of its closure (`:1752-1791`). `\_ -> if flag then … goGraph` captures `goGraph` even when the flag is off.

**Row 9: keep only `dynamicSlots` from staging** (`MonoGlobalOptimize.elm:143, 160`):

```elm
( dynamicSlots, graph2, wrappersInserted ) =
    case Staging.analyzeAndSolveStaging graph1 of
        ( sol, g, w ) -> ( sol.dynamicSlots, g, w )
```

**Row 10: clear the LSS member tables after AbiCloning.**
- `lssMemberKinds` and `lssBlockedMembers` have no reader after AbiCloning (`AbiCloning.elm:796-916`).
- `lssMemberOrigins` is read by `Borrow.run` (`borrow.enabled`), `Borrow.deriveFacts` (`oracleOpt`), and `MapTemplate.derive` or the `listReport` census (`list.mapTemplate`).
- Add `Mono.clearLssTables { keepOrigins = borrowCfg.enabled || borrowCfg.oracleOpt || cfg.list.mapTemplate }` after phase 4, threading those flags into `globalOptimizeWithStats`.

**Row 11: slim the codegen input.** On its own this is negligible: `mapping`, `countByGlobal`, `specHasEffects` and `specValueUsed` are already empty. Do it inside row 10.

**Row 8 (corrected): `callEdges` is live.**
- `pruneAfterInline` repopulates it (`Prune.elm:163-170, 281-288, 346`), and `MonoInlineSimplify.buildBodyLookup` (`:119-122`) uses it at codegen for recursion detection.
- It is deliberately stale: GlobalOpt and CafHoist nodes have no rows. Recomputing it would change `isRecursive`, then `inlineBodies`, and could change the output.
- **Identity-preserving change:** in `pruneAfterInline`, keep only intra-SCC edges, self-loops included. Any cycle in a later induced subgraph is a cycle of the original, so `isRecursive` is unchanged.
- **Docs:** fix CGEN_069 ("callEdges … verified dead") and MONO_022 (`invariants.csv:181, 361`).

### 7.6 Codegen (bytecode)

**Row 12: the MonoGraph is pinned for all of node codegen (impact rank 2).**
- `streamNodesCollectEncode` (`Generate/MLIR/Backend.elm:376-404`) is pure recursion; its docstring at `:370-375` is wrong. The node loop therefore runs inside `writeMonoMlirStreamingBytecode`'s callback, whose root is `MonoBuildResult`.
- **Change:**
  1. E0 gives a step boundary before codegen.
  2. `streamMlirBytecode` builds `ctx` and `nodesList` in step A, then returns `Task.succeed ( ctx, nodesList, initTables ) |> Task.andThen loop`. Capture `main`, `ports` and `flagsDecoder` separately; never capture `monoGraph0` or `nodes` afterwards.
  3. Emit in batches, keeping `streamNodesList`'s tail shape (`:230-258`):
     ```elm
     streamNodesStep ( ctx, remaining, tables ) =
         case remaining of
             [] -> Task.succeed ( ctx, tables )
             _ -> Task.succeed (encodeBatch 256 ctx remaining tables)   -- (ctx', rest, tables')
                    |> Task.andThen streamNodesStep
     ```
- **Output:** byte-identical; ops and ctx are threaded in the same order.
- **Check:** at the post-codegen-nodes point, live bytes are far below the MonoGraph's size.

**Row 13: drain `pendingLambdas` per node. NOT byte-identical; do not ship under the identity rule.**
- Draining per node changes the order of funcs in the output, the string/attribute/type interning order (`StreamEncode.elm:75-112`), `nextOpId` (baked into `_tail_<name>_<n>`, `Expr.elm:5891`) and `typeRegistry` ids.
- It needs an approved re-baseline, plus a program-wide set of emitted names.

**Row 14: `inlineBodies`.**
- `bytesFusion.enabled` defaults to `True` (`Config.elm:699`).
- Use `withInlineBodies Dict.empty` only when fusion is off. That is identity-safe, because every consumer is fusion-gated.
- A narrower candidate filter needs the full identity gate, so defer it.

**Row 15: `assembleModule` copies** (`StreamEncode.elm:116-238`).
- Today it materialises the module up to four times; the peak is about 3N alongside `encodedOps`.
- Compute section lengths arithmetically (`varIntWidth` plus the sum of the `Bytes.width` of each op), then build one `BE.sequence` of headers plus `List.map BE.bytes ops`, encoded once. The peak becomes about 2N.
- `Section.encodeSection` has no padding (`Section.elm:51-64`), so the result is byte-identical.
- True streaming would need a new `hWriteBytes` kernel, which is out of scope.

### 7.7 Pre-link

**Row 16: `ctx` captured by the final closures.** Bind `style = ctx.style` in both `handleElfOutput` (`:468`, done in §6.3) and `handleMlirOutput` (`:366`). `ctx.details` can hold `ArtifactsFresh Interfaces Opt.GlobalGraph` (`Details.elm:265`).

**The headline check:** after rows 1-4, 12 and 16, the pre-link `liveAfterMark` should be tens of MB.

---

## 8. Part F: measurement

### 8.1 Tool: `benchmarks/mem-trace.sh` and `benchmarks/mem-trace-summary.py`

```
usage: mem-trace.sh -o <prefix> [-i <sec>=1] [-w <file-to-size>] -- <cmd> [args...]
writes <prefix>.tsv .time .stdout .stderr .meta ; exit code = the command's
```

It is the scratchpad sampler (`stage9b_monitor.sh`) with three fixes:
- **Time:** use `$(( (now_ns - T0) / 1000000 ))` from `date +%s%N`, with no `bc` (it isn't installed).
- **Schedule:** sample at `T0 + k·IVAL`, which avoids drift.
- **Threads:** group them by `comm` with any trailing `-<digits>` removed (`eco`, `eco-gc`, `eco-mark`, `eco-cmark`, `eco-tenure`, `llvm-worker`).

TSV columns: `t_ms rss_mb hwm_mb threads cpu_s majflt memavail_mb swapfree_mb out_mb group_cpu`. Each line is written immediately, so the file survives a kill.

`mem-trace-summary.py` (standard library only) takes one or more prefixes and adds a median row for an `-rN` triple. For each run it reports:
- **Peaks:** peak RSS (sampled and `time -v`) and when it occurred; minimum MemAvailable and when; maximum swap used; major faults.
- **Phases:**
  - **FE** runs to the last sample where the GC-group CPU rises by more than 0.2 s. Do not use thread presence: the 23 → 47 jump is the back end's MLIR context.
  - **BE** is the rest. Within it, the first rise in thread count marks the MLIR context, and the second rise (to about 71) marks parallel codegen.
  - Duration, peak and mean RSS for each phase.
- **GC reports:** every `[gc-report]` line on the time axis, with the sampled RSS just before and after it.
- **INVALID** if: `time -v` shows a signal; `[gc-stats] SIG` appears; the output file is missing; or MemAvailable stays under 256 MB for more than 10 s, which is the reaper zone.

### 8.2 Report line (`ECO_GC_REPORT=1`, from `GcPoints.render`, on stderr)

The line is printed by Elm, so the format is identical in both builds:

```
[gc-report] v=1 point=pre-link kind=major collected=1 total_ms=812.4 gc_ms=… sweep_ms=… shrink_ms=… discard_ms=… trim_ms=…
  live_mb=… inuse_mb=A>B pending_mb=A>B highwater_mb=… rss_mb=A>B>C released_mb=… discarded_mb=… nursery_mb=…
  minors=… majors=… majors_run=… trim=…
```

- The whole report is one physical line; it is wrapped above only for display.
- Fields are `key=value` pairs separated by spaces. `A>B` means before → after, and `rss_mb=A>B>C` is before, after the discard, then after the trim.
- Parse it with the regex `^\[gc-report\] v=1 (.*)$`, splitting first on spaces and then on `=`.

### 8.3 Experiment protocol

**Workload.** Stage 9b exactly:
- Run `bin/eco make --optimize --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/eco-2 /work/compiler/src/Terminal/Main.elm` from `build/compiler/build-kernel`, using the candidate's own Stage 9 `bin/eco`.
- Wrap it in `mem-trace.sh -w bin/eco-2`, with `ECO_GC_REPORT=1`, `touch ~/.eco/0.1.1/packages/registry.dat` and `ulimit -c 0`.
- Nothing else may run on the box: the low-memory reaper is active, and a reaped run is invalid, not a data point.

**Cache.** Cold `eco-stuff` (`rm -rf` before each run), because that is the largest heap. Add one warm run each for C1 and Cset.

**Matrix.** N = 3 per configuration, strictly serial and interleaved by round.

| config | env | purpose |
|---|---|---|
| C0 | `ECO_GC_PRE_LINK=0` | the same binary without the pre-link GC: separates Part E's effect from the GC's |
| C1 | (default) | pre-link only: the default and the reference |
| C2…Ck | `ECO_GC_POINTS=<p>` | one optional point at a time |
| Call | `ECO_GC_POINTS=all` | interaction bound |
| Cset | the points chosen by the rule below | confirms the final default |

Plus the pre-plan baseline: 15.27 GB peak, 238 MB minimum available, 21,768 major faults, 714.7 s.

**Decision rule.** A point becomes default-on only if all of these hold:
1. Median peak RSS is lower than C1 by at least 500 MB **and** at least 5 %, with every run below C1's minimum.
2. Median wall is at most C1's median plus the larger triple spread.
3. The point's own `total_ms` is at most 2 s.
4. `eco-2` is byte-identical in every run.

Choose greedily in order of peak reduction, then measure Cset. If Cset is worse than its best single point, keep only that point. A point that only raises minimum MemAvailable by at least 1 GB, with a flat peak, needs a reviewer's sign-off. A point that is not adopted is recorded as off, with its numbers.

**Output identity is a hard rule:** `cmp` the `eco-2` of every configuration and run.

---

## 9. Benchmark, gates, success criteria

### 9.1 Results template (§8.3 runs)

| config | run | wall (s) | peak RSS (MB) | t_peak (s) | min MemAvail (MB) | majflt | FE s / peak | BE s / peak | GC time (s) | pre-link rss A>B>C, released (MB) | eco-2 same |
|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 1 | 714.7 | 15,265 | ~600 | 238 | 21,768 | | | | — | — |
| C0 / C1 / C2…Ck / Call / Cset | r1-3, median | | | | | | | | | | |

### 9.2 Loop entry `FHR` (`benchmarks/gc-opt-loop.md` §6 and §9), a compiler-source step

1. `lss-loop-snap.sh verify keep-REGFIX`, then implement, then `snap try-FHR`, then `diff keep-REGFIX try-FHR > snapshots/lss-loop/step-FHR.patch`. The patch covers `runtime/src`, `eco-kernel-cpp/src`, `compiler/src` and `compiler/src-xhr`.
2. `cmake --preset build`. Then a clean runtime build, as REGFIX did: `ninja -t clean` of every runtime and kernel archive plus `eco-boot-native`, rebuilt with `CCACHE_DISABLE=1`. Configuration: RelWithDebInfo, stats on, timers, validate and census off, no TLA trace.
3. Phase 1.2: `elm-tests`, plus the 1-second `elm make` type check.
4. Phase 1.3: cold `eco-opt-prev make … --output=bin/ecoFHR.mlir`.
5. Phase 1.4: `$BOOT bin/ecoFHR.mlir -o bin/eco-optFHR`. Check with `nm eco-optFHR | grep Eco_Kernel_GC_majorGC`.
6. **Phase 1.5 is required.** New source is reachable through the kernel calls in `Builder.*`, so do the extra bootstrap turn to `ecoFHR-b.mlir` and `eco-optFHR-b`. The gate is B==C. Record `cmp ecoFHR.mlir ecoFHR-b.mlir`.
7. Phase 2: three cold runs with the §2 commands, with **no** `ECO_GC_*` variables. Check that the runs are deterministic and that `r1-out.mlir == ecoFHR-b.mlir`. Quote the change in `out.mlir` bytes (the workload moved).
8. **Do not expect the mandatory GC to show here.** The loop's workload emits `.mlir`, so the pre-link GC never runs; only the Part E drops and the configuration show. The memory claim is §8.3's Stage 9b triple, recorded in the same entry.
9. **The counter gate gets an exception, like W1/W6/W7, and every move must be explained.**
   - Minors may change only in proportion to the source growth and the extra Task steps.
   - Majors and promoted MiB are expected to fall, because Part E shrinks the live set and the live-budget trigger fires lower.
   - Quote the old-gen in-use peak.
10. Verdict per §4. The expected outcome is a flat wall with lower RSS, which is a WIN under rule 2.

### 9.3 Gates (a separate pass, `ulimit -c 0`)

1. **Unit tests:** `build/test/test`, including the §3.9 tests.
2. **Validate tree:** the unit suite plus the validate stress runs at default, gc-pressure and gc-pressure-parallel.
3. **`--target full` (E2E).**
4. **`elm-tests`:** must not get worse than 13,565 / 12.
5. **`ECO_TEST_XFAIL=strict` register-guards.**
6. **`kernel-license-check`** must pass. No rows are added.
7. **`tla-canary` strict:** M4, M6, M7 and M8 audits, plus M7's `DiscardAllPending` (§3.8) with `run_models.py --model M7` quick and deep.
8. **Stage 5 with `ECO_GC_POINTS=all ECO_GC_REPORT=1`:** `eco-compiler.mlir` must be byte-identical to a run without them.
9. **Full clean bootstrap** (`cmake --build build --target bootstrap`: stages 1-9, the 4b and 8c fixed points). Then run Stage 9b on its own under `mem-trace.sh`, with nothing else running.

### 9.4 Success criteria

- **Output is byte-identical everywhere** (B==C, `eco-2`, E2E, stage 5).
- **GC_DET_001 holds,** including the explicit-release test.
- **Loop wall is flat** within the band.
- **Stage 9b:**
  - peak RSS ≤ **10 GB** (baseline 15.27 GB);
  - minimum MemAvailable ≥ **3 GB** (baseline 238 MB);
  - major faults under 100 (baseline 21,768);
  - wall below 11:54.
- **Pre-link `liveAfterMark`** is in the tens of MB after Part E.
- **Each optional point is either default-on** by §8.3's rule, or recorded as off with its numbers.

---

## 10. Traps

1. **The rooting rule.** A callback's argument stays rooted until the callback returns. Never collect inside the consumer's own callback; always add a separate `andThen` step, and pass values through `passThrough`.
2. **Eager `let`s and capture through `if`.** `writeMlirTask` holds `artifacts` until its own step runs. `\_ -> if flag then f g else …` keeps `g` alive. Hoist the `if` out of the closure.
3. **Reading an MVar after dropping it is fatal** ("MVar not found" fails a `Task Never`). Drop only after the last reader; when in doubt, use `take` and then `drop`, with a single owner.
4. **One pause, one sync point.** Do not call `Allocator::majorGC()` and then sweep and shrink outside a pause: that splits the sync point and bills stalls to the wrong side.
5. **What the release cannot free.** Partly-live blocks stay (there is no production compaction), the 128 MiB commit-ahead window stays, and the nursery stays (v1). Judge the release by `rssAfterDiscard` and `discardedBytes`, not by `oldInUseAfter`.
6. **`malloc_trim` is glibc-only.** Call it outside `thread_mutex_`; it can take milliseconds.
7. **JS reports are not comparable with native ones.** V8's `heapTotal` is not the native committed old gen. `collected = 0` without `--expose-gc` is normal, not an error.
8. **Tests may read fields that Part E clears.** TestLogic suites and `generateMlirModule` (`Backend.elm:63`) may read `callEdges`, the LSS tables or `schemeRoots`. Grep before clearing.
9. **Baselines move.** The extra Task steps change the allocation sequence, so GC counters shift. Modes 1 and 2 must still agree, and recorded baselines need refreshing.
10. **Never give the `Eco.GC` kernels a `gcLeafEligible` row,** and never make Elm control flow depend on report values.
11. **`posix_spawn` for `Process.cpp`'s fork-then-exec** (a REGFIX follow-up) is separate from this plan.

---

## 11. As built

### 11.1 P0-P2 (2026-10-01)

**Built:**
- **P0** `benchmarks/mem-trace.sh` (the §8.1 usage; `date +%s%N` bash arithmetic, samples at `T0 + k·IVAL` with missed slots skipped, sleeps sliced to ≤ 0.2 s so the end is seen promptly, thread groups = `comm` minus a trailing `-<digits>`) and `benchmarks/mem-trace-summary.py` (peaks, FE/BE phases, `[gc-report]` lines on the time axis, INVALID rules, `-rN` medians, `--json`). Tested on short commands and on the old `stage9b_samples.tsv` (whose `t_s` is all 0: the summary re-spaces such samples over the `time -v` wall). **Not done:** the baseline Stage 9b trace with the fixed sampler (a self-compile; out of this pass's scope).
- **P1** `GCReport.hpp`; `platform::processResidentBytes` (posix: `/proc/self/statm` on Linux, else 0; win32: 0); `OldGenSpace::ShrinkPass {Heavy, Light, Forced}`, `finishSweepForRelease`, `shrinkToFloorForRelease`, `majorLiveBytes`; `GCStats::total_maybe_shrink_forced_ns` and `MajorReason::Explicit = 8` (`"explicit"`); `ThreadLocalHeap::majorGCAndShrink` (region `TLH.majorGCAndShrink`); `Allocator::collectMajorAndRelease` (region `AL.releaseDiscard`) and `collectMinor`; `NurserySpace::minorSeq`; HEAP_076 and the GC_DET_001 amendment; tests `testExplicitReleaseModesAgree`, `testExplicitReleaseReturnsMemory` (registered in `test/main.cpp`).
- **P2** `eco-kernel-cpp/src/Eco/GC.elm` (the §4.1 record, decoder and zero record), `src/eco/GC.{hpp,cpp}`, `GCExports.cpp`, `KernelExports.h`; `EcoKernel_GC` in `eco-kernel-cpp/CMakeLists.txt` (library, aggregate, asserts list), `ECO_KERNEL_MODS`, the three `compiler/CMakeLists.txt` link lists; `"Eco.GC"` in `eco-kernel-cpp/elm.json`.
- **TLA canary:** pins fired `OGS.onSweepComplete` / `OGS.maybeShrinkCapacity` (M4, M8: no model change), the `Allocator.cpp` census and `F.threadMutex` (M6: no change; M7: model updated); new pins `TLH.majorGCAndShrink` (M1, M4, M8) and `AL.releaseDiscard` (M6, M7). **M7: the preferred option** — a `DiscardAllPending` mutator step (`M_DrainSlots`, `M_DrainDiscard`) in `PageWork.tla`, invariant `DrainSafe`, mutant `drain_no_await`; quick 28/28 and both deep rows pass (AUDIT.md 2026-10-01).

**Deviations from §3-§4:**
1. **`minorSeq` is a new always-on counter.** `census_minor_seq_` exists only in P1 census builds (`#if P1_CENSUS_COMPILED`), so `NurserySpace` has its own `minor_seq_`, incremented at `NurserySpace::minorGC` entry (both nursery modes; the parallel and region minors go through it).
2. **No `drainAll` wrapper:** `PageWork::drainAll` was already public. The call is `drainAll(page_work_->decommitOn())`, so with decommit off nothing is discarded (the config is respected) and the PageWork file pins did not fire.
3. **"Abort" in §3.3 is an early return** for the Forced pass (`gc_phase_ != Idle`, a cycle, a compaction). `finishSweepForRelease` additionally aborts (fatal) if a mark cycle is active, since its loop would not terminate on `Marking`.
4. **`collectMinor`** sets `rss_after_discard = rss_after` (as §5.2's JS report does) and `gc_ns` = the minor's time; sweep, shrink, discard and trim stay 0.
5. **§3.9 test 1:** an explicit round (`r % 6 == 5`) **replaces** that round's own major: `r % 6 == 5` is always an `r % 3 == 2` round, and the preceding major left nothing to release (`released > 0` failed). ModeRun folds `x_live`, `x_inuse_after`, `x_released` (and a count of calls that left pending bytes); `sameObjects` compares live and released, `==` also in-use.
6. **§3.9 test 2:** 256 × 1 MiB ByteBuffers, rooted, then dropped; runs in mode 0 and in mode 2 with the production schedule (`decommit_delay_majors = 1`, syncs never). The heap reservation is first-init-wins for the test process, so when an earlier test reserved a small heap the test scales to half the old-gen cap (drop ≥ half the dead bytes; skipped below 32 MiB).
7. **mem-trace TSV** has one more column than §8.1, `gc_reports` (the count of `[gc-report]` lines in `.stderr` so far), before `group_cpu`: it is what places each report on the time axis. "Max swap used" is the drop of SwapFree from the first sample (the box may start with swap in use).
8. The stale `eco-kernel-cpp/{typed-,}artifacts.dat` were already absent.

**Open for P3 (a hazard until then):** `Eco/GC.elm` imports `Eco.Kernel.GC`, and `Build.checkKernelExistsInDirs` requires `eco-kernel-cpp/src/Eco/Kernel/GC.js` to exist for **every** build that compiles the `eco/kernel` package (native ones too). Since `Eco.GC` is now exposed, E2E and bootstrap builds will report an import error until §5.3's `GC.js` lands. Also: `test/CMakeLists.txt`'s JIT whole-archive lists do not include `EcoKernel_GC` (not in §4.4); add it if a JIT-run test program ever calls `Eco.GC`.

### 11.2 P3-P4 (2026-10-01)

**Built:**
- **P3** `eco-kernel-cpp/src/Eco/Kernel/GC.js` (§5.3; returns the JSON string with exactly the C++ `toJson` keys; guards `process` for non-Node hosts) — this closed the §11.1 hazard. `compiler/src-xhr/Eco/GC.elm` (same exposing list, record, decoder and zero record as the kernel variant; transport `Eco.XHR.jsonTask "GC.minor"/"GC.major"`). `runGc` + `GC.minor`/`GC.major` in `compiler/bin/eco-io-handler.js`. `--expose-gc` on the four node invocations (`compiler/CMakeLists.txt:295, 324, 355, 425` — the plan's line numbers were right). `compiler/elm-application.json` lists modules explicitly: `Eco.GC` and `Builder.GcPoints` added. `EcoKernel_GC` added to the `test` target's whole-archive lists (all three platform branches; not `stress-test`), plus a JIT E2E test `test/eco-kernel/src/GcReportTest.elm` (minorGC then majorGC: kinds, `collected = 1`, `majorsRun >= 1`).
- **P4** `Compiler.Eco.Config`: `GcPoint` (7 constructors), `GcConfig`, `allGcPoints`, `gcPointFromString`/`gcPointToString`; `gc` is the LAST `EcoConfig` field, decoded by a last positional `D.apply (D.optionalField "gc" gcDecoder default.gc)` (JSON `{"gc": {"points": [...], "preLink": b, "report": b}}`; unknown JSON point names skipped silently because the decoder never fails); not hashed (comment at the top of `hash`). `Builder.Eco.Config.applyEnvOverrides` appends `ECO_GC_POINTS` (comma list; set-but-empty = `[]`; `all` = every point; unknown names warned on stderr and skipped; duplicates collapsed), `ECO_GC_PRE_LINK`, `ECO_GC_REPORT` (both `1|true|yes|on` / `0|false|no|off`, others ignored). `compiler/src/Builder/GcPoints.elm` (`at`, `passThrough`, `preLink`, `render`). Pre-link step in `Terminal/Make.handleElfOutput` exactly as §6.3 (`style`/`gcCfg` bound in the `let`; `reportGenerate style …`).
- **Optional points inserted (each its own `andThen` step):** post-build (first step of `Generate.buildMonoGraph`, `loadTypedObjects` moved into the following lambda); post-merge (after `finalizeAndMergeTypedObjects`); post-mono (in `monoPipelineFrom`, after the `withPhase PhaseMono` task, before `runInlineSimplifyPhase` — i.e. "after mono returns", so solver state is collectable too); post-inline (before `runGlobalOptPhase`); post-globalopt (both `writeMonoMlirStreaming*`, after `buildMonoGraph`); **post-codegen-nodes** (in `Backend.streamMlirBytecode` between `streamNodesCollectEncode` and the lambdas/main/assemble step — that boundary already exists today: the pure node loop runs while the task is built, inside the caller's callback, and the existing `andThen` runs after it returned, so no row 12 change was needed for the point itself; row 12 is still what removes the MonoGraph pin DURING the loop).
- **Deferred to Part E:** post-assign (needs row 5's `EntryPrep.assign` step split in `buildMonoGraphFromMerged`/`runMonoOptPipeline`; the name is parsed and `GcPostAssign` exists, but no call site, so `ECO_GC_POINTS=post-assign` is accepted and inert).

**Deviations:**
1. `src-xhr/Eco/GC.elm` decodes with `D.oneOf [ reportDecoder, D.succeed zero ]`, so an undecodable handler reply gives the `kind = "error"` record as §4.1 requires instead of an `orCrash` crash (§5.1's sketch passed `reportDecoder` straight to `jsonTask`).
2. `render` adds `shrink_released_mb=` (after `released_mb`) — the one report field §8.2's line did not carry. Times are ms and sizes MiB (2^20), both with one decimal from integer arithmetic; `trim=` is the raw `malloc_trim` rc (-1 in JS).
3. `Builder.GcPoints` is imported by `Compiler.Generate.MLIR.Backend` (a `Compiler.*` → `Builder.*` edge; precedent `Compiler.Reporting.Error`). Its post-codegen-nodes GC runs INSIDE the `PhaseMlir` timer (the `withPhase` wraps the whole bytecode task); the other points fall outside the phase timers as §6.4 intends (post-mono is after `PhaseMono`'s task).
4. The pre-link point is wired only on the ELF path; `handleMlirOutput` (row 16's second half) is untouched.
5. `ECO_GC_POINTS`: `all` may appear anywhere in the list (it selects every point; other valid names are then redundant, unknown ones still warn).

**Trap found (affects every later phase): the seeded `eco/kernel` cache is never refreshed.** `Details.seedLocalPackage` copies `--local-package eco/kernel` into `~/.eco/0.1.1/packages/eco/kernel/1.0.0` only when that directory has no `src/`, so the copy predated `Eco.GC` (its `elm.json` lacked the module) and the first `--target full` failed `GcReportTest` with MODULE NOT FOUND (2005 passed / 1 failed). Fixed by moving it aside to `1.0.0.stale-1790861021` (the convention already in that directory) and removing the test's `build/test/eco-kernel/eco-stuff/0.1.1/GcReportTest*` (its `d.dat` cached the stale dependency); the cache re-seeded on the next run. **Any machine/cache that compiles the compiler against `eco/kernel` (bootstrap stage 2+, `eco-opt-prev make`) needs the same move-aside first,** or `Builder.GcPoints`'s `import Eco.GC` fails.

**Verification:** `elm make` type check of `Terminal/Main.elm` (build-xhr) clean; `elm-tests` 13,565 passed / 12 failed (= the §9.3 baseline, no change); `--target guida` OK; `--target full` once: 2005 passed, 1 failed (`GcReportTest`, the stale cache above); after the fix `build/test/test --filter GcReportTest` passes (native JIT: `Eco.GC` → `Eco_Kernel_GC_*`). Stage 1 functional: `node --expose-gc compiler/bin/index.js make src/GcReportTest.elm` with `ECO_GC_POINTS=all,bogus ECO_GC_REPORT=1` printed the warning for `bogus` and six well-formed `[gc-report]` lines (post-build, post-merge, post-mono, post-inline, post-globalopt, post-codegen-nodes; e.g. post-build `rss_mb=171.8>111.9>111.9`), and its `.mlir` was byte-identical to the harness's (no GC env). `node -e` on `eco-io-handler.js`: `GC.major`/`GC.minor` return the full key set, `collected=0` without `--expose-gc`. The stage-1 ELF path stopped at a CORRUPT CACHE report before codegen when reusing a builddir that had just built `.mlir` (not investigated; JS ELF is unreachable by design, §5.4). Not run here: bootstrap, Stage 9b, a native build of the compiler with the new modules (stage 6/7a).

### 11.3 Part E batch 1 (2026-10-01): E0, rows 2, 1, 3, 4, 16, 12, 15

**Built** (snapshot `try-FHR-E1`; pre-batch tree = `try-FHR-P4`; GC reports saved in `try-FHR-E1/gc-reports-{E0base,E1}.txt`):
- **E0** `FEStats.withPhaseLazy : Handle -> PhaseName -> (() -> Task x a) -> Task x a` (Disabled = `Task.succeed () |> Task.andThen thunk`; Enabled = `withPhase` with `thunk ()` called inside the timing step). The five call sites switched: `monoPipelineFrom` (PhaseMono — the attribution fix), `runInlineSimplifyPhase`, `runGlobalOptPhase`, both `writeMonoMlirStreaming*` (PhaseMlir). `withPhase` is kept (Make.elm's PhaseLocal users).
- **Row 2** `Reporting.trackBuild : Style -> (BKey -> Task Never (BResult a)) -> Task Never (BResult a)` (decoder/encoder parameters dropped; both `Build.elm` callers updated); the channel is `Chan (Result BMsg (BResult ()))`, written with `Ok (Result.map (\_ -> ()) result)`, encoded by `buildChanEncoder = BE.result bMsgEncoder (bResultEncoder BE.unit)`, decoded with `bResultDecoder BD.unit`. `Utils.readChan` takes the hole then drops it (also fixes `trackDetails` and the per-`BDone` hole leak).
- **Row 1** `Build.takeAndDropStatuses` (take `smvar`, read every status, drop every status MVar, drop `smvar`) used by `collectPathStatuses` and by `waitForCrawlResults` (exposed path); `readAndDropRootStatuses` drops the root-status MVars in `crawlRootsAndCollect` after reading them. The REPL crawl (`crawlRepl`) is untouched.
- **Row 3** `takeAndDropDependencies` replaces `readMVar … dmvar` on all five `checkMidpoint`/`checkMidpointAndRoots` paths. `PathCompileState` gains `rmvar`; `finalizePathBuild` now reads results → `writeDetailsAndCollectRoots` (write details, read root results) → THEN drops the result MVars, the root-result MVars and `rmvar` (the reorder fix: result MVars used to be dropped before the `checkRoot` forks were awaited).
- **Row 4** `Generate.buildMonoGraph`'s first step is `Task.io (Utils.listTraverse_ dropCachedInterfaceMVar artifacts.modules)`, before the post-build point.
- **Row 16** `handleMlirOutput` binds `style = ctx.style`; the final closure captures it, not `ctx`.
- **Row 12** `Backend.streamMlirBytecode` builds ctx/node list/tables (step A = the `withPhaseLazy` thunk's step), then `Task.succeed ( ctx, nodesList, initTables ) |> Task.andThen streamNodesStep`; each step runs `encodeNodeBatch 256` (pure, tail-recursive, the old per-node body in the same order) and continues in a new step. The tail is a top-level `finishBytecode main ports flagsDecoder target` PAP (captures exactly those, never the graph). `streamNodesCollectEncode` removed. The post-codegen-nodes point sits between the loop and `finishBytecode`.
- **Row 15** `StreamEncode.assembleModule` encodes once: the IR section is `irSection` — two nested section headers whose lengths come from new `VarInt.varIntWidth` (mirrors `encodeVarInt`'s branches: 1/2/3/4 bytes, else 9) plus the summed `Bytes.width` of the ops (one fold that also builds the oldest-first `BE.bytes` list); `assembleIrSection` removed. The small table sections still use `Section.encodeSection`.

**Identity.** `ecoE1.mlir` (eco-opt-prev = REGFIX compiling the batch source) == `ecoE1-b.mlir` (the candidate `eco-optE1` compiling it) == the candidate with `ECO_GC_POINTS=all ECO_GC_REPORT=1` == the pre-batch binary (`eco-optE0base`) compiling the same source: all `cmp`-identical, 13,254,107 bytes. Stage-1 JS (`guida.js` old vs new) produced identical `.mlir` for four `test/elm` programs, cold and warm cache.

**Effect** (one cold self-compile each, `ECO_GC_POINTS=all ECO_GC_REPORT=1`, same source; MiB; `inuse` = after, `rss` = after discard):

| point | live before → after | inuse before → after | rss before → after |
|---|---|---|---|
| post-build | 1628.0 → 1499.0 | 3272.1 → 2978.0 | 4041.0 → 3734.4 |
| post-merge | 1645.8 → 1514.5 | 3423.2 → 3119.7 | 4019.1 → 3723.2 |
| post-mono | 1758.3 → **149.0** | 3984.2 → 1222.7 | 4607.6 → 1850.6 |
| post-inline | 1741.1 → **128.8** | 3971.7 → 1233.2 | 4589.4 → 1859.6 |
| post-globalopt | 1751.8 → **139.5** | 4004.2 → 1287.2 | 4617.5 → 1925.1 |
| post-codegen-nodes | 1803.2 → **185.0** | 3908.7 → 1249.2 | 4533.6 → 1869.0 |
| (`time -v`) | max RSS 9,063 MB → 9,619 MB; wall 2:02.8 → 1:54.5 | | |

Reading: ~1.6 GB was pinned from the build to the end (rows 1-4: the progress channel's `Artifacts`, crawl statuses with source/ASTs, result MVars); it stays live through post-merge because `buildMonoGraph` still needs the modules there, and is gone from post-mono on. Live at post-codegen-nodes is 185 MB, far below the graph (row 12's check). The peak RSS rose 0.56 GB in this single run (old-gen high-water 8,278 → 8,830 MB, during mono, before the post-mono point): with `ECO_GC_POINTS=all` the explicit majors reset the trigger baseline, and the trigger is chaotic (one run is not evidence either way); the §8.3 Stage 9b triple is the memory verdict.

**Deviations:**
1. Row 1/3 helper names (`takeAndDropStatuses`, `readAndDropRootStatuses`, `takeAndDropDependencies`) instead of inlined chains; same order as §7.2.
2. Row 12 batch boundary counts node-list ENTRIES (including empty slots), not emitted nodes; output-neutral.
3. Row 12's tail is a top-level function (`finishBytecode`) rather than a lambda capturing `main/ports/flagsDecoder`, to make the capture set explicit.
4. Not measured per row: the batch was built and measured as one unit (one before/after pair), so the table cannot split rows 1-4's share from row 2's.

**Verification:** `elm make` type check clean; `elm-tests` 13,565 passed / 12 failed (= baseline); `--target full` once: **2006/2006 passed**; identity and effect as above. Kept in `build/compiler/build-kernel/bin`: `eco-optE1`, `ecoE1.mlir`. Not done in this batch: rows 5-11, 13, 14; the §8.3 Stage 9b memory runs.

### 11.4 Part E batch 2 (2026-10-01): rows 6, 5, E-a, E-b, 9, 10, 11, 7, 8 (row 14 not built)

**Snapshots/patch:** no `step-FHR-E2.patch` (the `snapshots/` tree had been deleted, so there is no `try-FHR-E1` to diff against; git is the permanent history). A fresh `try-FHR-E2` snapshot was taken after the gates, as a local rollback point only.

**Built** (each claim was checked against the code before the change):
- **Row 6** `AssignMVarIds.assignIds` emits `GlobalGraph newNodes fields newAnnotations DMap.empty Dict.empty` and `{ state2 | rootEnv = Dict.empty, arrowRootEnv = Dict.empty }`. Verified: every consumer of the assigned graph matches fields 4-5 as `_` (both engines' `…Assigned` entries, `Fresh.assertMinted`, `LiftClosedArgs`, `EtaExpand`/`AliasForward` index builders) or only passes them through (`rewriteGraph` in `AliasForward`, `EtaExpand`, `InlineSimplify`). Outside this pass nothing reads `rootEnv`/`arrowRootEnv` (the `rootEnv` in `MonoSolver/Translate` is an unrelated local). No test consumes `assignIds`' graph fields; `lamLabels` is kept.
- **Row 5** `EntryPrep.assign` moved into `buildMonoGraphFromMerged`, followed by `Task.succeed ( assigned, globalTypeEnv ) |> andThen (GcPoints.passThrough … GcPostAssign) |> andThen (\( a, env ) -> runMonoOptPipeline ecoConfig stats env a)`. `runMonoOptPipeline : EcoConfig -> Handle -> GlobalTypeEnv -> Assigned -> …` (argument order changed). **The deferred `post-assign` point is now wired** (§11.2).
- **E-a** `runInlineSimplifyPhase`'s thunk runs only `MonoInlineSimplify.optimize` and returns `Task.succeed ( inlinedGraph, inlineMetrics ) |> andThen (pruneAndReportInline ecoConfig)`. The new top-level function captures only `ecoConfig` and holds the prune, the census and `validatePruned`.
- **E-b** `runGlobalOptPhase` is now 5 steps: GlobalOpt (thunk) → `globalOptCseStep` → `globalOptDedupeStep` → `globalOptHoistStep` → `globalOptReportStep`. These are top-level functions over a flags-only `GlobalOptCfg` and a `GlobalOptCarry` (stats plus already-rendered census strings). The census lines that need an intermediate graph (CSE census on `goGraph`, pre-hoist CAF census on `optimizedGraph`) are rendered to `Maybe String` in the step where that graph is live, so no closure captures an intermediate graph. Every stderr line is still written in the original order by the last step.
- **Row 9** `globalOptimizeWithStats` destructures `( sol.dynamicSlots, g, w )` right at the `analyzeAndSolveStaging` call.
- **Rows 10 + 11** new `Mono.clearLssTables { keepOrigins }`, called right after AbiCloning (Phase 4). It empties `lssMemberKinds` and `lssBlockedMembers`; it empties `lssMemberOrigins` unless `keepOrigins = borrow.enabled || borrow.oracleOpt || list.mapTemplate` (a new `Bool` parameter of `globalOptimizeWithStats`; callers `globalOptimize`, Generate and `TestPipeline` updated). Row 11 is in the same function: `registry.mapping`, `countByGlobal`, `specHasEffects` and `specValueUsed` have no reader after GlobalOpt (grep over `GlobalOpt/`, `Generate/`, `Builder/`). Clearing them is a no-op on the default path, where `Prune` and the inliner already emptied them, and frees them with `inline.postMono = False`. No test reads these tables from a post-GlobalOpt graph: the `Lss*`, `MuTie` and `LayoutQual` tests read mono-time graphs, and `BorrowTailCallEscape` uses `analyzeDefForTest`, which reads only `nodes`.
- **Row 7** `MonoSolver.Monomorphize`: `Ok (CellStore.disposeThen sFinal.store.ioRefsPoint ( graph, report ))`.
- **Row 8** `Prune.pruneAfterInline` replaces the pruned graph's `callEdges` with `restrictToSccEdges` of it (new and exposed): Kosaraju via `Graph.stronglyConnCompInt`, keeping only edges whose ends share a component, with each row's order and its `Nothing`/`Just` shape preserved. New fuzz test `PostInlinePruneTest` "restrictToSccEdges preserves the cyclic set of every induced subgraph" (it also passed separately at `--fuzz 3000`). `invariants.csv` updated: MONO_022 (callEdges carries intra-SCC edges only, is live, and is deliberately stale after GlobalOpt) and CGEN_069 (callEdges is NOT dead; the "verified dead" wording was wrong).

**Not built:**
- **Row 14: its premise is false.** `inlineBodies` has a reader that `bytesFusion.enabled` does not gate. The DECODE-fusion paths (`tryInlinedDecodeFusion` → `tryDecodeFusionWithBindings`, and the `Bytes.decode` / `Decode.decode` intercepts at `Expr.elm` ~3845 and ~4355) run whatever the flag is set to. They compile residuals through `bfExprCompiler` → `resolveFusedLets` → `findLetInInlineBodies`, which folds over `ctx.inlineBodies`. Emptying the table in the fusion-off arm could change that arm's output, and no gate here covers that arm. Only the encode `reifyEncoderWith` sites are gated.
- **Row 13:** not attempted (it needs approval).

**Identity** (`BK` = build-kernel, solver+LSS):
- `ecoE2.mlir` (eco-optE1 compiling the batch-2 source, cold) == `ecoE2-b.mlir` (eco-optE2 self-compile), `cmp`-identical at 13,264,494 bytes.
- These runs were also identical to `ecoE2.mlir`: eco-optE1 with `ECO_GC_POINTS=all ECO_GC_REPORT=1`, eco-optE2 with `all` (now including post-assign), and eco-optE2 with E1's six points.
- **Row 8 `isRecursive` check** (a temporary instrumented binary, never shipped). It kept the FULL post-prune edges, and on the codegen-time graph it compared `buildCallGraph`'s `isRecursive` from those edges with the one from `restrictToSccEdges` of them. On the self-compile: `liveSpecs=32564 edgesFull=121014 edgesScc=8712 recursiveFull=3944 recursiveScc=3944 identical=yes`, so **the recursive sets are identical and 92.8 % of the edges are dropped**. Its output (full edges, no restriction) was also `cmp`-identical to `ecoE2.mlir`. The instrumentation was applied only after the identity and effect runs above, and was then reverted (the three files were restored from copies).

**Effect** (one cold run each under `mem-trace.sh`, same batch-2 source, the six points E1 has. MiB; `inuse` is after the GC; `rss` is after the discard):

| point | live E1 → E2 | inuse E1 → E2 | rss E1 → E2 |
|---|---|---|---|
| post-build | 1500.5 → 1500.5 | 2962.5 → 2956.5 | 3718.7 → 3711.3 |
| post-merge | 1514.7 → 1514.7 | 3104.2 → 3097.2 | 3708.7 → 3700.3 |
| post-mono | 149.2 → 149.2 | 1228.2 → 1218.7 | 1853.9 → 1841.6 |
| post-inline | 129.3 → 138.1 | 1236.2 → 1236.2 | 1857.6 → 1852.0 |
| post-globalopt | 141.3 → 133.4 | 1293.2 → 1368.2 | 1924.2 → 1936.9 |
| post-codegen-nodes | 185.2 → 185.4 | 1256.7 → 1332.2 | 1869.0 → 1900.0 |
| peak RSS (`time -v`) | 9,613 MB → 9,609 MB (sampled peak at t = 53-54 s, both) | wall 115.6 → 113.6 s | min MemAvailable 4,917 → 4,927 MB |

With `ECO_GC_POINTS=all` (post-assign added): post-assign live **2367.6**, inuse 5159.7 → 4246.2, rss 5738.5 → 4860.0. At the next point (post-mono), E1's inuse-before is 5688.7 and E2's is 4568.7, so the extra collection cut the pre-mono/mono heap by about 1.1 GB. Peak RSS was still 9,612 MB.

**Reading:**
- **The batch does not move peak RSS on this workload, and cannot.** The peak is at t ≈ 53 s, inside the Build phase: before post-build (t = 68 s) and before any code this batch touched.
- **Per-point live differences of ±10 MB are noise.** `live_mb` is old-gen marked bytes, and the explicit major does not empty the nursery first (384 MiB). Young objects are therefore uncounted, and two binaries whose allocation sequences differ (minors 2432 vs 2435 at post-inline) split the same live set differently. The row 8/10/11 savings are of that order or smaller. A precise per-row figure needs a minor before the major in `GcPoints.collect` (not done here; it would change §6.2).
- **Post-assign live (2.37 GB) exceeds post-merge's (1.51 GB):** the MVarId graph plus the allocator state is larger than the Name graph it replaces. Whether any of the Name graph survives to post-assign was not established; a heap census would settle it.

**Deviations:**
1. Row 5's docstring move: the PHASE 0 comment now sits in `buildMonoGraphFromMerged`.
2. E-b renders the two intermediate-graph censuses early, as strings, rather than reordering the stderr output.
3. Rows 10/11 live in one function in `Monomorphized.elm`, called inside `globalOptimizeWithStats`, so `globalOptimize` (tests) clears too. Test defaults have `keepOrigins = False` and no test reads the tables afterwards.
4. Row 14 not built (above).

**Verification:** `elm make` type check clean; `elm-tests` 13,566 passed / 12 failed (the baseline 13,565 / 12 plus the new fuzz test); `--target full` once: **2006/2006 passed**. Kept in `build/compiler/build-kernel/bin`: `eco-optE2`, `ecoE2.mlir` (and `eco-optE1`, `ecoE1.mlir`). Not done: rows 13 and 14; the §8.3 Stage 9b memory runs.

### 11.5 P6: Stage 9b experiment matrix (2026-10-01)

Unified `eco` built from the tree after Part E batches 1 and 2. One cold run per configuration, at the user's request (2026-10-01): "the impacts will be obvious or not, and only matter if they are obvious". The runs used `benchmarks/fhr-matrix.sh` with `mem-trace.sh`; the data is in `benchmarks/fhr/p6/`. All three `eco-2` outputs are byte-identical.

| config | peak RSS (when) | BE peak | min MemAvailable | swap / majflt | wall |
|---|---|---|---|---|---|
| pre-plan baseline (old `eco`, warm) | 15.27 GB (BE) | — | 238 MB | 2.6 GB / 21,768 | 714.7 s |
| C0 (`ECO_GC_PRE_LINK=0`) | 14.63 GB (BE, 732 s) | 14.63 GB | 307 MB | 2.0 GB / 307 | 746.4 s |
| **C1 (default)** | **9.73 GB (FE, 57 s)** | **9.24 GB** | **4.9 GB** | **0 / 2** | 768.1 s |
| Call (`ECO_GC_POINTS=all`) | 9.73 GB (FE, 57 s) | 9.32 GB | 5.1 GB | 0 / 25 | 767.2 s |

**C1's pre-link report:**

| live | RSS before → after discard → after trim | time |
|---|---|---|
| **3.3 MB** (1.63 GB before Part E) | 8,005 → 923 → 917 MB | 347 ms |

**Decision:** every optional point stays **off**.
- **No benefit:** Call does not beat C1 on peak, minimum MemAvailable or faults. The peak now lies in the front end's build (type-check) phase, before the first point.
- **Real cost:** each point adds 0.3-2.8 s.
- **Single points were not run:** each is a subset of Call, and Call shows no benefit.

The config, the `ECO_GC_POINTS` plumbing and the call sites stay, for future experiments.

**Against §9.4:**

| criterion | result |
|---|---|
| Stage 9b peak RSS ≤ 10 GB | **met** (9.73) |
| min MemAvailable ≥ 3 GB | **met** (4.9) |
| major faults < 100 | **met** (2) |
| wall vs 11:54 | the 11:54 baseline was warm-cache. Cold C1 is 768 s; same-session C0 is 746 s (single runs) |

**Remaining peak:** about 9.7 GB in the build/type-check phase, outside this plan's scope.

### 11.6 P7: loop entry, gates, bootstrap (2026-10-01) — **INCOMPLETE: stopped at the user's request; `eco-opt-prev` NOT promoted**

**Done:**
- **Snapshot** `try-FHR` (tree verified == `try-FHR-E2` first). No `step-FHR.patch`: `keep-REGFIX` no longer exists.
- **Clean runtime build** in `build/` (`cmake --preset build`; `ninja -t clean` of 43 runtime/kernel archives + `eco-boot-native`, 258 files; `CCACHE_DISABLE=1 cmake --build build`, 245 steps, rc 0).
- **Phase 1.3/1.4/1.5:** `eco-opt-prev` (REGFIX) → `bin/ecoFHR.mlir` (13,264,494 B), `cmp`-identical to `ecoE2.mlir`; lowered to `bin/eco-optFHR` (`Eco_Kernel_GC_majorGC` present); `eco-optFHR` self-compile `ecoFHR-b.mlir` == `ecoFHR.mlir` (B==C), so the candidate is `eco-optFHR`.
- **Phase 2 triple** (no GC env): medians wall 107.04 s (+0.54, flat; spread 1.43), GC 7.86 s (+0.21), minors 2558 (+37), majors 11 (+1), promoted 20,525 MiB (+205), max RSS 9,840,052 kB (−1.02 GB, −9.4 %), old-gen in-use peak 8,820 MB (REGFIX 9,796). Deterministic, fixed point, no `[gc-stats] SIG`. **Verdict WIN (rule 2: flat wall, RSS down)**; the entry, with the counter-gate explanation (majors ROSE, not fell: the smaller post-sweep live set lowers the live-budget trigger, which is also why the peak fell), is `benchmarks/gc-opt-loop.md` §6 `FHR` + §9 row. Kept: `bin/eco-optFHR`, `bin/ecoFHR.mlir`, `eco-optFHR-r{1,2,3}.{time,stdout,stderr}`, `bin/eco-optFHR-r1-out.mlir`.
- **Gate `--target full`** (once, `/tmp/test_output.txt`): **2006/2006 PASSED** (unit + JIT E2E incl. `GcReportTest` and the §3.9 explicit-release tests); the ALL rebuild inside it re-ran `kernel-license-check` (passed) and the TLA canary (warn mode, no failure).
- **Bootstrap, run stage by stage after `full`:** `eco-boot` OK; `eco-boot-verify` OK (**4b JS fixed point passed**); `run-aot-e2e` (Gate B) **899/901**, failures exactly the known `FlagsRecordTest` and `PortEchoTest`; Stage 5 (`ECO_MONO_ENGINE=subst`) OK, `eco-compiler.mlir` 12,112,003 B.
- **Gate 8 (Stage 5 identity):** Stage 5 re-run with `ECO_GC_POINTS=all ECO_GC_REPORT=1` (same command, separate output) printed 7 `[gc-report]` lines (`collected=1`, V8 `--expose-gc`) and its `eco-compiler.mlir` is **byte-identical** to the plain one.
- **`bootstrap` target:** Stage 6, 7a, 7b completed; Stage 7a's `eco-compiler-boot.mlir` == `ecoFHR.mlir`, and Stage 8a's `eco-compiler-boot-2.mlir` (written before the stop) == `ecoFHR.mlir` too. **Interrupted during Stage 8 by the user** (ninja "interrupted by user", rc 2).

**Not done (stopped by the user):** Stage 8b/8c native fixed point (the binary `cmp`), Stage 9/9b (`eco-verify`) and the traced Stage 9b run under `mem-trace.sh` (the §11.5 C1 figures remain the memory claim); `elm-tests`; the `build-validate` tree (deleted; not re-created), its unit suite and the validate stress runs (default / `heap-config-gc-pressure.json` / `-parallel`, via `ECO_HEAP_CONFIG=… build-validate/test/stress-test`, build `test stress-test ecoc` by name); `ECO_TEST_XFAIL=strict register-guards`; `check-tla-manifest.sh` strict and the M7 quick/deep model runs; promotion (`keep-FHR` snapshot, `eco-opt-prev -> eco-optFHR`). `eco-opt-prev` still points at `eco-optREGFIX`.

- 2026-10-01 (after the halt): strict TLA canary `check-tla-manifest.sh .` = **green** (rc 0) on the final tree. Remaining gates are paused at the user's request (they killed the `full` run, which had already passed, and the bootstrap): elm-tests, build-validate unit + stress, strict register-guards, M7 model runs, bootstrap from Stage 8c through Stage 9b plus the traced Stage 9b re-run, then promotion of FHR.

### 11.7 Optional GC points removed (2026-10-01, user decision)

`benchmarks/fhr-gc-points.md` measured each optional point alone and all seven together, one cold self-compile per configuration. The points gave no change in peak memory and cost +1 to +4 s of wall each (+9.7 s for all seven). The user decided:
- **`pre-link` stays ON by default.** `ECO_GC_PRE_LINK=0` remains the opt-out and `ECO_GC_REPORT=1` the report switch.
- **The seven optional points are removed from the code.**

What was removed:
- in `Builder/Generate.elm`, the six call sites: post-build, post-merge, post-assign, post-mono, post-inline, and post-globalopt (×2);
- the post-codegen-nodes call site in `Compiler/Generate/MLIR/Backend.elm`;
- `GcPoints.at` and `GcPoints.passThrough`;
- from `Compiler/Eco/Config.elm`: `Config.GcPoint`, `allGcPoints`, `gcPointFromString`/`gcPointToString`, and the `GcConfig.points` field with its decoder;
- the `ECO_GC_POINTS` env override (`applyGcPointsOverride`) in `Builder/Eco/Config.elm`.

The step boundaries that Part E needs stay in place, among them row 5's assignment step and row 12's batched codegen steps. Removing a pass-through step never changes a value, so the output is unchanged; the fixed-point check below confirms it.
