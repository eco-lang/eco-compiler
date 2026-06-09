module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst
    , canTypeToMonoType, extractParamTypes
    , unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, unifyCallSiteDirectWithExpected
    , buildSchemeInfo, refreshSchemeInfo
    , applySubstWithFreeVars, applySubstKeepNumber
    )

{-| Type substitution and unification for monomorphization.

This module handles converting canonical types to monomorphic types
by applying type variable substitutions. All substitutions are keyed
by MVarId (as Int via Id.toComparable), not by Name.


# Substitution

@docs applySubst


# Type Conversion

@docs canTypeToMonoType, extractParamTypes


# Unification

@docs unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, unifyCallSiteDirectWithExpected


# Scheme Construction

@docs buildSchemeInfo, refreshSchemeInfo


# Substitution with Free Variables

@docs applySubstWithFreeVars, applySubstKeepNumber

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.State as State exposing (MVarEnv, SchemeInfo, Substitution)
import Dict
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Tuple


constraintOf : MVarId -> MVarEnv -> Mono.Constraint
constraintOf mvarId env =
    if State.isNumberVar mvarId env then
        Mono.CNumber

    else
        Mono.CEcoValue



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


{-| Follow MVar chains in the substitution to find the root variable.
Path compression updates intermediate links to point directly to the root.
-}
findRootVar : MVarEnv -> MVarId -> Substitution -> ( MVarId, Substitution, MVarEnv )
findRootVar env mvarId subst =
    findRootVarHelp env Set.empty mvarId subst


findRootVarHelp : MVarEnv -> Set Int -> MVarId -> Substitution -> ( MVarId, Substitution, MVarEnv )
findRootVarHelp env visited mvarId subst =
    let
        key =
            Id.toComparable mvarId
    in
    case Dict.get key subst of
        Just (Mono.MVar parentMvarId _) ->
            let
                parentKey =
                    Id.toComparable parentMvarId
            in
            if parentKey == key || Set.member parentKey visited then
                ( mvarId, subst, env )

            else
                let
                    ( root, subst1, env1 ) =
                        findRootVarHelp env (Set.insert key visited) parentMvarId subst

                    rootKey =
                        Id.toComparable root
                in
                if rootKey == parentKey then
                    ( root, subst1, env1 )

                else
                    -- Path compression: point this entry directly to root
                    let
                        rootConstraint =
                            constraintOf root env1
                    in
                    ( root
                    , Dict.insert key (Mono.MVar root rootConstraint) subst1
                    , env1
                    )

        _ ->
            ( mvarId, subst, env )


{-| Normalize a MonoType by resolving MVar references via the substitution.
-}
normalizeMonoType : MVarEnv -> Substitution -> Mono.MonoType -> ( Mono.MonoType, Substitution, MVarEnv )
normalizeMonoType env subst ty =
    case ty of
        Mono.MVar mvarId _ ->
            let
                ( root, subst1, env1 ) =
                    findRootVar env mvarId subst
            in
            if Id.toComparable root == Id.toComparable mvarId then
                ( ty, subst1, env1 )

            else
                let
                    rootConstraint =
                        constraintOf root env1
                in
                ( Mono.MVar root rootConstraint, subst1, env1 )

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
                step k v ( accPair, s, e ) =
                    let
                        ( vNorm, s1, e1 ) =
                            normalizeMonoType e s v
                    in
                    if vNorm == v then
                        ( accPair, s1, e1 )

                    else
                        ( ( True, Dict.insert k vNorm (Tuple.second accPair) ), s1, e1 )

                ( ( changed, fieldsNorm ), subst1, env1 ) =
                    Dict.foldl step ( ( False, fields ), subst, env ) fields
            in
            if changed then
                ( Mono.MRecord fieldsNorm, subst1, env1 )

            else
                ( ty, subst1, env1 )

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


{-| Insert a binding into the substitution with normalization, keyed by MVarId.
-}
insertBinding : MVarEnv -> MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
insertBinding env mvarId ty subst =
    let
        ( normalizedTy, subst1, env1 ) =
            normalizeMonoType env subst ty
    in
    ( Dict.insert (Id.toComparable mvarId) normalizedTy subst1, env1 )


{-| Unify a canonical type with a monomorphic type to produce a substitution for type variables.
-}
unify : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> ( Substitution, MVarEnv )
unify env canType monoType =
    unifyHelp env canType monoType Dict.empty


{-| Extend an existing substitution by unifying a canonical type with a monomorphic type.
Like `unify`, but starts from `baseSubst` instead of an empty substitution.
-}
unifyExtend : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyExtend env canType monoType baseSubst =
    unifyHelp env canType monoType baseSubst


{-| Helper for unification that extends an existing substitution.
-}
unifyHelp : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyHelp env canType monoType subst =
    case ( canType, monoType ) of
        ( Can.TVar mvarId, _ ) ->
            case Dict.get (Id.toComparable mvarId) subst of
                Just existingMono ->
                    let
                        ( substWithTransitives, env1 ) =
                            unifyMonoMono env existingMono monoType subst
                    in
                    insertBindingSafe env1 mvarId monoType substWithTransitives

                Nothing ->
                    insertBindingSafe env mvarId monoType subst

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
                Just extMvarId ->
                    let
                        -- Fields in monoFields that are not in the canonical record
                        remainingFields =
                            Dict.diff monoFields fields
                    in
                    insertBinding env1 extMvarId (Mono.MRecord remainingFields) substWithFields

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
get transitively resolved.

-}
unifyMonoMono : MVarEnv -> Mono.MonoType -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyMonoMono env m1 m2 subst =
    case ( m1, m2 ) of
        ( Mono.MVar mvarId1 _, Mono.MVar mvarId2 _ ) ->
            if Id.toComparable mvarId1 == Id.toComparable mvarId2 then
                ( subst, env )

            else
                insertBinding env mvarId1 m2 subst

        ( Mono.MVar mvarId _, _ ) ->
            insertBinding env mvarId m2 subst

        ( _, Mono.MVar mvarId _ ) ->
            insertBinding env mvarId m1 subst

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
unifyArgsOnly : MVarEnv -> Can.Type MVarId -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
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
    case monoType of
        Mono.MFunction argTypes returnType ->
            argTypes ++ extractParamTypes returnType

        _ ->
            []


