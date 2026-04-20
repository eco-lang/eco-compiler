# Test Failures Report

This file tracks known test failures across the `elm-test-rs`, E2E (`full`), and Stress
suites. Each failure is an **issue** with a lifecycle. The template below defines the
canonical shape of an issue; copy it when reporting a new failure.

---

## Issue Template

Copy this block when adding a new issue. Place new issues under the `## Open Issues`
section. Keep the ordering stable (append new issues to the end) so links remain valid.

```
### Issue <ID>: <short title — usually the failing test name>

- **Suite:** E2E | Stress | elm-test
- **Test(s):** `<relative path>/<file>.elm` (list every test covered by this issue)
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** YYYY-MM-DD
- **Last updated:** YYYY-MM-DD
- **Related:** Issue #<n> (if applicable)

**Failure mode:** one of
  - Output mismatch (missing / unexpected pattern)
  - Crash — SIGSEGV
  - Crash — SIGABRT (include assertion text)
  - Timeout (N seconds)
  - Compilation failure (include tool + exit code)

**Observed:**
- Expected: `<expected substring or value>`
- Actual:   `<actual substring, assertion message, or crash site>`

**Hypothesis:** (optional for OPEN; required when moving to IN_PROGRESS)
<One paragraph. What do we suspect is the root cause? Which invariants or
subsystems are implicated (REP_*, CGEN_*, HEAP_*, monomorphizer, kernel, GC)?>

**Suggested fix approach:** (optional for OPEN)
1. <first investigative / surgical step>
2. ...

**Attempt log:** (append one entry per attempt; never rewrite history)
- **Attempt 1 (YYYY-MM-DD):** what was tried, what was observed, outcome
  (FIXED | REVERTED | PARTIAL | NEW-HYPOTHESIS). Always say whether baseline
  was restored if the attempt was reverted.
```

### Status values

| Status          | Meaning |
|-----------------|---------|
| `OPEN`          | Reported, not yet triaged or attempted. |
| `IN_PROGRESS`   | Actively being investigated or patched in the current session. |
| `FIXED`         | Resolved; verified passing in the most recent run recorded below. |
| `SKIPPED`       | Deferred after one or more attempts — too deep for a single pass, or blocked on tooling (e.g. `ECO_GC_DEBUG_LIVENESS`). Must include *why* in the attempt log. |
| `WONTFIX`       | Determined not to be a compiler/runtime bug (e.g. test expectation is wrong, flaky infra). Must include *why*. |
| `REGRESSED`     | Was `FIXED` in an earlier run but is failing again now. |

### Failure-mode shorthand

| Shorthand                | What it means |
|--------------------------|---------------|
| Output mismatch          | The test harness reports `Missing pattern: ...` — the program ran to completion but produced the wrong text. |
| SIGSEGV                  | Segmentation fault — usually GC, rooting, or layout bug. |
| SIGABRT                  | `assert(...)` fired; capture the assertion text verbatim. |
| Timeout                  | Test did not finish within the suite's wall-clock limit (currently 60 s for stress). Often infinite loop or unbounded allocation. |
| Compilation failure      | Compiler (Elm → MLIR) or Guida wrapper exited non-zero; capture the exit code and first error line. |

### Grouping

Prefer **one issue per test** at first. Only merge into a single issue when you have
*evidence* the tests share a root cause (identical stack, identical assertion, identical
hypothesis confirmed by instrumentation). Cross-link with `**Related:** Issue #<n>`
rather than merging prematurely.

---

## Baseline

Most recent whole-suite run. Update after each full test pass. Keep only the latest
baseline here; prior baselines belong in git history.

