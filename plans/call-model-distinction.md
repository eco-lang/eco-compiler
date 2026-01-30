# Plan: Distinguish Call Paths by Call Model (Option 4)

## Status: IMPLEMENTATION REQUIRED

The design for "Option 4: distinguish call paths by call model" is **partially implemented**. The core infrastructure exists, but **call model tracking through local variable bindings is missing**. This causes incorrect `remaining_arity` when local variables alias kernel functions.

---

## 1. Goal

**User closures** use **stage-curried** calling convention:
- `eco.papExtend.remaining_arity` = stage arity (`Types.stageArity funcType`)

**Kernel functions** use **flattened** calling convention:
- `eco.papExtend.remaining_arity` = total ABI arity (`Types.countTotalArity`)

**The call model must propagate transitively through local variable aliases:**
```elm
let
    f = Elm.Kernel.List.map  -- FlattenedExternal
    g = f                     -- Must inherit FlattenedExternal
in
    g identity [1,2,3]        -- Must use flattened arity
```

---

## 2. What Already Exists

### 2.1 Context.elm (Complete)
- `CallModel` type with `FlattenedExternal | StageCurried`
- `FuncSignature` with `callModel` field
- `extractNodeSignature` classifying node types
- `buildSignatures` creating SpecId -> FuncSignature map
- `isFlattenedExternalSpec` querying the signature table
- `kernelFuncSignatureFromType` for kernel signatures

### 2.2 Expr.elm (Partially Complete)
- `callModelForCallee` - works for `MonoVarGlobal` and `MonoVarKernel`
- `applyByStages` - stage-curried path using `stageArity`
- `generateFlattenedPartialApplication` - flattened path using total arity
- `generateClosureApplication` - branches on call model

### 2.3 What's Missing
- `varMappings` does not track call model
- `generateLet` does not propagate call model when binding variables
- `generateSaturatedCall` for `MonoVarLocal` always uses stage-curried path
- `callModelForCallee` returns `StageCurried` for all locals (ignores aliases)

---

## 3. Implementation Plan

### Step 1: Extend VarMapping / Context to Include CallModel

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

1. Introduce a `VarInfo` record:
   ```elm
   type alias VarInfo =
       { ssaVar : String
       , mlirType : MlirType
       , callModel : Maybe CallModel  -- Nothing for non-function values
       }
   ```

2. Change `Context` fields to use `VarInfo`:
   ```elm
   type alias Context =
       { nextVar : Int
       , nextOpId : Int
       , mode : Mode.Mode
       , registry : Mono.SpecializationRegistry
       , pendingLambdas : List PendingLambda
       , signatures : Dict.Dict Int FuncSignature
       , varMappings : Dict.Dict String VarInfo
       , currentLetSiblings : Dict.Dict String VarInfo
       , kernelDecls : Dict.Dict String ( List MlirType, MlirType )
       , typeRegistry : TypeRegistry
       }
   ```

3. Change `PendingLambda` to store sibling mappings as `VarInfo`:
   ```elm
   type alias PendingLambda =
       { name : String
       , captures : List ( Name.Name, Mono.MonoType )
       , params : List ( Name.Name, Mono.MonoType )
       , body : Mono.MonoExpr
       , returnType : Mono.MonoType
       , siblingMappings : Dict.Dict String VarInfo
       }
   ```

4. Update `initContext` to initialize the new dictionaries:
   ```elm
   initContext ... =
       { ...
       , varMappings = Dict.empty
       , currentLetSiblings = Dict.empty
       , ...
       }
   ```

*(This makes it explicit that both `varMappings` and `currentLetSiblings`, and via them `PendingLambda.siblingMappings`, move to `VarInfo`.)*

### Step 2: Update addVarMapping, lookupVar, and add lookupVarCallModel

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