{-| Resolve MVar references in a MonoType using a substitution.
Uses Int keys (Id.toComparable) for substitution lookups.
-}
resolveMonoVars : Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVars subst monoType =
    monoType
        |> resolveMonoVarsHelp Set.empty subst
        |> Tuple.second


{-| Resolve MVars in a MonoType using a substitution, tracking which MVarId keys
are currently being expanded to detect indirect cycles.
-}
resolveMonoVarsHelp : Set Int -> Substitution -> Mono.MonoType -> ( Bool, Mono.MonoType )
resolveMonoVarsHelp visiting subst monoType =
    case monoType of
        Mono.MVar mvarId constraint ->
            let
                key =
                    Id.toComparable mvarId
            in
            if Set.member key visiting then
                ( False, monoType )

            else
                case Dict.get key subst of
                    Just resolved ->
                        let
                            ( _, newResolved ) =
                                resolveMonoVarsHelp (Set.insert key visiting) subst resolved
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
                    listMapChanged (resolveMonoVarsHelp visiting subst) args

                ( retChanged, newRet ) =
                    resolveMonoVarsHelp visiting subst ret
            in
            if argsChanged || retChanged then
                ( True, Mono.MFunction newArgs newRet )

            else
                ( False, monoType )

        Mono.MList inner ->
            let
                ( changed, newInner ) =
                    resolveMonoVarsHelp visiting subst inner
            in
            if changed then
                ( True, Mono.MList newInner )

            else
                ( False, monoType )

        Mono.MTuple elems ->
            let
                ( changed, newElems ) =
                    listMapChanged (resolveMonoVarsHelp visiting subst) elems
            in
            if changed then
                ( True, Mono.MTuple newElems )

            else
                ( False, monoType )

        Mono.MRecord fields ->
            let
                ( changed, newFields ) =
                    dictMapChanged (resolveMonoVarsHelp visiting subst) fields
            in
            if changed then
                ( True, Mono.MRecord newFields )

            else
                ( False, monoType )

        Mono.MCustom can name args ->
            let
                ( changed, newArgs ) =
                    listMapChanged (resolveMonoVarsHelp visiting subst) args
            in
            if changed then
                ( True, Mono.MCustom can name newArgs )

            else
                ( False, monoType )

        _ ->
            ( False, monoType )


{-| Apply a type substitution to a canonical type to produce a monomorphic type.

INVARIANT: Preserves TLambda staging exactly.

    a -> b -> c becomes MFunction [a] (MFunction [b] c), NOT MFunction [a, b] c.

Each TLambda in the Can.Type MVarId produces a single-arg MFunction. This preserves
Elm's curried semantics faithfully.

GlobalOpt will flatten these types to match closure param counts (GOPT\_016).
The flattening happens there, not here, because Monomorphize is staging-agnostic.

-}
applySubst : MVarEnv -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
applySubst env subst canType =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Id.toComparable mvarId
            in
            case Dict.get key subst of
                Just monoType ->
                    ( resolveMonoVars subst monoType, env )

                Nothing ->
                    let
                        constraint =
                            constraintOf mvarId env
                    in
                    case constraint of
                        Mono.CNumber ->
                            ( Mono.MInt, env )

                        Mono.CEcoValue ->
                            ( Mono.MVar mvarId constraint, env )

        Can.TLambda from to ->
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
                        ( Mono.MCustom canonical name monoArgs, env1 )

            else
                ( Mono.MCustom canonical name monoArgs, env1 )

        Can.TRecord fields maybeExtension ->
            let
                -- Start with base fields from extension variable if present
                baseFields =
                    case maybeExtension of
                        Just extMvarId ->
                            case Dict.get (Id.toComparable extMvarId) subst of
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
                        (\( paramId, t ) ( s, e ) ->
                            let
                                ( monoT, e1 ) =
                                    applySubst e subst t
                            in
                            ( Dict.insert (Id.toComparable paramId) monoT s, e1 )
                        )
                        ( subst, env )
                        args
            in
            applySubst env1 newSubst inner


