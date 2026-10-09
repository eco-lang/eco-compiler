# Plan: run every heap on the region nursery; legacy only where a test asks for it

Status: **implemented** (2026-10-09; §5 log). v1 was written the same day. Follows threaded-gc-07 (`plans/threaded-gc-07-concurrent-tenuring.md`):
TG7d made the region nursery (HEAP_069/HEAP_070) the runtime default on 2026-09-28. The test
infrastructure was never moved over.

**Read before coding:**
- `design_docs/invariants.csv`: HEAP_024, HEAP_069, HEAP_070, HEAP_075, GC_DET_001.
- `test/tla/README.md` ("The canary", "When it fires"). Phases 1 and 4 may touch `TLA-REGION`
  code or the fork-arm expectations. Run `check-tla-manifest.sh` after each phase; any changed
  prefix needs an AUDIT.md entry in every named model before `--update` (GC_MODEL_001).
- `docs/options.md` §`nursery_regions` and the `initAllocator` paragraph (both change here).
- `CLAUDE.md`: run each test command once, tee to `/tmp`, then grep. `ulimit -c 0`.

## 1. Problem (verified 2026-10-09)

**P1. The main E2E gate tests the legacy nursery.** A temporary probe in `EcoRunner` logged the
resolved config of every JIT program (it was removed afterwards):

| run | programs | `nursery_regions` actually used |
|---|---|---|
| `build/test/test`, unfiltered (what `full` and `check` run) | 1,476 | **0 (legacy) in every one** |
| `build/test/stress-test` | 114 | 1 (region) in every one |

Mechanism:
1. `test/test` runs the in-process unit suites first.
2. `initAllocator` (`test/allocator/TestHelpers.cpp:54`) pins `nursery_regions = 0`.
3. Each E2E program runs in a child forked from that process (`test/ElmE2ETestBase.hpp:1103`).
4. The child calls `EcoRunner::reset()` (`runtime/src/codegen/EcoRunner.cpp:326`), which calls
   `AllocatorTestAccess::reset(alloc)` with **no config**. `Allocator::reset` keeps `config_`, so the
   child inherits whatever config the last unit test installed.
5. The child's `Allocator::initialize()` is then a no-op because the allocator is already initialized.

A `TEST_FILTER` that skips the unit suites gives region mode instead, so filtered and unfiltered
runs test different nurseries. The in-process JIT codegen tests (`test/codegen/CodegenIsolatedTest.hpp:180`)
use the same runner and the same `reset()`.

Consequence: the E2E gate has not covered the production minor GC (region eden, tenure job, shadow,
heal) since TG7d. Every "E2E N/N" since 2026-09-28 is legacy-mode coverage. The intermittent
`WebSocketEchoTest` corruption ("big echoed intact: False") has only been seen in these
inherited-legacy runs, and in the explicit legacy validate arm.

**P2. The unit suites test legacy by default.** About 650 `initAllocator` call sites in 47
files, most of which test kernels, strings, bytes or old gen rather than the nursery.

**P3. GC concurrency drivers default to legacy.** In `test/gc-heap-tsan/`, five drivers pin 0 and
one defaults to 0 (§3 Phase 4).

**P4. Auto silently falls back.** `HeapConfig::resolveNurseryRegions()` (`AllocatorCommon.hpp:1054`)
turns `nursery_regions = 2` into 0 whenever `regionIncompatibility()` returns a reason. A config
change, in production or in a test, can move a heap to legacy with no message.

**Already region (no change):**
- Production entry points:
  - `eco_entry.cpp:104` (every AOT executable, so `run-aot-e2e` too);
  - `ecoc.cpp:361`;
  - `eco_embed.cpp:190`;
  - `EcoRunner`'s first `initialize()` (`EcoRunner.cpp:237`);
  - `runtime/src/main.cpp:693` (its 2 GB config resolves to 1, checked).
