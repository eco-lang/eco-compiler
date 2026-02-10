module Compiler.Monomorphize.Closure exposing
    ( freshParams
    , extractRegion
    , computeClosureCaptures
    , findFreeLocals
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

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
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
        varTypeMap : Dict String String Mono.MonoType
        varTypeMap =
            collectVarTypes body

        captureFor name =
            case Dict.get identity name varTypeMap of
                Just actualType ->
                    ( name, Mono.MonoVarLocal name actualType, False )

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

        Mono.MonoCase _ _ decider jumps _ ->
            let
                freeDecider =
                    collectDeciderFreeLocals bound decider

                freeJumps =
                    List.concatMap (\( _, e ) -> findFreeLocals bound e) jumps
            in
            freeDecider ++ freeJumps

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

        Mono.Chain _ success failure ->
            collectDeciderFreeLocals bound success
                ++ collectDeciderFreeLocals bound failure

        Mono.FanOut _ edges fallback ->
            let
                freeEdges =
                    List.concatMap (\( _, d ) -> collectDeciderFreeLocals bound d) edges

                freeFallback =
                    collectDeciderFreeLocals bound fallback
            in
            freeEdges ++ freeFallback


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
collectVarTypes : Mono.MonoExpr -> Dict String String Mono.MonoType
collectVarTypes expr =
    collectVarTypesHelper expr Dict.empty


collectVarTypesHelper : Mono.MonoExpr -> Dict String String Mono.MonoType -> Dict String String Mono.MonoType
collectVarTypesHelper expr acc =
    case expr of
        Mono.MonoVarLocal name monoType ->
            -- Only insert if not already present (keep first occurrence)
            if Dict.member identity name acc then
                acc

            else
                Dict.insert identity name monoType acc

        Mono.MonoClosure closureInfo body _ ->
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

                accAfterJumps =
                    List.foldl (\( _, e ) a -> collectVarTypesHelper e a) accAfterDecider jumps
            in
            accAfterJumps

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

        Mono.MonoDestruct _ body _ ->
            collectVarTypesHelper body acc

        _ ->
            acc


collectDeciderVarTypes : Mono.Decider Mono.MonoChoice -> Dict String String Mono.MonoType -> Dict String String Mono.MonoType
collectDeciderVarTypes decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectVarTypesHelper expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain _ success failure ->
            collectDeciderVarTypes failure (collectDeciderVarTypes success acc)

        Mono.FanOut _ edges fallback ->
            let
                accAfterEdges =
                    List.foldl (\( _, d ) a -> collectDeciderVarTypes d a) acc edges
            in
            collectDeciderVarTypes fallback accAfterEdges
