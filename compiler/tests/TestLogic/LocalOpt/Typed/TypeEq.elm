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
the `r` in `{ r | x : Int }`, have a renaming of their own, kept apart from
that of ordinary type variables. So a name used both as an extension variable
and as a type variable may be paired with different variables in each role.

Some differences are not seen at all. The arrow slot a function type carries
and the indices on record fields are ignored. A named type is identified by
its package and name, not its module. An alias is compared by its body, with
its arguments substituted for the body's type variables, so its own name does
not count; the exception is an alias set against a bare type variable, which
never matches, whatever the alias's body. An argument is not substituted for a
record extension variable in the body, so an alias whose parameter is used as
one, such as `type alias R a = { a | x : Int }`, is compared with that
parameter's name left in place. An alias argument that the body does not use is
not compared at all.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict exposing (Dict)



-- ============================================================================
-- TYPES
-- ============================================================================


{-| The renaming found so far between the variables of the left type and those
of the right, kept in both directions so that it stays one-to-one.

`tvarsL2R` and `tvarsR2L` are for ordinary type variables, and `extL2R` and
`extR2L` for record extension variables.

-}
type alias AlphaState =
    { tvarsL2R : Dict Name.Name Name.Name
    , tvarsR2L : Dict Name.Name Name.Name
    , extL2R : Dict Name.Name Name.Name
    , extR2L : Dict Name.Name Name.Name
    }


{-| The renaming before any variable has been paired.
-}
emptyState : AlphaState
emptyState =
    { tvarsL2R = Dict.empty
    , tvarsR2L = Dict.empty
    , extL2R = Dict.empty
    , extR2L = Dict.empty
    }



-- ============================================================================
-- MAIN FUNCTION
-- ============================================================================


{-| Returns whether `t1` and `t2` are alpha-equivalent: whether a one-to-one
renaming of type variables, held across every part of the types that is
compared, turns one into the other. Record extension variables are renamed
separately from ordinary type variables, so the renaming is one-to-one within
each kind, not across them.

A type variable never matches a concrete type. Its name is not inspected, so a
constrained variable such as `number` can be paired with an unconstrained one
such as `a`. Arrow slots, record field indices, the module of a named type and
the name of an alias are ignored. An alias is compared by its body, except
that an alias against a bare type variable is never a match. Alias arguments
are not substituted into record extension variables in the body. An alias
argument its body does not use is ignored.

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

The type-variable cases come before the alias cases, so an alias against a
bare type variable fails without its body being looked at. Two non-alias
types with different outer shapes, such as a tuple against a record, fail.

-}
alphaEqStrictHelp : AlphaState -> Can.Type Name -> Can.Type Name -> Maybe AlphaState
alphaEqStrictHelp state t1 t2 =
    case ( t1, t2 ) of
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

        ( Can.TAlias _ _ args1 at1, Can.TAlias _ _ args2 at2 ) ->
            let
                body1 =
                    unwrapAliasWithSubst args1 at1

                body2 =
                    unwrapAliasWithSubst args2 at2
            in
            alphaEqStrictHelp state body1 body2

        ( Can.TAlias _ _ args at, other ) ->
            alphaEqStrictHelp state (unwrapAliasWithSubst args at) other

        ( other, Can.TAlias _ _ args at ) ->
            alphaEqStrictHelp state other (unwrapAliasWithSubst args at)

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


{-| Pairs the extension variables of two records as `matchTVars` pairs type
variables, but in the renaming kept for extension variables. Two closed
records match with the renaming unchanged; an open record never matches a
closed one.
-}
matchExtVars : AlphaState -> Maybe Name.Name -> Maybe Name.Name -> Maybe AlphaState
matchExtVars state ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            Just state

        ( Just a, Just b ) ->
            case ( Dict.get a state.extL2R, Dict.get b state.extR2L ) of
                ( Just mappedB, Just mappedA ) ->
                    if mappedB == b && mappedA == a then
                        Just state

                    else
                        Nothing

                ( Just mappedB, Nothing ) ->
                    if mappedB == b then
                        Just { state | extR2L = Dict.insert b a state.extR2L }

                    else
                        Nothing

                ( Nothing, Just mappedA ) ->
                    if mappedA == a then
                        Just { state | extL2R = Dict.insert a b state.extL2R }

                    else
                        Nothing

                ( Nothing, Nothing ) ->
                    Just
                        { state
                            | extL2R = Dict.insert a b state.extL2R
                            , extR2L = Dict.insert b a state.extR2L
                        }

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


{-| Returns the body of an alias with each of its parameters replaced by the
argument `args` pairs it with.

The substitution is applied to a `Filled` body as well as a `Holey` one. It
does not reach a record's extension variable.

-}
unwrapAliasWithSubst : List ( Name.Name, Can.Type Name ) -> Can.AliasType Name -> Can.Type Name
unwrapAliasWithSubst args aliasType =
    let
        subst =
            Dict.fromList args

        body =
            case aliasType of
                Can.Filled t ->
                    t

                Can.Holey t ->
                    t
    in
    applySubst subst body


{-| Returns `tipe` with every type variable named in `subst` replaced by the
type it maps to, in one pass, so a replacement is not itself substituted
into.

A record's extension variable is left as it is. A function type is rebuilt
with no arrow slot, and an alias keeps its body untouched while its arguments
are substituted.

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
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (applySubst subst t)) fields)
                ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b cs ->
            Can.TTuple (applySubst subst a) (applySubst subst b) (List.map (applySubst subst) cs)

        Can.TAlias home name args at ->
            Can.TAlias home
                name
                (List.map (\( n, t ) -> ( n, applySubst subst t )) args)
                at



-- ============================================================================
-- CANONICAL TYPE EQUALITY
-- ============================================================================


{-| Returns whether two named types, each given as its home module and name,
are the same for this comparison: same package and same name.

The module within the package is ignored, so two different types that share a
name in two modules of one package compare equal.

-}
canonicalTypesEqual : ModuleName.Canonical -> String -> ModuleName.Canonical -> String -> Bool
canonicalTypesEqual (ModuleName.Canonical pkg1 _) name1 (ModuleName.Canonical pkg2 _) name2 =
    pkg1 == pkg2 && name1 == name2
