# Implementation Plan: Chain papExtend Per Stage (CGEN_052 Fix)

## Problem Summary

Stage-curried closures have types like `MFunction [a] (MFunction [b] c)` where each closure only accepts its first stage's arguments. The current codegen tries to apply ALL arguments at once via a single `papExtend`, causing CGEN_052 violations because `remaining_arity` doesn't match the PAP's actual arity.

## Solution

Emit a **chain of papExtend calls**, one per stage, where each papExtend applies only the arguments for that stage.

---

## Clarified Design Decisions

### 1. Intermediate Result Types

For each `papExtend` in the chain:
```elm
let
    stageRetType = Types.stageReturnType currentMonoType
    resultMlirType = Types.monoTypeToAbi stageRetType
in
    ... |> withResults [ ( resVar, resultMlirType ) ]
```

- If `stageRetType` is still a function (`MFunction ...`), `resultMlirType` will be `!eco.value` (intermediate closure)
- If `stageRetType` is a non-function, you get the appropriate primitive or `!eco.value` ABI type
- This matches the dialect: `eco.papExtend`'s result is `Eco_AnyValue` (either closure or final value)

### 2. Zero-Arity Stages

Zero-arity stages (`MFunction [] T`) are **never represented as PAP closures**:
- For globals/kernels with arity 0, codegen emits **direct calls** instead of `papCreate`
- For closures with arity 0, codegen skips `papCreate` and emits `eco.callNamed`

Therefore, `applyByStages` should only see function values with `stageArity > 0`.

**Defensive handling:**
- `stageArity == 0` with `remainingArgs == []`: Return current value (already fully applied)
- `stageArity == 0` with `remainingArgs /= []`: Internal bug (over-application of thunk)

### 3. newargs_unboxed_bitmap

Each `papExtend` in the chain computes its own `newargs_unboxed_bitmap` from **just that batch's argument MLIR types**:
```elm
newargsUnboxedBitmap =
    List.indexedMap
        (\i ( _, mlirTy ) ->
            if Types.isUnboxable mlirTy then
                Bitwise.shiftLeftBy i 1
            else
                0
        )
        batchArgsWithTypes
        |> List.foldl Bitwise.or 0
```

- **Not cumulative** across stages
- Runtime knows its own stored bitmap; each extend only describes the "delta" for its `newargs`
- Compliant with CGEN_003: compute bitmaps solely from SSA operand MLIR types

---

## Step 1: Create `applyByStages` Helper Function

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Location:** Add near `generateClosureApplication` (around line 918)

**Signature:**
```elm
applyByStages :
    Ctx.CodeGenContext
    -> String                      -- funcVar: the closure variable
    -> MlirType                    -- funcMlirType: the closure's MLIR type
    -> Mono.MonoType               -- funcMonoType: the function's MonoType (stage-curried)
    -> List (String, MlirType)     -- args: remaining (var, mlirType) pairs to apply
    -> List Mlir.Operation         -- accumulated ops
    -> ( List Mlir.Operation, String, MlirType, Ctx.CodeGenContext )
```