{-| Apply applySubst to a list of canonical types, threading MVarEnv.
-}
applySubstList : MVarEnv -> Substitution -> List (Can.Type MVarId) -> ( List Mono.MonoType, MVarEnv )
applySubstList env subst types =
    let
        ( revAcc, finalEnv ) =
            List.foldl
                (\t ( acc, e ) ->
                    let
                        ( monoT, e1 ) =
                            applySubst e subst t
                    in
                    ( monoT :: acc, e1 )
                )
                ( [], env )
                types
    in
    ( List.reverse revAcc, finalEnv )


{-| Apply a substitution to a canonical type, but only for MVarIds that
actually appear in the type. This prevents cross-scheme contamination
when a substitution carries bindings from multiple schemes.

The FreeVars parameter documents which annotation scheme this type belongs to
but the actual filtering is by MVarIds present in canType (sufficient because
MVarIds are globally unique post-AssignMVarIds).

-}
applySubstWithFreeVars :
    MVarEnv
    -> Can.FreeVars
    -> Substitution
    -> Can.Type MVarId
    -> Mono.MonoType
applySubstWithFreeVars mvarEnv _ subst canType =
    if Dict.size subst <= 8 then
        -- For small substitutions, filtering costs more than just applying
        -- the full subst directly (the overhead of building Set + Dict.filter
        -- exceeds any savings from a slightly smaller dict).
        Tuple.first (applySubst mvarEnv subst canType)

    else
        let
            rootIds =
                collectMVarIds canType []

            rootKeys =
                List.map Id.toComparable rootIds

            -- Compute transitive closure: include all MVarIds reachable
            -- through substitution bindings. This ensures chains like
            -- Id_x -> MVar 10, 10 -> MInt keep both entries so that
            -- applySubst + resolveMonoVars can fully resolve.
            reachableKeys =
                closureOverSubst rootKeys subst

            filteredSubst =
                Dict.filter
                    (\key _ -> Set.member key reachableKeys)
                    subst
        in
        Tuple.first (applySubst mvarEnv filteredSubst canType)


{-| Compute the transitive closure of substitution keys reachable from
the given initial keys. Starting from the root keys, follow each binding's
MonoType to discover further MVarId dependencies, and include those keys too.
-}
closureOverSubst : List Int -> Substitution -> Set Int
closureOverSubst initialKeys subst =
    closureOverSubstHelp initialKeys Set.empty subst


closureOverSubstHelp : List Int -> Set Int -> Substitution -> Set Int
closureOverSubstHelp pending visited subst =
    case pending of
        [] ->
            visited

        key :: rest ->
            if Set.member key visited then
                closureOverSubstHelp rest visited subst

            else
                let
                    newVisited =
                        Set.insert key visited
                in
                case Dict.get key subst of
                    Nothing ->
                        closureOverSubstHelp rest newVisited subst

                    Just monoType ->
                        let
                            depKeys =
                                collectMVarIdsFromMono monoType []
                                    |> List.map Id.toComparable
                        in
                        closureOverSubstHelp (depKeys ++ rest) newVisited subst


{-| Collect all MVarIds from a MonoType, mirroring collectMVarIds for Can.Type.
-}
collectMVarIdsFromMono : Mono.MonoType -> List MVarId -> List MVarId
collectMVarIdsFromMono monoType acc =
    let
        seen =
            List.foldl (\id s -> Set.insert (Id.toComparable id) s) Set.empty acc
    in
    Tuple.first (collectMVarIdsFromMonoHelp monoType ( acc, seen ))


collectMVarIdsFromMonoHelp : Mono.MonoType -> ( List MVarId, Set Int ) -> ( List MVarId, Set Int )
collectMVarIdsFromMonoHelp monoType (( acc, seen ) as pair) =
    case monoType of
        Mono.MVar mvarId _ ->
            let
                key =
                    Id.toComparable mvarId
            in
            if Set.member key seen then
                pair

            else
                ( mvarId :: acc, Set.insert key seen )

        Mono.MFunction args result ->
            let
                argsPair =
                    List.foldl (\a accPair -> collectMVarIdsFromMonoHelp a accPair) pair args
            in
            collectMVarIdsFromMonoHelp result argsPair

        Mono.MList inner ->
            collectMVarIdsFromMonoHelp inner pair

        Mono.MTuple elements ->
            List.foldl (\e accPair -> collectMVarIdsFromMonoHelp e accPair) pair elements

        Mono.MRecord fields ->
            Dict.foldl (\_ t accPair -> collectMVarIdsFromMonoHelp t accPair) pair fields

        Mono.MCustom _ _ args ->
            List.foldl (\a accPair -> collectMVarIdsFromMonoHelp a accPair) pair args

        _ ->
            pair


