# Stress Test Failures

Baseline (2026-04-22, after Dict fixes from previous session):
- elm-test: 12799/12799 pass, 0 fail
- E2E: 1124/1124 pass, 0 fail
- Stress (n=10 m=10): 83/97 pass, 14 fail

After this session's fixes:
- elm-test: 12799/12799 pass, 0 fail
- E2E: 1123/1123 pass, 0 fail (no regressions)
- Stress (n=1 m=1): 87/97 pass, 10 fail

## Fixed

### JsonRoundtripArray — FIXED

Root cause: `Json.Decode.array`'s `DEC_ARRAY` built a JsArray with the
declared element kind (kind 1 for Int via DEC_INT), but the "original"
array built via `Array.fromList (List.range ...)` had a JsArray with
kind 0 (boxed), because `List.range` uses the kernel `cons` that
produces boxed-head Cons cells and `JsArray.initializeFromList`
inherits that kind. The resulting arrays compared unequal because
`Utils.cpp eqHelp`'s `Tag_Array` branch rejected any kind mismatch.

Fix: `eqUnboxableSlot` now handles mixed boxed/unboxed-primitive
slots by resolving the boxed side and comparing the primitive values
(same logic the `Tag_Cons` branch already had). `Tag_Array` now
delegates to the per-element comparator instead of failing on
header-kind mismatch.

### JsonRoundtripKeyValuePairs — FIXED

### JsonRoundtripDict — FIXED (joint with above)

Root cause: `Json.Decode.keyValuePairs` / `Json.Decode.dict` build a
list of `(String, a)` tuples via `DEC_KEYVALUE` in
`elm-kernel-cpp/src/json/JsonExports.cpp`. The tuples were always
constructed with `unboxed_mask = 0` — both slots boxed. But callers
like `Dict.fromList` destructure at the monomorphized type,
projecting slot 1 as `i64` for a `(String, Int)` tuple. Reading the
boxed HPointer bits as `i64` yielded HPointer-encoded values (e.g.
`Just 536871077` instead of `Just 1`), corrupting the Dict.

Fix: `DEC_KEYVALUE` now inspects the value decoder's ctor (matching
`DEC_LIST`'s existing approach) and builds each Tuple2 with the
correct 2-bit-per-slot `tupleBitmap`:
- `DEC_INT`  → slot 1 kind 01 (i64), unbox the decoded ElmInt.
- `DEC_FLOAT`→ slot 1 kind 10 (f64), unbox the ElmFloat.
- other     → slot 1 kind 00 (boxed HPointer), unchanged.

### ArrayZipUnzip — FIXED
### ArrayConcatMap — FIXED (joint with above)

Root cause: `Elm_Kernel_JsArray_initialize` / `_map` / `_indexedMap`
in `elm-kernel-cpp/src/core/JsArrayExports.cpp` always pushed the
closure's return value as a boxed HPointer (kind 0), but downstream
code expects uniform-kind arrays that match how
`Array.fromList`/`JsArray.initializeFromList` would represent the
same element type. For `Array Int`, callers like `Array.get` that
project the element as `i64` would read HPointer bits instead of Int
values (e.g. `Just 536871040`).

Separately, `Elm_Kernel_JsArray_appendN` preserved `destArr`'s kind
even when `dest` was empty — a 0-element array necessarily has kind
0 from `allocArray`, so concatenating onto an empty tail produced
kind-0 arrays with kind-1 element bits, silently corrupting Ints in
`Array.append`.

Fix:
- Added `pushUnboxedResult` helper that inspects the returned
  HPointer's tag and unboxes `Tag_Int`/`Tag_Float`/`Tag_Char` using
  `arrayPushKind` (kinds 01/10/11), falling back to boxed otherwise.
  Used by `_initialize`, `_map`, and `_indexedMap`.
- `_appendN` now picks the result kind from whichever operand
  contributed elements: inherit src's kind if dest is empty, dest's
  kind if src contributed nothing, with an assert that both agree
  when both contribute.

## Remaining OPEN

Order best-to-tackle first:

1. **BytesRoundtripMixedRecord** — roundtrip False. Prior diagnosis
   (`guides/test-fails.md` #13): unboxed-bitmap mismatch on a mixed
   Int/Float/String record. Similar in spirit to the tuple/dict
   bitmap fixes above but in the Bytes encode/decode path.
2. **MVar family (6 tests)** — SIGABRT "MVar not found" after ~410
   iterations. Observed values[0] of the MVar Custom is overwritten
   with an ElmInt header bit pattern (0x1000000100 = Header{tag=
   Tag_Int, age=1, size=16}) after GC. Strongly suggests a stale
   HPointer to a reclaimed from-space location being dereferenced in
   a closure capture slot. Requires `ECO_GC_DEBUG_LIVENESS` pass +
   deeper GC root-tracking audit to localize the specific mis-traced
   capture. Known SKIPPED in prior sessions.
3. **SpawnGCChurn / SpawnThenAndThenChain** — SIGABRT, almost
   certainly the same root cause as the MVar family (shared task
   scheduler + closure capture machinery).
4. **JsonRoundtripIndex** — flaky 60s timeout (passed earlier). Not
   strictly "broken" but benchmark-sensitive.
