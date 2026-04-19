# Test Failures Report

## Baseline (2026-03-19)
- **elm-test**: 11667 passed, 1 failed
- **E2E**: 923 passed, 16 failed

## Current (2026-04-18, RS4GC migration)
- **elm-test**: 12664 passed, 0 failed (unaffected by backend changes)
- **E2E (full)**: 1018 passed, 1 failed out of 1019 (LetDestructFuncTupleTest pre-existing)
- **Stress**: 3 passed, 28 failed (all failures involve GC-heavy heap allocation; root cause is structural equality / GC interaction — see Category 19)

## Fix Order (by root cause, earliest compiler phase first)

| # | Category | Tests | Root Cause | Status |
|---|----------|-------|------------|--------|
| 1 | Invalid Elm: parse/canonicalize/nitpick | CaseNegativeIntTest, LetDestructConsTest, LetShadowingTest, AsPatternFuncArgTest | Tests used invalid Elm (neg patterns, cons in let, shadowing, non-exhaustive arg) | FIXED (deleted) |
| 2 | LLVM Translation (unrealized_conversion_cast) | PartialAppCaptureTypesTest | ProjectClosureOpLowering missing i16 truncation for Char | FIXED |
| 3 | Kernel raw-ptr vs HPointer (SIGSEGV) | PolyEscapeRecordTest | C++ kernels boxInt/boxFloat returned raw pointers, not HPointers | FIXED |
| 4 | Closure arity mismatch (SIGABRT) | CombinatorBComposeTest, CombinatorBSumMapTest, CombinatorCConsTest, CombinatorCFlipTest, CombinatorListStringTest, CombinatorTPipeTest, CombinatorTThrushTest, CombinatorTest, CombinatorSpMulTest + elm-test SKI | TWO bugs: (1) staging uses type-derived arities that don't match runtime (FIXED via generic_apply fallback), (2) monomorphizer picks wrong k specialization for combinators | SKIPPED (3 attempts — requires deep monomorphizer type unification change) |
| 5 | LetDestructFuncTupleTest (SIGSEGV) | LetDestructFuncTupleTest | Standalone accessor gets generic type; record unboxed_bitmap mismatch | SKIPPED (3 attempts — requires Specialize.elm accessor type propagation) |
| 20 | Alloca-in-loop stack exhaustion | Stress tests with 900K+ closure calls | LLVM::AllocaOp emitted inside loop bodies for args arrays; accumulates stack space | FIXED (hoisted allocas to entry block) |
| 6 | Branch operand mismatch in cf.SwitchOp | CaseSharedBranchTest, CaseReturningLambdaTest, LargeDispatchCaseTest, NestedCaseReturnTest | CaseOpLowering uses mergeBlock as SwitchOp default with 0 operands, but mergeBlock expects 1 | FIXED (2/4 tests pass; 2 have deeper pre-existing bugs) |
| 7 | scf.while do-region has multiple blocks | TailRecCaseMultiBranchTypesTest, TailRecDecoderLoopTest, TailRecMultiCaseWhileTest, TailRecTypeTraversalTest | Elm compiler emits scf.while with nested string eco.case in do-region | SKIPPED (3 attempts) |
| 8 | Unmasked: closure arity + SIGSEGV | CaseReturningLambdaTest (closure_call_saturated), LargeDispatchCaseTest (SIGSEGV) | Previously masked by Category 6 branch bug; now reveal deeper combinator/staging bugs | SKIPPED (same root causes as Cat 4/5) |
| 9 | ptr<1>: Embedded constants as GC roots → undef | construct_constants +14 others | EcoGCPrepare treated embedded constants as GC roots; PromoteMemToReg introduced `undef` → gc.relocate produced garbage 0xfefefefe | FIXED |
| 10 | ptr<1>: Closure wrapper returns `<fn>` | pap_basic +14 others | Codegen .mlir tests had hardcoded `i64` runtime function declarations instead of `ptr<1>` | FIXED |
| 11 | ptr<1>: Closure numeric wrong output | allocate_closure_funcptr +9 others | Same as Cat 10 — hardcoded i64 signatures in test MLIR | FIXED |
| 12 | ptr<1>: Statepoint CHECK pattern | safepoint_loop_gc_relocate | Test expected `ptrtoint` which is no longer emitted with ptr<1> roots | FIXED (removed CHECK: ptrtoint) |
| 13 | BF bf_alloc_large | bf_alloc_large | Was pre-existing; now FIXED as part of BF migration to ptr<1> | FIXED |
| 14 | ptr<1>: C++ HPtr conversion regressions | ~31 E2E tests | Superseded — actually Bool ZExt (Cat 15) + BF mismatch (Cat 16) | RESOLVED |
| 15 | ptr<1>: Constants as GC roots in StatepointConversion | CaseBoolTest +24 others | Constants excluded from GC roots in both EcoGCPrepare and StatepointConversion | FIXED |
| 16 | ptr<1>: BF/Eco type converter unified | All 51 elm-bytes/* + 88 BF codegen tests | BFTypeConverter unified to ptr<1>; all BF test .mlir files updated; bf.read.utf8 null comparison fixed | FIXED |
| 17 | ptr<1>: String case True constant comparison | CaseStringTest +8 others | String case lowering compared ptr<1> result from Elm_Kernel_Utils_equal with i64 True constant; fixed to use ptr<1> True constant via inttoptr | FIXED |
| 18 | ptr<1>: ClosureCaptureTupleTest unrealized cast | ClosureCaptureTupleTest | Tuple deconstruction in closures has unresolvable unrealized_conversion_cast | OPEN |

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

## FIXED: Category 6 — Branch operand mismatch in cf.SwitchOp default

**Tests**: CaseSharedBranchTest (PASS), NestedCaseReturnTest (PASS), CaseReturningLambdaTest (now combinator bug), LargeDispatchCaseTest (now SIGSEGV)
**Error**: `branch has 0 operands for successor #0, but target block has 1`

**Fix**: In `EcoToLLVMControlFlow.cpp:694`, changed general ADT/bool `cf::SwitchOp` to use `caseBlocks.back()` as default destination instead of `mergeBlock`. This matches the pattern used by `lowerIntegerOrCharCase`. Elm cases are exhaustive, so the default is just the last alternative.

**File**: `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`

---

## SKIPPED: Category 7 — scf.while do-region has multiple blocks

**Tests**: TailRecCaseMultiBranchTypesTest, TailRecDecoderLoopTest, TailRecMultiCaseWhileTest, TailRecTypeTraversalTest
**Error**: `'scf.while' op expects region #1 to have 0 or 1 blocks`
**Attempts**: 1

**Root Cause**: The **Elm compiler** (not the C++ backend) emits `scf.while` directly in its
MLIR codegen for tail-recursive functions. When the loop body contains an `eco.case` with
`case_kind = "str"` (string case), this case cannot be lowered to a single-block construct —
it needs `cf.cond_br` chains with runtime string comparison calls. This creates multiple
blocks in the scf.while do-region, violating MLIR's structural invariant.

**Attempt 1**: Tried to reject in `JoinpointNormalization.cpp:hasSimpleCaseDispatch()`, but
the `scf.while` is emitted directly by the Elm compiler — it never goes through joinpoint
normalization or JoinpointToScfWhilePattern in the C++ pipeline.

**Why it can't be fixed in C++ backend**: `applyFullConversion` requires all ops to be legal
at the end. The `eco.case` inside `scf.while` creates a circular dependency:
- If we lower `eco.case` first → multi-block do-region → invalid `scf.while`
- If we defer `eco.case` → `scf.while` is lowered to CF → `eco.case` is now illegal (not inside SCF)

**Required fix**: In the Elm compiler's MLIR codegen (`TailRec.elm`), when the tail-recursive
loop body contains a string case, emit `eco.joinpoint` + `eco.jump` instead of `scf.while`.
The C++ `EcoControlFlowToSCF` pass will then handle SCF lowering for eligible joinpoints,
correctly excluding ones with nested string cases.

---

---

## FIXED: Category 9 — Embedded Constants as GC Roots → undef (ptr<1> migration)

**Tests**: 15 codegen tests — all now pass.

**Fix**: Skip `eco::ConstantOp` results in three places in EcoGCPrepare.cpp where live roots are collected:
1. `computeLiveRoots()` in EcoGCLiveness.h — the `consider` lambda
2. Alloc-group leader union (line ~250)
3. Call safepoint union (line ~344)
4. Safepoint op union (line ~307)

Also updated `codegen/safepoint_statepoint_emission.mlir` to use a heap-allocated value instead of embedded constants as the test root.

**Files**: `EcoGCLiveness.h`, `EcoGCPrepare.cpp`, `safepoint_statepoint_emission.mlir`

---

## OPEN: Category 10 — Closure Wrapper Returns `<fn>` (ptr<1> migration)

**Tests**: 15 codegen tests (all pap_* and allocate_closure_* and call_indirect_* and closure_recursive)

**Error**: Tests expect a numeric result but print `<fn>` (the debug representation of an unevaluated closure)

### Root Cause

The closure calling chain involves:
1. `eco_pap_extend(HPtr closure, uint64_t* args, ...)` → returns new PAP as HPtr
2. When saturated, `eco_closure_call_saturated(HPtr closure, uint64_t* args, ...)` → calls evaluator → returns result HPtr
3. The `getOrCreateWrapper` in EcoToLLVMClosures.cpp creates wrapper functions that:
   - Load i64 args from the void** array
   - Convert eco.value args to ptr<1> via `i64ToValue`
   - Call the target Elm function
   - Convert ptr<1> result to ptr (AS0) for the runtime via `hptrToPtr`

The `<fn>` output means the closure HPtr (the closure OBJECT) is being returned to the caller instead of the closure's COMPUTED RESULT. This indicates the dispatch path is either:
- Not calling the evaluator at all (returning the PAP directly)
- Calling but losing the result somewhere in the ptr<1>→ptr conversion chain

### Debugging Approach

1. Pick `codegen/pap_basic.mlir`. Dump LLVM IR with `ecoc -emit=llvm`.
2. Find the `eco_closure_call_saturated` call and trace its return value through the wrapper.
3. Instrument `getOrCreateWrapper` result path: print the target function's return HPtr bits vs the wrapper's final return value.
4. Check: is the wrapper's result chain `target_result(ptr<1>) → ptrtoint → inttoptr(ptr)` preserving the correct bits?
5. Check: does the CALLER of the wrapper correctly interpret the `ptr` return as an HPtr value?

### Key Code Locations

- `EcoToLLVMClosures.cpp`: `getOrCreateWrapper` (line ~280), result conversion chain (line ~498)
- `EcoToLLVMClosures.cpp`: `emitClosureCall` (line ~920), result interpretation (line ~1025)
- `EcoToLLVMRuntime.cpp`: `eco_closure_call_saturated` declaration (line ~400)

---

## OPEN: Category 11 — Closure Numeric Wrong Output (ptr<1> migration)

**Tests**: 10 codegen tests (allocate_closure_funcptr, call_indirect, call_indirect_closure_only, call_indirect_many_captured, call_indirect_zero_args, closure_higher_order, map_closure, pap_extend_chain_saturate, papextend_exact_saturation, papextend_mixed_unboxed)

**Error**: Tests expect specific numeric values but get different numbers

### Root Cause

Same family as Category 10. These tests reach the point of producing output (unlike Category 10 which gets `<fn>`), but the values are wrong. Likely causes:
- The args array population in `emitRootedBoxedArgsArray` converts ptr<1> values to i64 for the uint64_t* array. If `valueToI64` truncates or reinterprets bits incorrectly, the arguments seen by the evaluator function are wrong.
- The wrapper's argument loading (`i64ToValue` converting loaded i64 back to ptr<1>) may lose bits.
- The result chain from evaluator → wrapper → caller may have an extra indirection or missing conversion.

### Debugging Approach

Same as Category 10 but focus on the ARGUMENT conversion path rather than the result path. Print raw bits at each stage: original ptr<1> → i64 (stored in array) → loaded back → i64ToValue → ptr<1> passed to callee.

---

## OPEN: Category 12 — Statepoint CHECK Pattern (ptr<1> migration)

**Test**: codegen/safepoint_loop_gc_relocate.mlir

**Error**: `Missing pattern: ptrtoint`

### Root Cause

The test's `// CHECK: ptrtoint` expects the old pattern where gc.relocate results (ptr<1>) were converted to i64 via `CreatePtrToInt` before storing into allocas. With ptr<1>-typed roots, allocas are `ptr<1>` and gc.relocate results are stored directly — no ptrtoint.

### Fix

Update the test's CHECK lines to match the new IR shape. Replace `CHECK: ptrtoint` with appropriate patterns (e.g., `CHECK: store ptr addrspace(1)` or `CHECK: gc.relocate`).

---

## OPEN: Category 13 — BF Dialect Not Migrated (ptr<1> migration)

**Test**: codegen-bf/bf_alloc_large.mlir

**Error**: `Missing pattern: 1`

### Root Cause

BFTypeConverter still maps `eco.value → i64` (reverted during migration). The BF test uses raw `i64` types in its MLIR. With runtime functions now expecting HPtr (ptr<1>) on the C++ side, the i64 values don't match.

### Fix

1. Change BFTypeConverter to map `eco.value → ptr<1>` using `getHPtrLLVMType`
2. Change BF runtime function declarations to use `ptr<1>` for Elm values
3. Update BF .mlir tests to use `!eco.value` instead of raw `i64` for heap values
4. Add `valueToI64`/`i64ToValue` at BF heap slot boundaries

---

## RESOLVED: Category 14 — C++ HPtr Conversion Regressions (reclassified)

Most of the ~31 failures previously attributed to C++ HPtr conversion bugs were actually caused by
Bool field ZExtOp (now Category 15) or BF type mismatch (Category 16). The HPtr ABI itself is correct —
`struct HPtr { uint64_t bits; }` is ABI-compatible with `ptr addrspace(1)` on x86-64 SysV ABI (both
pass/return in a single 64-bit register). After fixing Categories 9-12 (codegen tests), the E2E results
improved from 211 failures to 89, confirming the HPtr conversion is sound.

---

## OPEN: Category 15 — Bool Field ZExtOp on ptr<1> (ptr<1> migration)

**Tests (25)**: elm/CaseBoolTest, elm/CaseSingleCtorBoolMultiTypeTest, elm/CaseSingleCtorBoolTest,
elm/EqualityStringChainCaseTest, elm/ListAnyBoolTest, elm/ListMapBoolTest,
elm/SingleCtorPairBoolCharTest, elm/SingleCtorPairBoolFloatTest, elm/SingleCtorPairBoolIntBidiTest,
elm/SingleCtorPairFloatBoolTest, elm/SingleCtorPairStringBoolTest,
elm-core/JsArrayIndexedFilterTest, elm-core/JsArrayPushSliceTest, elm-core/TestIndexedMap, elm-core/TestIndexedMap3,
elm-core/BasicsIsNaNTest, elm-core/DebugToStringTest, elm-core/JsArrayBasicsTest,
elm-json/RoundTripBoolTest, elm/ClosureCaptureBoolTest, elm/CustomTypeMultiFieldTest,
elm/EmbeddedMixedConstantsTest, elm/MaybeJustTest, elm/TypeAliasCtorTest, elm/UnboxWrapperTrueFalseTest

**Error**: SIGSEGV or SIGABRT — all involve Bool values stored in record/custom fields

### Root Cause

In `CustomConstructOpLowering` and `RecordConstructOpLowering` (EcoToLLVMHeap.cpp), the code checks
`origType.isInteger(1)` (Bool) and does `ZExtOp(fieldVal, i64)`. But after type conversion by
EcoTypeConverter, Bool fields that came from `eco.box i1` are embedded constants represented as
`ptr<1>` (via `inttoptr`), NOT raw `i1`. Attempting `ZExtOp` on a `ptr<1>` is invalid and produces
garbage, which later crashes when resolved via `eco_resolve_hptr`.

The existing helper `widenFieldToI64` (EcoToLLVMHeap.cpp:443) already handles `ptr<1>` correctly
via `PtrToIntOp`, but is NOT used in Custom/RecordConstructOpLowering — those use ad-hoc ZExt instead.

### Fix

In `EcoToLLVMHeap.cpp`, in both `CustomConstructOpLowering::matchAndRewrite` and
`RecordConstructOpLowering::matchAndRewrite`, replace the Bool field branch:

```cpp
// BEFORE (broken):
} else if (origType.isInteger(1) || origType.isInteger(16)) {
    auto extended = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
    rewriter.create<LLVM::CallOp>(loc, storeI64Func, ...{extended});
}

// AFTER (correct):
} else if (origType.isInteger(1) || origType.isInteger(16)) {
    // fieldVal may be ptr<1> (boxed Bool) or i1/i16 (unboxed).
    // widenFieldToI64 handles all cases correctly.
    Value widened = widenFieldToI64(fieldVal, loc, rewriter);
    rewriter.create<LLVM::CallOp>(loc, storeI64Func, ...{widened});
}
```

The `widenFieldToI64` function (line 443) already has the correct logic:
- `ptr<1>` → `PtrToIntOp(ptr<1> → i64)` (preserves embedded constant bits)
- `i1`/`i16` → `ZExtOp(narrow → i64)`
- `i64` → passthrough
- `f64` → `BitcastOp`

### Key Files

- `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` — CustomConstructOpLowering (~line 785), RecordConstructOpLowering (~line 670)

---

## OPEN: Category 16 — BF/Eco Type Converter Mismatch (ptr<1> migration)

**Tests (52)**: All 51 elm-bytes/* tests + elm/ClosureCaptureTupleTest

**Error**: `Failed to create execution engine: could not convert to LLVM IR` — unrealized_conversion_cast remains

### Root Cause

BFTypeConverter (in BFToLLVM.cpp) maps `eco.value → i64`, while EcoTypeConverter maps `eco.value → ptr<1>`.
When BF-lowered code (which produces `i64` for Elm values) feeds into Eco-lowered code (which expects
`ptr<1>`), the dialect conversion creates `unrealized_conversion_cast(i64 → ptr<1>)` ops. The reconcile
pass cannot resolve these because there's no IntToPtrOp/PtrToIntOp insertion rule for unrealized casts.

ClosureCaptureTupleTest has a similar type bridge issue — tuple deconstruction in closures hits a path
where the type converter produces an unresolvable cast.

### Fix (preferred: unify BF on ptr<1>)

1. **BFTypeConverter**: Change `eco.value → i64` to `eco.value → getHPtrLLVMType(ctx)` (ptr<1>)
2. **BF runtime declarations**: Change LLVM declarations for `elm_alloc_bytebuffer`, `elm_bytebuffer_len`,
   `elm_bytebuffer_data`, `elm_utf8_*`, `elm_maybe_*`, `elm_list_reverse` to use `ptr<1>` for HPtr params/returns
3. **BF .mlir test files**: 88 files under `test/bf-codegen/` use raw `i64` for BF op result types.
   Change them to use `!eco.value` and let the type converter handle mapping to `ptr<1>`.
   This is a large mechanical change but each file is small.
4. **ClosureCaptureTupleTest**: Re-test after BF unification. If it still fails, look for remaining
   `unrealized_conversion_cast(i64 ↔ ptr<1>)` not from BF.

### Fix (fallback: insert explicit casts at BF→Eco boundary)

Add a post-conversion canonicalization that replaces `unrealized_conversion_cast(i64 → ptr<1>)` with
`IntToPtrOp` and `cast(ptr<1> → i64)` with `PtrToIntOp`. Brittle — the unification approach is preferred.

### Key Files

- `runtime/src/codegen/Passes/BFToLLVM.cpp` — BFTypeConverter (line ~47), ensureRuntimeFunctions (line ~87)
- `runtime/src/allocator/ElmBytesRuntime.h/.cpp` — C++ already uses HPtr (updated earlier)
- `test/bf-codegen/*.mlir` — 88 files need `i64` → `!eco.value` for BF op result types

---

## OPEN: Category 17 — String Case Lowering ABI (ptr<1> migration)

**Tests (5 new + 4 pre-existing)**: elm/CaseStringTest, elm/CaseStringEscapeTest,
elm/CaseStringManyBranchTest, elm/EqualityIntPapWithStringChainTest,
elm-json/JsonDecoderSelfRecursiveNoLazyTest (new);
CaseSharedBranchTest, CaseReturningLambdaTest, LargeDispatchCaseTest, NestedCaseReturnTest (pre-existing Cat 6/8)

**Error**: `JIT execution failed: Lowering pipeline failed`

### Root Cause

String case lowering in `EcoToLLVMControlFlow.cpp` emits a `func::CallOp` to `Elm_Kernel_Utils_equal`.
During the Eco→LLVM conversion, this `func::CallOp` must be lowered to `llvm.call`. The kernel
function's LLVM declaration has `(ptr<1>, ptr<1>) → ptr<1>` signature (set by KernelFuncOpLowering),
but the `func::CallOp` lowering encounters a type mismatch — the call's operand or result types
don't resolve cleanly through the standard FuncToLLVM conversion path.

The 4 pre-existing failures (CaseSharedBranch, CaseReturningLambda, LargeDispatch, NestedCaseReturn)
have deeper bugs from Category 6/8, not caused by ptr<1>.

### Fix

In `EcoToLLVMControlFlow.cpp`, the string case lowering (lowerStringCase method) should emit an
`LLVM::CallOp` directly instead of `func::CallOp`, bypassing the FuncToLLVM conversion:

```cpp
// Use EcoRuntime to get the LLVM-level kernel function
auto equalFunc = runtime.getOrCreateUtilsEqual(rewriter);

// Both scrutinee and pattern are already ptr<1> from type converter
auto call = rewriter.create<LLVM::CallOp>(loc, equalFunc,
    ValueRange{scrutineeVal, patternVal});
Value eqResult = call.getResult();

// Unbox Bool result: compare with True constant (also ptr<1>)
auto hptrTy = getHPtrLLVMType(*ctx);
Value trueI64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
    value_enc::encodeConstant(value_enc::True));
Value trueConst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
Value isEqual = rewriter.create<LLVM::ICmpOp>(loc,
    LLVM::ICmpPredicate::eq, eqResult, trueConst);
```

This keeps everything in the LLVM dialect and avoids the func::CallOp → llvm.call conversion
path that fails.

### Key Files

- `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` — lowerStringCase method (~line 292)

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

---

## OPEN: Category 19 — Structural equality (`==`) returns wrong results after GC

**Tests**: stress-elm/ListReverseStressTest + 27 other stress tests
**Error**: `roundtrip: False` (data comparison fails) or SIGSEGV/SIGABRT (heap corruption)

### Root Cause (revised 2026-04-18 — thorough re-investigation)

**Previous hypothesis was wrong.** The GC root tracking is NOT the bug. Thorough
investigation with instrumented GC (unconditional post-GC validation of all stackmap
roots and stack root ranges) proved:

1. All stackmap roots are correctly discovered (18-20 indirect locations per GC cycle)
2. All stack root ranges are correctly evacuated
3. No roots point to from-space after GC completes
4. The EcoPtrIntVerify pass finds zero violations in the compiled LLVM IR

**The actual bug is genuine heap corruption from GC.** Evidence:

| Test variant | Result |
|---|---|
| 10 elements, 10 reverses, `start == finished` | **PASS** (no GC triggered) |
| 1000 elements, 60 reverses, `start == finished` | **PASS** (1 GC cycle) |
| 1000 elements, 100 reverses, `start == finished` | **FAIL** (3 GC cycles) |
| 1000 elements, 100 reverses, pairwise comparison | **FAIL** — wildcard case hit (one list appears as `[]`) |
| 1000 elements, 1000 reverses, pairwise comparison | **FAIL** — same (10000 mismatches = wildcard) |
| 100 elements, 100 reverses, pairwise comparison | **PASS** (low GC pressure — lucky) |

After multiple GC cycles, list cons cells have corrupted structure — one list's
first cons cell appears as Nil to pattern matching. Individual `List.length` calls
sometimes return correct values (different code path), but structural traversal
via pattern match or `==` sees corruption.

With ECO_GC_DEBUG=ON, the assertion `hdr->tag < Tag_Forward && "Invalid tag after
forward resolution"` fires (SIGABRT), confirming the forwarding chain is corrupted.

### What was ruled out

1. **Stackmap root discovery**: instrumented GC shows 18-20 indirect stackmap roots
   correctly discovered and evacuated per cycle.
2. **Stack root range tracking**: all `eco_gc_push_stack_range` ranges are correctly
   evacuated. Post-GC unconditional validation confirms NO roots point to from-space.
3. **EcoPtrIntVerify**: zero violations in compiled LLVM IR (all ptrtoint/inttoptr
   involving ptr<1> follow allowed boundary patterns).
4. **gc-leaf marking**: marking `Elm_Kernel_Utils_equal` as gc-leaf does not fix it,
   confirming the issue is in the data, not the comparison mechanism.
5. **Hybrid DFS list copying**: disabling `use_hybrid_dfs` does not fix it.

### Mechanism (not yet fully identified)

The LLVM-compiled `List_foldl` function loads cons tail fields via:
```llvm
%16 = call ptr @eco_resolve_hptr(ptr addrspace(1) %6)  ; resolve cons → raw ptr
%17 = getelementptr i8, ptr %16, i64 16                ; tail field offset
%18 = load i64, ptr %17                                 ; load tail as i64
%19 = inttoptr i64 %18 to ptr addrspace(1)              ; i64 → ptr<1>
```
The raw pointer `%16` is from gc-leaf `eco_resolve_hptr` — no GC during the load.
The resulting `%19` is in the gc-live bundle for subsequent statepoints. RS4GC
should track it correctly.

One remaining hypothesis: the **double-rooting** of the args array (once by compiled
code via `eco_gc_push_stack_range`, then again by `eco_apply_closure` C++ runtime)
may cause a subtle ordering issue where the same HPointer slot is updated by two
different root sources in the same GC cycle.

### Affected tests (28 of 31 stress tests)

**Category A — Wrong result (4 tests):** CharListRoundtrip, ClosureCaptureVary,
DeepTreeMap, ListReverseStressTest

**Category B — SIGSEGV (22 tests):** DictFoldRebuild, DictFromListToList,
DictUnionDiff, DictMapRoundtrip, ListConcatMap, ListFilterRebuild, ListMapRoundtrip,
ListIntersperse, ListSort, ListZipUnzip, MaybeChainMap, MixedAlloc, MultiVariantADT,
NestedListMap, NestedMaybeMap, NestedRecord, PartialAppList, RecordUpdateList,
ResultMapChain, SetBuildFold, TreeBuildFold, TupleMapList

**Category C — SIGABRT (2 tests):** ClosureAccum, TailRecurseCallback

**Passing (3 tests):** TailRecurse (no heap alloc), StringSplitJoin, StringBuildChunk
(C++ kernel only, no LLVM-compiled list ops)

### Key Files

- `elm-kernel-cpp/src/core/Utils.cpp:244` — `eqHelp` structural equality traversal
- `elm-kernel-cpp/src/ExportHelpers.hpp:47` — `Export::toPtr` HPointer → raw ptr
- `runtime/src/allocator/RuntimeExports.cpp:1047` — `eco_apply_closure` double-rooting
- `runtime/src/allocator/NurserySpace.cpp:458` — Phase 1e stack range evacuation

**Status:** SKIPPED (3 attempts)
**Attempts:** 3 (1: C++ kernel ListOps fix; 2: gc-leaf on Utils_equal — no effect; 3: full instrumented investigation ruled out stackmap/root-range tracking bugs, identified alloca-in-loop as separate issue (Cat 20, FIXED), but GC corruption mechanism remains unidentified)
**Trace report:** See `/work/gc-stress-trace-report.md` for full investigation details.

---

## FIXED: Category 20 — Alloca-in-loop stack exhaustion (stress tests)

**Tests**: Stress tests with 900K+ closure call iterations (TailRecurseCallback, MinGcTest reproducer)
**Error**: SIGSEGV with 0 GC cycles (stack overflow, not GC corruption)

### Root Cause

`LLVM::AllocaOp` in `emitRootedBoxedArgsArray` (EcoToLLVMClosures.cpp:106) and 3 other
sites was emitted at the current insertion point, which for `papExtend` ops inside
`scf.while` loop bodies placed the alloca inside the loop. Each iteration allocated stack
space that was never freed, causing stack overflow after ~900K iterations (8 bytes per
alloca * 900K = 7.2MB, exceeding the 8MB stack limit).

### Fix

Hoisted all 4 args-array `AllocaOp` emissions to the function entry block using
`InsertionGuard` + `setInsertionPointToStart(entryBlock)`. The alloca becomes a fixed-size
stack frame slot that is reused (via memset zero-init) on each iteration.

**Note:** `llvm.stacksave`/`llvm.stackrestore` was tried first but CANNOT be used because
RS4GC may spill gc-live values to the same stack region; `stackrestore` would invalidate
those spill slots, causing crashes in `collectStackRootsFromStackMap`.

### Files Changed

- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — 4 alloca sites hoisted to entry block

### Verification

- MinGcTest (1M iterations, 16 GC cycles): PASSED
- E2E tests: 1018/1019 passed (zero regressions)
- Stress tests: same pass/fail count (alloca fix only prevents stack overflow; GC corruption from Category 19 remains)