- Test and benchmark drivers:
  - `test/eco-system-core/EcoSystemCoreTest.cpp:3487`;
  - `stress-test` (probe above);
  - `heap-profile.py`;
  - `compiler/cmake/bootstrap/build-kernel/heap-config.json` (auto, resolves to 1, checked).

## 2. Goal and rules

- Every heap runs `nursery_regions = 1` unless its code **explicitly** asks for 0.
- An explicit 0 is allowed only in tests whose subject is the legacy nursery itself, or the
  legacy-vs-region oracle (§3 Phase 3, list C).
- `nursery_regions = 2` (auto) never yields 0. An incompatible config is a **hard failure**: user decision 2026-10-09, "make this an assert failure, not a silent fall-back".
- E2E children always run the production config: compiled-in defaults plus the
  `ECO_HEAP_CONFIG`/env overrides, exactly as `Allocator::initialize` builds it.

## 3. Phases

Order: 1, 2 (gate), 3, 4, 5. Phase 2 first delivers the most value: it moves all 1,476 E2E
programs onto the production nursery with one function change.

### Phase 1: auto never falls back (P4)

1. **`AllocatorCommon.hpp` `resolveNurseryRegions()`:** auto with a non-null
   `regionIncompatibility()` throws `std::invalid_argument`. The message reads "nursery_regions = 2
   (auto): <reason>; set nursery_regions = 0 to run the legacy nursery". This is fatal in every
   build, not a debug-only assert: `Allocator::initialize` does not catch it, so a process with such
   a config terminates at startup with the reason, and tests can pin the throw.
   - Auto then resolves only to 1.
   - An explicit 0 is untouched.
   - An explicit 1 keeps its existing `validate()` throw (`AllocatorCommon.hpp:1342`).
2. **Callers that relied on the fallback must say `nursery_regions = 0`.** Find them by grepping
   for configs that set `old_gen_bitmap_alloc = false`, `promotion_age` outside 1..3, a large
   `large_object_threshold`, or a small `max_heap_size`/`nursery_region_bytes`, and that reach
   `resolveNurseryRegions` with auto. Known so far:
   - `RegionMinorTest.cpp:130-141`: the `autoc` case asserts auto → 0 with bitmap allocation off.
     Rewrite it to assert the throw and the message.
   - `ParallelMinorTest.cpp:96`, `IncrementalMarkTest.cpp:258` and `ParallelMarkTest.cpp:338` set
     `old_gen_bitmap_alloc = false`. They go through `initAllocator`, which pins 0 today. After
     Phase 3 they must use `initLegacyAllocator` or set 0 themselves.
   - `heap-profile.py` arms: none incompatible today (`D2_lot32K` is within the 64 KiB class + 8).
     Re-check when adding arms.
3. Unit test: every `regionIncompatibility()` reason, under auto, throws and names its reason, while
   explicit 0 with the same config succeeds.
4. Docs:
   - `docs/options.md` `nursery_regions` row: remove "otherwise auto falls back to legacy" (twice,
     including the `large_object_threshold` row).
   - Amend the HEAP_069 DEFAULT clause: "auto resolves to 1; an incompatible config fails
     initialization; 0 must be explicit".

### Phase 2: E2E children run the production config (P1)

1. **One builder for the production config.** Add `Allocator::environmentConfig()` (static): a
   default `HeapConfig`, then `applyHeapConfigFromEnv`, then `applyGcThreadEnv`, which is the
   sequence `Allocator::initialize` runs at `Allocator.cpp:258-263`. `initialize()` uses it, so the
   sequence exists once.
   - Watch for `helper_jitter_us_`, an out-parameter of `applyGcThreadEnv`: the builder must set
     it as `initialize` does.
2. **`EcoRunner::reset()` installs that config:** `AllocatorTestAccess::reset(alloc, &cfg)` with
   `cfg = environmentConfig()`. That path already resolves and validates (`Allocator.cpp:1218-1222`).
