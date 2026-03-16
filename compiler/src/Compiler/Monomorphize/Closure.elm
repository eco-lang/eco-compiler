module Compiler.Monomorphize.Closure exposing
    ( freshParams, extractRegion
    , computeClosureCaptures, findFreeLocals
    , flattenFunctionType
    )

{-| Closure utilities for monomorphization and GlobalOpt.

This module provides staging-neutral utilities for working with closures:

  - Computing closure captures (free variables)
  - Generating fresh parameter names
  - Extracting source regions from expressions
  - Flattening curried function types

Note: Staging-aware wrapper creation (ensureCallableTopLevel, buildNestedCalls)
has been moved to GlobalOpt.MonoGlobalOptimize as part of the staging consolidation.


# Parameters and Regions

@docs freshParams, extractRegion


# Free Variable Analysis

@docs computeClosureCaptures, findFreeLocals


# Type Utilities

@docs flattenFunctionType

-}

import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Utils.Crash



-- ========== TYPE UTILITIES ==========


{-| Flatten a curried function type into a list of argument types and a final return type.
-}
flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunctionType monoType =
    case monoType of
        Mono.MFunction args ret ->
            let
                ( moreArgs, finalRet ) =
                    flattenFunctionType ret
            in
            ( args ++ moreArgs, finalRet )

        _ ->
            ( [], monoType )



-- ========== PARAMETERS AND REGIONS ==========


{-| Generate fresh parameter names for a list of types.
-}
freshParams : List Mono.MonoType -> List ( Name, Mono.MonoType )
freshParams argTypes =
    List.indexedMap
        (\i ty -> ( "arg" ++ String.fromInt i, ty ))
        argTypes


{-| Extract the source region from a monomorphic expression.
-}
extractRegion : Mono.MonoExpr -> A.Region
extractRegion expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            A.zero

        Mono.MonoVarLocal _ _ ->
            A.zero

        Mono.MonoVarGlobal region _ _ ->
            region

        Mono.MonoVarKernel region _ _ _ ->
            region

        Mono.MonoList region _ _ ->
            region

        Mono.MonoClosure _ _ _ ->
            A.zero

        Mono.MonoCall region _ _ _ _ ->
            region

        Mono.MonoTailCall _ _ _ ->
            A.zero

        Mono.MonoIf _ _ _ ->
            A.zero

        Mono.MonoLet _ _ _ ->
            A.zero

        Mono.MonoDestruct _ _ _ ->
            A.zero

        Mono.MonoCase _ _ _ _ _ ->
            A.zero

        Mono.MonoRecordCreate _ _ ->
            A.zero

        Mono.MonoRecordAccess record _ _ ->
            extractRegion record

        Mono.MonoRecordUpdate record _ _ ->
            extractRegion record

        Mono.MonoTupleCreate region _ _ ->
            region

        Mono.MonoUnit ->
            A.zero



-- ========== CLOSURE CAPTURE ANALYSIS ==========


{-| Compute the free variables that need to be captured by a closure.
-}
computeClosureCaptures :
    List ( Name, Mono.MonoType )
    -> Mono.MonoExpr
    -> List ( Name, Mono.MonoExpr, Bool )
computeClosureCaptures params body =
    let
        boundInitial : EverySet String Name
        boundInitial =
            List.foldl
                (\( name, _ ) acc -> EverySet.insert identity name acc)
                EverySet.empty
                params

        freeNames : List Name
        freeNames =
            findFreeLocals boundInitial body
                |> dedupeNames

        -- Collect a mapping from variable names to their actual types from the body.
        -- This allows us to use the correct type for each captured variable instead
        -- of a placeholder MUnit.
        varTypeMap : Dict String Mono.MonoType
        varTypeMap =
            collectVarTypes body

        -- Collect types for MonoCase root variables that don't appear as MonoVarLocal
        -- in the body. The root variable's type is inferred from the decider tests.
        caseRootTypeMap : Dict String Mono.MonoType
        caseRootTypeMap =
            collectCaseRootTypes body

        captureFor name =
            case Dict.get name varTypeMap of
                Just actualType ->
                    ( name, Mono.MonoVarLocal name actualType, False )

                Nothing ->
                    case Dict.get name caseRootTypeMap of
                        Just rootType ->
                            ( name, Mono.MonoVarLocal name rootType, False )

                        Nothing ->
                            Utils.Crash.crash
                                ("computeClosureCaptures: missing type for captured var `"
                                    ++ name
                                    ++ "`; this violates Mono typing invariants"
                                )
    in
    List.map captureFor freeNames


