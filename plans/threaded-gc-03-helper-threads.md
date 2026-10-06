# Threaded GC 03 — Helper-thread infrastructure

**Status:** DONE (2026-09-25).
- **Compiled defaults:** `gc_thread_mode` 2 (concurrent), `decommit_delay_majors` 1,
  `decommit_delay_syncs` never, `decommit_pending_max_bytes` 0, `commit_ahead_bytes` 128 MiB,
  `gc_helper_threads` 1, `gc_helper_cpu` −1.
- **Snapshot and binary:** snapshot `keep-TG3` (+ `extra-files.tar`), `bin/eco-opt-prev` =
  `eco-optTG3`, loop entry TG3.
- **Results:** P§12 below.

(Originally PLANNED 2026-09-25, against the `keep-TG2` tree: `bin/eco-opt-prev` = `eco-optTG2`,
reference MLIR `ecoghash.mlir`.)

**Parent:** `plans/threaded-gc-master-plan.md`, phase 3.

**Background:**
- `design_docs/parallel-gc.md`:
  - §3.1 threads and ownership;
  - §3.2 handshakes (why mutator-initiated post/collect);
  - §3.4 memory model;
  - §6.4 housekeeping that can move to a GC thread;
  - §10 measuring a concurrent collector (GC_DET_001, the synchronous mode, the decomposition);
  - §11.1 (the HEAP_007 amendment);
- `benchmarks/threaded-gc-00-baseline.md` §4.4 (the 4.9 M in-minor page faults lead);
- `plans/threaded-gc-02-bitmap-allocation.md` §10 (prefaulting deferred to this phase).

§n points into the report, P§n into this plan, 02-P§n into the phase 2 plan, M§n into the
master plan.

---

## 0. What this phase delivers, and why

Every later threaded phase (4 parallel mark, 5 concurrent mark, 6 parallel minor, 7 concurrent
tenuring) needs the same plumbing:
- a pool of GC helper threads;
- a way for the mutator to hand them work and collect results at safe points;
- a synchronous mode that runs the same work on the mutator, as the reference for counters;
- a rule that collector progress never drives a GC decision (GC_DET_001);
- a TSan-tested protocol;
- the measurement split that "GC time = sum of pauses" stops covering: helper CPU, mutator stall
  and interference.

This phase builds that plumbing and proves it on work that **touches no HPointer**: page-level
housekeeping of old-gen memory. A defect there costs time or RSS. It can corrupt the heap in one
way only, a discard of memory the mutator owns, and P§3.6 closes that by construction and
checks it with validators.

### 0.1 The first users are real wins, not placeholders (measured 2026-09-25)

Two single runs of `eco-optTG2pt` (phase-timer build of the shipped TG2 runtime). Both produced
byte-identical `out.mlir` and identical GC counters (1,924 minors, 7 majors, promoted
675,767,781; every major event log row identical in `before/after/garbage/recovered/promoted/
markunits`):

| | TG2 as shipped (`decommit_on_oldgen_release` = true) | decommit off (`ECO_HEAP_CONFIG`) | Δ |
|---|---|---|---|
| page faults inside minors | **4,758,731** | 2,204,571 | **−2,554,160 (−54 %)** |
| process minor faults (`time -v`) | 4,960,692 | 2,306,963 | −2,653,729 |
| minor GC time | 56.78 s | 50.99 s | **−5.79 s** |
| major GC time | 13.12 s | 11.95 s | −1.17 s |
| major-event-log sweep column (sum of 7) | 889 ms | 343 ms | −546 ms (the inline `madvise`) |
| all pauses | 70.14 s | 63.16 s | **−6.98 s** |
| minor-only p99 / max | 146.5 / 191.5 ms | 139.1 / 178.1 ms | −7 / −13 ms |
| promotion allocator | 17.6 ns/call | 14.8 ns/call | faults were charged here |
| system time | 7.44 s | 3.25 s | −4.19 s |
| max RSS | 9,617,520 kB | 9,635,000 kB | **+17 MB** |
| wall (single runs) | 185.7 s | 176.9 s | −8.8 s |

What the data says:

1. **Half of the in-minor faults are refaults of memory the GC itself discarded.** The majors
   release ~12.3 GB of all-dead blocks (`recovered` column, summed), all through
   `reclaimAllDeadBlocksFromMeta` → `releaseOldGenBlock` → `madvise(MADV_DONTNEED)`. The minors
   that follow reacquire those same extents one 512 KiB block at a time, and every 4 KiB page
   faults again and is zero-filled. **One refault costs ≈ 2.3 µs of minor pause** (5.79 s /
   2.55 M).
2. **The other half (2.20 M ≈ 8.6 GB) are first touches of freshly committed memory.** That is
   the old-gen commit high-water mark (8,790 MB). It is irreducible by any decommit policy, but it
   can be taken **off the pause**: a helper can populate the pages before the mutator reaches them.
3. **Deferring the decommit costs almost no RSS**, because the RSS peak is reached *before* the
   major that releases the blocks (+17 MB with decommit completely off).
4. The `madvise` itself costs ~0.55 s inside major pauses, up to ~250 ms in one pause (the 90 s
   major: 369 → 115 ms sweep).

So this phase ships three things:

| # | Deliverable | Benefit | Where the benefit comes from |
|---|---|---|---|
| **INFRA** | the pool, the handshake, the three modes, GC_DET_001, TSan harness, measurement split | the foundation of phases 4–7 | — |
| **U1** | **deferred decommit**: a released extent is discarded only after it has stayed unused for `decommit_delay_syncs` pause ends. A reuse before then cancels the discard. Due discards run as a helper job. | ≈ −5.8 s minor pause (fewer refaults), ≈ −0.55 s major pause (no inline `madvise`) | the **delay** is a physical-memory policy (it works in sync mode too); the **thread** only moves the `madvise` off the pause |
| **U2** | **commit-ahead**: the mutator keeps a window of `commit_ahead_bytes` above the old-gen bump pointer committed, and a helper populates it (`MADV_POPULATE_WRITE`) before promotion reaches it | up to ≈ −5 s minor pause (2.2 M first-touch faults leave the pause); **unproven**, see P§1 rule 6 | the **thread** (in sync mode the same populate runs inside the pause and saves nothing) |

**Neither user changes a GC decision.** Which extent `acquireOldGenBlock` returns, every
counter, `old_gen_committed`, `old_gen_in_use_bytes_` and every trigger input are bit-identical
in all modes and to `eco-optTG2`. Only the **physical** state of pages changes: whether a page is
resident, and when it faulted. That is what makes these users safe first tenants of GC_DET_001.

| # | Deliverable (detailed) |
|---|---|
| D1 | Config and mode plumbing: `HeapConfig::gc_thread_mode` / `gc_helper_threads` / `gc_helper_cpu` / `decommit_delay_syncs` / `decommit_pending_max_bytes` / `commit_ahead_bytes`; the `ECO_GC_THREAD` and `ECO_GC_HELPER_JITTER_US` environment variables |
| D2 | `GCHelperPool` (standalone: `std` plus `<pthread.h>`/`<time.h>`): lazily started workers, the job state machine, post/wait/drain, CPU accounting, jitter injection |
| D3 | The pause-end **sync point**: one hook at the end of the outermost minor/major pause |
| D4 | `PageWork` (standalone): the per-extent state machine of U1 and U2 over an injectable `PageOps`, with unit tests |
| D5 | U1 wired into `Allocator` (release, reuse, sync point, reset, exit) |
| D6 | U2 wired into `Allocator` (commit-ahead window, bump-path commit, populate jobs) |
| D7 | Validators V1–V6 |
| D8 | The TSan harness (`test/gc-helper-tsan/`, built with g++), including a real-`madvise` end-to-end protocol test |
| D9 | Measurement: the "Old-gen page supply" and "GC helper threads" banner blocks, stall events, the event-log `stall`/`job` rows, `process CPU` for interference |
| D10 | Experiments E1 (delay), E2 (window), E3 (sync vs concurrent, pinning); gates in all modes; default flip; invariants (HEAP_007 amended, GC_DET_001, HEAP_058–060); docs; tracking row |

**Out of scope:** any HPointer-touching helper work (mark, copy, sweep: phases 4–7); an async
doorbell (§3.2); THP policy for old-gen blocks; the per-thread promotion cursors (phase 6);
prefaulting the nursery (the nursery's retained commit is already resident after the first
cycles, HEAP_042).

---

## 1. Ground rules for this phase

1. **No GC decision may change, in any mode.** Counters are **bit-identical** across
   `ECO_GC_THREAD=0/1/2`, across 2 + jitter, and against the same-session `eco-optTG2` control:
   minors, majors, the full major event log, promoted objects/MiB, copied-in-nursery,
   per-tag retention, old-gen in-use peak, commit high-water. `out.mlir` is byte-identical.
   **Allowed to change, and reported:** page faults, system time, max RSS, pause times, wall.
   (This is stricter than M§2's "policy phases re-baseline": U1 and U2 are physical-memory policy,
   not GC policy.)
2. **Mode 0 is today's path, byte for byte, including physical behaviour** (the escape hatch,
   §10.6). With `gc_thread_mode == 0`, no pool thread is created, no `PageWork` exists, and
   `releaseOldGenBlock` runs the inline `madvise` exactly as now. The mode-0 banner is identical
   to `eco-optTG2`'s except for the additive "Old-gen page supply" block (P§3.9).
3. **GC_DET_001 — collector progress is never a decision input** (§10.1). Concretely, in this
   phase:
   - no code outside `GCHelperPool`/`PageWork` may read a job's state;
   - `PageWork` reads a job's state only to **wait** for it (a stall), never to choose
     between two outcomes;
   - which extents are discarded, and when they are *posted*, depends only on the sync-point
     count, release order and configuration, never on how far the helper got.
   So mode 1 (sync) and mode 2 (concurrent) leave **the same physical state at every mutator
   observation point**: at every reuse of an extent and every release. The only exception is a
   populate job still in flight, which is content-neutral (P§3.7).
4. **No fence, atomic or lock on any mutator fast path** (§3.4). Every pool interaction happens
   at a slow path the mutator already takes: a pause end, `acquireOldGenBlock`,
   `releaseOldGenBlock` (all already under `Allocator::thread_mutex_`). The compiled bump path,
   `allocate`, the cursor and the promotion hit path are untouched. Check this in the diff.
5. **The environment is a program input** (baseline §1: object counts moved between sessions
   because the compiler reads its environment into Elm values). Every self-compile arm of this
   phase, **including the control**, sets `ECO_GC_THREAD` to a **one-character** value (`0`, `1`
   or `2`), and sets `ECO_GC_HELPER_JITTER_US` to the **same-length** value in every arm that uses
   it. A counter diff between arms whose environments differ in length is not evidence.
6. **The W3/W4 rule, thread edition:** "moving work to a helper" is a bet that the mutator stops
   paying for it. U2 especially can lose: a populate racing the mutator's own first touch serialises
   on the page-table lock, and zero-filling pages on another core may evict the mutator's L3 lines
   (§3.1: 16 MiB shared L3). **Measure in-minor faults, minor time and interference; never assume.**