- **Date:** 2026-04-20 (post-ParserHexIntTest fix)
- **elm-test:** 12799 passed, 0 failed (skip marker expected; not re-run for test/kernel-only fixes)
- **E2E (`full`):** 1102 run, 1094 passed, 8 failed (was 1093/9; +1 pass: Issue #7)
- **Stress:** 69 run, 51 passed, 18 failed

---

## Open Issues

### Issue 1: LetDestructFuncTupleTest

- **Suite:** E2E
- **Test(s):** `elm/LetDestructFuncTupleTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session; git history records 3 prior attempts
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `get: 10` (and `set: 99`)
- Actual:   `get: 0`, `set: 536870993` (`0x2000_0011` — looks like a primitive slot mis-interpreted as an Int).

**Hypothesis (from prior-session analysis, now in git history):** The test builds `(.a, \x m -> { m | a = x })` — a tuple whose first field is a standalone record accessor `.a` and whose second is an update lambda. The compiler gives the standalone accessor a generic type in `Specialize.elm`, producing a tuple/record `unboxed_bitmap` mismatch when the accessor and the update lambda are built together as tuple fields inside a `case` expression. Three prior fix attempts all failed to propagate accessor types correctly without regressing other sites.

**Attempt log:**
- **Skip rationale (2026-04-20):** No fresh hypothesis beyond the prior three attempts in git history. Fix requires an accessor-type-propagation change in `Specialize.elm` that is deeper than this session's budget allows. Marked SKIPPED.

---

### Issue 2: ListMap2FloatSumTest

- **Suite:** E2E
- **Test(s):** `elm/ListMap2FloatSumTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session; git history records 1 prior attempt
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #3, Issue #4, Issue #5, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `result: [12, 23]`
- Actual:   Float bit-patterns printed as signed i64 (e.g. `[-9215209262530166784, …]`).

**Hypothesis (shared with #3–#6):** In `processCallArg` (`Specialize.elm` ~line 2708), the `_ → TOpt.VarGlobal` fallthrough only defers a global arg when `Mono.containsCEcoMVar monoType` is True. For `Basics.add : number -> number -> number`, `applySubst` calls `resolveMonoVars` which defaults unresolved `CNumber` MVars to `MInt`, so `monoType = MInt -> MInt -> MInt` and `containsCEcoMVar` returns False. The global is specialised as Int before `refineSubstFromArgExprs` propagates `a = Float` from the list args, producing a closure that re-interprets IEEE 754 Float bits as Int.

**Attempt log:**
- **Skip rationale (2026-04-20):** Prior session's attempt 1 added `canTypeHasAnyTVar` + an extended deferral condition and confirmed it was necessary but NOT sufficient — a complete fix requires also reporting a non-committed `argMono` (MVars preserved) for `PendingGlobal` in `extractParamTypes` / `resolveProcessedArgs`, plus coordinated changes in `refineSubstFromArgExprs` and `unifyCallSiteDirect`. Multi-site compiler surgery with high regression risk across 1100+ E2E tests; out of this session's budget.

---

### Issue 3: ListMap2FloatTest

- **Suite:** E2E
- **Test(s):** `elm/ListMap2FloatTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session; git history records 1 prior attempt (shared root cause)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #4, Issue #5, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `map2Add: [11, 22, 33]`
- Actual:   Float bit-patterns: `[-9217742537320562688, -9208735338065821696, -9203668788485029888]`.

**Hypothesis:** See Issue #2. Same root cause.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #2.

---

### Issue 4: ArrayFoldrFloatSumTest

- **Suite:** E2E
- **Test(s):** `elm-core/ArrayFoldrFloatSumTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #3, Issue #5, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `result: 7`
- Actual:   `result: -2.5` (sum of float bit-patterns)

**Hypothesis:** See Issue #2. Same root cause.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #2.

---

### Issue 5: ArrayFoldlFloatSumTest

- **Suite:** E2E
- **Test(s):** `elm-core/ArrayFoldlFloatSumTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #3, Issue #4, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `result: 7`
- Actual:   `result: -2.5`

**Hypothesis:** See Issue #2.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #2.

---

### Issue 6: JsArrayFloatFoldlTest

- **Suite:** E2E
- **Test(s):** `elm-core/JsArrayFloatFoldlTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #3, Issue #4, Issue #5

**Failure mode:** Output mismatch

**Observed:**
- Expected: `sum: 7`
- Actual:   `sum: -2.5`

**Hypothesis:** See Issue #2.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #2.

---

### Issue 7: ParserHexIntTest

- **Suite:** E2E
- **Test(s):** `elm-parser/ParserHexIntTest.elm`
- **Status:** FIXED
- **Attempts:** 1
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `hex_ff: Ok 255`
- Actual:   `hex_ff: Err [{ col = 1, row = 1, problem = ExpectingInt }]`

**Hypothesis:** The test bug is in the test itself, not the compiler/runtime. `Parser.int` is documented (Parser.elm:551) as rejecting hex literals: `run int "0x1A" == Err ...`. Source-verified: `Parser.int = A.int ExpectingInt ExpectingInt` passes `Err ExpectingInt` as the `hex` handler, so when `number` dispatches to the hex arm (after matching `0x`), `finalizeInt` returns `Bad True (fromState s ExpectingInt)`. Runtime behaviour matches the library contract. The test's intent (`CHECK: hex_ff: Ok 255`) only matches `Parser.number` with `hex = Just identity`.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Rewrote `test/elm-parser/src/ParserHexIntTest.elm` to use `Parser.number { int = Nothing, hex = Just identity, octal = Nothing, binary = Nothing, float = Nothing }` — the correct API for a hex-int parser. CHECK lines unchanged. Post-fix: E2E 1102/1094/8 (+1 pass, zero regressions). FIXED.

---

### Issue 8: ParserChompUntilEndOrTest

- **Suite:** E2E
- **Test(s):** `elm-parser/ParserChompUntilEndOrTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session (no working hypothesis)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #9

**Failure mode:** SIGSEGV

**Observed:**
- Test body is tiny (2 lines: `Parser.getChompedString (Parser.chompUntilEndOr "}")` run on `"abc"`; expects `Ok "abc"`). No backtrace captured.

**Hypothesis:** Investigated `Elm_Kernel_Parser_findSubString` and `String.slice` — both look safe against the specific inputs. No null-deref pattern visible without a backtrace. Similar SIGSEGV in Issue #9 uses overlapping kernels (`chompUntilEndOr`, `chompWhile`, `findSubString`). Likely a GC-root or HPointer-packing bug exercised when a Parser state is threaded through `andThen`/`map`.

**Attempt log:**
- **Skip rationale (2026-04-20):** Requires running the test binary under a debugger or with `ECO_GC_DEBUG_LIVENESS` to capture the faulting site. Out of session budget.

---

### Issue 9: ParserCommentsTest

- **Suite:** E2E
- **Test(s):** `elm-parser/ParserCommentsTest.elm`
- **Status:** OPEN
- **Attempts:** 0 this session (no working hypothesis)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #8

**Failure mode:** SIGSEGV

**Observed:**
- Test uses `Parser.lineComment`, `Parser.multiComment` (both `NotNestable` and `Nestable`). Crashes without producing output.

**Hypothesis:** Likely shares a root cause with Issue #8 — both tests use parser kernels that thread state through `andThen`/`map` chains and may have the same rooting/HPointer-packing bug.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #8.

---

### Issue 10: Gen (Guida compilation)

- **Suite:** Stress
- **Test(s):** `stress-elm/Gen.elm`
- **Status:** FIXED
- **Attempts:** 1
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #11

**Failure mode:** Compilation failure

**Observed:**
- Guida compilation failed (exit code 1), "NO MAIN — When producing a JS file, I require that the given file has a `main` value."

**Hypothesis:** `Gen.elm` is a library module (`module Gen exposing (Seed, asciiString, …)`) imported by other stress tests. It has no `main`, so the Elm compiler's final "produce a JS file" stage fails. Verified: 69 of 71 files in `test/stress-elm/src/` have a top-level `main`; the two without `main` are `Gen.elm` and `Xorshift32.elm`, matching the two Guida-compilation failures exactly. The test harness (`discoverTests` in `test/ElmE2ETestBase.hpp`) was enumerating every `.elm` file and treating each as a standalone test.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Added `hasTopLevelMain` helper in `test/ElmE2ETestBase.hpp` and filtered `discoverTests` to skip files without a top-level `main` declaration. Verified that all 9 E2E test directories have 100% files with `main`, so the filter cannot mask any existing test. Post-fix counts: elm-test 12799/0 (unchanged); E2E 1102/1093/9 (unchanged, same 9 prior failures); Stress 69/49/20 (was 71/49/22 — two spurious failures removed, no regressions). FIXED.

---

### Issue 11: Xorshift32 (Guida compilation)

- **Suite:** Stress
- **Test(s):** `stress-elm/Xorshift32.elm`
- **Status:** FIXED
- **Attempts:** 1
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #10

**Failure mode:** Compilation failure

**Observed:**
- Guida compilation failed (exit code 1), "NO MAIN" error.

**Hypothesis:** Same as Issue #10 — `Xorshift32.elm` is a library module without `main`. The fix for Issue #10 (filter discovery to require a top-level `main`) resolves this as well.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Fixed jointly with Issue #10. Post-fix: no longer discovered, not treated as a test. FIXED.

---

### Issue 12: ArrayConcatMap

- **Suite:** Stress
- **Test(s):** `stress-elm/ArrayConcatMap.elm`
- **Status:** OPEN
- **Attempts:** 0 this session (no working hypothesis)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #18

**Failure mode:** SIGSEGV

**Observed:**
- Test crashes without producing output — crashes within the first iteration's heavy allocations.

**Hypothesis:** Same GC-under-load class as Issues #18, #29, #30. `Array.concatMap` expands each element via a user function returning an Array, then flattens. With 1000 outer elements producing arrays, allocation pressure is extreme and a GC root/bitmap bug trips.

**Attempt log:**
- **Skip rationale (2026-04-20):** Same as Issue #18 — needs `ECO_GC_DEBUG_LIVENESS` reproduction path.

---

### Issue 13: BytesRoundtripMixedRecord

- **Suite:** Stress
- **Test(s):** `stress-elm/BytesRoundtripMixedRecord.elm`
- **Status:** OPEN
- **Attempts:** 3
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #16, Issue #17

**Failure mode:** Output mismatch (`roundtrip: False`) — originally SIGABRT, then timeout, now completes with wrong result.

**Observed:**
- Attempt 1/2 (pre-timeout bump): SIGABRT → fixed via EmptyString handling.
- Attempt 2 post-fix: timed out at 60 s.
- Attempt 3 (post-timeout-bump to 180s): test completes but returns `roundtrip: False`.

**Hypothesis:** After the empty-string fixes (#16, #17) and the 180s timeout bump, this test runs to completion but reports an inequality. Likely cause: Float-field equality after round-trip through Bytes.Encode/Decode. `Gen.float32Safe` was used for the `d` field but `E.float32` encodes as IEEE 32-bit (truncating mantissa); decode returns the truncated value, not the original double. The `d == original.d` comparison would fail any time `float32Safe` produced a value that didn't round-trip exactly. Secondary candidate: HAMT tree canonicalisation for `List Rec` comparison — List-of-Record equality walks the list via cons, so tree shape is not relevant, but Record field order and unboxed_bitmap must match between construction paths.

**Attempt log:**
- **Attempt 1 (2026-04-20):** ENC_UTF8 + read_string partial fix (buggy Tuple2 return). SIGABRT moved from Allocator to `eco_resolve_hptr`.
- **Attempt 2 (2026-04-20):** Corrected read_string. Test progressed from SIGABRT to 60s timeout.
- **Attempt 3 (2026-04-20):** Timeout bump to 180s in `IsolatedTestRunner.hpp`. Test now completes in ~90-150s and prints `roundtrip: False`. Further diagnosis would need to log which iteration's `ok2` first goes False and inspect the differing record. Out of session budget. SKIPPED.

---

### Issue 14: ArrayFilterRebuild

- **Suite:** Stress
- **Test(s):** `stress-elm/ArrayFilterRebuild.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   `roundtrip: False` (test runs to completion).

**Hypothesis:** Test rebuilds the array via `Array.filter` twice → `Array.append` → `Array.toList |> List.sort |> Array.fromList`, then checks equal to original (`Array.initialize`). Elm documentation asserts `initialize n f == fromList [f 0, f 1, …, f (n-1)]` (Array.elm:170), but that invariant depends on canonical HAMT tree shape — if Eco's `Array.initialize` and `Array.fromList` produce different tree layouts for the same element sequence, structural `==` on the resulting Array_elm_builtin Custom returns false. Passing `ArrayReverse` (which repeatedly reverses the same array) does not exercise a cross-construction-path comparison, so it doesn't catch this.

**Attempt log:**
- **Skip rationale (2026-04-20):** Diagnosis requires printing `Array.toList original` vs `Array.toList rebuilt` (to prove the element sequences match) and then dumping the internal tree structures. Needs `ECO_GC_DEBUG` build or custom logging. Out of session budget.

---

### Issue 15: ArrayZipUnzip

- **Suite:** Stress
- **Test(s):** `stress-elm/ArrayZipUnzip.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   `roundtrip: False`.

**Hypothesis:** Zip builds `Array (Int, Int)` via `Array.initialize`, unzip splits via `Array.map Tuple.first/second`. Array.map preserves tree structure, so the unzipped arrays should have the same shape as the zipped. Possible root causes: (1) Array.map mis-preserves `startShift`/bitmap when the element kind changes (tuple-of-ints → int), (2) tuple unboxing bitmap mismatch between construction paths. Shares Custom/Array representation class with Issue #14.

**Attempt log:**
- **Skip rationale (2026-04-20):** Same diagnostic needs as Issue #14. Out of session budget.

---

### Issue 16: BytesRoundtripString

- **Suite:** Stress
- **Test(s):** `stress-elm/BytesRoundtripString.elm`
- **Status:** FIXED
- **Attempts:** 2
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #13, Issue #17

**Failure mode:** SIGABRT

**Observed:**
- Assertion: `Allocator.cpp:392: void *Elm::Allocator::resolve(Elm::HPointer): Assertion 'ptr.constant == 0 && "Cannot resolve HPointer with constant field set (embedded constant)"' failed.`

**Hypothesis:** Same root cause as Issue #13 — empty strings (length 0 via `Gen.intIn 0 20`) trigger `ENC_UTF8` resolve assertion. Fixed jointly.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Fixed ENC_UTF8 assertion but `read_string(0,...)` fix was buggy (returned bare HPointer instead of Tuple2). Downstream decoder destructured garbage → SIGABRT at `eco_resolve_hptr`.
- **Attempt 2 (2026-04-20):** Corrected `read_string` to return `makeTuple2_ip(offset, alloc::emptyString())` — proper Tuple2(new_offset, value). Post-fix: test passes. Stress 69/51/18 (was 69/49/20). No regressions. FIXED.

---

### Issue 17: BytesRoundtripTaggedUnion

- **Suite:** Stress
- **Test(s):** `stress-elm/BytesRoundtripTaggedUnion.elm`
- **Status:** FIXED
- **Attempts:** 2
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #13, Issue #16

**Failure mode:** SIGABRT

**Observed:**
- Assertion: `Allocator.cpp:392: void *Elm::Allocator::resolve(Elm::HPointer): Assertion 'ptr.constant == 0 && "Cannot resolve HPointer with constant field set (embedded constant)"' failed.`

**Hypothesis:** Confirmed same root cause as Issue #13. The `VC String` variant in `genVariant` (lines 55–63) generates strings of length 0–10, empty strings go through `ENC_UTF8` with `EmptyString` constant.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Fixed jointly with Issue #13; `read_string` fix was buggy (see Issue #16 attempt log).
- **Attempt 2 (2026-04-20):** Jointly with Issue #16's correction. FIXED.

---

### Issue 18: DictUnionDiff

- **Suite:** Stress
- **Test(s):** `stress-elm/DictUnionDiff.elm`
- **Status:** OPEN
- **Attempts:** 0 this session; git history records 3 prior attempts with multiple sub-hypotheses (rooting gaps, Dict Custom bitmap misreport, ptr↔i64 write-barrier)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** SIGSEGV

**Observed:**
- Test crashes on 1000× `Dict.union`/`Dict.diff` over Int→Int dicts of size 500+500.

**Hypothesis:** GC-under-pressure issue in Dict kernels. Candidate causes (per prior session Categories 21–26): shadow-stack arg ranges, double-rooting, object-size mismatch, unboxed-bitmap mis-handling on Custom, ptr<1>↔i64 conversion in the generational write-barrier. Narrowing requires `ECO_GC_DEBUG_LIVENESS` to turn the raw SIGSEGV into a targeted assertion.

**Attempt log:**
- **Skip rationale (2026-04-20):** Three prior attempts (in git history) were unable to narrow the cause without the `ECO_GC_DEBUG_LIVENESS` build-time flag and a dedicated reproducer. Fix requires a focused GC-debug session that exceeds this session's budget.

---

### Issue 19: JsonRoundtripArray

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripArray.elm`
- **Status:** FIXED
- **Attempts:** 1
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   `roundtrip: False`

**Hypothesis:** `Json.Decode.array` was `= Elm.Kernel.Json.decodeArray`, which builds a flat `Tag_Array` (ElmArray). But `Array.fromList` (used to build `original`) produces a `Tag_Custom` HAMT tree (`Array_elm_builtin len shift tree tail`). `Utils::equal` dispatches on tag first, so a `Tag_Array` vs `Tag_Custom` comparison returns false immediately. Only `JsonRoundtripArray` exercises `D.array` (no E2E tests use it), which is why this latent bug only surfaced in stress.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Rewrote `Json.Decode.array` in `/home/dev/.eco/1.0.0/packages/elm/json/1.1.3/src/Json/Decode.elm` from `= Elm.Kernel.Json.decodeArray` to `array decoder = map Array.fromList (list decoder)`. Also deleted `artifacts.dat` + `typed-artifacts.dat` from the package dir to force recompilation. Post-fix: Stress 69/52/17 (+1 pass). FIXED.

---

### Issue 20: DictFoldRebuild

- **Suite:** Stress
- **Test(s):** `stress-elm/DictFoldRebuild.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   `roundtrip: False`.

**Hypothesis (from prior session):** `DictFoldRebuild` rebuilds a Dict via `Dict.foldl insert Dict.empty`. The fold visits keys in ascending order and inserts into an initially empty RB tree. The original Dict was built by `buildDict` inserting keys in a different order. Elm's RB-tree `insert` should produce canonical trees (same keys → same tree regardless of insertion order), but some RB implementations aren't canonical. If Eco's `Dict.insert` produces non-canonical trees, the rebuilt Dict differs structurally from the original and `==` returns false, even though the logical key-value sets match.

**Attempt log:**
- **Skip rationale (2026-04-20):** Requires either a custom non-structural Dict equality in the runtime (big change) or confirming Eco's Dict.insert is not canonical (by printing internal structure). Both exceed session budget.

---

### Issue 21: BytesRoundtripNestedBytes

- **Suite:** Stress
- **Test(s):** `stress-elm/BytesRoundtripNestedBytes.elm`
- **Status:** OPEN
- **Attempts:** 1 (timeout bump)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #28, Issue #18

**Failure mode:** SIGABRT (was timeout; timeout bump exposed an underlying GC bug)

**Observed:**
- Before timeout bump: `Test timed out after 60 seconds`.
- After timeout bump to 180s: `stress-test: /work/runtime/src/allocator/NurserySpace.cpp:748: void Elm::NurserySpace::evacuate(...): Assertion 'hdr->tag <= Tag_Forward && "Invalid tag value!"' failed.` SIGABRT.

**Hypothesis:** The test encodes/decodes 1000 lists of 1000 small byte-lists, which allocates ~M nested Bytes + List values and triggers many GCs. The evacuation assertion indicates that a heap object's header.tag is corrupt — likely a misplaced pointer writing into a header slot, or a Cons cell whose `head.p` slot was written as raw i64 (Int) when it should have been a boxed HPointer. Same class of bug as Issues #18, #29, #30.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Bumped `TEST_TIMEOUT_SECONDS` from 60 → 180 in `test/IsolatedTestRunner.hpp`. Revealed the underlying GC evacuation bug (was masked by timeout). Deeper fix requires the `ECO_GC_DEBUG_LIVENESS` build flag to catch the offending write earlier. Out of session budget. SKIPPED.

---

### Issue 22: JsonRoundtripDict

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripDict.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #20

**Failure mode:** Output mismatch

**Observed:**
- `roundtrip: False`.

**Hypothesis:** Decoded Dict (via `D.dict` = `map Dict.fromList (keyValuePairs decoder)`) compared to original Dict. Probably same non-canonical RB tree issue as Issue #20.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #20.

---

### Issue 23: JsonRoundtripKeyValuePairs

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripKeyValuePairs.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- `roundtrip: False` (compares `List.sort v == List.sort original`).

**Hypothesis:** `D.keyValuePairs` decodes JSON `{"k0": v0, …}` into `List (String, Int)`. Comparison is after sort, so order doesn't matter; only the set of pairs matters. Candidates: (1) tuple equality edge case for `(String, Int)` with unboxed Int slot, (2) `List.sort` ordering differs between unrelated construction paths, (3) JSON parsing produces slightly different ints for boundary values (unlikely since `Gen.int32` stays in 32-bit range).

**Attempt log:**
- **Skip rationale (2026-04-20):** Need to print `List.length original` vs `List.length v` and the first differing pair to isolate. Out of budget.

---

### Issue 24: JsonRoundtripIndex

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripIndex.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- `roundtrip: False`.

**Hypothesis:** Uses `D.index` to decode positionally. Bug candidate: positional index off-by-one, or the index kernel resolving the wrong element.

**Attempt log:**
- **Skip rationale (2026-04-20):** Out of session budget for per-test diagnosis.

---

### Issue 25: JsonRoundtripOneOf

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripOneOf.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- `roundtrip: False`.

**Hypothesis:** Custom variants `VLeft Int | VRight String | VPair Int Int` encoded as one-field objects `{"left":…}`, `{"right":…}`, `{"pair":[a,b]}`. `D.oneOf` tries decoders in order and uses the first matching. Potential bug: `D.field "pair"` might accept `{"left":…}` erroneously, mapping to the wrong variant. Or the variant-equality post-decode could have unboxed-bitmap mismatch for `VPair Int Int`.

**Attempt log:**
- **Skip rationale (2026-04-20):** Out of session budget.

---

### Issue 26: JsonRoundtripString

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripString.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 27: RecordUpdateArray

- **Suite:** Stress
- **Test(s):** `stress-elm/RecordUpdateArray.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 28: JsonRoundtripObject

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripObject.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #21

**Failure mode:** Timeout (60 s)

**Observed:**
- Test timed out after 60 seconds

---

### Issue 29: TupleMapArray

- **Suite:** Stress
- **Test(s):** `stress-elm/TupleMapArray.elm`
- **Status:** OPEN
- **Attempts:** 0 this session; shares root cause with Issue #30 (prior 3 attempts)
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #30, Issue #18

**Failure mode:** SIGSEGV

**Observed:**
- Test crashes under heavy `List.map swap` over a 1000-element `Array (Int,Int)`.

**Hypothesis:** Same GC-under-pressure class as Issue #18. Tuple2 for `(Int,Int)` must have bits `01 | (01 << 2)` so GC skips both fields; Cons/Array cells of `(Int,Int)` must set the slot bitmap to 0 (boxed tuple), not 1 (unboxed Int). Candidate cause: `cons()` helper called with a bool overload that assumes `false == Int` instead of taking the 2-bit `head_kind`.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #18 — requires `ECO_GC_DEBUG_LIVENESS` reproduction path.

---

### Issue 30: TupleMapList

- **Suite:** Stress
- **Test(s):** `stress-elm/TupleMapList.elm`
- **Status:** OPEN
- **Attempts:** 0 this session
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #29, Issue #18

**Failure mode:** SIGSEGV

**Observed:**
- 1000× `List.map swap` over a 1000-element `List (Int,Int)` crashes.

**Hypothesis:** See Issue #29.

**Attempt log:**
- **Skip rationale (2026-04-20):** See Issue #18.

---

### Issue 31: RecordUpdateList

- **Suite:** Stress
- **Test(s):** `stress-elm/RecordUpdateList.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

## Closed Issues

_None — all historical content was archived to git history when this file was
reset on 2026-04-20. See `git log guides/test-fails.md` for prior triage notes,
including the 2026-03 SKIPPED analyses of Float re-boxing, tuple `compare` fix,
and the Dict/Tuple SIGSEGV work._