{-| Find free local variable names in an expression.
-}
findFreeLocals :
    EverySet String Name
    -> Mono.MonoExpr
    -> List Name
findFreeLocals bound expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            if EverySet.member identity name bound then
                []

            else
                [ name ]

        Mono.MonoClosure closureInfo body _ ->
            -- Descend into nested closures with their params added to bound.
            -- This ensures outer closures capture all variables needed by inner closures.
            let
                closureParams =
                    List.map Tuple.first closureInfo.params

                newBound =
                    List.foldl (\name acc -> EverySet.insert identity name acc) bound closureParams
            in
            findFreeLocals newBound body

        Mono.MonoLet _ _ _ ->
            -- For mutually recursive let-bindings, we need to collect ALL names
            -- from the entire let-chain first, add them all to bound, and only
            -- THEN analyze each definition. This ensures that when inner1's
            -- definition references inner2, inner2 is already in bound.
            let
                ( allDefs, finalBody ) =
                    collectLetChain expr

                -- Extract name from a MonoDef
                defName def =
                    case def of
                        Mono.MonoDef n _ ->
                            n

                        Mono.MonoTailDef n _ _ ->
                            n

                -- Add all names from the let-chain to bound BEFORE analyzing definitions
                allNames =
                    List.map defName allDefs

                boundWithAllNames =
                    List.foldl (\name acc -> EverySet.insert identity name acc) bound allNames

                -- Analyze a definition's expression, adding MonoTailDef params to bound
                analyzeDef def =
                    case def of
                        Mono.MonoDef _ defExpr ->
                            findFreeLocals boundWithAllNames defExpr

                        Mono.MonoTailDef _ params defExpr ->
                            -- For tail-recursive functions, add the function's params to bound
                            -- before analyzing the body. This prevents params from being
                            -- incorrectly identified as free variables.
                            let
                                paramNames =
                                    List.map Tuple.first params

                                boundWithParams =
                                    List.foldl (\name acc -> EverySet.insert identity name acc) boundWithAllNames paramNames
                            in
                            findFreeLocals boundWithParams defExpr

                -- Now analyze each definition with all sibling names in scope
                freeInDefs =
                    List.concatMap analyzeDef allDefs

                freeInBody =
                    findFreeLocals boundWithAllNames finalBody
            in
            freeInDefs ++ freeInBody

        Mono.MonoIf branches final _ ->
            let
                freeBranches =
                    List.concatMap
                        (\( cond, thenExpr ) ->
                            findFreeLocals bound cond
                                ++ findFreeLocals bound thenExpr
                        )
                        branches

                freeFinal =
                    findFreeLocals bound final
            in
            freeBranches ++ freeFinal

        Mono.MonoCase _ root decider jumps _ ->
            let
                -- The root (second Name field) is the scrutinee variable.
                -- It must be tracked as a free variable reference.
                rootFree =
                    if EverySet.member identity root bound then
                        []

                    else
                        [ root ]

                freeDecider =
                    collectDeciderFreeLocals bound decider

                freeJumps =
                    List.concatMap (\( _, e ) -> findFreeLocals bound e) jumps
            in
            rootFree ++ freeDecider ++ freeJumps

        Mono.MonoList _ exprs _ ->
            List.concatMap (findFreeLocals bound) exprs

        Mono.MonoCall _ func args _ _ ->
            findFreeLocals bound func
                ++ List.concatMap (findFreeLocals bound) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.concatMap (\( _, e ) -> findFreeLocals bound e) namedExprs

        Mono.MonoRecordCreate fields _ ->
            List.concatMap (\( _, e ) -> findFreeLocals bound e) fields

        Mono.MonoRecordAccess record _ _ ->
            findFreeLocals bound record

        Mono.MonoRecordUpdate record updates _ ->
            findFreeLocals bound record
                ++ List.concatMap (\( _, e ) -> findFreeLocals bound e) updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.concatMap (findFreeLocals bound) exprs

        Mono.MonoDestruct (Mono.MonoDestructor name path _) body _ ->
            let
                pathFree =
                    findPathFreeLocals bound path

                newBound =
                    EverySet.insert identity name bound
            in
            pathFree ++ findFreeLocals newBound body

        _ ->
            []


