# Plan: GC triggers for large-body allocation

Status: **draft** (2026-10-08). Follow-up to R7 in `plans/eco-system-websockets.md` (§8 and the §10
Integration entry). Touches `runtime/src/allocator/`: read `test/tla/README.md` and
`design_docs/invariants.csv` (HEAP_026, HEAP_034, HEAP_041, HEAP_042, HEAP_056, HEAP_062, HEAP_068)
before changing code.

## 1. Problem

A large `Bytes` or `String` (payload ≥ `large_header_split_threshold`, default 8 KiB) is a 16-byte
header in the nursery and a pinned body in the old generation (HEAP_026). The body is freed at the
end of the first minor GC that does not reach its header, so a short-lived large value is cheap,
**provided a minor GC runs**. Nothing makes one run:

- **G1. Minors ignore large-body bytes.** A minor runs when the nursery's clamped bump end is hit
  (`NurserySpace::computeAllocEnd`). A 16 MiB message costs the nursery 16 bytes. A program that
  mostly moves big buffers (an echo server, a file copy through Elm) allocates gigabytes of bodies
  between two minors.
- **G2. Major-GC work is paced by minors.** The major triggers are evaluated at minors
  (`ThreadLocalHeap::minorGC` → `evaluateMajorGCTrigger`). An incremental cycle advances one slice
  per minor (`stepMarkCycle`, 32 slices by default), and its pressure finish
  (`cyclePressureFinishDue`, 95% of the cap) is checked only there. Compiled code polls no
  safepoints (`__eco_safepoint_poll` is never emitted). A cycle that starts gets no further while
  minors are rare.
- **G3. No recovery when a body allocation fails.** `allocLargeByteBuffer` and `allocLargeString`
  assert when `allocateLargeBody` returns null. `allocateLargePinned` and `allocateYoungLarge` run
  a major GC and retry; the split allocators do not.

### Evidence

Native `WsEchoServer`, Autobahn group 13 in one process
(`/tmp/eco-p12j-autobahn-run2/logs/server-native-default.13.server.log`):

