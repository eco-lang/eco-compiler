# Finish Moving Call-Site Staging Logic from MLIR Codegen to GlobalOpt

## Overview

Complete the refactoring to ensure all call-site staging and calling-convention decisions are made in GlobalOpt, with MLIR codegen acting purely as a translation layer.

### Current State
- `Mono.CallInfo` and `GlobalOpt.annotateCallStaging` exist and are wired into `globalOptimize`
- MLIR codegen (`Expr.elm`, `Context.elm`) still has residual per-call staging/arity logic and its own `CallModel` / variable arity tracking
- Some newer CallInfo-based code paths exist in `Expr.elm`, but older Context-driven call paths remain

### Target State
- **GlobalOpt**: The *only* phase that decides staging / call model / per-stage arities, written as `Mono.CallInfo` on every `MonoCall`
- **MLIR codegen**: Only reads `CallInfo` (plus FuncSignature for ABI types), does Mono→MLIR type translation, and emits correct MLIR ops. Does **not** re-derive call models, call arities, or staging from `MonoType`

---

## Resolved Questions

### Q1: `FuncSignature.callModel`
**Decision: REMOVE.** Only read in `isFlattenedExternalSpec`, which is never used elsewhere. Dead code.

### Q2: `FuncSignature.returnedClosureParamCount`
**Decision: REMOVE.** Only used in `Expr.generateLet` to compute `exprSourceArity`, which is superseded by `CallInfo.initialRemaining` / `remainingStageArities`. Also allows removing `annotateReturnedClosureArity`.

### Q3: `extractNodeSignature`
**Decision: SIMPLIFY.** Becomes a pure type extractor returning only `{ paramTypes, returnType }`. No `callModel`, no returned-closure metadata. Still useful for invariant checking and kernel declaration generation.

### Q4: `applyByStages` when `remainingStageArities` empty but args remain
**Decision: NO SPECIAL HANDLING NEEDED.**
- `remainingStageArities` is only consulted when `rawResultRemaining <= 0` (stage boundary crossed)
- For partial applications (`rawResultRemaining > 0`), empty `remainingStageArities` is irrelevant
- GlobalOpt sets `remainingStageArities = []` for unknown callees with full total arity as `sourceArity` (single-stage treatment)
- If we exhaust a stage and need another but list is empty → malformed `CallInfo` from GlobalOpt (invariant violation), existing "treat as terminal" behavior is reasonable fallback

### Q5: `annotateReturnedClosureArity`
**Decision: REMOVE.** Once `FuncSignature.returnedClosureParamCount` is gone, no consumer exists. `CallInfo.remainingStageArities` provides all needed information.

### Q6: `Context.CallModel`
**Decision: REMOVE.** `Mono.CallModel` is used for calls via `Mono.CallInfo.callModel`. No remaining legitimate use of separate `Context.CallModel`.

---

## Phase 0: Invariants and Pipeline Context

### 0.1 Key Invariants

- **MONO_016 (staging invariant)**: For each `MonoClosure` with function type `T`:
  `length closureInfo.params == length (Mono.stageParamTypes T)`

- **Call-site invariant** (GlobalOpt side): For every `MonoCall`:
  ```elm
  callInfo : Mono.CallInfo
  { callModel         -- FlattenedExternal | StageCurried
  , stageArities      -- Full staging of function type (StageCurried only)
  , isSingleStageSaturated
  , initialRemaining  -- Current PAP's remaining arity (CGEN_052)
  , remainingStageArities -- Stage arities for subsequent stages
  }
  ```

- **CGEN_052 (PAP arity invariant)**: For each `eco.papExtend`, `remaining_arity` equals source closure's remaining arity prior to application, and `remaining_arity >= num_new_args`

### 0.2 Pipeline Order

1. Monomorphization produces `MonoGraph` with `Mono.defaultCallInfo` placeholders
2. `GlobalOpt.globalOptimize` runs:
   - Closure staging canonicalization (GOPT_016)
   - Case/if ABI normalization (GOPT_018)
   - Staging validation
   - `annotateCallStaging` to populate `CallInfo` on each `MonoCall`
   - ~~`annotateReturnedClosureArity`~~ (REMOVED)
3. MLIR backend consumes optimized `MonoGraph`:
   - `Context.buildSignatures` builds `FuncSignature` map (types only, no staging)
   - `Expr.generateExpr` walks graph including `MonoCall` nodes
   - `Expr.generateCall` and `Expr.generateClosureApplication` use **only** `Mono.CallInfo`

---

## Phase 1: Context.elm - Simplify to Pure Types

### Task 1.1: Update Module Exports
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Remove from exports:
- `CallModel(..)`
- `VarInfo`
- `isFlattenedExternalSpec`
- `lookupVarCallModel`
- `lookupVarArity`

### Task 1.2: Delete Local CallModel Type
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Remove:
```elm
type CallModel
    = FlattenedExternal
    | StageCurried
```
And its doc comment.

### Task 1.3: Simplify FuncSignature
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change from:
```elm
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , callModel : CallModel
    , returnedClosureParamCount : Maybe Int
    }
```

To:
```elm
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    }
```

Update doc comment to remove references to call model and returned-closure counts.

### Task 1.4: Update kernelFuncSignatureFromType
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change to:
```elm
kernelFuncSignatureFromType : Mono.MonoType -> FuncSignature
kernelFuncSignatureFromType funcType =
    let
        ( argTypes, retType ) =
            Mono.decomposeFunctionType funcType
    in
    { paramTypes = argTypes
    , returnType = retType
    }
```

Remove `callModel = FlattenedExternal` and `returnedClosureParamCount = Nothing`.

### Task 1.5: Delete isFlattenedExternalSpec
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Remove entire function and doc comment:
```elm
isFlattenedExternalSpec : Int -> Context -> Bool
isFlattenedExternalSpec specId ctx = ...
```

### Task 1.6: Simplify VarInfo
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change from:
```elm
type alias VarInfo =
    { ssaVar : String
    , mlirType : MlirType
    , callModel : Maybe CallModel
    , sourceArity : Maybe Int
    }
```

To:
```elm
type alias VarInfo =
    { ssaVar : String
    , mlirType : MlirType
    }
```

### Task 1.7: Simplify addVarMapping
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change from:
```elm
addVarMapping : String -> String -> MlirType -> Maybe CallModel -> Maybe Int -> Context -> Context
addVarMapping name ssaVar mlirTy maybeCallModel maybeSourceArity ctx =
    let
        info : VarInfo
        info =
            { ssaVar = ssaVar
            , mlirType = mlirTy
            , callModel = maybeCallModel
            , sourceArity = maybeSourceArity
            }
    in
    { ctx | varMappings = Dict.insert name info ctx.varMappings }
```

To:
```elm
addVarMapping : String -> String -> MlirType -> Context -> Context
addVarMapping name ssaVar mlirTy ctx =
    let
        info : VarInfo
        info =
            { ssaVar = ssaVar
            , mlirType = mlirTy
            }
    in
    { ctx | varMappings = Dict.insert name info ctx.varMappings }
```

### Task 1.8: Delete lookupVarCallModel and lookupVarArity
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Remove both functions and their doc comments.

### Task 1.9: Simplify extractNodeSignature
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change signature from:
```elm
extractNodeSignature : Int -> Mono.MonoNode -> Dict.Dict Int (Maybe Int) -> Maybe FuncSignature
```

To:
```elm
extractNodeSignature : Int -> Mono.MonoNode -> Maybe FuncSignature
```

Update implementation to return only `{ paramTypes, returnType }`:
```elm
extractNodeSignature specId node =
    case node of
        Mono.MonoDefine expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        }

        Mono.MonoTailFunc params _ monoType ->
            let
                returnType =
                    case monoType of
                        Mono.MFunction _ ret -> ret
                        _ -> monoType
            in
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = returnType
                }

        Mono.MonoCtor ctorShape monoType ->
            Just
                { paramTypes = ctorShape.fieldTypes
                , returnType = monoType
                }

        Mono.MonoEnum _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                }

        Mono.MonoExtern monoType ->
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Mono.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        }
                _ ->
                    Nothing

        Mono.MonoPortIncoming expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }
                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        }

        Mono.MonoPortOutgoing expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }
                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        }

        Mono.MonoCycle _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                }
```

### Task 1.10: Simplify buildSignatures
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change from:
```elm
buildSignatures :
    EveryDict.Dict Int Int Mono.MonoNode
    -> Dict.Dict Int (Maybe Int)
    -> Dict.Dict Int FuncSignature

buildSignatures nodes returnedCounts =
    EveryDict.foldl compare
        (\specId node acc ->
            case extractNodeSignature specId node returnedCounts of
                ...
```

To:
```elm
buildSignatures :
    EveryDict.Dict Int Int Mono.MonoNode
    -> Dict.Dict Int FuncSignature

buildSignatures nodes =
    EveryDict.foldl compare
        (\specId node acc ->
            case extractNodeSignature specId node of
                Just sig ->
                    Dict.insert specId sig acc

                Nothing ->
                    acc
        )
        Dict.empty
        nodes
```

---

## Phase 2: MonoGlobalOptimize.elm - Remove Returned-Closure Annotation

