module TestLogic.Optimize.Typed.TypeEq exposing
    ( alphaEqStrict
    )

{-| Strict alpha-equivalence for Can.Type values.

This module provides a type comparator that enforces consistent TVar renaming,
unlike the permissive alphaEq in TypePreservation.elm which treats TVar as wildcard.

Key property: TVar only matches TVar via a consistent bidirectional mapping.
TVar does NOT match a concrete type.

This is critical for catching MONO_018-class bugs where:

    case : List Int
    branch expression has type : List a  ← Would fail strict check

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- TYPES
-- ============================================================================


{-| State for tracking consistent TVar and extension var mappings.
-}
type alias AlphaState =
    { tvarsL2R : Dict String Name.Name Name.Name
    , tvarsR2L : Dict String Name.Name Name.Name
    , extL2R : Dict String Name.Name Name.Name
    , extR2L : Dict String Name.Name Name.Name
    }


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


{-| Strict alpha-equivalence with consistent TVar renaming.

TVar only matches TVar via a consistent bidirectional mapping.
TVar does NOT match a concrete type.

-}
alphaEqStrict : Can.Type -> Can.Type -> Bool
alphaEqStrict t1 t2 =
    case alphaEqStrictHelp emptyState t1 t2 of
        Just _ ->
            True

        Nothing ->
            False



-- ============================================================================
-- CORE COMPARISON
-- ============================================================================


alphaEqStrictHelp : AlphaState -> Can.Type -> Can.Type -> Maybe AlphaState
alphaEqStrictHelp state t1 t2 =
    case ( t1, t2 ) of
        ( Can.TVar a, Can.TVar b ) ->
            -- Check/extend consistent mapping
            matchTVars state a b

        ( Can.TVar _, _ ) ->
            -- TVar does NOT match non-TVar in strict mode
            Nothing

        ( _, Can.TVar _ ) ->
            Nothing

        ( Can.TType h1 n1 args1, Can.TType h2 n2 args2 ) ->
            if canonicalTypesEqual h1 n1 h2 n2 && List.length args1 == List.length args2 then
                alphaEqStrictList state args1 args2

            else
                Nothing

        ( Can.TLambda a1 b1, Can.TLambda a2 b2 ) ->
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
            -- Unwrap with substitution and compare underlying types
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


{-| Match two TVars with consistent bidirectional mapping.
-}
matchTVars : AlphaState -> Name.Name -> Name.Name -> Maybe AlphaState
matchTVars state a b =
    case ( Dict.get identity a state.tvarsL2R, Dict.get identity b state.tvarsR2L ) of
        ( Just mappedB, Just mappedA ) ->
            -- Both already mapped; must be consistent
            if mappedB == b && mappedA == a then
                Just state

            else
                Nothing

        ( Just mappedB, Nothing ) ->
            -- a is mapped but b is not reverse-mapped
            if mappedB == b then
                Just { state | tvarsR2L = Dict.insert identity b a state.tvarsR2L }

            else
                Nothing

        ( Nothing, Just mappedA ) ->
            -- b is reverse-mapped but a is not mapped
            if mappedA == a then
                Just { state | tvarsL2R = Dict.insert identity a b state.tvarsL2R }

            else
                Nothing

        ( Nothing, Nothing ) ->
            -- Neither mapped; create new mapping
            Just
                { state
                    | tvarsL2R = Dict.insert identity a b state.tvarsL2R
                    , tvarsR2L = Dict.insert identity b a state.tvarsR2L
                }



-- ============================================================================
-- LIST COMPARISON
-- ============================================================================


alphaEqStrictList : AlphaState -> List Can.Type -> List Can.Type -> Maybe AlphaState
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


alphaEqStrictRecord :
    AlphaState
    -> Dict String Name.Name Can.FieldType
    -> Maybe Name.Name
    -> Dict String Name.Name Can.FieldType
    -> Maybe Name.Name
    -> Maybe AlphaState
alphaEqStrictRecord state fields1 ext1 fields2 ext2 =
    let
        keys1 =
            Dict.keys compare fields1

        keys2 =
            Dict.keys compare fields2
    in
    if keys1 /= keys2 then
        Nothing

    else
        -- Compare extension variables using separate ext-var mapping
        matchExtVars state ext1 ext2
            |> Maybe.andThen (\s -> alphaEqStrictFields s keys1 fields1 fields2)


matchExtVars : AlphaState -> Maybe Name.Name -> Maybe Name.Name -> Maybe AlphaState
matchExtVars state ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            Just state

        ( Just a, Just b ) ->
            -- Use same logic as TVars but with ext mappings
            case ( Dict.get identity a state.extL2R, Dict.get identity b state.extR2L ) of
                ( Just mappedB, Just mappedA ) ->
                    if mappedB == b && mappedA == a then
                        Just state

                    else
                        Nothing

                ( Just mappedB, Nothing ) ->
                    if mappedB == b then
                        Just { state | extR2L = Dict.insert identity b a state.extR2L }

                    else
                        Nothing

                ( Nothing, Just mappedA ) ->
                    if mappedA == a then
                        Just { state | extL2R = Dict.insert identity a b state.extL2R }

                    else
                        Nothing

                ( Nothing, Nothing ) ->
                    Just
                        { state
                            | extL2R = Dict.insert identity a b state.extL2R
                            , extR2L = Dict.insert identity b a state.extR2L
                        }

        _ ->
            Nothing


alphaEqStrictFields :
    AlphaState
    -> List Name.Name
    -> Dict String Name.Name Can.FieldType
    -> Dict String Name.Name Can.FieldType
    -> Maybe AlphaState
alphaEqStrictFields state keys fields1 fields2 =
    List.foldl
        (\k acc ->
            case acc of
                Nothing ->
                    Nothing

                Just s ->
                    case ( Dict.get identity k fields1, Dict.get identity k fields2 ) of
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


{-| Unwrap alias, applying argument substitutions to the body.

Critical: Canonical aliases have argument bindings that must be substituted
into the alias body before comparison.

-}
unwrapAliasWithSubst : List ( Name.Name, Can.Type ) -> Can.AliasType -> Can.Type
unwrapAliasWithSubst args aliasType =
    let
        subst =
            Dict.fromList identity args

        body =
            case aliasType of
                Can.Filled t ->
                    t

                Can.Holey t ->
                    t
    in
    applySubst subst body


applySubst : Dict String Name.Name Can.Type -> Can.Type -> Can.Type
applySubst subst tipe =
    case tipe of
        Can.TVar name ->
            case Dict.get identity name subst of
                Just replacement ->
                    replacement

                Nothing ->
                    tipe

        Can.TType home name args ->
            Can.TType home name (List.map (applySubst subst) args)

        Can.TLambda a b ->
            Can.TLambda (applySubst subst a) (applySubst subst b)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (applySubst subst t)) fields)
                ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b cs ->
            Can.TTuple (applySubst subst a) (applySubst subst b) (List.map (applySubst subst) cs)

        Can.TAlias home name args at ->
            -- Recursively apply to alias args
            Can.TAlias home name
                (List.map (\( n, t ) -> ( n, applySubst subst t )) args)
                at



-- ============================================================================
-- CANONICAL TYPE EQUALITY (RE-EXPORT HANDLING)
-- ============================================================================


{-| Check if two canonical type references are equal, handling re-exports.

In Elm, types like String can appear as both Basics.String and String.String
within the same package. For type checking, these are equivalent.

-}
canonicalTypesEqual : IO.Canonical -> String -> IO.Canonical -> String -> Bool
canonicalTypesEqual (IO.Canonical pkg1 _) name1 (IO.Canonical pkg2 _) name2 =
    pkg1 == pkg2 && name1 == name2
