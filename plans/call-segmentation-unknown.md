# Plan: Introduce `CallSegmentationUnknown` Calling Convention

## Goal

Add a 4th `CallKind` — **`CallSegmentationUnknown`** — for stage-curried closures where:
- ABI and concrete monomorphized types **are known** (typed closure ABI)
- Staging information (remaining arity) **is not trusted** at compile time
- Runtime inspects the closure header (`max_values`, `n_values`) for saturation decisions
- Avoids degrading to the all-boxed `CallGenericApply` / `eco_apply_closure` path

This fills the missing quadrant: **known ABI + unknown staging**.

---

## Critical Architectural Finding

The user's original design assumed `_call_kind` is read by the C++ lowering. **It is not.** The actual dispatch in `PapExtendOpLowering::matchAndRewrite` is:

```
remaining_arity ABSENT  → lowerGenericApply() [all-boxed, eco_apply_closure]
remaining_arity PRESENT → typed mode (fastEval/captureAbi/closureKind dispatch)
```

`_call_kind` is purely informational metadata set by the Elm compiler — the C++ lowering never reads it. Similarly, `_dispatch_mode` is defined in `Ops.td` but **never set by any pass** in the current codebase.

**Consequence:** For `CallSegmentationUnknown`, we cannot just emit `_call_kind = "segmentation_unknown"` and expect the C++ lowering to notice. We must modify the C++ lowering to distinguish between two no-`remaining_arity` cases:
1. `generic_apply` → existing `lowerGenericApply()` (all-boxed, `eco_apply_closure`)
2. `segmentation_unknown` → **new** `lowerSegmentationUnknown()` (typed ABI, runtime header-driven saturation)

The cleanest signal is to read the existing `_call_kind` attribute in the C++ lowering when `remaining_arity` is absent.

---

## Step-by-Step Implementation Plan

### Step 1: Extend `CallKind` in the Monomorphized IR

**File:** `compiler/src/Compiler/AST/Monomorphized.elm` (~line 1081)

Add `CallSegmentationUnknown` to the `CallKind` type:
```elm
type CallKind
    = CallDirectKnownSegmentation
    | CallDirectFlat
    | CallGenericApply
    | CallSegmentationUnknown
```

No changes to `CallInfo` or `defaultCallInfo` needed.

### Step 2: Update `callKindToAttrString`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` (~line 1274)

Add the mapping:
```elm
Mono.CallSegmentationUnknown ->
    "segmentation_unknown"
```

### Step 3: Update `computeCallInfo` in GlobalOpt

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` (~line 1980)

Replace the `FromType _ -> Mono.CallGenericApply` branch with:
```elm
FromType _ ->
    if isDynamicCallee env func || calleeHasPolymorphicReturn env func then
        Mono.CallGenericApply
    else
        Mono.CallSegmentationUnknown
```

This routes monomorphic, non-dynamic, non-polymorphic-return callees with type-fallback arity to the new path. Dynamic and polymorphic-return callees stay on `CallGenericApply`.

The rest of `CallInfo` construction (stageArities, initialRemaining, remainingStageArities) stays the same — they're metadata, but won't be used to assert saturation.

### Step 4: Add `CallSegmentationUnknown` branch to `generateCall`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` (~line 1217)

Add a new case branch that mirrors the `CallGenericApply` pattern (generate + coerce), but calls the new helper:
```elm
Mono.CallSegmentationUnknown ->
    let
        unkRes =
            generateUnknownSegmentationCall ctx func args resultType callInfo

        expectedType =
            Types.monoTypeToAbi resultType

        ( coerceOps, finalVar, finalCtx ) =
            coerceResultToType unkRes.ctx
                unkRes.resultVar
                unkRes.resultType
                expectedType
    in
    { ops = unkRes.ops ++ coerceOps
    , resultVar = finalVar
    , resultType = expectedType
    , ctx = finalCtx
    , isTerminated = False
    }
```

### Step 5: Implement `generateUnknownSegmentationCall`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` (near `generateGenericApply`, ~line 1287)

