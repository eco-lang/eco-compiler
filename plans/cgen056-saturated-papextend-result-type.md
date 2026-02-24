# Plan: CGEN_056 – Saturated papExtend Result Type Test

## Invariant

**CGEN_056** (MLIR_Codegen; Closures; enforced): For every `eco.papExtend` that represents a fully saturated closure application (`isSaturatedCall`) of some `func.func @f`, the `eco.papExtend` result MLIR type must equal the result type of `@f`'s `func.func` signature.

## Context

Currently, CGEN_034 (`PapExtendResult.elm`) checks that `eco.papExtend` result types are *valid* MLIR types (`!eco.value`, `i1`, `i64`, `f64`), but does not verify that saturated calls actually match their target function's return type. This new test closes that gap.

### How saturated calls work in codegen (Expr.elm ~line 1320)

A `papExtend` is **saturated** when all three conditions hold:
1. `rawResultRemaining <= 0` — current stage is fully applied
2. `List.isEmpty rest` — no more arguments to apply in later batches
3. `List.isEmpty remainingStageArities` — no subsequent stages remain

When saturated, codegen sets `resultMlirType = saturatedReturnType`, which is derived from `Types.monoTypeToAbi(resultType)` — the ABI return type of the underlying function.

When NOT saturated (partial application), the result is always `!eco.value`.

### How to identify saturated vs partial papExtend in MLIR

A saturated `eco.papExtend` is one whose result type is NOT `!eco.value` — it uses the actual ABI return type (e.g., `i64`, `f64`, `i16`). This is the distinguishing characteristic since partial applications always return `!eco.value`.

**However**, a saturated call that returns a boxed value (e.g., a `List`, `String`, custom type) will also have result type `!eco.value` because `monoTypeToAbi` maps those to `!eco.value`. In those cases the invariant is trivially satisfied (papExtend result type = `!eco.value` = func.func result type = `!eco.value`). We can still verify these by tracing through the PAP chain.

### Strategy: PAP chain tracking + function resolution

1. Build a map from function `sym_name` → return type (from `function_type` attribute on `func.func` ops).
2. For each function scope, track PAP provenance:
   - `eco.papCreate` with `function` attribute → records which `func.func` this PAP targets, and its remaining arity (`arity - num_captured`).
   - `eco.papExtend` → traces back to source PAP, computes result remaining (`remaining_arity - num_new_args`).
3. A `papExtend` is saturated when its result remaining ≤ 0.
4. For saturated `papExtend`s, look up the originating function's return type and assert it matches the `papExtend` result type.

## Files to Create

### 1. `compiler/tests/TestLogic/Generate/CodeGen/PapExtendSaturatedResultType.elm`

Logic module for CGEN_056.

```
module TestLogic.Generate.CodeGen.PapExtendSaturatedResultType exposing
    ( expectPapExtendSaturatedResultType, checkPapExtendSaturatedResultType )
```

**Imports from `Invariants`:**
- `Violation`, `violationsToExpectation`
- `findFuncOps`, `findOpsNamed`, `walkOpAndChildren`
- `getIntAttr`, `getStringAttr`, `getTypeAttr`, `getArrayAttr`
- `extractResultTypes`

**Import from `TestPipeline`:**
- `runToMlir`

**Data structures:**

```elm
-- Tracks provenance of a PAP value: which function it targets and how many args remain
type alias PapInfo =
    { targetFunc : String     -- sym_name of the func.func this PAP ultimately calls
    , remaining : Int         -- args still needed before saturation
    }
```

**Core functions:**

#### `expectPapExtendSaturatedResultType : Src.Module -> Expectation`
- Run `runToMlir` on the source module.
- On success, call `checkPapExtendSaturatedResultType mlirModule`.
- Convert violations to expectation.

#### `checkPapExtendSaturatedResultType : MlirModule -> List Violation`
- Build `funcReturnTypeMap : Dict String MlirType` from all `func.func` ops:
  - Extract `sym_name` and `function_type` attribute.
  - From `FunctionType { results }`, take the first (and only) result type.
- Process each top-level op (function) independently to keep SSA scoping correct:
  - Call `checkFunction funcReturnTypeMap funcOp`.
- Concatenate all violations.

#### `buildFuncReturnTypeMap : MlirModule -> Dict String MlirType`
- For each `func.func` op in `mlirModule.body`:
  - Extract `sym_name` (via `getStringAttr`).
  - Extract `function_type` (via `getTypeAttr`).
  - Pattern-match on `FunctionType { results }` and take `List.head results`.
  - Insert `(sym_name, resultType)` into the map.