{-| Find free variables referenced in a MonoPath (via MonoRoot).
-}
findPathFreeLocals : EverySet String Name -> Mono.MonoPath -> List Name
findPathFreeLocals bound path =
    case path of
        Mono.MonoRoot name _ ->
            if EverySet.member identity name bound then
                []

            else
                [ name ]

        Mono.MonoIndex _ _ _ inner ->
            findPathFreeLocals bound inner

        Mono.MonoField _ _ inner ->
            findPathFreeLocals bound inner

        Mono.MonoUnbox _ inner ->
            findPathFreeLocals bound inner


{-| Collect all definitions from a let-chain, returning them along with the final body.

For example, given:
MonoLet (def1) (MonoLet (def2) (MonoLet (def3) finalBody))

Returns:
( [ def1, def2, def3 ], finalBody )

This is used by findFreeLocals to handle mutually recursive let-bindings correctly.
The full MonoDef is returned so that MonoTailDef params can be properly handled.

-}
collectLetChain : Mono.MonoExpr -> ( List Mono.MonoDef, Mono.MonoExpr )
collectLetChain expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                ( restDefs, finalBody ) =
                    collectLetChain body
            in
            ( def :: restDefs, finalBody )

        _ ->
            ( [], expr )


{-| Collect free local variables from a pattern match decider tree.
-}
collectDeciderFreeLocals :
    EverySet String Name
    -> Mono.Decider Mono.MonoChoice
    -> List Name
collectDeciderFreeLocals bound decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    findFreeLocals bound expr

                Mono.Jump _ ->
                    []

        Mono.Chain tests success failure ->
            let
                freePaths =
                    List.concatMap (\( dtPath, _ ) -> findDtPathFreeLocals bound dtPath) tests
            in
            freePaths
                ++ collectDeciderFreeLocals bound success
                ++ collectDeciderFreeLocals bound failure

        Mono.FanOut dtPath edges fallback ->
            let
                freeRoot =
                    findDtPathFreeLocals bound dtPath

                freeEdges =
                    List.concatMap (\( _, d ) -> collectDeciderFreeLocals bound d) edges

                freeFallback =
                    collectDeciderFreeLocals bound fallback
            in
            freeRoot ++ freeEdges ++ freeFallback


{-| Find free variables referenced in a MonoDtPath (decision tree path).
-}
findDtPathFreeLocals : EverySet String Name -> Mono.MonoDtPath -> List Name
findDtPathFreeLocals bound dtPath =
    case dtPath of
        Mono.DtRoot name _ ->
            if EverySet.member identity name bound then
                []

            else
                [ name ]

        Mono.DtIndex _ _ _ inner ->
            findDtPathFreeLocals bound inner

        Mono.DtUnbox _ inner ->
            findDtPathFreeLocals bound inner


{-| Remove duplicate names from a list while preserving order.
-}
dedupeNames : List Name -> List Name
dedupeNames names =
    let
        step name ( seen, acc ) =
            if EverySet.member identity name seen then
                ( seen, acc )

            else
                ( EverySet.insert identity name seen, name :: acc )
    in
    names
        |> List.foldl step ( EverySet.empty, [] )
        |> Tuple.second
        |> List.reverse


{-| Collect a mapping from variable names to their types from an expression.
This walks the expression tree and records the type of each MonoVarLocal encountered.
-}
collectVarTypes : Mono.MonoExpr -> Dict String Mono.MonoType
collectVarTypes expr =
    collectVarTypesHelper expr Dict.empty


