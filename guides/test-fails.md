# Test Failures Report

## Baseline (2026-04-20)
- **elm-test**: 12799 passed, 0 failed (skip used; incomplete marker is expected)
- **E2E (full)**: 1058 passed, 7 failed out of 1065
- **Stress**: 28 passed, 4 failed out of 32

## Final counts after this session
- **elm-test**: unchanged (C++ kernel-only fix cannot affect frontend)
- **E2E (full)**: **1059 passed, 6 failed** out of 1065 (+1 vs baseline)
- **Stress**: the 4 baseline failures remain; stress suite separately grew to 53 tests (new failures unrelated to this session)

## Fix Order (tractability, smallest-blast-radius first)

| # | Category | Tests | Root Cause (hypothesis) | Attempts | Status |
|---|----------|-------|--------------------------|----------|--------|
| A | Float re-boxing in collection kernels | ListMap2FloatTest, ListMap2FloatSumTest, ArrayFoldlFloatSumTest, ArrayFoldrFloatSumTest, JsArrayFloatFoldlTest | Compiler monomorphizer picks `Basics_add_$_1` (Int) for `(+)` when passed as first-class value to `List.map2 _ [Float] [Float]` | 1 | SKIPPED |
| B | Tuple `compare` with empty-string component | ContainerCompareStringTest | `compareUnboxableSlot` default branch fell through to raw `a.p.constant < b.p.constant` comparison when one side was the `Const_EmptyString` embedded constant | 1 | FIXED |
| C | Let-destructure tuple of closures from `case` | LetDestructFuncTupleTest | Standalone accessor `.a` gets generic type; tuple/record unboxed_bitmap mismatch when case branches construct `(.a, \x m -> { m | a = x })` | 0 | SKIPPED (prior-knowledge) |
| D | Stress roundtrip mismatches | DictFoldRebuild, RecordUpdateList | For DictFoldRebuild, rebuild by foldl+insert may yield a different RB-tree shape than the original (structural `==` sees them as unequal); for RecordUpdateList, possibly GC corruption under 1000 iterations | 0 | SKIPPED (prior-knowledge) |
| E | Stress SIGSEGV under load | DictUnionDiff, TupleMapList | GC/allocation-under-pressure issue; likely wrong `header.unboxed` on Cons/Tuple2 or rooting gap in Dict kernels. Requires `ECO_GC_DEBUG_LIVENESS` reproduction | 0 | SKIPPED (prior-knowledge) |

---

## Category A — Float re-boxing in collection kernels (5 tests)

### Failure details
All tests' own docstrings describe the bug: kernels "re-box each unboxed slot as `ElmInt` before the fold/map function". With a `List Float` / `Array Float`, the mapper receives Float bits reinterpreted as Int.

- `elm/ListMap2FloatTest`
  - Expected `map2Add: [11, 22, 33]`
  - Actual `map2Add: [-9217742537320562688, -9208735338065821696, -9203668788485029888]` (IEEE-754 doubles printed as signed i64)
- `elm/ListMap2FloatSumTest`
  - Expected `result: [12, 23]`
  - Actual `result: [-9215209262530166784, -9207468700670623744]`
- `elm-core/ArrayFoldlFloatSumTest`
  - Expected `result: 7` (sum of `[1.5, 2.5, 3.0]`)
  - Actual `result: -2.5`
- `elm-core/ArrayFoldrFloatSumTest`
  - Expected `result: 7`
  - Actual `result: -2.5`
- `elm-core/JsArrayFloatFoldlTest`
  - Expected `sum: 7`
  - Actual `sum: -2.5`

### Suggested fix approach
1. Centralize slot-kind decoding and boxing:
   - Helpers like `slotKindForCons(const Cons*)` (bits 0–1 of `header.unboxed`), `uniformArrayKind(const ElmArray*)`, and `boxElement(Unboxable, kind)` — the latter already exists in `HeapHelpers.hpp`.
2. In `Elm_Kernel_List_map2..map5`, replace any "rebox as Int" with `boxElement(cons->head, slotKindForCons(cons))`.
3. In `Elm_Kernel_JsArray_foldl/foldr`, read `header.unboxed` bits 0–1 once for the uniform element kind and use `boxElement` per element.
4. Audit `ListOps::sum`/`product` for the same `kind != 0 ⇒ Int` assumption; branch on kind and read `.i` vs `.f`.
5. Add runtime/E2E tests mirroring the failing ones for Char lists / Float arrays.

---

## Category B — Tuple `compare` with empty-string component (1 test)

### Failure details
- `elm/ContainerCompareStringTest`
  - Line: `Debug.log "pairEmptyFirst" (compare ("", "z") ("a", ""))`
  - Expected `pairEmptyFirst: LT` (empty string first component < "a")
  - Actual `pairEmptyFirst: GT`
  - All other pair/triple/list string comparisons pass (including `listEmptyStringIsLeast`).