{-| Collect a TLambda chain iteratively, then build the curried MFunction structure.
-}
applySubstLambdaChain : MVarEnv -> Substitution -> List (Can.Type MVarId) -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
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


{-| Like `applySubst`, but preserves unresolved `CNumber` TVars as `Mono.MVar _ CNumber`
instead of defaulting them to `MInt`.

Used by `processCallArg` in `Specialize.elm` to compute a representative monoType
for a polymorphic-number argument (e.g. `Basics.add : number -> number -> number`)
without committing to `Int`. The preserved MVars flow through `unifyCallSiteDirect`
so later args (e.g. `Array Float`) can transitively bind `number = Float`, then
`resolveProcessedArg PendingGlobal` unifies with the callee's param type and
specialises with the correct element type.

-}
applySubstKeepNumber : MVarEnv -> Substitution -> Can.Type MVarId -> Mono.MonoType
applySubstKeepNumber env subst canType =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Id.toComparable mvarId
            in
            case Dict.get key subst of
                Just monoType ->
                    resolveMonoVarsKeepNumber subst monoType

                Nothing ->
                    Mono.MVar mvarId (constraintOf mvarId env)

        Can.TLambda from to ->
            applySubstLambdaChainKeepNumber env subst [ from ] to

        Can.TType canonical name args ->
            let
                monoArgs =
                    List.map (applySubstKeepNumber env subst) args

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
                        Mono.MCustom canonical name monoArgs

            else
                Mono.MCustom canonical name monoArgs

        Can.TRecord fields maybeExtension ->
            let
                baseFields =
                    case maybeExtension of
                        Just extMvarId ->
                            case Dict.get (Id.toComparable extMvarId) subst of
                                Just (Mono.MRecord baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                monoFields =
                    Dict.foldl
                        (\k (Can.FieldType _ t) acc ->
                            Dict.insert k (applySubstKeepNumber env subst t) acc
                        )
                        baseFields
                        fields
            in
            Mono.MRecord monoFields

        Can.TTuple a b rest ->
            Mono.MTuple (List.map (applySubstKeepNumber env subst) (a :: b :: rest))

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            applySubstKeepNumber env subst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                newSubst =
                    List.foldl
                        (\( paramId, t ) s ->
                            Dict.insert (Id.toComparable paramId) (applySubstKeepNumber env subst t) s
                        )
                        subst
                        args
            in
            applySubstKeepNumber env newSubst inner


applySubstLambdaChainKeepNumber : MVarEnv -> Substitution -> List (Can.Type MVarId) -> Can.Type MVarId -> Mono.MonoType
applySubstLambdaChainKeepNumber env subst argsAcc to =
    case to of
        Can.TLambda from innerTo ->
            applySubstLambdaChainKeepNumber env subst (from :: argsAcc) innerTo

        _ ->
            List.foldl
                (\argType acc ->
                    Mono.MFunction [ applySubstKeepNumber env subst argType ] acc
                )
                (applySubstKeepNumber env subst to)
                argsAcc


{-| Like `resolveMonoVars` but preserves unresolved `CNumber` as `MVar _ CNumber`.
-}
resolveMonoVarsKeepNumber : Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVarsKeepNumber subst monoType =
    resolveMonoVarsKeepNumberHelp Set.empty subst monoType


resolveMonoVarsKeepNumberHelp : Set Int -> Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVarsKeepNumberHelp visiting subst monoType =
    case monoType of
        Mono.MVar mvarId _ ->
            let
                key =
                    Id.toComparable mvarId
            in
            if Set.member key visiting then
                monoType

            else
                case Dict.get key subst of
                    Just resolved ->
                        resolveMonoVarsKeepNumberHelp (Set.insert key visiting) subst resolved

                    Nothing ->
                        monoType

        Mono.MFunction args ret ->
            Mono.MFunction
                (List.map (resolveMonoVarsKeepNumberHelp visiting subst) args)
                (resolveMonoVarsKeepNumberHelp visiting subst ret)

        Mono.MList inner ->
            Mono.MList (resolveMonoVarsKeepNumberHelp visiting subst inner)

        Mono.MTuple elems ->
            Mono.MTuple (List.map (resolveMonoVarsKeepNumberHelp visiting subst) elems)

        Mono.MRecord fields ->
            Mono.MRecord (Dict.map (\_ t -> resolveMonoVarsKeepNumberHelp visiting subst t) fields)

        Mono.MCustom can name args ->
            Mono.MCustom can name (List.map (resolveMonoVarsKeepNumberHelp visiting subst) args)

        _ ->
            monoType


{-| Convert a canonical type to a monomorphic type using a substitution.
This is an alias for applySubst.
-}
canTypeToMonoType : MVarEnv -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
canTypeToMonoType =
    applySubst



-- ========== SCHEME INFO ==========


{-| Build SchemeInfo from a canonical function type.
Freshens all MVarIds using the global MVarEnv id supply so that scheme
ids never collide with caller substitutions.
-}
buildSchemeInfo : MVarEnv -> Can.Type MVarId -> ( SchemeInfo, MVarEnv )
buildSchemeInfo env canType =
    let
        origVarIds =
            collectMVarIds canType []

        renaming =
            buildSchemeRenaming env origVarIds

        freshVarIds =
            List.reverse renaming.freshIds

        renamedSchemeType =
            renameMVarIdsInCanType renaming.renameMap canType

        ( argTypes, resultType ) =
            flattenTLambda renamedSchemeType []

        argCount =
            List.length argTypes
    in
    ( { varIds = freshVarIds
      , numberVarKeys = renaming.numberVarKeys
      , argTypes = argTypes
      , resultType = resultType
      , argCount = argCount
      , schemeType = renamedSchemeType
      }
    , renaming.env
    )


{-| Re-freshen a cached SchemeInfo by replacing all its MVarIds with new ones.
This prevents stale MVar bindings from a previous unification from leaking
into a new call site that reuses the cached scheme.
-}
refreshSchemeInfo : MVarEnv -> SchemeInfo -> ( SchemeInfo, MVarEnv )
refreshSchemeInfo env cached =
    let
        renaming =
            buildSchemeRenaming env cached.varIds

        freshVarIds =
            List.reverse renaming.freshIds

        renameMap =
            renaming.renameMap

        refreshedArgTypes =
            List.map (renameMVarIdsInCanType renameMap) cached.argTypes

        refreshedResultType =
            renameMVarIdsInCanType renameMap cached.resultType

        refreshedSchemeType =
            renameMVarIdsInCanType renameMap cached.schemeType
    in
    ( { varIds = freshVarIds
      , numberVarKeys = Set.map (applyRenameToId renameMap) cached.numberVarKeys
      , argTypes = refreshedArgTypes
      , resultType = refreshedResultType
      , argCount = cached.argCount
      , schemeType = refreshedSchemeType
      }
    , renaming.env
    )


{-| Apply renaming to a single MVarId key, returning the renamed key or the original if not in the map.
-}
applyRenameToId : Dict.Dict Int MVarId -> Int -> Int
applyRenameToId renameMap id =
    case Dict.get id renameMap of
        Just newId ->
            Id.toComparable newId

        Nothing ->
            id


{-| Accumulator for buildSchemeRenaming.
-}
type alias SchemeRenamingAcc =
    { renameMap : Dict.Dict Int MVarId
    , freshIds : List MVarId
    , numberVarKeys : Set Int
    , env : MVarEnv
    }


{-| Build a renaming for all MVarIds in a scheme:
allocates fresh ids from the global MVarEnv, preserves constraints.
-}
buildSchemeRenaming :
    MVarEnv
    -> List MVarId
    -> SchemeRenamingAcc
buildSchemeRenaming env varIds =
    List.foldl
        (\oldId acc ->
            let
                origConstraint =
                    constraintOf oldId acc.env

                ( freshId, e1 ) =
                    State.freshMVar origConstraint acc.env

                oldKey =
                    Id.toComparable oldId

                freshKey =
                    Id.toComparable freshId

                newNumberVarKeys =
                    case origConstraint of
                        Mono.CNumber ->
                            Set.insert freshKey acc.numberVarKeys

                        Mono.CEcoValue ->
                            acc.numberVarKeys
            in
            { renameMap = Dict.insert oldKey freshId acc.renameMap
            , freshIds = freshId :: acc.freshIds
            , numberVarKeys = newNumberVarKeys
            , env = e1
            }
        )
        { renameMap = Dict.empty
        , freshIds = []
        , numberVarKeys = Set.empty
        , env = env
        }
        varIds


{-| Rename all MVarIds in a canonical type using an Int-keyed map
from original Id.toComparable to fresh MVarId.
-}
renameMVarIdsInCanType :
    Dict.Dict Int MVarId
    -> Can.Type MVarId
    -> Can.Type MVarId
renameMVarIdsInCanType renameMap canType =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Id.toComparable mvarId
            in
            case Dict.get key renameMap of
                Just freshId ->
                    Can.TVar freshId

                Nothing ->
                    canType

        Can.TLambda from to ->
            Can.TLambda
                (renameMVarIdsInCanType renameMap from)
                (renameMVarIdsInCanType renameMap to)

        Can.TType canonical name args ->
            Can.TType
                canonical
                name
                (List.map (renameMVarIdsInCanType renameMap) args)

        Can.TRecord fields maybeExt ->
            let
                newFields =
                    Dict.map
                        (\_ (Can.FieldType idx t) ->
                            Can.FieldType idx (renameMVarIdsInCanType renameMap t)
                        )
                        fields

                newExt =
                    maybeExt
                        |> Maybe.map
                            (\extId ->
                                let
                                    key =
                                        Id.toComparable extId
                                in
                                Maybe.withDefault extId (Dict.get key renameMap)
                            )
            in
            Can.TRecord newFields newExt

        Can.TTuple a b rest ->
            Can.TTuple
                (renameMVarIdsInCanType renameMap a)
                (renameMVarIdsInCanType renameMap b)
                (List.map (renameMVarIdsInCanType renameMap) rest)

        Can.TAlias canonical name args aliasType ->
            let
                newArgs =
                    List.map
                        (\( paramId, t ) ->
                            let
                                key =
                                    Id.toComparable paramId

                                newParamId =
                                    Maybe.withDefault paramId (Dict.get key renameMap)
                            in
                            ( newParamId, renameMVarIdsInCanType renameMap t )
                        )
                        args

                newAliasType =
                    case aliasType of
                        Can.Filled inner ->
                            Can.Filled (renameMVarIdsInCanType renameMap inner)

                        Can.Holey inner ->
                            Can.Holey (renameMVarIdsInCanType renameMap inner)
            in
            Can.TAlias canonical name newArgs newAliasType

        Can.TUnit ->
            canType


{-| Collect all TVar MVarIds from a canonical type.
-}
collectMVarIds : Can.Type MVarId -> List MVarId -> List MVarId
collectMVarIds canType acc =
    let
        seen =
            List.foldl (\id s -> Set.insert (Id.toComparable id) s) Set.empty acc
    in
    Tuple.first (collectMVarIdsHelp canType ( acc, seen ))


collectMVarIdsHelp : Can.Type MVarId -> ( List MVarId, Set Int ) -> ( List MVarId, Set Int )
collectMVarIdsHelp canType (( acc, seen ) as pair) =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Id.toComparable mvarId
            in
            if Set.member key seen then
                pair

            else
                ( mvarId :: acc, Set.insert key seen )

        Can.TLambda from to ->
            collectMVarIdsHelp from (collectMVarIdsHelp to pair)

        Can.TType _ _ args ->
            List.foldl (\a accPair -> collectMVarIdsHelp a accPair) pair args

        Can.TRecord fields maybeExt ->
            let
                fieldPair =
                    Dict.foldl (\_ (Can.FieldType _ t) accPair -> collectMVarIdsHelp t accPair) pair fields
            in
            case maybeExt of
                Just extId ->
                    let
                        extKey =
                            Id.toComparable extId

                        ( fieldAcc, fieldSeen ) =
                            fieldPair
                    in
                    if Set.member extKey fieldSeen then
                        fieldPair

                    else
                        ( extId :: fieldAcc, Set.insert extKey fieldSeen )

                Nothing ->
                    fieldPair

        Can.TTuple a b rest ->
            List.foldl (\t accPair -> collectMVarIdsHelp t accPair) pair (a :: b :: rest)

        Can.TAlias _ _ aliasArgs (Can.Filled inner) ->
            let
                argsPair =
                    List.foldl (\( _, t ) accPair -> collectMVarIdsHelp t accPair) pair aliasArgs
            in
            collectMVarIdsHelp inner argsPair

        Can.TAlias _ _ aliasArgs (Can.Holey inner) ->
            let
                argsPair =
                    List.foldl (\( _, t ) accPair -> collectMVarIdsHelp t accPair) pair aliasArgs
            in
            collectMVarIdsHelp inner argsPair

        Can.TUnit ->
            pair


{-| Flatten a TLambda chain into (argTypes, resultType).
-}
flattenTLambda : Can.Type MVarId -> List (Can.Type MVarId) -> ( List (Can.Type MVarId), Can.Type MVarId )
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
    -> List (Can.Type MVarId)
    -> Can.Type MVarId
    -> List Mono.MonoType
    -> Substitution
    -> ( Substitution, Mono.MonoType, MVarEnv )
unifyCallSiteDirect env schemeArgTypes schemeResultType argMonoTypes baseSubst =
    unifyCallSiteDirectWithExpected env schemeArgTypes schemeResultType argMonoTypes Nothing baseSubst


{-| Variant of unifyCallSiteDirect that additionally constrains the scheme by
unifying the scheme's residual type (after consuming the supplied argument
positions) with the call's expected result canonical type. This lets
concrete information encoded in the outer expression's result type (e.g. the
fact that `List.map swap` at a given use site returns `List (Int, Int)`) flow
back into the scheme's type variables, and through them into the arg
expressions' own free type variables. Without this, a polymorphic arg such as
a let-bound `swap : (ta, tb) -> (tb, ta)` passed as a first-class function
would remain unresolved and get specialized as `(!eco.value, !eco.value)`.
-}
unifyCallSiteDirectWithExpected :
    MVarEnv
    -> List (Can.Type MVarId)
    -> Can.Type MVarId
    -> List Mono.MonoType
    -> Maybe (Can.Type MVarId)
    -> Substitution
    -> ( Substitution, Mono.MonoType, MVarEnv )
unifyCallSiteDirectWithExpected env schemeArgTypes schemeResultType argMonoTypes maybeCallResultCanType baseSubst =
    let
        -- Unify each scheme arg type with the corresponding call-site mono type
        ( substAfterArgs0, env0 ) =
            unifyArgTypesZip env schemeArgTypes argMonoTypes baseSubst

        -- Additionally, if we know the call's own expected result canonical
        -- type, unify the scheme's residual (remaining scheme args + scheme
        -- result, curried as a function chain) with it. This pushes concrete
        -- information from the enclosing context back into scheme type
        -- variables.
        ( substAfterArgs, env1 ) =
            case maybeCallResultCanType of
                Just callResultCanType ->
                    let
                        schemeResidual =
                            buildCurriedCanType (List.drop (List.length argMonoTypes) schemeArgTypes) schemeResultType

                        ( callResultMono, envR ) =
                            applySubst env0 substAfterArgs0 callResultCanType

                        -- Over-application: when the call supplies MORE args than
                        -- the scheme's own arity, the surplus args are applied to
                        -- the scheme's RESULT, not the scheme itself. The scheme
                        -- result is therefore a function consuming those surplus
                        -- args and yielding the call's result. Re-wrap the expected
                        -- result mono with one arrow per surplus arg so the scheme
                        -- result variable unifies with the intermediate function
                        -- type (e.g. `Tuple.first fns 1` ⇒ `a := Int -> Int`), not
                        -- the final over-applied result (`Int`). Without this, the
                        -- residual `a` was unified directly with `Int`, collapsing
                        -- the projected-element type to an unboxed primitive and
                        -- emitting an invalid `eco.papExtend` (operand #0 i64).
                        surplusArgMonos =
                            List.drop (List.length schemeArgTypes) argMonoTypes

                        expectedResidualMono =
                            List.foldr
                                (\argMono acc -> Mono.MFunction [ argMono ] acc)
                                callResultMono
                                surplusArgMonos
                    in
                    unifyHelp envR schemeResidual expectedResidualMono substAfterArgs0

                Nothing ->
                    ( substAfterArgs0, env0 )

        -- Derive supplied arg types by applying the final substitution to the
        -- scheme's arg types, not from argMonoTypes directly. This matters when
        -- a supplied arg was a row-polymorphic local function whose argMono was
        -- narrowed (e.g. its record extension var was unbound at argument
        -- preparation time). Pulling from scheme-via-applySubst lets the cross-
        -- arg unification (e.g. a third arg giving the full record shape) flow
        -- back into the earlier positions instead of preserving the narrow type.
        suppliedSchemeArgs =
            List.take (List.length argMonoTypes) schemeArgTypes

        ( revResolvedSupplied, envS ) =
            List.foldl
                (\canArg ( accArgs, accEnv ) ->
                    let
                        ( monoArg, envN ) =
                            applySubst accEnv substAfterArgs canArg
                    in
                    ( monoArg :: accArgs, envN )
                )
                ( [], env1 )
                suppliedSchemeArgs

        resolvedSuppliedArgs =
            List.reverse revResolvedSupplied

        -- Resolve REMAINING scheme arg types through substitution
        remainingSchemeArgs =
            List.drop (List.length argMonoTypes) schemeArgTypes

        ( revResolvedRemainingArgs, env2 ) =
            List.foldl
                (\canArg ( accArgs, accEnv ) ->
                    let
                        ( monoArg, envN ) =
                            applySubst accEnv substAfterArgs canArg
                    in
                    ( monoArg :: accArgs, envN )
                )
                ( [], envS )
                remainingSchemeArgs

        resolvedAllArgs =
            resolvedSuppliedArgs ++ List.reverse revResolvedRemainingArgs

        -- Apply substitution to result type
        ( resultMono, env3 ) =
            applySubst env2 substAfterArgs schemeResultType

        -- Build the function mono type directly
        funcMonoType =
            buildCurriedFuncType schemeArgTypes resolvedAllArgs resultMono
    in
    ( substAfterArgs, funcMonoType, env3 )


{-| Zip scheme arg types with mono arg types and unify pairwise.
-}
unifyArgTypesZip : MVarEnv -> List (Can.Type MVarId) -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
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
buildCurriedFuncType : List (Can.Type MVarId) -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildCurriedFuncType schemeArgs resolvedArgs resultMono =
    case ( schemeArgs, resolvedArgs ) of
        ( _ :: schemeRest, arg :: argRest ) ->
            Mono.MFunction [ arg ] (buildCurriedFuncType schemeRest argRest resultMono)

        _ ->
            resultMono


{-| Build a curried Can.Type chain: args ++ result → TLambda arg0 (TLambda arg1 ... result).
When args is empty, returns result unchanged.
-}
buildCurriedCanType : List (Can.Type MVarId) -> Can.Type MVarId -> Can.Type MVarId
buildCurriedCanType args result =
    case args of
        [] ->
            result

        first :: rest ->
            Can.TLambda first (buildCurriedCanType rest result)



-- ========== MERGED OCCURS CHECK + NORMALIZATION ==========


{-| Insert a binding with occurs check and normalization in a single pass.
If the target MVarId appears in `monoType`, skip the binding (cyclic type).
Otherwise, normalize MVars via findRootVar and insert.
-}
insertBindingSafe : MVarEnv -> MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
insertBindingSafe env targetId monoType subst =
    case normalizeAndOccursCheck env targetId subst monoType of
        Nothing ->
            -- Occurs check failed: targetId appears in monoType, skip binding
            ( subst, env )

        Just ( normalizedTy, subst1, env1 ) ->
            ( Dict.insert (Id.toComparable targetId) normalizedTy subst1, env1 )


{-| Walk a MonoType, normalizing MVar references via findRootVar and
simultaneously checking whether `targetId` appears anywhere.
Returns Nothing if targetId is found (occurs check failure),
or Just (normalizedType, updatedSubst, updatedEnv) on success.
-}
normalizeAndOccursCheck : MVarEnv -> MVarId -> Substitution -> Mono.MonoType -> Maybe ( Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheck env targetId subst ty =
    case ty of
        Mono.MVar mvarId _ ->
            let
                ( root, subst1, env1 ) =
                    findRootVar env mvarId subst
            in
            if Id.toComparable root == Id.toComparable targetId then
                Nothing

            else if Id.toComparable root == Id.toComparable mvarId then
                Just ( ty, subst1, env1 )

            else
                let
                    rootConstraint =
                        constraintOf root env1
                in
                Just ( Mono.MVar root rootConstraint, subst1, env1 )

        Mono.MFunction args ret ->
            case normalizeAndOccursCheckList env targetId subst args of
                Nothing ->
                    Nothing

                Just ( argsNorm, subst1, env1 ) ->
                    case normalizeAndOccursCheck env1 targetId subst1 ret of
                        Nothing ->
                            Nothing

                        Just ( retNorm, subst2, env2 ) ->
                            Just ( Mono.MFunction argsNorm retNorm, subst2, env2 )

        Mono.MList inner ->
            case normalizeAndOccursCheck env targetId subst inner of
                Nothing ->
                    Nothing

                Just ( innerNorm, subst1, env1 ) ->
                    Just ( Mono.MList innerNorm, subst1, env1 )

        Mono.MTuple elems ->
            case normalizeAndOccursCheckList env targetId subst elems of
                Nothing ->
                    Nothing

                Just ( elemsNorm, subst1, env1 ) ->
                    Just ( Mono.MTuple elemsNorm, subst1, env1 )

        Mono.MRecord fields ->
            case normalizeAndOccursCheckDict env targetId subst fields of
                Nothing ->
                    Nothing

                Just ( fieldsNorm, subst1, env1 ) ->
                    Just ( Mono.MRecord fieldsNorm, subst1, env1 )

        Mono.MCustom can name args ->
            case normalizeAndOccursCheckList env targetId subst args of
                Nothing ->
                    Nothing

                Just ( argsNorm, subst1, env1 ) ->
                    Just ( Mono.MCustom can name argsNorm, subst1, env1 )

        _ ->
            Just ( ty, subst, env )


normalizeAndOccursCheckList : MVarEnv -> MVarId -> Substitution -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckList env targetId subst types =
    normalizeAndOccursCheckListHelp env targetId subst types []


normalizeAndOccursCheckListHelp : MVarEnv -> MVarId -> Substitution -> List Mono.MonoType -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckListHelp env targetId subst remaining acc =
    case remaining of
        [] ->
            Just ( List.reverse acc, subst, env )

        t :: rest ->
            case normalizeAndOccursCheck env targetId subst t of
                Nothing ->
                    Nothing

                Just ( tNorm, subst1, env1 ) ->
                    normalizeAndOccursCheckListHelp env1 targetId subst1 rest (tNorm :: acc)


normalizeAndOccursCheckDict : MVarEnv -> MVarId -> Substitution -> Dict.Dict Name Mono.MonoType -> Maybe ( Dict.Dict Name Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckDict env targetId subst fields =
    Dict.foldl
        (\k v maybeAcc ->
            case maybeAcc of
                Nothing ->
                    Nothing

                Just ( accPair, s, e ) ->
                    case normalizeAndOccursCheck e targetId s v of
                        Nothing ->
                            Nothing

                        Just ( vNorm, s1, e1 ) ->
                            if vNorm == v then
                                Just ( accPair, s1, e1 )

                            else
                                Just ( ( True, Dict.insert k vNorm (Tuple.second accPair) ), s1, e1 )
        )
        (Just ( ( False, fields ), subst, env ))
        fields
        |> Maybe.map (\( ( _, f ), s, e ) -> ( f, s, e ))
