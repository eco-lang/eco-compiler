module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst, applyReverseRenaming
    , canTypeToMonoType, constraintFromName, collectCanTypeVars
    , unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, extractParamTypes
    , buildSchemeInfo
    , lookupConstraint
    )

{-| Type substitution and unification for monomorphization.

This module handles converting canonical types to monomorphic types
by applying type variable substitutions.


# Substitution

@docs applySubst, applyReverseRenaming


# Type Conversion

@docs canTypeToMonoType, constraintFromName, collectCanTypeVars


# Unification

@docs unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, extractParamTypes


# Scheme Construction

@docs buildSchemeInfo


# Query

@docs lookupConstraint

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Monomorphize.State as State exposing (MVarEnv, SchemeInfo, Substitution)
import Data.Map
import Dict
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Tuple


{-| Look up the constraint for a tvar name via the MVarEnv.
Falls back to constraintFromName if the name is not registered.
-}
lookupConstraint : MVarEnv -> Name -> Mono.Constraint
lookupConstraint env name =
    constraintFromName name



-- INTERNAL HELPERS: changed-flag mapping, union-find, normalized insertion


listMapChanged :
    (a -> ( Bool, a ))
    -> List a
    -> ( Bool, List a )
listMapChanged f list =
    listMapChangedHelp f list list False []


listMapChangedHelp : (a -> ( Bool, a )) -> List a -> List a -> Bool -> List a -> ( Bool, List a )
listMapChangedHelp f remaining original anyChanged acc =
    case remaining of
        [] ->
            if anyChanged then
                ( True, List.reverse acc )

            else
                ( False, original )

        x :: xs ->
            let
                ( changed, newX ) =
                    f x
            in
            listMapChangedHelp f xs original (anyChanged || changed) (newX :: acc)


dictMapChanged :
    (v -> ( Bool, v ))
    -> Dict.Dict Name v
    -> ( Bool, Dict.Dict Name v )
dictMapChanged f dict =
    let
        fold key val accPair =
            let
                ( valChanged, newVal ) =
                    f val
            in
            if valChanged then
                ( True, Dict.insert key newVal (Tuple.second accPair) )

            else
                accPair
    in
    case Dict.foldl fold ( False, dict ) dict of
        ( True, newDict ) ->
            ( True, newDict )

        _ ->
            ( False, dict )


findRootVar : MVarEnv -> Name -> Substitution -> ( Name, Substitution, MVarEnv )
findRootVar env name subst =
    findRootVarHelp env Set.empty name subst


findRootVarHelp : MVarEnv -> Set Name -> Name -> Substitution -> ( Name, Substitution, MVarEnv )
findRootVarHelp env visited name subst =
    case Dict.get name subst of
        Just (Mono.MVar mvarId _) ->
            let
                parentName =
                    State.lookupMVarName mvarId env
                        |> Maybe.withDefault name
            in
            if parentName == name || Set.member parentName visited then
                ( name, subst, env )

            else
                let
                    ( root, subst1, env1 ) =
                        findRootVarHelp env (Set.insert name visited) parentName subst
                in
                if root == parentName then
                    ( root, subst1, env1 )

                else
                    -- Path compression: point name directly to root
                    let
                        ( rootMVarId, env2 ) =
                            State.allocMVar root env1
                    in
                    ( root
                    , Dict.insert name
                        (Mono.MVar rootMVarId (constraintFromName root))
                        subst1
                    , env2
                    )

        _ ->
            ( name, subst, env )


normalizeMonoType : MVarEnv -> Substitution -> Mono.MonoType -> ( Mono.MonoType, Substitution, MVarEnv )
normalizeMonoType env subst ty =
    case ty of
        Mono.MVar mvarId _ ->
            let
                varName =
                    State.lookupMVarName mvarId env
                        |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId))

                ( root, subst1, env1 ) =
                    findRootVar env varName subst
            in
            if root == varName then
                ( ty, subst1, env1 )

            else
                let
                    ( rootMVarId, env2 ) =
                        State.allocMVar root env1
                in
                ( Mono.MVar rootMVarId (constraintFromName root), subst1, env2 )

        Mono.MFunction args ret ->
            let
                ( argsNorm, subst1, env1 ) =
                    normalizeList env subst args

                ( retNorm, subst2, env2 ) =
                    normalizeMonoType env1 subst1 ret
            in
            ( Mono.MFunction argsNorm retNorm, subst2, env2 )

        Mono.MList inner ->
            let
                ( innerNorm, subst1, env1 ) =
                    normalizeMonoType env subst inner
            in
            ( Mono.MList innerNorm, subst1, env1 )

        Mono.MTuple elems ->
            let
                ( elemsNorm, subst1, env1 ) =
                    normalizeList env subst elems
            in
            ( Mono.MTuple elemsNorm, subst1, env1 )

        Mono.MRecord fields ->
            let
                ( fieldsNorm, subst1, env1 ) =
                    Dict.foldl
                        (\k v ( accFields, s, e ) ->
                            let
                                ( vNorm, s1, e1 ) =
                                    normalizeMonoType e s v
                            in
                            ( Dict.insert k vNorm accFields, s1, e1 )
                        )
                        ( Dict.empty, subst, env )
                        fields
            in
            ( Mono.MRecord fieldsNorm, subst1, env1 )

        Mono.MCustom can name args ->
            let
                ( argsNorm, subst1, env1 ) =
                    normalizeList env subst args
            in
            ( Mono.MCustom can name argsNorm, subst1, env1 )

        _ ->
            ( ty, subst, env )