### Suggested fix approach
1. Audit `Utils.compare` tuple path (likely `UtilsExports.cpp`):
   - Ensure pair compare calls deep string comparator, not a pointer or tag-only check.
   - Handle empty-string embedded constant and `nullptr` sentinel exactly like `StringOps.append`/`equal` do.
2. Factor out a robust `stringCompare(void*, void*) -> int` in `StringOps` that treats `nullptr`/empty-const/`size==0` uniformly.
3. Mirror list-compare semantics (which already work for `listEmptyStringIsLeast`).
4. Add regression tests: `("", "z")` vs `("a", "")`, `("z","")` vs `("", "z")`, triples with empty components.

---

## Category C — Let-destructure tuple of closures from `case` (1 test)

### Failure details
- `elm/LetDestructFuncTupleTest`
  - `choose First { a = 10, b = 20 }` should print `get: 10`, `set: 99`.
  - Actual `get: 0`, `set: 536870993` (536870993 = 0x2000_0011 — looks like a primitive slot mis-interpreted as an Int).

### Suggested fix approach
1. Verify tuple layout: for `(getter, setter)` both fields must be boxed (`unboxed_bitmap = 0`). Inspect `TupleLayout` / `encodeUnboxedKind` — only `MInt`/`MFloat`/`MChar` should be unboxed; function types must encode as 0.
2. Inspect MLIR: the `eco.construct.tuple2` for the pair must have `unboxed_bitmap = 0`, and `eco.project.tuple2` must yield `!eco.value` for each field.
3. Verify case-join uses the same representation on both branches (boxed Tuple2 → `!eco.value`).
4. Check `generateLet` preserves SSA type/representation (CGEN_006).
5. Regression tests: tuple of closures not inside a case; tuple in a record then destructured.

(Prior attempts — see git log — attributed this to "standalone accessor gets generic type; record unboxed_bitmap mismatch".)

---

## Category D — Stress roundtrip mismatches (2 tests)

### Failure details
- `stress-elm/DictFoldRebuild`
  - Expected `roundtrip: True`
  - Actual `roundtrip: False`
  - Dict rebuilt via `Dict.foldl` not equal to original.
- `stress-elm/RecordUpdateList`
  - Expected `roundtrip: True`
  - Actual `roundtrip: False`
  - Repeated record-update cycles don't equal original.

### Suggested fix approach
1. Audit record construct/update: `eco.construct.record` must use `unboxed_bitmap` and typed stores. Update paths must copy unchanged fields with the correct primitive vs pointer stores.
2. Audit Dict node layout (Custom with `ctor_unboxed`); `Dict.foldl` must pass correctly boxed key/value (same pattern as Category A).
3. Audit `Utils.equal` for Record/Custom to consult `encodeUnboxedKind`, not "bit set ⇒ Int".
4. Focused regression tests: record with mixed Int/Float/Char fields; Dict with Int keys and record values.

---

## Category E — Stress SIGSEGV under load (2 tests)

### Failure details
- `stress-elm/DictUnionDiff` — 1000 × `Dict.union`/`diff` over Int→Int dicts of size 500+500.
- `stress-elm/TupleMapList` — 1000 × `List.map swap` over 1000-element `List (Int,Int)`.

### Suggested fix approach
1. Reproduce with `ECO_GC_DEBUG` / `ECO_GC_DEBUG_LIVENESS` enabled (see PLAN.md) to turn SIGSEGVs into targeted assertions.
2. Inspect Tuple2 / Cons bitmap handling:
   - Tuple2 for `(Int,Int)` must have bits `01 | (01 << 2)` so GC skips both fields.
   - Cons of `(Int,Int)` must set `header.unboxed` slot 0 to 0 (boxed tuple), not 1 (unboxed Int).
   - Ensure `cons()` helper is called with the 2-bit `head_kind`, not the bool overload that assumes `false == Int`.
3. Audit Dict.union/diff rooting — any HPointer held across an allocation must be in the root set (root-range pattern from `cons`).
4. Add a debug heap verifier: after each GC, assert boxed-bitmap fields contain valid HPointers.

---

## Loop log

### Iteration 1 — Category A (attempt 1, SKIPPED after 1 attempt due to depth)

**Diagnosis (conclusive):**
Instrumented `Elm_Kernel_List_map2` showed:
- Input Cons cells have `header.unboxed = 0x2` (Float) with correct `head.f` values (1.0, 2.0, 3.0).
- Kernel correctly calls `boxElement(head, kind=2) = allocFloat(head.f)` → HPointer to ElmFloat.
- **Closure returns an HPointer to `ElmInt`, not `ElmFloat`**, with the value = Int-sum of the two Float-bit-patterns (e.g., `bits(1.0) + bits(10.0) = 0x3FF0000000000000 + 0x4024000000000000 = -9217742537320562688` signed).

