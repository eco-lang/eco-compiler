module TestLogic.LocalOpt.Typed.TypeEq exposing (alphaEqStrict)

{-| Two canonical types that differ only in the names of their type variables
describe the same thing, so `==` is too strict a test of whether two types
agree, while a comparison that lets a type variable match anything is too
loose. This module provides the comparison in between, `alphaEqStrict`.

Two types are _alpha-equivalent_ when one becomes the other by renaming its
type variables, so `a -> b` and `x -> y` are, but `a -> a` and `x -> y` are not.
The renaming must be one-to-one within each kind of variable: each type
variable on the left stands for one type variable on the right throughout the
parts of the types that are compared, and the reverse. A type variable matches
only another type variable, never a concrete type. That is what lets a check
catch a case expression typed `List Int` with a branch typed `List a`, which a
comparison where a variable matches anything would accept.

The comparison walks both types together, carrying the renaming found so far
from one part of the type to the next. Record extension variables, such as
the `r` in `{ r | x : Int }`, share that renaming with ordinary type
variables: a name used in both roles is one variable.

Some differences are not seen at all. The arrow slot a function type carries
and the indices on record fields are ignored. A named type is identified by
its home (package and module) and name. Aliases are transparent, as they are
to Elm's type checker: an alias is compared by its expansion, so its own name
does not count, and an alias argument that its body does not use (a phantom
parameter) is not compared, since `Tagged Int` and `Tagged String` are the same
type when `type alias Tagged a = Int`. A `Holey` alias body has the arguments
substituted for its parameters, record extension variables included; a
`Filled` body is already expanded and is used as it is.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict exposing (Dict)



-- ============================================================================
-- TYPES
-- ============================================================================


{-| The renaming found so far between the variables of the left type and those
of the right, kept in both directions so that it stays one-to-one. It covers
ordinary type variables and record extension variables alike.
-}
type alias AlphaState =
    { tvarsL2R : Dict Name.Name Name.Name
    , tvarsR2L : Dict Name.Name Name.Name
    }


{-| The renaming before any variable has been paired.
-}
emptyState : AlphaState
emptyState =
    { tvarsL2R = Dict.empty
    , tvarsR2L = Dict.empty
    }



-- ============================================================================
-- MAIN FUNCTION
-- ============================================================================


{-| Returns whether `t1` and `t2` are alpha-equivalent: whether a one-to-one
renaming of type variables, record extension variables included, held across
every part of the types that is compared, turns one into the other.

A type variable never matches a concrete type. Its name is not inspected, so a
constrained variable such as `number` can be paired with an unconstrained one
such as `a`. Arrow slots, record field indices and the name of an alias are
ignored: an alias is compared by its expansion, so an alias argument its body
does not use is ignored too.

-}
alphaEqStrict : Can.Type Name -> Can.Type Name -> Bool
alphaEqStrict t1 t2 =
    case alphaEqStrictHelp emptyState t1 t2 of
        Just _ ->
            True

        Nothing ->
            False



-- ============================================================================
-- CORE COMPARISON
-- ============================================================================


{-| Returns the renaming `state` extended by what makes `t1` and `t2`
alpha-equivalent, or `Nothing` if no extension does.

The alias cases come first, so an alias is expanded before anything else is
compared, even against a bare type variable. Two non-alias types with different
outer shapes, such as a tuple against a record, fail.

-}
alphaEqStrictHelp : AlphaState -> Can.Type Name -> Can.Type Name -> Maybe AlphaState
alphaEqStrictHelp state t1 t2 =
    case ( t1, t2 ) of
        ( Can.TAlias _ _ args1 at1, _ ) ->
            alphaEqStrictHelp state (unwrapAliasWithSubst args1 at1) t2

        ( _, Can.TAlias _ _ args2 at2 ) ->
            alphaEqStrictHelp state t1 (unwrapAliasWithSubst args2 at2)

        ( Can.TVar a, Can.TVar b ) ->
            matchTVars state a b

        ( Can.TVar _, _ ) ->
            Nothing

        ( _, Can.TVar _ ) ->
            Nothing

        ( Can.TType h1 n1 args1, Can.TType h2 n2 args2 ) ->
            if canonicalTypesEqual h1 n1 h2 n2 && List.length args1 == List.length args2 then
                alphaEqStrictList state args1 args2

            else
                Nothing

        ( Can.TLambda _ a1 b1, Can.TLambda _ a2 b2 ) ->
            alphaEqStrictHelp state a1 a2
                |> Maybe.andThen (\s -> alphaEqStrictHelp s b1 b2)

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            alphaEqStrictRecord state fields1 ext1 fields2 ext2

        ( Can.TUnit, Can.TUnit ) ->
            Just state

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            if List.length cs1 == List.length cs2 then
                alphaEqStrictHelp state a1 a2
                    |> Maybe.andThen (\s -> alphaEqStrictHelp s b1 b2)
                    |> Maybe.andThen (\s -> alphaEqStrictList s cs1 cs2)

            else
                Nothing

        _ ->
            Nothing



-- ============================================================================
-- TVAR CONSISTENT MAPPING
-- ============================================================================


{-| Pairs type variable `a` on the left with `b` on the right, returning the
extended renaming, or `Nothing` if either is already paired with a different
variable.
-}
matchTVars : AlphaState -> Name.Name -> Name.Name -> Maybe AlphaState
matchTVars state a b =
    case ( Dict.get a state.tvarsL2R, Dict.get b state.tvarsR2L ) of
        ( Just mappedB, Just mappedA ) ->
            if mappedB == b && mappedA == a then
                Just state

            else
                Nothing

        ( Just mappedB, Nothing ) ->
            if mappedB == b then
                Just { state | tvarsR2L = Dict.insert b a state.tvarsR2L }

            else
                Nothing

        ( Nothing, Just mappedA ) ->
            if mappedA == a then
                Just { state | tvarsL2R = Dict.insert a b state.tvarsL2R }

            else
                Nothing

        ( Nothing, Nothing ) ->
            Just
                { state
                    | tvarsL2R = Dict.insert a b state.tvarsL2R
                    , tvarsR2L = Dict.insert b a state.tvarsR2L
                }



-- ============================================================================
-- LIST COMPARISON
-- ============================================================================


{-| Returns `state` extended by pairing `ts1` with `ts2` element by element, or
`Nothing` if any pair fails or the lengths differ.
-}
alphaEqStrictList : AlphaState -> List (Can.Type Name) -> List (Can.Type Name) -> Maybe AlphaState
alphaEqStrictList state ts1 ts2 =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            Just state

        ( t1 :: rest1, t2 :: rest2 ) ->
            alphaEqStrictHelp state t1 t2
                |> Maybe.andThen (\s -> alphaEqStrictList s rest1 rest2)

        _ ->
            Nothing



-- ============================================================================
-- RECORD COMPARISON
-- ============================================================================


{-| Returns `state` extended by what makes two record types, given as their
fields and extension variables, alpha-equivalent, or `Nothing` if no extension
does.

They must have the same field names and both be open or both closed. The
extension variables are paired first, then the field types are compared in
field-name order. Field indices are ignored.

-}
alphaEqStrictRecord :
    AlphaState
    -> Dict Name.Name (Can.FieldType Name)
    -> Maybe Name.Name
    -> Dict Name.Name (Can.FieldType Name)
    -> Maybe Name.Name
    -> Maybe AlphaState
alphaEqStrictRecord state fields1 ext1 fields2 ext2 =
    let
        keys1 =
            Dict.keys fields1

        keys2 =
            Dict.keys fields2
    in
    if keys1 /= keys2 then
        Nothing

    else
        matchExtVars state ext1 ext2
            |> Maybe.andThen (\s -> alphaEqStrictFields s keys1 fields1 fields2)


{-| Pairs the extension variables of two records with `matchTVars`, in the
renaming ordinary type variables use. Two closed records match with the
renaming unchanged; an open record never matches a closed one.
-}
matchExtVars : AlphaState -> Maybe Name.Name -> Maybe Name.Name -> Maybe AlphaState
matchExtVars state ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            Just state

        ( Just a, Just b ) ->
            matchTVars state a b

        _ ->
            Nothing


{-| Returns `state` extended by comparing the types of the fields named in
`keys` in `fields1` and `fields2`, in the order of `keys`, or `Nothing` if any
comparison fails or a key is missing from either record.
-}
alphaEqStrictFields :
    AlphaState
    -> List Name.Name
    -> Dict Name.Name (Can.FieldType Name)
    -> Dict Name.Name (Can.FieldType Name)
    -> Maybe AlphaState
alphaEqStrictFields state keys fields1 fields2 =
    List.foldl
        (\k acc ->
            case acc of
                Nothing ->
                    Nothing

                Just s ->
                    case ( Dict.get k fields1, Dict.get k fields2 ) of
                        ( Just (Can.FieldType _ t1), Just (Can.FieldType _ t2) ) ->
                            alphaEqStrictHelp s t1 t2

                        _ ->
                            Nothing
        )
        (Just state)
        keys



-- ============================================================================
-- ALIAS UNWRAPPING WITH SUBSTITUTION
-- ============================================================================


{-| Returns the expansion of an alias: a `Holey` body with each of its
parameters replaced by the argument `args` pairs it with, or a `Filled` body,
which already has the arguments in place, as it is.
-}
unwrapAliasWithSubst : List ( Name.Name, Can.Type Name ) -> Can.AliasType Name -> Can.Type Name
unwrapAliasWithSubst args aliasType =
    case aliasType of
        Can.Filled t ->
            t

        Can.Holey t ->
            applySubst (Dict.fromList args) t


{-| Returns `tipe` with every type variable named in `subst` replaced by the
type it maps to, in one pass, so a replacement is not itself substituted
into.

A record's extension variable named in `subst` is replaced as
`substituteExtension` describes. A function type is rebuilt with no arrow
slot, and an alias keeps its body untouched while its arguments are
substituted.

-}
applySubst : Dict Name.Name (Can.Type Name) -> Can.Type Name -> Can.Type Name
applySubst subst tipe =
    case tipe of
        Can.TVar name ->
            case Dict.get name subst of
                Just replacement ->
                    replacement

                Nothing ->
                    tipe

        Can.TType home name args ->
            Can.TType home name (List.map (applySubst subst) args)

        Can.TLambda _ a b ->
            Can.tLambda (applySubst subst a) (applySubst subst b)

        Can.TRecord fields ext ->
            let
                substFields =
                    Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (applySubst subst t)) fields
            in
            case ext of
                Just extName ->
                    case Dict.get extName subst of
                        Just replacement ->
                            substituteExtension substFields extName replacement

                        Nothing ->
                            Can.TRecord substFields ext

                Nothing ->
                    Can.TRecord substFields Nothing

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b cs ->
            Can.TTuple (applySubst subst a) (applySubst subst b) (List.map (applySubst subst) cs)

        Can.TAlias home name args at ->
            Can.TAlias home
                name
                (List.map (\( n, t ) -> ( n, applySubst subst t )) args)
                at


{-| Returns the record `{ ext | fields }` with the type `replacement` put in
place of its extension variable `ext`. A record replacement contributes its
fields and its own extension variable, a type variable becomes the new
extension variable, and an alias is expanded first. Any other replacement
cannot stand for a record; the record is then returned with `ext` unchanged.
-}
substituteExtension : Dict Name.Name (Can.FieldType Name) -> Name.Name -> Can.Type Name -> Can.Type Name
substituteExtension fields ext replacement =
    case replacement of
        Can.TRecord moreFields moreExt ->
            Can.TRecord (Dict.union fields moreFields) moreExt

        Can.TVar n ->
            Can.TRecord fields (Just n)

        Can.TAlias _ _ args at ->
            substituteExtension fields ext (unwrapAliasWithSubst args at)

        _ ->
            Can.TRecord fields (Just ext)



-- ============================================================================
-- CANONICAL TYPE EQUALITY
-- ============================================================================


{-| Returns whether two named types, each given as its home module and name,
are the same: same package, same module and same name.
-}
canonicalTypesEqual : ModuleName.Canonical -> String -> ModuleName.Canonical -> String -> Bool
canonicalTypesEqual home1 name1 home2 name2 =
    home1 == home2 && name1 == name2
