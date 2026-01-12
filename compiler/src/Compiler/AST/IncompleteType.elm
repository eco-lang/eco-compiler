module Compiler.AST.IncompleteType exposing
    ( IncompleteType(..)
    , toCanonicalPreservingUnknown
    , buildFunctionType, peelFunctionType
    )

{-| Typed-pipeline wrapper around canonical types.

This module provides a structured way to represent types in the typed optimization
pipeline that may be "unknown" (to be solved later). The typed pipeline now uses
`ToSolve` to represent unknown types, replacing the previous ad-hoc use of
`TVar "?"` literals.


# Types

@docs IncompleteType


# Conversion

@docs toCanonicalPreservingUnknown


# Operations

@docs buildFunctionType, peelFunctionType

-}

import Compiler.AST.Canonical as Can
import Utils.Crash


{-| A type annotation in the typed pipeline.

  - `Complete t` is a normal `Can.Type` from the front-end type checker.
  - `ToSolve location` is the backend-only "unknown" placeholder. This represents
    cases where type information is unavailable at a particular point
    in the compilation pipeline. The location string tracks where in the source
    code this ToSolve originated, for debugging purposes.

-}
type IncompleteType
    = Complete Can.Type
    | ToSolve String


{-| Convert `IncompleteType` back to canonical, mapping `ToSolve` to `TVar "?"`.

This is used at the boundary where the typed pipeline feeds into downstream
consumers (like monomorphization) that expect `Can.Type`. The mapping ensures
backward compatibility: any `ToSolve` becomes `TVar "?"`, which monomorphization
handles by producing `MVar "?" CEcoValue`.

-}
toCanonicalPreservingUnknown : IncompleteType -> Can.Type
toCanonicalPreservingUnknown itype =
    case itype of
        Complete t ->
            t

        ToSolve source ->
            --Can.TVar "?"
            Utils.Crash.crash (source ++ " Escaped TVar \"?\"")


{-| Peel n argument types from a function type to get the result type.

For `ToSolve`, returns `ToSolve` since we can't know the result type.
For `Complete (a -> b -> c)` with n=2, returns `Complete c`.

-}
peelFunctionType : Int -> IncompleteType -> IncompleteType
peelFunctionType n itype =
    case itype of
        ToSolve loc ->
            ToSolve ("IncompleteType.peelFunctionType from " ++ loc)

        Complete canType ->
            Complete (peelCanFunctionType n canType)


{-| Helper to peel function types from a Can.Type.
-}
peelCanFunctionType : Int -> Can.Type -> Can.Type
peelCanFunctionType n tipe =
    if n <= 0 then
        tipe

    else
        case tipe of
            Can.TLambda _ result ->
                peelCanFunctionType (n - 1) result

            _ ->
                tipe


{-| Build a function type from argument types and a result type.

If all arguments are `Complete`, builds a proper `Complete` function type.
If any argument is `ToSolve`, returns `ToSolve`.

    buildFunctionType [Complete Int, Complete String] (Complete Bool)
        => Complete (Int -> String -> Bool)

    buildFunctionType [ToSolve, Complete String] (Complete Bool)
        => ToSolve

-}
buildFunctionType : List IncompleteType -> IncompleteType -> IncompleteType
buildFunctionType argTypes resultType =
    case collectCompleteTypes argTypes of
        Nothing ->
            ToSolve "IncompleteType.buildFunctionType: incomplete arg"

        Just canArgTypes ->
            case resultType of
                ToSolve loc ->
                    ToSolve ("IncompleteType.buildFunctionType: incomplete result from " ++ loc)

                Complete canResultType ->
                    Complete (buildCanFunctionType canArgTypes canResultType)


{-| Collect all Complete types from a list, or Nothing if any is ToSolve.
-}
collectCompleteTypes : List IncompleteType -> Maybe (List Can.Type)
collectCompleteTypes itypes =
    List.foldr
        (\itype acc ->
            case ( itype, acc ) of
                ( Complete t, Just ts ) ->
                    Just (t :: ts)

                _ ->
                    Nothing
        )
        (Just [])
        itypes


{-| Build a Can.Type function type from Can.Type arguments.
-}
buildCanFunctionType : List Can.Type -> Can.Type -> Can.Type
buildCanFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes
