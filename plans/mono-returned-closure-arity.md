# Plan: Move Returned Closure Arity Analysis to MonoGlobalOptimize

## Overview

This plan simplifies `computeReturnedClosureParamCount` to rely on now-normalized `MonoCase`/`MonoIf` result types, and moves this analysis from MLIR `Context.elm` into the Mono global optimization phase.

**Goal**: After ABI normalization in `MonoGlobalOptimize`, the result types of case/if expressions are trustworthy. We can eliminate the fragile structural analysis in MLIR and use a simple type-based approach computed once in the Mono layer.

---

## Background

### Current State (MLIR Context.elm)

`computeReturnedClosureParamCount` analyzes a `MonoExpr` structurally:

```elm
computeReturnedClosureParamCount : Mono.MonoExpr -> Maybe Int
computeReturnedClosureParamCount expr =
    case expr of
        Mono.MonoClosure closureInfo _ _ ->
            Just (List.length closureInfo.params)

        Mono.MonoLet _ body _ ->
            computeReturnedClosureParamCount body

        Mono.MonoCase _ _ _ jumps _ ->
            case jumps of
                ( _, branchExpr ) :: _ ->
                    computeReturnedClosureParamCount branchExpr
                [] ->
                    typeBasedArity expr

        Mono.MonoIf _ final _ ->
            computeReturnedClosureParamCount final

        _ ->
            typeBasedArity expr
```

This is used in `extractNodeSignature` to populate `FuncSignature.returnedClosureParamCount` for:
- `MonoDefine` whose expr is `MonoClosure`
- `MonoPortIncoming` / `MonoPortOutgoing` whose expr is `MonoClosure`

### Why This Is Now Overkill

After `MonoGlobalOptimize`:
- `normalizeCaseIfAbi` normalizes staging of case/if result types
- `validateClosureStaging` enforces MONO_016: `length closureInfo.params == length (Types.stageParamTypes closureType)`

So for any expression `e` whose type is function-typed, `Types.stageArity (Mono.typeOf e)` is the **right** per-stage arity (and matches closure params). The special-casing for `MonoCase` jumps and "empty jump -> fallback" paths are no longer needed.

---

## Verified Type Information

### Dict Types

**In MonoGraph** (uses `Data.Map as Dict`):
```elm
returnedClosureParamCounts : Dict Int SpecId (Maybe Int)
```

**In MLIR Context** (uses Elm's `Dict`):
```elm
Dict.Dict Int (Maybe Int)
```

**Conversion required at Backend boundary** - see Step 7.

### SpecId Export

`SpecId` is exported from `Compiler.AST.Monomorphized`:
```elm
type alias SpecId = Int
```

So type annotations can use `Mono.SpecId`.

### MonoGraph Definition (actual field name is `ctorShapes`)

```elm
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List String) (List CtorShape)
        }
```

### Node Coverage

**All node types produce FuncSignature**, but only these compute `returnedClosureParamCount`:
- `MonoDefine` where expr is `MonoClosure`
- `MonoPortIncoming` where expr is `MonoClosure`
- `MonoPortOutgoing` where expr is `MonoClosure`

**Always use `returnedClosureParamCount = Nothing`**:
- `MonoTailFunc` - produces signature but no returned closure analysis
- `MonoCycle` - produces signature with empty params
- `MonoCtor` - uses `FlattenedExternal` call model
- `MonoEnum` - uses `FlattenedExternal` call model
- `MonoExtern` - uses `FlattenedExternal` call model

### stageArity Usage

`applyByStages` fallback is already `Types.stageArity stageRetType`, so `returnedClosureParamCount` must be stage-arity based (not total arity). This matches MONO_016.

---

## Implementation Steps

### Step 1: Create MonoReturnArity Module

**File**: `compiler/src/Compiler/Optimize/MonoReturnArity.elm`

```elm
module Compiler.Optimize.MonoReturnArity exposing (computeReturnedClosureParamCount)

{-| Compute returned closure parameter count using normalized types.

After ABI normalization, we can rely on `Types.stageArity` instead of
structural analysis of case/if branches.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Types as Types
import Utils.Crash as Utils


{-| Compute how many parameters a returned closure takes (first stage only).

For closures, validates MONO_016 and returns stage param count.
For other function-typed expressions, returns stage arity from type.
For non-function expressions, returns Nothing.

-}
computeReturnedClosureParamCount : Mono.MonoExpr -> Maybe Int
computeReturnedClosureParamCount expr =
    case expr of
        Mono.MonoClosure info _ closureType ->
            let
                stageParamCount =
                    List.length (Types.stageParamTypes closureType)
            in
            if List.length info.params /= stageParamCount then
                Utils.crash
                    ("MonoReturnArity: MONO_016 violation: closure params="
                        ++ String.fromInt (List.length info.params)
                        ++ ", stage arity="
                        ++ String.fromInt stageParamCount
                    )

            else
                Just stageParamCount

        _ ->
            let
                exprType =
                    Mono.typeOf expr
            in
            case exprType of
                Mono.MFunction _ _ ->
                    Just (Types.stageArity exprType)

                _ ->
                    Nothing
```

Key points:
- **No structural recursion** over `MonoCase`/`MonoIf` - just ask the (now-normalized) type
- **Uses `stageArity`** - matches how `applyByStages` consumes it
- **Validates MONO_016** for closures as a sanity check

### Step 2: Extend MonoGraph with returnedClosureParamCounts Field

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`

Change MonoGraph from:
```elm
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List String) (List CtorShape)
        }
