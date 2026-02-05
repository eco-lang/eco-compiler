# Plan: Introduce Mono.GlobalOptimize Phase

## Overview

This plan introduces a **Mono.GlobalOptimize** phase that runs after monomorphization but before MLIR codegen. It consolidates scattered staging/arity logic that currently lives in multiple places (Specialize.elm, Context.elm, Expr.elm) into a single, well-defined pass.

**Primary goal**: Fix the CGEN_052 violation where `remaining_arity=1` but `source PAP has remaining=2` in the `letSeparatedStaging` test case.

**Root cause**: The function's declared type has staging [1,1] (from `TypeSubst.applySubst`), but the case expression normalizes branches to canonical staging [2]. The MLIR codegen uses the type-derived staging when it should use the value-derived staging.

## Scope

### In scope
- Introduce `Mono.GlobalOptimize` as a late pass over the Mono graph
- **Move ABI wrapping entirely out of monomorphization** into this phase
- Move staging/ABI logic for `case` and `if` returns from monomorphization/MLIR into this phase
- Enforce closure stage-arity invariants (MONO_016) over the final Mono graph
- Run `MonoInlineSimplify` (inlining + DCE + let simplification) as part of this phase

### Out of scope (future work)
- Moving full lambda lifting out of codegen (design hooks provided but not full implementation)

---

## Key Design Decisions

### 1. LambdaId Generation Without MonoState

The critical challenge is that `buildAbiWrapper` currently depends on `MonoState` for `lambdaCounter` and `currentModule`. We solve this by following the pattern established in `MonoInlineSimplify`:

1. **GlobalCtx with its own lambdaCounter** - seeded from max lambda index in existing graph
2. **Get home module from SpecializationRegistry** - lookup via SpecId
3. **Pure wrapper functions** - `buildAbiWrapperGO` and `rewriteCaseLeavesToAbiGO`

### 2. Closure.elm Exports

Export `freshParams`, `extractRegion`, `buildNestedCalls` from `Compiler.Generate.Monomorphize.Closure` and reuse them in GlobalOptimize. These are small, pure utilities with well-defined behavior - duplicating them would be error-prone.

### 3. collectCaseLeafFunctions: Re-implement in GlobalOptimize

Re-implement `collectCaseLeafFunctions` as `collectCaseLeafFunctionsGO` inside `MonoGlobalOptimize` rather than importing from `Specialize.elm`. This avoids an awkward downward dependency from the late optimizer to a monomorphization module.

### 4. MonoIf ABI Normalization

Treat `MonoIf` identically to `MonoCase` with respect to function-typed branch results:
- Collect their function types
- Choose canonical segmentation
- Wrap mismatched branches using `buildAbiWrapperGO`
- Update `resultType` to the canonical type

### 5. MonoInlineSimplify Integration

Call `MonoInlineSimplify.optimize` as a black box - do NOT use internal functions like `rewriteExpr`, `simplifyLets`, `dce`. There is no `emptyCtx` export. The passes run in sequence:
1. `MonoGlobalOptimize.globalOptimize` (ABI normalization)
2. `MonoInlineSimplify.optimize` (inlining/DCE)

---

## Verified Type Information

### MonoExpr Constructors (Complete List)

From `Compiler.AST.Monomorphized`, pattern match all of these in `maxLambdaIndexInExpr` and `rewriteExprForAbi`:

```elm
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name MonoType
    | MonoUnit
    | MonoList Region (List MonoExpr) MonoType
    | MonoClosure ClosureInfo MonoExpr MonoType
    | MonoCall Region MonoExpr (List MonoExpr) MonoType
    | MonoTailCall Name (List ( Name, MonoExpr )) MonoType
    | MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
    | MonoLet MonoDef MonoExpr MonoType
    | MonoDestruct MonoDestructor MonoExpr MonoType
    | MonoCase Name MonoType (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
    | MonoRecordCreate (List MonoExpr) MonoType
    | MonoRecordAccess MonoExpr Name Int Bool MonoType
    | MonoRecordUpdate MonoExpr (List ( Int, MonoExpr )) MonoType
    | MonoTupleCreate Region (List MonoExpr) MonoType
```

Use `computeCost` and `collectCalls` in `MonoInlineSimplify` as templates for traversal.

### LambdaId (Single Variant)

```elm
type LambdaId
    = AnonymousLambda IO.Canonical Int
```

No `NamedLambda` or other variants exist today.

### ClosureInfo (Exact Fields)

```elm
type alias ClosureInfo =
    { lambdaId : LambdaId
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    }
```

### Types.Segmentation

```elm
type alias Segmentation = List Int
```

Exported from `Compiler.Generate.MLIR.Types` along with `buildSegmentedFunctionType`, `chooseCanonicalSegmentation`, `segmentLengths`, `stageParamTypes`, `stageReturnType`.

