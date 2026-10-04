module Compiler.Type.KernelTypes exposing
    ( KernelTypeEnv
    , lookup, hasEntry
    , insertFirstUsage, buildFunctionType
    )

{-| A kernel function has no Elm declaration, so it has no annotation of its
own to give its type. This module defines the table in which a type for each
kernel function is recorded once one has been worked out.

A _kernel function_ is a function of a kernel module, referred to in a module
of a kernel package as `Elm.Kernel.List.map` or `Eco.Kernel.File.size`. The
canonical AST gives such a reference as `Can.VarKernel`, with the kernel prefix
(`Elm` or `Eco`), the _home_ (the rest of the module name, `List` for
`Elm.Kernel.List`) and the function name.

The table is keyed by home and function name only. The prefix is not part of
the key, so `Elm.Kernel.File.size` and `Eco.Kernel.File.size` share one entry.

The table holds one type per kernel function, however many types its uses
would need. Entries added through `insertFirstUsage` follow the rule _first
usage wins_: the first type recorded for a kernel function is the one kept, and
later ones are dropped.


# Type

@docs KernelTypeEnv


# Lookup

@docs lookup, hasEntry


# Building an environment

@docs insertFirstUsage, buildFunctionType

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)



-- ====== TYPE ======


{-| The types recorded for kernel functions, keyed by home and function name,
with no kernel prefix.

This is a name for a `Dict`, not a new type. Any such `Dict` is accepted where
a `KernelTypeEnv` is expected, so the first-usage-wins rule holds only for
entries added through `insertFirstUsage`.

-}
type alias KernelTypeEnv =
    Dict ( Name, Name ) (Can.Type Name)



-- ====== LOOKUP ======


{-| Returns the type recorded for the kernel function `name` of the kernel
module `home`, or `Nothing` when none is recorded. `home` is the module name
without its kernel prefix, such as `List` for `Elm.Kernel.List`.
-}
lookup : Name -> Name -> KernelTypeEnv -> Maybe (Can.Type Name)
lookup home name env =
    Dict.get ( home, name ) env


{-| Tells whether a type is recorded for the kernel function `name` of the
kernel module `home`.
-}
hasEntry : Name -> Name -> KernelTypeEnv -> Bool
hasEntry home name env =
    case Dict.get ( home, name ) env of
        Just _ ->
            True

        Nothing ->
            False



-- ====== BUILDING ======


{-| Records `tipe` as the type of the kernel function `name` of the kernel
module `home`, unless a type is already recorded for that pair, in which case
`env` is returned unchanged.
-}
insertFirstUsage : Name -> Name -> Can.Type Name -> KernelTypeEnv -> KernelTypeEnv
insertFirstUsage home name tipe env =
    if hasEntry home name env then
        env

    else
        Dict.insert ( home, name ) tipe env


{-| Builds the curried function type that takes `argTypes`, in order, and
returns `resultType`. With no argument types the result is `resultType` itself.
Its arrows are made by `Can.tLambda`, so none carries an arrow identity.
-}
buildFunctionType : List (Can.Type Name) -> Can.Type Name -> Can.Type Name
buildFunctionType argTypes resultType =
    List.foldr Can.tLambda resultType argTypes
