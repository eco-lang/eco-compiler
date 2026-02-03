# Fix Closure Stage Return Type

## Problem

In `Functions.generateClosureFunc`, the return type is computed using `decomposeFunctionType` which flattens **all** currying levels. This causes closures that return functions to have incorrect return types.

**Example:** For `getOp : Op -> (Int -> Int -> Int)`:
- `monoType = MFunction [Op] (MFunction [Int,Int] Int)`
- `decomposeFunctionType` returns `([Op, Int, Int], Int)`
- Return type becomes `i64` instead of `!eco.value`

This generates invalid MLIR:
```mlir
%4 = "eco.case"(%op) ... : (!eco.value) -> !eco.value
%5 = "eco.unbox"(%4) ... : (!eco.value) -> i64  // WRONG: unboxing a closure
"eco.return"(%5) ... : (i64) -> ()
```

Leading to runtime PAP errors:
```
eco_pap_extend: new_n_values (1) exceeds max_values (0)
eco_closure_call_saturated: argument count mismatch
```

## Solution

Replace `decomposeFunctionType` with `stageReturnType` in `generateClosureFunc`. The `stageReturnType` function only strips one level of currying, preserving intermediate function types.

## Code Change

**File:** `compiler/src/Compiler/Generate/MLIR/Functions.elm`

**Location:** `generateClosureFunc` function, around line 237

**Current code:**
```elm
-- Extract return type from the closure's full type, not the body's type.
-- The body's type may be !eco.value if it's a parameter reference,
-- but the caller expects the actual return type (e.g., i64 for identity 42).
( _, extractedReturnType ) =
    Types.decomposeFunctionType monoType

returnType : MlirType
returnType =
    Types.monoTypeToAbi extractedReturnType
```

**New code:**
```elm
-- Extract the STAGE return type from the closure's function type.
-- For stage-curried functions, monoType is the full function type
-- (e.g., MFunction [Op] (MFunction [Int,Int] Int)).
-- The first stage consumes closureInfo.params and returns stageReturnType monoType.
extractedReturnType : Mono.MonoType
extractedReturnType =
    Types.stageReturnType monoType

returnType : MlirType
returnType =
    Types.monoTypeToAbi extractedReturnType
```

## Do NOT Change

Other uses of `decomposeFunctionType` are correct and should remain:
- `generateExtern` - flattened ABI for externs
- `generateKernelDecl` - flattened ABI for kernels
- `generateTailFunc` - final return type for tail-recursive functions
- `Types.chooseCanonicalSegmentation` - case branch join types
- `Context.extractNodeSignature` for `MonoExtern` - flattened external call model

## Verification

Run the failing test:
```bash
TEST_FILTER=CaseReturnFunction cmake --build build --target check
```

Expected result after fix:
- `getOp` function type: `(!eco.value) -> (!eco.value)` (not `-> (i64)`)
- No `eco.unbox` on the case result
- Test output: `op1: 7`, `op2: 3`, `op3: 10`

## Rationale

This aligns `generateClosureFunc` with the stage-curried invariants:
1. `MFunction argTypes resultType` represents **one stage**: expects `argTypes`, returns `resultType`
2. Closure params (`closureInfo.params`) correspond to one stage (`stageParamTypes`)
3. `applyByStages` already uses `stageReturnType` for PAP evaluation

The fix ensures closure evaluator signatures match the first stage of the function type.
