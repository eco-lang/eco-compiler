module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst
    , canTypeToMonoType
    , unify, unifyFuncCall, extractParamTypes
    )

{-| Type substitution and unification for monomorphization.

This module handles converting canonical types to monomorphic types
by applying type variable substitutions.


# Substitution

@docs applySubst


# Type Conversion

@docs canTypeToMonoType


# Unification

@docs unify, unifyFuncCall, extractParamTypes

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Generate.MLIR.Types as Types
import Compiler.Monomorphize.State exposing (Substitution)
import Data.Map as Dict
import System.TypeCheck.IO as IO


{-| Unify a function call by matching argument types and result type.
-}
unifyFuncCall :
    Can.Type
    -> List Mono.MonoType
    -> Can.Type
    -> Substitution
    -> Substitution
unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst =
    let
        subst1 =
            unifyArgsOnly funcCanType argMonoTypes baseSubst

        desiredResultMono =
            applySubst subst1 resultCanType

        desiredFuncMono =
            Mono.MFunction argMonoTypes desiredResultMono
    in
    unifyHelp funcCanType desiredFuncMono subst1


{-| Unify a canonical type with a monomorphic type to produce a substitution for type variables.
-}
unify : Can.Type -> Mono.MonoType -> Substitution
unify canType monoType =
    unifyHelp canType monoType Dict.empty


{-| Helper for unification that extends an existing substitution.
-}
unifyHelp : Can.Type -> Mono.MonoType -> Substitution -> Substitution
unifyHelp canType monoType subst =
    case ( canType, monoType ) of
        ( Can.TVar name, _ ) ->
            Dict.insert identity name monoType subst

        -- Handle primitive types from elm/core that map to specialized MonoTypes
        ( Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Int" [], Mono.MInt ) ->
            subst

        ( Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Float" [], Mono.MFloat ) ->
            subst

        ( Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Bool" [], Mono.MBool ) ->
            subst

        ( Can.TType (IO.Canonical ( "elm", "core" ) "Char") "Char" [], Mono.MChar ) ->
            subst

        ( Can.TType (IO.Canonical ( "elm", "core" ) "String") "String" [], Mono.MString ) ->
            subst

        ( Can.TLambda from to, Mono.MFunction args ret ) ->
            case args of
                [] ->
                    subst

                firstArg :: restArgs ->
                    let
                        subst1 =
                            unifyHelp from firstArg subst
                    in
                    if List.isEmpty restArgs then
                        unifyHelp to ret subst1

                    else
                        unifyHelp to (Mono.MFunction restArgs ret) subst1

        ( Can.TType _ _ args, Mono.MCustom _ _ monoArgs ) ->
            List.foldl
                (\( canArg, monoArg ) s ->
                    unifyHelp canArg monoArg s
                )
                subst
                (List.map2 Tuple.pair args monoArgs)

        ( Can.TType _ _ args, Mono.MList innerType ) ->
            case args of
                [ elemType ] ->
                    unifyHelp elemType innerType subst

                _ ->
                    subst

        ( Can.TRecord fields maybeExtension, Mono.MRecord monoFields ) ->
            let
                -- First unify matching fields
                substWithFields =
                    Dict.foldl compare
                        (\fieldName monoFieldType s ->
                            case Dict.get identity fieldName fields of
                                Just (Can.FieldType _ fieldType) ->
                                    unifyHelp fieldType monoFieldType s

                                Nothing ->
                                    s
                        )
                        subst
                        monoFields
            in
            case maybeExtension of
                Just extName ->
                    let
                        -- Fields in monoFields that are not in the canonical record
                        remainingFields =
                            Dict.filter
                                (\fieldName _ -> Dict.get identity fieldName fields == Nothing)
                                monoFields
                    in
                    Dict.insert identity extName (Mono.MRecord remainingFields) substWithFields

                Nothing ->
                    substWithFields

        ( Can.TTuple a b rest, Mono.MTuple monoTypes ) ->
            let
                canTypes =
                    a :: b :: rest
            in
            List.foldl
                (\( canT, monoT ) s ->
                    unifyHelp canT monoT s
                )
                subst
                (List.map2 Tuple.pair canTypes monoTypes)

        ( Can.TAlias _ _ _ (Can.Filled inner), _ ) ->
            unifyHelp inner monoType subst

        ( Can.TAlias _ _ args (Can.Holey inner), _ ) ->
            let
                argSubst =
                    List.foldl
                        (\( _, t ) s ->
                            unifyHelp t (applySubst s t) s
                        )
                        subst
                        args
            in
            unifyHelp inner monoType argSubst

        _ ->
            subst


{-| Unify function arguments only, ignoring the result type.
-}
unifyArgsOnly : Can.Type -> List Mono.MonoType -> Substitution -> Substitution
unifyArgsOnly canFuncType argTypes subst =
    case ( canFuncType, argTypes ) of
        ( _, [] ) ->
            subst

        ( Can.TLambda from to, arg0 :: rest ) ->
            let
                subst1 =
                    unifyHelp from arg0 subst
            in
            unifyArgsOnly to rest subst1

        -- If we run out of lambdas or mismatch shape, just stop.
        _ ->
            subst


{-| Extract parameter types from a MFunction type.
When we have a function type MFunction [arg1, arg2, ...] returnType,
this extracts the list of argument types [arg1, arg2, ...].
For non-function types, returns an empty list.
-}
extractParamTypes : Mono.MonoType -> List Mono.MonoType
extractParamTypes monoType =
    -- For curried functions, recursively extract all param types.
    -- E.g., (a -> x) -> (a, b) -> (x, b) is MFunction [funcType] (MFunction [tupleType] result)
    -- and we need to return [funcType, tupleType]
    case monoType of
        Mono.MFunction argTypes returnType ->
            argTypes ++ extractParamTypes returnType

        _ ->
            []


{-| Apply a type substitution to a canonical type to produce a monomorphic type.
-}
applySubst : Substitution -> Can.Type -> Mono.MonoType
applySubst subst canType =
    case canType of
        Can.TVar name ->
            case Dict.get identity name subst of
                Just monoType ->
                    monoType

                Nothing ->
                    let
                        constraint =
                            constraintFromName name
                    in
                    case constraint of
                        Mono.CNumber ->
                            -- If a number typeclass has not been resolved, we use MInt in the belief that
                            -- this is safe, since only int literals can remain polymorphic at runtime, float
                            -- literals already all are Float.
                            -- TODO: Record the above as an invariant.
                            Mono.MInt

                        Mono.CEcoValue ->
                            -- Truly polymorphic type variable - keep as MVar
                            Mono.MVar name constraint

        Can.TLambda from to ->
            let
                argMono =
                    applySubst subst from

                resultMono =
                    applySubst subst to
            in
            Mono.MFunction [ argMono ] resultMono

        Can.TType canonical name args ->
            let
                monoArgs =
                    List.map (applySubst subst) args

                isElmCore =
                    case canonical of
                        IO.Canonical ( "elm", "core" ) _ ->
                            True

                        _ ->
                            False
            in
            if isElmCore then
                case name of
                    "Int" ->
                        Mono.MInt

                    "Float" ->
                        Mono.MFloat

                    "Bool" ->
                        Mono.MBool

                    "Char" ->
                        Mono.MChar

                    "String" ->
                        Mono.MString

                    "List" ->
                        case monoArgs of
                            [ inner ] ->
                                Mono.MList inner

                            _ ->
                                Mono.MList Mono.MUnit

                    _ ->
                        -- Custom type from elm/core
                        Mono.MCustom canonical name monoArgs

            else
                -- Custom type
                Mono.MCustom canonical name monoArgs

        Can.TRecord fields maybeExtension ->
            let
                -- Get base fields from extension variable if present
                baseFields =
                    case maybeExtension of
                        Just extName ->
                            case Dict.get identity extName subst of
                                Just (Mono.MRecord baseFieldsDict) ->
                                    -- MRecord now directly contains the fields dict
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                -- Convert explicit fields to mono types
                extensionFields =
                    Dict.map (\_ (Can.FieldType _ t) -> applySubst subst t) fields

                -- Merge: extension fields override base fields
                monoFields =
                    Dict.union extensionFields baseFields
            in
            Mono.MRecord monoFields

        Can.TTuple a b rest ->
            let
                monoTypes =
                    List.map (applySubst subst) (a :: b :: rest)
            in
            Mono.MTuple monoTypes

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            applySubst subst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                newSubst =
                    List.foldl
                        (\( varName, t ) s ->
                            Dict.insert identity varName (applySubst subst t) s
                        )
                        subst
                        args
            in
            applySubst newSubst inner


{-| Convert a canonical type to a monomorphic type using a substitution.
This is an alias for applySubst.
-}
canTypeToMonoType : Substitution -> Can.Type -> Mono.MonoType
canTypeToMonoType =
    applySubst


{-| Derive a constraint from a type variable name.
-}
constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber

    else
        Mono.CEcoValue
