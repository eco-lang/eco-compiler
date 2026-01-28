# Plan: CGEN_052 Fix via Option 4 (External vs Closure Dispatch)

## Problem Summary

After MONO_016, user-defined closures are **stage-curried** (params match stage arity), but external/kernel functions remain **flattened** (all params at once). This creates a mismatch:

- `List.map` PAP created with `arity=2` (total params)
- `applyByStages` emits `remaining_arity=1` (stage arity)
- CGEN_052 violation: `remaining_arity=1 ≠ source PAP remaining=2`

## Solution: Option 4

Distinguish call paths by **underlying node type**:
- **External functions** (`MonoExtern` nodes, `MonoVarKernel`): Use total ABI arity (flattened)
- **User functions** (`MonoDefine`, `MonoTailFunc`, accessors, etc.): Use stage arity (stage-curried)

**Critical insight:** The check is on the **node type**, not just `MonoVarGlobal`. A `MonoVarGlobal` can point to either a `MonoExtern` (flattened) or a user-defined `MonoDefine`/`MonoTailFunc` (stage-curried).

---

## Clarified Semantics

### 1. Subsequent Applications Work Correctly

For `[{x = 0}] |> List.map .x` (desugars to `Basics.apR [{x = 0}] (List.map .x)`):

**Step 1: `List.map` as value**
- `List.map` is `MonoExtern` with type `(a -> b) -> List a -> List b`
- `generateVarGlobal` emits `eco.papCreate` with `arity=2, num_captured=0`
- PAP remaining = 2

**Step 2: `List.map .x` (partial application)**
- `generateClosureApplication` sees `MonoVarGlobal` pointing to `MonoExtern`
- Uses flattened path: `remaining_arity = 2` (total ABI arity)
- Emits single `eco.papExtend` with `remaining_arity=2`
- CGEN_052 satisfied: source remaining=2, papExtend remaining_arity=2
- New PAP remaining = 2 - 1 = 1

**Step 3: Applying the list (inside `Basics.apR`)**
- Inside `Basics.apR`, the call `f xs` treats `f` as a local parameter (not `MonoVarGlobal`)
- Goes through closure/stage-curried path
- `stageArity(MFunction [List a] (List b)) = 1`
- Emits `eco.papExtend` with `remaining_arity=1`
- CGEN_052 satisfied: source remaining=1, papExtend remaining_arity=1

### 2. Accessors Use Stage-Curried Path

Accessor `.x` used as a function:
- Monomorphization creates `MonoVarGlobal` with `Global = Mono.Accessor fieldName`
- Underlying node is `MonoDefine` (with closure body), **NOT** `MonoExtern`
- `extractNodeSignature` → `callModel = StageCurried`
- Uses `applyByStages` with stage arity

### 3. Recursive User Functions Use Stage-Curried Path

Recursive/non-recursive user functions:
- Referenced via `MonoVarGlobal` when called by name
- Underlying node is `MonoDefine` or `MonoTailFunc`, **NOT** `MonoExtern`
- `extractNodeSignature` → `callModel = StageCurried`
- Direct calls use `eco.call`, closure captures use stage-curried model

**Only `MonoExtern` and `MonoVarKernel` use flattened path.**

---

## Step 1: Add `CallModel` Type and Helper

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Add type:**
```elm
{-| Call model for a function: determines arity calculation strategy.
-}
type CallModel
    = FlattenedExternal  -- External/kernel: use total ABI arity
    | StageCurried       -- User closure: use stage arity
```

**Add to `FuncSignature`:**
```elm
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , callModel : CallModel  -- NEW
    }
```

**Update `extractNodeSignature`:**
```elm
extractNodeSignature : Mono.MonoNode -> Maybe FuncSignature
extractNodeSignature node =
    case node of
        Mono.MonoExtern monoType ->
            -- External: flattened ABI
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Types.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        , callModel = FlattenedExternal
                        }
                _ ->
                    Nothing

        Mono.MonoDefine expr monoType ->
            -- User function: stage-curried
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        , callModel = StageCurried
                        }
                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , callModel = StageCurried
                        }

        Mono.MonoTailFunc params _ monoType ->
            -- Tail-recursive: stage-curried
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = Types.stageReturnType monoType
                , callModel = StageCurried
                }

        -- ... other cases with callModel = StageCurried
```

