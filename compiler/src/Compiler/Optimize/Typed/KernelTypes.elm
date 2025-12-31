module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , lookup
    , hasEntry
    , insertFirstUsage
    , buildFunctionType
    )

{-| Kernel function type environment for typed optimization.

This module provides the kernel type environment and helper utilities.
The environment maps kernel function (home, name) pairs to their canonical types.

Construction of the kernel environment is handled by the PostSolve phase,
which uses alias seeding and usage-based inference over the canonical AST.


# Type

@docs KernelTypeEnv


# Lookup

@docs lookup


# Helpers for PostSolve

@docs insertFirstUsage, buildFunctionType

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)



-- ====== TYPE ======


{-| Environment mapping kernel function (home, name) pairs to their types.
-}
type alias KernelTypeEnv =
    Dict ( String, String ) ( Name, Name ) Can.Type


toComparable : ( Name, Name ) -> ( String, String )
toComparable ( a, b ) =
    ( a, b )



-- ====== LOOKUP ======


{-| Look up a kernel type by (home, name).
-}
lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type
lookup home name env =
    Dict.get toComparable ( home, name ) env


{-| Check if an entry exists for a kernel.
-}
hasEntry : Name -> Name -> KernelTypeEnv -> Bool
hasEntry home name env =
    case Dict.get toComparable ( home, name ) env of
        Just _ ->
            True

        Nothing ->
            False



-- ====== HELPERS FOR POSTSOLVE ======


{-| Insert a kernel type only if no entry exists (first-usage-wins).
-}
insertFirstUsage : Name -> Name -> Can.Type -> KernelTypeEnv -> KernelTypeEnv
insertFirstUsage home name tipe env =
    if hasEntry home name env then
        env

    else
        Dict.insert toComparable ( home, name ) tipe env


{-| Build a function type from argument types and result type.
-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes
