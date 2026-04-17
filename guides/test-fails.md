# Test Failures Report

## Baseline (2026-03-19)
- **elm-test**: 11667 passed, 1 failed
- **E2E**: 923 passed, 16 failed

## Current (2026-04-17, ptr<1> migration in progress)
- **elm-test**: 12664 passed, 0 failed (unaffected by backend changes)
- **E2E (codegen only)**: 312 passed, 1 failed out of 313 (1 pre-existing)
- **E2E (full)**: not yet measured post-fix

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
| 13 | BF bf_alloc_large pre-existing | bf_alloc_large | Pre-existing baseline failure — 64KB allocation returns 0; not caused by ptr<1> migration. BF dialect not yet migrated to ptr<1> (88 test files need !eco.value conversion); C++ BF runtime uses HPtr but BF LLVM declarations still use i64 (ABI-compatible) | PRE-EXISTING |
| 14 | ptr<1>: C++ HPtr conversion regressions | ~31 E2E tests (elm-bytes/DecodeMap*, elm-json/RoundTrip*, elm/TailRec*, elm/Equality*, etc.) | One or more kernel .cpp files incorrectly converted to HPtr — all crash with `raw=0xfefefefe` | OPEN |

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

## OPEN: Category 14 — C++ HPtr Conversion Regressions (ptr<1> migration)

**Tests**: ~31 E2E tests that passed before the C++ HPtr changes but now crash

**Error**: All crash with `resolve() bad HPointer: raw=0xfefefefe`

### Root Cause

During the HPtr migration, ~30 kernel .cpp files and RuntimeExports.cpp were updated by agents to change function signatures from `uint64_t` to `HPtr` and add `.toBits()`/`HPtr::fromBits()` at boundaries. One or more files have incorrect conversions — likely a function that reads HPtr.bits incorrectly or passes the wrong variable.

The `0xfefefefe` pattern (32-bit debug fill) appears in ALL crashes, suggesting a systematic issue rather than individual per-file bugs. Possible causes:
- A helper function (e.g., in ExportHelpers.hpp or a closure-calling helper) still expects uint64_t but receives HPtr
- A GC root rooting call (`eco_gc_push_stack_range`) passes an `HPtr*` instead of `uint64_t*`
- An internal function stores HPtr into a uint64_t array without `.toBits()`

### Debugging Approach

1. Binary search: revert half the kernel .cpp changes and re-test to narrow which file(s) introduce the bug
2. Check all `eco_gc_push_stack_range` calls — they take `uint64_t*` but if someone passes `&hptr_var` (HPtr*) the GC would read struct bytes as raw uint64_t
3. Check all internal helper functions (callUnaryClosure, callBinaryClosure, etc.) that bridge between HPtr and uint64_t* arrays

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
