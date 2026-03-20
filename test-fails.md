# Test Failures Report

## Baseline (2026-03-19)
- **elm-test**: 11667 passed, 1 failed
- **E2E**: 923 passed, 16 failed

## Current (after fixes)
- **elm-test**: 11667 passed, 1 failed (unchanged)
- **E2E**: 925 passed, 10 failed (6 fixed: 4 deleted invalid tests + 2 code fixes)

## Fix Order (by root cause, earliest compiler phase first)

| # | Category | Tests | Root Cause | Status |
|---|----------|-------|------------|--------|
| 1 | Invalid Elm: parse/canonicalize/nitpick | CaseNegativeIntTest, LetDestructConsTest, LetShadowingTest, AsPatternFuncArgTest | Tests used invalid Elm (neg patterns, cons in let, shadowing, non-exhaustive arg) | FIXED (deleted) |
| 2 | LLVM Translation (unrealized_conversion_cast) | PartialAppCaptureTypesTest | ProjectClosureOpLowering missing i16 truncation for Char | FIXED |
| 3 | Kernel raw-ptr vs HPointer (SIGSEGV) | PolyEscapeRecordTest | C++ kernels boxInt/boxFloat returned raw pointers, not HPointers | FIXED |
| 4 | Closure arity mismatch (SIGABRT) | CombinatorBComposeTest, CombinatorBSumMapTest, CombinatorCConsTest, CombinatorCFlipTest, CombinatorListStringTest, CombinatorTPipeTest, CombinatorTThrushTest, CombinatorTest, CombinatorSpMulTest + elm-test SKI | remaining_arity from static type doesn't match runtime closure arity for combinator-style code | OPEN |
| 5 | LetDestructFuncTupleTest (Missing pattern) | LetDestructFuncTupleTest | Polymorphic accessor + tuple destructuring | OPEN |

---

## FIXED: Category 1 — Invalid Elm Tests (Deleted)

4 tests used Elm language features that are intentionally unsupported:
- **CaseNegativeIntTest**: Negative int literals in patterns (Elm parser doesn't support `-` prefix)
- **LetDestructConsTest**: Cons pattern `h :: t` in let destructuring (not allowed in Elm)
- **LetShadowingTest**: Variable shadowing in nested lets (Elm forbids this)
- **AsPatternFuncArgTest**: Non-exhaustive pattern `(h :: t) as list` in function arg (doesn't cover `[]`)

All deleted per user instruction.

---

## FIXED: Category 2 — ProjectClosureOpLowering i16 Truncation

**Test**: PartialAppCaptureTypesTest
**Error**: `LLVM Translation failed for operation: builtin.unrealized_conversion_cast`

**Root Cause**: `ProjectClosureOpLowering` in `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:63-70` loaded captured value as i64 from closure values array but had no case for i16 (Char). Only handled f64 and pointer types, leaving `unrealized_conversion_cast(i64 → i16)`.

**Fix**: Added i16 truncation case at line 69:
```cpp
} else if (auto intTy = dyn_cast<IntegerType>(resultType); intTy && intTy.getWidth() < 64) {
    result = rewriter.create<LLVM::TruncOp>(loc, resultType, loadedValue);
}
```

**File**: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

---

## FIXED: Category 3 — Kernel boxInt/boxFloat HPointer Encoding

**Test**: PolyEscapeRecordTest
**Error**: SIGSEGV when `eco_resolve_hptr` received raw pointer from kernel

**Root Cause**: `boxInt`/`boxFloat` in `elm-kernel-cpp/src/core/BasicsExports.cpp` returned `reinterpret_cast<uint64_t>(obj)` (raw pointer) instead of HPointer encoding. JIT's `eco.box` uses `eco_alloc_int` which returns HPointers. When kernel result was passed as `!eco.value` and later unboxed via `eco_resolve_hptr`, the raw pointer was misinterpreted.

**Fix**: Changed `boxInt`/`boxFloat` to return HPointers using `Allocator::instance().wrap(obj)`:
```cpp
Elm::HPointer hp = Elm::Allocator::instance().wrap(obj);
return fromHPointer(hp);
```

**File**: `elm-kernel-cpp/src/core/BasicsExports.cpp`

**Collateral fixes**: This also fixed previously-failing tests that relied on kernel arithmetic:
- IntMinMaxTest, TupleSecondTest, TupleTripleTest, LetDestructuringTest, LetDestructTupleNestedTest, LetNestedTest, MultiLocalTailRecTest

---

## OPEN: Category 4 — Closure Arity Mismatch (HIGHEST IMPACT)

**Tests**: 9 E2E Combinator tests + 1 elm-test SKI combinator

**Error**: `eco_closure_call_saturated: argument count mismatch` (SIGABRT)

### Detailed Trace (CombinatorBComposeTest)

**Elm source**:
```elm
k a _ = a
s bf uf x = bf x (uf x)
b = s (k s) k
result = b square inc 4  -- should be 25
```

**Generated MLIR for main (lines 9-11)**:
```
%7 = "eco.papExtend"(%2, %3) {_call_kind = "direct_known_segmentation", remaining_arity = 1}
%8 = "eco.papExtend"(%7, %4) {remaining_arity = 1}  ← WRONG: static type predicts arity 1
%9 = "eco.papExtend"(%8, %6) {remaining_arity = 1}  ← WRONG: actual runtime arity differs
```

**Why it fails**: The compiler computes staging from the static type `b : (Int→Int) → (Int→Int) → Int → Int`, producing stage arities `[1, 1, 1]`. But `b` is defined as `s (k s) k`, a partial application that at runtime returns a PAP of `s_$_7` with `max_values=3, n_values=1, remaining=2`. The second `papExtend` expects `remaining=1` but gets a closure with `remaining=2`.

**Runtime assertion trace**:
1. `b_$_3(square)` calls `s_$_9(lambda_wrapping_s7, k, square)` → returns PAP of `s_$_7` with `n_values=1, max_values=3`
2. `eco_closure_call_saturated(PAP, [inc], 1)` checks: `n_values(1) + num_newargs(1) == max_values(3)` → `2 ≠ 3` → **ABORT**

### Investigation of compiler fix

Attempted fixes in `MonoGlobalOptimize.elm` (sourceArityForExpr, computeCallInfo) and `Staging/Rewriter.elm` did not affect the generated MLIR. The root issue: the Elm canonical optimizer flattens `b square inc 4` into `Call b [square, inc, 4]`, which gets a single `MonoCall`. The call goes through `annotateCallStaging` → `computeCallInfo`, but the pipeline between monomorphization and MLIR generation creates staged calls using type-level stage arities that don't match runtime arities for combinator-composed functions.

Further investigation needed to identify exactly which pass creates the staged papExtend chain and how to make it use generic_apply for opaque returns.

**Attempted fix (runtime fallback)**: Changed `eco_closure_call_saturated` to fall back to `eco_apply_closure` on mismatch. This eliminated the SIGABRT but caused SIGSEGV because the typed-path args are raw unboxed values while the generic path expects HPointer-encoded values. Reverted.

---

## OPEN: Category 5 — LetDestructFuncTupleTest

**Test**: LetDestructFuncTupleTest
**Error**: `Missing pattern: get: 10` (test output doesn't match expected)

**Elm source**: Uses `.a`/`.b` record accessors in tuple destructuring via case branches. The polymorphic accessor returns `!eco.value` but the record has unboxed fields, causing incorrect value propagation.

Needs further investigation — may be related to the accessor monomorphization or unboxed field projection.