7. **Assert what you rely on** (M§2). The one catastrophic failure is a `MADV_DONTNEED` on an
   extent the mutator owns: silent zeroing of live objects. V1–V3 re-derive ownership at every
   sync point and every reuse in validate builds, and the TSan harness's real-`madvise` test
   (P§4 Step 8) checks it end to end.
8. **Every run has a timeout, and a hang is a failure** (§10.5). Wrap every self-compile and test
   invocation in `timeout 1200` (self-compile), `timeout 3600` (E2E, stress). An exit of 124 is a
   defect in this phase until proven otherwise.
9. **Verify the artifact, never `rc`** (M§2). `cmp` the `out.mlir` every time.
10. **Judge counters against a same-session control** (baseline §1): `eco-optTG2` run once per
    session with `ECO_GC_THREAD=0` set.

---

## 2. Verified facts the steps rely on

Verified 2026-09-25 against `keep-TG2`. **Re-verify each before editing.** Line numbers are in
`runtime/src/allocator/` unless a path is given.

| # | Fact | Where |
|---|---|---|
| F1 | `Allocator::acquireOldGenBlock` holds `thread_mutex_` (recursive). It first scans `old_gen_free_blocks_` **first-fit, in vector order** (page requests skip `heap_base` and non-page-multiple extents), swap-removes the hit, calls `madvise(block, block_size, MADV_WILLNEED)` and adds to `old_gen_in_use_bytes_`. Otherwise it **bumps**: `block_base = heap_base + old_gen_committed`, `platform::commitAt(block_base, size)` (an `mmap MAP_FIXED` RW), then advances `old_gen_committed`. | `Allocator.cpp:634-729` (reuse `:657-686`, WILLNEED `:673`, commit `:701`) |
| F2 | `Allocator::releaseOldGenBlock` holds `thread_mutex_`. When `config_.decommit_on_oldgen_release`, it calls `madvise(block, size, MADV_DONTNEED)` **inline**, then `old_gen_free_blocks_.emplace_back(block, size)` and debits `old_gen_in_use_bytes_`. `old_gen_committed` is never decremented. | `Allocator.cpp:734-766` (`madvise` `:742`) |
| F3 | Release callers: `OldGenSpace::releaseBlockToAllocator` (`:3865`, calls F2 at `:3970`) from `reclaimAllDeadBlocksFromMeta` (`:4043`, the post-mark all-dead reclaim, inside the major pause) and `maybeShrinkCapacity` (`:3571`, heavy pass in the major, light pass from `onSweepComplete`, **which can run from a mutator-side old-gen allocation outside any pause**); `releaseUnassignedBlockToAllocator` (`:4004`, calls F2 at `:4021`). | `OldGenSpace.cpp` |
| F4 | Acquire callers: `ensureBagPageAvailable` (`:728`, when `unassigned_blocks_` is empty, one page at a time; feeds `startVirginBlock` `:746` in bitmap mode), `populateFromBlock`/`allocateFromBagPage`-era paths (`:1609`, `:1697`, `:4480`, flag-off code), `allocateLargeBlock` (`:1887`, step 3), `Allocator::ensureOldGenCapacityFor` (`Allocator.cpp:768`, post-major growth into `unassigned_blocks_`). Several run **outside** a pause (mutator-side large and old-gen allocation, `ThreadLocalHeap.cpp:338-400`). | as listed |
| F5 | `old_gen_free_blocks_` is **Allocator-global** (all heaps) and protected by `thread_mutex_`. `reset()` clears it (`Allocator.cpp:881`) after destroying all heaps. | `Allocator.hpp:~336`, `Allocator.cpp:850-900` |
| F6 | Nothing reads physical residency or RSS to make a decision: no `ru_maxrss`, `/proc/self/statm` or `/proc/self/status` read anywhere in `runtime/src`, `elm-kernel-cpp/src` or `eco-kernel-cpp/src` (grep, 2026-09-25). Triggers read `old_gen_in_use_bytes_` / committed accounting only. | grep |
| F7 | Pause structure: `ThreadLocalHeap::minorGC` (`ThreadLocalHeap.cpp:572`) walks the stack, runs `NurserySpace::minorGC`, then evaluates the major trigger and may call `majorGC` **nested**. `majorGC` (`:611`) is also called directly from `collectAtSafepoint` (`:528`), from allocation failure (`:361`, `:389`) and from forced entry points (`Allocator.cpp:439`, `RuntimeExports.cpp:4272`, `eco_entry.cpp:133/202`). The phase-timer `GCPauseScope` (`:535`) already brackets the outermost call with `gc_depth_`, **but only under `ENABLE_GC_PHASE_TIMERS`** (`ThreadLocalHeap.hpp:257`). | as listed |
| F8 | The in-minor fault count comes from `getrusage(RUSAGE_THREAD)` around `NurserySpace::minorGC` (`NurserySpace.cpp:487`, `:1092`) into `MinorGCRecord::minflt` (`GCStats.hpp:124`), printed as "page faults inside minors" (`GCStats.cpp:2333`). | as listed |
| F9 | The pause log: `GCPhaseTotals` (`GCStats.hpp:183`) keeps `pause_events` and `pause_count_by_kind[3]` (kinds 0 minor-only, 1 minor+major, 2 major-only; `GCStats.cpp:2040`). Percentiles and MMU are computed at print time (`printThreadedGcBlocks`, `GCStats.cpp:2199`). **All pause instruments are compiled only with `ENABLE_GC_PHASE_TIMERS`** (`CMakeLists.txt:123`), default OFF (T01). | as listed |
| F10 | Stats reach the banner through `Allocator::getCombinedStats` (`Allocator.cpp:959`), which merges per-heap `GCStats` under `thread_mutex_`. It is called from the atexit handler **and from a signal handler** (`eco_entry.cpp` `printGCStatsOnce`, `signalPrintStats`): anything it reads from the pool must be lock-free. | `eco_entry.cpp:~150-230` |
| F11 | Existing service threads (`TimerService`, `WaitService`, `HttpService`) use a **leaky heap singleton with a detached `std::thread`**, never joined (`platform/TimerService.cpp:6-23`). On Win64 the entry point hard-exits with `TerminateProcess` because parked detached threads deadlock the CRT teardown (`eco_entry.cpp:~340`). A GC pool built the same way inherits that handling. | as listed |
| F12 | `Process.cpp` (`eco-kernel-cpp/src/eco-kernel/Process.cpp:70, 124`) `fork()`s and the child only `execvp`s or `_exit`s. It never allocates, so helper threads missing in the child are harmless. | as listed |
| F13 | HeapConfig plumbing: compiled defaults are `constexpr` in `AllocatorCommon.hpp` (e.g. `DECOMMIT_ON_OLDGEN_RELEASE` `:176`, field `:520`), `HeapConfig::validate` at `:653`. JSON keys: the known-key list (`HeapConfigJson.cpp:160`), plus `parseBool`/`parseU32` (`:126`)/`parseByteSize` (`:33`) blocks. `ECO_HEAP_CONFIG` is applied in `Allocator::initialize` (`:228`). **Unit tests do not see `ECO_HEAP_CONFIG` in the old gen** (`initAllocator` → `reset` installs the raw config; memory `unit-tests-ignore-heap-config-env`): tests set fields directly. | as listed |
| F14 | Allocator sources are listed **explicitly in four places**: `CMakeLists.txt:~400` (`ecor`), `runtime/src/codegen/CMakeLists.txt` `ecoc` (`~462`), `EcoRunner` (`~582`), `EcoRuntimeStatic` (`:670`). A new `.cpp` must be added to all four. Unit tests are listed in `test/CMakeLists.txt:~111` and registered in `test/main.cpp` (`#include` at `:26`, `oldGenTests.add(...)` at `:652`). | as listed |
| F15 | Toolchain: `clang++` 14.0.6 **has no TSan runtime** (`libclang_rt.tsan-x86_64.a` missing: link error). **`g++` 12.2 with `-fsanitize=thread` works** (`libtsan.so.2`; a deliberate race was reported, 2026-09-25). | scratchpad probe |
| F16 | Machine: kernel 6.12 (`MADV_POPULATE_WRITE`, Linux ≥ 5.14, is available), THP `always`, 24 cores, no SMT, 16 MiB shared L3, 15 GB RAM. `OS_PAGE_SIZE` 4 KiB, `ALLOC_BUFFER_SIZE` 512 KiB (`AllocatorCommon.hpp:91`). | `uname`, sysfs |
| F17 | `Allocator.cpp:44-54` stubs `madvise` to a no-op on Win64. `platform::decommit` remaps `PROT_NONE` (it is **not** what `releaseOldGenBlock` uses); `platform::resetPagesToZero` remaps RW (`PlatformVirtualMemory_posix.cpp:57-80`). | as listed |
| F18 | Reference numbers (P§0.1 runs, `eco-optTG2pt`, one run each; timed TG2 triple in `gc-opt-loop.md` TG2): wall 180.97 s, GC 67.32 s, minor 54.59 s, major 12.67 s, 7 majors, old-gen peak 8,790 MB, max RSS 9,622,612 kB. | loop entry TG2 |

---

## 3. Design

### 3.1 Threads, lifetime and the pool

`runtime/src/allocator/GCHelperPool.{hpp,cpp}`, `namespace Elm::gc`. **It includes nothing from
the allocator**: `<atomic>`, `<condition_variable>`, `<mutex>`, `<thread>`, `<vector>`,
`<cstdint>`, `<ctime>`, and `<pthread.h>` under `#ifndef _WIN32`. This keeps it compilable alone
under g++/TSan (F15) and makes "helpers never touch HPointers" a property of the include graph
(gate G10).

- **One pool per process** (M§3), a leaky singleton exactly like `TimerService` (F11):
  `static GCHelperPool& instance()`; the object is `new`'d once and never destroyed.
- **Workers start lazily** at the first `post` in Concurrent mode, `gc_helper_threads` of them
  (default 1, max 64). Each is a `std::thread`, **detached**, named `eco-gc-<i>`
  (`pthread_setname_np`, POSIX only). If `gc_helper_cpu >= 0`, worker 0 pins itself to that CPU
  (`pthread_setaffinity_np`); other workers are not pinned.
- **Test-only shutdown:** `void shutdownForTesting()` stops and joins the workers, and returns the
  pool to "not started". Production never calls it. Unit tests and the TSan harness must, so that
  TSan sees joined threads.
- The pool serves every heap. The benchmark driver's several mutators may post concurrently, so
  `post`, `wait` and `drain` are thread-safe (a pool mutex). Real Elm programs have one mutator
  (§3.1).

### 3.2 Jobs and the handshake

```cpp
namespace Elm::gc {
enum class HelperMode : uint8_t { Off = 0, Sync = 1, Concurrent = 2 };
enum class HelperClient : uint8_t { Decommit = 0, Populate = 1, Test = 2, kCount = 3 };

struct HelperJob {
    void (*run)(HelperJob*) = nullptr;        // executed by a worker, or inline in Sync
    HelperClient client = HelperClient::Test;
    // Idle -> Posted -> Running -> Done -> (owner resets to Idle before re-posting).
    std::atomic<uint32_t> state{0};
    HelperJob* next = nullptr;                // intrusive FIFO link; pool-owned while Posted
    uint64_t bytes = 0;                       // stats only
};

class GCHelperPool {
public:
    static GCHelperPool& instance();
    // First call wins; later calls with different values abort with a message
    // (a mode switch mid-process would break GC_DET_001's mode equivalence).
    void configure(HelperMode mode, unsigned threads, int pin_cpu, unsigned jitter_us);
    HelperMode mode() const;
    void post(HelperJob& job);        // job.state must be Idle
    void wait(HelperJob& job);        // returns when Done; accounts a stall if it blocked
    void drain();                     // waits for every Posted/Running job
    struct Stats { /* all std::atomic<uint64_t>, see P§3.9 */ };
    const Stats& stats() const;       // lock-free reads (signal path, F10)
    void shutdownForTesting();
};
}
```

**Protocol.**
- `post`, in **Sync** mode: set Running, run `job.run(&job)` inline on the caller, account its
  CPU to the client as *mutator-run helper work*, then set Done.
  In **Concurrent** mode: lock `m_`, set Posted, append to the FIFO, unlock, `cv_work_.notify_one()`.
- **Worker loop:** lock `m_`; wait on `cv_work_` until the FIFO is non-empty or stopping; pop;
  set Running; unlock.
  - If `jitter_us > 0`, sleep a pseudo-random `[0, jitter_us)` µs. Use a per-worker xorshift
    seeded from the worker index; this must never be read by any decision.
  - Read `CLOCK_THREAD_CPUTIME_ID`, run the job, read it again, add to the client's `cpu_ns`.
  - Lock `m_`, set Done (release), `cv_done_.notify_all()`, unlock.
- `wait`: if `state.load(acquire) == Done`, return (no stall). Otherwise take a
  `steady_clock` timestamp, lock `m_`, `cv_done_.wait(lk, [&]{ return state == Done; })`, and
  account the stall (count, total ns, max ns).
- **Publication (§3.4):** everything the mutator wrote before `post` is visible to the worker
  through the `m_` unlock/lock pair. Everything the worker wrote is visible to the mutator after
  `wait` (or after an acquire load that sees Done). No fences are needed elsewhere.
- **Why a mutex and condition variable, not a lock-free queue:** the post rate is at most a few
  jobs per pause, about 2,000 pauses per self-compile. The mutex is uncontended in practice and
  TSan understands it. Phase 4 adds Chase–Lev deques for *intra*-job work. This FIFO carries only
  whole jobs.
- **Asserts (always on, slow path only):** `post` requires Idle; the worker requires Posted; the
  owner resets Done to Idle before reuse; `drain` leaves the FIFO empty and nothing Running.

### 3.3 Modes

| `gc_thread_mode` / `ECO_GC_THREAD` | Meaning |
|---|---|
| `0` (Off) | Today's code. No pool, no `PageWork`, inline `madvise` in `releaseOldGenBlock`, no commit-ahead. |
| `1` (Sync) | `PageWork` is active. Every job runs **inline at its post point** on the mutator. This is the reference for counters and physical state (§10.2). |
| `2` (Concurrent) | Like 1, but jobs run on the pool; the mutator waits only where a job's result is required (P§3.6). |

**Equivalence argument (the gate G8 checks it).** Take a job posted at sync point *s*:
- In mode 1 it is complete when `post` returns.
- In mode 2 it may still be running, but every mutator action that depends on its effect waits
  for it first:
  - reusing an extent under a posted discard waits;
  - releasing an extent under an in-flight populate waits.
- No decision reads the job. So the sequence of decisions is identical in both modes, and the
  physical state at every such mutator action is identical too.
- The only permitted difference is *which thread* takes a first-touch fault on a page covered
  by an in-flight populate. That changes `minflt` and time, and nothing else.

`ECO_GC_THREAD` accepts exactly `0`, `1` or `2` (rule 5). Anything else aborts at
`initialize` with `ECO_GC_THREAD must be 0, 1 or 2`. It is applied **after** `ECO_HEAP_CONFIG`
and overrides it.

### 3.4 GC_DET_001 in code, and the jitter switch

- `HelperJob::state` is private to `GCHelperPool` and `PageWork`. G10 greps for `.state` reads
  outside those two files.
- `ECO_GC_HELPER_JITTER_US=<n>` (n written as a fixed-width 4-digit number, e.g. `0000` or
  `0500`, rule 5) makes every worker sleep a random `[0, n)` µs before each job. **A run with
  jitter must reproduce the mode-1 counters exactly.** A divergence means a timing dependence has
  leaked into a decision. It is honoured in every build (cost: one relaxed load per job).

### 3.5 The sync point

One hook, at the end of the **outermost** pause on a heap:

- `ThreadLocalHeap` gets an always-on `int pause_depth_ = 0;` (F7: `gc_depth_` exists only with
  phase timers; do not reuse it).
- A RAII `PauseEndHook` is declared at the top of `minorGC()` and `majorGC()`, **after**
  `GCPauseScope` so that it destructs *before* it. Sync-mode work is then inside the pause
  bracket, which is correct, because in Sync mode it *is* pause work.
  - The constructor does `++pause_depth_`.
  - The destructor: `if (--pause_depth_ == 0) parent_->onGCPauseEnd(*this);`.
- `Allocator::onGCPauseEnd(ThreadLocalHeap&)`:
  - returns immediately when `page_work_ == nullptr` (mode 0: one predictable branch per pause);
  - otherwise locks `thread_mutex_` and calls `page_work_->syncPoint(...)` (P§3.6, P§3.7).
- The sync-point **epoch** is `Allocator::sync_epoch_` (uint64), incremented once per
  `onGCPauseEnd` call, before `syncPoint` runs. With one mutator it is exactly "pauses so far",
  deterministic. With several mutators (benchmark driver only) it interleaves
  nondeterministically, which is acceptable because that driver is not a counter gate.

### 3.6 U1 — deferred decommit

**State per released extent** (keyed by start address; extents in `old_gen_free_blocks_` never
overlap):

```
            release (decommit on)                 syncPoint: age > D, or over the byte cap
  (in use) ───────────────────────► Pending ──────────────────────────────────────► Posted(job j)
                                       │ reuse by acquire                              │ job done
                                       ▼                                               ▼
                                   Cancelled (no madvise; pages stay resident)     Discarded
                                                                            reuse waits for j
```

`PageWork` holds, under `thread_mutex_`:
- `pending_`: `std::unordered_map<char*, Pending{size, epoch}>`, plus a FIFO
  `std::deque<char*> pending_order_` (release order; entries whose key is gone were cancelled and
  are skipped lazily);
- `pending_bytes_`;
- `posted_discard_`: `std::unordered_map<char*, uint8_t slot>`, which maps an extent to the
  in-flight job slot that will discard it;
- a fixed ring of `kJobSlots = 8` `PageJob` objects:
  `struct PageJob : gc::HelperJob { Kind kind; std::vector<Extent> extents; char* lo; char* hi; }`.
  Their vectors keep their capacity, so there is no per-post allocation after warm-up.

**Operations** (all called with `thread_mutex_` held):

1. `onRelease(p, n)`, from `releaseOldGenBlock` in modes 1/2, **replacing** the inline
   `madvise`:
   - first `awaitPopulateOverlapping(p, n)` (P§3.7);
   - then, if `decommit_on_oldgen_release`, insert `pending_[p] = {n, sync_epoch_}`, push `p` on
     `pending_order_`, and add `n` to `pending_bytes_`.
   - `old_gen_free_blocks_.emplace_back` and the in-use debit stay exactly where they are, so
     the decision state is unchanged.
2. `onReuse(p, n)`, from the reuse branch of `acquireOldGenBlock`, after the hit is chosen and
   **before** `MADV_WILLNEED`:
   - if `p` is in `pending_`: erase it, debit `pending_bytes_`, and count
     `decommit_cancelled_bytes`. The pages are still resident, so no refault;
   - else if `p` is in `posted_discard_`: `pool.wait(job)` (counted as a stall), reap the job,
     and count `reuse_after_discard_bytes`;
   - else count `reuse_after_discard_bytes` (discarded earlier, or never pending).
3. `syncPoint(epoch)`:
   - **(a) Reap** every slot whose job is Done: erase its extents from `posted_discard_` (or its
     range from the populate list) and reset it to Idle. A non-Done slot stays. Reaping is
     bookkeeping only and decides nothing.
   - **(b) Age.** Walk `pending_order_` from the front. For each live key with
     `epoch − entry.epoch > decommit_delay_syncs`, move it into the batch. Also move entries from
     the front while `pending_bytes_ > decommit_pending_max_bytes` (if the cap is non-zero). Stop
     at the first live entry that meets neither condition. Releases are in epoch order, so the
     front is always the oldest.
   - **(c) Post.** If the batch is non-empty: take a free slot (if none is free,
     `pool.wait` the oldest slot, reap it, and count `slot_full_waits`), fill
     `kind = Discard, extents = batch`, insert each extent in `posted_discard_`, and
     `pool.post(slot)`. The job body is: for each extent, `ops.discard(p, n)`
     (`madvise MADV_DONTNEED`), and accumulate bytes.
   - **(d)** U2's top-up (P§3.7).
4. `drainAll()`, from `Allocator::reset`, from the atexit stats print, and from
   `~Allocator`: `pool.drain()`, reap everything, **and then discard every still-Pending
   extent synchronously** (reset: the next heap starts clean; exit: irrelevant but
   deterministic), and clear all maps.

**`decommit_delay_syncs = D` semantics.** An extent released during pause *k* (epoch at release
= *k*−1, since the epoch increments at the end of that pause) is posted at the end of pause
*k* + D:
- **D = 0** discards at the end of the releasing pause. That is today's behaviour, minus
  same-pause reuse, and off the pause in mode 2.
- **D = ∞** is spelled as `UINT32_MAX` and never discards except under the cap. It is the
  decommit-off arm of P§0.1.

**Why posted extents stay in `old_gen_free_blocks_`.** Removing them until the discard
completes would make `acquireOldGenBlock`'s choice depend on helper progress. That breaks rule 3.
The reuse-waits rule keeps the choice and pays for a rare stall instead.

**RSS.** Pending bytes are resident but not in use. They are bounded by
`decommit_pending_max_bytes`, and reported as `pending_peak_bytes`. For 4 GB-budget programs
(M§1.3) the cap is the lever; E1 sets its default.

### 3.7 U2 — commit-ahead with populate

**State (in `Allocator`, under `thread_mutex_`):** `char* commit_ahead_end_ = nullptr`. It is
the end of the range `[heap_base + old_gen_committed, commit_ahead_end_)` that is already
mapped RW above the bump pointer. `nullptr` or `<=` the bump pointer means no window.