3. **A permanent guard, so this cannot regress silently.**
   - After `runner.reset()` in both E2E paths (`ElmE2ETestBase.hpp:747` and `:862`), fail the test
     with "E2E child is not on the region nursery" when
     `Allocator::instance().getConfig().nursery_regions != 1`.
   - The one exception is when `ECO_NURSERY_REGIONS=0` or `ECO_HEAP_CONFIG` asks for 0. That keeps
     the explicit legacy validate arm runnable.
   - Do the same in the in-process codegen JIT path (`CodegenIsolatedTest.hpp:199`).
4. **Negative control:** with the guard in place and `reset()` temporarily reverted, a filtered run
   that includes one unit suite and one E2E test must fail on the guard. Then restore `reset()`.
5. **Gate:** `cmake --build build --target full`, run once and teed. Expect new failures: this is
   the first time since TG7d that 1,476 programs run on the region nursery under the test harness.
   Each failure is a region-mode finding, not a regression from this phase. Triage it before
   Phase 3 and record it in §5.
   - Also run `WebSocketEchoTest` in a loop of 30 under the region validate build, with the
     word-diff diagnostic on, and record the result in §5.

### Phase 3: unit tests default to region (P2)

1. **`TestHelpers.cpp`:**
   - `initAllocator` stops pinning 0 and passes the config through, like `initRegionAllocator`
     today. Remove `initRegionAllocator`, or keep it as an alias and remove it at the end of the
     phase.
   - Add `initLegacyAllocator(cfg)`, which sets `nursery_regions = 0` and is the only place a unit
     test gets legacy.
   - `scaledHeapConfig` and `pressureHeapConfig`: check that each geometry is
     region-compatible. After Phase 1 an incompatible one throws instead of falling back, and must
     be resized (preferred) or moved to list C.
2. **List A: flip to region, these test no nursery mechanics.** Expect these to pass unchanged; any
   failure is a finding.
   - `test/kernel/KernelExportsTest.cpp` (16), `test/kernel/VirtualDomKernelTest.cpp` (9),
     `test/platform/PlatformServicesTest.cpp` (1).
   - `HeapHelpersTest` (53), `BytesOpsTest` (37), `StringOpsTest` (26), `RuntimeExportsTest` (25),
     `ListOpsTest` (20).
   - `SliceRepresentationTest` (19), `Utf8StringTest` (13), `ChunkedListTest` (10), `ElmTest` (7),
     `EcoApplyClosureTypedTest` (6).
   - `GenericApplyBoxingTest` (5), `WideObjectTest` (13), `WideObjectPinsTest` (6),
     `WideKindsTest` (5), `WideClosureTest` (5).
3. **List B: flip to region, but they assert GC timing or counts.** Some assertions will encode
   legacy timing: promotion at the first minor, from/to spaces, survivor bytes per minor. Rewrite
   each one against region semantics (promotion one minor later via the tenure job; HEAP_069's eden
   allotment keeps triggers and counters equal to legacy). Move a test to list C only if its
   subject really is legacy behaviour, and record each move here.
   - `AllocatorTest` (19), `OldGenSpaceTest` (27), `GCPressureTest` (21), `ConcurrentMarkTest` (20),
     `IncrementalMarkTest` (24).
   - `ParallelMarkTest` (13), `GCHelperTest` (12), `LargePtrPlacementTest` (15),
     `OldGenBitmapAllocTest` (9), `P1CensusTest` (9).
   - `OldGenCapacityTest` (8), `TriggerPacingTest` (8), `EnsureHeadroomTest` (7),
     `OldGenSmallClassBudgetTest` (6), `OldGenLazySweepTest` (5).
   - `OldGenSweepBudgetTest` (4), `OldGenSweepOnDemandTest` (4), `TenureGrantTest` (4),
     `LargeObjectSpaceTest` (4), `LargeBodyChurnTest` (4).
   - `FreeListBackLinkTest` (1), and the 19 legacy sites of `ConcurrencyRegisterTest`.
