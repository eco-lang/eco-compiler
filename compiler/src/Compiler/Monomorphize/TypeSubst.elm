module Compiler.Monomorphize.TypeSubst exposing
    ( applySubstPure, applySubstPureRO
    , extractParamTypes
    , unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, unifyCallSiteDirectWithExpected
    , buildSchemeInfo, refreshSchemeInfo
    , applySubstFiltered
    , refreshConstraints
    )

{-| Monomorphization needs, at every use of a polymorphic value, the concrete
type it is used at, and this module is the type algebra that works it out.

Two kinds of type meet here. A _canonical type_ (`Can.Type MVarId`) is a type
as the source declares it, with type variables. A _MonoType_ is a type as one
specialization uses it, and it may still contain open variables (`MVar`). A
_substitution_ (`State.Substitution`) maps type variables to MonoTypes. It is
keyed by `MVarId` (as `Id.toComparable`), never by name, so two variables that
share a name in the source are still kept apart.

The module does two things with them.

_Unification_ (`unify`, `unifyExtend`, `unifyArgsOnly`,
`unifyCallSiteDirect`, `unifyCallSiteDirectWithExpected`) walks a canonical type
and a MonoType side by side and records what each variable must be. It is
lenient: there is no failure result, and a pair of shapes it does not recognise
adds nothing; where argument or element lists differ in length, the common
prefix is unified and the surplus ignored. A
binding of a canonical type variable is skipped when the type contains a
variable whose chain of variable-to-variable bindings leads back to the bound
variable; containment through a variable bound to a non-variable type is not
detected. Bindings made while re-unifying an old binding with a new type, and
record extension bindings, are not checked. When a variable
that is already bound meets a new type, the old and the new types are unified
with each other and then the new type is stored, unless that binding is
cyclic.

_Application_ (`applySubstPure`, `applySubstPureRO`, `applySubstFiltered`)
turns a canonical type into a MonoType by replacing each bound variable. Each
arrow becomes a one-argument `MFunction`, so `a -> b -> c` becomes a function
returning a function, never a two-argument one. The `elm/core` types `Int`,
`Float`, `Bool`, `Char` and `String` become the primitive MonoTypes and `List`
becomes `MList`. A variable with no binding stays an `MVar`. In particular an
open number variable is not defaulted to `Int` here; that happens later, in
`Compiler.Monomorphize.Prune`. Application reads the `MVarEnv` and never
changes it.

One rule about constraints runs through unification. Each `MVar` carries a
stamp, `CNumber` for a variable known to be a number and `CEcoValue` for any
other, read from the `MVarEnv` side table (`State.isNumberVar`). When an
unbound canonical number variable meets a `CEcoValue` `MVar`, or when two `MVar`s
of different constraint meet while re-unifying an old binding, number wins: the
`CEcoValue` variable is bound toward the number variable and recorded as a number
in the `MVarEnv` (`State.taintNumber`). Copies of a tainted variable stamped
before the taint still say `CEcoValue`; such a copy has a _stale stamp_, and
`refreshConstraints` corrects it. An unbound canonical `CEcoValue` variable
meeting a number `MVar` is bound to it but not recorded as a number.

A _scheme_ (`State.SchemeInfo`) is a callee's type prepared for unification at
a call site. `buildSchemeInfo` and `refreshSchemeInfo` give every variable of it
a fresh id, so bindings made at one call site do not reach another.


# Substitution

@docs applySubstPure, applySubstPureRO


# Type Conversion

@docs extractParamTypes


# Unification

@docs unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, unifyCallSiteDirectWithExpected


# Scheme Construction

@docs buildSchemeInfo, refreshSchemeInfo


# Substitution with Free Variables

@docs applySubstFiltered
@docs refreshConstraints

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.State as State exposing (MVarEnv, SchemeInfo, Substitution)
import Dict
import Set exposing (Set)


{-| Returns the stamp a variable should carry now: `CNumber` when the `MVarEnv`
records it as a number, `CEcoValue` otherwise, including for a variable
constrained to `comparable`, `appendable` or `compappend`.
-}
constraintOf : MVarId -> MVarEnv -> Mono.Constraint
constraintOf mvarId env =
    if State.isNumberVar mvarId env then
        Mono.CNumber

    else
        Mono.CEcoValue


{-| Returns `monoType` with every `MVar` restamped `CNumber` or `CEcoValue`
according to the `MVarEnv` as it is now.

A variable recorded as a number after a copy of it was stamped `CEcoValue`
leaves that copy with a stale stamp. A specialization key built from the
type without this refresh keys such a variable as a boxed value rather than as
the number it has become.

When no stamp is stale the input itself is returned, not a copy; the type is
rebuilt only when some stamp disagrees.

-}
refreshConstraints : MVarEnv -> Mono.MonoType -> Mono.MonoType
refreshConstraints env monoType =
    if hasStaleConstraint env monoType then
        refreshConstraintsRebuild env monoType

    else
        monoType


{-| Returns whether any `MVar` in the type carries a stamp that differs from the
one `constraintOf` gives it now.
-}
hasStaleConstraint : MVarEnv -> Mono.MonoType -> Bool
hasStaleConstraint env monoType =
    case monoType of
        Mono.MVar mvarId stamped ->
            constraintOf mvarId env /= stamped

        Mono.MList _ inner ->
            hasStaleConstraint env inner

        Mono.MTuple _ elems ->
            List.any (hasStaleConstraint env) elems

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || hasStaleConstraint env t) False fields

        Mono.MCustom _ _ _ args ->
            List.any (hasStaleConstraint env) args

        Mono.MFunction _ _ args result ->
            List.any (hasStaleConstraint env) args || hasStaleConstraint env result

        _ ->
            False


