# Plan: GC triggers for large-body allocation

Status: **implemented 2026-10-08 (D1-D6, gates in §10); Phase 0.2 native RSS bound and Phase 3.1 blocked by bag-page fragmentation, see §10.** v2 was implementation-ready (2026-10-08). v1 was the draft; §11 is the review that
produced v2. Follow-up to R7 in `plans/eco-system-websockets.md` (§8, and the §10 Integration
entry).

**Read before coding:**
- `design_docs/invariants.csv`: HEAP_007, HEAP_026, HEAP_034, HEAP_041, HEAP_042, HEAP_062,
  HEAP_063, HEAP_068, HEAP_074.
- `test/tla/README.md`, "The canary". This plan touches no `TLA-REGION`; §6 says how to confirm
  that.
- `CLAUDE.md`: run each test command once, tee its output to `/tmp`, then grep.

## 1. Problem (verified in the tree, 2026-10-08)

A `String` or `Bytes` whose allocation size is at least `HeapConfig::large_object_threshold`
(8 KiB) uses the **split** form (HEAP_026):
- a 16-byte `Tag_LargeStringHeader` / `Tag_LargeByteHeader` in the nursery;
- a pinned body in the old generation.

The routing lives in `alloc::allocString` / `allocByteBuffer` / `allocByteBufferBlank`
(`HeapHelpers.hpp`). They call `ThreadLocalHeap::allocLargeString` / `allocLargeByteBuffer`, which
allocate the header with `allocate()` and then the body with `OldGenSpace::allocateLargeBody`.

The end of every minor GC frees the bodies whose headers it did not reach
(`OldGenSpace::sweepNurseryLargeBodies`). That happens in every phase except compaction. So a
short-lived large value is cheap, **provided minors run**. Three things stop them from running:

- **G1. Minors ignore direct old-generation bytes.**
  - A minor runs only when an allocation misses the nursery's clamped end
    (`NurserySpace::computeAllocEnd`).
  - The only other route, `ThreadLocalHeap::collectAtSafepoint`, is reached only through
    `__eco_safepoint_poll`, which compiled code never emits (the comment in
    `ThreadLocalHeap::isNurseryNearFull` says so).
  - A large body costs the nursery 16 bytes, so a program that mostly moves big buffers allocates
    gigabytes of bodies between two minors.
- **G2. Major work is paced by minors.** `ThreadLocalHeap::minorGC` evaluates the major triggers
  at its end (`evaluateMajorGCTrigger`). While an incremental cycle runs, each minor end is one
  cycle step instead (`stepMarkCycle`; HEAP_063: a cycle spans T + 1 minors, T =
  `incremental_mark_slices` = 32). The pressure finish (`cyclePressureFinishDue`, at
  `incremental_mark_finish_fraction` = 0.95 of the old-gen cap) is checked only in `stepMarkCycle`.
  With rare minors, a cycle that has started never finishes.
- **G3. No recovery when a body allocation fails.** `allocLargeString` / `allocLargeByteBuffer`
  assert on a null body. In an `NDEBUG` build the assert vanishes and the null pointer is then
  dereferenced. `allocateLargePinned` and `allocateYoungLarge` call `majorGC(AllocFailure)` and
  retry; the split allocators do not.

### Evidence

Native `WsEchoServer`, Autobahn group 13 in one process
(`/tmp/eco-p12j-autobahn-run2/logs/server-native-default.13.server.log`, GC stats at exit):

| Counter | Value |
|---|---|
| Bytes allocated (nursery and direct, total) | 5265 MB |
| Minor GC cycles | **5** |
| Large bodies freed at minors / deferred | 4720 MB / 0 MB |
| Global-pressure triggers | 1 (a cycle started) |
| Major GC cycles completed | **0** |
| Old-gen in use at the end | 20480 MB (100% of the cap) |

