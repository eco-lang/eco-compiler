module Compiler.Generate.Monomorphize.Closure exposing
    ( ensureCallableTopLevel
    , computeClosureCaptures
    )

{-| Closure handling and capture analysis for monomorphization.

This module handles:

  - Creating closures for function-typed expressions
  - Computing closure captures (free variables)
  - Finding free local variables in expressions


# Closure Creation

@docs ensureCallableTopLevel


# Parameters and Regions


# Free Variable Analysis

@docs computeClosureCaptures

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Monomorphize.State exposing (MonoState)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Utils.Crash



-- ========== LAMBDA AND CLOSURE HANDLING ==========


{-| Ensure that a top-level expression is directly callable by wrapping it in a closure if necessary.
-}
ensureCallableTopLevel : Mono.MonoExpr -> Mono.MonoType -> MonoState -> ( Mono.MonoExpr, MonoState )
ensureCallableTopLevel expr monoType state =
    case monoType of
        Mono.MFunction _ _ ->
            let
                -- MONO_016: Use stage arity (first MFunction params only)
                stageArgTypes =
                    Types.stageParamTypes monoType

                stageRetType =
                    Types.stageReturnType monoType

                stageArity =
                    List.length stageArgTypes
            in
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    -- MONO_016: Check against stage arity, not flattened arity
                    -- Closures from specializeLambda have exactly stage params
                    if List.length closureInfo.params >= stageArity then
                        ( expr, state )

                    else
                        Utils.Crash.crash
                            ("ensureCallableTopLevel: under-parameterized closure for type "
                                ++ Debug.toString monoType
                                ++ " (have "
                                ++ String.fromInt (List.length closureInfo.params)
                                ++ " params, expected stage arity "
                                ++ String.fromInt stageArity
                                ++ "). This should not happen; fix monomorphization."
                            )

                Mono.MonoVarGlobal region specId _ ->
                    -- MONO_016: Create stage-aware closure wrapper
                    makeAliasClosure
                        (Mono.MonoVarGlobal region specId monoType)
                        region
                        stageArgTypes
                        stageRetType
                        monoType
                        state

                Mono.MonoVarKernel region home name kernelAbiType ->
                    -- Kernels use flattened ABI (all params at once), not stage-curried.
                    -- Create a fully flattened alias closure that calls the kernel with all args.
                    let
                        ( kernelFlatArgTypes, kernelFlatRetType ) =
                            flattenFunctionType kernelAbiType

                        -- Build a flattened function type for the wrapper so callers
                        -- see the correct arity and apply all args at once.
                        flattenedFuncType =
                            Mono.MFunction kernelFlatArgTypes kernelFlatRetType
                    in
                    makeAliasClosure
                        (Mono.MonoVarKernel region home name kernelAbiType)
                        region
                        kernelFlatArgTypes
                        kernelFlatRetType
                        flattenedFuncType
                        state

                _ ->
                    -- MONO_016: Create stage-aware closure wrapper
                    makeGeneralClosure expr stageArgTypes stageRetType monoType state

        _ ->
            ( expr, state )


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


{-| Create an alias closure wrapping a callee expression.
-}
makeAliasClosure :
    Mono.MonoExpr
    -> A.Region
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeAliasClosure calleeExpr region argTypes retType funcType state =
    let
        params =
            freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        callExpr =
            Mono.MonoCall region calleeExpr paramExprs retType

        -- Compute captures from the call expression.
        -- For MonoVarGlobal/MonoVarKernel callees this will be empty,
        -- but we compute defensively for future-proofing.
        captures =
            computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            }

        closureExpr =
            Mono.MonoClosure closureInfo callExpr funcType
    in
    ( closureExpr, stateWithLambda )


{-| Create a general closure around an expression.
-}
makeGeneralClosure :
    Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeGeneralClosure expr argTypes retType funcType state =
    let
        region =
            extractRegion expr

        params =
            freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        callExpr =
            Mono.MonoCall region expr paramExprs retType

        -- Compute captures: find free locals in the call expression
        -- that are not bound by the closure's own params.
        -- This is critical when `expr` references outer variables.
        captures =
            computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            }

        closureExpr =
            Mono.MonoClosure closureInfo callExpr funcType
    in
    ( closureExpr, stateWithLambda )


{-| Create an alias closure wrapping an existing expression.
-}
makeAliasClosureOverExpr :
    Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeAliasClosureOverExpr expr argTypes retType funcType state =
    -- For now, treat it like a general closure around the expression.
    -- If you later want to reuse existing captures of an inner closure,
    -- you can extend this to preserve them.
    makeGeneralClosure expr argTypes retType funcType state


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

        Mono.MonoCall region _ _ _ ->
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

        Mono.MonoRecordAccess record _ _ _ _ ->
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
            let
                -- Look up the actual type from the body expression.
                -- If not found (shouldn't happen for well-typed code), fall back to MUnit.
                actualType =
                    Dict.get identity name varTypeMap
                        |> Maybe.withDefault Mono.MUnit
            in
            ( name, Mono.MonoVarLocal name actualType, False )
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

        Mono.MonoCall _ func args _ ->
            findFreeLocals bound func
                ++ List.concatMap (findFreeLocals bound) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.concatMap (\( _, e ) -> findFreeLocals bound e) namedExprs

        Mono.MonoRecordCreate exprs _ ->
            List.concatMap (findFreeLocals bound) exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            findFreeLocals bound record

        Mono.MonoRecordUpdate record updates _ ->
            findFreeLocals bound record
                ++ List.concatMap (\( _, e ) -> findFreeLocals bound e) updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.concatMap (findFreeLocals bound) exprs

        _ ->
            []


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

        Mono.MonoCall _ func args _ ->
            List.foldl collectVarTypesHelper (collectVarTypesHelper func acc) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) acc namedExprs

        Mono.MonoRecordCreate exprs _ ->
            List.foldl collectVarTypesHelper acc exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
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