collectVarTypesHelper : Mono.MonoExpr -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectVarTypesHelper expr acc =
    case expr of
        Mono.MonoVarLocal name monoType ->
            -- Only insert if not already present (keep first occurrence)
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.MonoClosure _ body _ ->
            -- Recurse into closure body
            collectVarTypesHelper body acc

        Mono.MonoLet def body _ ->
            let
                accAfterDef =
                    case def of
                        Mono.MonoDef _ defExpr ->
                            collectVarTypesHelper defExpr acc

                        Mono.MonoTailDef _ _ defExpr ->
                            collectVarTypesHelper defExpr acc
            in
            collectVarTypesHelper body accAfterDef

        Mono.MonoIf branches final _ ->
            let
                accAfterBranches =
                    List.foldl
                        (\( cond, thenExpr ) a ->
                            collectVarTypesHelper thenExpr (collectVarTypesHelper cond a)
                        )
                        acc
                        branches
            in
            collectVarTypesHelper final accAfterBranches

        Mono.MonoCase _ _ decider jumps _ ->
            let
                accAfterDecider =
                    collectDeciderVarTypes decider acc
            in
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) accAfterDecider jumps

        Mono.MonoList _ exprs _ ->
            List.foldl collectVarTypesHelper acc exprs

        Mono.MonoCall _ func args _ _ ->
            List.foldl collectVarTypesHelper (collectVarTypesHelper func acc) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) acc namedExprs

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) acc fields

        Mono.MonoRecordAccess record _ _ ->
            collectVarTypesHelper record acc

        Mono.MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) (collectVarTypesHelper record acc) updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl collectVarTypesHelper acc exprs

        Mono.MonoDestruct (Mono.MonoDestructor _ path _) body _ ->
            let
                accAfterPath =
                    collectPathVarTypes path acc
            in
            collectVarTypesHelper body accAfterPath

        _ ->
            acc


collectPathVarTypes : Mono.MonoPath -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectPathVarTypes path acc =
    case path of
        Mono.MonoRoot name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.MonoIndex _ _ _ inner ->
            collectPathVarTypes inner acc

        Mono.MonoField _ _ inner ->
            collectPathVarTypes inner acc

        Mono.MonoUnbox _ inner ->
            collectPathVarTypes inner acc


collectDeciderVarTypes : Mono.Decider Mono.MonoChoice -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectDeciderVarTypes decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectVarTypesHelper expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain tests success failure ->
            let
                accWithTests =
                    List.foldl (\( dtPath, _ ) a -> collectDtPathVarTypes dtPath a) acc tests
            in
            collectDeciderVarTypes failure (collectDeciderVarTypes success accWithTests)

        Mono.FanOut dtPath edges fallback ->
            let
                accWithPath =
                    collectDtPathVarTypes dtPath acc

                accAfterEdges =
                    List.foldl (\( _, d ) a -> collectDeciderVarTypes d a) accWithPath edges
            in
            collectDeciderVarTypes fallback accAfterEdges


{-| Collect variable-to-type mappings from a MonoDtPath (decision tree path).
-}
collectDtPathVarTypes : Mono.MonoDtPath -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectDtPathVarTypes dtPath acc =
    case dtPath of
        Mono.DtRoot name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.DtIndex _ _ _ inner ->
            collectDtPathVarTypes inner acc

        Mono.DtUnbox _ inner ->
            collectDtPathVarTypes inner acc


{-| Collect types for MonoCase root variables by inferring from decider tests.

MonoCase stores the scrutinee variable by name but not by type. When a variable
is only referenced as a MonoCase root (and never as a MonoVarLocal), collectVarTypes
won't find its type. This function fills that gap by inferring the root type from
the decision tree tests.
-}
collectCaseRootTypes : Mono.MonoExpr -> Dict String Mono.MonoType
collectCaseRootTypes expr =
    collectCaseRootTypesHelper expr Dict.empty