**At `syncPoint` (d), when `commit_ahead_bytes > 0` and populate is supported:**
1. `bump = heap_base + old_gen_committed`.
   `target = min(round_up(bump + commit_ahead_bytes, 2 MiB), heap_base + nursery_offset)`. The
   2 MiB rounding lets THP back whole granules (F16), and the window never crosses the old-gen
   cap.
2. `lo = max(commit_ahead_end_, bump)`. If `target > lo`:
   - the **mutator** maps `[lo, target)` with `platform::commitAt`;
   - on failure, stop: best effort, no decision reads it;
   - set `commit_ahead_end_ = target`;
   - post a Populate job over `[lo, target)` with the same slot discipline as U1. Its body is
     `ops.populate(lo, target − lo)`, i.e. `madvise(MADV_POPULATE_WRITE)`, and it counts
     `populated_bytes` and `populate_failures`.

**Bump path of `acquireOldGenBlock` (modes 1/2 only):** replace `commitAt(block_base, size)`
with `commitFresh(block_base, size)`:
- if `block_base + size <= commit_ahead_end_`, commit nothing and count
  `fresh_bytes_ahead_hit`;
- otherwise commit only `[max(block_base, commit_ahead_end_), block_base + size)` and count
  `fresh_bytes_ahead_miss` for that part.

**Never `commitAt` over the window.** An `mmap MAP_FIXED` over populated pages silently discards
them. That does not corrupt anything, but it is exactly the work U2 exists to avoid (trap 2).

**Safety of an in-flight populate** (why acquire does not wait for it):
- `MADV_POPULATE_WRITE` "populates page tables writable, faulting-in all pages as if written,
  but avoids the actual memory access". It never changes the contents of a present page.
- If the mutator faults a page first, the kernel serialises the two faults on the page-table
  lock, and one of them installs the page.
- The mutator's data is never lost, so the mutator may write into a block under an in-flight
  populate.

**The one ordering that must be prevented** is a populate still running over an extent that has
since been acquired, used and **released**. A discard of that extent racing the populate would
leave it resident again, which is RSS only, but confusing. `onRelease` therefore first runs
`awaitPopulateOverlapping(p, n)`: it waits for any in-flight Populate slot whose `[lo, hi)`
overlaps `[p, p+n)`. There are at most 8 slots, so the check is a linear scan.

**Availability.** `PageWork` probes once at construction by calling `ops.populate` on a
one-page scratch `mmap`. If it fails (`EINVAL` on kernels < 5.14; Win64, where the op is a stub
returning false):
- set `populate_supported_ = false`;
- print `commit-ahead: unsupported (no MADV_POPULATE_WRITE)` in the helper banner block;
- never open a window.
- **Do not fall back to touching pages:** a write races the mutator, and a read maps only the
  shared zero page.

**Reset:** `Allocator::reset` sets `commit_ahead_end_ = nullptr` after `drainAll`. The next
acquire's `commitAt(heap_base + 0, …)` remaps fresh pages. Any residue above it is harmless and
is remapped when reached.

### 3.8 Where the pool is configured

`Allocator::initialize` does the following, after `applyHeapConfigFromEnv` and the
`ECO_GC_THREAD` / `ECO_GC_HELPER_JITTER_US` overrides and `validate()`:
- if `gc_thread_mode != 0`: call
  `gc::GCHelperPool::instance().configure(mode, gc_helper_threads, gc_helper_cpu, jitter)`;
- create `page_work_ = std::make_unique<PageWork>(realPageOps(), config_, pool)`.

`Allocator::reset(new_config)`:
- runs `page_work_->drainAll()` **before** `old_gen_free_blocks_.clear()`;
- then recreates `page_work_` from the new config (or destroys it if the mode is 0);
- the pool's first `configure` wins (F13's test caveat). Unit tests that need different modes
  use the test-only `GCHelperPool::reconfigureForTesting` (Step 2), which is legal only after
  `shutdownForTesting`.

### 3.9 Measurement additions

**1. "Old-gen page supply (threaded-gc-03)" block.** Printed in every stats build and every
mode. It is additive (new lines only, trap 7) and uses counters from `Allocator`, all updated
under `thread_mutex_`:

| line | meaning |
|---|---|
| `released` | bytes / extents through `releaseOldGenBlock` |
| `discarded` | bytes `MADV_DONTNEED`ed (mode 0: inline; modes 1/2: by jobs), and the `madvise` ns (mode 0: timed inline; modes 1/2: job CPU) |
| `reuse: resident` | reused bytes whose discard was cancelled (U1's win) |
| `reuse: after discard` | reused bytes that were discarded (they will refault) |
| `fresh commit` | bump bytes, split into `ahead-hit` / `ahead-miss` (U2's coverage) |
| `pending peak` | max `pending_bytes_` |

**2. "GC helper threads (threaded-gc-03)" block**, printed only when `gc_thread_mode != 0`:
- the mode, thread count, pin and jitter;
- per client (Decommit, Populate): jobs, bytes, helper CPU, and mutator-run CPU (sync mode);
- **stalls**: count, total, max; how many of them were outside a pause; and `slot_full_waits`;
- `process CPU` = `CLOCK_PROCESS_CPUTIME_ID` at print;
- `non-helper CPU` = process CPU − the sum of helper CPU. **Interference** (§10.3) is
  `non-helper CPU(mode 2) − non-helper CPU(mode 1)`, computed across runs in the analysis, not in
  the banner.

**3. Stall events** (phase-timer builds only, F9):
- a stall **outside** a pause is appended to a new `GCPhaseTotals::stall_events` vector (not to
  `pause_events`, so that existing pause lines do not change, trap 7);
- the pause block gains one new line, `MMU incl. helper stalls`, at the same windows as the
  existing MMU line;
- a stall **inside** a pause is already pause time and is not double-counted;
- the event log (`ECO_GC_EVENT_LOG`) gains row kinds `stall` (start, dur, client) and `job`
  (client, post_ns, start_ns, end_ns, bytes). `benchmarks/gc-event-log-summary.py` learns to
  skip unknown kinds and to summarise these two.

**How a stall knows whether it is inside a pause.** `PageWork` is Allocator-level and does not
know the heap. So `Allocator` passes it a `bool in_pause` computed from
`tl_heap_ && tl_heap_->pause_depth_ > 0` at each `onReuse`/`onRelease` call.

### 3.10 What does not change

- **Hot paths untouched:** compiled bump; `allocate`; the bitmap cursor; the promotion hit path;
  the mark loop.
- **In `OldGenSpace.cpp`: zero edits** (all hooks are in `Allocator.cpp` and
  `ThreadLocalHeap.cpp`), so the alignment trap (01-P§9a.13) cannot fire.
- `old_gen_free_blocks_` order and every accounting field.
- The `WILLNEED` madvise on reuse (a no-op for anonymous memory, but part of mode 0's byte
  identity).

---

## 4. Steps

Do the steps in order. Every step ends with `cmake --build build --target check` green, and the
listed checkpoint.

**Checkpoint C[m…]** is one self-compile per listed mode, using the loop body of
`gc-opt-loop.md` §2 with `timeout 1200`, `ECO_GC_THREAD=<m>` and the lowered candidate
`eco-optTG3-cN`. **Pass** requires all of:
- `cmp` of `out.mlir` with `ecoghash.mlir` succeeds;
- the counter lines (`Minor GC cycles`, `Major GC cycles`, `totals: promoted`, `allocated`,
  `copied`, per-tag retention) are identical to the same-session control `eco-optTG2`
  (`ECO_GC_THREAD=0`);
- the Major GC Event Log rows are identical in every column except the times.

**Before you start:**
- `benchmarks/lss-loop-snap.sh verify keep-TG2`.
- Take the snapshot `try-TG3-pre`.
- Recreate the session scripts in the scratchpad from 01-P§5 (`run1.sh`, `counters.sh`,
  `checkpoint.sh`); add the `ECO_GC_THREAD` export and the `timeout` wrapper.
- Run the control `eco-optTG2` once with `ECO_GC_THREAD=0`.
- The phase-timer reference `eco-optTG2pt` already exists (P§0.1 used it).

### Step 0 — record the target measurement (no code)

1. Copy P§0.1's two runs into the phase log (`benchmarks/gc-opt-loop.md`, a new entry
   **TG3-0 (diagnostic)**). Include the commands, and note that the decommit-off arm used
   `ECO_HEAP_CONFIG` and is diagnostic only.
2. **Decision recorded here:** U1 and U2 both proceed.
   - U1's ceiling is the decommit-off arm (−5.8 s minor, −1.2 s major).
   - U2's ceiling is the 2.20 M residual faults (≈ 5 s at 2.3 µs each), under rule 6.
   - If a future re-measure shows the residual below 0.5 M faults, skip Step 7 (U2) and record
     why.

### Step 1 — D1: configuration and mode plumbing

**Files:** `AllocatorCommon.hpp`, `HeapConfigJson.cpp`, `HeapConfigJson.hpp` (key comment),
`Allocator.cpp`.

1. `AllocatorCommon.hpp`, next to `DECOMMIT_ON_OLDGEN_RELEASE`: add the following constants and
   one `HeapConfig` field for each, with a comment naming this plan:
   ```cpp
   constexpr uint32_t GC_THREAD_MODE = 0;               // 0 off, 1 sync, 2 concurrent (threaded-gc-03)
   constexpr uint32_t GC_HELPER_THREADS = 1;
   constexpr int32_t  GC_HELPER_CPU = -1;               // -1 = no pinning
   constexpr uint32_t DECOMMIT_DELAY_SYNCS = 4;         // provisional; E1 sets it (UINT32_MAX = never)
   constexpr size_t   DECOMMIT_PENDING_MAX_BYTES = 0;   // 0 = no cap; E1 sets it
   constexpr size_t   COMMIT_AHEAD_BYTES = 0;           // 0 = off; E2 sets it
   ```
   Field types: `uint32_t gc_thread_mode`, `uint32_t gc_helper_threads`,
   `int32_t gc_helper_cpu`, `uint32_t decommit_delay_syncs`,
   `size_t decommit_pending_max_bytes`, `size_t commit_ahead_bytes`.
2. `HeapConfig::validate` (`:653`) must throw `std::invalid_argument` when:
   - `gc_thread_mode > 2`;
   - `gc_helper_threads` is 0 or greater than 64;
   - `gc_helper_cpu < -1`;
   - `commit_ahead_bytes` is not a multiple of `OS_PAGE_SIZE`.
3. `HeapConfigJson.cpp`:
   - add the six keys to `kKnownKeys` (`:160`);
   - parse blocks: `parseU32` for the mode, threads and delay; `parseByteSize` for the two sizes;
   - for the cpu, a new `parseI32` modelled on `parseU32` that accepts -1.
4. `Allocator::initialize` (`:228`), after `applyHeapConfigFromEnv(config_)` and before
   `validate()`:
   - read `ECO_GC_THREAD`. It must be exactly one character in `0`–`2`; otherwise throw
     `std::invalid_argument("ECO_GC_THREAD must be 0, 1 or 2")`. Set `config_.gc_thread_mode`
     from it;
   - read `ECO_GC_HELPER_JITTER_US`: an unsigned decimal ≤ 100000, else throw; keep it in a
     new `Allocator::helper_jitter_us_`.
   - Document both variables in `HeapConfigJson.hpp`'s header comment beside `ECO_HEAP_CONFIG`.
5. **Unit test** `testHelperConfigValidation` (new file `test/allocator/GCHelperTest.cpp`,
   registered per F14):
   - the JSON round-trips all six keys;
   - `validate` rejects each bad value above.
6. **Checkpoint C[0]** (nothing reads the fields yet).

### Step 2 — D2: `GCHelperPool` (standalone)

**Files:** new `GCHelperPool.hpp/.cpp`; add the `.cpp` to all four source lists (F14); new
tests in `GCHelperTest.cpp`.

1. Implement P§3.1–P§3.4 exactly. `Stats` holds `std::atomic<uint64_t>` fields:
   - per client: `jobs`, `bytes`, `cpu_ns` (worker-run), `inline_cpu_ns` (Sync mode);
   - `stall_count`, `stall_ns`, `stall_max_ns`, `stall_outside_pause`;
   - `posts`.
   All are updated with `fetch_add(relaxed)`, and `stall_max_ns` with a CAS loop. Readers use
   relaxed loads, so the signal path is safe (F10).
2. `wait(job, bool in_pause)` takes the in-pause flag for `stall_outside_pause`. Also keep
   `last_stall_start_ns_`/`last_stall_ns_` for the caller to log (P§3.9 item 3).
3. CPU time helper: `static uint64_t threadCpuNs()` uses `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`
   on POSIX and `GetThreadTimes` on Win64 (100 ns units × 100).
4. Test-only API:
   - `shutdownForTesting()`: set `stopping_`, `notify_all`, join workers (keep their
     `std::thread` objects in a vector *before* detaching; in production detach after start,
     under a `detach_workers_` flag that tests clear);
   - `reconfigureForTesting(...)`: legal only when no workers are running.
5. **Unit tests** (each ends with `shutdownForTesting()`):
   - `testHelperPoolSyncRunsInline`: in Sync mode, `post` runs the job on the caller thread
     (compare `std::this_thread::get_id()` recorded by the job) and it is Done on return.
   - `testHelperPoolConcurrentRunsOnWorker`: the job records a different thread id; `wait`
     returns Done; `stats().jobs` is 1.
   - `testHelperPoolFifoAndDrain`: post 1,000 jobs that append their index to a vector (under the
     job's own mutex); `drain()`; the vector is 0..999 in order with 1 worker, and a permutation
     with 4 workers.
   - `testHelperPoolStallAccounting`: a job that spins 20 ms; `wait` immediately. `stall_count`
     becomes 1 and `stall_ns` is ≥ 15 ms. Waiting on an already Done job adds no stall.
   - `testHelperPoolJitterDoesNotReorderOneWorker`: jitter 500 µs, 1 worker, 200 jobs: FIFO
     order holds.
   - `testHelperPoolStateMachineAsserts`: run in a forked child (the suite's isolation helper,
     `test/IsolatedTestRunner.hpp`); `post` of a job that is not Idle must abort.
6. **Checkpoint C[0]** (the pool is linked but never configured).

### Step 3 — D3: the pause-end sync point and the stats plumbing

**Files:** `ThreadLocalHeap.hpp/.cpp`, `Allocator.hpp/.cpp`, `GCStats.hpp/.cpp`.

1. `ThreadLocalHeap`: add `int pause_depth_ = 0;`, a public `bool inPause() const`, and the
   `PauseEndHook` RAII from P§3.5 in `minorGC()` and `majorGC()`, declared after `GCPauseScope`.
2. `Allocator`:
   - add `uint64_t sync_epoch_ = 0;` and `void onGCPauseEnd(ThreadLocalHeap&);`;
   - its body in this step is `if (!page_work_) return; std::lock_guard lk(thread_mutex_);
     ++sync_epoch_;`. The `PageWork` call comes in Step 5.
   - add a forward-declared `std::unique_ptr<PageWork> page_work_;` (null in this step).
3. `GCStats`: add `struct PageSupplyStats` and `struct HelperStatsSnapshot` (plain `uint64_t`
   fields mirroring P§3.9; a `mode` byte; `any()`), with `combine` (sum; max for peaks) and
   `reset`. `Allocator::getCombinedStats` fills both from the live allocator and pool,
   **after** the per-heap merge, like `oldgen_inuse_peak_bytes`.
4. `GCStats::print`:
   - add `printPageSupplyBlock()` after `printBitmapAllocBlock()`, always in stats builds;
   - add `printHelperBlock()`, only when `helper.mode != 0`.
5. `releaseOldGenBlock` (mode 0 path, still the only path): time the inline `madvise` with
   `GC_STATS_TIMER_START`, and count `released`/`discarded` bytes and ns into
   `page_supply_`. `acquireOldGenBlock`: count `reuse_after_discard` (every reuse in mode 0 is
   after a discard when the decommit flag is on; otherwise count it as `reuse: resident`) and
   `fresh commit` bytes (all `ahead-miss` in mode 0).
6. **Checkpoint C[0,1,2].**
   - Modes 1/2 still do nothing: `page_work_` is null in all modes because Step 5 creates it.
     So this checks that the hook costs nothing and changes nothing.
   - The new banner block must show `released` ≈ the major event log's `recovered` sum
     (≈ 12.3 GB).
   - `discarded` must equal `released`, since decommit is on.

### Step 4 — D4: `PageWork` (standalone) and its tests

**Files:** new `PageWork.hpp/.cpp` (namespace `Elm::gc`; it includes only `GCHelperPool.hpp`
and `std`); add the `.cpp` to all four lists; tests in `GCHelperTest.cpp`.

1. Types:
   ```cpp
   struct PageOps {
       bool (*discard)(void* ctx, char* p, size_t n);    // MADV_DONTNEED
       bool (*populate)(void* ctx, char* p, size_t n);   // MADV_POPULATE_WRITE
       bool (*commit)(void* ctx, char* p, size_t n);     // platform::commitAt
       void* ctx;
   };
   struct PageWorkConfig { bool decommit; uint32_t delay; size_t pending_cap;
                           size_t ahead_bytes; };
   struct PageWorkCounters { /* the U1/U2 lines of P§3.9 block 1 and 2 */ };
   class PageWork {
   public:
       PageWork(PageOps, PageWorkConfig, GCHelperPool&);
       void onRelease(char* p, size_t n, bool in_pause);
       void onReuse(char* p, size_t n, bool in_pause);
       // Returns the byte count the caller must still commitAt, starting at
       // `*commit_from` (P§3.7 bump path).
       size_t onFreshBump(char* p, size_t n, char** commit_from);
       void syncPoint(uint64_t epoch, char* bump, char* cap_end);
       void drainAll();
       const PageWorkCounters& counters() const;
       // Validate builds (V1-V3): state queries, never called by policy code.
       bool isPendingOrPosted(char* p) const;
       void forEachTracked(void (*f)(void*, char*, size_t, int state), void* ctx) const;
   };
   ```
   The "not thread-safe; caller holds `thread_mutex_`" contract goes in the header comment.
2. Implement P§3.6 and P§3.7 exactly as written.
   - Every `wait` goes through one private `awaitSlot(slot, in_pause)`, which also reaps.
   - `syncPoint`'s window top-up is skipped when `ahead_bytes == 0 || !populate_supported_`.
3. **Unit tests with fake `PageOps`.** The fake records `(op, p, n)` into a vector guarded by a
   mutex. A "gated" variant blocks inside `discard` until the test releases a gate, which is how
   an in-flight job is simulated. Run each test in both Sync and Concurrent modes:
   - `testPageWorkReleaseThenCancel`: release A and B; reuse A before any sync point. Then:
     `discard` is never called for A; A is not tracked; `decommit_cancelled_bytes` is 512 KiB.
   - `testPageWorkDelaySemantics`: D = 0, 1, 4. Release at epoch e, then call `syncPoint` for
     e+1, …, e+6. The discard of the extent is **posted** at exactly `e + D + 1` (the P§3.6
     table), checked by the fake's log after `drainAll`. In Sync mode, also check that the
     discard happened *during* that `syncPoint` call.
   - `testPageWorkReuseWaitsForPostedDiscard`: Concurrent mode, gated fake. Release A, sync to
     post it (the job blocks in the gate). `onReuse(A)` runs on a second test thread and must not
     return until the gate opens. Afterwards `stall_count` is 1, and the fake shows `discard(A)`
     **before** the reuse returned.
   - `testPageWorkPendingCap`: cap 1 MiB, D = ∞. Releasing three 512 KiB extents posts the oldest
     at the next `syncPoint`.
   - `testPageWorkReleaseWaitsForOverlappingPopulate`: gated populate over [0, 4 MiB). `onRelease`
     of an extent inside that range blocks until the gate opens; one outside does not.
   - `testPageWorkFreshBumpWindow`: ahead = 2 MiB.
     - After `syncPoint` with bump = X: `commit(X', …)` and `populate` were called once over the
       2 MiB-rounded window;
     - `onFreshBump(X, 512K)` returns 0 bytes to commit;
     - a request straddling the window end returns exactly the part above it.
   - `testPageWorkSlotFullWaits`: 9 posts without reaping; the ninth waits for the first, and
     `slot_full_waits` is 1.
   - `testPageWorkDrainAllDiscardsPending`: pending extents are discarded synchronously by
     `drainAll`, and nothing stays tracked.
   - `testPageWorkPopulateUnsupported`: a fake `populate` returns false at the probe, so no
     window is ever opened and `commit` is never called by `syncPoint`.
4. No checkpoint (nothing is wired yet).

### Step 5 — D5: U1 wired into `Allocator`

**Files:** `Allocator.hpp/.cpp`, `PlatformVirtualMemory.hpp` + `_posix.cpp` + `_win32.cpp`.

1. Platform:
   - add `bool discardPages(void*, size_t)` (POSIX: `madvise(MADV_DONTNEED) == 0`; Win64:
     `return true`, the no-op parity of F17);
   - add `bool populatePagesWrite(void*, size_t)` (Linux:
     `madvise(p, n, MADV_POPULATE_WRITE) == 0`, defining the constant as `23` if the libc header
     lacks it; other POSIX and Win64: `return false`).
   - `realPageOps()` in `Allocator.cpp` binds these and `commitAt`.
2. `initialize`/`reset` per P§3.8. `~Allocator` calls `drainAll()` if `page_work_` is set.
3. `releaseOldGenBlock`: `if (page_work_) page_work_->onRelease(block, size, inPause()); else
   { /* existing inline madvise, unchanged */ }`. The emplace and in-use debit are unchanged.
4. `acquireOldGenBlock` reuse branch: `if (page_work_) page_work_->onReuse(block, block_size,
   inPause());`, placed immediately **before** the `madvise(..., MADV_WILLNEED)` line.
5. `onGCPauseEnd`: `++sync_epoch_; page_work_->syncPoint(sync_epoch_, heap_base +
   old_gen_committed, heap_base + nursery_offset);`.
6. The atexit path (`eco_entry.cpp` `atexitPrintStats`, **not** the signal path): call
   `Allocator::instance().drainHelperWork()`, a public wrapper that locks and calls
   `drainAll()`, before `printGCStatsOnce`, so that job CPU and bytes are final. The signal path
   prints whatever the atomics hold.
7. Copy `page_work_->counters()` into `getCombinedStats`'s `PageSupplyStats`/
   `HelperStatsSnapshot`.
8. **Allocator-level unit test** `testDecommitModesAgreeOnCounters`:
   - a deterministic workload: seeded `HeapGenerators` churn under a 64 MiB old-gen config with
     `decommit_on_oldgen_release` true, forcing ≥ 5 majors, where each major releases blocks
     that later minors reacquire;
   - run it three times in one process: mode 0, mode 1, mode 2 with jitter 200. Use
     `reset(&cfg)` between runs, and `shutdownForTesting` plus `reconfigureForTesting` for the
     pool;
   - assert that every GCStats counter the loop compares is identical across the three runs:
     minor/major counts, promoted, allocated, the major event log's before/after/recovered, and
     the old-gen in-use peak;
   - assert that `decommit_cancelled_bytes > 0` in modes 1/2 (so U1 actually engaged).
9. **Checkpoint C[0,1,2]** with the compiled defaults (D = 4, no cap, window 0):
   - counters identical in all three modes;
   - in modes 1/2, "page faults inside minors" falls towards the P§0.1 decommit-off arm (record
     the number); `reuse: resident` is non-zero.

### Step 6 — D7: validators (validate builds only, `#if ECO_HEAP_VALIDATE`)

**Files:** `Allocator.cpp`, `PageWork.cpp`.

- **V1 (reuse is safe):** at the end of `onReuse`, the extent is neither pending nor posted
  (`isPendingOrPosted` is false), and every job whose extents contained it is Done.
- **V2 (tracked extents are free):** at every `onGCPauseEnd`, for every extent `PageWork`
  tracks as pending or posted-discard:
  - it appears **exactly once** in `old_gen_free_blocks_`;
  - it overlaps no `BlockInfo` range of any heap (walk `thread_heaps_` →
    `getOldGen().blockTableForValidation()`, a const accessor added for this) and no
    `unassigned_blocks_` extent.
  O(tracked × log) with a sorted copy; validate builds only.
- **V3 (the window is above the bump):** at every `onGCPauseEnd`, `commit_ahead_end_` is
  `nullptr` or `>= heap_base + old_gen_committed`, and no populate slot's range lies below
  `heap_base` or above the old-gen cap.
- **V4 (no zero-page dependence):** in validate builds, `onReuse` of a **cancelled** extent
  fills it with the poison byte `0xD8` (not `0xDD`, which decodes as a plausible `ptr_ind`:
  memory `nursery-per-site-zeroing-shipped`). Any code that silently relied on reacquired
  memory being zero now fails the validate gates instead of passing by luck. (P§0.1's
  decommit-off run produced identical output, which is evidence but not proof.)
- **V5 (drain is complete):** after `drainAll`, nothing is tracked, every slot is Idle, and
  `pending_bytes_ == 0`.
- **V6 (mode 0 is inert):** in mode 0, `page_work_ == nullptr` and `GCHelperPool::instance()`
  was never configured. Check it at `onGCPauseEnd` and at exit.
- **Unit tests:** in the validate tree, `testDecommitModesAgreeOnCounters` runs with V1–V6
  live; a deliberate V2 violation (a test hook that pushes a tracked extent into a heap's
  unassigned list) must abort (forked child).

### Step 7 — D6: U2 commit-ahead wired into `Allocator`

**Files:** `Allocator.hpp/.cpp`.

1. `acquireOldGenBlock` bump path, modes 1/2: replace the `commitAt(block_base, size)` call with
   ```cpp
   char* from = block_base; size_t n = size;
   if (page_work_) n = page_work_->onFreshBump(block_base, size, &from);
   if (n > 0 && Elm::platform::commitAt(from, n) == nullptr) { /* existing failure path */ }
   ```
   `old_gen_committed` arithmetic is unchanged. Mode 0 keeps the original line.
2. `PageWork` owns `commit_ahead_end_` (P§3.7, through `PageOps::commit`); `Allocator` passes
   `bump` and `cap_end` at each `syncPoint`.
3. Keep `COMMIT_AHEAD_BYTES = 0` in this step. Run **checkpoint C[1,2]** twice:
   - with the compiled default: U2 off, must match Step 5;
   - with a lowered test binary compiled with `COMMIT_AHEAD_BYTES = 64 MiB`: counters identical;
     `fresh commit: ahead-hit` ≫ `ahead-miss`; record in-minor faults.
4. **Unit test** `testCommitAheadNeverRemapsWindow`: an allocator-level run in mode 1 with a
   64 MiB window and a fake-free real run. After a sequence of fresh bumps, check (via a test
   hook counting `commitAt` calls and ranges) that no `commitAt` range intersects a previously
   committed window range.

### Step 8 — D8: the TSan harness

**Files:** new `test/gc-helper-tsan/CMakeLists.txt`, `test/gc-helper-tsan/harness.cpp`,
`test/gc-helper-tsan/README.md`.

1. A **standalone** CMake project (not added to the main build: clang 14 cannot link TSan, F15).
   It compiles `runtime/src/allocator/GCHelperPool.cpp`, `runtime/src/allocator/PageWork.cpp` and
   `harness.cpp` with `-fsanitize=thread -O1 -g -std=c++20`. Configure and run:
   ```bash
   cmake -S test/gc-helper-tsan -B build-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
   cmake --build build-tsan && timeout 900 build-tsan/gc-helper-tsan 2>&1 | tee /tmp/tsan_output.txt
   ```
   Pass: exit 0 **and** no `WARNING: ThreadSanitizer` in the output.
2. Harness scenarios. Each runs with 1, 2 and 4 workers and with jitter 0 and 300 µs:
   - **H1 pool protocol:** 3 poster threads × 20,000 jobs, mixed `wait` and `drain`;
     `shutdownForTesting` at the end.
   - **H2 PageWork with fake ops under a mutex:** the harness's "mutator" thread holds a harness
     mutex (standing in for `thread_mutex_`) around every `PageWork` call. It drives a random
     script of release / reuse / fresh bump / syncPoint over 256 fake extents for 200,000 steps.
     The fake ops check that an extent is **never** discarded while the harness marks it as "in
     use" (acquired and not released). A violation aborts.
   - **H3 real memory:** the H2 script over a real 256 MiB `mmap` region (512 KiB extents), with
     the real ops (`madvise DONTNEED`, `MADV_POPULATE_WRITE`, `mmap MAP_FIXED`).
     - After every acquire, the mutator writes a per-extent 64-bit pattern (its generation
       number) into the first word of every 4 KiB page.
     - Before every release, it verifies all of them.
     - **Any zeroed word means a discard hit owned memory**: print the extent and abort.
     This is the end-to-end proof of P§3.6's ownership argument (rule 7).
3. `README.md` records the command, the g++ requirement and the pass condition.

### Step 9 — D9: measurement plumbing completion

**Files:** `GCStats.hpp/.cpp`, `benchmarks/gc-event-log-summary.py`.

1. `GCPhaseTotals`:
   - add `std::vector<PauseEvent> stall_events` (same cap and dropped counter as
     `pause_events`), filled from `Allocator` after an outside-pause stall;
   - `merge` and `reset` handle it;
   - add the `MMU incl. helper stalls` line: MMU over the time-sorted union of pauses and
     outside-pause stalls, at the existing windows.
2. Event log: `stall` and `job` rows (P§3.9). The job timestamps come from the worker; store
   `post_ns`, `start_ns` and `end_ns` in `PageJob` and log them at reap time on the mutator.
   The log writer is not thread-safe, so never write from a worker.
3. `gc-event-log-summary.py`: skip unknown kinds; summarise stalls (count, total, max, p99) and
   jobs per client (count, bytes, sum and max of `end − start`, and the post→start queueing
   delay).
4. **Unit test** (`GCPauseStatsTest.cpp`): `mmu` over pauses+stalls equals a hand-computed case.
5. **Checkpoint C[2]** on the phase-timer tree (`eco-optTG3pt-cN`): the pause lines that existed
   in TG2 print in the same format, and the new lines appear.

### Step 10 — gates, all modes (P§6)

Run G1–G10. G3–G5 run in **mode 2** (the intended default) **and** mode 1. Mode 0 is covered by
G3's `check` re-run and by G8.

### Step 11 — measurement and experiments (P§5)

Build the timed candidate `eco-optTG3` with the Step-10 tree, lowering `ecoghash.mlir`. Also
build the phase-timer candidate `eco-optTG3pt`.

### Step 12 — defaults, cleanup, documentation

1. Set the compiled defaults from E1/E2/E3: `GC_THREAD_MODE` (expected `2`),
   `DECOMMIT_DELAY_SYNCS`, `DECOMMIT_PENDING_MAX_BYTES`, `COMMIT_AHEAD_BYTES`, `GC_HELPER_CPU`
   (expected `-1`).
2. **Rerun G1–G8 with the new defaults.** The candidate triple *is* the P§5 acceptance run if it
   used the final defaults. Otherwise run one more.
3. Invariants (P§8), `THEORY.md` "Execution Model" (the "There is no separate collector thread"
   paragraph, `THEORY.md:253`), `design_docs/theory/heap_representation_theory.md` "Thread
   Ownership (HEAP_007)", and THEORY.md's shrink-and-return item 6 (`:89`) on decommit.
4. Snapshot `keep-TG3`; copy `eco-optTG3` to `keep-TG3/bin/`; `cp -p` it to `eco-opt-prev`.
   Write loop entry **TG3**, the master plan row 3 (status plus facts for phases 4–7), and M§5's
   trajectory row.

---

## 5. Measurement and acceptance

**Runs** (`gc-opt-loop.md` §2 loop body, strictly serial, idle machine, `timeout 1200`, rule 5
environment):

| arm | binary | `ECO_GC_THREAD` | R |
|---|---|---|---|
| control | `eco-optTG2` | `0` | 1, 2, 3 |
| candidate, sync | `eco-optTG3` | `1` | 1, 2, 3 |
| candidate, concurrent | `eco-optTG3` | `2` | 1, 2, 3 |
| candidate, concurrent + jitter | `eco-optTG3` | `2`, `ECO_GC_HELPER_JITTER_US=0500` | 1 |
| candidate, mode 0 | `eco-optTG3` | `0` | 1 |
| pauses | `eco-optTG2pt` (0) and `eco-optTG3pt` (1 and 2), `ECO_GC_EVENT_LOG` set | as listed | 1 each |

Record for every run: wall, GC, minor, major, mark, sweep, **in-minor faults, process minor
faults, system time**, max RSS, the page-supply block, and the helper block. From the pause
runs, record max / p99 / p50 of minor-only and of all pauses, both MMU lines, and the
stall and job summaries.

**Acceptance:**

| Criterion | Pass |
|---|---|
| C: counters and output | bit-identical across all ten candidate runs and equal to the control; every `out.mlir` identical to `ecoghash.mlir` |
| Z: mode 0 | the mode-0 candidate matches the control in counters **and** in in-minor faults (±0.5 %) and max RSS (±0.5 %): the escape hatch is physically inert |
| F: faults | mode 2 in-minor faults ≤ 50 % of the control's (U1 alone should reach ~46 %, P§0.1; U2 lowers it further) |
| P: pauses | mode 2 minor GC time and minor-only p99 are **below** the control (medians), and the worst pause is not above the control's |
| S: stall | total stall ≤ 1 % of total pause time, and max stall ≤ 5 ms |
| R: RSS | median max RSS ≤ control + `commit_ahead_bytes` + 64 MB; `pending peak` ≤ the E1 cap |
| I: interference | median `non-helper CPU`(mode 2) − median `non-helper CPU`(mode 1) ≤ 1 % of it; above that, E3's pinning arm decides |
| W: wall | mode 2 median ≤ control median + the larger spread (expected: lower) |
| H: hangs | zero timeouts across every run and gate |

### 5a. Experiment E1 — `decommit_delay_syncs` and the pending cap (mode 1)

- Arms: D ∈ {0, 1, 4, 16, ∞}, one run each. Use a lowered binary per value (the compiled-default
  rule, `gc-opt-loop.md` §5), or `ECO_HEAP_CONFIG` with **same-length** JSON file paths, since
  these runs are judged on faults and RSS, which the environment cannot move.
- Report per arm: in-minor faults, `reuse: resident` / `after discard`, minor GC, max RSS,
  `pending peak`.
- **4 GB check:** repeat D = the chosen value and D = ∞ under a heap config capping the old gen
  at 4 GiB (`max_heap_size` such that `oldGenCapBytes()` = 4 GiB) on the E2E stress workload
  (`benchmarks/heap-config-gc-pressure.json` plus the cap). Record `pending peak` against the cap.
- **Rule:**
  - D = the smallest value whose in-minor faults are within 10 % of D = ∞;
  - the cap = max(256 MB, 10 % of the E1 old-gen peak), unless the 4 GB run shows the chosen D
    already keeps `pending peak` under 10 % of 4 GiB, in which case the cap is 0.

### 5b. Experiment E2 — `commit_ahead_bytes` (mode 2, E1's D)

- Arms: W ∈ {0, 32, 128, 512} MiB, one run each.
- Report: in-minor faults, `ahead-hit` / `ahead-miss`, populate job CPU, the queueing delay
  (post→start) and duration (from the event log), minor GC, max RSS.
- **Rule:**
  - W = the smallest value that brings in-minor fresh-commit faults (`ahead-miss` / 4 KiB,
    cross-checked against the in-minor faults) to ≤ 10 % of W = 0 **and** lowers minor GC time;
  - if no W lowers minor GC time (rule 6: the populate race or L3 interference ate it), ship
    W = 0, keep the code, and record the negative result.

### 5c. Experiment E3 — sync vs concurrent, pinning

- At E1's D and E2's W, the candidate triples in modes 1 and 2 (the acceptance runs), plus one
  mode-2 run with `gc_helper_cpu` = 23 (a lowered variant or JSON) under `taskset -c 0-23`.
- Report interference (P§3.9) and the minor-GC and pause deltas.
- **Pin by default only if** the pinned run lowers interference by more than its spread.

---

## 6. Gates

| # | Gate | Command / check | Pass |
|---|---|---|---|
| G1 | Runtime unit tests (main tree) | `cmake --build build --target test && timeout 3600 build/test/test 2>&1 \| tee /tmp/test_output.txt` | all pass, incl. `GCHelper*`, `PageWork*`, `testDecommitModesAgreeOnCounters`, `testCommitAheadNeverRemapsWindow` |
| G2 | Elm unit tests | `cmake --build build --target elm-tests` | the reference set (13,565 / 12) |
| G3 | E2E | `timeout 3600 cmake --build build --target full 2>&1 \| tee /tmp/test_output.txt` **once**, with the final defaults (mode 2). Then `ECO_GC_THREAD=1` and `ECO_GC_THREAD=0` each with `--target check` (C++-only change, no MLIR regeneration, CLAUDE.md) | all pass in all three (1,757/1,757 at TG2) |
| G4 | GC-pressure stress | `ECO_HEAP_CONFIG=/work/benchmarks/heap-config-gc-pressure.json cmake --build build --target stress` in modes 0, 1, 2 | 100/100 and ≳1,000 minors in each |
| G5 | Heap validator | validate tree: build `test`, `ecoc` **and `EcoRuntimeStatic`** explicitly (W11b). Run G1, G3 (`check`) and G4 there in mode 2 **with `ECO_GC_HELPER_JITTER_US=0300`**, and G1 in mode 1. **No validator self-compile** (M§2) | green; no `[heap-validate]` line; the 5 pre-existing `JsonRoundtrip*` stress aborts only (TG2) |
| G6 | Stats-off build | `cmake --build build-nostats --target ecoc` | builds (the pool and `PageWork` compile without stats) |
| G7 | TSan harness | P§4 Step 8 | exit 0, no TSan warning, H3 no zeroed word |
| G8 | Counters, determinism, fixed point | the P§5 runs | criterion C and Z |
| G9 | Hang audit | grep every run and gate log for exit 124 / `timeout` | none |
| G10 | Static checks | (a) `grep -n 'MADV_DONTNEED' runtime/src/allocator/*.cpp` shows only the mode-0 line in `releaseOldGenBlock` and `platform::discardPages`; (b) `grep -nE '#include' runtime/src/allocator/{GCHelperPool,PageWork}.{hpp,cpp}` shows no allocator/heap header except `GCHelperPool.hpp`; (c) `grep -n '\.state' runtime/src/allocator/*.cpp` matches only in `GCHelperPool.cpp` and `PageWork.cpp`; (d) the diff adds no atomic, lock or `PageWork` call to `allocate*`, `eco_alloc*`, `NurserySpace.cpp` or `OldGenSpace.cpp` | all as stated |

---

## 7. Traps (read before starting)

1. **`MADV_DONTNEED` on owned memory is silent heap corruption.** The ownership argument is
   P§3.6: posted extents stay in the free list, and reuse waits. Do not "optimise" the wait away,
   and do not discard anything outside `PageWork`. V1/V2, H3 and G10(a) guard it.
2. **`mmap MAP_FIXED` over the commit-ahead window discards the populated pages** without any
   error. It costs only the work U2 was supposed to save, which is why a broken `onFreshBump`
   looks like "U2 does nothing". `testCommitAheadNeverRemapsWindow` and `ahead-hit` guard it.
3. **The environment is a program input** (rule 5). An arm with `ECO_GC_THREAD=conc` against a
   control without the variable is not a counter comparison.
4. **Deadlock shapes.**
   - Workers never take `thread_mutex_`. The mutator waits for workers *while holding*
     `thread_mutex_`, which is safe only because of that.
   - The signal-path stats print must not take the pool mutex (F10): read atomics only.
   - `drainAll` from `atexit` runs on the Elm thread with no lock held by the caller.
5. **`Allocator::reset` with jobs in flight** (unit tests reset constantly). `drainAll` must run
   before `old_gen_free_blocks_.clear()` and before the heaps are destroyed, or a late discard
   hits the next test's heap. V5 and the test order in Step 5.8 guard it.
6. **Unit tests do not see `ECO_HEAP_CONFIG`** (F13). Set fields in the test config. The pool's
   first `configure` wins: use `reconfigureForTesting` after `shutdownForTesting`.
7. **Banner parsers** (`heap-profile.py`, `lss-loop-extract.sh`, the loop's greps) key on
   existing lines. Add blocks and lines; never reformat an existing one. In particular the stall
   events do **not** go into `pause_events`.
8. **Sync-mode populate is pure pause cost.** Do not judge U2 in mode 1. In mode 1 it can only
   lose; E2 runs in mode 2.
9. **Machine hygiene** (phases 1–2): don't rebuild `build/` during a lowering; don't run E2E
   next to a timed run; no `pkill -f` pattern that matches your own shell; `touch` restored
   sources.
10. **`rc == 0` is not success** (M§2), and a timeout is a failure (rule 8).
11. **Win64/macOS:** `discardPages` is a no-op on Win64 (parity with today's stub), and
    `populatePagesWrite` returns false off Linux, so U2 disables itself. The pool itself is
    portable. Do not add a page-touching fallback (P§3.7).

---

## 8. Invariants (land in Step 12)

**Amend** (keep the id; append "(Amended 2026-09-2x, threaded-gc-03)"):
- **HEAP_007 ThreadOwnership:**
  - Each heap region is owned by exactly one `ThreadLocalHeap`. There are no cross-thread heap
    pointers, and every *decision* about a heap is made by its mutator.
  - Collection *work* may run on GC helper threads (`GCHelperPool`, one per process) only as a
    job the owning mutator posted at a sync point, touching only state the job owns until the
    mutator collects it.
  - As of threaded-gc-03, helper jobs touch **no heap object and no HPointer**: they discard
    and populate old-gen pages. Phases 4+ extend the set of job kinds, and each such phase amends
    this row.

**Add:**
- **GC_DET_001 DeterministicGCDecisions:**
  - Every GC policy decision (collection triggers, promotion, nursery sizing, which block or
    extent an allocation receives, heap growth and shrink) is a function of mutator allocation
    and of state observed at a mutator sync point, **never of helper progress**.
  - Mutator code may inspect a helper job only to wait for it.
  - `gc_thread_mode` 1 (sync, jobs run inline at post) is the reference: mode 2 and mode 2
    with `ECO_GC_HELPER_JITTER_US` must reproduce its GC counters exactly.
  - Sources: `GCHelperPool.cpp`, `PageWork.cpp`, report §10.
- **HEAP_058 GCHelperHandshake:**
  - Helper jobs are posted and collected only at mutator slow paths: the outermost pause end
    (`Allocator::onGCPauseEnd`), and `acquireOldGenBlock` / `releaseOldGenBlock` under
    `thread_mutex_`.
  - Publication is the pool mutex's release/acquire; there is no fence, atomic or lock on any
    mutator fast path.
  - Workers never take `thread_mutex_`; the mutator may wait for a worker while holding it.
  - A job's state is read only by `GCHelperPool` and `PageWork`.
- **HEAP_059 DeferredDecommit:**
  - With `gc_thread_mode` ≠ 0, a released old-gen extent is not discarded at release. It stays
    Pending, and resident, in `old_gen_free_blocks_`.
  - It is posted for `MADV_DONTNEED` at the first sync point where its age exceeds
    `decommit_delay_syncs`, or earlier when pending bytes exceed `decommit_pending_max_bytes`.
  - A reuse of a Pending extent cancels its discard. A reuse of a posted extent waits for the
    job.
  - Posted extents stay in `old_gen_free_blocks_`, so allocation choices never depend on helper
    progress (GC_DET_001).
  - No code may rely on a reacquired old-gen extent reading as zero (V4 poisons cancelled
    extents in validate builds).
  - Mode 0 discards inline at release, exactly as before.
- **HEAP_060 CommitAhead:**
  - With `gc_thread_mode` ≠ 0 and `commit_ahead_bytes` > 0, the range
    `[heap_base + old_gen_committed, commit_ahead_end_)` is mapped RW by the mutator at a sync
    point and populated by a helper with `MADV_POPULATE_WRITE`, a content-neutral operation.
  - The bump path of `acquireOldGenBlock` never re-maps any part of that range.
  - A release waits for an overlapping in-flight populate.
  - `old_gen_committed` and every accounting field are unchanged by the window.

---

## 9. As-built deviations

Recorded during implementation (2026-09-25).

1. **E1 refuted the pause-end delay; the delay is counted in MAJORS
   (`decommit_delay_majors`, new).** E1, mode 2, one run each (`eco-optTG3-c1`), counters
   identical across all arms:

   | `decommit_delay_syncs` | process minflt | minor GC | reuse resident / after discard | max RSS |
   |---|---|---|---|---|
   | 0 | 4,824,867 | 54.64 s | 0 / 10,127 MB | 9,391 MB |
   | 4 | 4,686,077 | 53.68 s | 473 / 9,654 MB | 9,402 MB |
   | 16 | 4,378,512 | 53.66 s | 1,676 / 8,451 MB | 9,403 MB |
   | 64 | 3,957,370 | 53.40 s | 3,327 / 6,801 MB | 9,397 MB |
   | 256 | 2,867,039 | 51.48 s | 7,598 / 2,530 MB | 9,409 MB |
   | ∞ | 2,218,993 | 50.93 s | 10,127 / 0 MB | 9,410 MB |

   - No finite value came within the P§5a rule's 10 % of ∞: the minors reacquire released
     blocks throughout a whole major cycle, not in the first few pauses.
   - A block not reused by the *next major* is real surplus. So `PageWork` also ages by a
     **major epoch**: `Allocator::major_epoch_`, bumped at the sync point that ends a pause
     containing a major (`ThreadLocalHeap::pause_had_major_`).
   - `decommit_delay_majors = 1` reproduces ∞ exactly (2,220,177 faults, 50.63 s minor, 0 MB
     reused after discard) while bounding retention to one cycle.
   - Defaults: `DECOMMIT_DELAY_SYNCS = UINT32_MAX` (off), `DECOMMIT_DELAY_MAJORS = 1`.
   - Unit test `testPageWorkDelayMajors`.
2. **Pending cap default 0, not the P§5a formula.** The formula gives ≈ 880 MB. A 1 GiB-cap arm
   (with W = 128 MiB, M = 1) measured:
   - reuse-after-discard 5,896 MB (vs 0);
   - process minflt 3.31 M (vs 1.96 M);
   - minor GC 49.21 s (vs 46.77 s);
   - max RSS unchanged (9,764,572 vs 9,770,888 kB).

   Pending pages were resident *before* the major that released them, so retaining them never
   raises max RSS. The cap stays as the lever for programs that want RSS to fall after a burst.
   The 4 GB-budget argument follows from the same fact: retention with M = 1 is bounded by one
   cycle's releases, and never above the preceding RSS peak.
3. **E2: W = 128 MiB** (mode 2, M = 1, `eco-optTG3-c2`):

   | W | ahead hit / miss | process minflt | minor GC | max RSS |
   |---|---|---|---|---|
   | 0 | 0 / 8,769 MB | 2,220,177 | 50.63 s | 9,407 MB |
   | 32 MiB | 6,482 / 2,287 MB | 1,948,334 | 47.94 s | 9,447 MB |
   | 128 MiB | 8,769 / 0 MB | 1,958,650 | 46.77 s | 9,541 MB |
   | 512 MiB | 8,769 / 0 MB | 2,053,371 | 46.81 s | 9,925 MB |

   - 128 MiB is the smallest W with `ahead-miss` ≤ 10 % (it is 0), and it lowers minor GC by
     3.9 s.
   - Process minflt barely moves, because the populate faults now happen on the helper. The
     in-minor count is in the phase-timer runs (P§10 results).
4. **E1/E2 ran in mode 2, not mode 1.** Decisions are identical (G8), and E2 is only
   meaningful in mode 2 (trap 8). They used `ECO_HEAP_CONFIG` files with same-length names, so
   they are counter-comparable with each other but not with the control (rule 5): their
   counters are identical among themselves and differ from the no-JSON control by the known
   environment effect.
5. **`drainAll(bool discard_pending)`.**
   - The exit path (`drainHelperWork`, `~Allocator`) waits for the jobs but does **not** discard
     pending extents: that would be wasted `madvise` at exit.
   - `reset()` discards them (V5).
6. **`GCHelperPool::wait` returns a `StallRecord`** instead of storing a "last wait" in the
   pool. A shared field raced across waiters under TSan's model.
7. **V3 re-stated.** After a large bump, `window_end_` may lie *below* the bump (the window is
   then simply exhausted, and the next sync point opens a new one at the bump). V3 therefore
   checks that every in-flight populate range lies inside `[heap_base, heap_base + old-gen cap)`,
   not that the window is above the bump.
8. **Jitter on reset.** `rebuildPageWork()` (see item 12) restarts the pool only when the mode,
   threads or pin differ. A pool that a test configured with its own jitter keeps it (the
   environment jitter is process-level).
9. **Snapshots.** `lss-loop-snap.sh` covers `runtime/src`, the kernels and a file list, but not
   `test/`, the root `CMakeLists.txt`, `THEORY.md` or `benchmarks/`. Each TG3 snapshot therefore
   carries `extra-files.tar` with the phase's files in those places.
10. **Negative control of the TSan harness.** With `onReuse`'s wait removed, H2 fails in its
    first scenario (`discard of an extent that is not free`). With the source restored: 0
    warnings, exit 0.

---
11. **Fork safety (a real defect, found by G1).** The unit-test runner forks per test. Before
    the fix:
    - a child inherited a pool whose workers did not exist, but with `started_ = true`, so a
      posted job never ran and `wait` hung (60 s timeouts in 4 pressure tests);
    - the parent's parked workers also left `cv_work_` with waiters that do not exist in the
      child.

    `GCHelperPool` now registers `pthread_atfork` at its first `configure`:
    - **prepare:** drain, then lock `m_`;
    - **parent:** unlock;
    - **child:** re-construct `m_`, `cv_work_` and `cv_done_` in place, abandon (leak) the
      parent's `std::thread` objects (`workers_` is a heap pointer for this), and restart workers
      on the next post.

    Pinned by `testHelperPoolSurvivesFork`. It also covers embedders that fork without exec.
    (`Process.cpp` forks and immediately `execvp`s, so it was never exposed.)
12. **First-configuration-wins vs test harnesses.** In a test harness a `reset()` can configure
    the pool (mode 2) before the process's first `initialize()` (mode 1 from `ECO_GC_THREAD`).
    The latter aborted: G4 mode 1 was 0/100. `rebuildPageWork` now restarts the pool whenever it
    is configured differently. That is safe because every earlier `PageWork` has been drained and
    destroyed at that point. Production configures exactly once.
13. **One extra unit test beyond the plan:** `testMmuIncludesHelperStalls` (Step 9.4, a
    hand-computed MMU over pauses + stalls) lives in `GCHelperTest.cpp` rather than
    `GCPauseStatsTest.cpp`.

## 10a. Results (2026-09-25)

Full tables: loop entry TG3 in `benchmarks/gc-opt-loop.md`. Candidate `eco-optTG3`
(`ecoghash.mlir` lowered against the final runtime). Same-session control: `eco-optTG2` in
mode 0.

| criterion | result |
|---|---|
| C: counters and output | **identical** across all 11 timed runs and the control. Every `out.mlir` equals `ecoghash.mlir`. The re-lowered final binary (post fork fix) is identical too |
| Z: mode 0 inert | faults 4,803,105 vs 4,803,717; RSS +0.02 % |
| F: faults | in-minor faults **4,708,246 → 28,904 (−99.4 %)**; process minflt −62 % |
| P: pauses | minor GC median 54.15 → 47.60 s. Minor-only p99 141.5 → 113.7 ms and total 55.05 → 47.35 s (phase-timer runs). The worst pause (last major) has triple median 5,341 → 5,158 ms |
| S: stall | 0 stalls in every run |
| R: RSS | +142 MB, against the bound W + 64 MB = 192 MB |
| I: interference | non-helper CPU, mode 2 − mode 1 = −3.1 s |
| W: wall | 181.21 → 172.67 s (−8.54 s; spreads 1.8 / 3.0 s) |
| H: hangs | none in the final gates. The pre-fix unit-test timeouts were the item-11 defect |

The gates:
- G1 unit + E2E 1,779/1,779;
- G2 elm-tests 13,565/12 (the reference set);
- G3 `full` 1,779/1,779, and `check` 1,779/1,779 in modes 1 and 0;
- G4 stress 100/100 at 1,263 minors in modes 0, 1 and 2;
- G5 validate 1,780/1,780 in mode 2 + jitter 300 and in mode 1, with zero `[heap-validate]`
  lines. Validate stress is 95/100 in both mode 2 + jitter and mode 0: the same 5
  pre-existing `JsonRoundtrip*` aborts;
- G6 stats-off `ecoc` builds;
- G7 TSan 0 warnings (the negative control fails as it must);
- G8 as C;
- G9 no timeouts;
- G10 static checks pass. `OldGenSpace.cpp` and `NurserySpace.cpp` are byte-identical to
  `keep-TG2`.

## 10. Out of scope (and where it goes)

| item | where |
|---|---|
| parallel STW mark on the pool (atomic mark bits, Chase–Lev, termination) | phase 4 |
| incremental / concurrent mark, pacing, assist | phases 5a/5b |
| parallel minor GC, per-thread promotion cursors | phase 6 |
| an async doorbell via `bump.end` | not planned (§3.2); only if a later phase needs sub-pause latency |
| THP policy for old-gen blocks (2 MiB-aligned block commits) | phase 8 candidate; E2 records `AnonHugePages` of the window as a data point only |
| background mark-bitmap clearing | phase 8 (double-buffered bitmaps) |
| deleting mode 0 | after one release with mode 2 default-on (M§2) |

---

## 11. Done means

- G1–G10 are green with the final defaults; G3–G5 are also green in mode 1.
- P§5 acceptance holds: C, Z, F, P, S, R, I, W, H, with any exception diagnosed and recorded.
- E1, E2 and E3 have been run, and the defaults have been chosen by their rules; their tables
  are in the loop entry.
- HEAP_007 is amended, and GC_DET_001 and HEAP_058–060 are added.
- `THEORY.md` and the heap-representation theory doc are updated.
- Snapshot `keep-TG3` is taken, and `eco-opt-prev` is updated.
- Loop entry TG3 is written.
- The master plan's row 3 and §5 row are filled in, with the facts phases 4–7 need: the pool
  API, the sync-point hook, the determinism gate recipe, and the measured interference.