### Dict API

Always use `compare` as first argument:
```elm
Dict.foldl compare (\key value acc -> ...) initialAcc dict
Dict.get identity key dict
Dict.insert identity key value dict
```

---

## Implementation Steps

### Step 1: Export Helpers from Closure.elm

**File**: `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

Change the module header from:
```elm
module Compiler.Generate.Monomorphize.Closure exposing
    ( ensureCallableTopLevel
    , computeClosureCaptures
    , buildAbiWrapper
    )
```

to:
```elm
module Compiler.Generate.Monomorphize.Closure exposing
    ( ensureCallableTopLevel
    , computeClosureCaptures
    , buildAbiWrapper
    , freshParams
    , extractRegion
    , buildNestedCalls
    )
```

No internal code changes needed.

### Step 2: Create GlobalOptimize Module

**File**: `compiler/src/Compiler/Optimize/MonoGlobalOptimize.elm`

```elm
module Compiler.Optimize.MonoGlobalOptimize exposing (globalOptimize)

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name exposing (Name)
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Mode as Mode
import Compiler.Generate.Monomorphize.Closure as Closure
import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify
import Data.Map as Dict exposing (Dict)
import Reporting.Annotation as A
import System.TypeCheck.IO as IO


-- Internal context for the pass
type alias GlobalCtx =
    { registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    }


globalOptimize : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
globalOptimize mode typeEnv graph0 =
    let
        -- Phase 1: ABI normalization (case/if result types, wrapper generation)
        graph1 =
            normalizeCaseIfAbi graph0

        -- Phase 2: Closure staging invariant check
        graph2 =
            validateClosureStaging graph1

        -- Phase 3: Inlining and DCE (call as black box)
        graph3 =
            MonoInlineSimplify.optimize mode typeEnv graph2
    in
    graph3
```

### Step 3: Implement Lambda Index Scanning

```elm
initGlobalCtx : Mono.MonoGraph -> GlobalCtx
initGlobalCtx (Mono.MonoGraph record) =
    { registry = record.registry
    , lambdaCounter = maxLambdaIndexInGraph (Mono.MonoGraph record) + 1
    }


freshLambdaId : IO.Canonical -> GlobalCtx -> ( Mono.LambdaId, GlobalCtx )
freshLambdaId home ctx =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )


maxLambdaIndexInGraph : Mono.MonoGraph -> Int
maxLambdaIndexInGraph (Mono.MonoGraph { nodes }) =
    Dict.foldl compare
        (\_ node acc -> max acc (maxLambdaIndexInNode node))
        0
        nodes


maxLambdaIndexInNode : Mono.MonoNode -> Int
maxLambdaIndexInNode node =
    case node of
        Mono.MonoDefine expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoTailFunc _ expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoPortIncoming expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoPortOutgoing expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoCycle defs _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 defs

        Mono.MonoCtor _ _ _ ->
            0

        Mono.MonoEnum _ _ ->
            0

        Mono.MonoExtern _ ->
            0


maxLambdaIndexInExpr : Mono.MonoExpr -> Int
maxLambdaIndexInExpr expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            0

        Mono.MonoVarLocal _ _ ->
            0

        Mono.MonoVarGlobal _ _ _ ->
            0

        Mono.MonoVarKernel _ _ _ _ ->
            0

        Mono.MonoUnit ->
            0

        Mono.MonoList _ items _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 items

        Mono.MonoClosure info body _ ->
            let
                idx =
                    case info.lambdaId of
                        Mono.AnonymousLambda _ i ->
                            i
            in
            max idx (maxLambdaIndexInExpr body)

        Mono.MonoCall _ f args _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e))
                (maxLambdaIndexInExpr f)
                args

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 args

        Mono.MonoIf branches final _ ->
            let
                branchMax =
                    List.foldl
                        (\( cond, then_ ) acc ->
                            max acc (max (maxLambdaIndexInExpr cond) (maxLambdaIndexInExpr then_))
                        )
                        0
                        branches
            in
            max branchMax (maxLambdaIndexInExpr final)

        Mono.MonoLet def body _ ->
            max (maxLambdaIndexInDef def) (maxLambdaIndexInExpr body)

        Mono.MonoDestruct _ inner _ ->
            maxLambdaIndexInExpr inner

        Mono.MonoCase _ _ decider branches _ ->
            let
                decMax =
                    maxLambdaIndexInDecider decider

                branchMax =
                    List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 branches
            in
            max decMax branchMax

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 fields

        Mono.MonoRecordAccess inner _ _ _ _ ->
            maxLambdaIndexInExpr inner

        Mono.MonoRecordUpdate record updates _ ->
            let
                recMax =
                    maxLambdaIndexInExpr record

                updMax =
                    List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 updates
            in
            max recMax updMax

        Mono.MonoTupleCreate _ elements _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 elements