**Algorithm:**
```elm
applyByStages ctx funcVar funcMlirType funcMonoType args accOps =
    case args of
        [] ->
            -- Base case: no more args to apply
            ( accOps, funcVar, funcMlirType, ctx )

        _ ->
            let
                stageN = Types.stageArity funcMonoType
                stageRetType = Types.stageReturnType funcMonoType
                resultMlirType = Types.monoTypeToAbi stageRetType
            in
            if stageN == 0 then
                -- Defensive: zero-arity stage shouldn't happen with remaining args
                -- Return current value (treat as fully applied)
                ( accOps, funcVar, funcMlirType, ctx )
            else
                let
                    ( batch, rest ) = List.splitAt stageN args

                    -- Compute bitmap for this batch only
                    newargsUnboxedBitmap =
                        List.indexedMap
                            (\i ( _, mlirTy ) ->
                                if Types.isUnboxable mlirTy then
                                    Bitwise.shiftLeftBy i 1
                                else
                                    0
                            )
                            batch
                            |> List.foldl Bitwise.or 0

                    ( resVar, ctx1 ) = Ctx.freshVar ctx

                    allOperandNames = funcVar :: List.map Tuple.first batch
                    allOperandTypes = funcMlirType :: List.map Tuple.second batch

                    papExtendAttrs =
                        Dict.fromList
                            [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                            , ( "remaining_arity", IntAttr Nothing stageN )
                            , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                            ]

                    ( ctx2, papExtendOp ) =
                        Ops.mlirOp ctx1 "eco.papExtend"
                            |> Ops.opBuilder.withOperands allOperandNames
                            |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                            |> Ops.opBuilder.withAttrs papExtendAttrs
                            |> Ops.opBuilder.build
                in
                -- Recurse with the result closure and remaining args
                applyByStages ctx2 resVar resultMlirType stageRetType rest (accOps ++ [ papExtendOp ])
```

**Note:** Need to add `List.splitAt` helper or use `List.take`/`List.drop`.

---

## Step 2: Refactor `generateClosureApplication`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Lines:** 918-1020

**Changes:**
1. Keep early-exit for "already evaluated" (non-closure) functions with no args (lines 932-945)
2. Replace the single `papExtend` emission (lines ~948-1015) with:

```elm
-- After generating func and boxing args...
let
    funcType = Mono.typeOf func

    ( papOps, finalVar, finalMlirType, ctx3 ) =
        applyByStages ctx2 funcResult.resultVar funcResult.resultType funcType boxedArgsWithTypes []
in
{ ops = funcResult.ops ++ argOps ++ boxOps ++ papOps
, resultVar = finalVar
, resultType = finalMlirType  -- or coerce to expectedType if needed
, ctx = ctx3
, isTerminated = False
}
```

---

## Step 3: Refactor `generateSaturatedCall` - MonoVarLocal Case

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Lines:** ~1635-1686

**Changes:**
1. Keep early-exit for "already evaluated" functions with no args
2. Replace lines ~1650-1686 (single papExtend with `countTotalArity`) with call to `applyByStages`:

```elm
let
    ( papOps, finalVar, finalMlirType, ctx3 ) =
        applyByStages ctx1b funcVarName funcVarType funcType boxedArgsWithTypes []
in
{ ops = argOps ++ boxOps ++ papOps
, resultVar = finalVar
, resultType = finalMlirType  -- or expectedType
, ctx = ctx3
, isTerminated = False
}
```

---

## Step 4: Refactor `generateSaturatedCall` - Fallback Case

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Lines:** ~1693-1783

**Changes:**
1. Keep early-exit for "already evaluated" functions with no args
2. Replace lines ~1720-1783 (single papExtend with `countTotalArity`) with call to `applyByStages`

---

## Step 5: Audit Uses of `countTotalArity`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Action:** Search for all uses of `countTotalArity`:
- Should NOT be used for `remaining_arity` in papExtend operations
- May still be valid for other purposes (e.g., test over-application checks)

Expected to find/change:
- Line ~1660: `MonoVarLocal` case - change to use `applyByStages`
- Line ~1762: Fallback `_` case - change to use `applyByStages`

---

## Step 6: Add `List.splitAt` Helper (if needed)

Elm's core `List` module may not have `splitAt`. Options:
1. Use `( List.take n xs, List.drop n xs )`
2. Add a local helper function

---

## Step 7: Run Tests

```bash
cd compiler && npx elm-test-rs --fuzz 1  # Front-end tests (MONO_016, CGEN_052)
cmake --build build --target check        # Full E2E tests
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `applyByStages`, refactor 3 call sites |

## Estimated Scope

- 1 new helper function (~50 lines)
- 3 refactored call sites (replace ~30 lines each with ~10 line call)
- Net: cleaner abstraction, unified stage-by-stage application logic