4. **List C: stay legacy, via `initLegacyAllocator`.** These are the small set of tests whose
   subject is the legacy nursery.
   - `NurserySpaceTest` (13), `NurseryContiguityTest` (8: semi-space shape, `promotion_age = 3`),
     `NurseryFillerTest` (5), `PromoBufferTest` (3), `ParallelMinorTest` (5: the phase-6 legacy
     parallel minor).
   - Review each test. Any that holds for the region eden too gets a region twin.
   - `TenureAgeingTest.cpp:102`: the legacy arm of the legacy-k == region-k oracle.
   - The bitmap-off rejection tests of Phase 1 step 2.
5. **Risk R1: tenure collector threads in the test process.** In-process unit tests will now leave
   a region heap with tenure collector threads alive before the E2E forks. Fork safety relies on the
   registered fork hooks (`gc::registerForkLayer(kForkAllocator, ...)`, threaded-gc-03 pthread_atfork).
   Phase 2's `reset()` makes each child rebuild its heap anyway. Run `full` and check there are no
   hangs at fork. Any hang is a fork-hook bug, and fixing the hook is in scope.
6. **Docs:** update the `docs/options.md` paragraph "`initAllocator` also pins
   `nursery_regions = 0`", and the TG7d memory note.
7. **Gate:** `build/test/test`, filtered to the unit suites, then `full`, each run once and teed.

### Phase 4: GC concurrency drivers (P3)

| file | today | change |
|---|---|---|
| `test/gc-heap-tsan/heap_driver.cpp:215` | 0 unless `regions` | default 1; a `--legacy` flag for 0 |
| `test/gc-heap-tsan/fork_harness.cpp:196,227` | `regions = false` (on only in arms `:606`, `:1004`) | default true; legacy arms explicit |
| `test/gc-heap-tsan/tiny_graph.cpp:230` | 0 | 1 |
| `test/gc-heap-tsan/cr012_two_heap.cpp:47` | 0 | 1 |
| `test/gc-heap-tsan/promo_sweep.cpp:194` | 0 ("legacy parallel minor") | add a region arm; keep the legacy arm only if it covers something the region eden evacuation does not (same phase-6 engine) |
| `test/gc-heap-tsan/ylos_sweep.cpp:215` | 0 ("legacy parallel minor") | as `promo_sweep` |
| `test/gc-heap-tsan/tiny_tenure.cpp:143` | 1 | none |

- `run_fork_arms.py` / `fork_arms.txt` and the register-guards expectations change with the
  defaults. Re-derive each expected verdict; never copy one across.
- If a driver change alters any `TLA-REGION` prefix or a model-referenced scenario, add the AUDIT.md
  entry in each named model first (GC_MODEL_001).
- **Gate:** `register-guards` (strict), the heap-TSan scenarios, `tla-canary` (strict).

### Phase 5: close-out

- `design_docs/invariants.csv`: HEAP_069 (Phase 1). Add a row stating that E2E children run
  `Allocator::environmentConfig()` (Phase 2 guard).
- Memory: update the TG7d and E2E-legacy notes. Mark the old "E2E N/N" baselines as legacy-mode.
- **Out of scope, but note it:** `compiler/cmake/bootstrap/build-kernel/heap-config.json` lags the
  compiled-in defaults (`shadow_granule_log2` 3 vs 4, `major_gc_live_budget` 4.5 vs 3.0,
  `nursery_max_block_count` 384). It is not a legacy issue (it resolves to 1), but docs/options.md
  claims it is regenerated from the defaults.

## 4. Final gates (batched at the end)

`full` (C++ E2E + JS), `stress`, AOT E2E, elm-tests, validate build (unit + E2E + stress) in region
mode, plus the explicit legacy arm for list C only. Also `register-guards`, `tla-canary` (strict),
the kernel-licence check, and the bootstrap (4b/8c/9b fixed points). The self-compile benchmark is
unaffected: the compiler binary already runs region mode.

## 5. Log

### Phase 1 (done)
- `HeapConfig::resolveNurseryRegions()` throws on auto with an incompatible config. The message is
  "nursery_regions = 2 (auto): <reason>; set nursery_regions = 0 to run the legacy nursery".