maxLambdaIndexInDef : Mono.MonoDef -> Int
maxLambdaIndexInDef def =
    case def of
        Mono.MonoDef _ bound ->
            maxLambdaIndexInExpr bound

        Mono.MonoTailDef _ _ bound ->
            maxLambdaIndexInExpr bound


maxLambdaIndexInDecider : Mono.Decider Mono.MonoChoice -> Int
maxLambdaIndexInDecider dec =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    maxLambdaIndexInExpr expr

                Mono.Jump _ ->
                    0

        Mono.Chain _ success failure ->
            max (maxLambdaIndexInDecider success) (maxLambdaIndexInDecider failure)

        Mono.FanOut _ edges fallback ->
            let
                edgeMax =
                    List.foldl (\( _, d ) acc -> max acc (maxLambdaIndexInDecider d)) 0 edges
            in
            max edgeMax (maxLambdaIndexInDecider fallback)
```

### Step 4: Implement specHome

```elm
specHome : Mono.SpecializationRegistry -> Int -> IO.Canonical
specHome registry specId =
    case Dict.get identity specId registry.reverseMapping of
        Just ( global, _, _ ) ->
            case global of
                Mono.Global home _ ->
                    home

                Mono.Accessor _ ->
                    IO.Canonical ( "eco", "accessor" ) "Accessor"

        Nothing ->
            IO.Canonical ( "eco", "global-optimize" ) "GlobalOptimize"
```

### Step 5: Implement collectCaseLeafFunctionsGO

```elm
collectCaseLeafFunctionsGO :
    Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> List Mono.MonoType
collectCaseLeafFunctionsGO monoDecider monoJumps =
    let
        jumpDict =
            Dict.fromList identity monoJumps

        collectFromDecider : Mono.Decider Mono.MonoChoice -> List Mono.MonoType -> List Mono.MonoType
        collectFromDecider dec acc =
            case dec of
                Mono.Leaf choice ->
                    case choice of
                        Mono.Inline expr ->
                            case Mono.typeOf expr of
                                Mono.MFunction _ _ ->
                                    Mono.typeOf expr :: acc

                                _ ->
                                    acc

                        Mono.Jump idx ->
                            case Dict.get identity idx jumpDict of
                                Just jumpExpr ->
                                    case Mono.typeOf jumpExpr of
                                        Mono.MFunction _ _ ->
                                            Mono.typeOf jumpExpr :: acc

                                        _ ->
                                            acc

                                Nothing ->
                                    acc

                Mono.Chain _ success failure ->
                    collectFromDecider success (collectFromDecider failure acc)

                Mono.FanOut _ edges fallback ->
                    let
                        accAfterEdges =
                            List.foldl (\( _, d ) a -> collectFromDecider d a) acc edges
                    in
                    collectFromDecider fallback accAfterEdges
    in
    collectFromDecider monoDecider []
```

### Step 6: Implement buildAbiWrapperGO

```elm
buildAbiWrapperGO :
    IO.Canonical
    -> Mono.MonoType
    -> Mono.MonoExpr
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
buildAbiWrapperGO home targetType calleeExpr ctx0 =
    let
        srcType =
            Mono.typeOf calleeExpr

        targetSeg =
            Types.segmentLengths targetType

        srcSeg =
            Types.segmentLengths srcType
    in
    if targetSeg == srcSeg then
        ( calleeExpr, ctx0 )

    else
        let
            region =
                Closure.extractRegion calleeExpr

            buildStages :
                Mono.MonoType
                -> List ( Name, Mono.MonoType )
                -> GlobalCtx
                -> ( Mono.MonoExpr, GlobalCtx )
            buildStages remainingType accParams ctx =
                let
                    stageArgTypes =
                        Types.stageParamTypes remainingType

                    stageRetType =
                        Types.stageReturnType remainingType
                in
                case stageArgTypes of
                    [] ->
                        ( Closure.buildNestedCalls region calleeExpr accParams, ctx )

                    _ ->
                        let
                            paramsForStage =
                                Closure.freshParams stageArgTypes

                            newAccParams =
                                accParams ++ paramsForStage

                            ( innerBody, ctx1 ) =
                                buildStages stageRetType newAccParams ctx

                            captures =
                                Closure.computeClosureCaptures paramsForStage innerBody

                            ( lambdaId, ctx2 ) =
                                freshLambdaId home ctx1

                            closureInfo =
                                { lambdaId = lambdaId
                                , captures = captures
                                , params = paramsForStage
                                }
                        in
                        ( Mono.MonoClosure closureInfo innerBody remainingType, ctx2 )
        in
        buildStages targetType [] ctx0
