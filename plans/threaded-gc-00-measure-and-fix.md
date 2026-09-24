# Threaded GC 00 — Measure and fix

**Status:** DONE (2026-09-24), all gates green, kept as snapshot `keep-T00`; see §6a for as-built deviations and `benchmarks/threaded-gc-00-baseline.md` for results. Written against the W13c/`keep-W13d` tree.

**Parent:** `plans/threaded-gc-master-plan.md`, phase 0.

**Background:** `design_docs/parallel-gc.md`, the design-space report. Section references written
§n point into that report. References written P§n point into this plan.

## 0. What this phase delivers, and why

Every later phase of the threaded-GC series is scoped by numbers that nobody has measured:

- how the ~31 ms minor pause divides between stack walk, roots, copying, promotion and in-pause
  sweeping;
- how deep the stacks are at GC time;
- what the pause **distribution** looks like. Pause time is now the primary goal, and today's
  minor-GC histogram tops out at 1 ms, so every real pause lands in its overflow bucket;
- whether kernels write into objects after those objects have survived a GC (M2 in the report,
  §2.2). Phase 7 depends on that answer;
- how much a copying thread on another core slows the mutator through the shared L3.

This phase adds the instruments, fixes one latent bug and some stale documentation, and records a
baseline. **It changes no GC behaviour.**

| # | Deliverable | Build where it is active |
|---|---|---|
| D1 | Fix the `ensureHeadroom` unsigned underflow, with a unit test | all |
| D2 | A minor-GC phase breakdown: stack walk, root phases, per-scanner external roots, Cheney drain vs promoted drain, promotion-allocation estimate, in-pause lazy sweep, large-body sweep, page faults | `ECO_GC_STATS` builds |
| D3 | GC pause accounting: every contiguous mutator stop recorded, then percentiles, max, a log-scale histogram and an MMU curve | `ECO_GC_STATS` builds |
| D4 | New banner blocks, **additive only**: no existing line changes its text, position or meaning | `ECO_GC_STATS` builds |
| D5 | A per-collection event log written as TSV when `ECO_GC_EVENT_LOG=<path>` is set, plus a summary script | `ECO_GC_STATS` builds |
| D6 | A census of writes into survived objects (for P1) | `ECO_HEAP_VALIDATE` builds, runtime-gated |
| D7 | The L3 co-runner interference experiment | benchmark script, no runtime change |
| D8 | Stale documentation fixes (report §14) | docs and comments |
| D9 | The baseline document `benchmarks/threaded-gc-00-baseline.md` | — |

## 1. Ground rules for this phase

1. **No behaviour change.**
   - GC counters (minor cycles, major cycles, promoted, survived, bytes, nursery grow events)
     must be **bit-identical** to the reference on the self-compile.
   - `out.mlir` must be byte-identical to `bin/ecoghash.mlir`.
   - The only permitted behaviour change is D1, which is unreachable today: nothing clamps `end`
     below `ptr`.
2. **Timers at loop granularity, never per object.** A per-object clock read costs several % of
   wall (the `g_in_minor_gc` note at `OldGenSpace.cpp:643-655`; `inline-bump-state-tls`). The
   only per-object paths touched here use **deterministic 1-in-N sampling** (P§3.7).
3. **Timers must not feed decisions.** No GC policy may read any new counter. That is what keeps
   rule 1 true.
4. **Additive banner.** Existing parsers depend on the current text:
   `benchmarks/lss-loop-extract.sh:14-19`, `heap-profile.py:parse_summary` (`:516`) and its
   histogram parsers, and `benchmarks/call-stats-extract.py`.
   - New blocks are appended **after** the existing "Allocator Timings" / "Adaptive Lazy-Sweep
     Bytes" blocks.
   - New labels must not contain any string an existing parser searches for: `Minor GC cycles:`,
     `Major GC cycles:`, `Total time:`, `Total GC/Alloc time:`, `True mutator`,
     `totals: promoted`, `Minor GC Timing:`, `Major GC Timing:`.
   - Check this mechanically (P§4 G6).
5. **Everything compiles away when stats are off.**
   - D2–D5 sit inside `#if ENABLE_GC_STATS`.
   - D6 sits inside `#if ECO_HEAP_VALIDATE` and is additionally runtime-gated.
   - The Release preset (`ECO_GC_STATS=OFF`) must build and must not grow.
6. **One kill switch.** `ECO_GC_PHASE_TIMERS=0` disables the fine-grained timers and sampling
   of D2 and D3 at runtime. It is read once per process, like `gcPhaseProfileEnabled`
   (`ThreadLocalHeap.cpp:33-40`). The default is on in stats builds. It exists so that the
   instruments' overhead can itself be measured (P§4 G8).

## 2. Verified facts the steps rely on

Re-verify each fact before editing; line numbers drift ([[gc-plan-premises-need-rederiving]]).

