module Compiler.Generate.Monomorphize.Closure exposing
    ( ensureCallableTopLevel, flattenFunctionType, makeAliasClosure, makeGeneralClosure, makeAliasClosureOverExpr
    , freshParams, extractRegion
    , computeClosureCaptures, findFreeLocals, collectDeciderFreeLocals, dedupeNames
    )

{-| Closure handling and capture analysis for monomorphization.

This module handles:

  - Creating closures for function-typed expressions
  - Computing closure captures (free variables)
  - Finding free local variables in expressions


# Closure Creation

@docs ensureCallableTopLevel, flattenFunctionType, makeAliasClosure, makeGeneralClosure, makeAliasClosureOverExpr


# Parameters and Regions

@docs freshParams, extractRegion


# Free Variable Analysis

@docs computeClosureCaptures, findFreeLocals, collectDeciderFreeLocals, dedupeNames

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Generate.Monomorphize.State exposing (MonoState)
import Compiler.Reporting.Annotation as A
import Data.Set as EverySet exposing (EverySet)



-- ========== LAMBDA AND CLOSURE HANDLING ==========


{-| Ensure that a top-level expression is directly callable by wrapping it in a closure if necessary.
-}
ensureCallableTopLevel : Mono.MonoExpr -> Mono.MonoType -> MonoState -> ( Mono.MonoExpr, MonoState )
ensureCallableTopLevel expr monoType state =
    case monoType of
        Mono.MFunction _ _ ->
            let
                ( argTypes, retType ) =
                    flattenFunctionType monoType
            in
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    if List.length closureInfo.params >= List.length argTypes then
                        ( expr, state )

                    else
                        -- Under-parameterized closure: wrap it in an alias closure
                        makeAliasClosureOverExpr expr argTypes retType monoType state

                Mono.MonoVarGlobal region specId _ ->
                    makeAliasClosure
                        (Mono.MonoVarGlobal region specId monoType)
                        region
                        argTypes
                        retType
                        monoType
                        state

                Mono.MonoVarKernel region home name kernelAbiType ->
                    -- IMPORTANT: Keep the original kernel ABI type, don't replace with monoType.
                    -- The kernel ABI type was derived by deriveKernelAbiType and must remain
                    -- consistent across all call sites (polymorphic kernels use boxed ABI).
                    makeAliasClosure
                        (Mono.MonoVarKernel region home name kernelAbiType)
                        region
                        argTypes
                        retType
                        monoType
                        state

                _ ->
                    makeGeneralClosure expr argTypes retType monoType state

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

        closureInfo =
            { lambdaId = lambdaId
            , captures = []
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

        closureInfo =
            { lambdaId = lambdaId
            , captures = []
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

        Mono.MonoRecordCreate _ _ _ ->
            A.zero

        Mono.MonoRecordAccess record _ _ _ _ ->
            extractRegion record

        Mono.MonoRecordUpdate record _ _ _ ->
            extractRegion record

        Mono.MonoTupleCreate region _ _ _ ->
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

        captureFor name =
            let
                -- We do not track an environment here; in practice we only
                -- capture by name and type from the VarLocal uses.
                -- For now, use a placeholder MUnit when the type is unknown.
                placeholderType =
                    Mono.MUnit
            in
            ( name, Mono.MonoVarLocal name placeholderType, False )
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

                -- Add all names from the let-chain to bound BEFORE analyzing definitions
                allNames =
                    List.map Tuple.first allDefs

                boundWithAllNames =
                    List.foldl (\name acc -> EverySet.insert identity name acc) bound allNames

                -- Now analyze each definition with all sibling names in scope
                freeInDefs =
                    List.concatMap (\( _, defExpr ) -> findFreeLocals boundWithAllNames defExpr) allDefs

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

        Mono.MonoRecordCreate exprs _ _ ->
            List.concatMap (findFreeLocals bound) exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            findFreeLocals bound record

        Mono.MonoRecordUpdate record updates _ _ ->
            findFreeLocals bound record
                ++ List.concatMap (\( _, e ) -> findFreeLocals bound e) updates

        Mono.MonoTupleCreate _ exprs _ _ ->
            List.concatMap (findFreeLocals bound) exprs

        _ ->
            []


{-| Collect all definitions from a let-chain, returning them along with the final body.

For example, given:
MonoLet (def1) (MonoLet (def2) (MonoLet (def3) finalBody))

Returns:
( [ (name1, expr1), (name2, expr2), (name3, expr3) ], finalBody )

This is used by findFreeLocals to handle mutually recursive let-bindings correctly.

-}
collectLetChain : Mono.MonoExpr -> ( List ( Name, Mono.MonoExpr ), Mono.MonoExpr )
collectLetChain expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                ( defName, defExpr ) =
                    case def of
                        Mono.MonoDef n e ->
                            ( n, e )

                        Mono.MonoTailDef n _ e ->
                            ( n, e )

                ( restDefs, finalBody ) =
                    collectLetChain body
            in
            ( ( defName, defExpr ) :: restDefs, finalBody )

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