### Task 2.1: Remove annotateReturnedClosureArity from globalOptimize
**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Change from:
```elm
graph4 =
    annotateCallStaging graph3

graph5 =
    annotateReturnedClosureArity graph4
in
graph5
```

To:
```elm
graph4 =
    annotateCallStaging graph3
in
graph4
```

Update doc comment to remove step 5 reference.

### Task 2.2: Delete annotateReturnedClosureArity
**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Remove entire function:
```elm
annotateReturnedClosureArity : Mono.MonoGraph -> Mono.MonoGraph
annotateReturnedClosureArity (Mono.MonoGraph record) =
    ...
```

Note: `MonoGraph.returnedClosureParamCounts` field becomes unused but can be cleaned up in a later change.

---

## Phase 3: Backend.elm - Stop Threading returnedClosureParamCounts

### Task 3.1: Remove returnedCounts and Simplify signatures Build
**File:** `compiler/src/Compiler/Generate/MLIR/Backend.elm`

Delete:
```elm
-- Convert Data.Map -> Elm Dict for returnedClosureParamCounts
returnedCounts : Dict.Dict Int (Maybe Int)
returnedCounts =
    EveryDict.foldl compare
        (\specId maybeCount acc ->
            Dict.insert specId maybeCount acc
        )
        Dict.empty
        returnedClosureParamCounts

signatures : Dict.Dict Int Ctx.FuncSignature
signatures =
    Ctx.buildSignatures nodes returnedCounts
```

Replace with:
```elm
signatures : Dict.Dict Int Ctx.FuncSignature
signatures =
    Ctx.buildSignatures nodes
```

Keep the record destructure pattern to match the type (just don't use `returnedClosureParamCounts`).

---

## Phase 4: Expr.elm - Use Only CallInfo-Based Paths

### Task 4.1: Keep Only CallInfo-Based generateCall
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Keep the version with signature:
```elm
generateCall :
    Ctx.Context
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
    -> ExprResult
```

That pattern-matches on `callInfo.callModel` and `callInfo.isSingleStageSaturated`.

Delete the older version that uses `callModelForCallee ctx func`.

Ensure `Mono.MonoCall` case in `generateExpr` calls the new signature:
```elm
Mono.MonoCall _ func args resultType callInfo ->
    generateCall ctx func args resultType callInfo
```

### Task 4.2: Keep Only CallInfo-Based generateClosureApplication
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Keep the version that takes `Mono.CallInfo` and uses:
- `callInfo.initialRemaining`
- `callInfo.remainingStageArities`
- `applyByStages` with `List Int` remaining stage arities

Delete the older version that:
- Takes no `CallInfo`
- Recomputes staging with `callModelForCallee ctx func`
- Derives `initialRemaining` and `returnedClosureParamCount` from `Ctx.lookupVarArity` / signatures

### Task 4.3: Keep Only List-Based applyByStages
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Keep:
```elm
applyByStages :
    Ctx.Context
    -> String
    -> MlirType
    -> Int              -- sourceRemaining
    -> List Int         -- remainingStageArities
    -> MlirType
    -> List ( String, MlirType )
    -> List MlirOp
    -> ApplyByStagesResult
```

Delete the older version with `Maybe Int` for `returnedClosureParamCount`.

### Task 4.4: Simplify generateLet
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Remove `exprSourceArity` binding and its case-expression entirely.

Change from:
```elm
Mono.MonoDef name expr ->
    let
        exprResult =
            generateExpr ctxWithPlaceholders expr

        exprSourceArity : Maybe Int
        exprSourceArity =
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    Just (List.length closureInfo.params)

                Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) args _ _ ->
                    case Dict.get specId ctxWithPlaceholders.signatures of
                        Just sig ->
                            if List.length args >= List.length sig.paramTypes then
                                sig.returnedClosureParamCount
                            else
                                Just (List.length sig.paramTypes - List.length args)
                        Nothing ->
                            Nothing

                _ ->
                    Nothing

        ctx1 =
            Ctx.addVarMapping name exprResult.resultVar exprResult.resultType Nothing exprSourceArity exprResult.ctx
```

To:
```elm
Mono.MonoDef name expr ->
    let
        exprResult =
            generateExpr ctxWithPlaceholders expr

        ctx1 =
            Ctx.addVarMapping name exprResult.resultVar exprResult.resultType exprResult.ctx
```

### Task 4.5: Delete callModelForExpr
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Remove helper:
```elm
callModelForExpr : Ctx.Context -> Mono.MonoExpr -> Maybe Ctx.CallModel
callModelForExpr ctx expr =
    ...
```

And all uses of it.

### Task 4.6: Update All addVarMapping Call Sites
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Search for `Ctx.addVarMapping` and update all calls to new 3-arg signature:

From:
```elm
Ctx.addVarMapping paramName ("%" ++ paramName) (Types.monoTypeToAbi paramType) Nothing Nothing acc
```

To:
```elm
Ctx.addVarMapping paramName ("%" ++ paramName) (Types.monoTypeToAbi paramType) acc
```

Apply to:
- Tail function parameters
- `addPlaceholderMappings`
- Any other uses

---

## Phase 5: Verification

### Task 5.1: Verify CGEN_052 Tests Pass
**File:** `compiler/tests/TestLogic/Generate/CodeGen/PapExtendArity.elm`

Confirm:
- `remaining_arity` for StageCurried = `callInfo.initialRemaining` (not recomputed from MonoType)
- `remaining_arity` for FlattenedExternal = `totalArity` from FuncSignature

### Task 5.2: Verify MONO_016 Tests Pass
Ensure tests check stage arity, not flattened total arity.

### Task 5.3: Run Full Test Suite
```bash
cd compiler && npx elm-test-rs --fuzz 1
cmake --build build --target check
```

---

## Complete Checklist

### Phase 1: Context.elm
- [ ] 1.1: Update module exports (remove CallModel, VarInfo, dead functions)
- [ ] 1.2: Delete local CallModel type
- [ ] 1.3: Simplify FuncSignature to `{ paramTypes, returnType }`
- [ ] 1.4: Update kernelFuncSignatureFromType
- [ ] 1.5: Delete isFlattenedExternalSpec
- [ ] 1.6: Simplify VarInfo to `{ ssaVar, mlirType }`
- [ ] 1.7: Simplify addVarMapping to 3 args
- [ ] 1.8: Delete lookupVarCallModel and lookupVarArity
- [ ] 1.9: Simplify extractNodeSignature (remove returnedCounts param)
- [ ] 1.10: Simplify buildSignatures (remove returnedCounts param)

### Phase 2: MonoGlobalOptimize.elm
- [ ] 2.1: Remove annotateReturnedClosureArity from globalOptimize
- [ ] 2.2: Delete annotateReturnedClosureArity function

### Phase 3: Backend.elm
- [ ] 3.1: Remove returnedCounts and simplify signatures build

### Phase 4: Expr.elm
- [ ] 4.1: Keep only CallInfo-based generateCall
- [ ] 4.2: Keep only CallInfo-based generateClosureApplication
- [ ] 4.3: Keep only List-based applyByStages
- [ ] 4.4: Simplify generateLet (remove exprSourceArity)
- [ ] 4.5: Delete callModelForExpr
- [ ] 4.6: Update all addVarMapping call sites to 3-arg form

### Phase 5: Verification
- [ ] 5.1: Verify CGEN_052 tests pass
- [ ] 5.2: Verify MONO_016 tests pass
- [ ] 5.3: Run full test suite

---

## Summary of Removals

| Item | File | Reason |
|------|------|--------|
| `Context.CallModel` | Context.elm | Superseded by `Mono.CallModel` |
| `FuncSignature.callModel` | Context.elm | Only used by dead `isFlattenedExternalSpec` |
| `FuncSignature.returnedClosureParamCount` | Context.elm | Superseded by `CallInfo.remainingStageArities` |
| `VarInfo.callModel` | Context.elm | Not needed; calls use `Mono.CallInfo` |
| `VarInfo.sourceArity` | Context.elm | Not needed; calls use `Mono.CallInfo` |
| `isFlattenedExternalSpec` | Context.elm | Never used |
| `lookupVarCallModel` | Context.elm | Never used |
| `lookupVarArity` | Context.elm | Never used |
| `annotateReturnedClosureArity` | MonoGlobalOptimize.elm | No consumer after FuncSignature simplification |
| `callModelForExpr` | Expr.elm | Replaced by `Mono.CallInfo` |
| Old `applyByStages` (Maybe Int) | Expr.elm | Replaced by List Int version |
| `exprSourceArity` in generateLet | Expr.elm | Replaced by `CallInfo.initialRemaining` |

---

## End State

After all changes:
- `FuncSignature` is purely `{ paramTypes, returnType }`
- No `Context.CallModel` or staging metadata in MLIR context
- `buildSignatures` no longer consumes `returnedClosureParamCounts`
- `Expr` strictly uses `Mono.CallInfo` for call lowering
- `FuncSignature` only used for types and kernel ABI

**GlobalOpt is the sole owner of staging and call-model decisions. MLIR codegen is a pure translator driven by that metadata.**