normalizeList : MVarEnv -> Substitution -> List Mono.MonoType -> ( List Mono.MonoType, Substitution, MVarEnv )
normalizeList env subst types =
    List.foldr
        (\t ( acc, s, e ) ->
            let
                ( tNorm, s1, e1 ) =
                    normalizeMonoType e s t
            in
            ( tNorm :: acc, s1, e1 )
        )
        ( [], subst, env )
        types


insertBinding : MVarEnv -> Name -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
insertBinding env name ty subst =
    let
        ( normalizedTy, subst1, env1 ) =
            normalizeMonoType env subst ty
    in
    ( Dict.insert name normalizedTy subst1, env1 )


{-| Unify a canonical type with a monomorphic type to produce a substitution for type variables.
-}
unify : MVarEnv -> Can.Type Name -> Mono.MonoType -> ( Substitution, MVarEnv )
unify env canType monoType =
    unifyHelp env canType monoType Dict.empty


{-| Extend an existing substitution by unifying a canonical type with a monomorphic type.
Like `unify`, but starts from `baseSubst` instead of an empty substitution.
-}
unifyExtend : MVarEnv -> Can.Type Name -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyExtend env canType monoType baseSubst =
    unifyHelp env canType monoType baseSubst


{-| Helper for unification that extends an existing substitution.
-}
unifyHelp : MVarEnv -> Can.Type Name -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyHelp env canType monoType subst =
    case ( canType, monoType ) of
        ( Can.TVar name, _ ) ->
            case Dict.get name subst of
                Just existingMono ->
                    let
                        ( substWithTransitives, env1 ) =
                            unifyMonoMono env existingMono monoType subst
                    in
                    insertBindingSafe env1 name monoType substWithTransitives

                Nothing ->
                    insertBindingSafe env name monoType subst

        -- Handle primitive types from elm/core that map to specialized MonoTypes
        ( Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Int" [], Mono.MInt ) ->
            ( subst, env )

        ( Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Float" [], Mono.MFloat ) ->
            ( subst, env )

        ( Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Bool" [], Mono.MBool ) ->
            ( subst, env )

        ( Can.TType (IO.Canonical ( "elm", "core" ) "Char") "Char" [], Mono.MChar ) ->
            ( subst, env )

        ( Can.TType (IO.Canonical ( "elm", "core" ) "String") "String" [], Mono.MString ) ->
            ( subst, env )

        ( Can.TLambda from to, Mono.MFunction args ret ) ->
            case args of
                [] ->
                    ( subst, env )

                firstArg :: restArgs ->
                    let
                        ( subst1, env1 ) =
                            unifyHelp env from firstArg subst
                    in
                    if List.isEmpty restArgs then
                        unifyHelp env1 to ret subst1

                    else
                        unifyHelp env1 to (Mono.MFunction restArgs ret) subst1

        ( Can.TType _ _ args, Mono.MCustom _ _ monoArgs ) ->
            List.foldl
                (\( canArg, monoArg ) ( s, e ) ->
                    unifyHelp e canArg monoArg s
                )
                ( subst, env )
                (List.map2 Tuple.pair args monoArgs)

        ( Can.TType _ _ args, Mono.MList innerType ) ->
            case args of
                [ elemType ] ->
                    unifyHelp env elemType innerType subst

                _ ->
                    ( subst, env )

        ( Can.TRecord fields maybeExtension, Mono.MRecord monoFields ) ->
            let
                -- First unify matching fields
                ( substWithFields, env1 ) =
                    Dict.foldl
                        (\fieldName monoFieldType ( s, e ) ->
                            case Dict.get fieldName fields of
                                Just (Can.FieldType _ fieldType) ->
                                    unifyHelp e fieldType monoFieldType s

                                Nothing ->
                                    ( s, e )
                        )
                        ( subst, env )
                        monoFields
            in
            case maybeExtension of
                Just extName ->
                    let
                        -- Fields in monoFields that are not in the canonical record
                        remainingFields =
                            Dict.diff monoFields fields
                    in
                    insertBinding env1 extName (Mono.MRecord remainingFields) substWithFields

                Nothing ->
                    ( substWithFields, env1 )

        ( Can.TTuple a b rest, Mono.MTuple monoTypes ) ->
            let
                canTypes =
                    a :: b :: rest
            in
            List.foldl
                (\( canT, monoT ) ( s, e ) ->
                    unifyHelp e canT monoT s
                )
                ( subst, env )
                (List.map2 Tuple.pair canTypes monoTypes)

        ( Can.TAlias _ _ _ (Can.Filled inner), _ ) ->
            unifyHelp env inner monoType subst

        ( Can.TAlias _ _ args (Can.Holey inner), _ ) ->
            let
                ( argSubst, env1 ) =
                    List.foldl
                        (\( _, t ) ( s, e ) ->
                            let
                                ( monoT, e1 ) =
                                    applySubst e s t
                            in
                            unifyHelp e1 t monoT s
                        )
                        ( subst, env )
                        args
            in
            unifyHelp env1 inner monoType argSubst

        _ ->
            ( subst, env )


{-| Propagate transitive bindings between two MonoTypes.

When a type variable is re-bound from one MonoType to another,
this function ensures that any MVar references in the old binding
get transitively resolved. For example, if `c` was bound to `MVar "a"`
and is now bound to `MInt`, this adds `a → MInt` to the substitution.

-}
unifyMonoMono : MVarEnv -> Mono.MonoType -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyMonoMono env m1 m2 subst =
    case ( m1, m2 ) of
        ( Mono.MVar mvarId1 _, Mono.MVar mvarId2 _ ) ->
            let
                name1 =
                    State.lookupMVarName mvarId1 env |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId1))

                name2 =
                    State.lookupMVarName mvarId2 env |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId2))
            in
            if name1 == name2 then
                ( subst, env )

            else
                insertBinding env name1 m2 subst

        ( Mono.MVar mvarId _, _ ) ->
            let
                name =
                    State.lookupMVarName mvarId env |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId))
            in
            insertBinding env name m2 subst

        ( _, Mono.MVar mvarId _ ) ->
            let
                name =
                    State.lookupMVarName mvarId env |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId))
            in
            insertBinding env name m1 subst

        ( Mono.MFunction args1 ret1, Mono.MFunction args2 ret2 ) ->
            let
                ( substWithArgs, env1 ) =
                    List.foldl
                        (\( a1, a2 ) ( s, e ) -> unifyMonoMono e a1 a2 s)
                        ( subst, env )
                        (List.map2 Tuple.pair args1 args2)
            in
            unifyMonoMono env1 ret1 ret2 substWithArgs

        ( Mono.MList inner1, Mono.MList inner2 ) ->
            unifyMonoMono env inner1 inner2 subst

        ( Mono.MCustom _ _ args1, Mono.MCustom _ _ args2 ) ->
            List.foldl
                (\( a1, a2 ) ( s, e ) -> unifyMonoMono e a1 a2 s)
                ( subst, env )
                (List.map2 Tuple.pair args1 args2)

        _ ->
            ( subst, env )