#### `checkFunction : Dict String MlirType -> MlirOp -> List Violation`
- Walk all ops in this function (`walkOpAndChildren`).
- Build a `papInfoMap : Dict String PapInfo` tracking PAP provenance:
  - For `eco.papCreate`: extract `function` attr (or `_fast_evaluator` attr for two-clone model), `arity`, `num_captured`. Record `PapInfo { targetFunc, remaining = arity - num_captured }` keyed by result SSA name.
  - For `eco.papExtend`: look up first operand in `papInfoMap`. If found, compute `newRemaining = source.remaining - numNewArgs`. If `newRemaining > 0`, record new `PapInfo { targetFunc = source.targetFunc, remaining = newRemaining }` for the result SSA name.
- Find all `eco.papExtend` ops in this function.
- For each, check if saturated:
  - Look up first operand in `papInfoMap` to get source `PapInfo`.
  - If not found, skip (source may be a block arg or unknown provenance).
  - Compute `resultRemaining = source.remaining - numNewArgs`.
  - If `resultRemaining <= 0` → this is a saturated call.
  - For saturated calls: look up `source.targetFunc` in `funcReturnTypeMap`. If found, compare the func's return type with the `papExtend`'s result type. If they differ → violation.
  - For the two-clone model: when resolving the target function, if the `papCreate` had `_fast_evaluator` pointing to `$cap`, also check the `$cap` function's return type (which should be the same as the base function).

#### `checkSaturatedPapExtend : Dict String MlirType -> Dict String PapInfo -> MlirOp -> Maybe Violation`
- Extract first operand (source PAP SSA name).
- Look up `PapInfo` from `papInfoMap`.
- If not found → `Nothing` (skip, unknown provenance).
- Compute `numNewArgs = List.length op.operands - 1`.
- Compute `resultRemaining = papInfo.remaining - numNewArgs`.
- If `resultRemaining > 0` → not saturated → `Nothing`.
- If saturated:
  - Extract result type from `op.results` (should be exactly 1).
  - Look up `papInfo.targetFunc` in `funcReturnTypeMap`.
  - If function not found → `Nothing` (external/kernel function without definition; skip).
  - If function found: compare `funcReturnType` with `papExtendResultType`.
  - If they don't match → `Just violation` with message: `"Saturated eco.papExtend result type <actualType> does not match func.func @<funcName> return type <expectedType>"`.
  - If they match → `Nothing`.

### 2. `compiler/tests/TestLogic/Generate/CodeGen/PapExtendSaturatedResultTypeTest.elm`

Thin test harness.

```elm
module TestLogic.Generate.CodeGen.PapExtendSaturatedResultTypeTest exposing (suite)

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendSaturatedResultType
    exposing (expectPapExtendSaturatedResultType)

suite : Test
suite =
    Test.describe "CGEN_056: Saturated PapExtend Result Type"
        [ StandardTestSuites.expectSuite
            expectPapExtendSaturatedResultType
            "passes saturated papExtend result type invariant"
        ]
```

## Invariant Coverage Matrix

| Condition from CGEN_056 | How tested |
|---|---|
| Identifies saturated `eco.papExtend` | PAP chain tracking: `remaining_arity - numNewArgs <= 0` from `papCreate` through `papExtend` chain |
| Resolves target `func.func @f` | Traces provenance from `papExtend` → source PAP → `papCreate` → `function` / `_fast_evaluator` attribute → `func.func` `sym_name` |
| Result MLIR type must equal @f's return type | Compares `papExtend` result type against `function_type` attribute's result type on the matching `func.func` op |
| Handles two-clone model | Uses `_fast_evaluator` attribute to resolve to `$cap` function when present |
| Non-saturated papExtend excluded | Only checks when `resultRemaining <= 0`; partial applications are skipped |
| Unknown provenance skipped gracefully | When source PAP not in map (block args, cross-function values), no false positive |
| External functions skipped | When target function not found in `funcReturnTypeMap`, no false positive |

## Edge Cases Handled

1. **Chained papExtend**: Provenance propagates through chains — each intermediate PAP records its target function and updated remaining count.
2. **Two-clone model**: `_fast_evaluator` on `papCreate` points to `$cap` clone; we resolve the return type from whichever clone is referenced.
3. **Cross-function PAPs**: PAPs created in one function and used in another won't be in the local `papInfoMap`; these are gracefully skipped (no false positives).
4. **Saturated calls returning `!eco.value`**: When `monoTypeToAbi` maps a boxed return type to `!eco.value`, the func.func also returns `!eco.value`, so the check passes trivially. This is correct — the invariant is still enforced.
5. **Zero-capture closures**: These use `eco.call` not `eco.papCreate`/`eco.papExtend`, so they are outside scope of this test.

## Registration

The test harness file needs to be discoverable by `elm-test-rs`. No explicit registration is needed beyond placing the file in the test directory — `elm-test-rs` discovers all `*Test.elm` files exposing `suite`.

## Questions Deferred

None. The design follows established patterns from `PapExtendArity.elm` (per-function PAP tracking) and `PapArityConsistency.elm` (function metadata lookup), combining both approaches.