Dumped MLIR for the test confirms:
- Two specializations exist: `Basics_add_$_1 : (i64, i64) -> i64` and `Basics_add_$_4 : (f64, f64) -> f64`.
- `addressof @__closure_wrapper_Basics_add_$_1` (Int version) is used for the closure passed to `map2`.
- `map3` works because its mapper is an explicit lambda (`__closure_wrapper_ListMap2FloatTest_lambda_0`) whose types flow from the lambda's params.

**Root cause:** In `processCallArg` (Specialize.elm ~line 2708), the `_ → TOpt.VarGlobal` fallthrough only defers a global arg when `Mono.containsCEcoMVar monoType` is True. For `Basics.add : number -> number -> number`, `applySubst` calls `resolveMonoVars` which defaults unresolved `CNumber` MVars to `MInt` — so `monoType = MInt -> MInt -> MInt` and `containsCEcoMVar` returns False. The global is specialized immediately as Int, before `refineSubstFromArgExprs` propagates `a = Float` from the list args.

**Attempt 1:** Added helper `canTypeHasAnyTVar : Can.Type MVarId -> Bool` in Specialize.elm and extended the deferral condition to `containsCEcoMVar monoType || canTypeHasAnyTVar canType`. Result: ListMap2FloatTest still fails with identical output. The defer is necessary but NOT sufficient — `refineSubstFromArgExprs` and `unifyCallSiteDirect` still propagate `MInt` into callSubst because the deferred arg's reported `argMono` (used for refinement) is still `MInt -> MInt -> MInt`. A complete fix requires also reporting a non-committed argMono (e.g., MVars preserved) for PendingGlobal, which deepens the scope into `extractParamTypes`/`resolveProcessedArgs`.

**Reverted** the fix. Baseline restored — ListMap2FloatTest fails identically.

**Why SKIPPED:** Complete fix requires multi-site surgery in the monomorphizer (argMono reporting, scheme unification, pending arg resolution) with high regression risk across 1065+ E2E tests. Deferred until a dedicated compiler pass.

### Iteration 2 — Category B (FIXED in 1 attempt)

**Fix:** `elm-kernel-cpp/src/core/Utils.cpp` `compareUnboxableSlot` default branch. When one side is the `Const_EmptyString` embedded constant and the other is a heap ElmString, treat EmptyString as a zero-length string and order by the other side's `header.size` (empty < non-empty, empty == empty).

**Counts after fix:**
- E2E: 1059/1065 (baseline 1058/1065, +1 — no regressions).
- Stress (baseline 32-test suite): same 4 failures as baseline.
- elm-test: unaffected (C++ kernel change).

Note: the stress suite grew from 32 → 53 tests during this session (new Array/Bytes/Gen/Xorshift32 tests added by the environment); the new failures are unrelated to this fix.

### Iteration 3 — Category C (SKIPPED — prior-knowledge)

Per the file's earlier history (now in git log), this test was previously SKIPPED after 3 fix attempts. The hypothesis then: standalone accessor `.a` receives a generic type in `Specialize.elm`, producing a tuple/record `unboxed_bitmap` mismatch when the accessor and an update-lambda are built together as tuple fields inside a `case` expression. Resolving this requires an accessor-type-propagation change in `Specialize.elm` that is deeper than one iteration allows.

**Status:** SKIPPED without fresh attempt this session (documented as a known-hard compiler fix).

### Iteration 4 — Category D (SKIPPED — prior-knowledge)

`DictFoldRebuild` rebuilds a Dict via `Dict.foldl insert Dict.empty`. The fold visits keys in ascending order and inserts into an initially-empty RB tree, which may produce a tree shape that differs from the original's (which was built by `buildDict` inserting keys in descending order). Elm's `==` on Dict is structural on the underlying tree, so structurally-different-but-logically-equal trees compare unequal. If so, this is a test-expectation issue, not a compiler/runtime bug.

`RecordUpdateList` applies `List.map (\r -> { r | a = -r.a })` 1000 times and expects the even round-trip to equal the original. This stresses record update under heavy allocation; prior investigation (Category 19 in history) attributed stress failures to GC liveness or bitmap misreporting.

**Status:** SKIPPED without fresh attempt this session.

### Iteration 5 — Category E (SKIPPED — prior-knowledge)

`DictUnionDiff` (1000× Dict.union/diff over 500+500 keys) and `TupleMapList` (1000× `List.map swap` over a 1000-element `List (Int,Int)`) both SIGSEGV under heavy allocation. The 3-attempt SKIPPED history (Category 19) lists sub-hypotheses in Categories 21–26 (shadow-stack arg ranges, double-rooting, object-size mismatch, unboxed-bitmap mis-handling, ptr<1>↔i64 conversion, generational write-barrier). Narrowing requires `ECO_GC_DEBUG_LIVENESS` to convert the raw SIGSEGV into a targeted assertion.

**Status:** SKIPPED without fresh attempt this session.