- **User request, mid-implementation:** GC pressure tests should run a heap "just big enough" for the
  region nursery. Added `HeapConfig::minRegionHeapBytes(slots = 1)`, which is
  `2 x slots x regionExtents() x regionStrideBytes()` on a small heap.
  `regionIncompatibilityMessage()` now names that minimum when a slot is missing, in both the auto
  throw and the explicit-1 throw. The stride comes from `nursery_max_block_count`, so a pressure
  test pins the maximum to its small `nursery_block_count`.
- `RegionMinorTest` pins every reason under auto (bitmap allocation off, LOT 128 KiB, no heap slot,
  `promotion_age` 4). It also pins explicit 0 on the bitmap-off config, and the tight-heap sizes
  (one slot at exactly the minimum, two at `minRegionHeapBytes(2)`, none one buffer below).
- Docs: `docs/options.md` (three rows); HEAP_069 amended.

### Phase 2 (done)
- `Allocator::environmentConfig(base, jitter)` is the one builder. `initialize()` uses it, and
  `EcoRunner::reset()` re-installs it with `HeapConfig()` as the base.
- `test/RegionNurseryGuard.hpp` (`eco_test::requireRegionNursery()`) runs after `runner.reset()` in
  both `ElmE2ETestBase.hpp` paths and in `CodegenIsolatedTest.hpp`.
- **Negative control:** with `reset()` reverted, `test --filter Kernel` (unit tests plus 6 E2E
  programs) failed 6/18 on the guard. Restored, it passed 18/18.
- **Gate:** `full` 2,369/2,369 and JS 162/162, the first unfiltered E2E run on the region nursery
  since TG7d. No new failures.
- **WebSocketEchoTest:** 30 runs of the region validate eco-system suite under the GC-pressure
  config. Every run reported `big echoed intact: True`; the results are at the end of this log.

### Phase 3 (done)
- `initAllocator` passes the config through. `initLegacyAllocator` is the only route to legacy.
  `initRegionAllocator` is gone, and its 36 call sites became `initAllocator`.
- `promoteToOldGen` is mode-aware (region: `promotion_age + 2` minors). New `tenureMerge(alloc)` runs
  the merging minor on region and does nothing on legacy.
- **Geometry is first-init-wins** (`Allocator::rebuildNurserySliceTable`). A filtered run whose
  first test had a tiny heap left CR-025's default config no region slot ("heap slots exhausted",
  process abort). `initAllocatorWith` now always reserves with the default `HeapConfig()`, which is
  what an unfiltered run's first test did anyway. Each test's config still applies through `reset()`.
- **First region run:** 90 unit failures. Triage:
  - **Geometry too small for a slot** (21): `nursery_max_block_count` defaulted to 384 while the test
    used 4 blocks. Pinned the maximum to the block count in OldGenCapacityTest, OldGenSweepBudgetTest,
    LargeBodyChurnTest, LargeObjectSpaceTest and three ConcurrencyRegister configs. Pressure is
    unchanged.
  - **Legacy promotion timing** (about 50): `oldInt` (IncrementalMark) and the graph builders
    (ConcurrentMark, ParallelMark) now call `promoteToOldGen`. AllocatorTest `runFullGCCycle` and the
    split-header promotion test do the same. The 04b YLOS tests (LargePtrPlacement) and the 05a
    deferred-free and YLOS-in-place tests use `tenureMerge`. No assertion was weakened; each now waits
    for the region merge.
  - **Bitmap allocation off** is the legacy old gen, which only the legacy nursery runs. Those arms
    ask for 0 explicitly: OldGenBitmapAllocTest D1b's off arm, and CR-029 and CR-033's legacy arms.
  - **Allocate-black negative control (05a):** the hook removes the legacy promotion path's
    allocate-black, so it runs `initLegacyAllocator`. The region tenure grant's allocation bit is the
    mark, and its own negative control is TV5 (ConcurrentTenureTest).