collectCaseRootTypesHelper : Mono.MonoExpr -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectCaseRootTypesHelper expr acc =
    case expr of
        Mono.MonoCase _ root decider jumps _ ->
            let
                accWithRoot =
                    if Dict.member root acc then
                        acc

                    else
                        case inferRootTypeFromDecider decider of
                            Just rootType ->
                                Dict.insert root rootType acc

                            Nothing ->
                                -- Fallback: use MUnit which maps to !eco.value at ABI.
                                -- This is correct for all union types (the common case for MonoCase).
                                Dict.insert root Mono.MUnit acc

                accAfterDecider =
                    collectCaseRootTypesFromDecider decider accWithRoot
            in
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) accAfterDecider jumps

        Mono.MonoClosure _ body _ ->
            collectCaseRootTypesHelper body acc

        Mono.MonoLet def body _ ->
            let
                accAfterDef =
                    case def of
                        Mono.MonoDef _ defExpr ->
                            collectCaseRootTypesHelper defExpr acc

                        Mono.MonoTailDef _ _ defExpr ->
                            collectCaseRootTypesHelper defExpr acc
            in
            collectCaseRootTypesHelper body accAfterDef

        Mono.MonoIf branches final _ ->
            let
                accAfterBranches =
                    List.foldl
                        (\( cond, thenExpr ) a ->
                            collectCaseRootTypesHelper thenExpr (collectCaseRootTypesHelper cond a)
                        )
                        acc
                        branches
            in
            collectCaseRootTypesHelper final accAfterBranches

        Mono.MonoCall _ func args _ _ ->
            List.foldl collectCaseRootTypesHelper (collectCaseRootTypesHelper func acc) args

        Mono.MonoList _ exprs _ ->
            List.foldl collectCaseRootTypesHelper acc exprs

        Mono.MonoDestruct _ inner _ ->
            collectCaseRootTypesHelper inner acc

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            collectCaseRootTypesHelper inner acc

        Mono.MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) (collectCaseRootTypesHelper inner acc) updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl collectCaseRootTypesHelper acc exprs

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) acc args

        _ ->
            acc


collectCaseRootTypesFromDecider : Mono.Decider Mono.MonoChoice -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectCaseRootTypesFromDecider decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCaseRootTypesHelper expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain tests success failure ->
            let
                accWithTests =
                    List.foldl (\( dtPath, _ ) a -> collectDtPathCaseRootTypes dtPath a) acc tests
            in
            collectCaseRootTypesFromDecider failure (collectCaseRootTypesFromDecider success accWithTests)

        Mono.FanOut dtPath edges fallback ->
            let
                accWithPath =
                    collectDtPathCaseRootTypes dtPath acc

                accAfterEdges =
                    List.foldl (\( _, d ) a -> collectCaseRootTypesFromDecider d a) accWithPath edges
            in
            collectCaseRootTypesFromDecider fallback accAfterEdges


{-| Collect root variable types from a MonoDtPath (decision tree path).
-}
collectDtPathCaseRootTypes : Mono.MonoDtPath -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectDtPathCaseRootTypes dtPath acc =
    case dtPath of
        Mono.DtRoot name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.DtIndex _ _ _ inner ->
            collectDtPathCaseRootTypes inner acc

        Mono.DtUnbox _ inner ->
            collectDtPathCaseRootTypes inner acc


{-| Infer the root variable's MonoType from the first test in a Decider.
-}
inferRootTypeFromDecider : Mono.Decider Mono.MonoChoice -> Maybe Mono.MonoType
inferRootTypeFromDecider decider =
    case decider of
        Mono.Chain tests _ _ ->
            case tests of
                ( Mono.DtRoot _ _, test ) :: _ ->
                    inferTypeFromTest test

                _ ->
                    Nothing

        Mono.FanOut path edges _ ->
            case path of
                Mono.DtRoot _ _ ->
                    case edges of
                        ( test, _ ) :: _ ->
                            inferTypeFromTest test

                        [] ->
                            Nothing

                _ ->
                    Nothing

        Mono.Leaf _ ->
            Nothing


inferTypeFromTest : DT.Test -> Maybe Mono.MonoType
inferTypeFromTest test =
    case test of
        DT.IsInt _ ->
            Just Mono.MInt

        DT.IsChr _ ->
            Just Mono.MChar

        DT.IsStr _ ->
            Just Mono.MString

        _ ->
            -- Custom types, Bool, List, Tuple all map to !eco.value at ABI,
            -- same as MUnit. The exact type params aren't needed for capture ABI.
            Just Mono.MUnit
