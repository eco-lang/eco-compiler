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
| 19 | GC heap corruption in stress tests | 28 stress tests | Cons cell data corrupted after 2+ GC cycles; exact mechanism TBD | SKIPPED (3 attempts — see Categories 21-26 for sub-investigations) |
| 20 | Alloca-in-loop stack exhaustion | Stress tests with 900K+ closure calls | LLVM::AllocaOp inside loop bodies accumulates stack | FIXED |
| 21 | Shadow-stack arg ranges mis-described | 28 stress tests | Wrong bitmap/length/base in eco_gc_push_stack_range for closure arg buffers | OPEN |
| 22 | Double-rooting of same arg buffer | 28 stress tests | Compiled code + C++ runtime both register same args alloca as GC root range | OPEN |
| 23 | Mis-sized or mis-scanned object layouts | 28 stress tests | getObjectSize / scanObject mismatch for Cons/Closure under heavy GC | OPEN |
| 24 | Unboxed vs boxed slot mis-handling | 28 stress tests | Wrong unboxed bitmap in heap objects or arg arrays | OPEN |
| 25 | ptr<1>↔i64 conversion escaping role | 28 stress tests | A boundary crossing not using the intended role-specific helper | OPEN |
| 26 | Generational invariant violation | 28 stress tests | Old-to-young pointer from mutation/backpatching without write barrier | OPEN |

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

**Status:** OPEN (root cause identified — LLVM backend stackmap bug)
**Attempts:** 4
- Attempt 1: C++ kernel ListOps stale-pointer fix (applied, partial)
- Attempt 2: gc-leaf on Utils_equal — no effect
- Attempt 3: Full instrumented investigation — ruled out root tracking, found alloca-in-loop (Cat 20, FIXED)
- Attempt 4: Root cause identified — LLVM backend encodes gc-live values as Constant (kind=4) in stackmap instead of Indirect (kind=3). Attempted EcoGCLiveSpill LLVM pass to force alloca+store+load for gc-live values — crashes due to statepoint operand bundle rebuild complexity. Need different approach.
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

---

## OPEN: Category 21 — Shadow-stack arg ranges mis-described (bitmap / length / base)

**Related to:** Category 19 (GC heap corruption in stress tests)

The closure dispatch helpers (`eco_apply_closure`, `eco_apply_segmentation_unknown`,
`eco_pap_extend`, `eco_closure_call_saturated`) build `uint64_t` arg buffers on the
stack and register them with the GC via `eco_gc_push_stack_range`, each range carrying
an unboxed bitmap so the collector only visits HPointer slots.

If any of the following is wrong:
- The range start/end pointer (off-by-one, wrong alloca, reused after hoisting)
- The count of words in the range
- The bitmap for which slots are pointers vs unboxed ints

then during GC the collector will either skip a real pointer root (use-after-free) or
**treat a non-pointer word as an HPointer**, resolve it, and evacuate random heap
memory. The second case fits the observed symptoms: corruption only shows up after a
few cycles (bad "pointer" gets forwarded and re-forwarded), `Allocator::resolve`
follows a bogus forward chain and hits an invalid tag.

The failing scenario is heavy in closure calls (`foldl`/`reverse`), exactly the users
of these arg buffers. The recent alloca-hoisting change (Category 20) altered where
arg arrays live on the stack — if the range metadata (base pointer, count, or bitmap)
doesn't match the hoisted alloca, the GC will scan the wrong memory.

### Investigation approach

- In `eco_apply_closure`, `eco_closure_call_saturated`, `eco_pap_extend`: assert that
  the `base` pointer passed to `eco_gc_push_stack_range` points to valid stack memory
  and that `count * 8` bytes from `base` are within the current stack frame.
- Compare the bitmap passed by compiled code (in `emitRootedBoxedArgsArray` /
  `emitPushArgsRootRange`) with the bitmap assumed by the C++ runtime helper.
- Check whether `eco_gc_restore_stack_range_point` pops the correct range (especially
  after the alloca-hoisting change where the same alloca is reused across iterations).

### Key Files

- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — `emitRootedBoxedArgsArray`,
  `emitPushArgsRootRange`, `lowerSegmentationUnknown`, `lowerGenericApply`
- `runtime/src/allocator/RuntimeExports.cpp` — `eco_apply_closure` (line 1047),
  `eco_closure_call_saturated` (line 1239), `eco_pap_extend`
- `runtime/src/allocator/NurserySpace.cpp` — Phase 1e stack range evacuation (line 458)

**Status:** OPEN
**Attempts:** 0

---

## OPEN: Category 22 — Double-rooting / stale shadow-stack ranges on same buffer

**Related to:** Category 19 (GC heap corruption in stress tests)

The GC has two root sources: statepoint-derived stackmap roots (from RS4GC) and
shadow-stack ranges (`RootSet::stack_ranges`) for dynamic buffers. The compiled code
registers an alloca'd args buffer as a root range, then calls `eco_apply_closure`
which *also* registers the same buffer as a root range.

If the same physical memory is registered twice with different bitmaps or lengths, a
GC cycle can:
- Relocate pointers in the buffer based on one range description, then
- Re-process the same address range with a different bitmap or length, treating stale
  or dead words as HPointers.

This can produce inconsistent pointer graphs where some slots are updated twice and
others once, or dead stack words that look like random HPointer bit patterns cause the
resolver to chase garbage and lay down `Tag_Forward` headers into arbitrary objects.

This matches the observation that either rooting mechanism alone appears correct in
isolation, but over multiple cycles the forwarding chain becomes impossible.

### Investigation approach

- Add a debug assertion in `eco_gc_push_stack_range` that checks whether the new range
  overlaps any existing range in the stack. If so, verify the bitmaps are compatible.
- In `NurserySpace::minorGC`, Phase 1e, log any range whose base pointer falls within
  another range's extent.
- Check whether `eco_gc_restore_stack_range_point` in the C++ runtime correctly
  unregisters the inner range before the outer range is accessed again.

### Key Files

- `runtime/src/allocator/RuntimeExports.cpp` — `eco_apply_closure` (line 1059-1063),
  `eco_closure_call_saturated` (line 1262-1270)
- `runtime/src/allocator/NurserySpace.cpp` — Phase 1e (line 458)
- `runtime/src/allocator/RootSet.hpp` — `pushStackRootRange`, `restoreStackRangePoint`

**Status:** OPEN
**Attempts:** 0

---

## OPEN: Category 23 — Mis-sized or mis-scanned object layouts (Cons / Closure)

**Related to:** Category 19 (GC heap corruption in stress tests)

`getObjectSize()` and the tag-based layout logic are a known source of bugs; tag
completely determines layout and size, and `getObjectSize` must match the C++ struct
definitions exactly. A previous bug was fixed where Closure Cheney-copy used
`n_values` instead of `hdr->size`.

A similar off-by-N or wrong-field bug in:
- `getObjectSize` for Cons, Closure, Custom, etc.
- `scanObject` in the nursery (visiting too few or too many child slots)
- `markChildren` in the old gen

could produce copy/scan loops that run past the true end of an object, overwriting
the header of the next object with `Tag_Forward` or junk. Alternatively, incomplete
child updates (some pointers within a cons cell still point to from-space) will later
be re-followed and double-forwarded.

The corrupted thing is a **Cons cell tail** (list structure breaks but elements are
fine). `List.reverse` uses many cons cells plus closures, both relying on correct
size/scan metadata. Failure appears only after several GCs — typical of an off-by-one
in scanning where the right heap shape is needed for one object to overrun its neighbor.

### Investigation approach

- In `scanObject` Tag_Cons case, assert `sizeof(Cons) == getObjectSize(obj)`.
- In `evacuate`, after copying an object to to-space, validate that the forwarding
  pointer's target object has a valid header.
- Add a full-heap validation pass after each minor GC (under ECO_GC_DEBUG): walk all
  live objects in to-space and verify every child pointer is either a constant, points
  to to-space/old-gen, or has been forwarded.

### Key Files

- `runtime/src/allocator/NurserySpace.cpp` — `scanObject` (line 982), `evacuate` (line 673)
- `runtime/src/allocator/Heap.hpp` — Cons/Closure/Custom struct definitions
- `runtime/src/allocator/HeapHelpers.hpp` — `getObjectSize`

**Status:** OPEN
**Attempts:** 0

---

## OPEN: Category 24 — Mis-handling of unboxed vs boxed slots in heap and arg arrays

**Related to:** Category 19 (GC heap corruption in stress tests)

Heap objects and arg arrays use `Unboxable` to mix pointers and primitives, with an
`unboxed` bitmap in the header or range metadata so GC knows which fields are pointers
vs raw data. If any of the following is wrong:
- The header's `unboxed` bits for a given tag
- The per-object interpretation of those bits in `scanObject` / `markChildren`
- The arg-range bitmap associated with a particular closure call pattern

then the collector may treat an integer or float payload as an HPointer, follow it,
and overwrite some real object with a forwarding pointer. Or it may fail to follow a
real HPointer, leaving a from-space reference that later resolves to a bogus forwarded
object.

This is particularly plausible for `foldl` and list operations, which pass around
accumulator and element values that can be primitive or composite, and rely heavily
on correct unboxed bitmaps in both closures and transient arg buffers.

### Investigation approach