---

## Step 2: Add `isFlattenedExternalSpec` Helper

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

```elm
{-| Check if a SpecId refers to a flattened external function.
-}
isFlattenedExternalSpec : Int -> Context -> Bool
isFlattenedExternalSpec specId ctx =
    case Dict.get specId ctx.signatures of
        Just sig ->
            sig.callModel == FlattenedExternal

        Nothing ->
            False
```

---

## Step 3: Add `callModelForCallee` Helper

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

```elm
{-| Determine the call model for a callee expression.
-}
callModelForCallee : Ctx.Context -> Mono.MonoExpr -> Ctx.CallModel
callModelForCallee ctx funcExpr =
    case funcExpr of
        Mono.MonoVarGlobal _ specId _ ->
            -- Look up whether this global is a MonoExtern
            if Ctx.isFlattenedExternalSpec specId ctx then
                Ctx.FlattenedExternal
            else
                Ctx.StageCurried

        Mono.MonoVarKernel _ _ _ _ ->
            -- Kernels are always flattened
            Ctx.FlattenedExternal

        _ ->
            -- Local vars, closures, other expressions: stage-curried
            Ctx.StageCurried
```

---

## Step 4: Add `generateFlattenedPartialApplication` Helper

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Location:** Add near `generateClosureApplication`

```elm
{-| Partial-apply a flattened external function (MonoExtern or kernel).

Uses total ABI arity for remaining_arity, not stage arity.
-}
generateFlattenedPartialApplication :
    Ctx.Context
    -> Mono.MonoExpr      -- func (MonoVarGlobal to MonoExtern, or MonoVarKernel)
    -> Mono.MonoType      -- funcType
    -> List Mono.MonoExpr -- args
    -> Mono.MonoType      -- resultType (post-application)
    -> ExprResult
generateFlattenedPartialApplication ctx func funcType args resultType =
    let
        -- 1. Generate the function value (creates PAP with total arity)
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        -- 2. Generate argument expressions
        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        -- 3. Box for closure boundary
        ( boxOps, boxedArgsWithTypes, ctx1b ) =
            boxArgsForClosureBoundary ctx1 argsWithTypes

        -- 4. Get total ABI arity from signature
        totalArity : Int
        totalArity =
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Dict.get specId ctx.signatures of
                        Just sig ->
                            List.length sig.paramTypes

                        Nothing ->
                            -- Fallback (shouldn't happen)
                            Types.countTotalArity funcType

                Mono.MonoVarKernel _ _ _ kernelType ->
                    let
                        sig = Ctx.kernelFuncSignatureFromType kernelType
                    in
                    List.length sig.paramTypes

                _ ->
                    Types.countTotalArity funcType

        -- 5. Build eco.papExtend with total arity
        ( resVar, ctx2 ) =
            Ctx.freshVar ctx1b

        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first boxedArgsWithTypes

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second boxedArgsWithTypes

        newargsUnboxedBitmap =
            List.indexedMap
                (\i ( _, mlirTy ) ->
                    if Types.isUnboxable mlirTy then
                        Bitwise.shiftLeftBy i 1
                    else
                        0
                )
                boxedArgsWithTypes
                |> List.foldl Bitwise.or 0

        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "remaining_arity", IntAttr Nothing totalArity )
                , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                ]

        resultMlirType =
            Types.monoTypeToAbi resultType

        ( ctx3, papExtendOp ) =
            Ops.mlirOp ctx2 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build
    in
    { ops = funcResult.ops ++ argOps ++ boxOps ++ [ papExtendOp ]
    , resultVar = resVar
    , resultType = resultMlirType
    , ctx = ctx3
    , isTerminated = False
    }
```

---

## Step 5: Modify `generateClosureApplication` to Dispatch by Call Model

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