- **Allocation:** 5.3 GB allocated, but only **5 minor GCs** in the whole run.
- **Large bodies:** 4.7 GB freed at those 5 minors, with nothing deferred.
- **Majors:** a global-pressure trigger fired once, yet **0 major cycles completed**.
- **Old generation:** 20,480 MB in use at the end, 100% of the cap.
- **Result:** abort in `allocLargeByteBuffer` ("Failed to allocate large byte buffer body in old
  gen").

The native server and client each reached 7–8 GB RSS during groups 12 and 13; the JS server stayed
under 170 MB. WS6 measured the same effect at small scale: a loop dropping 1000 × 256 KiB `Bytes`
grows RSS by ~300 MB with no GC.

Large Strings take the same path, so string-heavy code is exposed too, not only eco/system
streams.

## 2. Goals and non-goals

Goals:
1. Dead large bodies are reclaimed within a bounded number of bytes of large allocation, whatever
   the program's nursery allocation rate.
2. A major cycle that has started keeps advancing under large-body allocation and finishes before
   the cap.
3. A body allocation that fails gets one minor GC, then one major GC, before it gives up.
4. No measurable cost on the Stage 7 self-compile (§6 gate).

Non-goals:
- Safepoint polls in compiled code.
- Changes to the split representation, the large-body sweep, or the mark protocol.
- Changes inside TLA-pinned regions, unless §4 step 1.2 finds one unavoidable.

## 3. Design

**D1. Direct-allocation debt.** `ThreadLocalHeap` keeps `direct_debt_bytes_`: bytes allocated
straight into the old generation since the last minor GC. It counts:
- split bodies (`allocLargeString`, `allocLargeByteBuffer`);
- young large objects (`allocateYoungLarge`, freed at minors);
- pinned large objects (`allocateLargePinned`). These are not freed by a minor, but counting them
  lets the major triggers be evaluated.

The counter is a plain per-heap field (one mutator thread per heap, HEAP_007). It is never shared,
has no atomics, and leaves the census pins unchanged.

**D2. Budget.** Add `HeapConfig::direct_alloc_minor_budget` (bytes; `0` disables; JSON key
`direct_alloc_minor_budget`). The default equals the nursery's minor threshold in object bytes
(`threshold_total_bytes_`), so a byte of large body weighs the same as a byte of nursery. Choose
the final default by measurement (§4 Phase 3), not by fiat.

**D3. Request a minor through the existing clamp.** When the debt reaches the budget, a new
`NurserySpace::requestMinor()` sets `bump_.end = bump_.ptr`. Every allocation path then misses at
an existing GC point and runs `minorGC()` there:
- the C++ `allocate` and `allocateSlow`;
- the compiled inline bump through `eco_alloc_inline_slow` (it reloads `bump.end` from the TLS
  bump state, HEAP_034);
- `ensureHeadroom` (HEAP_041: a miss means "the threshold tripped").

No new GC point is introduced. A minor recomputes `bump_.end = computeAllocEnd()`, which removes
the clamp. Because the minor runs `evaluateMajorGCTrigger` and `stepMarkCycle`, G2 is fixed by the
same change: minors now come at least once per budget of large allocation, so a cycle advances
and its pressure finish is checked at most one budget late.

**D4. Resetting the debt.** The debt belongs to a minor epoch: it resets when the heap's minor
count differs from the count at the last increment. That needs no edit to `TLH.minorGC`, provided
a monotonic per-heap minor counter exists outside the pinned region; §4 step 1.2 checks. If none
exists, increment one in `minorGC` and follow the canary procedure (AUDIT entries for M1, M4, M5,
M6, M8). The expected verdict is "no model change": a thread-local counter adds no shared state.

**D5. Recovery on body failure (G3).** In `allocLargeString` and `allocLargeByteBuffer`, a null
body is handled as follows:
1. Leave the null-bodied header as garbage. GC skips a null body; HEAP_026's null guards already
   cover this.
2. Run `minorGC()`. If the body still fails, run `majorGC(AllocFailure)`; if a cycle is in
   flight, finish it first with `finishMarkCycleNow(Pressure)`.
3. Restart the function from the header allocation.

The header-first ordering note stays true: no GC runs between a *successful* body registration
and its wiring. For the caller the call is still one GC point, as before, because the header
allocation already was one.

**D6. Caller audit.** `allocLargeByteBuffer(data, …)` and `allocLargeString(chars, …)` copy from a
raw pointer after GC points. Every caller must pass memory that a GC cannot move or free: a C++
buffer, or an old-generation body that the caller roots. The existing header allocation already
requires this, but nothing has checked it; D5 adds GCs, so audit every caller (`grep -rn
'allocLarge\(String\|ByteBuffer\)\|allocByteBufferBlank'`) and fix or document each one.

**D7. Telemetry.** Add `GCStats`:
- `minor_gc_direct_debt_triggers`;
- `direct_debt_bytes_total`;
- `large_body_alloc_failure_recoveries`, split by minor or major.

Print them in the Minor GC block.

## 4. Phases

### Phase 0: reproduce (red tests first)
- 0.1 Add an allocator test, `test/allocator/LargeBodyChurnTest.cpp`. With a small heap (old-gen
  cap 256 MB), allocate and drop 100,000 × 64 KiB byte buffers (6.4 GB), with no other nursery
  allocation.
  - It must complete with committed old-gen bytes bounded by cap × 0.5.
  - Today it should fail with the G3 assertion. Record that failure.
  - Add a variant with live retention (keep every 100th buffer, up to a bound) to exercise G2:
    majors must run and complete.
- 0.2 Add an Elm E2E test, `test/eco-system/src/LargeBytesChurnTest.elm`. Stream 4 GiB through
  Elm in 256 KiB chunks (`Stream` from a generated source, dropping each chunk) and check the RSS
  delta with `rssKiB`, following the pattern of `WebSocketStreamedMemoryTest`. Mark it SKIP-JS if
  the JS measurement is meaningless.
- 0.3 Take a baseline. Run the Stage 7 self-compile with GC stats and record:
  - large-placement bytes (`noteLargeAlloc` counters) and split-body bytes;
  - minors, majors, GC time and wall time.

  This bounds the extra minors D2 would add.

### Phase 1: debt and clamp (D1–D4, D7)
- 1.1 Add the `HeapConfig` field with validation (`> 0` or `0` for off), the JSON key, and a
  `HeapConfigJson` test.
- 1.2 Find or add the monotonic minor counter (D4). Decide the reset site; if it is inside
  `TLH.minorGC`, do the canary procedure.
- 1.3 Count the debt in the three direct paths and the two split allocators; call
  `nursery_.requestMinor()` when the debt reaches the budget.
- 1.4 Implement `NurserySpace::requestMinor()` in both legacy and region mode, covering
  `rg_->eden_base` and the region bump. It must be idempotent and must not fight `failSoftUnclamp`:
  a fail-soft unclamp after the requested minor is fine, because the minor resets the debt.
- 1.5 Add tests:
  - 0.1 passes, and its stats show `minor_gc_direct_debt_triggers > 0`;
  - an `EnsureHeadroomTest` case shows that a clamp requested between two `ensureHeadroom` calls
    yields exactly one minor and no loop;
  - inline allocation is covered by an E2E test that allocates large Bytes from compiled code
    (Phase 0.2 covers this).

### Phase 2: recovery (D5, D6)
- 2.1 Implement the retry loop in both split allocators, at most one minor and one major per call.
  Then fail with a clear message naming the cap and the debt.
- 2.2 Do the caller audit (D6); fix or annotate every call site.
- 2.3 Add tests:
  - a heap with a tiny cap and a pre-filled old generation of dead large bodies makes the next
    body allocation recover via the minor;
  - with live bodies it recovers via the major;
  - with everything live it fails with the message.

### Phase 3: workloads and tuning
- 3.1 Native Autobahn with all cases in one process (`test/conformance/autobahn.sh`, add a
  `--one-process` mode if needed). It must not crash, and server RSS must stay within a small
  multiple of the largest message. Record RSS for groups 9, 12 and 13.
- 3.2 Re-measure the WS6 loop (1000 × 256 KiB) and `WebSocketStreamedMemoryTest`. Tighten the
  latter's RSS bound if it now holds a lower figure.
- 3.3 Self-compile A/B against the Phase 0.3 baseline at the default budget and at 0.5× and 2× the
  default. Pick the default on wall time and GC time; document the choice next to the constant,
  in the house style of `AllocatorCommon.hpp`.

### Phase 4: documentation
- New invariant `HEAP_0xx DirectAllocDebt`: direct old-gen allocation bytes since the last minor
  are bounded by `direct_alloc_minor_budget` plus one allocation; reaching the budget clamps the
  nursery end, so the next allocation runs a minor.
- Extend HEAP_026 with the recovery path.
- Close R7 in `plans/eco-system-websockets.md` (§8 row and memory `eco-large-bytes-not-freed`).
  Revisit `autobahn.sh`'s per-subsection default.

## 5. Risks

| # | Risk | Mitigation |
|---|---|---|
| K1 | Extra minors cost the compiler time | Phase 0.3 / 3.3 A/B; the budget is configurable; minors with few survivors are cheap |
| K2 | The clamp interacts with hoisted headroom (HEAP_041) | A clamp only follows an allocation, which is already a GC point, so no hoisted run spans it; covered by the 1.5 test |
| K3 | A minor counter edit lands in a pinned region | D4 prefers an existing counter; otherwise the canary procedure with AUDIT entries |
| K4 | Recovery GC invalidates a caller's `data` pointer | D6 audit before D5 lands |
| K5 | Region-mode (threaded-gc-07) bump state differs | 1.4 implements and tests both modes |
| K6 | A large *live* working set still hits the cap | That is genuine exhaustion; D5 fails with a clear message instead of an assertion |

## 6. Gates

Run each once, tee to `/tmp`:
- `cmake --build build --target full`;
- the validate tree: `cmake --build build-validate --target test stress-test`, then the
  `--filter eco-system` and allocator runs with `ECO_NURSERY_POISON=1` and the gc-pressure config;
- the stress run (`ECO_VALIDATE_FREELIST_DUP_SCAN=0`);
- `TEST_FILTER=eco- … run-aot-e2e`;
- `tla-canary` with `ECO_TLA_CANARY_STRICT=ON`, plus `tla-check` for any model named in a new
  AUDIT entry;
- the self-compile A/B (§4 3.3).

No model checks in CI.

## 7. Open questions

1. Should pinned large objects (`allocateLargePinned`) count towards the debt? They are not freed
   by a minor; counting them only makes major triggers be evaluated sooner. Proposed: yes.
2. Should the budget be absolute bytes or a fraction of the nursery threshold? Proposed: bytes,
   defaulting to the threshold, because the nursery grows.
3. Should `autobahn.sh` return to one process per group once Phase 3.1 passes? Proposed: yes;
   keep per-subsection as an option.