{-| Returns a copy of the type with every `MVar` restamped from the `MVarEnv`.
-}
refreshConstraintsRebuild : MVarEnv -> Mono.MonoType -> Mono.MonoType
refreshConstraintsRebuild env monoType =
    case monoType of
        Mono.MVar mvarId _ ->
            Mono.MVar mvarId (constraintOf mvarId env)

        Mono.MList _ inner ->
            Mono.mList (refreshConstraintsRebuild env inner)

        Mono.MTuple _ elems ->
            Mono.mTuple (List.map (refreshConstraintsRebuild env) elems)

        Mono.MRecord _ fields ->
            Mono.mRecord (Dict.map (\_ t -> refreshConstraintsRebuild env t) fields)

        Mono.MCustom _ home name args ->
            Mono.mCustom home name (List.map (refreshConstraintsRebuild env) args)

        Mono.MFunction _ anno args result ->
            Mono.mFunction anno (List.map (refreshConstraintsRebuild env) args) (refreshConstraintsRebuild env result)

        _ ->
            monoType


{-| Maps `f` over a list, where `f` also says whether it changed its element.
Returns whether any element changed, and the original list itself when none
did.
-}
listMapChanged :
    (a -> ( Bool, a ))
    -> List a
    -> ( Bool, List a )
listMapChanged f list =
    listMapChangedHelp f list list False []


{-| Does the work of `listMapChanged`, with `acc` holding the mapped elements so
far in reverse.
-}
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


{-| Maps `f` over a dictionary's values, where `f` also says whether it changed
its value. Returns whether any value changed, and the original dictionary when
none did.
-}
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


{-| Returns the variable at the end of the chain of variable-to-variable bindings
that starts at `mvarId`, which is `mvarId` itself when it is bound to anything
other than a variable, or to nothing.

The returned substitution has each link passed on the way pointed directly at
that root. The chain stops early at a variable bound to itself or at a variable
already passed. The `MVarEnv` is returned unchanged.

-}
findRootVar : MVarEnv -> MVarId -> Substitution -> ( MVarId, Substitution, MVarEnv )
findRootVar env mvarId subst =
    findRootVarHelp env Set.empty mvarId subst


{-| Does the work of `findRootVar`, with `visited` holding the keys already
passed so that a cycle of bindings ends the walk.
-}
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