```elm
generateClosureApplication ctx func args resultType =
    let
        funcType = Mono.typeOf func
        callModel = callModelForCallee ctx func
    in
    case callModel of
        Ctx.FlattenedExternal ->
            -- External/kernel: use total ABI arity
            generateFlattenedPartialApplication ctx func funcType args resultType

        Ctx.StageCurried ->
            -- User closure: use stage-curried applyByStages
            let
                funcResult = generateExpr ctx func
                expectedType = Types.monoTypeToAbi resultType
            in
            if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
                -- Already evaluated thunk
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType expectedType
                in
                { ops = funcResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = expectedType
                , ctx = ctx1
                , isTerminated = False
                }
            else
                -- Stage-curried application
                let
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped funcResult.ctx args

                    ( boxOps, boxedArgsWithTypes, ctx1b ) =
                        boxArgsForClosureBoundary ctx1 argsWithTypes

                    papResult =
                        applyByStages ctx1b funcResult.resultVar funcResult.resultType funcType boxedArgsWithTypes []
                in
                { ops = funcResult.ops ++ argOps ++ boxOps ++ papResult.ops
                , resultVar = papResult.resultVar
                , resultType = papResult.resultType
                , ctx = papResult.ctx
                , isTerminated = False
                }
```

---

## Step 6: Keep `applyByStages` Unchanged

No changes needed. It continues to:
- Use `Types.stageArity` and `Types.stageReturnType`
- Set `remaining_arity = stageN` per stage
- Only called for `StageCurried` call model

---

## Step 7: Run Tests

```bash
cd compiler && npx elm-test-rs --fuzz 1  # Front-end tests
cmake --build build --target check        # Full E2E tests
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add `CallModel` type, add to `FuncSignature`, update `extractNodeSignature`, add `isFlattenedExternalSpec` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `callModelForCallee`, add `generateFlattenedPartialApplication`, modify `generateClosureApplication` dispatch |

---

## Invariant Compliance

### CGEN_051 (papCreate arity = func params)
- **MonoExtern:** `extractNodeSignature` uses `decomposeFunctionType` → total params ✓
- **User functions:** `extractNodeSignature` uses `closureInfo.params` → stage params ✓
- **Kernels:** `generateVarKernel` uses kernel signature → total params ✓

### CGEN_052 (papExtend remaining_arity = source PAP remaining)
- **Flattened external (first partial app):**
  - Source PAP: `remaining = totalArity - 0 = totalArity`
  - papExtend: `remaining_arity = totalArity` ✓
- **Stage-curried (user closures):**
  - Source PAP: `remaining = stageArity`
  - papExtend: `remaining_arity = stageArity` via `applyByStages` ✓
- **Subsequent applications of external PAPs:**
  - After first extend, PAP remaining = totalArity - argsApplied
  - Next call through closure path sees matching stageArity ✓

---

## Summary: What Uses Which Path

| Expression Type | Node Type | Call Model | Arity Source |
|-----------------|-----------|------------|--------------|
| `List.map` | `MonoExtern` | FlattenedExternal | `decomposeFunctionType` (total) |
| `Basics.add` | `MonoExtern` | FlattenedExternal | `decomposeFunctionType` (total) |
| `Debug.log` | `MonoVarKernel` | FlattenedExternal | `kernelFuncSignatureFromType` |
| `.x` (accessor) | `MonoDefine` | StageCurried | `closureInfo.params` (stage) |
| `myFunc` (user) | `MonoDefine`/`MonoTailFunc` | StageCurried | `closureInfo.params` (stage) |
| `\x -> ...` | Closure expr | StageCurried | `closureInfo.params` (stage) |
| Local var `f` | Parameter | StageCurried | `stageArity(type)` |

---

## Estimated Scope

| Component | Lines |
|-----------|-------|
| `CallModel` type + `FuncSignature` update | ~10 |
| `extractNodeSignature` updates | ~20 |
| `isFlattenedExternalSpec` helper | ~10 |
| `callModelForCallee` helper | ~15 |
| `generateFlattenedPartialApplication` | ~60 |
| `generateClosureApplication` dispatch | ~15 |
| **Total** | **~130 lines** |