This helper is structurally identical to `generateGenericApply` with two differences:
1. **Boxing policy:** Uses `evaluatorBoxesAll` logic from `generateClosureApplication` (respects per-callee boxing policy via signature/externBoxedVars lookup), instead of hardcoded `False`.
2. **`_call_kind` attribute:** Emits `"segmentation_unknown"` instead of `"generic_apply"`.

Key details:
- Generates callee + args via `generateExpr` / `generateExprListTyped`
- Determines `evaluatorBoxesAll` the same way `generateClosureApplication` does (checking signatures, kernel types, externBoxedVars)
- Calls `boxArgsForClosureBoundary evaluatorBoxesAll` (typed boxing, not all-boxed)
- Computes `newargsUnboxedBitmap` from the boxed arg types
- Emits a single `eco.papExtend` **without** `remaining_arity`, with `_call_kind = "segmentation_unknown"` and `_operand_types` / `newargs_unboxed_bitmap`
- Result type is always `!eco.value` (caller's `coerceResultToType` handles conversion)

### Step 6: Update the C++ `PapExtendOpLowering` to read `_call_kind`

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` (~line 936)

Currently:
```cpp
if (!remainingArityAttr) {
    return lowerGenericApply(op, adaptor, rewriter, loc, closureI64, newargs);
}
```

Change to:
```cpp
if (!remainingArityAttr) {
    // Check _call_kind to distinguish generic_apply from segmentation_unknown
    auto callKindAttr = op->getAttrOfType<StringAttr>("_call_kind");
    if (callKindAttr && callKindAttr.getValue() == "segmentation_unknown") {
        return lowerSegmentationUnknown(op, adaptor, rewriter, loc, closureI64, newargs);
    }
    return lowerGenericApply(op, adaptor, rewriter, loc, closureI64, newargs);
}
```

### Step 7: Implement `lowerSegmentationUnknown` in C++

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

New method on `PapExtendOpLowering` that provides **typed-ABI, runtime-header-driven** closure application. The semantics:

1. **Load closure header** from the first operand (`%clo`): decode `max_values` and `n_values`.
2. **Compute `numNewArgs`** from operand count.
3. **Branch on saturation** (runtime comparison: `n_values + numNewArgs` vs `max_values`):

   **Under-saturated** (`sum < max_values`):
   - Call `eco_pap_extend(closure, args_array, numNewArgs, bitmap)` — same as the existing partial-application path in typed mode (lines 974-1008). This stores typed args with the unboxed bitmap, so the evaluator wrapper can unbox them correctly later.

   **Exactly saturated** (`sum == max_values`):
   - Gather captured values from closure + new args.
   - Call the evaluator via the typed closure ABI (same as the typed saturated path).
   - Since we don't know the closure kind at compile time, use `emitInlineClosureCall` (the legacy typed path that reads evaluator from closure header at runtime).

   **Over-saturated** (`sum > max_values`):
   - Saturate with the first `max_values - n_values` arguments (typed ABI).
   - Recursively apply remaining args to the result via the **same typed `segmentation_unknown` logic** (not `eco_apply_closure`). This preserves typed ABI throughout the chain and avoids reintroducing ABI mismatch on the tail.
   - Implementation: emit a loop (or tail-recursive helper) that re-enters the three-way branch with the saturated result as the new closure and the remaining args as new args. The loop terminates when the result is not over-saturated.

The key difference from `lowerGenericApply`:
- **Does NOT** box everything to HPointer before calling. Passes typed (unboxed Int/Float/Char) args through the bitmap mechanism.
- Uses `eco_pap_extend` for partial application (preserves bitmap) instead of `eco_apply_closure` (which expects all-boxed).

The key difference from the existing typed saturated path:
- **No assertion** that `numNewArgs == remainingArity`.
- Saturation is computed **at runtime** from the header, not at compile time.

**Implementation approach:** Emit LLVM `br`-based three-way branch:
```
sum = n_values + numNewArgs
if sum < max_values: eco_pap_extend (partial)
elif sum == max_values: emitInlineClosureCall (saturated, typed ABI)
else:
  // Over-application loop (typed recursive):
  // 1. Take first (max_values - n_values) args, call evaluator (typed)
  // 2. Result is new closure; remaining args become new args
  // 3. Re-enter three-way branch with new closure + remaining args
  // Loop terminates when under-saturated or exactly saturated.
```

**Design note on the three-way branch cost:** These combinator/case-returning-lambda sites are the "hard" higher-order cases; first-order and most hot code stays on `CallDirectKnownSegmentation` or `CallDirectFlat`. The branch is just a couple of integer loads and compares — cheap relative to closure allocation and evaluator calls. Correctness and simplicity win for now; fast-paths can be added later if profiling warrants it.

### Step 7.5: Update `EcoPAPSimplify` to propagate `_call_kind`

**File:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp` (~line 194)

The PAP simplify pass fuses chained papExtend ops and propagates attributes from the first extend. Currently `_call_kind` is not propagated. Add propagation:

```cpp
prevExtend->getAttrOfType<StringAttr>("_call_kind"),  // Propagate _call_kind
```

**Lattice rule for safety:** If fusing ops with different `_call_kind` values ever becomes possible, pick the most conservative (most generic) one:
`direct_known_segmentation < segmentation_unknown < generic_apply`

Never synthesize `direct_known_segmentation` inside EcoPAPSimplify — that remains a GlobalOpt decision. In practice, `segmentation_unknown` calls are always single (non-chained) papExtend ops, so this is a defensive measure.

### Step 8: Update `Ops.td` verifier comments

**File:** `runtime/src/codegen/Ops.td` (~line 915)

Update the documentation to list `segmentation_unknown` as a valid `_call_kind` value. No structural TableGen changes needed since `_call_kind` is not a formal attribute of `Eco_PapExtendOp` — it's set as a generic op attribute by the Elm compiler.

### Step 9: Update `EcoOps.cpp` verifier (if needed)

**File:** `runtime/src/codegen/EcoOps.cpp`

The current verifier checks:
- Bitmap constraints
- REP_CLOSURE_001 (no Bool at closure boundary)
- Result type must be `!eco.value` when `remaining_arity` absent

The last constraint is already correct for `segmentation_unknown` (we always emit `!eco.value` result). No verifier changes needed unless we want to add an explicit check that `_call_kind` is one of the known strings.

### Step 10: Update invariants

**File:** `design_docs/invariants.csv`

1. **Update GOPT_016** to mention `CallSegmentationUnknown`:
   > `CallSegmentationUnknown` is used for StageCurried calls where the callee has known monomorphic ABI types but untrusted staging (sourceArityInfo = FromType). The callee must not be dynamic and must not have polymorphic return.

2. **Add CGEN_0XX**: For `eco.papExtend` with `_call_kind = "segmentation_unknown"`, `remaining_arity` must be absent.

3. **Confirm CGEN_052 and CGEN_056** already exclude the no-`remaining_arity` case (they do — both say "In generic mode (remaining_arity absent) this invariant does not apply").

### Step 11: Update compiler invariant tests

**Files:**
- `compiler/tests/TestLogic/GlobalOpt/CallInfoComplete.elm` — add test for `CallSegmentationUnknown` selection
- `compiler/tests/TestLogic/Generate/CodeGen/PapExtendArity.elm` — verify no `remaining_arity` on segmentation_unknown papExtend ops
- `compiler/tests/TestLogic/Generate/CodeGen/PapExtendResult.elm` — verify `!eco.value` result type

### Step 12: E2E validation

Run `cmake --build build --target full` and verify:
- CaseReturningLambdaTest passes
- All CombinatorTest variants pass
- No `eco_closure_call_saturated` assertion failures
- No ABI mismatch crashes from monomorphized evaluators
- Check MLIR output for affected tests: should see `eco.papExtend` with `_call_kind = "segmentation_unknown"` and no `remaining_arity`

---

## File Change Summary

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Add `CallSegmentationUnknown` variant |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Update `callKind` in `computeCallInfo` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `generateCall` branch, `callKindToAttrString` mapping, `generateUnknownSegmentationCall` helper |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Add `_call_kind` check in no-remaining_arity path, implement `lowerSegmentationUnknown` |
| `runtime/src/codegen/Passes/EcoPAPSimplify.cpp` | Propagate `_call_kind` when fusing papExtend chains |
| `runtime/src/codegen/Ops.td` | Update docs only |
| `runtime/src/codegen/EcoOps.cpp` | Optional: validate `_call_kind` string |
| `design_docs/invariants.csv` | Update GOPT_016, add CGEN_0XX |
| `compiler/tests/TestLogic/GlobalOpt/CallInfoComplete.elm` | Add invariant test |
| `compiler/tests/TestLogic/Generate/CodeGen/PapExtendArity.elm` | Add invariant test |

---

## Resolved Decisions

### D1: Over-application tail strategy → Typed recursive

Keep the over-application tail **typed and recursive**, not `eco_apply_closure` fallback.
- `segmentation_unknown` is explicitly "ABI known, staging unknown" for monomorphic callees. Dropping to `eco_apply_closure` (all-boxed) for the tail would reintroduce the same ABI mismatch this feature fixes.
- Implement the over-application branch by re-entering the same typed three-way logic: saturate once, then apply remaining args via the same `segmentation_unknown` path (loop or recursive helper in LLVM IR).

### D2: `evaluatorBoxesAll` reachability → Unlikely but safe

In practice, `FromType` callees in the `StageCurried` branch should not be raw externs/kernels:
- Extern/kernel calls use `callModel = FlattenedExternal` → `CallDirectFlat`, bypassing the `StageCurried` path.
- Alias closures around externs have arities from wrapper construction → tagged `FromProducer`, not `FromType`.
- If a corner case ever did reach `FromType` with `evaluatorBoxesAll = True`, the current design (honoring `evaluatorBoxesAll` inside `generateUnknownSegmentationCall`) keeps it correct.

### D3: `EcoPAPSimplify` interaction → Propagate `_call_kind` conservatively

- Propagate `_call_kind` from the first extend (same as other attributes).
- If fusing ops with different kinds, use a safety lattice: `direct_known_segmentation < segmentation_unknown < generic_apply` — pick the most conservative.
- Never synthesize `direct_known_segmentation` inside EcoPAPSimplify; that's a GlobalOpt decision.
- In practice, `segmentation_unknown` calls are single (non-chained) papExtend ops, so this is defensive.

### D4: Three-way branch cost → Acceptable

- These combinator/case-returning-lambda sites are the "hard" higher-order cases; first-order and hot code stays on `CallDirectKnownSegmentation` or `CallDirectFlat`.
- The branch is a couple of integer loads and compares — cheap relative to closure allocation and evaluator calls.
- Correctness and simplicity win for now; fast-paths can be added later if profiling warrants it.

### D5: Multi-stage emit → Single papExtend per callsite

- For `segmentation_unknown`, always emit **one `eco.papExtend`** taking all new args; runtime decides under/over-saturation and handles multi-stage evaluation internally.
- Per-stage `papExtend` only makes sense when you trust the segmentation (`CallDirectKnownSegmentation` with `applyByStages`).
- With unknown segmentation, splitting into multiple papExtend ops adds complexity with no precision gain.

## Assumptions

- A1: `_call_kind` is safe to read in the C++ lowering since it's already emitted as a string attribute by the Elm compiler on all papExtend ops. We're just making the C++ code aware of it.
- A2: The `emitInlineClosureCall` legacy path in EcoToLLVMClosures.cpp is suitable for the saturated case in `lowerSegmentationUnknown`, since it reads the evaluator from the closure header at runtime and calls it with typed args.
- A3: No other Stage2 passes need modification — the existing typed closure capture checking pass (`CheckEcoClosureCapturesPass`) only runs on typed-mode papExtend (remaining_arity present) and will correctly skip segmentation_unknown ops.
