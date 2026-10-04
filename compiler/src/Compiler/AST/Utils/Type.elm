module Compiler.AST.Utils.Type exposing
    ( dealias, deepDealias, iteratedDealias
    , delambda
    )

{-| Several phases of the compiler need to see through a type alias to the type
it stands for, or to read off the argument types of a function type, and this
module holds the functions that do both on a canonical `Type Name`.

A use of a type alias is a `TAlias` node. It keeps the alias's name and the
use's arguments, each paired with the parameter name it is given for, together
with the aliased type in one of the two forms that
`Compiler.AST.Canonical.AliasType` describes: a `Holey` body still written in
the alias's own parameter names, or a `Filled` body with the arguments already
in place. To _dealias_ a use is to replace it with its aliased type, putting
the arguments in place of the parameters when the body is `Holey`.

The three dealiasing functions differ in how much of a type they expand.
`dealias` produces the aliased type of one use. `iteratedDealias` expands
aliases at the top of a type until the outermost node is not an alias, and
leaves any alias inside it alone. `deepDealias` expands every alias at every
depth. None of them substitutes into the extension variable of a record type,
which stays the name it was even when it names one of the alias's parameters.

`delambda` splits a function type into its argument types and its result
type. It does not dealias.

A function here that rebuilds a `TLambda` keeps its arrow slot, whose meaning
`Compiler.AST.TypeIds.ArrowSlot` describes, so dealiasing changes no arrow's
identity.


# Type Alias Expansion

@docs dealias, deepDealias, iteratedDealias


# Function Type Utilities

@docs delambda

-}

import Compiler.AST.Canonical exposing (AliasType(..), FieldType(..), Type(..))
import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)



-- ====== DELAMBDA ======


{-| Returns the argument types of a function type, in order, followed by its
result type, so that `a -> b -> c` gives `[ a, b, c ]`. A type that is not a
`TLambda` gives a list holding only itself.

Aliases are not expanded, so where the result, or the whole type, is an alias
of a function type, the list ends with that alias. The arrow slots are dropped.

-}
delambda : Type Name -> List (Type Name)
delambda tipe =
    case tipe of
        TLambda _ arg result ->
            arg :: delambda result

        _ ->
            [ tipe ]



-- ====== DEALIAS ======


{-| Returns the aliased type of one use of an alias, given `args`, the use's
pairs of parameter name and argument type, and the use's `AliasType`.

From a `Holey` body, every `TVar` that `args` names is replaced by its
argument type. A type variable that `args` does not name is left as it is, and
so is a record type's extension variable. A use of another alias inside the
body has its argument types substituted but keeps its own aliased type as it
is, and stays a `TAlias`.

A `Filled` body is returned unchanged, and `args` is ignored.

-}
dealias : List ( Name, Type Name ) -> AliasType Name -> Type Name
dealias args aliasType =
    case aliasType of
        Holey tipe ->
            dealiasHelp (Dict.fromList args) tipe

        Filled tipe ->
            tipe


{-| Returns `tipe` with every `TVar` that `typeTable` names replaced by its
type, except inside the aliased type of an alias use, whose arguments alone are
substituted. Record extension names are left as they are.
-}
dealiasHelp : Dict Name (Type Name) -> Type Name -> Type Name
dealiasHelp typeTable tipe =
    case tipe of
        TLambda aid a b ->
            TLambda aid
                (dealiasHelp typeTable a)
                (dealiasHelp typeTable b)

        TVar x ->
            Dict.get x typeTable
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


{-| Returns a record field, keeping its position, with `dealiasHelp`'s
substitution applied to its type.
-}
dealiasField : Dict Name (Type Name) -> FieldType Name -> FieldType Name
dealiasField typeTable (FieldType index tipe) =
    FieldType index (dealiasHelp typeTable tipe)



-- ====== DEEP DEALIAS ======


{-| Returns `tipe` with every use of an alias, at every depth, replaced by its
aliased type as `dealias` builds it, so that the result holds no `TAlias`.
Record extension variables are left as they are.
-}
deepDealias : Type Name -> Type Name
deepDealias tipe =
    case tipe of
        TLambda aid a b ->
            TLambda aid (deepDealias a) (deepDealias b)

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


{-| Returns a record field, keeping its position, with `deepDealias` applied to
its type.
-}
deepDealiasField : FieldType Name -> FieldType Name
deepDealiasField (FieldType index tipe) =
    FieldType index (deepDealias tipe)



-- ====== ITERATED DEALIAS ======


{-| Returns `tipe` with the alias at its top replaced by its aliased type, as
`dealias` builds it, repeatedly until the outermost node is not a `TAlias`.
An alias anywhere inside the result, such as in a function's argument or a
record field, is left in place.
-}
iteratedDealias : Type Name -> Type Name
iteratedDealias tipe =
    case tipe of
        TAlias _ _ args realType ->
            iteratedDealias (dealias args realType)

        _ ->
            tipe