{-| Unify function arguments only, ignoring the result type.
-}
unifyArgsOnly : MVarEnv -> Can.Type Name -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyArgsOnly env canFuncType argTypes subst =
    case ( canFuncType, argTypes ) of
        ( _, [] ) ->
            ( subst, env )

        -- Fast path: single argument (most common for curried Elm)
        ( Can.TLambda from _, [ singleArg ] ) ->
            unifyHelp env from singleArg subst

        ( Can.TLambda from to, arg0 :: rest ) ->
            let
                ( subst1, env1 ) =
                    unifyHelp env from arg0 subst
            in
            unifyArgsOnly env1 to rest subst1

        -- If we run out of lambdas or mismatch shape, just stop.
        _ ->
            ( subst, env )


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


{-| Resolve MVar references in a MonoType using a substitution.
When a MonoType contains MVar "a" CEcoValue, and the substitution maps "a" → MInt,
replace the MVar with MInt. This prevents stale MVars from overwriting correct
bindings during subsequent unification steps.
-}
resolveMonoVars : MVarEnv -> Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVars env subst monoType =
    monoType
        |> resolveMonoVarsHelp env Set.empty subst
        |> Tuple.second


{-| Resolve MVars in a MonoType using a substitution, tracking which MVar names
are currently being expanded to detect indirect cycles through recursive types
(e.g. Array's Node -> Tree -> JsArray (Node a) cycle).
-}
resolveMonoVarsHelp : MVarEnv -> Set Name -> Substitution -> Mono.MonoType -> ( Bool, Mono.MonoType )
resolveMonoVarsHelp env visiting subst monoType =
    case monoType of
        Mono.MVar mvarId constraint ->
            let
                name =
                    State.lookupMVarName mvarId env |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId))
            in
            if Set.member name visiting then
                ( False, monoType )

            else
                case Dict.get name subst of
                    Just resolved ->
                        let
                            ( _, newResolved ) =
                                resolveMonoVarsHelp env (Set.insert name visiting) subst resolved
                        in
                        ( True, newResolved )

                    Nothing ->
                        case constraint of
                            Mono.CNumber ->
                                ( True, Mono.MInt )

                            Mono.CEcoValue ->
                                ( False, monoType )

        Mono.MFunction args ret ->
            let
                ( argsChanged, newArgs ) =
                    listMapChanged (resolveMonoVarsHelp env visiting subst) args

                ( retChanged, newRet ) =
                    resolveMonoVarsHelp env visiting subst ret
            in
            if argsChanged || retChanged then
                ( True, Mono.MFunction newArgs newRet )

            else
                ( False, monoType )

        Mono.MList inner ->
            let
                ( changed, newInner ) =
                    resolveMonoVarsHelp env visiting subst inner
            in
            if changed then
                ( True, Mono.MList newInner )

            else
                ( False, monoType )

        Mono.MTuple elems ->
            let
                ( changed, newElems ) =
                    listMapChanged (resolveMonoVarsHelp env visiting subst) elems
            in
            if changed then
                ( True, Mono.MTuple newElems )

            else
                ( False, monoType )

        Mono.MRecord fields ->
            let
                ( changed, newFields ) =
                    dictMapChanged (resolveMonoVarsHelp env visiting subst) fields
            in
            if changed then
                ( True, Mono.MRecord newFields )

            else
                ( False, monoType )

        Mono.MCustom can name args ->
            let
                ( changed, newArgs ) =
                    listMapChanged (resolveMonoVarsHelp env visiting subst) args
            in
            if changed then
                ( True, Mono.MCustom can name newArgs )

            else
                ( False, monoType )

        _ ->
            ( False, monoType )