| # | Fact | Where |
|---|---|---|
| F1 | There are **three** `GCStats` objects per heap, merged only at print time by `Allocator::getCombinedStats`: nursery `stats`, old-gen `alloc_stats_`, and heap `stats_`. Every new field must be added to `combine()` and `reset()`, or it silently reads zero in the banner. | `NurserySpace.hpp:151`, `OldGenSpace.hpp:379`, `ThreadLocalHeap.hpp:252`, `Allocator.cpp:962-971`, `GCStats.cpp:837`, `:1778` |
| F2 | The minor-GC pause timer starts after the stack walk and stops before the large-body sweep. | `ThreadLocalHeap.cpp:530-531`; timer `NurserySpace.cpp:436-440`, `:920-925`; sweep `:931` |
| F3 | Every GC entry goes through `ThreadLocalHeap::minorGC` or `ThreadLocalHeap::majorGC`. `minorGC` may call `majorGC` (`:538-547`). Other `majorGC` callers: `:354`, `:382`, `:521`, `Allocator::majorGC` (`Allocator.cpp:439`), `eco_major_gc` (`RuntimeExports.cpp:4272`). | `ThreadLocalHeap.cpp` |
| F4 | The minor-GC histogram's finite buckets end at 1 ms, so the ~31 ms pauses all fall into the overflow bucket. | `GCStats.hpp:106-117` |
| F5 | External root scanners are anonymous `std::function`s stored in a vector, with 9 production registration sites. | `RootSet.hpp:297-314`, `RootSet.cpp:96`; sites: `PlatformRuntime.cpp:101`, `Scheduler.cpp:56`, `PortRuntime.cpp:260`, `RuntimeExports.cpp:4548` (list scratch), `TimeEffectManager.cpp:78`, `HttpExports.cpp:292`, `MVar.cpp:344`, `CellStore.cpp:147`, `Runtime.cpp:85` |
| F6 | `OldGenSpace::lazySweep` returns `void`. Its local `work_done` counts heap bytes walked (the budget's unit). | `OldGenSpace.cpp:2628-2649`, `:2720`, `:2778` |
| F7 | The promotion lazy-sweep slice is at `OldGenSpace.cpp:677-693` (inside `allocate`, while `gc_phase_ == Sweeping`, budget divided by `minor_sweep_divisor` when `g_in_minor_gc`). The size-class dispatch follows at `:703-717`. | `OldGenSpace.cpp` |
| F8 | The Cheney ↔ promoted drain is an alternating loop run to a fixed point. | `NurserySpace.cpp:562-577` |
| F9 | The stack walk loop, with `findRecord` per frame and `Indirect` locations, is `collectStackRootsFromStackMap`. | `ThreadLocalHeap.cpp:793-864` |
| F10 | After the swap, the age-1 survivors are the contiguous prefix `[fromBase(), bump_.ptr)`, which is parsable by header. The validator already walks it that way. | `NurserySpace.cpp:908-912`, `preEvacuationFromSpaceWalk` `:2049-2093` |
| F11 | `ensureHeadroom` computes `static_cast<size_t>(bump_.end - bump_.ptr) >= n`, and the test helper `headroom()` has the same shape. | `NurserySpace.cpp:254-256`, `NurserySpace.hpp:426-428` |
| F12 | Closures have `n_values`/`max_values` in the word after the header, and `evaluator` is an `EvaluatorDesc*` whose `generic` function pointer is at +0. `Custom` has `ctor` (16 bits). | `Heap.hpp:550`, `:615-633` |
| F13 | This series is runtime-only. The candidate is the reference MLIR `$BK/bin/ecoghash.mlir` lowered against the changed runtime, and the fixed-point check compares against the same file. | `benchmarks/gc-opt-loop.md` §1 Phase 1.4, §2 |

## 3. Steps

Do the steps in order. Each ends in a state that builds and passes `cmake --build build --target
check`. Take a snapshot before starting: `benchmarks/lss-loop-snap.sh snap try-T00-pre
"threaded-gc-00 start"`. There is no working git in the container; see `benchmarks/gc-opt-loop.md`
§1.

### Step 1 — D1: fix the `ensureHeadroom` underflow

**Files:** `runtime/src/allocator/NurserySpace.cpp`, `NurserySpace.hpp`,
`test/allocator/EnsureHeadroomTest.{cpp,hpp}`, `test/main.cpp`.

1. Replace the body of `NurserySpace::ensureHeadroom` (F11) with an explicit ordered compare in
   integer space. Do not use pointer arithmetic that could form an out-of-range pointer:
   ```cpp
   bool NurserySpace::ensureHeadroom(size_t n) {
       const uintptr_t p = reinterpret_cast<uintptr_t>(bump_.ptr);
       const uintptr_t e = reinterpret_cast<uintptr_t>(bump_.end);
       return e >= p && e - p >= n;   // end < ptr (remote clamp) => no headroom
   }
   ```
   Update the comment above it: state that `end < ptr` is a legal "must collect" state, and name
   the report §3.2 as the reason.
2. Make `NurserySpaceTestAccess::headroom` (`NurserySpace.hpp:426-428`) return 0 when
   `end < ptr`, using the same form.
3. Add a test, `testEnsureHeadroomEndBelowPtr`, to `EnsureHeadroomTest.cpp`:
   - Use the existing `tinyThresholdConfig()` heap and bump a few cells.
   - Then set `bump_.end = bump_.ptr - 8` through a new `NurserySpaceTestAccess::setBumpEnd`
     static helper, added beside `bumpEnd` in the header.
   - Assert that `ensureHeadroom(8)` is false, and that `ThreadLocalHeap::ensureNursery(8)` runs
     a minor GC: `getStats().minor_gc_count` goes up by 1. Afterwards the headroom must be ≥ 8
     and `bump_.end` must be ≥ `bump_.ptr`.
   - Declare it in the `.hpp` and register it in `test/main.cpp` next to
     `testEnsureHeadroomPostconditionAcrossAdvanceAndGC` (`main.cpp:827`).
4. **Done when:** `build/test/test --filter EnsureHeadroom` passes, and the new test *fails* when
   step 1's change is temporarily reverted. Check that once, then restore the fix.

### Step 2 — Timer primitives and the kill switch

**Files:** `runtime/src/allocator/GCStats.hpp`, `GCStats.cpp`.

1. In `GCStats.hpp`, inside `namespace Elm` and inside `#if ENABLE_GC_STATS`, add:
   ```cpp
   // threaded-gc-00: fine-grained GC phase timers. Latched once per process
   // from ECO_GC_PHASE_TIMERS (default ON; "0" disables).
   bool gcPhaseTimersEnabled() noexcept;

   // Monotonic ns since process start (same origin as the major event log).
   inline uint64_t gcNowNs() noexcept { return GCStats::nowSinceProcessStartNs(); }

   // Deterministic 1-in-2^K sampler for per-object paths. Counter-based, no
   // randomness, so it can never perturb anything that is compared across runs.
   template <unsigned K>
   struct SampledTimer {
       uint64_t calls = 0, sampled_calls = 0, sampled_ns = 0;
       bool shouldSample() noexcept { return ((calls++) & ((1u << K) - 1)) == 0; }
       uint64_t estimatedNs() const noexcept {
           return sampled_calls ? (uint64_t)((double)sampled_ns * calls / sampled_calls) : 0;
       }
   };
   ```
2. In `GCStats.cpp`, implement `gcPhaseTimersEnabled()` as a function-local static latched from
   `std::getenv("ECO_GC_PHASE_TIMERS")`: disabled only when the value is exactly `"0"`. Mirror
   `gcPhaseProfileEnabled` (`ThreadLocalHeap.cpp:33-40`).
3. Also add one global and one struct:
   ```cpp
   // Stable 16-bit ids for per-scanner stats; see Step 6.
   constexpr int GC_EXT_SCANNER_CAP = 16;

   // One minor collection's measurements; filled by NurserySpace/ThreadLocalHeap,
   // consumed by ThreadLocalHeap::recordMinorPhases (Step 5.6).
   struct MinorGCRecord {
       uint64_t start_ns = 0;             // process-relative, at the stack-walk start
       uint64_t stack_walk_ns = 0, frames_walked = 0, frames_matched = 0, stack_slots = 0;
       uint64_t roots_longlived_jit_ns = 0, roots_stackmap_ns = 0, roots_ranges_ns = 0;
       uint64_t roots_external_ns = 0;
       uint64_t ext_ns[GC_EXT_SCANNER_CAP] = {0}, ext_slots[GC_EXT_SCANNER_CAP] = {0};
       uint64_t drain_tospace_ns = 0, drain_promoted_ns = 0, drain_rounds = 0;
       uint64_t tail_ns = 0;              // checkAndGrow + clear + swap + stats
       uint64_t nursery_pause_ns = 0;     // == the existing elapsed_ns (unchanged meaning)
       uint64_t large_body_sweep_ns = 0;
       uint64_t lazy_sweep_calls = 0, lazy_sweep_bytes = 0, lazy_sweep_est_ns = 0;
       uint64_t promo_alloc_calls = 0, promo_alloc_est_ns = 0;
       uint64_t survived = 0, promoted = 0, survived_bytes = 0, promoted_bytes = 0;
       uint64_t minflt = 0, majflt = 0;
       uint64_t pause_ns = 0;             // whole ThreadLocalHeap::minorGC, excl. any nested major
   };
   ```
   For `survived_bytes`/`promoted_bytes`: if the nursery stats do not already keep byte totals
   next to `objects_survived`/`objects_promoted`, derive them from the per-tag byte arrays
   (`survived_bytes_by_tag`, `promoted_bytes_by_tag`) as a before/after difference of their sums.
   Do not add a per-object increment.

### Step 3 — Aggregate fields in `GCStats` (merge-safe)

**Files:** `GCStats.hpp`, `GCStats.cpp`.

1. Add the run totals as a new section in the `GCStats` class body, after the major-GC event log
   fields:
   - one `uint64_t minor_<name>_total` field for every numeric `MinorGCRecord` member except
     `start_ns`;
   - `minor_frames_walked_max`;
   - `minor_stack_walk_ns_max`;
   - `minor_records` (the count of minors recorded with timers enabled);
   - per-scanner arrays `ext_scanner_ns_total[CAP]`, `ext_scanner_slots_total[CAP]`,
     `ext_scanner_slots_max[CAP]`;
   - `const char* ext_scanner_name[CAP]` (initialised to `nullptr`), and `int ext_scanner_count`.
2. Add the pause-accounting fields (Step 7):
   ```cpp
   struct PauseEvent { uint64_t start_ns; uint64_t dur_ns; uint8_t kind; };
   // kind: 0 = minor only, 1 = minor + nested major, 2 = major only
   static constexpr size_t PAUSE_EVENT_CAP = 1u << 18;   // 262,144 events, ~6 MB if full
   std::vector<PauseEvent> pause_events;                 // reserve lazily on first push
   uint64_t pause_events_dropped = 0;
   uint64_t pause_count = 0, pause_total_ns = 0, pause_max_ns = 0;
   uint64_t pause_count_by_kind[3] = {0, 0, 0};
   static constexpr int PAUSE_LOG2_BUCKETS = 32;         // bucket b: [2^b, 2^(b+1)) µs; b=0 is <2 µs
   uint64_t pause_log2_hist[PAUSE_LOG2_BUCKETS] = {0};
   ```
   `GCStats` gains its first non-trivial member here. Before committing, grep for
   `memset`/`memcpy`/`sizeof(GCStats)`/`std::is_trivially` applied to `GCStats`. None was found on
   2026-09-24; re-check. Copies, as in `combined = accumulated_stats_`, are fine.
3. `combine(other)`:
   - Sum every `_total` field. Take the max of the `_max` fields.
   - For scanners, merge **by name**: for each `other` scanner id, find the same name in `this`
     (append if absent and `ext_scanner_count < CAP`), then sum.
   - Append `other.pause_events` to `pause_events` (respecting the cap and adding overflow to
     `pause_events_dropped`). Sum `pause_count`, `pause_total_ns`, the kinds and the histogram;
     take the max of `pause_max_ns`. Sort `pause_events` by `start_ns` once, at print time, not
     in `combine`.
4. `reset()`: zero every new field, `pause_events.clear()`, names back to `nullptr`, count to 0.
5. **Done when** it builds, `check` passes, and the banner is unchanged (the new fields are not
   printed until Step 8).

### Step 4 — Stack-walk instrumentation

**Files:** `ThreadLocalHeap.hpp`, `ThreadLocalHeap.cpp`.

1. Change `collectStackRootsFromStackMap()` to return a small POD,
   `struct StackWalkCounts { uint64_t frames_walked, frames_matched, slots; }`. Declare it in
   `ThreadLocalHeap.hpp`.
2. In the loop (F9):
   - increment `frames_walked` once per `do { … } while (cur.step())` iteration;
   - increment `frames_matched` when `rec != nullptr`;
   - set `slots = sm_roots.get().size()` at the end.

   These are plain increments: the walk costs ~100 ns per frame, so they are free.
3. Update both call sites: `minorGC` (`:530`) and `majorGC` (`:593`). `majorGC` ignores the
   counts; the major root-scan time is already in its event log.
4. In `ThreadLocalHeap::minorGC`, wrap the call with a timer when `gcPhaseTimersEnabled()`:
   ```cpp
   MinorGCRecord rec;                        // member `pending_minor_` is fine too
   rec.start_ns = gcNowNs();
   const uint64_t t_sw = rec.start_ns;
   StackWalkCounts sw = collectStackRootsFromStackMap();
   rec.stack_walk_ns = gcNowNs() - t_sw;
   rec.frames_walked = sw.frames_walked; rec.frames_matched = sw.frames_matched;
   rec.stack_slots = sw.slots;
   ```
   When timers are disabled, still call the walk, but skip the clock reads.

### Step 5 — Minor-GC phase timers inside `NurserySpace::minorGC`

**Files:** `NurserySpace.hpp`, `NurserySpace.cpp`, `OldGenSpace.hpp`, `OldGenSpace.cpp`,
`ThreadLocalHeap.cpp`.

1. Change the signature to `void minorGC(OldGenSpace&, const StackMapRoots&, MinorGCRecord*
   rec)`. A `nullptr` `rec` means no phase timing. Tests that call `NurserySpace::minorGC`
   directly must pass `nullptr`: grep `test/` for `.minorGC(` and update each call.
2. Let `const bool T = rec && gcPhaseTimersEnabled();`. The existing `gc_start`/`elapsed_ns`
   logic stays exactly as it is. The root phases run in the order 1a, 1b, 1c, 1e, 1e′, 1d, and
   **that order must not change**: root evacuation order decides to-space layout, and therefore
   mutator locality (rule 1). Take one clock read (guarded by `T`) at each phase boundary:

   | Read | Position | Accumulates into |
   |---|---|---|
   | `t0` | right after `gc_start` (`:439`) | — |
   | `t1` | after phase 1a (long-lived roots) | `roots_longlived_jit_ns += t1 − t0` |
   | `t2` | after phase 1b (stackmap roots) | `roots_stackmap_ns = t2 − t1` |
   | `t3` | after phase 1c (JIT/CAF roots) | `roots_longlived_jit_ns += t3 − t2` |
   | `t4` | after phases 1e and 1e′ (stack ranges, single roots) | `roots_ranges_ns = t4 − t3` |
   | `t5` | after phase 1d (external scanners) | `roots_external_ns = t5 − t4`; the per-scanner split comes from Step 6 |

   Each root-phase time includes copying or promoting the objects that phase reaches *directly*.
   Their children are copied later, in the drain. State this in the banner note.
3. The drain loop (F8). Inside `while (scanHasMore() || promoted_idx < promoted_objects.size())`:
   - read the clock before the inner Cheney `while`, after it, and after the inner promoted
     `while`;
   - add the two differences to `drain_tospace_ns` and `drain_promoted_ns`;
   - `++drain_rounds` per outer iteration.

   Record `drain_rounds` in the baseline: if it is large (> 100 on any minor), the per-round clock
   reads become a measurable cost, and P§4 G8 will show it.
4. From the end of the drain loop to the existing `elapsed_ns` computation (`checkAndGrow`, clear,
   validate blocks, swap), add one read at loop exit. Then `tail_ns = (gc_start + elapsed) -
   t_loop_exit`: compute it after `elapsed_ns` is known, using the same clock origin. Simplest:
   take `t_loop_exit` with `GC_STATS_TIMER_START()` and compute
   `GC_STATS_TIMER_ELAPSED_NS(t_loop_exit)` right where `elapsed_ns` is computed.
5. Set `rec->nursery_pause_ns = elapsed_ns`, the existing value, unchanged. Then time
   `oldgen.sweepNurseryLargeBodies(minor_color_)` (`:931`) into `large_body_sweep_ns`.
6. Survived/promoted per minor: read `stats.objects_survived`/`objects_promoted` and the two
   byte sums (Step 2.3) at `t0` and just before `elapsed_ns`, and store the differences in `rec`.
7. Page faults: when `T`, call `getrusage(RUSAGE_THREAD, …)` at `t0` and after the large-body
   sweep, and store the `ru_minflt`/`ru_majflt` differences. Guard with `#if defined(RUSAGE_THREAD)`
   exactly as `majorGC` does (`ThreadLocalHeap.cpp:572-585`).
8. **Recording (ThreadLocalHeap).** After `nursery_.minorGC(old_gen_, stack_map_roots_, &rec)`
   returns, and **before** `evaluateMajorGCTrigger`, call a new private
   `ThreadLocalHeap::recordMinorPhases(MinorGCRecord&)`. It:
   - sets `rec.pause_ns = gcNowNs() - rec.start_ns`. That is the minor's own pause, with any major
     excluded, because the major has not started yet;
   - adds every field into `stats_`'s `_total` fields and updates the maxima;
   - `++minor_records`;
   - hands `rec` to the event-log writer (Step 9) when `ECO_GC_EVENT_LOG` is set.

   Only when `gcPhaseTimersEnabled()`.
9. **Done when** it builds, `check` passes, and on any E2E program with a few minors a temporary
   `fprintf` of one `MinorGCRecord` shows plausible values. Remove the `fprintf` before moving on.

### Step 6 — Named external root scanners with per-scanner cost

**Files:** `RootSet.hpp`, `RootSet.cpp`, `NurserySpace.cpp`, and the 9 registration sites (F5).

1. Extend the API compatibly:
   ```cpp
   void addExternalRootScanner(ExternalRootScanner scanner, const char* name = "unnamed");
   const std::vector<const char*>& getExternalRootScannerNames() const { return external_scanner_names; }
   ```
   Store the names in a parallel `std::vector<const char*> external_scanner_names`, pushed in the
   same `addExternalRootScanner` call. Clear it in `reset()`. Names must be string literals
   (static lifetime).
2. Pass a name at each production site: `"platform-runtime"`, `"scheduler"`, `"port-runtime"`,
   `"list-scratch"`, `"time-effects"`, `"http"`, `"mvar"`, `"cellstore"`, `"eco-runtime"`. Test
   registrations may keep the default.
3. In phase 1d of `NurserySpace::minorGC`, iterate by index `i`. When `T`, wrap each scanner call
   with two clock reads. Count slots by incrementing a local counter inside the existing
   evacuation lambda: capture `uint64_t& slots` by reference, one increment per invoked slot.
   Store the results in `rec->ext_ns[i]` and `rec->ext_slots[i]` for `i < GC_EXT_SCANNER_CAP`;
   add anything beyond the cap to the last entry.
4. Name registry in stats: in `recordMinorPhases`, the first time scanner `i` is seen, copy
   `getExternalRootScannerNames()[i]` into `stats_.ext_scanner_name[i]` and update
   `ext_scanner_count`. Then accumulate `ns`/`slots` totals and take the max of slots.
5. **Done when** the banner (after Step 8) lists `cellstore` with a non-zero slot count on the
   self-compile.

### Step 7 — Promotion-path instrumentation in the old gen

**Files:** `OldGenSpace.hpp`, `OldGenSpace.cpp`, `NurserySpace.cpp`.

1. Make `lazySweep` return `size_t work_done` (F6). All callers ignore the value today, so no
   caller changes. Keep the `static` test-access wrapper (`OldGenSpace.hpp:1396`) returning
   `void`, or forward the value; either is fine.
2. Add to `OldGenSpace`, under `#if ENABLE_GC_STATS`:
   ```cpp
   SampledTimer<4> minor_sweep_timer_;   // 1 in 16 lazySweep calls from promotions
   uint64_t        minor_sweep_bytes_ = 0;
   SampledTimer<8> promo_alloc_timer_;   // 1 in 256 promotion dispatches
   ```
   plus a public accessor that returns them, so the nursery can take start/end differences.
3. In `allocate` (F7), only on the `g_in_minor_gc` side and only when `gcPhaseTimersEnabled()`:
   - Around the `lazySweep(cls_for_sweep, budget)` call: if `minor_sweep_timer_.shouldSample()`,
     bracket it with `gcNowNs()`, then `++sampled_calls` and `sampled_ns += dt`. Always do
     `minor_sweep_bytes_ += lazySweep(...)`.
   - Around the path 2/3/4 dispatch block (`:703-717`, **after** the lazy-sweep block, so the two
     estimates never double-count): if `promo_alloc_timer_.shouldSample()`, bracket it. This
     estimates the allocator's own cost per promotion: free-list pop, split, bag page. The sweep
     is excluded.
   - The mutator-context branch (`timed == true`) is untouched.
4. In `NurserySpace::minorGC`, snapshot the four counters (`calls`, `bytes`, `sampled_calls`,
   `sampled_ns` of each timer) at `t0`, and at loop exit store the differences in `rec`:
   - `lazy_sweep_calls`, `lazy_sweep_bytes`, `promo_alloc_calls`;
   - the estimates, computed from the **differences**: `est = d_sampled_ns * d_calls /
     d_sampled_calls`, or 0 when `d_sampled_calls` is 0.
5. Caveats to print beside these numbers in the banner:
   - They are *estimates* from deterministic 1-in-16 and 1-in-256 samples.
   - Clock-read overhead on sampled calls (~40 ns) inflates the sampled durations. The per-call
     estimate is therefore an upper bound, by about 40 ns per sampled call. The totals stay
     accurate to a few %.

### Step 8 — Pause accounting, percentiles and MMU

**Files:** `ThreadLocalHeap.hpp`, `ThreadLocalHeap.cpp`, `GCStats.hpp`, `GCStats.cpp`.

1. A "pause" is one contiguous interval during which the mutator is inside GC code on this
   thread: from entry to exit of the **outermost** `ThreadLocalHeap::minorGC` or
   `ThreadLocalHeap::majorGC` call. A minor that triggers a major is **one** pause of kind 1.
2. Add private members `int gc_depth_ = 0; uint64_t pause_start_ns_ = 0; bool
   pause_saw_minor_ = false, pause_saw_major_ = false;` and an RAII helper in
   `ThreadLocalHeap.cpp`:
   ```cpp
   struct PauseScope {
       ThreadLocalHeap& h; bool is_major;
       PauseScope(ThreadLocalHeap& h_, bool major) : h(h_), is_major(major) {
           if (h.gc_depth_++ == 0) { h.pause_start_ns_ = gcNowNs();
               h.pause_saw_minor_ = h.pause_saw_major_ = false; }
           (is_major ? h.pause_saw_major_ : h.pause_saw_minor_) = true;
       }
       ~PauseScope() {
           if (--h.gc_depth_ == 0) h.recordPause(h.pause_start_ns_, gcNowNs() - h.pause_start_ns_,
               h.pause_saw_minor_ ? (h.pause_saw_major_ ? 1 : 0) : 2);
       }
   };
   ```
   - Put `PauseScope ps(*this, false);` as the first statement of `minorGC`, and
     `PauseScope ps(*this, true);` as the first statement of `majorGC`.
   - Make `PauseScope` a friend, or give it access through accessors.
   - The pause bracket is always on in stats builds: it is 2 clock reads per GC. It does not
     depend on `ECO_GC_PHASE_TIMERS`.
3. `recordPause(start, dur, kind)` does four things:
   - updates `pause_count`, `pause_total_ns`, `pause_max_ns` and `pause_count_by_kind`;
   - updates `pause_log2_hist`: bucket `b = dur < 2000 ? 0 : min(31, floor(log2(dur/1000)))`,
     i.e. µs-based, where bucket b covers `[2^b, 2^(b+1))` µs. Bucket 20 is about 1–2 s, and
     bucket 31 catches everything slower;
   - appends a `PauseEvent` (reserve 4096 on the first push; `++pause_events_dropped` at the cap);
   - writes an event-log row (Step 9).
4. Statistics at print time (`GCStats.cpp`, new static helpers):
   - **Percentiles** p50, p90, p99, p99.9 and max, by nearest rank on a sorted copy of the
     durations. Compute them over all pauses, and separately for kind 0 and for kinds 1+2 ("any
     pause containing a major"). If `pause_events_dropped > 0`, print a warning line: the
     percentiles then cover only the first `PAUSE_EVENT_CAP` events.
   - **MMU** (minimum mutator utilisation, HB 1 / HB 19.5) for windows
     w ∈ {1, 2, 5, 10, 20, 50, 100, 200, 500 ms, 1, 2, 5, 10 s}, over the run
     `[0, wall_time_ns]`:
     - Sort the events by start and build prefix sums of the durations.
     - `gcIn(a, b)` is the total pause time overlapping `[a, b)`. Binary-search the first event
       with `end > a` and the last with `start < b`, take the prefix-sum difference over the
       fully contained events, and clip the two boundary events to `[a, b)`.
     - The window minimising utilisation starts at some pause start, or ends at some pause end.
       So evaluate `t ∈ {s_i} ∪ {e_i − w}`, clamped to `[0, wall − w]`, and take
       `MMU(w) = min_t (w − gcIn(t, t + w)) / w`.
     - Skip any w > wall. The cost is O(n log n) per window, and n ≤ 262,144.
   - `wall_time_ns` is stamped by `Allocator::getCombinedStats` (`Allocator.cpp:977`). If it is
     0 (unstamped), skip MMU and print why.
5. **Unit test** `test/allocator/GCPauseStatsTest.cpp` (new; add to `test/CMakeLists.txt` next to
   `EnsureHeadroomTest.cpp` at `:107`, and register it in `test/main.cpp`). Build a `GCStats` by
   hand with synthetic `PauseEvent`s, and expose the percentile and MMU helpers as `static`
   functions declared in `GCStats.hpp` so the test can call them. Assert:
   - (a) one 10 ms pause in a 1 s run gives MMU(10 ms) = 0, MMU(20 ms) = 0.5 and
     MMU(1 s) = 0.99;
   - (b) two 5 ms pauses 1 ms apart give MMU(11 ms) = 1/11;
   - (c) percentiles of {1, …, 100} ms give p50 = 50, p99 = 99 and max = 100;
   - (d) `combine()` of two stats objects concatenates their pause events and sums their counts.

### Step 9 — Per-collection event log (TSV) and a summary script

**Files:** `GCStats.hpp`, `GCStats.cpp`, `ThreadLocalHeap.cpp`; new `benchmarks/gc-event-log-summary.py`.

1. `GCEventLog` is a tiny singleton in `GCStats.cpp`. It is enabled when
   `std::getenv("ECO_GC_EVENT_LOG")` names a path, is opened lazily with `fopen(path, "w")`,
   and a mutex serialises writes across heaps.
2. Header row, written once:
   ```
   kind  tid  seq  start_ns  pause_ns  nursery_pause_ns  stack_walk_ns  frames_walked
   frames_matched  stack_slots  roots_longlived_jit_ns  roots_stackmap_ns  roots_ranges_ns
   roots_external_ns  drain_tospace_ns  drain_promoted_ns  drain_rounds  tail_ns
   large_body_sweep_ns  lazy_sweep_calls  lazy_sweep_bytes  lazy_sweep_est_ns
   promo_alloc_calls  promo_alloc_est_ns  survived  promoted  survived_bytes
   promoted_bytes  minflt  majflt  ext:<name>_ns  ext:<name>_slots ...
   major_total_ns  major_mark_ns  major_sweep_ns  major_roots_ns  major_reason
   ```
   - The file is tab-separated.
   - `kind` is `minor`, `major` or `pause`.
   - Columns that do not apply to a row kind are written as `-`.
   - External-scanner columns are fixed at log-open time from the names registered on the first
     heap. If a scanner registers later, its values go into a trailing `ext:late_ns`/`_slots`
     pair, and the summary script reports a warning.
3. Write sites:
   - **Minor rows** from `recordMinorPhases` (Step 5.8).
   - **Major rows** from `ThreadLocalHeap::majorGC` right after `recordMajorGCEvent`. Reuse the
     values it already computes: total, mark, sweep, root scan+push, reason.
   - **Pause rows** from `recordPause` (Step 8.3).

   Every write happens **after** its measured bracket has closed, so file I/O is never inside a
   timed phase. It is inside the pause, which is acceptable: about 2 µs per row against a 31 ms
   pause, and only when the environment variable is set.
4. `fflush` at process exit (`atexit` registered at open), and also from the existing fatal-signal
   stats printer path, so that a crashed run leaves a readable log. Find that path by grepping for
   `[gc-stats] SIG`.
5. **Script** `benchmarks/gc-event-log-summary.py <log.tsv> [--json]`, Python 3 standard library
   only. It prints:
   - **(a)** Per-phase totals and shares of the summed minor `pause_ns`, plus the unaccounted
     residual: `pause_ns − (stack_walk + all roots + drains + tail + large_body_sweep)`. This
     should be under 2 %; a larger residual means a missed phase.
   - **(b)** Percentiles of minor `pause_ns`, and of each phase, per minor.
   - **(c)** Per-scanner totals and max slots.
   - **(d)** The 20 worst pauses, with their phase breakdowns.
   - **(e)** A correlation line: the Pearson r of `pause_ns` against `promoted`, `survived`,
     `lazy_sweep_bytes` and `stack_slots`.
   - **(f)** Per-promotion cost: `(drain_tospace_ns + drain_promoted_ns) / (survived + promoted)`,
     and `promo_alloc_est_ns / promoted`.

   `--json` emits the same data as a JSON object, for the baseline document.

### Step 10 — Banner blocks (D4)

**Files:** `GCStats.cpp` (`print()`).

Append three blocks after the "Adaptive Lazy-Sweep Bytes" block (`GCStats.cpp:~1386`) and before
the allocation-size histograms. Guard with `minor_records > 0` or `pause_count > 0` respectively.
Labels must obey rule 4. Use the exact titles below: parsers key on titles.

1. **`GC Pause Distribution (threaded-gc-00):`**
   - Rows for pause count and kinds, total, max, p50/p90/p99/p99.9, for all pauses, minor-only
     pauses, and pauses containing a major.
   - Then the log2 histogram, printed like the existing ones with `█` bars, and the MMU table:
     one line per window, `MMU  <w>: <pct>%`.
   - Then one explanatory line:

     > pause = contiguous mutator stop; includes the stack walk and the large-body sweep, which
     > "Minor GC Timing" excludes.
2. **`Minor GC Phase Breakdown (threaded-gc-00):`**
   - For each phase: total seconds, share of summed minor pause, and mean ms per minor.
     Phases: stack walk; roots (long-lived + JIT); roots (stackmap); roots (ranges); roots
     (external); drain to-space; drain promoted; tail; large-body sweep; unaccounted.
   - Then:
     - stack frames walked (mean, max) and frames matched (mean);
     - drain rounds (mean, max);
     - in-pause lazy sweep (calls, GB, estimated s);
     - promotion allocator (calls, estimated s, estimated ns per call);
     - page faults (minor, major) inside minors.
   - A note line if `ECO_GC_PHASE_TIMERS=0` was set: "phase timers disabled".
3. **`External Root Scanners (threaded-gc-00):`**
   - One row per named scanner: total ms, mean µs per minor, total slots, max slots in one minor.
4. Add one line inside block 1 for the two GC activities the existing "True mutator" line counts
   as mutator time:

   > GC work outside the minor timer: stack walk X s, large-body sweep Y s (counted as mutator in
   > "Allocator Timings")

   **Do not modify the existing "True mutator" line** (rule 4).

### Step 11 — D6: census of writes into survived objects (validate builds)

**Purpose.** Phase 7 of the master plan needs to know whether any code writes into an object after
that object has survived a minor GC. That rule is P1 in report §7.4.3; §11.2 drafts it as the
HEAP_SNAPSHOT_001 invariant row. The existing `in_phase3_` assertion (`NurserySpace.cpp:1186-1222`)
only catches such a write when the written value is **younger** than the parent, so it is
insufficient: a concurrent promoter would also lose writes of *older* values. This census catches
**any** write, by checksum.

**Files:** `NurserySpace.hpp`, `NurserySpace.cpp`. All code is inside `#if ECO_HEAP_VALIDATE`, and
active only when `ECO_SURVIVOR_WRITE_CENSUS=1` (latched once, like `ECO_NURSERY_POISON` at
`NurserySpace.cpp:83`).

1. Members:
   ```cpp
   struct CensusEntry { uint32_t offset_q; uint32_t size; uint64_t hash; uint8_t builder; };
   std::vector<CensusEntry> census_;     // survivors recorded at the end of the previous minor
   char* census_base_ = nullptr;         // fromBase() at record time
   struct CensusKey { uint8_t tag; uint32_t sub; uint16_t word; };  // sub = ctor or evaluator id
   std::unordered_map<uint64_t, uint64_t> census_hits_;   // packed key -> count
   std::unordered_map<uint64_t, uintptr_t> census_eval_addr_;  // evaluator id -> generic fn ptr
   uint64_t census_checked_ = 0, census_mismatched_ = 0, census_skipped_builder_ = 0;
   ```
   `offset_q` is `(obj − census_base_) >> 3`, which fits 32 bits for nurseries up to 32 GiB.
   Assert `from_capacity_bytes_ < (32ull << 30)` when enabling.
2. **Record.** At the very end of `NurserySpace::minorGC`, after the swap and the bump reset:
   - walk `[fromBase(), bump_.ptr)` by `getObjectSize` (F10);
   - for each object, hash its bytes `[obj, obj + size)` as 64-bit words, using a simple strong
     mix such as `h = (h ^ w) * 0x9E3779B97F4A7C15; h ^= h >> 29;` seeded with `size`;
   - push `{offset_q, size, hash, header.builder}`;
   - set `census_base_ = fromBase()`.

   This is exactly the survivor population. With `promotion_age = 1`, all of these objects are
   promoted, or die, at the next minor.
3. **Check.** At the start of the next `NurserySpace::minorGC`, immediately after
   `preEvacuationFromSpaceWalk()` and before any evacuation, for each entry:
   - `obj = census_base_ + (offset_q << 3)`.
   - If `builder` was set at record time, `++census_skipped_builder_` and continue. Builder
     objects are allowed to be written: HEAP_BUILDER_*.
   - Otherwise `++census_checked_`, recompute the hash over `size` bytes, and compare.
   - On a mismatch, `++census_mismatched_`. Find the first differing word by rehashing. For
     that, record per object not only the hash but also the first 8 words, or simply keep a copy
     of the object's bytes when `size ≤ 128` and fall back to "word unknown" (`word = 0xFFFF`)
     otherwise. Keeping copies of ≤ 128-byte survivors costs about 14 MB per minor.
   - Key the hit on `(tag, sub, word)`:
     - `sub = ctor` for `Tag_Custom`;
     - for `Tag_Closure`, `sub` = a 32-bit id interned from the `evaluator` pointer, with the
       `EvaluatorDesc::generic` function pointer (F12) remembered in `census_eval_addr_`;
     - `sub = 0` for other tags.
   - The census does **not** abort, and it does not repair anything.
4. Clear `census_` at the start of the record step. Guard: skip the check if `census_base_ !=
   fromBase()`, which would indicate a nursery resize or swap bug. Print one warning if that
   happens.
5. **Report.** From an `atexit` handler registered on enable, print to **stderr**:
   ```
   [survivor-write-census] checked=<n> mismatched=<n> skipped_builder=<n>
   [survivor-write-census]   tag=<name> sub=<ctor|evaluator-fn 0x...> word=<i> count=<n>   (top 50 by count)
   [survivor-write-census] anchor eco_alloc_custom=0x...   (for offline nm symbolisation of evaluator fns)
   ```
   Use `dladdr` on each evaluator function address as well. Print its `dli_sname` when available;
   statically linked binaries will usually need the anchor plus `nm` offline, the method already
   used for dispatch-stats rows.
6. **Unit test** in `test/allocator/NurserySpaceTest.cpp`, validate build only:
   - Enable the census through a test-access setter, not the environment variable, so other
     tests are unaffected.
   - Allocate a `Custom` with 2 boxed fields, root it, run a minor GC (it survives into to-space
     with age 1), then write a different value into field 1 *through the raw pointer*, and run
     another minor GC.
   - Assert `census_mismatched_ == 1` with key `(Tag_Custom, ctor, word = 2)`.
   - Also run a no-write control (`mismatched == 0`) and a builder-object control
     (`skipped_builder == 1`).
7. **Attribution (conditional).** Only if the census reports hits whose writer is not obvious from
   the tag, ctor or evaluator: add an `ECO_SURVIVOR_WRITE_TRAP=1` mode.
   - After the record step, `mprotect(PROT_READ)` the page-aligned interior of
     `[fromBase(), bump_.ptr)`: only whole pages, since the last partial page is shared with new
     allocation.
   - Install a `SIGSEGV` handler. On a fault inside the protected range, capture `backtrace()`
     (census-only, so async-signal-safety is knowingly waived), `mprotect(PROT_READ|PROT_WRITE)`
     the page, record `(page, first backtrace)`, and return.
   - Unprotect everything at the start of the next minor GC, before the check.
   - Transparent huge pages will be split by `mprotect`; this is a diagnostic mode only.
   - Write this as a sub-step of this plan only if it is needed. Otherwise record "not needed" in
     the baseline document.

### Step 12 — D7: the L3 co-runner interference experiment

**Files:** new `benchmarks/l3-corunner.cpp` and `benchmarks/l3-corunner.sh`. No runtime change.

1. `l3-corunner.cpp` (C++17, standalone, build with `g++ -O2 -o build/l3-corunner
   benchmarks/l3-corunner.cpp`) models the collector thread of design C (§7.4). It:
   - allocates a source arena of `--src-mb` (default 512) filled with 40-byte records linked into
     **one random cyclic permutation**, so every step is a dependent load, as in pointer-chasing
     GC work;
   - allocates a bump destination arena of `--dst-mb` (default 64);
   - loops over periods of `--period-ms` (default 59, the mean mutator epoch between minors). In
     each period it chases and copies `--objs` records (default 350,000, one minor's promotions),
     memcpy'ing each 40-byte record to the destination bump (wrapping at the end), then sleeps
     the remainder of the period. With `--duty 1.0` it never sleeps;
   - prints the achieved ns per object and the per-period busy fraction to stderr every 10 s.
2. `l3-corunner.sh` runs the self-compile (commands from `benchmarks/gc-opt-loop.md` §2, with the
   candidate binary from P§5) in three arms, **three cold runs each**:

   | arm | mutator | co-runner |
   |---|---|---|
   | A | `taskset -c 2` | none |
   | B | `taskset -c 2` | `taskset -c 10 build/l3-corunner` (defaults: collector-like duty) |
   | C | `taskset -c 2` | `taskset -c 10 build/l3-corunner --duty 1.0` (upper bound) |

   Record wall and the banner's **"True mutator"** time. The metric is **mutator slowdown =
   (true mutator B − true mutator A) / true mutator A**, and the same for C. Also record the
   co-runner's achieved ns per object: if it is far from ~40 ns, the model is not
   collector-like, and the result must say so.
   - Before choosing core ids, check `lscpu -e` so that cores 2 and 10 are distinct physical
     cores on the same socket (the box has 24 cores, no SMT).
   - Kill the co-runner at the end of each run: the script traps `EXIT`.
3. **Done when** the three arms have results recorded in the baseline document, with the noise
   band stated. The existing 2σ wall band is 5.3 s. The true-mutator band is unknown and must be
   estimated from arm A's three runs.

### Step 13 — D8: stale documentation fixes

These are text-only edits. Each one corrects a claim verified false on 2026-09-24 (report §14).

| File | Change |
|---|---|
| `THEORY.md:83` | "incremental marking driven by `MARK_WORK_RATIO`" → marking runs to completion inside the major pause (`finishMarkAndSweep`); `mark_work_ratio` is parsed but unused (`OldGenSpace.cpp:665-672`) |
| `THEORY.md:87` | `decommit_on_oldgen_release` is `true` (`AllocatorCommon.hpp:177`); the old corruption was carry-over mark bits, fixed by the `startMark` bitmap clear |
| `THEORY.md:65`, `:208-209` | `alloc_buffer_size` default 512 KiB; `promotion_age` default 1 |
| `NurserySpace.cpp:926-928` | the comment on `sweepNurseryLargeBodies`: it is skipped only while **compaction** is in flight, not during a major GC |
| `OldGenSpace.cpp`, `freeLargeBodyCell` `case GCPhase::Marking` | add a comment: unreachable, because `gc_phase_` is never set to `Marking`. Leave the code: phase 5a reworks this function |
| `GCStats.hpp` (the minor-timing comment) and the "Minor GC Timing" banner comment | state that the minor pause timer excludes the stack walk and the large-body sweep, and point to the new pause block |
| `design_docs/gc_handbook/12-concurrency.md` §12.10 table, `15-barriers.md:158` | add a note: SATB retains everything live at t0 and floats **more** garbage than incremental update. The summary's "none" is wrong |
| `THEORY.md` | new short subsection "GC instrumentation" listing `ECO_GC_PHASE_TIMERS`, `ECO_GC_EVENT_LOG`, `ECO_SURVIVOR_WRITE_CENSUS` and the three new banner blocks |

## 4. Gates

Run these in order after Step 13. They are correctness gates, run separately from any timed run.

| # | Gate | Command / check | Pass condition |
|---|---|---|---|
| G1 | Runtime unit tests | `cmake --build build --target test && build/test/test` | all pass, including `EnsureHeadroom*`, `GCPauseStats*` and the census test in the validate tree |
| G2 | Elm unit tests | `cmake --build build --target elm-tests` | same pass/fail set as the reference (13,565 pass / 12 pre-existing failures, `gc-opt-loop.md` §1) |
| G3 | E2E | `cmake --build build --target full 2>&1 \| tee /tmp/test_output.txt` (run **once**; CLAUDE.md) | 1731/1731 |
| G4 | GC-pressure stress | `ECO_HEAP_CONFIG=/work/benchmarks/heap-config-gc-pressure.json cmake --build build --target stress` | 100/100, **and** the banner shows ≳1,000 minor cycles. The default config runs zero, which would make the pass vacuous |
| G5 | Heap-validate tree | configure a second tree with `-DECO_HEAP_VALIDATE=ON`, build **both** `test` and `ecoc` (see `plans/gc-mark-and-bookkeeping-followup.md` §0); run G1 and G3 there | green; census active in G3 via `ECO_SURVIVOR_WRITE_CENSUS=1`, with its stderr summary saved |
| G6 | Parser compatibility | Run `benchmarks/lss-loop-extract.sh` and `heap-profile.py`'s `parse_summary` on (a) a reference stdout (`$BK/eco-optW13c-r1.stdout` if present, else re-run the reference once) and (b) the candidate's stdout. Load the module with `importlib.util.spec_from_file_location("hp", "heap-profile.py")`, then `hp.parse_summary(out, err, wall)` | every field both parsers extract is present in (b), and GC counter fields are **equal** between (a) and (b) |
| G7 | Release preset | `cmake --preset release && cmake --build <release dir> --target ecor` (or the release binary target used by `plans/static-link-eco-binary.md`) | builds; `.text` size of the runtime objects unchanged within noise, confirming the instruments compile away |
| G8 | Overhead | two timed triples (P§5): candidate with default env, and candidate with `ECO_GC_PHASE_TIMERS=0` | GC counters bit-identical in all six runs and equal to the W13c reference; the median GC-time difference between the two arms is within 2σ of the noise, or at most 1 % of GC time, whichever is larger. If not, reduce sampling rates (Step 7) or drop per-round drain timing (Step 5.3) and re-measure |
| G9 | Determinism + fixed point | the `cmp` commands of `gc-opt-loop.md` §2 on the six G8 outputs | all identical to `ecoghash.mlir` |

## 5. Baseline measurement (D9)

1. **Build the candidate** (runtime-only, F13):
   ```bash
   BK=build/compiler/build-kernel; BOOT=build/runtime/src/codegen/eco-boot-native
   cmake --build build --target eco-boot-native
   # CHECK the relink really happened: the target can no-op
   # (gc-opt-loop-results memory, trap 3)
   ls -l --time-style=full-iso build/runtime/src/codegen/CMakeFiles/EcoRuntimeStatic.dir/__/allocator/*.o | head
   $BOOT "$BK/bin/ecoghash.mlir" -o "$BK/bin/eco-optT00"
   ```
2. **Measure** with the Phase 2 loop of `benchmarks/gc-opt-loop.md` §2, `ARM=eco-optT00`,
   R = 1, 2, 3, adding `ECO_GC_EVENT_LOG=$PWD/$ARM-r$R.gclog.tsv` to the environment of each run.
   These three runs **also serve as the G8 "timers on" arm**.
3. **Validator census run** (G5 tree):
   - Lower `ecoghash.mlir` with the validate tree's `eco-boot-native` into `eco-optT00v`.
   - Run one self-compile with `ECO_SURVIVOR_WRITE_CENSUS=1`, which takes much longer than a
     normal run.
   - Save its stderr census summary and confirm `out.mlir` is byte-identical.
4. **Co-runner experiment:** Step 12.
5. **Write `benchmarks/threaded-gc-00-baseline.md`** with these sections:
   - **Reference.** Binary, MLIR, runtime snapshot name, date, machine.
   - **Pause distribution.** Count by kind; p50, p90, p99, p99.9, max; the log2 histogram; the MMU
     table. Give the median of 3 runs for scalar values and quote run r1's table.
   - **Minor-pause anatomy.** The `gc-event-log-summary.py --json` output for r1, and the phase
     shares as the median over 3 runs. Include the unaccounted residual; it must be < 2 %.
     Explicitly answer:
     - What share of the minor pause is promotion? Use `drain_promoted_ns` +
       `promo_alloc_est_ns` + `lazy_sweep_est_ns`. The report's derived estimate is 75–80 %.
     - What does a to-space copy cost vs a promotion, in ns per object?
     - How long is the stack walk, and how deep is the stack (mean/max frames)?
     - How much time goes to the CellStore scan (mean/max slots, ms)?
     - Where is the worst pause, and what is in it (the 20-worst table)?
   - **Survivor-write census.** Checked/mismatched/skipped, and the top rows with symbolised
     evaluators. Verdict for phase 7a: P1 holds, or a list of paths to fix.
   - **Co-runner interference.** Arms A/B/C, mutator slowdown with its noise band, and the
     achieved co-runner ns per object.
   - **Overhead.** G8 results.
   - **Implications for later phases** (prompts to answer; the answers feed the master plan's
     tracking table):
     - does the stack walk justify master-plan phase 8's stack watermark?
     - does the CellStore scan justify a dirty-chunk scan?
     - do the numbers confirm promotion as phase 6's and phase 7's target?
     - is the interference low enough for concurrent designs?
6. **Update** `plans/threaded-gc-master-plan.md` §4 tracking row 0 with the status, a link to the
   baseline document, and 3–5 one-line facts that later phases must know. Do not rewrite later
   phase descriptions.
7. Take snapshot `keep-T00` (`benchmarks/lss-loop-snap.sh snap keep-T00 "threaded-gc-00
   instruments"`) and copy `eco-optT00` into its `bin/`. Make `eco-optT00` the new
   `bin/eco-opt-prev`: it has the same MLIR and the same counters, plus the instruments, so later
   phases compare against it.

## 5a. Invariants

- Amend **HEAP_041** in `design_docs/invariants.csv`: `ensureHeadroom` defines headroom as 0 when
  `end < ptr`, so a clamp below the bump pointer means "must collect". This is the prerequisite
  for any future asynchronous doorbell (report §3.2).
- No other invariant changes. The census **measures** P1; phase 7a adopts it.

## 6. Traps (read before starting)

1. **`rc == 0` does not prove a run completed.** A SIGSEGV prints the banner and still exits 0.
   Verify `out.mlir` every time (`gc-sensitivity-sweep-sep22` memory).
2. **The stress suite at default config runs zero minor GCs.** Always use the GC-pressure config
   and read the cycle count (G4).
3. **`cmake --build build --target eco-boot-native` can no-op.** Check the object mtimes (P§5.1).
4. **The validate tree must build both `test` and `ecoc`,** or 12 Elm cases fail with exit 127
   and look like a codegen regression.
5. **Do not reorder root phases or anything in the drain.** Order changes to-space layout, and so
   mutator locality (Step 5.2).
6. **Missing `combine()` entries show as zero, not as a crash (F1).** After Step 10, sanity-check
   that the phase totals sum to the existing "Minor GC Timing → Total time" plus the stack walk
   and large-body sweep, within about 1 %.
7. **Sampled estimates are upper-biased by timer overhead (Step 7.5).** Present them as estimates.
8. **The census compares whole-object bytes.** A closure's unfilled capture slots are not zeroed
   (W1b), so they hold garbage. That is fine: garbage only mismatches if somebody writes it,
   which is exactly what the census is looking for.
9. **Run each timed triple on an otherwise idle machine.** The co-runner arms are the only runs
   where a second busy process is intended.

## 6a. As-built deviations (recorded during implementation, 2026-09-24)

1. **The object-level counters depend on the launch session, not on this phase.**
   - The recorded W13c reference (254,094,367 allocated / 675,767,765 promoted) was launched from
     an earlier session.
   - Re-run now, the *same* W13c binary gives 254,094,395 / 675,767,781, exactly what every T00
     run gives: seven runs, with and without `ECO_GC_EVENT_LOG` / `ECO_GC_PHASE_TIMERS=0`. The
     output path's form (absolute vs relative) moves them too; the first sanity run, with an
     absolute `--output`, gave 254,094,413.
   - The compiler reads its arguments and part of its environment into Elm values, so these are
     program inputs.
   - **Rule:** judge the strict counter gate against a reference re-run in the same session, with
     the same argument shape (`eco-optW13c-ctl` here). Cycle counts and promoted MiB were identical
     throughout.
2. **G7:** the `release` preset cannot be configured on this machine. The static musl toolchain is
   absent: `-lc++abi`, `libclang_rt.builtins` and `libunwind.a` are missing. This is pre-existing
   and unrelated to this phase. G7 instead used a stats-off tree
   (`cmake --preset build -B build-nostats -DECO_GC_STATS=OFF`) and checked with `nm` that
   `NurserySpace`, `ThreadLocalHeap` and `OldGenSpace` reference none of the new instrument
   symbols.
3. **Sampled estimates are overhead-corrected** rather than presented as upper bounds (P§3 Step
   7.5). `gcClockOverheadNs()` calibrates the empty-bracket cost once per process (the minimum of
   2000 back-to-back reads), and `sampledEstimateNs` subtracts it per sampled call. The banner
   prints the calibrated value.
4. **The per-scanner, pause and phase totals live in one nested struct**, `GCStats::tg`
   (`GCPhaseTotals`), with its own `merge()`. This replaces loose `_total` fields, so that
   `combine()`/`reset()` cannot miss a field (trap 6).

5. **Scanner names vs the LSS_022 kernel-license manifest.** Four registration sites live in files
   the manifest pins by hash: `Scheduler.cpp`, `MVar.cpp`, `Runtime.cpp` and `HttpExports.cpp`.
   Adding a name argument there broke `check-kernel-license-manifest.sh` at the first
   `--target full`. A proper re-audit means editing `KernelSetFacts.elm` evidence strings, which
   is compiler source, and would break this phase's byte-identical fixed point for a cosmetic
   label.
   - Those four files were restored byte-for-byte, and the manifest check passes.
   - `RootSet::addExternalRootScanner` labels any scanner registered without a name from its
     registration address (`__builtin_return_address(0)` + `dladdr`): a symbol when one resolves,
     otherwise `unnamed@+0x<offset>`, which `nm` resolves. The other five sites (not pinned) keep
     explicit names.
6. **Validator self-compile: the free-list duplicate-push scan is O(list length) per push.** It is
   capped at 10^6 steps, but the post-major sweep pushes millions of cells, so a heap-validate
   self-compile is days long. The first census run was stopped after 22 min, still in the first
   post-major sweep.
   - Added the validator-only opt-out `ECO_VALIDATE_FREELIST_DUP_SCAN=0`, which skips just that
     scan. Every other validator check stays on.
   - The census self-compile runs with it.
7. **G5 ordering trap.** The heap-validate test binary invokes the **main** tree's `ecoc` by
   relative path (`build/runtime/src/codegen/ecoc`). Running it while the main tree is being
   cleaned (`--target full`) fails 63 codegen tests with `ecoc: not found`. Run G5 only after the
   main tree is fully built.

8. **The instruments are compile-time opt-in (decided after T00, 2026-09-24).** P§1 rule 6's
   runtime kill switch is superseded.
   - Measured left-on in a stats build: **+1.52 s GC (+2.3 %)** (`benchmarks/gc-opt-loop.md`
     entry T00). The old env var `ECO_GC_PHASE_TIMERS=0` removed only about half of that.
   - The CMake option `ECO_GC_PHASE_TIMERS` (default OFF, requires `ECO_GC_STATS`, defines
     `ENABLE_GC_PHASE_TIMERS`) now gates the phase timers, promotion-path sampling, pause
     bracket and log, event-log writes and banner blocks. There is no runtime switch.
   - The census stays under `ECO_HEAP_VALIDATE`.
   - Always compiled: the scanner labels, stack-walk frame counters, the `GCPhaseTotals`
     types and the print-time statistics helpers (cold code, and used by the unit tests).

## 7. Out of scope

- Any change to GC policy, ordering, sizing or allocation. That starts in master-plan phase 1.
- Removing the dead `GCPhase::Marking` code (phase 5a) and the unused `mark_work_ratio` config
  field (leave it, to avoid breaking heap-config JSON files).
- An asynchronous safepoint doorbell. D1 only makes it possible later.
- Symbolising stack frames in the stack-depth counters. Counts are enough for this phase.
