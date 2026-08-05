module Compiler.Monomorphize.TypeSubst exposing
    ( applySubstPure, applySubstPureRO
    , extractParamTypes
    , unify, unifyExtend, unifyArgsOnly, unifyCallSiteDirect, unifyCallSiteDirectWithExpected
    , buildSchemeInfo, refreshSchemeInfo
    , applySubstFiltered
    , refreshConstraints
    )

{-| Type substitution and unification for monomorphization.

This module handles converting canonical types to monomorphic types
by applying type variable substitutions. All substitutions are keyed
by MVarId (as Int via Id.toComparable), not by Name.


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


{-| Re-stamp every `MVar id _` in a MonoType with its CURRENT class constraint
from the shared side table (`constraintOf`). Join-R records a number taint in the
table at merge time; a copy stamped `MVar id CEcoValue` before that merge still
carries the stale annotation. Applying this before building a specialization key
(`Mono.toComparableMonoType`) reconciles the stamped annotation with the
authoritative side table, so a tainted number var keys to the concrete Int
specialization (D4) instead of the boxed-erased sentinel.

Identity-preserving (perf, see plans/monomorphization-perf-analysis.md Q1): this
runs on the hottest keying path (every `enqueueSpec`, every instance lookup). A
stale stamp is RARE (only Join-R-tainted copies), so an allocation-free pre-scan
(`hasStaleConstraint`) short-circuits the common case and returns the input by
reference — no deep copy. Only when a genuine disagreement exists is the type
rebuilt.

-}
refreshConstraints : MVarEnv -> Mono.MonoType -> Mono.MonoType
refreshConstraints env monoType =
    if hasStaleConstraint env monoType then
        refreshConstraintsRebuild env monoType

    else
        monoType


{-| Does any `MVar id stamped` in the type disagree with `constraintOf id env`?
Zero-allocation short-circuiting walk (records use non-short-circuit foldl, cheap).
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
                    case monoType of
                        Mono.MVar otherId _ ->
                            case ( constraintOf mvarId env, constraintOf otherId env ) of
                                ( Mono.CNumber, Mono.CEcoValue ) ->
                                    -- Symmetric join (J2), canonical-vs-mono form. A number
                                    -- canonical tvar is unifying with a boxed (CEcoValue) mono
                                    -- var — typically a number ARGUMENT being resolved against a
                                    -- polymorphic/kernel-ABI parameter slot (e.g. Debug.log's `a`,
                                    -- PreserveVars). Binding the number var TOWARD the boxed var
                                    -- (the default) would erase its number-ness, so the arg would
                                    -- be typed CEcoValue while its value stays an unboxed i64 —
                                    -- an i64/ptr boundary mismatch. Instead: number dominates.
                                    -- Bind the boxed var toward the number var (as an open CNumber
                                    -- residual) and taint it, leaving the number var open so it
                                    -- closes to Int; the boxed ABI slot (a separate, already-built
                                    -- funcMonoType) still drives boxing at the call boundary.
                                    insertBindingSafe (State.taintNumber otherId env) otherId (Mono.MVar mvarId Mono.CNumber) subst

                                _ ->
                                    insertBindingSafe env mvarId monoType subst

                        _ ->
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

        ( Can.TLambda from to, Mono.MFunction _ anno args ret ) ->
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
                case ( constraintOf mvarId1 env, constraintOf mvarId2 env ) of
                    ( Mono.CNumber, Mono.CEcoValue ) ->
                        -- Symmetric constraint join. The class constraint is the join
                        -- of members: CNumber dominates CEcoValue. Make the number var
                        -- (mvarId1) the class representative — bind the boxed var toward
                        -- it (Join-W, subst-carried, so routing survives however the env
                        -- is threaded) — AND taint the boxed var Number in the shared
                        -- side table (Join-R, so copies of its type stamped before this
                        -- merge still close to Int and key to the concrete Int spec).
                        -- The decision reads constraintOf (the authoritative side table),
                        -- not the stamped annotations, and is outcome-symmetric with the
                        -- mirror case below.
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
            -- Recurse into matching fields. Without this, re-binding a scheme var
            -- whose old and new monos are records (e.g. a `map`/fold combinator's
            -- element var bound to `{n:Float}` from the function and then re-unified
            -- against `{n: CNumber}` from the container) would drop the field-level
            -- propagation, leaving the container element defaulted to Int.
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


{-| Extract parameter types from a Mono.mFunction type.
When we have a function type MFunction [arg1, arg2, ...] returnType,
this extracts the list of argument types [arg1, arg2, ...].
For non-function types, returns an empty list.
-}
extractParamTypes : Mono.MonoType -> List Mono.MonoType
extractParamTypes monoType =
    case monoType of
        Mono.MFunction _ _ argTypes returnType ->
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
                                -- Quiescence-before-defaulting: preserve the number
                                -- var as a residual (no change). CNumber is discharged
                                -- only by the residual-number close (fused into Prune) at the end of
                                -- monomorphization.
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


{-| Apply a type substitution to a canonical type to produce a monomorphic type.

INVARIANT: Preserves TLambda staging exactly.

    a -> b -> c becomes Mono.mFunction [a] (Mono.mFunction [b] c), NOT Mono.mFunction [a, b] c.

Each TLambda in the Can.Type MVarId produces a single-arg Mono.mFunction. This preserves
Elm's curried semantics faithfully.

GlobalOpt will flatten these types to match closure param counts (GOPT\_016).
The flattening happens there, not here, because Monomorphize is staging-agnostic.

-}
applySubstPure : MVarEnv -> Substitution -> Can.Type MVarId -> Mono.MonoType
applySubstPure env subst canType =
    Tuple.first (applySubstPureI env subst canType Intern.disabled)


{-| `applySubstPure` **reading** a hash-cons table without writing to it (K7 of
`plans/mono-comparable-key-optimization.md`).

`applySubstPure`'s callers hold no place to put an updated table, so before K7
they ran the whole traversal with `Intern.disabled` and every type they built
was uninterned — never shared, and therefore separately retained. That was 42%
of all composite `hashCons` traffic on a subst self-compile (plan §16), diluting
K6's win by exactly that much.

This entry point closes the gap without any state threading: it probes the table
and returns the EXISTING canonical object on a hit, and on a miss keeps the node
it just built and registers nothing. Since nothing is registered there is no new
table, so the caller passes a table it already holds and forgets about it — one
extra ARGUMENT, never a returned pair, and none of the `state`/`state1` hazard
that threading brings.

Passing `Intern.disabled` is still valid and still means "no interning": the
read-only view of a disabled table is a disabled table.

-}
applySubstPureRO : Intern -> MVarEnv -> Substitution -> Can.Type MVarId -> Mono.MonoType
applySubstPureRO intern env subst canType =
    Tuple.first (applySubstPureI env subst canType (Intern.readOnly intern))


{-| `applySubstPure` with a hash-consing table threaded through it (K6 of
`plans/mono-comparable-key-optimization.md`).

Every composite this traversal builds is offered to `Intern.hashCons`, so a
structure that already exists is returned as the EXISTING object instead of a
fresh one. A self-compile builds 14.8M type nodes for 116K distinct types
(plan §13), and this is where nearly all of them are built.

Children are canonicalised before their parent, so the bucket confirm inside
`hashCons` compares child pointers rather than walking subtrees. The one
exception is the `Can.TVar` branch, whose `resolveMonoVars` result is left
uncanonical (that function is identity-preserving where nothing changes, so its
output is already shared in the common case); a parent above such a child pays a
structural compare on a bucket hit.

Callers with no table to thread pass `Intern.disabled`, which turns every
`hashCons` into an identity; callers that hold a table but cannot thread an
updated one back go through `applySubstPureRO`, whose read-only view shares on a
hit and registers nothing.

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
                            -- Quiescence-before-defaulting: preserve the number var
                            -- as a residual. CNumber->MInt is discharged only by the
                            -- residual-number closing (fused into Prune) at the end
                            -- of monomorphization.
                            ( Mono.MVar mvarId constraint, intern )

                        Mono.CEcoValue ->
                            ( Mono.MVar mvarId constraint, intern )

        Can.TLambda from to ->
            applySubstLambdaChainI env subst [ from ] to intern

        Can.TType canonical name args ->
            let
                ( monoArgs, intern1 ) =
                    applySubstListI env subst args intern

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
                -- Start with base fields from extension variable if present
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

                -- Convert explicit fields and merge into base using foldl
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


{-| Apply applySubstPureI to a list of canonical types. Env-pure (MONO\_028 J5): the
MVarEnv is read-only here — applySubstPureI never taints or allocates fresh vars — so
there is no env to thread back. The Intern table IS threaded, left to right.
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


{-| Apply a substitution to a canonical type, but only for MVarIds that
actually appear in the type. This prevents cross-scheme contamination
when a substitution carries bindings from multiple schemes.

Filtering is by the MVarIds present in canType (sufficient because MVarIds are
globally unique post-AssignMVarIds), so no scheme/FreeVars argument is needed.

-}
applySubstFiltered :
    MVarEnv
    -> Substitution
    -> Can.Type MVarId
    -> Intern
    -> ( Mono.MonoType, Intern )
applySubstFiltered mvarEnv subst canType intern =
    if Dict.size subst <= 8 then
        -- For small substitutions, filtering costs more than just applying
        -- the full subst directly (the overhead of building Set + Dict.filter
        -- exceeds any savings from a slightly smaller dict).
        applySubstPureI mvarEnv subst canType intern

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
        applySubstPureI mvarEnv filteredSubst canType intern


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


{-| Collect a TLambda chain iteratively, then build the curried Mono.mFunction structure.
-}
applySubstLambdaChainI : MVarEnv -> Substitution -> List (Can.Type MVarId) -> Can.Type MVarId -> Intern -> ( Mono.MonoType, Intern )
applySubstLambdaChainI env subst argsAcc to intern =
    case to of
        Can.TLambda from innerTo ->
            applySubstLambdaChainI env subst (from :: argsAcc) innerTo intern

        _ ->
            List.foldl
                (\argType ( acc, i ) ->
                    let
                        ( argMono, i1 ) =
                            applySubstPureI env subst argType i
                    in
                    Intern.hashCons (Mono.mFunction Mono.LTop [ argMono ] acc) i1
                )
                (applySubstPureI env subst to intern)
                argsAcc



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
Mono.mFunction in one pass. Returns the updated substitution and the funcMonoType.

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

                        callResultMono =
                            applySubstPureRO intern env0 substAfterArgs0 callResultCanType

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
                                (\argMono acc -> Mono.mFunction Mono.LTop [ argMono ] acc)
                                callResultMono
                                surplusArgMonos
                    in
                    unifyHelp env0 schemeResidual expectedResidualMono substAfterArgs0

                Nothing ->
                    ( substAfterArgs0, env0 )

        -- Derive supplied arg types by applying the final substitution to the
        -- scheme's arg types, not from argMonoTypes directly. This matters when
        -- a supplied arg was a row-polymorphic local function whose argMono was
        -- narrowed (e.g. its record extension var was unbound at argument
        -- preparation time). Pulling from scheme-via-applySubst lets the cross-
        -- arg unification (e.g. a third arg giving the full record shape) flow
        -- back into the earlier positions instead of preserving the narrow type.
        -- applySubstPure is env-pure (J5), so the arg/result resolution below reads
        -- env1 (the last tainting step: unifyArgTypesZip + the residual unifyHelp)
        -- without threading — there is no further env to carry.
        suppliedSchemeArgs =
            List.take (List.length argMonoTypes) schemeArgTypes

        resolvedSuppliedArgs =
            List.map (applySubstPureRO intern env1 substAfterArgs) suppliedSchemeArgs

        -- Resolve REMAINING scheme arg types through substitution
        remainingSchemeArgs =
            List.drop (List.length argMonoTypes) schemeArgTypes

        resolvedAllArgs =
            resolvedSuppliedArgs ++ List.map (applySubstPureRO intern env1 substAfterArgs) remainingSchemeArgs

        -- Apply substitution to result type
        resultMono =
            applySubstPureRO intern env1 substAfterArgs schemeResultType

        -- Build the function mono type directly
        funcMonoType =
            buildCurriedFuncType schemeArgTypes resolvedAllArgs resultMono
    in
    ( substAfterArgs, funcMonoType, env1 )


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


{-| Build a curried Mono.mFunction mirroring the TLambda structure.
Each scheme arg corresponds to one level of currying.
-}
buildCurriedFuncType : List (Can.Type MVarId) -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildCurriedFuncType schemeArgs resolvedArgs resultMono =
    case ( schemeArgs, resolvedArgs ) of
        ( _ :: schemeRest, arg :: argRest ) ->
            Mono.mFunction Mono.LTop [ arg ] (buildCurriedFuncType schemeRest argRest resultMono)

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