The run ended with an abort in `allocLargeByteBuffer` ("Failed to allocate large byte buffer body
in old gen").

Other measurements:
- The native server and client each reached 7–8 GB RSS during groups 12 and 13; the JS server
  stayed under 170 MB.
- WS6: a loop dropping 1000 × 256 KiB `Bytes` grows RSS by ~300 MB with no GC.

Any code that handles large Strings or Bytes is exposed. That includes every eco/system stream,
whose chunks are 64 KiB (`FileSystemOps.cpp` `kChunk`, `StreamPipe.cpp` `kPipeReadChunk`).

## 2. Goals and non-goals

Goals:
1. The bytes allocated straight into the old generation between two minors are bounded by a
   budget (§3 D2) plus one allocation, whatever the program's nursery allocation rate.
2. Because minors then happen, the major triggers are evaluated and a running cycle advances and
   pressure-finishes before the cap (G2 is fixed by G1's fix).
3. A body allocation that fails gets one minor and one major GC, then a clear fatal message
   (never an assert or a null dereference).
4. No measurable slowdown of the Stage 7 self-compile (§5 Phase 4).

Non-goals:
- Safepoint polls in compiled code.
- Changes to the split representation, the large-body sweep, the mark protocol or any
  `TLA-REGION`.

## 3. Design

**D1. Direct-allocation debt.** `ThreadLocalHeap` gets two plain fields:
- `direct_debt_bytes_`: bytes allocated straight into the old generation since the last minor;
- `direct_debt_seq_`: the `nursery_.minorSeq()` value that debt belongs to.

The debt resets lazily: when `nursery_.minorSeq()` differs from `direct_debt_seq_`.
`NurserySpace::minorSeq()` already exists. It is always on and is incremented at the start of
every minor in both nursery modes (`NurserySpace.cpp`, `++minor_seq_`). No GC code changes. HEAP_007
(one mutator per process) makes plain fields correct; there are no atomics, so the canary's census
pins do not change.

The debt counts four allocation paths:

| Path | What it allocates | Freed by |
|---|---|---|
| `allocLargeString` | split string body | a minor |
| `allocLargeByteBuffer` | split byte-buffer body | a minor |
| `allocateYoungLarge` | pointer-bearing large object (HEAP_062) | a minor |
| `allocateLargePinned` | pointer-free non-split large object | a major only |

Pinned objects are counted too: a minor does not free them, but it evaluates the major triggers,
which is what bounds them.

**D2. Budget.**

    budget = min( direct_alloc_minor_budget × nursery_.minorThresholdBytes(),
                  getOldGenMaxBytes() / 32 )

`direct_alloc_minor_budget` is a new `HeapConfig` field, a `double` multiplier with default 1.0;
`0` disables the mechanism. `minorThresholdBytes()` is a new accessor returning
`threshold_total_bytes_`, the nursery's own trip point in object bytes. Because it is read at
each check, it follows nursery growth.

The cap bound (1/32 ≈ 3%) is needed because of G2. A cycle pressure-finishes only at a minor
that sees committed ≥ 95% of the cap. With at most 3% of the cap between minors, at least one
minor falls inside the 95–100% window.

**D3. Requesting a minor.** `NurserySpace::requestMinor()` sets `bump_.end = bump_.ptr` when
`bump_.end > bump_.ptr`, and returns whether it changed anything. After that, every nursery
allocation misses into an existing slow path, which runs `minorGC()`:
- `ThreadLocalHeap::allocate` and `allocateSlow` (`nursery_.allocate` returns null);
- `allocateSlowRaw`, reached from compiled code's inline bump through `eco_alloc_inline_slow`.
  The expansion reloads `{ptr, end}` from `eco_bump_state()`, the address of this same
  `NurseryBump`, on every allocation (HEAP_034);
- `ensureNursery`, reached from `eco_ensure_nursery_slow`: `ensureHeadroom` fails when
  end − ptr < n (HEAP_041).

These facts make the clamp safe:
- Only nursery initialization, the end of a minor and `failSoftUnclamp` (called only right after
  a minor) write `bump_.end`. The clamp therefore lasts until the next minor, which recomputes
  `bump_.end = computeAllocEnd()`.
- The only validator check on the end is `assert(bump_.ptr <= bump_.end)` at the end of a minor,
  and `end == ptr` satisfies it.
- No new GC point is created: the clamp is set inside an allocating call, which already is a GC
  point. No hoisted headroom region can contain one, because `eco_ensure_nursery_slow` is "the ONE
  statepoint of a covered region" (`RuntimeExports.cpp`).
- There is no GC loop: after the minor, the next request needs another full budget of direct
  allocation.

**D4. Recovery (G3).** The split allocators become a loop of at most three attempts:
1. Allocate the header, then the body.
2. On a null body, abandon the header. It is unreachable garbage with a null `body`, which every
   GC path skips (HEAP_026's null guards). On the first failure run `minorGC()`; on the second
   run `majorGC(GCStats::MajorReason::AllocFailure)`. Count each in `GCStats`, the major also as
   `major_gc_alloc_failure_triggers`, as the sibling paths do.
3. Start again from step 1.
4. After the third failure, call a `[[noreturn]] largeBodyExhausted(kind, body_size)` that prints
   the size, the old-gen in-use bytes and the cap, then aborts. It follows the shape of
   `ThreadLocalHeap::regionTooLarge`.

`majorGC` already finishes a running cycle (`finishMarkCycleNow(Join)`), so no extra step is
needed. The header-first ordering note stays true: no GC runs between a *successful* body
registration and its wiring.

**D5. Callers keep the same contract.**
- `allocLargeString(chars, …)` and `allocLargeByteBuffer(data, …)` already copy from the caller's
  raw pointer after a GC point: the header allocation can run a minor, and that minor can chain
  into a major. The small-object paths (`eco_alloc_with_roots`, then the copy) do the same.
- D4 adds more GCs of the same kinds, not a new hazard. So instead of a call-site audit, write
  the contract on the four `HeapHelpers` entry points: `chars`/`data` must not point into the GC
  heap unless it is a rooted, pinned large body.

**D6. Telemetry.** Add `GCStats` fields, combined in `GCStats::combine`, zeroed in
`GCStats::reset` and printed in `GCStats::print`'s "Minor GC" block:

| Field | Meaning |
|---|---|
| `direct_debt_bytes_total` | bytes counted by D1 |
| `minor_gc_debt_requests` | `requestMinor()` calls that set a clamp |
| `large_body_recover_minors` | D4 first retries |
| `large_body_recover_majors` | D4 second retries |

All four are behind `ENABLE_GC_STATS`, like the other counters. The debt itself is not.

## 4. Implementation, file by file

**`runtime/src/allocator/AllocatorCommon.hpp`**
- Next to `MAJOR_GC_GARBAGE_FRACTION`, add the constant with a comment in the house style:

  ```cpp
  // Multiple of the nursery's minor-GC threshold (object bytes) that allocation made directly
  // in the old generation (split large bodies, young large objects, pinned large objects)
  // may reach before the next allocation runs a minor GC (0 disables). The effective budget is
  // also capped at 1/32 of the old-gen cap (plans/large-body-gc-trigger.md D2).
  constexpr double DIRECT_ALLOC_MINOR_BUDGET = 1.0;
  ```

- In `HeapConfig`, next to `major_gc_garbage_fraction`:
  `double direct_alloc_minor_budget = DIRECT_ALLOC_MINOR_BUDGET;`
- In `HeapConfig::validate()`, reject non-finite values and values outside `[0, 64]`, with the
  same throw style as its neighbours.

**`runtime/src/allocator/HeapConfigJson.cpp`**
- Add `"direct_alloc_minor_budget"` to the known-key list (the array that holds
  `"major_gc_garbage_fraction"`).
- Parse it with `parseDouble`, not `parseFraction`, which rejects values above 1; `validate()`
  does the range check.

**`runtime/src/allocator/NurserySpace.hpp`** (public section, near `minorSeq()`)

```cpp
// The proactive minor-GC trip point in object bytes (computeAllocEnd's threshold).
size_t minorThresholdBytes() const { return threshold_total_bytes_; }
// Make the next allocation on every path (allocate/allocateSlow/allocateSlowRaw, the inline
// bump, ensureHeadroom) miss into its slow path and run a minor GC, which re-derives
// bump_.end. Returns false if a miss was already due (end <= ptr).
bool requestMinor() {
    if (bump_.end <= bump_.ptr) return false;
    bump_.end = bump_.ptr;
    return true;
}
```

**`runtime/src/allocator/ThreadLocalHeap.hpp`**
- Private fields: `size_t direct_debt_bytes_ = 0;` and `uint64_t direct_debt_seq_ = 0;`.
- Public method (tests read it): `size_t directAllocBudget() const;`.
- Private methods: `void noteDirectAlloc(size_t bytes);`,
  `[[noreturn]] void largeBodyExhausted(const char* kind, size_t body_size);`.

**`runtime/src/allocator/ThreadLocalHeap.cpp`**

```cpp
size_t ThreadLocalHeap::directAllocBudget() const {
    const double f = config_->direct_alloc_minor_budget;
    if (!(f > 0.0)) return 0;
    size_t b = static_cast<size_t>(f * static_cast<double>(nursery_.minorThresholdBytes()));
    const size_t cap = parent_->getOldGenMaxBytes();
    if (cap != 0) b = std::min(b, cap / 32);
    return std::max<size_t>(b, 1);
}

void ThreadLocalHeap::noteDirectAlloc(size_t bytes) {
    const uint64_t seq = nursery_.minorSeq();
    if (seq != direct_debt_seq_) {   // a minor ran since the last note: the debt is paid
        direct_debt_seq_ = seq;
        direct_debt_bytes_ = 0;
    }
    direct_debt_bytes_ += bytes;
#if ENABLE_GC_STATS
    stats_.direct_debt_bytes_total += bytes;
#endif
    const size_t budget = directAllocBudget();
    if (budget != 0 && direct_debt_bytes_ >= budget && nursery_.requestMinor()) {
#if ENABLE_GC_STATS
        stats_.minor_gc_debt_requests++;
#endif
    }
}
```

- `allocateYoungLarge` and `allocateLargePinned`: call `noteDirectAlloc(size)` once the object
  exists, just before `return obj`.
- `allocLargeString` / `allocLargeByteBuffer`: wrap the existing body in
  `for (int attempt = 0;; ++attempt) { … }`. When the body is non-null, keep the existing fill
  and wiring, then `noteDirectAlloc(body_size); return header_hp;`. When it is null:

  ```cpp
  if (attempt == 0) { /* stats */ minorGC(); continue; }
  if (attempt == 1) { /* stats */ majorGC(GCStats::MajorReason::AllocFailure); continue; }
  largeBodyExhausted("byte buffer", body_size);   // "string" in allocLargeString
  ```

  Remove the two `assert(body && …)` lines, which the loop replaces. Extend the ordering comment
  in `allocLargeString`: a failed attempt abandons its header with a null body, and the retry
  starts from the header.
- `largeBodyExhausted`: `std::fprintf(stderr, "eco: out of memory: cannot allocate a %zu-byte
  large %s body (old generation %zu of %zu bytes in use after a minor and a major GC)\n", …);
  std::abort();` using `parent_->getOldGenCommittedBytes()` and `getOldGenMaxBytes()`.

**`runtime/src/allocator/GCStats.hpp` / `GCStats.cpp`**: the D6 fields (`uint64_t`, next to
`minor_gc_count`), each added to `combine`, `reset` and `print` (four lines in the Minor GC
block).

**`runtime/src/allocator/HeapHelpers.hpp`**: the D5 contract sentence on `allocString`,
`allocByteBuffer`, `allocStringBlank` and `allocByteBufferBlank`.

## 5. Phases

Every phase ends with its tests green. Run each command once, tee its output to `/tmp`, then
grep.

### Phase 0: reproduce, before any runtime change

**0.1** Add `test/allocator/LargeBodyChurnTest.{hpp,cpp}`, registered like
`OldGenCapacityTest` (`test/CMakeLists.txt` source list, `#include` and registration in
`test/main.cpp`). Heap config, following `capacityHeapConfig()`:
- `alloc_buffer_size = 64 KiB`, `nursery_block_count = 4` (a 256 KiB nursery);
- `initial_old_gen_size = 256 KiB`, `max_heap_size = 64 MiB`;
- defaults otherwise.

Allocate through `alloc.allocLargeByteBuffer(nullptr, 60 * 1024)`, the split path.
`alloc.allocate(…, Tag_ByteBuffer)` would take the pinned path instead.

Three cases:
- **(a) churn:** 20,000 buffers (1.2 GB), none kept. Pass: the loop completes and
  `alloc.getCurrentThreadHeap()->getNursery().minorSeq()` grows by at least 1.2 GB ÷ (2 ×
  budget), where budget = `alloc.getCurrentThreadHeap()->directAllocBudget()` (Phase 1). Before
  Phase 1 exists, only the abort matters.
- **(b) promoted garbage:** keep every 16th buffer in a rooted ring of 64 slots
  (`getRootSet().addRoot`), overwriting the oldest. The kept headers get promoted, so their bodies
  die old and only majors free them: about 75 MB of old garbage against a cap of a few tens of
  MB. Pass: completes. Completing at all proves majors ran.
- **(c) recovery only:** like (a) with `cfg.direct_alloc_minor_budget = 0`. Pass: completes. If
  stats are compiled, `large_body_recover_minors > 0`.

Before the fix, case (a) aborts the whole in-process test binary. Do **not** commit it red: run it
once against the unfixed runtime with a temporary `--filter` and record the abort in §10, then
continue straight to Phase 1 with the test in place.

**0.2** Add `test/eco-system/src/LargeBytesChurnTest.elm`:
1. Read `/dev/zero` with
   `System.File.readFileStream (Between { start = 0, end = 2147483647 })`: 2 GiB, 32,768 fresh
   64 KiB `Bytes` natively.
2. Drop each chunk; count the bytes.
3. Sample `rssKiB` (import `WebSocketTestHelp`) after the first 64 MiB and at the end.

CHECK lines:
- `read: 2147483648 bytes`;
- `rss growth under 512 MiB: True`;
- `-- EXIT: 0`.

Before the fix the second line should print `False` (expect about 2 GiB of growth). Record the
figure in §10. If `/dev/zero` cannot be opened through `readFileStream` on either backend, write
a 64 MiB temp file once and read it 32 times instead. JS stays enabled: V8's own GC bounds it.

**0.3** Take a baseline: Stage 7 self-compile, 3 runs. Create
`plans/large-body-gc-trigger/variants.json`:

```json
[{"name": "baseline", "overrides": {}},
 {"name": "budget_0", "overrides": {"direct_alloc_minor_budget": 0}}]
```

Run `./heap-profile.py sweep --variants baseline --label large-body-baseline` (built-in
baseline, before the key exists). From its GC stats, record:
- minors, majors, GC time and wall time;
- the "Large placement" counters (`stats_.lp`);
- the split-body bytes. To get those, add `direct_debt_bytes_total` first (Phase 1 step 1),
  then rerun this step. With `budget_0` the mechanism is off, so it measures debt without changing
  behaviour.

### Phase 1: debt and clamp (D1–D3, D6)

1. `GCStats` fields (D6).
2. `HeapConfig` and JSON key (§4). Add a case to `LargeBodyChurnTest.cpp`, copying the
   `mkstemp` + `applyHeapConfigJsonFile` round trip in `test/allocator/GCHelperTest.cpp`:
   - `{"direct_alloc_minor_budget": 2.5}` parses to 2.5;
   - `-1` and `100` make `HeapConfig::validate()` throw.
3. `NurserySpace::minorThresholdBytes()` and `requestMinor()`.
4. `ThreadLocalHeap::directAllocBudget()` and `noteDirectAlloc()`, called from the four paths.
5. Tests:
   - 0.1 (a) and (b) pass.
   - New `EnsureHeadroomTest` case, using `NurserySpaceTestAccess` (`NurserySpace.hpp`), as
     that file's cases do:
     1. `ensureHeadroom(n, 64)` holds.
     2. `n.requestMinor()` returns true; then `headroom(n) == 0` and `ensureHeadroom(n, 64)` is
        false.
     3. `Allocator::ensureNursery(64)` runs exactly one minor (`minorSeq` + 1), after which
        `headroom(n) >= 64` again.
   - New `LargeBodyChurnTest` case (d): with `direct_alloc_minor_budget = 0`, 1000 small
     allocations after many large ones run no extra minor. This proves the switch is off.
   - 0.2 passes natively.
6. Run `cmake --build build --target check` (C++ only) and confirm `full` is not needed yet: no
   Elm or MLIR change.

### Phase 2: recovery and contract (D4, D5)

1. The retry loop in both split allocators, `largeBodyExhausted`, and the assert removal.
2. The `HeapHelpers` contract comments.
3. Tests: 0.1 (c) passes. Manual check of the fatal path: a scratch program (under
   `/tmp/large-body/`) that keeps every buffer alive under the 0.1 config must print the
   `eco: out of memory` line and abort. Record its output in §10. In-process death tests would
   kill the test binary.

### Phase 3: workloads

1. Native Autobahn, all cases in one process: `test/conformance/autobahn.sh --mode both --backend
   native --no-split`. Pass: no program crashed in the summary. Record, from each server and
   client log's exit GC stats:
   - "Old-gen commit hiwtr";
   - "Minor GC cycles";
   - "Major GC cycles";
   - the new debt counters.

   Also record each program's peak RSS: read `VmHWM` from `/proc/<pid>/status` before the script
   stops it, or wrap it in `/usr/bin/time -v` via the script's build step.
2. Re-run `WebSocketStreamedMemoryTest` and the WS6 loop (1000 × 256 KiB). Tighten
   `WebSocketStreamedMemoryTest`'s RSS bound if it now holds a clearly lower figure (keep 2×
   headroom).

### Phase 4: tuning (the self-compile A/B)

1. Extend `variants.json` with `budget_0_5` (0.5), `budget_1` (1.0, the default) and `budget_2`
   (2.0).
2. Run `./heap-profile.py sweep --variants-file plans/large-body-gc-trigger/variants.json
   --label large-body-ab`. The default is 3 serial repeats per cell; compare the medians.
3. Accept the default (1.0) if its `mutator_pct` is within 1.0 point of `budget_0` and its wall
   time within 2%. Otherwise pick the smallest multiplier that is.
4. Record the table in §10 and the choice in the constant's comment.

### Phase 5: documentation and closure

- `design_docs/invariants.csv`:
  - add `HEAP_079;Runtime_Heap;DirectAllocDebt;enforced;…`: direct old-gen allocation since the
    last minor is bounded by the D2 budget plus one allocation; reaching the budget clamps the
    nursery end (`requestMinor`), so the next allocation on any path runs a minor GC; the debt is
    keyed by `minorSeq`.
  - In HEAP_026, replace the stale `large_header_split_threshold` with `large_object_threshold`
    and add the D4 recovery.
- `plans/eco-system-websockets.md`: mark R7 resolved, citing this plan; update memory
  `eco-large-bytes-not-freed`.
- `test/conformance/autobahn.sh`: keep the split default (it isolates crashes) and add a header
  line saying `--no-split` is now expected to pass natively.

## 6. Gates (after Phase 5)

Run each once, tee its output to `/tmp`:
- `cmake --build build --target full`;
- the validate tree: `cmake --build build-validate --target test stress-test`; then
  `ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=$PWD/benchmarks/heap-config-gc-pressure.json
  build-validate/test/test --filter eco-system`; then the same with the allocator tests' filter
  (`build-validate/test/test --help` lists the filter syntax; the new suite's name is
  `LargeBodyChurn`);
- `ECO_NURSERY_POISON=1 ECO_VALIDATE_FREELIST_DUP_SCAN=0 build-validate/test/stress-test -n 10`;
- `TEST_FILTER=eco- cmake --build build --target run-aot-e2e`;
- the same two validate runs again with `ECO_NURSERY_REGIONS=1` (region mode, K5);
- `sh test/scripts/check-tla-manifest.sh .` (strict when run by hand). It must pass unchanged,
  because no `TLA-REGION` was edited and no atomic or lock was added (census pins on
  `ThreadLocalHeap.*` and `NurserySpace.*`). If it fails, follow `test/tla/README.md` "When it
  fires"; never just update the hash.

No model checks in CI.

## 7. Risks

| # | Risk | Mitigation |
|---|---|---|
| K1 | Extra minors slow the compiler | Phase 0.3 / 4 A/B; the knob; minors with few survivors are cheap |
| K2 | The clamp breaks a headroom guarantee | No covered region contains a statepoint (D3); the Phase 1 `EnsureHeadroomTest` case |
| K3 | A GC loop | A request needs a full budget of new direct allocation after each minor (D3) |
| K4 | Recovery GCs invalidate a caller's source pointer | Same GC kinds as today (D5); the contract is written down |
| K5 | Region mode (threaded-gc-07) differs | `requestMinor` only touches `bump_`, shared by both modes; `minorSeq` counts both; §6 runs the allocator and eco-system validate filters once more with `ECO_NURSERY_REGIONS=1` |
| K6 | A live working set at the cap | Genuine exhaustion: D4 ends in a clear message |
| K7 | Debt counted for pinned objects causes useless minors | They make the major triggers be evaluated, which is what bounds pinned objects; the A/B shows the cost |

## 8. Out of scope, noted

- Freed body cells return to free lists, but committed pages are not necessarily decommitted, so
  RSS stays at its high-water mark. Phase 3 shows whether that matters; if it does, it is a
  decommit-policy follow-up.

## 9. Decisions taken (change them here if you disagree)

1. Pinned large objects count towards the debt (D1, K7).
2. The budget is a multiplier of the nursery threshold, not absolute bytes: it follows nursery
   growth and needs no per-machine tuning. It is capped by 1/32 of the old-gen cap for G2.
3. `autobahn.sh` keeps one process per group by default (Phase 5).

## 10. Progress log

**2026-10-08: D1-D6 implemented** (`ThreadLocalHeap.{hpp,cpp}`, `NurserySpace.hpp`,
`AllocatorCommon.hpp`, `HeapConfigJson.cpp`, `GCStats.{hpp,cpp}`, `HeapHelpers.hpp`,
`Allocator.hpp` test hook `oldGenReservationBytes`). HEAP_079 added, HEAP_026 amended.

- **Phase 0.1 red:** not run against an unfixed build (the runtime was edited first). The
  unfixed abort is on record from the stress suite the same day: `EcoSystemTransformChain -n 100`
  aborted in `allocLargeString` ("Failed to allocate large string body in old gen") with old-gen
  in use 21,474,492,416 of 21,474,836,480 B after 4 minors and 0 majors, while the old gen had
  only 3.03 GB allocated (see the fragmentation finding below).
- **Phase 0.1 / 1 tests:** `test/allocator/LargeBodyChurnTest.cpp`, isolated (forked) suite
  `LargeBodyChurn`: (a) churn, (b) promoted garbage, (c) recovery only, (d) budget 0 is off,
  (e) the knob. All pass. (c) asserts a recovery minor only when the old-gen ADDRESS range is
  the test's own: a body allocation fails at `nursery_offset`, which the first initialize fixes
  (first-init-wins), so after an earlier test reserved 24 GiB the reconfigured 32 MiB cap is only
  a trigger figure. `EnsureHeadroomTest` (f) `requestMinor` passes.
- **Phase 0.2:** `test/eco-system/src/LargeBytesChurnTest.elm` added. **Fails** natively: reads
  2 GiB but RSS grows 6,998,320 KiB. The debt itself works (AOT build of the test: 33 minors,
  33 debt requests, 2,048 MB direct, 2,007 MB of bodies freed at minors), but old-gen in use
  peaks at 16,387 MB for 2 GB of bodies. Cause (not this plan's mechanism): **bag-page
  fragmentation for bodies in (64 KiB, alloc_buffer_size)**. The largest size class is 64 KiB, so
  `sizeClass(65,552)` = NUM_SIZE_CLASSES; `allocateFromBagPage`'s step 1
  (`tryAllocateBySplittingLarger` from class 40) finds nothing, step 3 takes a fresh 512 KiB page
  per body and pushes its 448 KiB tail as 64 KiB-class cells, 16 B too small for the next body.
  8x the bytes per 64 KiB chunk (every eco/system stream chunk), 2x for 256 KiB bodies. Freed
  bodies return to the same too-small class. `allocateFromBagPage` is a TLA-REGION: a fix is a
  follow-up plan.
- **Phase 2:** recovery loop + `largeBodyExhausted`. Manual fatal check
  (`/tmp/large-body/KeepAll.elm`, every 64 KiB chunk kept, heap 64 MiB / nursery 256 KiB /
  alloc_buffer 64 KiB): `eco: out of memory: cannot allocate a 65544-byte large byte buffer body
  (old generation 33554432 of 33554432 bytes in use after a minor and a major GC)`, rc 134;
  224 debt requests, 1 recovery minor, 1 recovery major, 10 majors.
- **Phase 3.1 (Autobahn native `--no-split`):** NOT completed. The server cases ran to 13.1.4
  with ws-echo-server VmHWM climbing 1.6 -> 5.2 -> 9.8 -> 11.6 GB; the harness host (15 GB)
  ran out of memory and the run was stopped. No exit GC stats. Before the plan the same run
  aborted at the cap; the trigger alone does not bound it (see the fragmentation finding).
- **Phase 3.2:** `WebSocketStreamedMemoryTest` passes (KiB 0 / 2,048 both ways, bound 32 MiB);
  bound left as is. WS6-style scratch loop (`Bytes.Encode`-built 256 KiB chunks) is not
  representative: the encoder's nursery allocation runs minors itself (8 minors, 0 debt
  requests); it shows the 2x bag-page waste (old-gen peak 502 MB for 250 MB of bodies).
- **Phase 0.3 / 4 (Stage 7 self-compile A/B, 3 runs per cell, medians;
  `heap-profiles/ws-dev-01/2026-10-08T18-06-26Z__large-body-ab`):** the baseline cell was
  dropped (budget_0 = mechanism off stands in for "before"; same compiler MLIR in every cell):

  | cell | wall s | CPU s | RSS GB | minors / majors | GC s | mutator % |
  |---|---:|---:|---:|---:|---:|---:|
  | budget_0 | 72.88 | 105.25 | 6.532 | 1313 / 7 | 3.06 | 95.8 |
  | budget_0_5 | 73.22 | 105.69 | 6.524 | 1313 / 7 | 3.05 | 95.8 |
  | budget_1 (default) | 73.20 | 105.13 | 6.524 | 1313 / 7 | 3.05 | 95.8 |
  | budget_2 | 73.07 | 104.96 | 6.525 | 1313 / 7 | 3.05 | 95.8 |

  Direct old-gen bytes 547.94 MB per run, **0 debt requests in every cell**: the compiler never
  reaches the budget, so behaviour is identical (promoted bytes and output hash equal) and the
  wall spread is noise. Default 1.0 accepted.
- **TLA canary:** `sh test/scripts/check-tla-manifest.sh .` passes unchanged.
- **§6 gates (2026-10-08):**
  - `full`: JIT E2E 2,336 / 2,337; the one failure is `LargeBytesChurnTest` (bag-page
    fragmentation, above). `full` stops there, so `run-js-e2e` was run by itself: 158 / 158
    (2 skipped), `LargeBytesChurnTest` passes on JS.
  - validate tree, `ECO_NURSERY_POISON=1` + `heap-config-gc-pressure.json`: `--filter eco-system`
    160 / 160 (`LargeBytesChurnTest` passes under that config: its smaller alloc_buffer_size sends
    64 KiB bodies to dedicated large blocks, which are reused); `--filter LargeBodyChurn` 5 / 5
    after case (c) was cut from 20,000 to 2,000 buffers (it had timed out at 60 s: past the cap
    nearly every allocation recovers with a validated minor).
  - validate `stress-test -n 10` (`ECO_VALIDATE_FREELIST_DUP_SCAN=0`): 113 / 113.
  - the same two validate runs with `ECO_NURSERY_REGIONS=1`: 160 / 160 and 5 / 5.
  - `TEST_FILTER=eco- run-aot-e2e`: 173 / 174; the failure is `LargeBytesChurnTest` (as JIT).
  - default `stress` (-n 100): 112 / 113. `EcoSystemTransformChain` (aborted before) PASSES; the
    failure is `EcoSystemFileManySmall`, a 60 s timeout unrelated to this plan (10,000 files x
    100 cycles at ~2.5 s per cycle, thread hand-off bound; Node's fs is 2x slower per cycle).
  - TLA canary: passes unchanged.
- **2026-10-09:** the bag-page fragmentation that blocked Phase 0.2 and Phase 3.1 is fixed by `plans/large-object-space.md` (HEAP_080/HEAP_081); `LargeBytesChurnTest` now passes natively.
- **Status:** D1-D6 done and gated. Goals 2.1 (debt bounds direct bytes between minors), 2.2
  (majors run, cycles finish: case (b), KeepAll's 10 majors), 2.3 (recovery + clear message) and
  2.4 (no self-compile slowdown) are met. Not met: Phase 0.2's RSS bound natively and Phase 3.1
  Autobahn `--no-split`, both blocked by the bag-page fragmentation above (a follow-up plan:
  `allocateFromBagPage` is a TLA-REGION). `autobahn.sh` header left unchanged (`--no-split` does
  NOT yet pass natively).


## 11. Review log (v1 → v2, 2026-10-08)

| # | v1 said | Finding | v2 |
|---|---|---|---|
| A1 | `large_header_split_threshold` (8 KiB) | No such field; the split uses `large_object_threshold` (`HeapHelpers.hpp`); HEAP_026's text is stale | §1; Phase 5 fixes HEAP_026 |
| A2 | D5: finish a running cycle, then `majorGC` | `majorGC` already finishes a running cycle (`finishMarkCycleNow(Join)`) | D4: just `majorGC(AllocFailure)` |
| A3 | D4: maybe add a minor counter inside `TLH.minorGC` | `NurserySpace::minorSeq()` exists (always on, both modes) | D1 keys the debt on it; no pinned edit |
| A4 | D2: default "equals `threshold_total_bytes_`" as a config constant, and open question 2 answered "bytes" | A config constant cannot track a growing nursery; bytes vs fraction contradicted D2 | D2: multiplier of `minorThresholdBytes()`, read at each check |
| A5 | (missing) | With the budget near the nursery threshold and a small cap, a whole minor gap could jump from below 95% of the cap to 100%, missing the pressure finish | D2: cap at 1/32 of the old-gen cap |
| A6 | D6: audit ~30 callers of the source-pointer allocators | The header allocation can already run a minor that chains into a major, and the small paths copy after a GC point too; no new hazard | D5: document the contract instead |
| A7 | G3: "assert" | In `NDEBUG` builds it is a null dereference, not an assert | §1 G3; D4 always ends in a message |
| A8 | Phase 0.1: red test "fails today" | The test binary runs allocator tests in-process; an abort kills the run | Record the abort once, don't commit red |
| A9 | Phase 0.1 allocation path unspecified | `alloc.allocate(…, Tag_ByteBuffer)` takes the pinned path, not the split | 0.1 uses `allocLargeByteBuffer` |
| A10 | Phase 0.2 "generated source" | `patternSource` writes the same chunk value repeatedly: no fresh large allocation per chunk | 0.2 reads `/dev/zero` (fresh 64 KiB `Bytes` per chunk) |
| A11 | Phase 3.1 "add a `--one-process` mode" | `autobahn.sh --no-split` exists | Phase 3.1 uses it |
| A12 | 1.4 "both legacy and region mode, covering `rg_->eden_base`" | Both modes use the one `bump_`; the clamp needs no mode code | §4 `requestMinor` |
| A13 | Evidence "5.3 GB allocated, but only 5 minors" read as nursery bytes | The counter totals all allocation | §1 table wording |
| A14 | K2 rested on "an allocation is already a GC point" | True, and stronger: a covered region's only statepoint is `eco_ensure_nursery_slow` | D3 cites it |
| A15 | JSON parsing unspecified | `parseFraction` rejects > 1; multipliers up to 2 are needed for the A/B | `parseDouble` + `validate()` |
| A16 | K5 relied on the gc-pressure config for region mode | That config only sets `nursery_region_bytes` (HEAP_043 sizing); region mode is `ECO_NURSERY_REGIONS` | §6 runs region mode explicitly |
| A17 | Canary run with `ECO_TLA_CANARY=strict` | The script is strict by hand; the variable only knows `warn` | §6 command |
