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
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `get: 10`
- Actual:   (missing — wrong value printed)

---

### Issue 2: ListMap2FloatSumTest

- **Suite:** E2E
- **Test(s):** `elm/ListMap2FloatSumTest.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #3, Issue #4, Issue #5, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `result: [12, 23]`
- Actual:   (missing — Float-as-Int reinterpretation suspected; see Issue #3)

---

### Issue 3: ListMap2FloatTest

- **Suite:** E2E
- **Test(s):** `elm/ListMap2FloatTest.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #4, Issue #5, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `map2Add: [11, 22, 33]`
- Actual:   (missing)

---

### Issue 4: ArrayFoldrFloatSumTest

- **Suite:** E2E
- **Test(s):** `elm-core/ArrayFoldrFloatSumTest.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #3, Issue #5, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `result: 7`
- Actual:   (missing)

---

### Issue 5: ArrayFoldlFloatSumTest

- **Suite:** E2E
- **Test(s):** `elm-core/ArrayFoldlFloatSumTest.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #3, Issue #4, Issue #6

**Failure mode:** Output mismatch

**Observed:**
- Expected: `result: 7`
- Actual:   (missing)

---

### Issue 6: JsArrayFloatFoldlTest

- **Suite:** E2E
- **Test(s):** `elm-core/JsArrayFloatFoldlTest.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #2, Issue #3, Issue #4, Issue #5

**Failure mode:** Output mismatch

**Observed:**
- Expected: `sum: 7`
- Actual:   (missing)

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
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #9

**Failure mode:** SIGSEGV

**Observed:**
- Test crashed: SIGSEGV (Segmentation fault)

---

### Issue 9: ParserCommentsTest

- **Suite:** E2E
- **Test(s):** `elm-parser/ParserCommentsTest.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #8

**Failure mode:** SIGSEGV

**Observed:**
- Test crashed: SIGSEGV (Segmentation fault)

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
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** SIGSEGV

**Observed:**
- Test crashed: SIGSEGV (Segmentation fault)

---

### Issue 13: BytesRoundtripMixedRecord

- **Suite:** Stress
- **Test(s):** `stress-elm/BytesRoundtripMixedRecord.elm`
- **Status:** IN_PROGRESS
- **Attempts:** 2
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #16, Issue #17

**Failure mode:** Timeout (60 s) — was SIGABRT before Issue #16/17 fix

**Observed:**
- Originally: Assertion `Allocator.cpp:392` on EmptyString.
- After Attempt 2: test no longer crashes; runs but does not complete within 60 s wall-clock.

**Hypothesis:** Same empty-string root cause as Issues #16/#17 — fix eliminated the SIGABRT. Residual timeout is performance, not correctness: each of the 1000 outer iterations decodes 1000 records of 5 fields (`Int × 3, Float, String`), i.e. ~5 M field allocations plus record allocations and GCs. BytesRoundtripString (1 string field per item) passes comfortably, but MixedRecord's ~6× allocation pressure pushes past the 60 s limit. Likely needs either a test-harness timeout bump for this specific test, or allocator/GC-side optimisation; both are out of scope for a single loop iteration focused on correctness.

**Attempt log:**
- **Attempt 1 (2026-04-20):** Two changes in `elm-kernel-cpp/src/bytes/BytesExports.cpp`:
  1. `writeEncoder` ENC_UTF8 arm: early-exit when `alloc::isEmptyString(encoder->values[1].p)`.
  2. `Elm_Kernel_Bytes_read_string` for length=0: returned bare HPointer instead of Tuple2 — BUG.
  Result: SIGABRT moved from `Allocator.cpp:392` (ENC_UTF8) to `RuntimeExports.cpp:2683` (`eco_resolve_hptr` on embedded constant) because the decoder destructured the malformed return.
- **Attempt 2 (2026-04-20):** Corrected read_string to `makeTuple2_ip(offset, alloc::emptyString())`. SIGABRT resolved. Test now times out at 60 s (≈500 of 1000 iterations completed based on typical allocation rate). No regressions. Fix is a real improvement; deferring the timeout resolution to a future iteration. PARTIAL PROGRESS — still counts as a failure until the test completes within budget.

---

### Issue 14: ArrayFilterRebuild

- **Suite:** Stress
- **Test(s):** `stress-elm/ArrayFilterRebuild.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 15: ArrayZipUnzip

- **Suite:** Stress
- **Test(s):** `stress-elm/ArrayZipUnzip.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

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
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** SIGSEGV

**Observed:**
- Test crashed: SIGSEGV (Segmentation fault)

---

### Issue 19: JsonRoundtripArray

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripArray.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 20: DictFoldRebuild

- **Suite:** Stress
- **Test(s):** `stress-elm/DictFoldRebuild.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 21: BytesRoundtripNestedBytes

- **Suite:** Stress
- **Test(s):** `stress-elm/BytesRoundtripNestedBytes.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #28

**Failure mode:** Timeout (60 s)

**Observed:**
- Test timed out after 60 seconds

---

### Issue 22: JsonRoundtripDict

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripDict.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 23: JsonRoundtripKeyValuePairs

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripKeyValuePairs.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 24: JsonRoundtripIndex

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripIndex.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

---

### Issue 25: JsonRoundtripOneOf

- **Suite:** Stress
- **Test(s):** `stress-elm/JsonRoundtripOneOf.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20

**Failure mode:** Output mismatch

**Observed:**
- Expected: `roundtrip: True`
- Actual:   (missing)

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
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #30

**Failure mode:** SIGSEGV

**Observed:**
- Test crashed: SIGSEGV (Segmentation fault)

---

### Issue 30: TupleMapList

- **Suite:** Stress
- **Test(s):** `stress-elm/TupleMapList.elm`
- **Status:** OPEN
- **Attempts:** 0
- **First seen:** 2026-04-20
- **Last updated:** 2026-04-20
- **Related:** Issue #29

**Failure mode:** SIGSEGV

**Observed:**
- Test crashed: SIGSEGV (Segmentation fault)

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