{-| Returns `ty` with each `MVar` that is not its own root replaced by the root
variable of its chain (`findRootVar`), stamped from the `MVarEnv`; a variable that
is its own root keeps its stamp. A variable bound to a type other
than a variable is left as it is; this replaces variables only by variables.
Also returns the substitution with its chains shortened.
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

        Mono.MFunction _ anno args ret ->
            let
                ( argsNorm, subst1, env1 ) =
                    normalizeList env subst args

                ( retNorm, subst2, env2 ) =
                    normalizeMonoType env1 subst1 ret
            in
            ( Mono.mFunction anno argsNorm retNorm, subst2, env2 )

        Mono.MList _ inner ->
            let
                ( innerNorm, subst1, env1 ) =
                    normalizeMonoType env subst inner
            in
            ( Mono.mList innerNorm, subst1, env1 )

        Mono.MTuple _ elems ->
            let
                ( elemsNorm, subst1, env1 ) =
                    normalizeList env subst elems
            in
            ( Mono.mTuple elemsNorm, subst1, env1 )

        Mono.MRecord _ fields ->
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
                ( Mono.mRecord fieldsNorm, subst1, env1 )

            else
                ( ty, subst1, env1 )

        Mono.MCustom _ can name args ->
            let
                ( argsNorm, subst1, env1 ) =
                    normalizeList env subst args
            in
            ( Mono.mCustom can name argsNorm, subst1, env1 )

        _ ->
            ( ty, subst, env )


{-| Applies `normalizeMonoType` to each type of a list, threading the
substitution.
-}
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


{-| Binds `mvarId` to `ty` in the substitution, after replacing each variable in
`ty` by the root of its chain. Unlike `insertBindingSafe`, it does no occurs
check, and it replaces any binding already there.
-}
insertBinding : MVarEnv -> MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
insertBinding env mvarId ty subst =
    let
        ( normalizedTy, subst1, env1 ) =
            normalizeMonoType env subst ty
    in
    ( Dict.insert (Id.toComparable mvarId) normalizedTy subst1, env1 )


{-| Returns the substitution that makes `canType` match `monoType`, starting from
an empty one, together with the `MVarEnv` with any number taints added.
Mismatched shapes contribute nothing rather than failing.
-}
unify : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> ( Substitution, MVarEnv )
unify env canType monoType =
    unifyHelp env canType monoType Dict.empty


{-| Like `unify`, but starts from `baseSubst` instead of an empty substitution.
-}
unifyExtend : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyExtend env canType monoType baseSubst =
    unifyHelp env canType monoType baseSubst


{-| Extends `subst` so that `canType` matches `monoType`, as `unify` describes.

For a variable already bound, the old binding and `monoType` are unified with
each other (`unifyMonoMono`) and then `monoType` replaces the old binding,
unless that binding would be cyclic, in which case the old binding stays. For
an unbound number variable meeting a `CEcoValue` variable, the `CEcoValue`
variable is the one bound, toward the number variable, and it is tainted as a
number, so the number variable stays open. A record's extension variable is
bound to a record of the fields `monoType` has beyond the canonical ones. A
`Holey` alias is unified through its body; its arguments are not related to
`monoType`.

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
                    case monoType of
                        Mono.MVar otherId _ ->
                            case ( constraintOf mvarId env, constraintOf otherId env ) of
                                ( Mono.CNumber, Mono.CEcoValue ) ->
                                    -- Binding the number var toward the boxed one, as the
                                    -- default branch would, would type a number argument as a
                                    -- boxed value while its value stays an unboxed integer.
                                    insertBindingSafe (State.taintNumber otherId env) otherId (Mono.MVar mvarId Mono.CNumber) subst

                                _ ->
                                    insertBindingSafe env mvarId monoType subst

                        _ ->
                            insertBindingSafe env mvarId monoType subst

        ( Can.TType (ModuleName.Canonical ( "elm", "core" ) "Basics") "Int" [], Mono.MInt ) ->
            ( subst, env )

        ( Can.TType (ModuleName.Canonical ( "elm", "core" ) "Basics") "Float" [], Mono.MFloat ) ->
            ( subst, env )

        ( Can.TType (ModuleName.Canonical ( "elm", "core" ) "Basics") "Bool" [], Mono.MBool ) ->
            ( subst, env )

        ( Can.TType (ModuleName.Canonical ( "elm", "core" ) "Char") "Char" [], Mono.MChar ) ->
            ( subst, env )

        ( Can.TType (ModuleName.Canonical ( "elm", "core" ) "String") "String" [], Mono.MString ) ->
            ( subst, env )

        ( Can.TLambda _ from to, Mono.MFunction _ anno args ret ) ->
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
                        unifyHelp env1 to (Mono.mFunction anno restArgs ret) subst1

        ( Can.TType _ _ args, Mono.MCustom _ _ _ monoArgs ) ->
            List.foldl
                (\( canArg, monoArg ) ( s, e ) ->
                    unifyHelp e canArg monoArg s
                )
                ( subst, env )
                (List.map2 Tuple.pair args monoArgs)

        ( Can.TType _ _ args, Mono.MList _ innerType ) ->
            case args of
                [ elemType ] ->
                    unifyHelp env elemType innerType subst

                _ ->
                    ( subst, env )

        ( Can.TRecord fields maybeExtension, Mono.MRecord _ monoFields ) ->
            let
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
                        remainingFields =
                            Dict.diff monoFields fields
                    in
                    insertBinding env1 extMvarId (Mono.mRecord remainingFields) substWithFields

                Nothing ->
                    ( substWithFields, env1 )

        ( Can.TTuple a b rest, Mono.MTuple _ monoTypes ) ->
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
                            unifyHelp e t (applySubstPure e s t) s
                        )
                        ( subst, env )
                        args
            in
            unifyHelp env1 inner monoType argSubst

        _ ->
            ( subst, env )


{-| Extends `subst` so that MonoTypes `m1` and `m2` agree, binding the variables
either one contains. This is how a variable that is re-bound passes what it
learns on to the variables in its old binding.

When two variables meet and one is a number and the other is not, the other is
bound toward the number variable and tainted as a number, whichever side it is
on. Function arguments, tuple elements and custom-type arguments are paired
position by position and any surplus on either side is ignored; record fields
are paired by name.

-}
unifyMonoMono : MVarEnv -> Mono.MonoType -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyMonoMono env m1 m2 subst =
    case ( m1, m2 ) of
        ( Mono.MVar mvarId1 _, Mono.MVar mvarId2 _ ) ->
            if Id.toComparable mvarId1 == Id.toComparable mvarId2 then
                ( subst, env )

            else
                case ( constraintOf mvarId1 env, constraintOf mvarId2 env ) of
                    ( Mono.CNumber, Mono.CEcoValue ) ->
                        -- Decided by the side table, not by the stamps, which may be stale.
                        insertBinding (State.taintNumber mvarId2 env) mvarId2 m1 subst

                    ( Mono.CEcoValue, Mono.CNumber ) ->
                        insertBinding (State.taintNumber mvarId1 env) mvarId1 m2 subst

                    _ ->
                        insertBinding env mvarId1 m2 subst

        ( Mono.MVar mvarId _, _ ) ->
            insertBinding env mvarId m2 subst

        ( _, Mono.MVar mvarId _ ) ->
            insertBinding env mvarId m1 subst

        ( Mono.MFunction _ _ args1 ret1, Mono.MFunction _ _ args2 ret2 ) ->
            let
                ( substWithArgs, env1 ) =
                    List.foldl
                        (\( a1, a2 ) ( s, e ) -> unifyMonoMono e a1 a2 s)
                        ( subst, env )
                        (List.map2 Tuple.pair args1 args2)
            in
            unifyMonoMono env1 ret1 ret2 substWithArgs

        ( Mono.MList _ inner1, Mono.MList _ inner2 ) ->
            unifyMonoMono env inner1 inner2 subst

        ( Mono.MCustom _ _ _ args1, Mono.MCustom _ _ _ args2 ) ->
            List.foldl
                (\( a1, a2 ) ( s, e ) -> unifyMonoMono e a1 a2 s)
                ( subst, env )
                (List.map2 Tuple.pair args1 args2)

        ( Mono.MRecord _ fields1, Mono.MRecord _ fields2 ) ->
            -- Needed so that, e.g., `{ n : Float }` re-unified with `{ n : number }`
            -- binds the number var to Float rather than leaving it to close to Int.
            Dict.foldl
                (\fieldName ft2 ( s, e ) ->
                    case Dict.get fieldName fields1 of
                        Just ft1 ->
                            unifyMonoMono e ft1 ft2 s

                        Nothing ->
                            ( s, e )
                )
                ( subst, env )
                fields2

        ( Mono.MTuple _ ts1, Mono.MTuple _ ts2 ) ->
            List.foldl
                (\( t1, t2 ) ( s, e ) -> unifyMonoMono e t1 t2 s)
                ( subst, env )
                (List.map2 Tuple.pair ts1 ts2)

        _ ->
            ( subst, env )


{-| Extends `subst` by unifying the first argument type of `canFuncType` with the
first of `argTypes`, the second with the second, and so on, ignoring the result
type. It stops at the first position where `canFuncType` is no longer an arrow,
so surplus arguments are ignored.
-}
unifyArgsOnly : MVarEnv -> Can.Type MVarId -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyArgsOnly env canFuncType argTypes subst =
    case ( canFuncType, argTypes ) of
        ( _, [] ) ->
            ( subst, env )

        ( Can.TLambda _ from _, [ singleArg ] ) ->
            unifyHelp env from singleArg subst

        ( Can.TLambda _ from to, arg0 :: rest ) ->
            let
                ( subst1, env1 ) =
                    unifyHelp env from arg0 subst
            in
            unifyArgsOnly env1 to rest subst1

        _ ->
            ( subst, env )


{-| Returns every argument type down a chain of functions, in order: for a
function returning a function, the outer arguments followed by the inner ones.
A type that is not a function gives the empty list.
-}
extractParamTypes : Mono.MonoType -> List Mono.MonoType
extractParamTypes monoType =
    case monoType of
        Mono.MFunction _ _ argTypes returnType ->
            argTypes ++ extractParamTypes returnType

        _ ->
            []


{-| Returns `monoType` with every bound variable replaced by its binding, itself
resolved in turn. An unbound variable, including an open number variable, is
kept. Where nothing changes the input itself is returned.
-}
resolveMonoVars : Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVars subst monoType =
    monoType
        |> resolveMonoVarsHelp Set.empty subst
        |> Tuple.second


{-| Does the work of `resolveMonoVars`, also returning whether anything changed.
`visiting` holds the variables being expanded, so that a cycle of bindings among
variables leaves the repeated variable in place instead of looping.
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
                                -- Left open: Prune closes number vars to Int.
                                ( False, monoType )

                            Mono.CEcoValue ->
                                ( False, monoType )

        Mono.MFunction _ anno args ret ->
            let
                ( argsChanged, newArgs ) =
                    listMapChanged (resolveMonoVarsHelp visiting subst) args

                ( retChanged, newRet ) =
                    resolveMonoVarsHelp visiting subst ret
            in
            if argsChanged || retChanged then
                ( True, Mono.mFunction anno newArgs newRet )

            else
                ( False, monoType )

        Mono.MList _ inner ->
            let
                ( changed, newInner ) =
                    resolveMonoVarsHelp visiting subst inner
            in
            if changed then
                ( True, Mono.mList newInner )

            else
                ( False, monoType )

        Mono.MTuple _ elems ->
            let
                ( changed, newElems ) =
                    listMapChanged (resolveMonoVarsHelp visiting subst) elems
            in
            if changed then
                ( True, Mono.mTuple newElems )

            else
                ( False, monoType )

        Mono.MRecord _ fields ->
            let
                ( changed, newFields ) =
                    dictMapChanged (resolveMonoVarsHelp visiting subst) fields
            in
            if changed then
                ( True, Mono.mRecord newFields )

            else
                ( False, monoType )

        Mono.MCustom _ can name args ->
            let
                ( changed, newArgs ) =
                    listMapChanged (resolveMonoVarsHelp visiting subst) args
            in
            if changed then
                ( True, Mono.mCustom can name newArgs )

            else
                ( False, monoType )

        _ ->
            ( False, monoType )


{-| Returns the MonoType that `canType` becomes under `subst`, with no
hash-consing.

Each arrow becomes a one-argument function, so `a -> b -> c` becomes a function
from `a` returning a function from `b`, not a two-argument function. A bound
variable becomes its binding with the variables in it resolved; an unbound one
stays an `MVar` stamped from `env`.

-}
applySubstPure : MVarEnv -> Substitution -> Can.Type MVarId -> Mono.MonoType
applySubstPure env subst canType =
    Tuple.first (applySubstPureI env subst canType Intern.disabled)


{-| Returns the same type as `applySubstPure`, sharing structure with the
hash-cons table `intern` without adding to it.

Each type built that is already in the table is replaced by the object there,
and one that is not is kept as built and not registered. So the table is never
changed and the caller has none to thread back. Passing `Intern.disabled` means
no sharing.

-}
applySubstPureRO : Intern -> MVarEnv -> Substitution -> Can.Type MVarId -> Mono.MonoType
applySubstPureRO intern env subst canType =
    Tuple.first (applySubstPureI env subst canType (Intern.readOnly intern))


{-| Returns the MonoType `canType` becomes under `subst`, as `applySubstPure`
describes, offering every list, tuple, record, custom type and function it
builds to `Intern.hashCons`, and returns the table after.

Children are offered before their parent. The exception is a bound variable,
whose resolved binding is returned without being offered.

A record's extension variable contributes the fields of its binding only when it
is bound directly to a record; otherwise only the record's own fields remain.
An `elm/core` `List` with other than one argument becomes a list of unit. A
`Holey` alias is applied by binding each of its parameter ids to its applied
argument and applying that to the body. The parameter ids are bound in order
into one substitution, so parameters sharing an id resolve to the last argument.

-}
applySubstPureI : MVarEnv -> Substitution -> Can.Type MVarId -> Intern -> ( Mono.MonoType, Intern )
applySubstPureI env subst canType intern =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Id.toComparable mvarId
            in
            case Dict.get key subst of
                Just monoType ->
                    ( resolveMonoVars subst monoType, intern )

                Nothing ->
                    let
                        constraint =
                            constraintOf mvarId env
                    in
                    case constraint of
                        Mono.CNumber ->
                            -- Left open: Prune closes number vars to Int.
                            ( Mono.MVar mvarId constraint, intern )

                        Mono.CEcoValue ->
                            ( Mono.MVar mvarId constraint, intern )

        Can.TLambda _ from to ->
            applySubstLambdaChainI env subst [ from ] to intern

        Can.TType canonical name args ->
            let
                ( monoArgs, intern1 ) =
                    applySubstListI env subst args intern

                isElmCore =
                    case canonical of
                        ModuleName.Canonical ( "elm", "core" ) _ ->
                            True

                        _ ->
                            False
            in
            if isElmCore then
                case name of
                    "Int" ->
                        ( Mono.MInt, intern1 )

                    "Float" ->
                        ( Mono.MFloat, intern1 )

                    "Bool" ->
                        ( Mono.MBool, intern1 )

                    "Char" ->
                        ( Mono.MChar, intern1 )

                    "String" ->
                        ( Mono.MString, intern1 )

                    "List" ->
                        case monoArgs of
                            [ inner ] ->
                                Intern.hashCons (Mono.mList inner) intern1

                            _ ->
                                Intern.hashCons (Mono.mList Mono.MUnit) intern1

                    _ ->
                        Intern.hashCons (Mono.mCustom canonical name monoArgs) intern1

            else
                Intern.hashCons (Mono.mCustom canonical name monoArgs) intern1

        Can.TRecord fields maybeExtension ->
            let
                baseFields =
                    case maybeExtension of
                        Just extMvarId ->
                            case Dict.get (Id.toComparable extMvarId) subst of
                                Just (Mono.MRecord _ baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                ( monoFields, intern1 ) =
                    Dict.foldl
                        (\k (Can.FieldType _ t) ( acc, i ) ->
                            let
                                ( fieldMono, i1 ) =
                                    applySubstPureI env subst t i
                            in
                            ( Dict.insert k fieldMono acc, i1 )
                        )
                        ( baseFields, intern )
                        fields
            in
            Intern.hashCons (Mono.mRecord monoFields) intern1

        Can.TTuple a b rest ->
            let
                ( elems, intern1 ) =
                    applySubstListI env subst (a :: b :: rest) intern
            in
            Intern.hashCons (Mono.mTuple elems) intern1

        Can.TUnit ->
            ( Mono.MUnit, intern )

        Can.TAlias _ _ _ (Can.Filled inner) ->
            applySubstPureI env subst inner intern

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                ( newSubst, intern1 ) =
                    List.foldl
                        (\( paramId, t ) ( s, i ) ->
                            let
                                ( argMono, i1 ) =
                                    applySubstPureI env subst t i
                            in
                            ( Dict.insert (Id.toComparable paramId) argMono s, i1 )
                        )
                        ( subst, intern )
                        args
            in
            applySubstPureI env newSubst inner intern1


{-| Applies `applySubstPureI` to each type of a list, threading the hash-cons
table from left to right.
-}
applySubstListI : MVarEnv -> Substitution -> List (Can.Type MVarId) -> Intern -> ( List Mono.MonoType, Intern )
applySubstListI env subst types intern =
    case types of
        [] ->
            ( [], intern )

        t :: rest ->
            let
                ( head, intern1 ) =
                    applySubstPureI env subst t intern

                ( tail, intern2 ) =
                    applySubstListI env subst rest intern1
            in
            ( head :: tail, intern2 )


{-| Returns the MonoType `canType` becomes under `subst`, as `applySubstPureI`
describes, after dropping from a substitution of more than eight bindings every
binding not reachable from the variables of `canType`.

Reachable means a variable of `canType`, or a variable in the binding of a
reachable one. Bindings of variables from other schemes that share the
substitution are therefore not consulted.

-}
applySubstFiltered :
    MVarEnv
    -> Substitution
    -> Can.Type MVarId
    -> Intern
    -> ( Mono.MonoType, Intern )
applySubstFiltered mvarEnv subst canType intern =
    if Dict.size subst <= 8 then
        -- Filtering a small substitution costs more than it saves.
        applySubstPureI mvarEnv subst canType intern

    else
        let
            rootIds =
                collectMVarIds canType []

            rootKeys =
                List.map Id.toComparable rootIds

            -- Transitive, so a chain like x -> MVar 10, 10 -> MInt survives whole.
            reachableKeys =
                closureOverSubst rootKeys subst

            filteredSubst =
                Dict.filter
                    (\key _ -> Set.member key reachableKeys)
                    subst
        in
        applySubstPureI mvarEnv filteredSubst canType intern


{-| Returns the keys reachable from `initialKeys`: the keys themselves, and the
keys of the variables in the binding of any reachable key.
-}
closureOverSubst : List Int -> Substitution -> Set Int
closureOverSubst initialKeys subst =
    closureOverSubstHelp initialKeys Set.empty subst


{-| Does the work of `closureOverSubst`, with `pending` the keys still to visit.
-}
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


{-| Returns the variables of a MonoType that are not in `acc`, each once, in
front of `acc`.
-}
collectMVarIdsFromMono : Mono.MonoType -> List MVarId -> List MVarId
collectMVarIdsFromMono monoType acc =
    let
        seen =
            List.foldl (\id s -> Set.insert (Id.toComparable id) s) Set.empty acc
    in
    Tuple.first (collectMVarIdsFromMonoHelp monoType ( acc, seen ))


{-| Does the work of `collectMVarIdsFromMono`, with `seen` holding the keys
already in the list.
-}
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

        Mono.MFunction _ _ args result ->
            let
                argsPair =
                    List.foldl (\a accPair -> collectMVarIdsFromMonoHelp a accPair) pair args
            in
            collectMVarIdsFromMonoHelp result argsPair

        Mono.MList _ inner ->
            collectMVarIdsFromMonoHelp inner pair

        Mono.MTuple _ elements ->
            List.foldl (\e accPair -> collectMVarIdsFromMonoHelp e accPair) pair elements

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t accPair -> collectMVarIdsFromMonoHelp t accPair) pair fields

        Mono.MCustom _ _ _ args ->
            List.foldl (\a accPair -> collectMVarIdsFromMonoHelp a accPair) pair args

        _ ->
            pair


{-| Returns the curried function MonoType for an arrow chain, with `argsAcc` the
argument types gathered so far, innermost first, and `to` the rest of the chain.
Each function built is offered to `Intern.hashCons`.
-}
applySubstLambdaChainI : MVarEnv -> Substitution -> List (Can.Type MVarId) -> Can.Type MVarId -> Intern -> ( Mono.MonoType, Intern )
applySubstLambdaChainI env subst argsAcc to intern =
    case to of
        Can.TLambda _ from innerTo ->
            applySubstLambdaChainI env subst (from :: argsAcc) innerTo intern

        _ ->
            List.foldl
                (\argType ( acc, i ) ->
                    let
                        ( argMono, i1 ) =
                            applySubstPureI env subst argType i
                    in
                    Intern.hashCons (Mono.mFunction Mono.topDeclOther [ argMono ] acc) i1
                )
                (applySubstPureI env subst to intern)
                argsAcc


{-| Builds the scheme for `canType`, with every variable replaced by a fresh one
from the `MVarEnv`, so its ids are shared with no existing substitution.

Each fresh variable is a number exactly when the one it replaces is. The
argument types are the arguments down the arrow chain, looking through `Filled`
aliases, and the result type is what remains.

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


{-| Returns a copy of a scheme with every variable in `varIds` replaced by a fresh
one, so bindings made at an earlier use of the scheme do not apply to this one.

Each fresh variable is a number exactly when the `MVarEnv` records the old one
as a number now, which includes a number taint the old one received at an
earlier use.

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


{-| Returns the key of the fresh variable `renameMap` gives for key `id`, or `id`
itself when it has none.
-}
applyRenameToId : Dict.Dict Int MVarId -> Int -> Int
applyRenameToId renameMap id =
    case Dict.get id renameMap of
        Just newId ->
            Id.toComparable newId

        Nothing ->
            id


{-| A renaming of a scheme's variables to fresh ones, as `buildSchemeRenaming`
builds it.

`renameMap` is keyed by the old variable's comparable key. `freshIds` is in
reverse order of the old variables. `numberVarKeys` holds the keys of the fresh
variables that are numbers.

-}
type alias SchemeRenamingAcc =
    { renameMap : Dict.Dict Int MVarId
    , freshIds : List MVarId
    , numberVarKeys : Set Int
    , env : MVarEnv
    }


{-| Builds a renaming of `varIds` to fresh variables from the `MVarEnv`, each a
number exactly when `constraintOf` says the old one is.
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


{-| Returns `canType` with each variable renamed by `renameMap`, including record
extension variables and alias parameters. A variable the map lacks is kept.
Arrow ids are copied unchanged.
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

        Can.TLambda aid from to ->
            -- The arrow id is copied, so the original and the renamed copy
            -- share it; a consumer keying on arrow ids would see all uses of a
            -- scheme as one arrow.
            Can.TLambda aid
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


{-| Returns the variables of a canonical type that are not in `acc`, each once, in
front of `acc`, including record extension variables and the variables of alias
arguments.
-}
collectMVarIds : Can.Type MVarId -> List MVarId -> List MVarId
collectMVarIds canType acc =
    let
        seen =
            List.foldl (\id s -> Set.insert (Id.toComparable id) s) Set.empty acc
    in
    Tuple.first (collectMVarIdsHelp canType ( acc, seen ))


{-| Does the work of `collectMVarIds`, with `seen` holding the keys already in
the list.
-}
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

        Can.TLambda _ from to ->
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


{-| Returns the argument types down an arrow chain, after those already in `acc`
(held innermost first), and the result type that remains. `Filled` aliases are
looked through; a `Holey` one ends the chain.
-}
flattenTLambda : Can.Type MVarId -> List (Can.Type MVarId) -> ( List (Can.Type MVarId), Can.Type MVarId )
flattenTLambda canType acc =
    case canType of
        Can.TLambda _ from to ->
            flattenTLambda to (from :: acc)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            flattenTLambda inner acc

        _ ->
            ( List.reverse acc, canType )


{-| Unifies a scheme's argument types with the types of the arguments supplied at
a call, starting from `baseSubst`, and returns the substitution, the scheme's
whole type under it as a curried function MonoType, and the `MVarEnv` with any
number taints added.

Arguments are paired by position; those beyond the scheme's arity are ignored.
Every argument type of the function MonoType, supplied or not, is the scheme's
argument type under the final substitution, not the supplied type. Types are
shared with the hash-cons table `intern` as `applySubstPureRO` describes.

-}
unifyCallSiteDirect :
    Intern
    -> MVarEnv
    -> List (Can.Type MVarId)
    -> Can.Type MVarId
    -> List Mono.MonoType
    -> Substitution
    -> ( Substitution, Mono.MonoType, MVarEnv )
unifyCallSiteDirect intern env schemeArgTypes schemeResultType argMonoTypes baseSubst =
    unifyCallSiteDirectWithExpected intern env schemeArgTypes schemeResultType argMonoTypes Nothing baseSubst


{-| Does what `unifyCallSiteDirect` does and, when given the call's expected
result type, also unifies the scheme with it.

The part of the scheme a call leaves unapplied, its residual, is the arrow chain
of the argument types not supplied ending in the scheme's result type. That
residual is unified with the expected result type under the substitution so far.
This lets what the context knows about the result reach the scheme's
variables: for example that `List.map swap` here returns `List ( Int, Int )`
fixes the type `swap` is used at.

When the call supplies more arguments than the scheme takes, the surplus is
applied to the scheme's result, so the expected result type is first wrapped in
one arrow per surplus argument. For `Tuple.first fns 1` the scheme's result is
then unified with a function from `Int`, not with the final result.

-}
unifyCallSiteDirectWithExpected :
    Intern
    -> MVarEnv
    -> List (Can.Type MVarId)
    -> Can.Type MVarId
    -> List Mono.MonoType
    -> Maybe (Can.Type MVarId)
    -> Substitution
    -> ( Substitution, Mono.MonoType, MVarEnv )
unifyCallSiteDirectWithExpected intern env schemeArgTypes schemeResultType argMonoTypes maybeCallResultCanType baseSubst =
    let
        ( substAfterArgs0, env0 ) =
            unifyArgTypesZip env schemeArgTypes argMonoTypes baseSubst

        ( substAfterArgs, env1 ) =
            case maybeCallResultCanType of
                Just callResultCanType ->
                    let
                        schemeResidual =
                            buildCurriedCanType (List.drop (List.length argMonoTypes) schemeArgTypes) schemeResultType

                        callResultMono =
                            applySubstPureRO intern env0 substAfterArgs0 callResultCanType

                        -- Over-application: the surplus arguments apply to the
                        -- scheme's result, so it must unify with a function.
                        surplusArgMonos =
                            List.drop (List.length schemeArgTypes) argMonoTypes

                        expectedResidualMono =
                            List.foldr
                                (\argMono acc -> Mono.mFunction Mono.topDeclOther [ argMono ] acc)
                                callResultMono
                                surplusArgMonos
                    in
                    unifyHelp env0 schemeResidual expectedResidualMono substAfterArgs0

                Nothing ->
                    ( substAfterArgs0, env0 )

        -- From the scheme, not argMonoTypes: a later argument can widen what an
        -- earlier one supplied, e.g. the full shape of a record whose extension
        -- var was unbound when that argument was typed.
        suppliedSchemeArgs =
            List.take (List.length argMonoTypes) schemeArgTypes

        resolvedSuppliedArgs =
            List.map (applySubstPureRO intern env1 substAfterArgs) suppliedSchemeArgs

        remainingSchemeArgs =
            List.drop (List.length argMonoTypes) schemeArgTypes

        resolvedAllArgs =
            resolvedSuppliedArgs ++ List.map (applySubstPureRO intern env1 substAfterArgs) remainingSchemeArgs

        resultMono =
            applySubstPureRO intern env1 substAfterArgs schemeResultType

        funcMonoType =
            buildCurriedFuncType schemeArgTypes resolvedAllArgs resultMono
    in
    ( substAfterArgs, funcMonoType, env1 )


{-| Extends `subst` by unifying each canonical argument type with the MonoType in
the same position, stopping at the end of the shorter list.
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


{-| Returns a curried function MonoType with one one-argument function per
element of `resolvedArgs`, ending in `resultMono`. `schemeArgs` only bounds how
many are used: the chain stops at the end of the shorter list.
-}
buildCurriedFuncType : List (Can.Type MVarId) -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildCurriedFuncType schemeArgs resolvedArgs resultMono =
    case ( schemeArgs, resolvedArgs ) of
        ( _ :: schemeRest, arg :: argRest ) ->
            Mono.mFunction Mono.topDeclOther [ arg ] (buildCurriedFuncType schemeRest argRest resultMono)

        _ ->
            resultMono


{-| Returns the canonical arrow chain from `args` to `result`, or `result` itself
when `args` is empty. The arrows are new, so they carry no arrow id
(`Can.tLambda`).
-}
buildCurriedCanType : List (Can.Type MVarId) -> Can.Type MVarId -> Can.Type MVarId
buildCurriedCanType args result =
    case args of
        [] ->
            result

        first :: rest ->
            Can.tLambda first (buildCurriedCanType rest result)


{-| Binds `targetId` to `monoType`, with each variable in it replaced by the root
of its chain, replacing any binding already there. When `targetId` is itself a
root of a variable in `monoType`, the binding would be cyclic and the
substitution is returned unchanged.
-}
insertBindingSafe : MVarEnv -> MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
insertBindingSafe env targetId monoType subst =
    case normalizeAndOccursCheck env targetId subst monoType of
        Nothing ->
            ( subst, env )

        Just ( normalizedTy, subst1, env1 ) ->
            ( Dict.insert (Id.toComparable targetId) normalizedTy subst1, env1 )


{-| Returns `ty` normalized as `normalizeMonoType` does, with the substitution
whose chains were shortened on the way, or `Nothing` when any variable in `ty`
has `targetId` as its root.
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

        Mono.MFunction _ anno args ret ->
            case normalizeAndOccursCheckList env targetId subst args of
                Nothing ->
                    Nothing

                Just ( argsNorm, subst1, env1 ) ->
                    case normalizeAndOccursCheck env1 targetId subst1 ret of
                        Nothing ->
                            Nothing

                        Just ( retNorm, subst2, env2 ) ->
                            Just ( Mono.mFunction anno argsNorm retNorm, subst2, env2 )

        Mono.MList _ inner ->
            case normalizeAndOccursCheck env targetId subst inner of
                Nothing ->
                    Nothing

                Just ( innerNorm, subst1, env1 ) ->
                    Just ( Mono.mList innerNorm, subst1, env1 )

        Mono.MTuple _ elems ->
            case normalizeAndOccursCheckList env targetId subst elems of
                Nothing ->
                    Nothing

                Just ( elemsNorm, subst1, env1 ) ->
                    Just ( Mono.mTuple elemsNorm, subst1, env1 )

        Mono.MRecord _ fields ->
            case normalizeAndOccursCheckDict env targetId subst fields of
                Nothing ->
                    Nothing

                Just ( fieldsNorm, subst1, env1 ) ->
                    Just ( Mono.mRecord fieldsNorm, subst1, env1 )

        Mono.MCustom _ can name args ->
            case normalizeAndOccursCheckList env targetId subst args of
                Nothing ->
                    Nothing

                Just ( argsNorm, subst1, env1 ) ->
                    Just ( Mono.mCustom can name argsNorm, subst1, env1 )

        _ ->
            Just ( ty, subst, env )


{-| Applies `normalizeAndOccursCheck` to each type of a list, giving `Nothing`
if any element does.
-}
normalizeAndOccursCheckList : MVarEnv -> MVarId -> Substitution -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Substitution, MVarEnv )
normalizeAndOccursCheckList env targetId subst types =
    normalizeAndOccursCheckListHelp env targetId subst types []


{-| Does the work of `normalizeAndOccursCheckList`, with `acc` holding the
normalized elements so far in reverse.
-}
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


{-| Applies `normalizeAndOccursCheck` to each field type of a record, giving
`Nothing` if any field does.
-}
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