```

To:
```elm
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List String) (List CtorShape)
        , returnedClosureParamCounts : Dict Int SpecId (Maybe Int)
        }
```

### Step 3: Initialize Field in Monomorphize

**File**: `compiler/src/Compiler/Generate/Monomorphize.elm`

Where `MonoGraph` is constructed, add:
```elm
Mono.MonoGraph
    { nodes = nodes
    , main = main
    , registry = registry
    , ctorShapes = ctorShapes
    , returnedClosureParamCounts = Dict.empty
    }
```

### Step 4: Thread Field Through MonoInlineSimplify

**File**: `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm`

Update pattern matching and reconstruction to preserve the new field:
```elm
let
    (Mono.MonoGraph { nodes, main, registry, ctorShapes, returnedClosureParamCounts }) =
        graph
in
...
( Mono.MonoGraph
    { nodes = optimizedNodes
    , main = main
    , registry = registry
    , ctorShapes = ctorShapes
    , returnedClosureParamCounts = returnedClosureParamCounts
    }
, metrics
)
```

### Step 5: Add annotateReturnedClosureArity to MonoGlobalOptimize

**File**: `compiler/src/Compiler/Optimize/MonoGlobalOptimize.elm`

Add import:
```elm
import Compiler.Optimize.MonoReturnArity as MonoReturnArity
```

Add the annotation function:
```elm
annotateReturnedClosureArity : Mono.MonoGraph -> Mono.MonoGraph
annotateReturnedClosureArity (Mono.MonoGraph record) =
    let
        returnedMap : Dict Int SpecId (Maybe Int)
        returnedMap =
            Dict.foldl compare
                (\specId node acc ->
                    case node of
                        Mono.MonoDefine expr _ ->
                            case expr of
                                Mono.MonoClosure _ body _ ->
                                    Dict.insert identity specId (MonoReturnArity.computeReturnedClosureParamCount body) acc

                                _ ->
                                    acc

                        Mono.MonoPortIncoming expr _ ->
                            case expr of
                                Mono.MonoClosure _ body _ ->
                                    Dict.insert identity specId (MonoReturnArity.computeReturnedClosureParamCount body) acc

                                _ ->
                                    acc

                        Mono.MonoPortOutgoing expr _ ->
                            case expr of
                                Mono.MonoClosure _ body _ ->
                                    Dict.insert identity specId (MonoReturnArity.computeReturnedClosureParamCount body) acc

                                _ ->
                                    acc

                        -- MonoTailFunc, MonoCycle, MonoCtor, MonoEnum, MonoExtern: no annotation
                        _ ->
                            acc
                )
                Dict.empty
                record.nodes
    in
    Mono.MonoGraph { record | returnedClosureParamCounts = returnedMap }
```

### Step 6: Wire Into globalOptimize

Update `globalOptimize`:
```elm
globalOptimize mode typeEnv graph0 =
    let
        -- Phase 1: ABI normalization
        graph1 =
            normalizeCaseIfAbi graph0

        -- Phase 2: Closure staging invariant check
        graph2 =
            validateClosureStaging graph1

        -- Phase 3: Returned-closure arity annotation
        graph3 =
            annotateReturnedClosureArity graph2

        -- Phase 4: Inlining / DCE (optional)
        -- ( graph4, _ ) =
        --     MonoInlineSimplify.optimize mode typeEnv graph3
    in
    graph3
```

### Step 7: Update MLIR Backend Destructuring

**File**: `compiler/src/Compiler/Generate/MLIR/Backend.elm`

Update destructuring to include new field and convert from `Data.Map` to Elm `Dict`:

```elm
generateMlirModule : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> MlirModule
generateMlirModule mode typeEnv monoGraph0 =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes, returnedClosureParamCounts }) =
            monoGraph0

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
        ...
```

Note: `Backend.elm` already imports `Data.Map as EveryDict` and `Dict`, so no new imports needed.

### Step 8: Update Context.buildSignatures Signature

**File**: `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change signature to accept the precomputed map:
```elm
buildSignatures :
    EveryDict.Dict Int Int Mono.MonoNode
    -> Dict.Dict Int (Maybe Int)
    -> Dict.Dict Int FuncSignature
buildSignatures nodes returnedMap =
    EveryDict.foldl compare
        (\specId node acc ->
            case extractNodeSignature specId node returnedMap of
                Just sig ->
                    Dict.insert identity specId sig acc

                Nothing ->
                    acc
        )
        Dict.empty
        nodes
```