```

### Step 7: Implement rewriteExprForAbi (Complete Traversal)

```elm
rewriteExprForAbi : IO.Canonical -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
rewriteExprForAbi home expr ctx =
    case expr of
        -- ABI normalization targets
        Mono.MonoCase scrutName scrutType decider branches resultType ->
            rewriteCaseForAbi home scrutName scrutType decider branches resultType ctx

        Mono.MonoIf branches final resultType ->
            rewriteIfForAbi home branches final resultType ctx

        -- Structural recursion (no lambdas in these)
        Mono.MonoLiteral _ _ ->
            ( expr, ctx )

        Mono.MonoVarLocal _ _ ->
            ( expr, ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        Mono.MonoVarKernel _ _ _ _ ->
            ( expr, ctx )

        Mono.MonoUnit ->
            ( expr, ctx )

        -- Structural recursion (may contain lambdas)
        Mono.MonoList region items tipe ->
            let
                ( newItems, ctx1 ) =
                    List.foldr
                        (\item ( acc, accCtx ) ->
                            let
                                ( newItem, accCtx1 ) =
                                    rewriteExprForAbi home item accCtx
                            in
                            ( newItem :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        items
            in
            ( Mono.MonoList region newItems tipe, ctx1 )

        Mono.MonoClosure info body tipe ->
            let
                ( newBody, ctx1 ) =
                    rewriteExprForAbi home body ctx
            in
            ( Mono.MonoClosure info newBody tipe, ctx1 )

        Mono.MonoCall region f args tipe ->
            let
                ( newF, ctx1 ) =
                    rewriteExprForAbi home f ctx

                ( newArgs, ctx2 ) =
                    List.foldr
                        (\arg ( acc, accCtx ) ->
                            let
                                ( newArg, accCtx1 ) =
                                    rewriteExprForAbi home arg accCtx
                            in
                            ( newArg :: acc, accCtx1 )
                        )
                        ( [], ctx1 )
                        args
            in
            ( Mono.MonoCall region newF newArgs tipe, ctx2 )

        Mono.MonoTailCall name args tipe ->
            let
                ( newArgs, ctx1 ) =
                    List.foldr
                        (\( n, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        args
            in
            ( Mono.MonoTailCall name newArgs tipe, ctx1 )

        Mono.MonoLet def body tipe ->
            let
                ( newDef, ctx1 ) =
                    rewriteDefForAbi home def ctx

                ( newBody, ctx2 ) =
                    rewriteExprForAbi home body ctx1
            in
            ( Mono.MonoLet newDef newBody tipe, ctx2 )

        Mono.MonoDestruct destructor inner tipe ->
            let
                ( newInner, ctx1 ) =
                    rewriteExprForAbi home inner ctx
            in
            ( Mono.MonoDestruct destructor newInner tipe, ctx1 )

        Mono.MonoRecordCreate fields tipe ->
            let
                ( newFields, ctx1 ) =
                    List.foldr
                        (\field ( acc, accCtx ) ->
                            let
                                ( newField, accCtx1 ) =
                                    rewriteExprForAbi home field accCtx
                            in
                            ( newField :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( Mono.MonoRecordCreate newFields tipe, ctx1 )

        Mono.MonoRecordAccess inner name idx unboxed tipe ->
            let
                ( newInner, ctx1 ) =
                    rewriteExprForAbi home inner ctx
            in
            ( Mono.MonoRecordAccess newInner name idx unboxed tipe, ctx1 )

        Mono.MonoRecordUpdate record updates tipe ->
            let
                ( newRecord, ctx1 ) =
                    rewriteExprForAbi home record ctx

                ( newUpdates, ctx2 ) =
                    List.foldr
                        (\( idx, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( idx, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( Mono.MonoRecordUpdate newRecord newUpdates tipe, ctx2 )

        Mono.MonoTupleCreate region elements tipe ->
            let
                ( newElements, ctx1 ) =
                    List.foldr
                        (\elem ( acc, accCtx ) ->
                            let
                                ( newElem, accCtx1 ) =
                                    rewriteExprForAbi home elem accCtx
                            in
                            ( newElem :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        elements
            in
            ( Mono.MonoTupleCreate region newElements tipe, ctx1 )


rewriteDefForAbi : IO.Canonical -> Mono.MonoDef -> GlobalCtx -> ( Mono.MonoDef, GlobalCtx )
rewriteDefForAbi home def ctx =
    case def of
        Mono.MonoDef name bound ->
            let
                ( newBound, ctx1 ) =
                    rewriteExprForAbi home bound ctx
            in
            ( Mono.MonoDef name newBound, ctx1 )

        Mono.MonoTailDef name params bound ->
            let
                ( newBound, ctx1 ) =
                    rewriteExprForAbi home bound ctx
            in
            ( Mono.MonoTailDef name params newBound, ctx1 )
```

### Step 8: Implement rewriteCaseForAbi

```elm
rewriteCaseForAbi :
    IO.Canonical
    -> Name
    -> Mono.MonoType
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
rewriteCaseForAbi home scrutName scrutType decider branches resultType ctx0 =
    let
        leafTypes =
            collectCaseLeafFunctionsGO decider branches
    in
    case leafTypes of
        [] ->
            -- No function leaves, just recurse into components
            let
                ( newDecider, ctx1 ) =
                    rewriteDeciderForAbi home decider ctx0

                ( newBranches, ctx2 ) =
                    rewriteBranchesForAbi home branches ctx1
            in
            ( Mono.MonoCase scrutName scrutType newDecider newBranches resultType, ctx2 )

        _ ->
            -- Function leaves: normalize to canonical ABI
            let
                ( canonicalSeg, flatArgs, flatRet ) =
                    Types.chooseCanonicalSegmentation leafTypes

                canonicalType =
                    Types.buildSegmentedFunctionType flatArgs flatRet canonicalSeg

                ( newDecider, newBranches, ctx1 ) =
                    rewriteCaseLeavesToAbiGO home canonicalType canonicalSeg decider branches ctx0
            in
            ( Mono.MonoCase scrutName scrutType newDecider newBranches canonicalType, ctx1 )


rewriteCaseLeavesToAbiGO :
    IO.Canonical
    -> Mono.MonoType
    -> Types.Segmentation
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> GlobalCtx
    -> ( Mono.Decider Mono.MonoChoice, List ( Int, Mono.MonoExpr ), GlobalCtx )
rewriteCaseLeavesToAbiGO home targetType targetSeg decider jumps ctx0 =
    let
        rewriteLeafExpr : Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
        rewriteLeafExpr expr ctx =
            case Mono.typeOf expr of
                Mono.MFunction _ _ ->
                    if Types.segmentLengths (Mono.typeOf expr) == targetSeg then
                        ( expr, ctx )

                    else
                        buildAbiWrapperGO home targetType expr ctx

                _ ->
                    ( expr, ctx )

        rewriteDecider : Mono.Decider Mono.MonoChoice -> GlobalCtx -> ( Mono.Decider Mono.MonoChoice, GlobalCtx )
        rewriteDecider dec ctx =
            case dec of
                Mono.Leaf choice ->
                    case choice of
                        Mono.Inline expr ->
                            let
                                ( newExpr, ctx1 ) =
                                    rewriteLeafExpr expr ctx
                            in
                            ( Mono.Leaf (Mono.Inline newExpr), ctx1 )

                        Mono.Jump _ ->
                            ( dec, ctx )

                Mono.Chain testChain success failure ->
                    let
                        ( newSuccess, ctx1 ) =
                            rewriteDecider success ctx

                        ( newFailure, ctx2 ) =
                            rewriteDecider failure ctx1
                    in
                    ( Mono.Chain testChain newSuccess newFailure, ctx2 )

                Mono.FanOut path edges fallback ->
                    let
                        ( newEdges, ctx1 ) =
                            List.foldr
                                (\( test, d ) ( acc, accCtx ) ->
                                    let
                                        ( newD, accCtx1 ) =
                                            rewriteDecider d accCtx
                                    in
                                    ( ( test, newD ) :: acc, accCtx1 )
                                )
                                ( [], ctx )
                                edges

                        ( newFallback, ctx2 ) =
                            rewriteDecider fallback ctx1
                    in
                    ( Mono.FanOut path newEdges newFallback, ctx2 )

        rewriteJumps : List ( Int, Mono.MonoExpr ) -> GlobalCtx -> ( List ( Int, Mono.MonoExpr ), GlobalCtx )
        rewriteJumps js ctx =
            List.foldr
                (\( idx, expr ) ( acc, accCtx ) ->
                    let
                        ( newExpr, accCtx1 ) =
                            rewriteLeafExpr expr accCtx
                    in
                    ( ( idx, newExpr ) :: acc, accCtx1 )
                )
                ( [], ctx )
                js

        ( newDecider, ctx1 ) =
            rewriteDecider decider ctx0

        ( newJumps, ctx2 ) =
            rewriteJumps jumps ctx1
    in
    ( newDecider, newJumps, ctx2 )


rewriteDeciderForAbi :
    IO.Canonical
    -> Mono.Decider Mono.MonoChoice
    -> GlobalCtx
    -> ( Mono.Decider Mono.MonoChoice, GlobalCtx )
rewriteDeciderForAbi home dec ctx =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( newExpr, ctx1 ) =
                            rewriteExprForAbi home expr ctx
                    in
                    ( Mono.Leaf (Mono.Inline newExpr), ctx1 )

                Mono.Jump _ ->
                    ( dec, ctx )

        Mono.Chain testChain success failure ->
            let
                ( newSuccess, ctx1 ) =
                    rewriteDeciderForAbi home success ctx

                ( newFailure, ctx2 ) =
                    rewriteDeciderForAbi home failure ctx1
            in
            ( Mono.Chain testChain newSuccess newFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( newEdges, ctx1 ) =
                    List.foldr
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( newD, accCtx1 ) =
                                    rewriteDeciderForAbi home d accCtx
                            in
                            ( ( test, newD ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        edges

                ( newFallback, ctx2 ) =
                    rewriteDeciderForAbi home fallback ctx1
            in
            ( Mono.FanOut path newEdges newFallback, ctx2 )


rewriteBranchesForAbi :
    IO.Canonical
    -> List ( Int, Mono.MonoExpr )
    -> GlobalCtx
    -> ( List ( Int, Mono.MonoExpr ), GlobalCtx )
rewriteBranchesForAbi home branches ctx =
    List.foldr
        (\( idx, expr ) ( acc, accCtx ) ->
            let
                ( newExpr, accCtx1 ) =
                    rewriteExprForAbi home expr accCtx
            in
            ( ( idx, newExpr ) :: acc, accCtx1 )
        )
        ( [], ctx )
        branches
```

### Step 9: Implement rewriteIfForAbi

```elm
rewriteIfForAbi :
    IO.Canonical
    -> List ( Mono.MonoExpr, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
rewriteIfForAbi home branches final resultType ctx0 =
    let
        branchResults : List Mono.MonoExpr
        branchResults =
            List.map Tuple.second branches ++ [ final ]

        leafTypes : List Mono.MonoType
        leafTypes =
            branchResults
                |> List.filterMap
                    (\e ->
                        case Mono.typeOf e of
                            Mono.MFunction _ _ ->
                                Just (Mono.typeOf e)

                            _ ->
                                Nothing
                    )
    in
    case leafTypes of
        [] ->
            -- No function leaves, just recurse structurally
            let
                ( newBranches, ctx1 ) =
                    List.foldr
                        (\( cond, then_ ) ( acc, accCtx ) ->
                            let
                                ( newCond, accCtx1 ) =
                                    rewriteExprForAbi home cond accCtx

                                ( newThen, accCtx2 ) =
                                    rewriteExprForAbi home then_ accCtx1
                            in
                            ( ( newCond, newThen ) :: acc, accCtx2 )
                        )
                        ( [], ctx0 )
                        branches

                ( newFinal, ctx2 ) =
                    rewriteExprForAbi home final ctx1
            in
            ( Mono.MonoIf newBranches newFinal resultType, ctx2 )

        _ ->
            -- Function leaves: normalize to canonical ABI
            let
                ( canonicalSeg, flatArgs, flatRet ) =
                    Types.chooseCanonicalSegmentation leafTypes

                canonicalType =
                    Types.buildSegmentedFunctionType flatArgs flatRet canonicalSeg

                rewriteResultExpr : Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
                rewriteResultExpr expr ctx =
                    case Mono.typeOf expr of
                        Mono.MFunction _ _ ->
                            if Types.segmentLengths (Mono.typeOf expr) == canonicalSeg then
                                rewriteExprForAbi home expr ctx

                            else
                                buildAbiWrapperGO home canonicalType expr ctx

                        _ ->
                            rewriteExprForAbi home expr ctx

                ( newBranches, ctx1 ) =
                    List.foldr
                        (\( cond, then_ ) ( acc, accCtx ) ->
                            let
                                ( newCond, accCtx1 ) =
                                    rewriteExprForAbi home cond accCtx

                                ( newThen, accCtx2 ) =
                                    rewriteResultExpr then_ accCtx1
                            in
                            ( ( newCond, newThen ) :: acc, accCtx2 )
                        )
                        ( [], ctx0 )
                        branches

                ( newFinal, ctx2 ) =
                    rewriteResultExpr final ctx1
            in
            ( Mono.MonoIf newBranches newFinal canonicalType, ctx2 )
```

### Step 10: Implement normalizeCaseIfAbi (Graph-Level)

```elm
normalizeCaseIfAbi : Mono.MonoGraph -> Mono.MonoGraph
normalizeCaseIfAbi (Mono.MonoGraph record0) =
    let
        ctx0 =
            initGlobalCtx (Mono.MonoGraph record0)

        ( newNodes, _ ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) ->
                    let
                        home =
                            specHome accCtx.registry specId

                        ( newNode, accCtx1 ) =
                            rewriteNodeForAbi home node accCtx
                    in
                    ( Dict.insert identity specId newNode accNodes, accCtx1 )
                )
                ( Dict.empty, ctx0 )
                record0.nodes
    in
    Mono.MonoGraph { record0 | nodes = newNodes }


rewriteNodeForAbi : IO.Canonical -> Mono.MonoNode -> GlobalCtx -> ( Mono.MonoNode, GlobalCtx )
rewriteNodeForAbi home node ctx =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExprForAbi home expr ctx
            in
            ( Mono.MonoDefine newExpr tipe, ctx1 )

        Mono.MonoTailFunc params body tipe ->
            let
                ( newBody, ctx1 ) =
                    rewriteExprForAbi home body ctx
            in
            ( Mono.MonoTailFunc params newBody tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExprForAbi home expr ctx
            in
            ( Mono.MonoPortIncoming newExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExprForAbi home expr ctx
            in
            ( Mono.MonoPortOutgoing newExpr tipe, ctx1 )

        Mono.MonoCycle defs tipe ->
            let
                ( newDefs, ctx1 ) =
                    List.foldr
                        (\( n, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        defs
            in
            ( Mono.MonoCycle newDefs tipe, ctx1 )

        Mono.MonoCtor _ _ _ ->
            ( node, ctx )

        Mono.MonoEnum _ _ ->
            ( node, ctx )

        Mono.MonoExtern _ ->
            ( node, ctx )
```

### Step 11: Implement validateClosureStaging

```elm
validateClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
validateClosureStaging (Mono.MonoGraph record) =
    let
        _ =
            Dict.foldl compare
                (\_ node () -> validateNodeClosures node)
                ()
                record.nodes
    in
    Mono.MonoGraph record


validateNodeClosures : Mono.MonoNode -> ()
validateNodeClosures node =
    case node of
        Mono.MonoDefine expr _ ->
            validateExprClosures expr

        Mono.MonoTailFunc _ body _ ->
            validateExprClosures body

        Mono.MonoPortIncoming expr _ ->
            validateExprClosures expr

        Mono.MonoPortOutgoing expr _ ->
            validateExprClosures expr

        Mono.MonoCycle defs _ ->
            List.foldl (\( _, e ) () -> validateExprClosures e) () defs

        _ ->
            ()


validateExprClosures : Mono.MonoExpr -> ()
validateExprClosures expr =
    case expr of
        Mono.MonoClosure info body tipe ->
            let
                expectedParams =
                    Types.stageParamTypes tipe

                actualParams =
                    info.params

                _ =
                    if List.length actualParams /= List.length expectedParams then
                        Debug.todo
                            ("MONO_016 violation: closure has "
                                ++ String.fromInt (List.length actualParams)
                                ++ " params but type expects "
                                ++ String.fromInt (List.length expectedParams)
                            )

                    else
                        ()
            in
            validateExprClosures body

        -- Recurse into all other forms (abbreviated - same pattern as maxLambdaIndexInExpr)
        Mono.MonoCall _ f args _ ->
            let
                _ = validateExprClosures f
            in
            List.foldl (\e () -> validateExprClosures e) () args

        Mono.MonoLet def body _ ->
            let
                _ = validateDefClosures def
            in
            validateExprClosures body

        Mono.MonoCase _ _ decider branches _ ->
            let
                _ = validateDeciderClosures decider
            in
            List.foldl (\( _, e ) () -> validateExprClosures e) () branches

        Mono.MonoIf branches final _ ->
            let
                _ = List.foldl (\( c, t ) () ->
                        let _ = validateExprClosures c
                        in validateExprClosures t
                    ) () branches
            in
            validateExprClosures final

        -- ... other cases recurse similarly
        _ ->
            ()


validateDefClosures : Mono.MonoDef -> ()
validateDefClosures def =
    case def of
        Mono.MonoDef _ bound ->
            validateExprClosures bound

        Mono.MonoTailDef _ _ bound ->
            validateExprClosures bound


validateDeciderClosures : Mono.Decider Mono.MonoChoice -> ()
validateDeciderClosures dec =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    validateExprClosures expr

                Mono.Jump _ ->
                    ()

        Mono.Chain _ success failure ->
            let
                _ = validateDeciderClosures success
            in
            validateDeciderClosures failure

        Mono.FanOut _ edges fallback ->
            let
                _ = List.foldl (\( _, d ) () -> validateDeciderClosures d) () edges
            in
            validateDeciderClosures fallback
```

### Step 12: Remove ABI Normalization from Specialize.elm

**File**: `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Remove** these functions (they become dead code):
- `collectCaseLeafFunctions`
- `rewriteCaseLeavesToAbi`

**Simplify** the `TOpt.Case` branch in `specializeExpr` to:

```elm
TOpt.Case label root decider jumps canType ->
    let
        monoTypeFromCan =
            TypeSubst.applySubst subst canType

        initialVarTypes =
            state.varTypes

        ( monoDecider0, state1 ) =
            specializeDecider decider subst state

        state1WithResetVarTypes =
            { state1 | varTypes = initialVarTypes }

        ( monoJumps0, state2 ) =
            specializeJumps jumps subst state1WithResetVarTypes
    in
    ( Mono.MonoCase label root monoDecider0 monoJumps0 monoTypeFromCan, state2 )
```

No call to `rewriteCaseLeavesToAbi`, no `collectCaseLeafFunctions`, no segmentation logic.

### Step 13: Wire GlobalOptimize into Pipeline

**File**: `compiler/src/Builder/Generate.elm`

Add import:
```elm
import Compiler.Optimize.MonoGlobalOptimize as MonoGlobalOptimize
```

Change from:
```elm
case Monomorphize.monomorphize "main" globalTypeEnv typedGraph of
    Err err ->
        Task.throw (Exit.GenerateMonomorphizationError err)

    Ok monoGraph ->
        prepareSourceMaps withSourceMaps root
            |> Task.map (generateMonoOutput backend leadingLines mode monoGraph globalTypeEnv)
```

To:
```elm
case Monomorphize.monomorphize "main" globalTypeEnv typedGraph of
    Err err ->
        Task.throw (Exit.GenerateMonomorphizationError err)

    Ok monoGraph0 ->
        let
            monoGraph =
                MonoGlobalOptimize.globalOptimize mode globalTypeEnv monoGraph0
        in
        prepareSourceMaps withSourceMaps root
            |> Task.map (generateMonoOutput backend leadingLines mode monoGraph globalTypeEnv)
```

---

## File Changes Summary

| File | Change |
|------|--------|
| `compiler/src/Compiler/Optimize/MonoGlobalOptimize.elm` | **NEW** - ~500 lines: GlobalCtx, ABI normalization for case/if, staging validation, MonoInlineSimplify integration |
| `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Export 3 functions: `freshParams`, `extractRegion`, `buildNestedCalls` |
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Remove `collectCaseLeafFunctions`, `rewriteCaseLeavesToAbi`, simplify TOpt.Case branch |
| `compiler/src/Builder/Generate.elm` | Add import, wire `MonoGlobalOptimize.globalOptimize` after monomorphization |

---

## Logic Move Summary

| Concern | Old Location | New Location |
|---------|--------------|--------------|
| ABI wrapper generation | `Closure.buildAbiWrapper` (MonoState) | `MonoGlobalOptimize.buildAbiWrapperGO` (GlobalCtx) |
| Case ABI normalization | `Specialize.rewriteCaseLeavesToAbi` | `MonoGlobalOptimize.rewriteCaseForAbi` |
| If ABI normalization | (not handled) | `MonoGlobalOptimize.rewriteIfForAbi` |
| LambdaId generation | `MonoState.lambdaCounter` | `GlobalCtx.lambdaCounter` (seeded) |
| Home module lookup | `MonoState.currentModule` | `specHome registry specId` |
| Leaf function collection | `Specialize.collectCaseLeafFunctions` | `MonoGlobalOptimize.collectCaseLeafFunctionsGO` |
| Staging validation | `Specialize.specializeLambda` assertion | `MonoGlobalOptimize.validateClosureStaging` |
| Inlining/DCE | Separate `MonoInlineSimplify.optimize` | Called from `MonoGlobalOptimize.globalOptimize` |

---

## Pass Ordering

```
Monomorphize.monomorphize
    ↓
MonoGlobalOptimize.globalOptimize
    ├── normalizeCaseIfAbi      (ABI wrappers, canonical types)
    ├── validateClosureStaging  (MONO_016 check)
    └── MonoInlineSimplify.optimize  (inlining, DCE)
    ↓
generateMonoOutput (MLIR codegen)
```

---

## Testing Strategy

1. **CGEN_052 test**: `PapExtend remaining_arity calculation` should pass
2. **Specific case**: `4.4 letSeparatedStaging` in JoinpointABICases should work
3. **Regression**: `cd compiler && npx elm-test-rs --fuzz 1`
4. **E2E**: `TEST_FILTER=elm-core cmake --build build --target check`

---

## Why This Fixes CGEN_052

**Before**: Function type from `TypeSubst.applySubst` has staging [1,1,1,1]. Case normalizes branches to [2] but `resultType` still says [1,1]. MLIR's `applyByStages` falls back to `stageArity stageRetType` → 1, not 2.

**After**: `normalizeCaseIfAbi` rewrites the `MonoCase` so `resultType` is the canonical type with staging [2]. MLIR gets correct staging directly from the normalized result type.
