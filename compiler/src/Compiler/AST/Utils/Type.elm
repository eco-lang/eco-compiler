module Compiler.AST.Utils.Type exposing
    ( dealias, deepDealias, iteratedDealias
    , delambda
    )

{-| Utilities for manipulating and normalizing canonical type representations.

This module provides functions to work with type aliases and function types in the
canonical AST. The primary operations are dealiasing (expanding type aliases with
their concrete definitions) and delambda (flattening nested function types).


# Type Alias Expansion

@docs dealias, deepDealias, iteratedDealias


# Function Type Utilities

@docs delambda

-}

import Compiler.AST.Canonical exposing (AliasType(..), FieldType(..), Type(..))
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)



-- DELAMBDA


{-| Flatten a function type into a list of its argument types followed by the return type.
For example, `(a -> b -> c)` becomes `[a, b, c]`.
-}
delambda : Type -> List Type
delambda tipe =
    case tipe of
        TLambda arg result ->
            arg :: delambda result

        _ ->
            [ tipe ]



-- DEALIAS


{-| Expand a type alias by substituting its type parameters with concrete types.
Takes a list of (parameter name, concrete type) pairs and the alias definition to expand.
-}
dealias : List ( Name, Type ) -> AliasType -> Type
dealias args aliasType =
    case aliasType of
        Holey tipe ->
            dealiasHelp (Dict.fromList identity args) tipe

        Filled tipe ->
            tipe


dealiasHelp : Dict String Name Type -> Type -> Type
dealiasHelp typeTable tipe =
    case tipe of
        TLambda a b ->
            TLambda
                (dealiasHelp typeTable a)
                (dealiasHelp typeTable b)

        TVar x ->
            Dict.get identity x typeTable
                |> Maybe.withDefault tipe

        TRecord fields ext ->
            TRecord (Dict.map (\_ -> dealiasField typeTable) fields) ext

        TAlias home name args t_ ->
            TAlias home name (List.map (Tuple.mapSecond (dealiasHelp typeTable)) args) t_

        TType home name args ->
            TType home name (List.map (dealiasHelp typeTable) args)

        TUnit ->
            TUnit

        TTuple a b cs ->
            TTuple
                (dealiasHelp typeTable a)
                (dealiasHelp typeTable b)
                (List.map (dealiasHelp typeTable) cs)


dealiasField : Dict String Name Type -> FieldType -> FieldType
dealiasField typeTable (FieldType index tipe) =
    FieldType index (dealiasHelp typeTable tipe)



-- DEEP DEALIAS


{-| Recursively expand all type aliases in a type, replacing them with their concrete definitions.
-}
deepDealias : Type -> Type
deepDealias tipe =
    case tipe of
        TLambda a b ->
            TLambda (deepDealias a) (deepDealias b)

        TVar _ ->
            tipe

        TRecord fields ext ->
            TRecord (Dict.map (\_ -> deepDealiasField) fields) ext

        TAlias _ _ args tipe_ ->
            deepDealias (dealias args tipe_)

        TType home name args ->
            TType home name (List.map deepDealias args)

        TUnit ->
            TUnit

        TTuple a b cs ->
            TTuple (deepDealias a) (deepDealias b) (List.map deepDealias cs)


deepDealiasField : FieldType -> FieldType
deepDealiasField (FieldType index tipe) =
    FieldType index (deepDealias tipe)



-- ITERATED DEALIAS


{-| Expand type aliases at the top level only, iterating until no more aliases remain.
Does not recurse into nested types.
-}
iteratedDealias : Type -> Type
iteratedDealias tipe =
    case tipe of
        TAlias _ _ args realType ->
            iteratedDealias (dealias args realType)

        _ ->
            tipe