### Step 9: Update extractNodeSignature to Use Precomputed Map

```elm
extractNodeSignature :
    Int
    -> Mono.MonoNode
    -> Dict.Dict Int (Maybe Int)
    -> Maybe FuncSignature
extractNodeSignature specId node returnedMap =
    let
        returnedCountForThisNode =
            Dict.get specId returnedMap |> Maybe.withDefault Nothing
    in
    case node of
        Mono.MonoDefine expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        , callModel = StageCurried
                        , returnedClosureParamCount = returnedCountForThisNode
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , callModel = StageCurried
                        , returnedClosureParamCount = Nothing
                        }

        Mono.MonoTailFunc params _ monoType ->
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = returnType  -- derived from monoType
                , callModel = StageCurried
                , returnedClosureParamCount = Nothing
                }

        Mono.MonoCtor ctorShape monoType ->
            Just
                { paramTypes = ctorShape.fieldTypes
                , returnType = monoType
                , callModel = FlattenedExternal
                , returnedClosureParamCount = Nothing
                }

        Mono.MonoEnum _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                , callModel = FlattenedExternal
                , returnedClosureParamCount = Nothing
                }

        Mono.MonoExtern monoType ->
            case monoType of
                Mono.MFunction _ _ ->
                    Just
                        { paramTypes = argMonoTypes  -- derived from monoType
                        , returnType = resultMonoType
                        , callModel = FlattenedExternal
                        , returnedClosureParamCount = Nothing
                        }

                _ ->
                    Nothing

        Mono.MonoPortIncoming expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        , callModel = StageCurried
                        , returnedClosureParamCount = returnedCountForThisNode
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , callModel = StageCurried
                        , returnedClosureParamCount = Nothing
                        }

        Mono.MonoPortOutgoing expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        , callModel = StageCurried
                        , returnedClosureParamCount = returnedCountForThisNode
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , callModel = StageCurried
                        , returnedClosureParamCount = Nothing
                        }

        Mono.MonoCycle _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                , callModel = StageCurried
                , returnedClosureParamCount = Nothing
                }
```

Note: Only `MonoDefine`, `MonoPortIncoming`, and `MonoPortOutgoing` with `MonoClosure` use `returnedCountForThisNode`. All other cases keep `returnedClosureParamCount = Nothing` exactly as before.

### Step 10: Delete MLIR-local computeReturnedClosureParamCount

Remove from `Context.elm`:
- `computeReturnedClosureParamCount`
- `typeBasedArity`
- Any imports they required

### Step 11: Update Test Helpers

Grep for `Mono.MonoGraph {` or `= MonoGraph {` in `compiler/tests/` and update any test helpers that construct `MonoGraph` directly to include:
```elm
, returnedClosureParamCounts = Dict.empty
```

---

## File Changes Summary

| File | Change |
|------|--------|
| `compiler/src/Compiler/Optimize/MonoReturnArity.elm` | **NEW** - Type-based arity computation (~30 lines) |
| `compiler/src/Compiler/AST/Monomorphized.elm` | Add `returnedClosureParamCounts` field to MonoGraph |
| `compiler/src/Compiler/Generate/Monomorphize.elm` | Initialize new field as `Dict.empty` |
| `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm` | Thread new field through graph reconstruction |
| `compiler/src/Compiler/Optimize/MonoGlobalOptimize.elm` | Add `annotateReturnedClosureArity`, wire into pipeline |
| `compiler/src/Compiler/Generate/MLIR/Backend.elm` | Destructure `returnedClosureParamCounts`, pass to `buildSignatures` |
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Update `buildSignatures`/`extractNodeSignature` to use map; delete local analysis |
| `compiler/tests/**` | Update any test helpers that construct MonoGraph |

---

## Why This Works

### Relies on Normalized Types

- ABI normalization ensures `resultType` of case/if matches canonical segmentation
- `Mono.typeOf expr` for any expression returns the normalized type
- `Types.stageArity` on that type gives the correct per-stage arity
- This matches how `applyByStages` consumes `returnedClosureParamCount`

### Pulled Out of MLIR

- Analysis now lives in `Optimize/MonoReturnArity.elm` (Mono+Types only)
- `MonoGlobalOptimize.annotateReturnedClosureArity` computes once
- MLIR Context becomes a consumer, not a producer, of this information

### Behavior-Preserving

- Only annotates same node types as current MLIR logic
- `MonoTailFunc` and `MonoCycle` remain unannotated
- Stage-arity semantics match existing `applyByStages` fallback

---

## Testing Strategy

1. **Unit**: Verify `MonoReturnArity.computeReturnedClosureParamCount` returns correct values for:
   - Direct closures (validates MONO_016)
   - Expressions with function types (case/if results)
   - Non-function expressions (returns Nothing)

2. **Integration**: Existing E2E tests should pass with precomputed map

3. **Regression**: `cd compiler && npx elm-test-rs --fuzz 1`

4. **E2E**: `cmake --build build --target check`
