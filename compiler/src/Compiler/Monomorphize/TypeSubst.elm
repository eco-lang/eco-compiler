module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst
    , canTypeToMonoType
    , unify, unifyExtend, unifyFuncCall, unifyArgsOnly, extractParamTypes
    , fillUnconstrainedCEcoWithErased
    , monoTypeContainsMVar
    )

{-| Type substitution and unification for monomorphization.

This module handles converting canonical types to monomorphic types
by applying type variable substitutions.


# Substitution

@docs applySubst


# Type Conversion

@docs canTypeToMonoType


# Unification

@docs unify, unifyExtend, unifyFuncCall, unifyArgsOnly, extractParamTypes


# CEco Variable Filling

@docs fillUnconstrainedCEcoWithErased

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Monomorphize.State exposing (Substitution)
import Data.Map
import Dict
import Set exposing (Set)
import System.TypeCheck.IO as IO


-- INTERNAL HELPERS: changed-flag mapping, union-find, normalized insertion


listMapChanged :
    (a -> ( Bool, a ))
    -> List a
    -> ( Bool, List a )
listMapChanged f list =
    let
        step item ( anyChanged, acc ) =
            let
                ( itemChanged, newItem ) =
                    f item
            in
            ( anyChanged || itemChanged, newItem :: acc )

        ( changed, reversed ) =
            List.foldl step ( False, [] ) list
    in
    if changed then
        ( True, List.reverse reversed )

    else
        ( False, list )


dictMapChanged :
    (v -> ( Bool, v ))
    -> Dict.Dict Name v
    -> ( Bool, Dict.Dict Name v )
dictMapChanged f dict =
    Dict.foldl
        (\key val ( anyChanged, acc ) ->
            let
                ( changed, newVal ) =
                    f val
            in
            ( anyChanged || changed, Dict.insert key newVal acc )
        )
        ( False, dict )
        dict


findRootVar : Name -> Substitution -> ( Name, Substitution )
findRootVar name subst =
    findRootVarHelp Set.empty name subst


findRootVarHelp : Set Name -> Name -> Substitution -> ( Name, Substitution )
findRootVarHelp visited name subst =
    case Dict.get name subst of
        Just (Mono.MVar parentName _) ->
            if parentName == name || Set.member parentName visited then
                ( name, subst )

            else
                let
                    ( root, subst1 ) =
                        findRootVarHelp (Set.insert name visited) parentName subst
                in
                if root == parentName then
                    ( root, subst1 )

                else
                    -- Path compression: point name directly to root
                    ( root
                    , Dict.insert name
                        (Mono.MVar root (constraintFromName root))
                        subst1
                    )

        _ ->
            ( name, subst )


{-| Check if a MonoType contains an MVar with the given name.
Used as an occurs check to detect cyclic bindings like a = (Global, a).
-}
monoTypeContainsMVar : Name -> Mono.MonoType -> Bool
monoTypeContainsMVar name monoType =
    case monoType of
        Mono.MVar mName _ ->
            mName == name

        Mono.MFunction args ret ->
            List.any (monoTypeContainsMVar name) args || monoTypeContainsMVar name ret

        Mono.MList inner ->
            monoTypeContainsMVar name inner

        Mono.MTuple elems ->
            List.any (monoTypeContainsMVar name) elems

        Mono.MRecord fields ->
            Dict.foldl (\_ v acc -> acc || monoTypeContainsMVar name v) False fields

        Mono.MCustom _ _ args ->
            List.any (monoTypeContainsMVar name) args

        _ ->
            False


normalizeMonoType : Substitution -> Mono.MonoType -> ( Mono.MonoType, Substitution )
normalizeMonoType subst ty =
    case ty of
        Mono.MVar varName _ ->
            let
                ( root, subst1 ) =
                    findRootVar varName subst
            in
            if root == varName then
                ( ty, subst1 )

            else
                ( Mono.MVar root (constraintFromName root), subst1 )

        Mono.MFunction args ret ->
            let
                ( argsNorm, subst1 ) =
                    normalizeList subst args

                ( retNorm, subst2 ) =
                    normalizeMonoType subst1 ret
            in
            ( Mono.MFunction argsNorm retNorm, subst2 )

        Mono.MList inner ->
            let
                ( innerNorm, subst1 ) =
                    normalizeMonoType subst inner
            in
            ( Mono.MList innerNorm, subst1 )

        Mono.MTuple elems ->
            let
                ( elemsNorm, subst1 ) =
                    normalizeList subst elems
            in
            ( Mono.MTuple elemsNorm, subst1 )

        Mono.MRecord fields ->
            let
                ( fieldsNorm, subst1 ) =
                    Dict.foldl
                        (\k v ( accFields, s ) ->
                            let
                                ( vNorm, s1 ) =
                                    normalizeMonoType s v
                            in
                            ( Dict.insert k vNorm accFields, s1 )
                        )
                        ( Dict.empty, subst )
                        fields
            in
            ( Mono.MRecord fieldsNorm, subst1 )

        Mono.MCustom can name args ->
            let
                ( argsNorm, subst1 ) =
                    normalizeList subst args
            in
            ( Mono.MCustom can name argsNorm, subst1 )

        _ ->
            ( ty, subst )


normalizeList : Substitution -> List Mono.MonoType -> ( List Mono.MonoType, Substitution )
normalizeList subst types =
    List.foldr
        (\t ( acc, s ) ->
            let
                ( tNorm, s1 ) =
                    normalizeMonoType s t
            in
            ( tNorm :: acc, s1 )
        )
        ( [], subst )
        types


insertBinding : Name -> Mono.MonoType -> Substitution -> Substitution
insertBinding name ty subst =
    let
        ( normalizedTy, subst1 ) =
            normalizeMonoType subst ty
    in
    Dict.insert name normalizedTy subst1



{-| Unify a function call by matching argument types and result type.
Returns the updated substitution and the renamed function canonical type
(with callee type variables renamed to avoid collisions with caller vars).
-}
unifyFuncCall :
    Can.Type
    -> List Mono.MonoType
    -> Can.Type
    -> Substitution
    -> Int
    -> ( Substitution, Can.Type )
unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst epoch =
    let
        -- Vars from the caller's context (existing substitution bindings)
        callerVarNames =
            Dict.keys baseSubst

        -- Vars appearing in the callee's canonical type
        funcVarNames =
            collectCanTypeVars funcCanType []

        renameMap =
            buildRenameMap epoch callerVarNames funcVarNames Data.Map.empty 0

        funcCanTypeRenamed =
            renameCanTypeVars renameMap funcCanType

        resultCanTypeRenamed =
            renameCanTypeVars renameMap resultCanType

        subst1 =
            unifyArgsOnly funcCanTypeRenamed argMonoTypes baseSubst

        desiredResultMono =
            applySubst subst1 resultCanTypeRenamed

        -- Resolve MVars in arg types through subst1 to avoid re-introducing
        -- unresolved MVars that would overwrite correct bindings during the
        -- final unification step.
        resolvedArgTypes =
            List.map (resolveMonoVars subst1) argMonoTypes

        desiredFuncMono =
            Mono.MFunction resolvedArgTypes desiredResultMono
    in
    ( unifyHelp funcCanTypeRenamed desiredFuncMono subst1, funcCanTypeRenamed )


{-| Unify a canonical type with a monomorphic type to produce a substitution for type variables.
-}
unify : Can.Type -> Mono.MonoType -> Substitution
unify canType monoType =
    unifyHelp canType monoType Dict.empty


{-| Extend an existing substitution by unifying a canonical type with a monomorphic type.
Like `unify`, but starts from `baseSubst` instead of an empty substitution.
-}
unifyExtend : Can.Type -> Mono.MonoType -> Substitution -> Substitution
unifyExtend canType monoType baseSubst =
    unifyHelp canType monoType baseSubst


{-| Helper for unification that extends an existing substitution.
-}
unifyHelp : Can.Type -> Mono.MonoType -> Substitution -> Substitution
unifyHelp canType monoType subst =
    case ( canType, monoType ) of
        ( Can.TVar name, _ ) ->
            if monoTypeContainsMVar name monoType then
                -- Occurs check: binding name to monoType would create a cyclic type.
                -- Skip this binding to prevent infinite loops in resolveMonoVars.
                subst

            else
                case Dict.get name subst of
                    Just existingMono ->
                        let
                            substWithTransitives =
                                unifyMonoMono existingMono monoType subst
                        in
                        insertBinding name monoType substWithTransitives

                    Nothing ->
                        insertBinding name monoType subst

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
                    Dict.foldl
                        (\fieldName monoFieldType s ->
                            case Dict.get fieldName fields of
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
                                (\fieldName _ -> Dict.get fieldName fields == Nothing)
                                monoFields
                    in
                    insertBinding extName (Mono.MRecord remainingFields) substWithFields

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


{-| Propagate transitive bindings between two MonoTypes.

When a type variable is re-bound from one MonoType to another,
this function ensures that any MVar references in the old binding
get transitively resolved. For example, if `c` was bound to `MVar "a"`
and is now bound to `MInt`, this adds `a → MInt` to the substitution.

-}
unifyMonoMono : Mono.MonoType -> Mono.MonoType -> Substitution -> Substitution
unifyMonoMono m1 m2 subst =
    case ( m1, m2 ) of
        ( Mono.MVar name1 _, Mono.MVar name2 _ ) ->
            if name1 == name2 then
                subst

            else
                insertBinding name1 m2 subst

        ( Mono.MVar name _, _ ) ->
            insertBinding name m2 subst

        ( _, Mono.MVar name _ ) ->
            insertBinding name m1 subst

        ( Mono.MFunction args1 ret1, Mono.MFunction args2 ret2 ) ->
            let
                substWithArgs =
                    List.foldl
                        (\( a1, a2 ) s -> unifyMonoMono a1 a2 s)
                        subst
                        (List.map2 Tuple.pair args1 args2)
            in
            unifyMonoMono ret1 ret2 substWithArgs

        ( Mono.MList inner1, Mono.MList inner2 ) ->
            unifyMonoMono inner1 inner2 subst

        ( Mono.MCustom _ _ args1, Mono.MCustom _ _ args2 ) ->
            List.foldl
                (\( a1, a2 ) s -> unifyMonoMono a1 a2 s)
                subst
                (List.map2 Tuple.pair args1 args2)

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


{-| Resolve MVar references in a MonoType using a substitution.
When a MonoType contains MVar "a" CEcoValue, and the substitution maps "a" → MInt,
replace the MVar with MInt. This prevents stale MVars from overwriting correct
bindings during subsequent unification steps.
-}
resolveMonoVars : Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVars subst monoType =
    monoType
        |> resolveMonoVarsHelp Set.empty subst
        |> Tuple.second


{-| Resolve MVars in a MonoType using a substitution, tracking which MVar names
are currently being expanded to detect indirect cycles through recursive types
(e.g. Array's Node -> Tree -> JsArray (Node a) cycle).
-}
resolveMonoVarsHelp : Set Name -> Substitution -> Mono.MonoType -> ( Bool, Mono.MonoType )
resolveMonoVarsHelp visiting subst monoType =
    case monoType of
        Mono.MVar name _ ->
            if Set.member name visiting then
                ( False, monoType )

            else
                case Dict.get name subst of
                    Just resolved ->
                        let
                            ( _, newResolved ) =
                                resolveMonoVarsHelp (Set.insert name visiting) subst resolved
                        in
                        ( True, newResolved )

                    Nothing ->
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


{-| Extend a substitution by mapping any CEcoValue TVar in the canonical type
that is still unmapped to Mono.MErased. Used for functions whose some type
parameters are genuinely phantom at a given specialization.
-}
fillUnconstrainedCEcoWithErased : Can.Type -> Substitution -> Substitution
fillUnconstrainedCEcoWithErased canType subst =
    let
        vars =
            collectCanTypeVars canType []
    in
    List.foldl
        (\name acc ->
            if Dict.member name acc then
                acc

            else
                case constraintFromName name of
                    Mono.CEcoValue ->
                        Dict.insert name Mono.MErased acc

                    Mono.CNumber ->
                        acc
        )
        subst
        vars


{-| Collect all TVar names from a canonical type.
-}
collectCanTypeVars : Can.Type -> List Name -> List Name
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


{-| Build a rename map for callee type variables that clash with caller variables.
Only variables in funcVarNames that also appear in callerVarNames get renamed.
-}
buildRenameMap : Int -> List Name -> List Name -> Data.Map.Dict String Name Name -> Int -> Data.Map.Dict String Name Name
buildRenameMap epoch callerVarNames funcVarNames acc counter =
    case funcVarNames of
        [] ->
            acc

        name :: rest ->
            if List.member name callerVarNames && not (Data.Map.member identity name acc) then
                let
                    freshName =
                        name ++ "__callee" ++ String.fromInt epoch ++ "_" ++ String.fromInt counter
                in
                buildRenameMap epoch callerVarNames rest (Data.Map.insert identity name freshName acc) (counter + 1)

            else
                buildRenameMap epoch callerVarNames rest acc counter


{-| Rename type variables in a canonical type according to a rename map.
-}
renameCanTypeVars : Data.Map.Dict String Name Name -> Can.Type -> Can.Type
renameCanTypeVars renameMap canType =
    case canType of
        Can.TVar name ->
            case Data.Map.get identity name renameMap of
                Just newName ->
                    Can.TVar newName

                Nothing ->
                    canType

        Can.TLambda from to ->
            Can.TLambda (renameCanTypeVars renameMap from) (renameCanTypeVars renameMap to)

        Can.TType canonical name args ->
            Can.TType canonical name (List.map (renameCanTypeVars renameMap) args)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (renameCanTypeVars renameMap t)) fields)
                ext

        Can.TTuple a b rest ->
            Can.TTuple
                (renameCanTypeVars renameMap a)
                (renameCanTypeVars renameMap b)
                (List.map (renameCanTypeVars renameMap) rest)

        Can.TAlias canonical name aliasArgs aliasType ->
            Can.TAlias canonical
                name
                (List.map (\( n, t ) -> ( n, renameCanTypeVars renameMap t )) aliasArgs)
                (case aliasType of
                    Can.Filled inner ->
                        Can.Filled (renameCanTypeVars renameMap inner)

                    Can.Holey inner ->
                        Can.Holey (renameCanTypeVars renameMap inner)
                )

        Can.TUnit ->
            canType


{-| Apply a type substitution to a canonical type to produce a monomorphic type.

INVARIANT: Preserves TLambda staging exactly.

    a -> b -> c becomes MFunction [a] (MFunction [b] c), NOT MFunction [a, b] c.

Each TLambda in the Can.Type produces a single-arg MFunction. This preserves
Elm's curried semantics faithfully.

GlobalOpt will flatten these types to match closure param counts (GOPT\_016).
The flattening happens there, not here, because Monomorphize is staging-agnostic.

-}
applySubst : Substitution -> Can.Type -> Mono.MonoType
applySubst subst canType =
    case canType of
        Can.TVar name ->
            case Dict.get name subst of
                Just monoType ->
                    resolveMonoVars subst monoType

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
            -- IMPORTANT: Preserve curried structure - each TLambda becomes a single-arg MFunction.
            -- Do NOT flatten nested TLambdas here. GlobalOpt handles flattening (GOPT_001).
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
                            case Dict.get extName subst of
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
                            Dict.insert varName (applySubst subst t) s
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