1. Change `addVarMapping` to store `VarInfo`:
   ```elm
   addVarMapping : String -> String -> MlirType -> Maybe CallModel -> Context -> Context
   addVarMapping name ssaVar mlirTy maybeCallModel ctx =
       let
           info : VarInfo
           info =
               { ssaVar = ssaVar
               , mlirType = mlirTy
               , callModel = maybeCallModel
               }
       in
       { ctx | varMappings = Dict.insert name info ctx.varMappings }
   ```

2. Update `lookupVar` to unpack `VarInfo`:
   ```elm
   lookupVar : Context -> String -> ( String, MlirType )
   lookupVar ctx name =
       case Dict.get name ctx.varMappings of
           Just info ->
               ( info.ssaVar, info.mlirType )

           Nothing ->
               ( "%" ++ name, Types.ecoValue )
   ```

3. Add a helper to read the call model for a let-bound variable:
   ```elm
   lookupVarCallModel : Context -> String -> Maybe CallModel
   lookupVarCallModel ctx name =
       case Dict.get name ctx.varMappings of
           Just info ->
               info.callModel

           Nothing ->
               Nothing
   ```

*(You don't need to export `VarInfo`; keep it internal to `Context.elm`.)*

### Step 3: Add callModelForExpr (expression → Maybe CallModel)

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

```elm
callModelForExpr : Ctx.Context -> Mono.MonoExpr -> Maybe Ctx.CallModel
callModelForExpr ctx expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            if Ctx.isFlattenedExternalSpec specId ctx then
                Just Ctx.FlattenedExternal
            else
                Just Ctx.StageCurried

        Mono.MonoVarKernel _ _ _ _ ->
            Just Ctx.FlattenedExternal

        Mono.MonoVarLocal name _ ->
            -- Inherit whatever the binding decided (may be FlattenedExternal or StageCurried)
            Ctx.lookupVarCallModel ctx name

        Mono.MonoClosure _ _ _ ->
            Just Ctx.StageCurried

        _ ->
            -- Non-function (or unknown) expression
            Nothing
```

*Intended use:* in `generateLet`, to decide what `Maybe CallModel` to store for a new local binding.

### Step 4: Update generateLet to store callModel in varMappings

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

In the `Mono.MonoDef name expr` branch of `generateLet`, change:

```elm
exprResult =
    generateExpr ctxWithPlaceholders expr

ctx1 =
    Ctx.addVarMapping name exprResult.resultVar exprResult.resultType exprResult.ctx
```

to:

```elm
exprResult =
    generateExpr ctxWithPlaceholders expr

exprCallModel : Maybe Ctx.CallModel
exprCallModel =
    callModelForExpr ctxWithPlaceholders expr

ctx1 =
    Ctx.addVarMapping name exprResult.resultVar exprResult.resultType exprCallModel exprResult.ctx
```

In the `Mono.MonoTailDef` branch, update both `addVarMapping` calls:

```elm
-- parameters: plain values
ctxWithParams =
    List.foldl
        (\( paramName, paramType ) acc ->
            Ctx.addVarMapping
                paramName
                ("%" ++ paramName)
                (Types.monoTypeToAbi paramType)
                Nothing
                acc
        )
        ctxWithPlaceholders
        params

-- function name: local tail func is stage-curried
funcMlirType =
    Types.ecoValue

ctxWithFunc =
    Ctx.addVarMapping name ("%" ++ name) funcMlirType (Just Ctx.StageCurried) ctxWithParams
```

### Step 5: Update callModelForCallee for locals

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

```elm
callModelForCallee : Ctx.Context -> Mono.MonoExpr -> Ctx.CallModel
callModelForCallee ctx funcExpr =
    case funcExpr of
        Mono.MonoVarGlobal _ specId _ ->
            if Ctx.isFlattenedExternalSpec specId ctx then
                Ctx.FlattenedExternal
            else
                Ctx.StageCurried

        Mono.MonoVarKernel _ _ _ _ ->
            Ctx.FlattenedExternal

        Mono.MonoVarLocal name _ ->
            case Ctx.lookupVarCallModel ctx name of
                Just model ->
                    model

                Nothing ->
                    -- Function parameters and non-annotated locals default to user-closure semantics
                    Ctx.StageCurried

        _ ->
            -- Arbitrary expressions default to stage-curried closure model
            Ctx.StageCurried
```

### Step 6: Use callModelForCallee for saturated local calls

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

In `generateSaturatedCall`, replace the entire `Mono.MonoVarLocal name funcType ->` branch with:

```elm
    Mono.MonoVarLocal name funcType ->
        let
            ( funcVarName, funcVarType ) =
                Ctx.lookupVar ctx name

            callModel =
                callModelForCallee ctx func

            expectedType =
                Types.monoTypeToAbi resultType
        in
        case callModel of
            Ctx.FlattenedExternal ->
                -- Local alias of a flattened external (e.g. let f = List.map in f x xs)
                --
                -- Reuse the flattened external machinery by treating this as a
                -- call through the original expression, not by stages.
                --
                -- We already know func is a MonoVarLocal; just route through
                -- the generic flattened path:
                generateFlattenedPartialApplication ctx func args resultType

            Ctx.StageCurried ->
                -- Existing stage-curried behavior
                if not (Types.isEcoValueType funcVarType) && List.isEmpty args then
                    let
                        ( coerceOps, finalVar, ctx1 ) =
                            coerceResultToType ctx funcVarName funcVarType expectedType
                    in
                    { ops = coerceOps
                    , resultVar = finalVar
                    , resultType = expectedType
                    , ctx = ctx1
                    , isTerminated = False
                    }

                else
                    let
                        ( argOps, argsWithTypes, ctx1 ) =
                            generateExprListTyped ctx args

                        ( boxOps, boxedArgsWithTypes, ctx1b ) =
                            boxArgsForClosureBoundary ctx1 argsWithTypes

                        papResult =
                            applyByStages ctx1b funcVarName funcVarType funcType boxedArgsWithTypes []
                    in
                    { ops = argOps ++ boxOps ++ papResult.ops
                    , resultVar = papResult.resultVar
                    , resultType = papResult.resultType
                    , ctx = papResult.ctx
                    , isTerminated = False
                    }
```

*(This keeps global/kernel saturated calls unchanged; only local aliases now respect the stored call model.)*

### Step 7: Update All addVarMapping Call Sites

Search for all uses of `addVarMapping` and update them:

1. **generateLet** (Step 4 above)
2. **generateDestruct** - destructured bindings are values, use `Nothing`
3. **ctxWithParams** in generateLet for TailDef - parameters are values, use `Nothing`
4. **addPlaceholderMappings** - placeholders, use `Nothing`
5. **Lambda parameter bindings** - parameters are values, use `Nothing`

Additionally, update all direct constructors of `Dict.Dict String ( String, MlirType )` that are used as `varMappings` or `siblingMappings` to build `VarInfo` instead:

- **`Lambdas.elm` / `generateLambdaFunc`**:
  - `varMappingsWithArgs` and `varMappingsWithSiblings` should be `Dict String VarInfo`, with `callModel = Nothing` for captures/params.
  - When seeding the context:
    ```elm
    varInfo =
        { ssaVar = varName, mlirType = mlirType, callModel = Nothing }
    ```
- **`Functions.elm`**:
  - In `generateTailFunc`, `generateClosureFunc`, and any other helper that builds `freshVarMappings`, switch to `Dict String VarInfo` with `callModel = Nothing` for parameters.
- **`Expr.elm`**:
  - `addPlaceholderMappings` and `generateDestruct` must pass `Nothing` for `callModel` when calling `Ctx.addVarMapping`.

This makes sure every place that seeds a new mapping does so with an explicit `Maybe CallModel`.

### Step 8: Update currentLetSiblings and closure siblingMappings

**Files:**
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`
- `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`

1. In `Expr.generateLet`, after Step 4's changes, the construction of `ctxWithPlaceholders` remains:
   ```elm
   ctxWithPlaceholders =
       { groupVarMappings | currentLetSiblings = groupVarMappings.varMappings }
   ```
   This now copies a `Dict String VarInfo` instead of a dict of pairs.

2. In `Expr.generateClosure`, update `baseSiblings` and `pendingLambda`:
   ```elm
   baseSiblings : Dict.Dict String Ctx.VarInfo
   baseSiblings =
       if Dict.isEmpty ctx.currentLetSiblings then
           ctx.varMappings
       else
           ctx.currentLetSiblings

   pendingLambda =
       { name = ...
       , captures = captureTypes
       , params = closureInfo.params
       , body = body
       , returnType = Mono.typeOf body
       , siblingMappings = baseSiblings
       }
   ```

3. In `Lambdas.generateLambdaFunc`, change:
   ```elm
   varMappingsWithArgs : Dict.Dict String ( String, MlirType )
   ...
   varMappingsWithSiblings : Dict.Dict String ( String, MlirType )
   ...
   { ctx | varMappings = varMappingsWithSiblings, ... }
   ```
   to:
   ```elm
   varMappingsWithArgs : Dict.Dict String Ctx.VarInfo
   varMappingsWithArgs =
       List.foldl
           (\( name, monoTy ) acc ->
               let
                   mlirType = Types.monoTypeToAbi monoTy
                   varName = "%" ++ name
               in
               Dict.insert name
                   { ssaVar = varName
                   , mlirType = mlirType
                   , callModel = Nothing
                   }
                   acc
           )
           Dict.empty
           (lambda.captures ++ lambda.params)

   varMappingsWithSiblings : Dict.Dict String Ctx.VarInfo
   varMappingsWithSiblings =
       Dict.union varMappingsWithArgs lambda.siblingMappings

   ctxWithArgs =
       { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarAfterParams }
   ```

### Step 9: Add Test Case

**File:** `tests/codegen/kernel_alias_call.elm` (or similar)

```elm
module KernelAliasCall exposing (main)

import Elm.Kernel.List

main =
    let
        f = Elm.Kernel.List.map
        g = f  -- transitive alias
    in
    g (\x -> x + 1) [1, 2, 3]
```

This should compile and produce correct `remaining_arity=2` in the `papExtend` operations.

---

## 4. Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add `VarInfo` type, update `Context` fields, update `PendingLambda`, update `addVarMapping`, update `lookupVar`, add `lookupVarCallModel` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `callModelForExpr`, update `callModelForCallee`, update `generateLet`, update `generateSaturatedCall` for `MonoVarLocal`, update `generateClosure`, update `addPlaceholderMappings`, update `generateDestruct` |
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | Update `generateLambdaFunc` to use `VarInfo` for `varMappingsWithArgs` and `varMappingsWithSiblings` |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | Update `generateTailFunc`, `generateClosureFunc` to use `VarInfo` |
| Test file | Add test case for kernel alias |

---

## 5. Verification

After implementation:

1. **Unit tests**: `cd compiler && npx elm-test --fuzz 1`
2. **E2E tests**: `cmake --build build --target check`
3. **Specific test**: Verify the kernel alias test case produces correct MLIR with `remaining_arity` matching total arity

---

## 6. Resolved Questions

1. **VarInfo type:** Type alias (confirmed)
2. **Closure captures:** No call model needed - captures become SSA values, call model looked up at call time
3. **Function parameters:** No call model needed - use `callModel = Nothing`

---

## 7. Assumptions

1. **Only kernel functions use flattened calling convention** - user-defined externs from other packages would also need flattened if they were compiled with that convention, but for now kernels are the primary concern.

2. **Transitive propagation is sufficient** - we don't need to track through complex expressions like `if cond then kernelFn else userFn`, only simple aliases.

3. **The Mono IR preserves aliasing** - `let f = Kernel.fn` creates a `MonoDef` with `MonoVarKernel` as the bound expression, not inlined away.