{-| Collect all TVar names from a canonical type.
-}
collectCanTypeVars : Can.Type Name -> List Name -> List Name
collectCanTypeVars canType acc =
    case canType of
        Can.TVar name ->
            name :: acc

        Can.TLambda from to ->
            collectCanTypeVars from (collectCanTypeVars to acc)

        Can.TType _ _ args ->
            List.foldl (\a accInner -> collectCanTypeVars a accInner) acc args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ t) accInner -> collectCanTypeVars t accInner) acc fields

        Can.TTuple a b rest ->
            List.foldl (\t accInner -> collectCanTypeVars t accInner) acc (a :: b :: rest)

        Can.TAlias _ _ aliasArgs (Can.Filled inner) ->
            let
                argsAcc =
                    List.foldl (\( _, t ) accInner -> collectCanTypeVars t accInner) acc aliasArgs
            in
            collectCanTypeVars inner argsAcc

        Can.TAlias _ _ aliasArgs (Can.Holey inner) ->
            let
                argsAcc =
                    List.foldl (\( _, t ) accInner -> collectCanTypeVars t accInner) acc aliasArgs
            in
            collectCanTypeVars inner argsAcc

        Can.TUnit ->
            acc


{-| Apply a type substitution to a canonical type to produce a monomorphic type.

INVARIANT: Preserves TLambda staging exactly.

    a -> b -> c becomes MFunction [a] (MFunction [b] c), NOT MFunction [a, b] c.

Each TLambda in the Can.Type Name produces a single-arg MFunction. This preserves
Elm's curried semantics faithfully.

GlobalOpt will flatten these types to match closure param counts (GOPT\_016).
The flattening happens there, not here, because Monomorphize is staging-agnostic.

-}
applySubst : MVarEnv -> Substitution -> Can.Type Name -> ( Mono.MonoType, MVarEnv )
applySubst env subst canType =
    case canType of
        Can.TVar name ->
            case Dict.get name subst of
                Just monoType ->
                    ( resolveMonoVars env subst monoType, env )

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
                            ( Mono.MInt, env )

                        Mono.CEcoValue ->
                            -- Truly polymorphic type variable - keep as MVar
                            let
                                ( mvarId, env1 ) =
                                    State.allocMVar name env
                            in
                            ( Mono.MVar mvarId constraint, env1 )

        Can.TLambda from to ->
            -- IMPORTANT: Preserve curried structure - each TLambda becomes a single-arg MFunction.
            -- Do NOT flatten nested TLambdas here. GlobalOpt handles flattening (GOPT_001).
            -- Collect the lambda chain iteratively to avoid stack depth proportional to arity,
            -- then build MFunction chain from inside out.
            applySubstLambdaChain env subst [ from ] to

        Can.TType canonical name args ->
            let
                ( monoArgs, env1 ) =
                    applySubstList env subst args

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
                        ( Mono.MInt, env1 )

                    "Float" ->
                        ( Mono.MFloat, env1 )

                    "Bool" ->
                        ( Mono.MBool, env1 )

                    "Char" ->
                        ( Mono.MChar, env1 )

                    "String" ->
                        ( Mono.MString, env1 )

                    "List" ->
                        case monoArgs of
                            [ inner ] ->
                                ( Mono.MList inner, env1 )

                            _ ->
                                ( Mono.MList Mono.MUnit, env1 )

                    _ ->
                        -- Custom type from elm/core
                        ( Mono.MCustom canonical name monoArgs, env1 )

            else
                -- Custom type
                ( Mono.MCustom canonical name monoArgs, env1 )

        Can.TRecord fields maybeExtension ->
            let
                -- Start with base fields from extension variable if present
                baseFields =
                    case maybeExtension of
                        Just extName ->
                            case Dict.get extName subst of
                                Just (Mono.MRecord baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                -- Convert explicit fields and merge into base using foldl
                ( monoFields, env1 ) =
                    Dict.foldl
                        (\k (Can.FieldType _ t) ( acc, e ) ->
                            let
                                ( monoT, e1 ) =
                                    applySubst e subst t
                            in
                            ( Dict.insert k monoT acc, e1 )
                        )
                        ( baseFields, env )
                        fields
            in
            ( Mono.MRecord monoFields, env1 )

        Can.TTuple a b rest ->
            let
                ( monoTypes, env1 ) =
                    applySubstList env subst (a :: b :: rest)
            in
            ( Mono.MTuple monoTypes, env1 )

        Can.TUnit ->
            ( Mono.MUnit, env )

        Can.TAlias _ _ _ (Can.Filled inner) ->
            applySubst env subst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                ( newSubst, env1 ) =
                    List.foldl
                        (\( varName, t ) ( s, e ) ->
                            let
                                ( monoT, e1 ) =
                                    applySubst e subst t
                            in
                            ( Dict.insert varName monoT s, e1 )
                        )
                        ( subst, env )
                        args
            in
            applySubst env1 newSubst inner


{-| Apply applySubst to a list of canonical types, threading MVarEnv.
-}
applySubstList : MVarEnv -> Substitution -> List (Can.Type Name) -> ( List Mono.MonoType, MVarEnv )
applySubstList env subst types =
    List.foldl
        (\t ( acc, e ) ->
            let
                ( monoT, e1 ) =
                    applySubst e subst t
            in
            ( acc ++ [ monoT ], e1 )
        )
        ( [], env )
        types


{-| Collect a TLambda chain iteratively, then build the curried MFunction structure.
argsAcc accumulates args in reverse order (innermost first), so the foldl
builds MFunction [c'] (MFunction [b'] (MFunction [a'] result')) correctly.

Wait — we want the ORIGINAL order:
TLambda a (TLambda b (TLambda c result))
→ MFunction [a'] (MFunction [b'] (MFunction [c'] result'))

Collecting in reverse gives argsAcc = [c, b, a].
foldl builds: start with result', then:
c → MFunction [c'] result'
b → MFunction [b'] (MFunction [c'] result')
a → MFunction [a'] (MFunction [b'] (MFunction [c'] result'))
That's correct!

-}
applySubstLambdaChain : MVarEnv -> Substitution -> List (Can.Type Name) -> Can.Type Name -> ( Mono.MonoType, MVarEnv )
applySubstLambdaChain env subst argsAcc to =
    case to of
        Can.TLambda from innerTo ->
            applySubstLambdaChain env subst (from :: argsAcc) innerTo

        _ ->
            let
                ( resultMono, env1 ) =
                    applySubst env subst to
            in
            List.foldl
                (\argType ( acc, e ) ->
                    let
                        ( monoArg, e1 ) =
                            applySubst e subst argType
                    in
                    ( Mono.MFunction [ monoArg ] acc, e1 )
                )
                ( resultMono, env1 )
                argsAcc


{-| Convert a canonical type to a monomorphic type using a substitution.
This is an alias for applySubst.
-}
canTypeToMonoType : MVarEnv -> Substitution -> Can.Type Name -> ( Mono.MonoType, MVarEnv )
canTypeToMonoType =
    applySubst



-- ========== SCHEME INFO ==========


{-| Build SchemeInfo from a canonical function type.
Walks the TLambda chain once and collects type variables once.
The prefix is used to create definition-scoped canonical names for
pre-renamed types (e.g., "Module\_funcName" -> a\__def_Module\_funcName\_0).
-}
buildSchemeInfo : String -> Can.Type Name -> SchemeInfo
buildSchemeInfo prefix canType =
    let
        ( argTypes, resultType ) =
            flattenTLambda canType []

        argCount =
            List.length argTypes

        varNames =
            collectCanTypeVars canType []

        constraints =
            List.foldl
                (\name acc -> Dict.insert name (constraintFromName name) acc)
                Dict.empty
                varNames

        -- Build pre-rename map: rename ALL callee vars to definition-scoped names
        ( renameMap, renamedVarNames ) =
            buildPreRenameMap prefix varNames Set.empty 0 Data.Map.empty []

        renamedFuncType =
            renameCanTypeVarsInternal renameMap canType

        renamedArgTypes =
            List.map (renameCanTypeVarsInternal renameMap) argTypes

        renamedResultType =
            renameCanTypeVarsInternal renameMap resultType
    in
    { varNames = varNames
    , constraints = constraints
    , argTypes = argTypes
    , resultType = resultType
    , argCount = argCount
    , renamedFuncType = renamedFuncType
    , renamedArgTypes = renamedArgTypes
    , renamedResultType = renamedResultType
    , renamedVarNames = renamedVarNames
    , preRenameMap = renameMap
    }


{-| Build a pre-rename map that renames all vars to definition-scoped names.
Uses a Set to deduplicate (collectCanTypeVars can return duplicates).
-}
buildPreRenameMap : String -> List Name -> Set Name -> Int -> Data.Map.Dict String Name Name -> List Name -> ( Data.Map.Dict String Name Name, List Name )
buildPreRenameMap prefix names seen counter acc renamedAcc =
    case names of
        [] ->
            ( acc, List.reverse renamedAcc )

        name :: rest ->
            if Set.member name seen then
                buildPreRenameMap prefix rest seen counter acc renamedAcc

            else
                let
                    canonicalName =
                        name ++ "__def_" ++ prefix ++ "_" ++ String.fromInt counter
                in
                buildPreRenameMap prefix
                    rest
                    (Set.insert name seen)
                    (counter + 1)
                    (Data.Map.insert identity name canonicalName acc)
                    (canonicalName :: renamedAcc)


{-| Given a substitution with renamed-keyed bindings and a rename map (original -> renamed),
copy bindings from renamed keys to original keys so that downstream consumers using
original Can.Type Name names can find the correct MonoType bindings.
-}
applyReverseRenaming : Dict.Dict Name Mono.MonoType -> Data.Map.Dict String Name Name -> Dict.Dict Name Mono.MonoType
applyReverseRenaming subst renameMap =
    Data.Map.foldl compare
        (\orig renamed acc ->
            case Dict.get renamed acc of
                Just monoType ->
                    case Dict.get orig acc of
                        Nothing ->
                            Dict.insert orig monoType acc

                        Just _ ->
                            -- Already bound (from caller's context) — keep existing
                            acc

                Nothing ->
                    acc
        )
        subst
        renameMap


{-| Rename type variables in a canonical type using a rename map.
Internal version used for pre-renaming in SchemeInfo.
-}
renameCanTypeVarsInternal : Data.Map.Dict String Name Name -> Can.Type Name -> Can.Type Name
renameCanTypeVarsInternal renameMap canType =
    case canType of
        Can.TVar name ->
            case Data.Map.get identity name renameMap of
                Just newName ->
                    Can.TVar newName

                Nothing ->
                    canType

        Can.TLambda from to ->
            Can.TLambda (renameCanTypeVarsInternal renameMap from) (renameCanTypeVarsInternal renameMap to)

        Can.TType canonical name args ->
            Can.TType canonical name (List.map (renameCanTypeVarsInternal renameMap) args)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (renameCanTypeVarsInternal renameMap t)) fields)
                ext

        Can.TTuple a b rest ->
            Can.TTuple
                (renameCanTypeVarsInternal renameMap a)
                (renameCanTypeVarsInternal renameMap b)
                (List.map (renameCanTypeVarsInternal renameMap) rest)

        Can.TAlias canonical name aliasArgs aliasType ->
            Can.TAlias canonical
                name
                (List.map (\( n, t ) -> ( n, renameCanTypeVarsInternal renameMap t )) aliasArgs)
                (case aliasType of
                    Can.Filled inner ->
                        Can.Filled (renameCanTypeVarsInternal renameMap inner)

                    Can.Holey inner ->
                        Can.Holey (renameCanTypeVarsInternal renameMap inner)
                )

        Can.TUnit ->
            canType


{-| Flatten a TLambda chain into (argTypes, resultType).
-}
flattenTLambda : Can.Type Name -> List (Can.Type Name) -> ( List (Can.Type Name), Can.Type Name )
flattenTLambda canType acc =
    case canType of
        Can.TLambda from to ->
            flattenTLambda to (from :: acc)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            flattenTLambda inner acc

        _ ->
            ( List.reverse acc, canType )



-- ========== SINGLE-PASS CALL-SITE UNIFIER ==========


{-| Single-pass call-site unifier that replaces the multi-step
unifyArgsOnly + applySubst + resolveMonoVars + unifyExtend sequence.

Walks argTypes and argMonoTypes in lockstep, unifying each pair via unifyHelp.
Then applies the resulting substitution to the result type, and constructs
MFunction in one pass. Returns the updated substitution and the funcMonoType.

-}
unifyCallSiteDirect :
    MVarEnv
    -> List (Can.Type Name)
    -> Can.Type Name
    -> List Mono.MonoType
    -> Substitution
    -> ( Substitution, Mono.MonoType, MVarEnv )
unifyCallSiteDirect env schemeArgTypes schemeResultType argMonoTypes baseSubst =
    let
        -- Unify each scheme arg type with the corresponding call-site mono type
        ( substAfterArgs, env1 ) =
            unifyArgTypesZip env schemeArgTypes argMonoTypes baseSubst

        -- Resolve arg mono types through updated substitution
        resolvedArgs =
            List.map (resolveMonoVars env1 substAfterArgs) argMonoTypes

        -- Apply substitution to result type
        ( resultMono, env2 ) =
            applySubst env1 substAfterArgs schemeResultType

        -- Build the function mono type directly
        funcMonoType =
            buildCurriedFuncType schemeArgTypes resolvedArgs resultMono
    in
    ( substAfterArgs, funcMonoType, env2 )


{-| Zip scheme arg types with mono arg types and unify pairwise.
-}
unifyArgTypesZip : MVarEnv -> List (Can.Type Name) -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyArgTypesZip env canArgs monoArgs subst =
    case ( canArgs, monoArgs ) of
        ( canArg :: canRest, monoArg :: monoRest ) ->
            let
                ( subst1, env1 ) =
                    unifyHelp env canArg monoArg subst
            in
            unifyArgTypesZip env1 canRest monoRest subst1

        _ ->
            ( subst, env )


{-| Build a curried MFunction mirroring the TLambda structure.
Each scheme arg corresponds to one level of currying.
-}
buildCurriedFuncType : List (Can.Type Name) -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildCurriedFuncType schemeArgs resolvedArgs resultMono =
    case ( schemeArgs, resolvedArgs ) of
        ( _ :: schemeRest, arg :: argRest ) ->
            Mono.MFunction [ arg ] (buildCurriedFuncType schemeRest argRest resultMono)

        _ ->
            resultMono



-- ========== MERGED OCCURS CHECK + NORMALIZATION ==========


{-| Insert a binding with occurs check and normalization in a single pass.
If `name` appears in `monoType`, skip the binding (cyclic type).
Otherwise, normalize MVars via findRootVar and insert.
-}
insertBindingSafe : MVarEnv -> Name -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
insertBindingSafe env name monoType subst =
    case normalizeAndOccursCheck env name subst monoType of
        Nothing ->
            -- Occurs check failed: name appears in monoType, skip binding
            ( subst, env )

        Just ( normalizedTy, subst1, env1 ) ->
            ( Dict.insert name normalizedTy subst1, env1 )


{-| Walk a MonoType, normalizing MVar references via findRootVar and
simultaneously checking whether `targetName` appears anywhere.
Returns Nothing if targetName is found (occurs check failure),
or Just (normalizedType, updatedSubst, updatedEnv) on success.
-}
normalizeAndOccursCheck : MVarEnv -> Name -> Substitution -> Mono.MonoType -> Maybe ( Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheck env targetName subst ty =
    case ty of
        Mono.MVar mvarId _ ->
            let
                varName =
                    State.lookupMVarName mvarId env |> Maybe.withDefault ("__mvar_" ++ String.fromInt (Id.toComparable mvarId))

                ( root, subst1, env1 ) =
                    findRootVar env varName subst
            in
            if root == targetName then
                Nothing

            else if root == varName then
                Just ( ty, subst1, env1 )

            else
                let
                    ( rootMVarId, env2 ) =
                        State.allocMVar root env1
                in
                Just ( Mono.MVar rootMVarId (constraintFromName root), subst1, env2 )

        Mono.MFunction args ret ->
            case normalizeAndOccursCheckList env targetName subst args of
                Nothing ->
                    Nothing

                Just ( argsNorm, subst1, env1 ) ->
                    case normalizeAndOccursCheck env1 targetName subst1 ret of
                        Nothing ->
                            Nothing

                        Just ( retNorm, subst2, env2 ) ->
                            Just ( Mono.MFunction argsNorm retNorm, subst2, env2 )

        Mono.MList inner ->
            case normalizeAndOccursCheck env targetName subst inner of
                Nothing ->
                    Nothing

                Just ( innerNorm, subst1, env1 ) ->
                    Just ( Mono.MList innerNorm, subst1, env1 )

        Mono.MTuple elems ->
            case normalizeAndOccursCheckList env targetName subst elems of
                Nothing ->
                    Nothing

                Just ( elemsNorm, subst1, env1 ) ->
                    Just ( Mono.MTuple elemsNorm, subst1, env1 )

        Mono.MRecord fields ->
            case normalizeAndOccursCheckDict env targetName subst fields of
                Nothing ->
                    Nothing

                Just ( fieldsNorm, subst1, env1 ) ->
                    Just ( Mono.MRecord fieldsNorm, subst1, env1 )

        Mono.MCustom can name args ->
            case normalizeAndOccursCheckList env targetName subst args of
                Nothing ->
                    Nothing

                Just ( argsNorm, subst1, env1 ) ->
                    Just ( Mono.MCustom can name argsNorm, subst1, env1 )

        _ ->
            Just ( ty, subst, env )


normalizeAndOccursCheckList : MVarEnv -> Name -> Substitution -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckList env targetName subst types =
    normalizeAndOccursCheckListHelp env targetName subst types []


normalizeAndOccursCheckListHelp : MVarEnv -> Name -> Substitution -> List Mono.MonoType -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckListHelp env targetName subst remaining acc =
    case remaining of
        [] ->
            Just ( List.reverse acc, subst, env )

        t :: rest ->
            case normalizeAndOccursCheck env targetName subst t of
                Nothing ->
                    Nothing

                Just ( tNorm, subst1, env1 ) ->
                    normalizeAndOccursCheckListHelp env1 targetName subst1 rest (tNorm :: acc)


normalizeAndOccursCheckDict : MVarEnv -> Name -> Substitution -> Dict.Dict Name Mono.MonoType -> Maybe ( Dict.Dict Name Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckDict env targetName subst fields =
    Dict.foldl
        (\k v maybeAcc ->
            case maybeAcc of
                Nothing ->
                    Nothing

                Just ( accFields, s, e ) ->
                    case normalizeAndOccursCheck e targetName s v of
                        Nothing ->
                            Nothing

                        Just ( vNorm, s1, e1 ) ->
                            Just ( Dict.insert k vNorm accFields, s1, e1 )
        )
        (Just ( Dict.empty, subst, env ))
        fields


{-| Derive a constraint from a type variable name.
-}
constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber

    else
        Mono.CEcoValue
