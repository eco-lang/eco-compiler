# Test Failures Report

## Baseline (2026-03-19)
- **elm-test**: 11667 passed, 1 failed
- **E2E**: 923 passed, 16 failed

## Current (after this session)
- **elm-test**: 11667 passed, 1 failed (unchanged — pre-existing CGEN_056 SKI combinator result type)
- **E2E**: 925 passed, 10 failed (unchanged count but staging fix applied: 2 partial code fixes)
- **Code changes**: Staging generic_apply fallback in Expr.elm + closureBodyStageArities fix in MonoGlobalOptimize.elm

## Fix Order (by root cause, earliest compiler phase first)

| # | Category | Tests | Root Cause | Status |
|---|----------|-------|------------|--------|
| 1 | Invalid Elm: parse/canonicalize/nitpick | CaseNegativeIntTest, LetDestructConsTest, LetShadowingTest, AsPatternFuncArgTest | Tests used invalid Elm (neg patterns, cons in let, shadowing, non-exhaustive arg) | FIXED (deleted) |
| 2 | LLVM Translation (unrealized_conversion_cast) | PartialAppCaptureTypesTest | ProjectClosureOpLowering missing i16 truncation for Char | FIXED |
| 3 | Kernel raw-ptr vs HPointer (SIGSEGV) | PolyEscapeRecordTest | C++ kernels boxInt/boxFloat returned raw pointers, not HPointers | FIXED |
| 4 | Closure arity mismatch (SIGABRT) | CombinatorBComposeTest, CombinatorBSumMapTest, CombinatorCConsTest, CombinatorCFlipTest, CombinatorListStringTest, CombinatorTPipeTest, CombinatorTThrushTest, CombinatorTest, CombinatorSpMulTest + elm-test SKI | TWO bugs: (1) staging uses type-derived arities that don't match runtime (FIXED via generic_apply fallback), (2) monomorphizer picks wrong k specialization for combinators | SKIPPED |
| 5 | LetDestructFuncTupleTest (Missing pattern) | LetDestructFuncTupleTest | Standalone accessor gets generic type; record unboxed_bitmap mismatch | SKIPPED |

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

## SKIPPED: Category 4 — Combinator Closure Bugs (TWO ROOT CAUSES)

**Tests**: 9 E2E Combinator tests + 1 elm-test SKI combinator

### Root Cause 1: Staging Arity Mismatch (FIXED)

`closureBodyStageArities` returned type-derived stage arities `[1, 1]` for closures whose body is a call (e.g., `b = s (k s) k`). At runtime, the returned closure has different staging (remaining=2 instead of [1,1]). `applyByStages` emitted papExtends with wrong `remaining_arity`, causing `eco_closure_call_saturated` assertion failures.

**Fix applied**:
1. `MonoGlobalOptimize.elm:closureBodyStageArities`: Returns `Nothing` when closure body is an opaque call returning a function type (instead of trusting type-derived arities)
2. `Expr.elm:applyByStages`: When `sourceRemaining <= 0` and args remain (unknown staging), emits a single generic papExtend (no `remaining_arity`) with `_call_kind = "generic_apply"`, forcing runtime `eco_apply_closure` dispatch. Adds `eco.unbox` if caller expects non-boxed result type.

### Root Cause 2: Monomorphization Wrong Specialization (NOT FIXED)

The monomorphizer picks wrong specialization of `k` for combinator `b = s (k s) k`. The trailing `k` in `s (k s) k` should be specialized as `(!eco.value, i64) → !eco.value` (since k receives `Int→Int` as first arg and `Int` as second), but gets specialized as `(i64, i64) → i64`.

**Type derivation**: In `b : (Int→Int) → (Int→Int) → Int → Int`, the trailing `k` used as `uf` in `s bf uf x = bf x (uf x)` has type `(Int→Int) → Int → (Int→Int)` where:
- First param = `Int→Int` (a function type → `!eco.value`)
- Second param = `Int` → `i64`
- Return = `Int→Int` (a function type → `!eco.value`)

**Why monomorphization fails**: The monomorphizer resolves `k`'s canonical type `a → b → a` using the outer substitution, which maps all type variables to `Int` (from `b`'s overall result type being `Int`). It doesn't distinguish between `Int` and `Int→Int` for the first parameter.

**Attempted fixes**:
1. Deferred VarGlobal processing with `isFunctionType` check → PendingGlobal resolved but `paramType` from `s`'s unified type already has wrong `Int` types
2. The `unifyCallSiteWithRenaming` for the call `s [(k s), k]` computes `s`'s second parameter type incorrectly because the type variable `b` in `s`'s type is resolved through complex combinator composition that the current unification doesn't properly handle

**Impact**: After staging fix, tests crash with SIGSEGV instead of SIGABRT because `k_$_8(i64, i64) → i64` evaluator wrapper tries to unbox a closure HPointer as an Int.

**Required fix**: Deep change to the monomorphizer's type unification for combinator-composed partial applications, ensuring intermediate types (like `k`'s first param being `Int→Int`) are correctly propagated through the unification chain.

---

## SKIPPED: Category 5 — LetDestructFuncTupleTest (Record Accessor Monomorphization)

**Test**: LetDestructFuncTupleTest
**Error**: `Missing pattern: get: 10` / SIGSEGV (after staging fix)

### Root Cause

Two interconnected issues with standalone record accessors stored in tuples:

**Issue 1: Accessor has generic type**
The accessor `.a` in `( .a, \x m -> { m | a = x } )` is specialized as `(!eco.value) → !eco.value` instead of `(!eco.value) → i64`. This happens because:
- The accessor's canonical type is `{ a : v | r } → v` with row variable `r` and field type `v`
- `Specialize.elm:1975` handles standalone accessors by applying the outer substitution to the canonical type
- The outer substitution doesn't bind the accessor's row variable `r` (it's a fresh variable from the accessor's type scheme)
- `forceCNumberToInt` preserves `MVar _ CEcoValue` for the field type, resulting in `!eco.value` return type
- The accessor body uses `eco.project.record → !eco.value`, which loads the raw i64 value (10) from the unboxed field and treats it as an HPointer → SIGSEGV

**Issue 2: Setter creates record with wrong unboxed_bitmap**
The setter lambda `\x m -> { m | a = x }` takes `(!eco.value, !eco.value)` params and constructs a record with `unboxed_bitmap = 0` (all boxed). But the caller projects field 0 as `i64` (expecting unboxed), getting HPointer bits instead of the raw int value.

### Attempted Fixes

1. **RecordProjectOpLowering bitmap check**: Added runtime `unboxed_bitmap` checking in `eco.project.record` lowering for both `!eco.value → box if unboxed` and `i64 → unbox if boxed` cases. The `!eco.value` case caused 27 regressions (unnecessary `eco_alloc_int` calls on every record projection). The `i64` case with `eco_unbox_field_i64` helper also caused regressions (LLVM function linkage issues). Reverted.

### Required Fix

The accessor monomorphization needs to be fixed in `Specialize.elm:1975-2001`:
- When a standalone accessor appears in a context where its record type is known (e.g., inside a function with typed parameters), the accessor's type variables should be unified with the expected record type from the surrounding context
- This requires propagating the enclosing function's record parameter type into the case branch where the accessor appears
- Alternatively, the `PendingAccessor` mechanism (currently only for call arguments) should be extended to handle standalone accessors in tuple expressions
- The setter lambdas should also inherit the correct `unboxed_bitmap` from the original record type