- **List C (legacy, explicit):** NurserySpaceTest, NurseryContiguityTest, NurseryFillerTest,
  PromoBufferTest, ParallelMinorTest, TenureAgeingTest's legacy oracle arm, and the arms above. The
  region eden, tenure, ageing and parallel tenure engine are covered by RegionMinorTest,
  ConcurrentTenureTest and TenureAgeingTest.
- **Gate:** unit+E2E `build/test/test` 2,368/2,369. The one failure, `HttpsGetTest`, came from a run
  overlapping another test binary (see the trap below); alone it passes 3/3.

### Phase 4 (done)
- `heap_driver.cpp`: `scenario(..., regions = true)` by default. Scenarios 1-5 and 10 and all nine
  `kDefaultList` arms now run region. The TLA+ trace scenarios keep their explicit `legacy-*` names.
- `fork_harness.cpp`: `Opts::regions = true` by default. `det-cr004` is pinned to legacy
  explicitly; see finding F1.
- `cr012_two_heap.cpp`: region.
- `promo_sweep.cpp`, `ylos_sweep.cpp`: legacy, explicitly. Their routes (parallel promotion into
  blocks a pending lazy sweep owns; CR-019's mixed-block YLOS sweep) exist only on the legacy minor.
  M4 AUDIT entry written; manifest updated (comment-only change).
- `tiny_graph.cpp` (M1 trace b): tried on region and reverted exactly (hash unchanged). M1's
  tiny-graph hooks log only the legacy minor's writes, so the merge rejects a region log ("values
  read but never written"). The region tenure path has its own traced counterpart (`tiny_tenure.cpp`,
  TraceTenurePause).
- **Gates:**
  - heap-TSan default run: PASS, all region.
  - `register-guards` (strict): unit and validate guards ok. Harness arms: 19 PASS, 2 RETIRED,
    1 WONTFIX and 1 ERROR (`det-cr004`, exit 4). After the F1 pin, `det-cr004` passes (closed 3/3).
  - `tla-trace --model M1`: 20/20 as expected.
  - `tla-canary`: green.

### Findings
- **F1 (open):** on the region nursery, no minor relaunches a fork-stopped background mark episode
  on the gang `det-cr004` watches. The arm reports `no-relaunch` across the whole cycle, at T = 6
  and at T = 32. The cycle still closes normally at T + 1 because the closing step drains the
  deques, so this is about pause length, not correctness. It may be benign (the work drained
  another way) or a real gap in `runCycleStepConcurrent`'s relaunch path on region heaps.
  Investigate before relying on concurrent marking across forks in region mode.
- **Trap (test harness):** `TestServerConfig.hpp` binds an ephemeral port per run, rewrites the
  shared generated `TestServerConfig.elm` and touches the test sources. Two test binaries at once
  (for example `build/test/test` and `build-validate/test/test`) overwrite each other's port, and the
  HTTP/WebSocket tests then fail with "unexpected response". The ~220 source timestamps that changed
  at 14:19 were this, not an external sync. Never run two test binaries concurrently.
- **WebSocketEchoTest, region vs legacy** (`build-validate/test/test --filter eco-system`,
  `ECO_HEAP_CONFIG=benchmarks/heap-config-gc-pressure.json`, `ECO_NURSERY_POISON=1`):
  - **Region:** 30/30 runs report `big echoed intact: True`.
  - **Legacy** (`ECO_NURSERY_REGIONS=0`): the corruption reproduces in **10/10** runs
    (`big echoed intact: False`), and `WebSocketDeflateBombTest` times out in 10/10.
  - The open corruption is therefore **legacy-nursery-only**, and now has a reliable reproduction.
    Every earlier sighting ran legacy, either explicitly or through the inherited-config defect of §1.
    Open finding **F2**.
- **F3 (open):** `HttpServerHttp2LimitsTest` fails in about 7 of the 30 region suite runs (curl 92,
  "Stream error in the HTTP/2 framing layer", before the 431 is read). Legacy: 0/10. Alone it passes
  6/6 in both modes. This looks like a timing race in the test or the HTTP/2 server that region
  timing makes more likely, not a heap fault (no validator fired).