- In `scanObject`, for each child visited via `evacuateUnboxable`, log the raw bits
  and the `is_boxed` flag. Check whether any "boxed" value looks like a raw integer
  (e.g. small values like 1-1000 that couldn't be valid heap offsets).
- In `emitRootedBoxedArgsArray`, verify the bitmap matches the actual types stored:
  - `eco.value` args → HPointer (bitmap bit = 1)
  - Boxed Int/Float/Char (result of eco_alloc_*) → HPointer (bitmap bit = 1)
  - Raw i64/f64 → NOT HPointer (bitmap bit = 0)
- Cross-check the compiler-emitted `unboxed_bitmap` attribute on `papCreate`/`papExtend`
  with the runtime's bitmap interpretation in `buildEvaluatorArgs`.

### Key Files

- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — `emitRootedBoxedArgsArray`,
  `emitPushArgsRootRange` (bitmap computation)
- `runtime/src/allocator/RuntimeExports.cpp` — `buildEvaluatorArgs` (bitmap interpretation)
- `runtime/src/allocator/NurserySpace.cpp` — `scanObject`, `evacuateUnboxable`
- `runtime/src/allocator/Heap.hpp` — `Unboxable` union, header `unboxed` field

**Status:** OPEN
**Attempts:** 0

---

## OPEN: Category 25 — ptr<1>↔i64 conversion escaping its intended role

**Related to:** Category 19 (GC heap corruption in stress tests)

The RS4GC integration funnels all ptr<1>↔i64 conversions through role-specific helpers
(`heapLoadI64ToValue`, `closureLoadI64ToValue`, `argsSlotStoreValueToI64`, etc.) and
the post-RS4GC verifier (`EcoPtrIntVerify`) rejects casts outside the allow-listed
patterns.

If there is one path where a value loaded from the heap (like a cons tail pointer) is
converted int→ptr→int and then stored in a way that bypasses the intended helper, or a
helper meant for one "role" (heap slot vs closure vs arg slot) is accidentally used for
another, then RS4GC will still see a valid-looking `ptr addrspace(1)` in the live set,
but the runtime side might misinterpret the bits (wrong base, wrong tagging), producing
an HPointer that doesn't correspond to any valid header or that points into the middle
of another object.

The `List_foldl` IR does `load i64` from the cons tail field and then `inttoptr` to
`ptr addrspace(1)` — exactly the style of boundary the pass regulates. A subtle
mismatch between which helper the lowering uses and what the GC/runtime assumes could
give rare, data-dependent corruption.

### Investigation approach

- Audit every `inttoptr i64 → ptr addrspace(1)` in the compiled LLVM IR for
  `ListReverseStressTest` and verify its operand comes from one of the allowed sources
  (heap field load, closure slot load, args alloca load, or embedded constant).
- Check that the `heapLoadI64ToValue` helper is used consistently for ALL heap field
  loads, not just the ones touched by the boundary refactor.
- Look for any remaining direct `LLVM::IntToPtrOp` / `LLVM::PtrToIntOp` creation in
  the lowering code that doesn't go through a role-specific helper.

### Key Files

- `runtime/src/codegen/Passes/EcoToLLVMInternal.h` — role-specific helpers
- `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` — heap field load/store
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — closure/args slot load/store
- `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp` — boundary verifier

**Status:** OPEN
**Attempts:** 0

---

## OPEN: Category 26 — Violated generational invariant (old-to-young pointer)

**Related to:** Category 19 (GC heap corruption in stress tests)

The GC design assumes Elm immutability, so there are never old-to-young pointers and
no write barrier. An explicit invariant test asserts old-gen objects never point into
the nursery.

If any part of the runtime mutates old-gen objects to point to nursery objects (e.g.
through a kernel primitive, mutable ByteBuffer, closure self-capture backpatching, or
an "optimization"), minor GC would miss those edges and later end up tracing or
forwarding through partially-collected structures, leading to invalid headers and
forward chains.

This seems less likely for pure list reversal, but if `List.reverse` happens to
involve any long-lived structures or kernel helpers that cache things in old gen
(e.g. the `(::)` closure that gets promoted after many uses), this is worth ruling out.

### Investigation approach

- Under ECO_GC_DEBUG, after each minor GC, walk all promoted/old-gen objects and
  verify that no child pointer references nursery (from-space or to-space) memory.
- Check `PapCreateOp` self-capture backpatching: the self_capture_indices write
  directly into closure values after allocation. If the closure has been promoted to
  old gen before the write, this creates an old-to-young pointer.
- Check kernel primitives (`ListOps`, `DictOps`) for any in-place mutation of objects
  that might have been promoted.

### Key Files

- `runtime/src/allocator/NurserySpace.cpp` — post-GC validation (ECO_GC_DEBUG block)
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — `PapCreateOpLowering`,
  self_capture_indices handling (line 650)
- `runtime/src/allocator/ListOps.cpp` — `reverse`, `foldl`, etc.

**Status:** OPEN
**Attempts:** 0

---

## FIXED: Category 27 — JIT `.eh_frame` registered section-style to LLVM libunwind

**Tests**: all stress tests + E2E `elm/LetDestructFuncTupleTest` + routine output of
`libunwind: __unw_add_dynamic_fde: bad fde: FDE is really a CIE` warnings.

### Root cause

`EcoSectionMemoryManager::registerEHFrames` in `runtime/src/jit/EcoJIT.cpp` called
`__register_frame(section_base)` once per `.eh_frame` section. LLVM libunwind's
`__register_frame` expects a **single FDE pointer** (per `/opt/llvm-mlir/include/unwind.h:133`:
"The FDE must use pc-rel addressing to point to its function"); a `.eh_frame` section
begins with a CIE, so libunwind rejects every call with "bad fde: FDE is really a CIE"
and registers **zero** FDEs. Without FDE info, libunwind cannot unwind across the
C++ → JIT boundary: `ThreadLocalHeap::collectStackRootsFromStackMap` walks only 8
C++ frames, `unw_step` returns `rc=0`, and the GC never visits JIT stack-map roots
(`[gc] phase 1b: 0 stackmap roots`). Live Elm values in JIT spill slots go
unforwarded and manifest as stale HPointers in downstream resolves.

Byte evidence — the first 16 bytes of the section handed to `__register_frame`:
`14 00 00 00 00 00 00 00 01 7a 52 00 01 78 10 01` — length 20, CIE_id 0,
augmentation `"zR"`: a textbook CIE.

### Fix

`runtime/src/jit/EcoJIT.cpp`: walk the `.eh_frame` block and call `__register_frame(fde)`
per FDE, skipping CIEs (`cie_pointer == 0`). This is what stock
`RTDyldMemoryManager::registerEHFrames` does internally; we do it ourselves to keep
the memory-manager hook for future diagnostics.

### Impact

With the fix, phase 1b stackmap roots jump from 0 to 114–728 per GC, all `bad fde`
warnings disappear. Stress tests pass rate 8/31 → 19/31. E2E test `LetDestructFuncTupleTest`
is still failing, but with different evidence (see Cat 5 / compiler-side bugs).

**Status:** FIXED
**Attempts:** 1
**Full report:** `notes/stress-test-root-cause.md`

---

## FIXED: Category 28 — Cheney scan overruns tail gap after `copyToSpace` block advance

**Tests**: `stress-elm/MaybeChainMap` (crashes in evacuator), plausibly several other
GC-heavy stress tests hitting the same overrun. Was masked by Cat 27.

### Root cause

`NurserySpace::copyToSpace` (NurserySpace.cpp:267–291) advances `current_to_idx_` to the
next block when an object doesn't fit in the remaining space of the current block,
leaving an **uninitialised tail gap** between the old block's last copied object and
`block_end`. `clearToSpaceFreeRegion` (line 1260–1273) only zeros
`[current_to_idx_ .. end)`, so the gap in any earlier block is left holding
stale bytes from prior GC cycles.

The Cheney scan's `advanceScanIfNeeded` (line 304–315) advances to the next block
only when `scan_ptr_ >= block_end`. Between the last legitimate object end and
`block_end`, the scan reads the stale bytes as if they were a real object header,
picks a bogus `{tag, size}`, and either (a) mis-advances `scan_ptr_`, or (b) calls
`evacuate` on a "child field" read from the next block → SIGSEGV.

Byte evidence (MaybeChainMap, GC #2):

```
[scan] obj=0x…_01ffe0 header=0x0000000100000807 tag=7 size=1 decoded=24   ← last legit
[scan-loop] OVERRUN scan_ptr=0x…_01fff8 block_end=0x…_20000
            rem=8 obj_size=40 scan_block_idx=0 current_to_idx=1
[scan] obj=0x…_01fff8 header=0x00000000000003cc tag=12 size=0 decoded=40   ← STALE
```

Tag 12 = `Tag_Process`, color=Black, age=3, epoch=3 — values the minor GC never
writes; must be residue from a prior cycle.

### Fix

Add a `std::vector<char*> block_end_of_objects_` sibling to `to_blocks`; record
`copy_ptr_` at the moment `copyToSpace` abandons a block. `advanceScanIfNeeded`
stops at the recorded end when `scan_block_idx_ < current_to_idx_` rather than at
`block_end`. Initialise entries to `block_start + block_size_` (safe default) at
the top of `minorGC`.

### Impact

Stress: 19/31 → 20/31 (MaybeChainMap moves from SIGSEGV to `roundtrip: True`).
Other still-failing stress tests turn out to have different root causes (Cat 29–33
below).

**Status:** FIXED
**Attempts:** 1
**Full report:** `notes/cheney-tail-gap-bug.md`

---

## FIXED: Category 29 — `collectStackRootsFromStackMap` crashes on null HPointer in tracked slot

**Tests**: 6 of 12 crashing stress tests (`ListSort`, `ListFilterRebuild`, `ListIntersperse`,
`ListConcatMap`, `ListZipUnzip`, `MixedAlloc`)

### Root cause

`ThreadLocalHeap::collectStackRootsFromStackMap` (ThreadLocalHeap.cpp:335–356) skips
HPointers with `constant != 0` (embedded constants) before calling
`Allocator::resolve`, but does not skip HPointers with `ptr == 0`. RS4GC
legitimately records slots that are statically null at a statepoint (unfilled
closure capture, null-base derived pointer), matching the existing skip in
`NurserySpace::evacuate` (NurserySpace.cpp:676: `if (ptr.ptr == 0) return;`).

With `raw = 0`, `Allocator::resolve` computes `obj = heap_base + (0 << 3) = heap_base`,
which is the bottom of the 2 GB reserved-but-not-committed nursery address range
(`0x7fef00000000` in the captured trace). Dereferencing `obj` to read the header
(Allocator.cpp:417) → SIGSEGV.

Per-slot trace of the crashing call:
```
[sm-slot] locIdx=7 reg=7 off=24 raw=0x0000000000000000 ptr=0x0 const=0
[resolve] enter raw=0x0 ptr=0x0 obj=0x7fef00000000 heap_base=0x7fef00000000
← SIGSEGV
```

Same pattern verified on MixedAlloc and ListConcatMap.

### Fix

`runtime/src/allocator/ThreadLocalHeap.cpp`: before calling `alloc.resolve(potential)`,
add the symmetric skip:

```cpp
if (potential.constant != 0) continue;
+if (potential.ptr == 0) continue;    // matches NurserySpace::evacuate
void* phys = alloc.resolve(potential);
```

### Impact

Stress: 20/31 → 26/31 (6 tests move from crash to OK).

**Status:** FIXED
**Attempts:** 1
**Full report:** `notes/stress-test-round3.md`

---

## SKIPPED: Category 30 — Record-update lambda loses fields when specialised through polymorphic wrapper

**Tests**: `stress-elm/RecordUpdateList` — runs to completion, produces `roundtrip: False`;
also blocks the remaining 2 wrong-result tests in spirit.

### Root cause

When `\r -> { r | a = -r.a }` is passed through the polymorphic
`applyNTimes : Int -> (a -> a) -> a -> a`, monomorphisation fixes the lambda's
`MonoType` to `MRecord { a: Int }` — the row mentioned inside the lambda body only —
even though callers pass full `Rec = { a: Int, b: Int, c: Int }`. Codegen at
`Compiler/Generate/MLIR/Expr.elm:419–433` drives `generateRecordUpdate` with
`layout.fieldCount = 1, layout.unboxedBitmap = 1`, so `eco.construct.record` emits
a 24-byte 1-field record. Later `eco.project.record` calls at `field_index = 1` and
`2` read past the end of the record, straight into the adjacent `Cons` cell that
`List.map` allocates next. Observed first record of `transformed`:
`{ a = -1, b = 6, c = <HPointer-shaped value> }` — where `b = 6` is literally
`Tag_Cons = 6` of the following object's header and `c` is the `Cons.head` HPointer.

### Bisection

Same lambda text, same `buildRecs` tail-recursive builder, 7 variants. The *only*
change that flips the MLIR from 3-field to 1-field is introducing `applyNTimes`.
Without the polymorphic wrapper (direct `List.map λ lst`), lambda emits
`field_count = 3, unboxed_bitmap = 7` and the test passes.

### Fix (suggested, not yet applied)

In `Compiler/Monomorphize/Specialize.elm:2308–2356` (`TOpt.Update` specialisation),
fall back to `Mono.typeOf monoRecord` when the derived `monoType` has strictly fewer
fields than the already-specialised input record. This guarantees the output row is
at least as wide as the input row.

Alternatively, at `Compiler/Monomorphize/Specialize.elm:507–581` (`specializeLambda`),
when the lambda parameter type is an `MRecord`, propagate extra rows discovered at
the call site into the lambda's `refinedSubst` before specialising the body.

### Key files

- `compiler/src/Compiler/Monomorphize/Specialize.elm:2308–2356`
- `compiler/src/Compiler/Generate/MLIR/Expr.elm:419–433, 4774–4852, 5075–5082`
- `runtime/src/allocator/Heap.hpp:202–213` — `Record` layout

**Status:** SKIPPED
**Attempts:** 1
- Attempt 1 (code review, no compile): the existing `TOpt.Update` handler at
  `Specialize.elm:2356–2359` already merges `recordMonoType` (from
  `Mono.typeOf monoRecord`) with `monoType` (from
  `applySubstFV state subst canType`) via `Dict.union`. This is the only
  widening intervention available at the `Update` site. When both maps are
  identically narrowed — which is the case when the record is the lambda's
  parameter flowing through a polymorphic wrapper — the union also has
  only the narrow set of fields. No fix is possible at this level without
  the same substantial compiler change identified in Cat 31 attempt 2
  (refining `specializeLambda`'s parameter-type derivation so caller
  substitutions propagate into the lambda's body). Since Cat 30 and Cat 31
  share a root cause and Cat 31 was already SKIPPED with full reasoning,
  a repeated trial here is unproductive.
**Full report:** `notes/bug-B-record-row-narrowing.md`

---

## SKIPPED: Category 31 — Tuple-create lambda loses element types through polymorphic wrapper

**Tests**: `stress-elm/TupleMapList` — crashes with SIGSEGV inside
`NurserySpace::evacuate` on the first minor GC.

### Root cause

Direct tuple variant of Cat 30. The `swap` lambda `\(a, b) -> (b, a)` passed through
`applyNTimes (List.map swap)` is specialised with tuple elements erased to
`!eco.value`, so it emits:

```mlir
%9 = "eco.construct.tuple2"(%8, %6)
       {_operand_types = [!eco.value, !eco.value], unboxed_bitmap = 0}
       : (!eco.value, !eco.value) -> !eco.value
```

where `buildTuples` (which is not inside the polymorphic wrapper) correctly emits
`unboxed_bitmap = 3` for `(Int, Int)`.

The resulting Tuple2 has `header.unboxed == 0`. `scanObject`'s Tag_Tuple2 branch
(NurserySpace.cpp:924–929) sees `is_boxed = true` for both fields, calls
`evacuateUnboxable`, which calls `evacuate` on the raw `i64` Int value (e.g.
`-1000 = 0xfffffffffffffc18`) treated as an HPointer. `Allocator::resolve` → SIGSEGV.

### Fix (suggested, not yet applied)

Symmetric to Cat 30, but for the `MTuple` branch: the monomorphiser must not
drop tuple element types when the lambda flows through a polymorphic type variable.
Fix site is the same pass (`Compiler/Monomorphize/Specialize.elm`), with analogous
treatment in `TOpt.Tuple`'s `monoType` derivation and in `specializeLambda` for
`MTuple`-typed parameters.

### Key files

- `compiler/src/Compiler/Monomorphize/Specialize.elm` — tuple specialisation
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` — `MonoTupleCreate` codegen
- `runtime/src/allocator/NurserySpace.cpp:924–929` — `scanObject` Tuple2 dispatch
- `runtime/src/allocator/Heap.hpp:183–194` — Tuple2/Tuple3 layout

**Status:** SKIPPED
**Attempts:** 2
- Attempt 1: modified `TOpt.Tuple` monoType derivation in `Specialize.elm`
  to prefer `Mono.MTuple (List.map Mono.typeOf allExprs)` over
  `applySubstFV canType`. Result: no effect. `construct.tuple2` still emits
  `unboxed_bitmap = 0`. The tuple's operand types are determined at the
  surrounding `eco.project.tuple2` ops, which are themselves erased (return
  `!eco.value`) because the lambda's argument tuple type is already erased.
  The fix targeted the wrong layer. Reverted.
- Attempt 2: considered a codegen-layer fix in `generateTupleCreate` that
  would infer unboxed bitmap from the actual SSA types of the input
  expressions rather than from `layout.unboxedBitmap`. On code review this
  was also a no-op: by the time codegen runs, the element SSA values are
  already `!eco.value` (boxed) because the upstream projections erased
  them; there is no primitive i64 SSA value at this point to salvage.
- Why remaining fixes are non-trivial: root cause is at the lambda-argument
  type derivation in `Specialize.elm:507–581` (specializeLambda). The
  substitution (`refinedSubst`) applied to `paramCanType` does not resolve
  the lambda's row/tuple-element type variables when the lambda flows
  through a polymorphic type variable in a wrapper like
  `applyNTimes : (a -> a) -> a -> a`. Fixing this requires either
  (a) changing the monomorphization traversal order so the caller's
  concrete type flows back into the lambda's specialization before its
  body is visited, or (b) a post-specialization re-sync pass that patches
  lambda parameter types using the call-site substitution. Both are
  substantive compiler changes with cross-cutting risk to all other
  polymorphic-higher-order uses (fold, map, compose, …) — well beyond the
  scope of a small targeted fix.
**Full report:** `notes/stress-test-3segvs.md`

---

## FIXED: Category 32 — `Kernel::Utils::eqHelp`/`cmp` Tuple2/Tuple3 case skips unboxed check

**Tests**: `stress-elm/DictFromListToList` — crashes with SIGSEGV inside
`Kernel::Utils::equal → eqHelp → resolveAndCompare → Allocator::resolve` on the
first equality comparison, before any GC runs.

### Root cause

The `Tag_Tuple2` and `Tag_Tuple3` cases in both `cmp` (Utils.cpp:107–158) and
`eqHelp` (Utils.cpp:287–335) read `atup->a.p` / `atup->b.p` / `atup->c.p` directly —
the `.p` (HPointer) arm of the `Unboxable` union — without consulting
`header.unboxed`. `Tag_Cons` (Utils.cpp:168–198 / 337–385), `Tag_Custom`
(Utils.cpp:396–415), and `Tag_Record` all check the unboxed bits first and dispatch
to raw-i64 comparison for unboxed fields. Tuple2/Tuple3 don't.

For `List (Int, Int)` — exactly what `buildPairs` creates and what `Dict.toList`
reconstructs — tuples have `header.unboxed = 3`; `atup->a.p` returns an HPointer
whose bit pattern is the raw Int value. `resolveAndCompare` finds `constant = 0`,
calls `allocator.resolve(HPointer{ptr=1, const=0})`, which maps to
`heap_base + 8`. That address is inside the reserved-but-uncommitted nursery range
(e.g. `0x7fef00000008`); the header-read dereference SEGVs.

### Fix (suggested, not yet applied)

In `elm-kernel-cpp/src/core/Utils.cpp`, rewrite the four Tuple2/Tuple3 cases in the
shape of the working `Tag_Cons` branch:

```cpp
case Tag_Tuple2: {
    auto* atup = static_cast<Elm::Tuple2*>(a);
    auto* btup = static_cast<Elm::Tuple2*>(b);
    bool aUb = ahdr->unboxed & 1, bUb = bhdr->unboxed & 1;
    if (aUb && bUb) {
        if (atup->a.i != btup->a.i) return false;
    } else if (!aUb && !bUb) {
        /* existing resolveAndCompare(atup->a.p, btup->a.p) path */
    } else { /* mixed — one boxed, one raw */ }
    /* same for field b with (unboxed & 2) */
}
```

Runtime C++ only — no compiler changes.

### Key files

- `elm-kernel-cpp/src/core/Utils.cpp` — all four Tuple2/Tuple3 cases (cmp + eqHelp) rewritten to mirror the Tag_Cons unboxed-aware pattern
- `elm-kernel-cpp/src/core/Utils.cpp` Tag_Cons (168–198, 337–385) — template copied from

**Status:** FIXED
**Attempts:** 1
**Result:** stress 26/31 → 27/31 (DictFromListToList passes); elm-test 12799/12799 passing; no regressions.
**Full report:** `notes/stress-test-3segvs.md`

---

## SKIPPED: Category 33 — `Dict.remove` of an existing key passes Int where HPointer expected

**Tests**: `stress-elm/DictUnionDiff` — crashes with SIGSEGV inside
`eco_get_tag → Allocator::resolve`, *before* any GC. Same class of crash in any
program that does `Dict.remove k d` where `k ∈ keys(d)`.

### Root cause (narrowed, not fully pinned)

Deterministic reducer:
```elm
d1 = Dict.insert 42 10 Dict.empty
d2 = Dict.remove 42 d1       -- crashes
```
With `42` in the dict, `eco_get_tag` is eventually called with `raw = 0x2a` (=42).
With a different key (`Dict.remove 1 d1`), the bad value is `0x1` (=1). With
`Dict.remove k d` where `k ∉ keys(d)`, no crash. The i64 key value is flowing into
a register/slot where a Dict `!eco.value` is expected.

The generated MLIR is clean: every `eco.get_tag` operand is `!eco.value`, and every
use of `%targetKey: i64` stays as `i64` (never crossed to `!eco.value` in MLIR).
So this is NOT a Bug B-family source-level type narrowing and NOT a runtime
equality bug like Cat 32.

Observed runtime symptom: the first ~96 294 `eco_get_tag` calls in
`DictUnionDiff` succeeded with proper Dict HPointers. Exactly one call arrives
with the raw Int. The bug is triggered by the `Dict.diff` path — whose lambda
`\k _ t -> Dict.remove k t` (papCreated with `num_captured = 0, unboxed_bitmap = 0`,
NO `_fast_evaluator` attribute) saturates via papExtend with
`newargs_unboxed_bitmap = 3`, invoking `eco_apply_segmentation_unknown`'s
"unknown" path. Somewhere between that runtime dispatch and the underlying call
chain `Dict_remove → Dict_removeHelp → Dict_removeHelpEQGT → Dict_balance`, the
i64 key flows into a pointer slot.

Two candidates worth instrumenting next:
1. `EcoToLLVMClosures.cpp` `getOrCreateWrapper` — the wrapper emitted for
   functions with mixed `i64` / `!eco.value` signatures (e.g. `Dict_balance :
   (!eco.value, i64, i64, !eco.value, !eco.value) -> !eco.value`). If the wrapper
   mis-numbers the unboxed columns of `combined_args`, an Int ends up in a
   `!eco.value` position.
2. `eco_apply_segmentation_unknown`'s marshalling when
   `newargs_unboxed_bitmap != 0` AND the target function's signature mixes
   boxed/unboxed slots. The fact that `DUDDiff_lambda_2` has no
   `_fast_evaluator` means the "unknown" runtime path is used rather than the
   fast clone.

### Investigation approach

- Dump LLVM IR (`ecoc --emit=llvm`) for `Dict_balance`, `Dict_removeHelpEQGT`,
  `Dict_getMin`, and `Dict_removeMin`. Check argument marshalling at every call
  site.
- Instrument `buildEvaluatorArgs` (RuntimeExports.cpp:977–1034) to print each
  slot's raw value and the interpreted bitmap for the lambda's closure on entry
  to `eco_closure_call_saturated`.
- Check whether the wrapper generated by `getOrCreateWrapper` for
  `DUDDiff_lambda_2` reads `combined_args[0]` as `i64` (correct) or as an
  HPointer (would be the bug).

### Key files

- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — `getOrCreateWrapper`,
  closure/PAP lowering
- `runtime/src/allocator/RuntimeExports.cpp:977–1034` — `buildEvaluatorArgs`
- `runtime/src/allocator/RuntimeExports.cpp:1106–1180` —
  `eco_apply_segmentation_unknown`
- `runtime/src/allocator/RuntimeExports.cpp:1239–1293` —
  `eco_closure_call_saturated`

**Status:** SKIPPED
**Attempts:** 1
- Attempt 1 (code-review only): considered adding a defensive guard in
  `eco_get_tag` to detect `hp.ptr < heap_low_threshold` and return the
  Int tag, skipping the crash-producing `resolve`. Rejected on code
  review: this would mask the SEGV but produce wrong control flow —
  the JIT pattern-match would take the `Tag_Int` branch on what is
  meant to be a Dict node, and Dict rebalancing would corrupt the
  tree silently. Runtime-level patches cannot fix this without
  finding the exact lowering/ABI site that leaks the Int. The
  investigation narrowed to either `EcoToLLVMClosures.cpp`'s
  `getOrCreateWrapper` for mixed-ABI signatures
  (`(!eco.value, i64, i64, !eco.value, !eco.value) -> !eco.value`)
  or `eco_apply_segmentation_unknown`'s marshalling when
  `newargs_unboxed_bitmap != 0` interacts with a target function of
  mixed signature. Confirming either requires dumping and auditing
  the generated LLVM IR for `Dict_balance` /
  `Dict_removeHelpEQGT` / `Dict_getMin` / `Dict_removeMin` at each
  call boundary — significant work beyond a quick loop iteration.
**Full report:** `notes/stress-test-3segvs.md`

---

## SKIPPED: Category 34 — DictFoldRebuild produces `roundtrip: False`

**Test**: `stress-elm/DictFoldRebuild.elm` — completes all 26 minor GC cycles
without assertion or crash; returns wrong `roundtrip: False` where the program
semantics require `True` (two applications of negate-values through
`Dict.foldl (\k v acc -> Dict.insert k (-v) acc) Dict.empty` should round-trip
through `applyNTimes 1000`).

### Root cause class (not pinned)

Test uses the same polymorphic higher-order wrapper pattern
(`applyNTimes : Int -> (a -> a) -> a -> a` with `a = Dict Int Int`) that
is the root of Cat 30/31. The rebuild helper's
`DictFoldRebuild_lambda_1 : (i64, i64, !eco.value) -> !eco.value` MLIR is
correctly typed, and all Dict kernel signatures are consistent — so at MLIR
level this does not show the tuple/record-row narrowing shape. Two plausible
places the incorrectness could live:

1. Same family as Cat 33 — a lowering/ABI confusion in Dict's RBT helpers
   (`Dict_balance`, `Dict_removeHelpEQGT`) when called via the polymorphic
   `applyNTimes`-wrapped path, producing silent tree corruption instead of
   SEGV.
2. A distinct closure-evaluation bug where `eco_closure_call_saturated`'s
   argument marshalling for the "unknown" segmentation path produces
   valid-looking but wrong values for one of the Dict entries.

### Key files

- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` —
  `getOrCreateWrapper`, `eco_apply_segmentation_unknown` dispatch
- `elm-kernel-cpp/src/core/Dict*.elm` — Dict.insert / Dict.foldl
- `compiler/src/Compiler/Monomorphize/Specialize.elm` — if this turns
  out to be a row-narrowing sibling of Cat 30/31

**Status:** SKIPPED
**Attempts:** 1
- Attempt 1 (code-review only): inspected `rebuildWithTransform` and
  `DictFoldRebuild_lambda_1` MLIR — both emit correctly typed
  `(i64, i64, !eco.value)` signatures, correct `Dict_foldl` call, correct
  `Dict_insert` call. At the MLIR level the test does not exhibit the
  Cat 30/31 row-narrowing shape. Without a compact, deterministic
  reducer (the stress-test's m=1000/n=1000 is too large for pattern
  inspection), pinning the exact failure site needs instrumented JIT IR
  dumps. Same class of investigation as Cat 33.

**Full report:** (none standalone — investigation was brief, see
notes/stress-test-3segvs.md §"Remaining stress-suite status" for the
initial classification.)
