module Compiler.Monomorphize.Specialize exposing (specializeNode)

{-| Expression and node specialization for monomorphization.

This module handles converting typed optimized expressions and nodes
into monomorphized form by applying type substitutions.


# Specialization

@docs specializeNode

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State exposing (LocalMultiState, MVarEnv, MonoState, SchemeInfo, Substitution, ValueMultiState, VarEnv, WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet
import Dict
import Set
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== INTERNAL TYPES ==========


{-| A processed argument that might be pending specialization.

Accessors need special handling because they must be specialized AFTER
call-site type unification to receive the fully-resolved record type.

Number-boxed kernels (like Basics.add) need special handling because they
must be specialized AFTER call-site type unification to determine if they
can use the monomorphic numeric type (enabling intrinsics) or must fall
back to the boxed ABI.

-}
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name (Can.Type MVarId)
    | PendingExpr (TOpt.Expr MVarId) Substitution (Can.Type MVarId)
    | LocalFunArg Name (Can.Type MVarId)
    | PendingNumberValue Name (Can.Type MVarId)



-- ========== SCHEME INFO ==========


{-| Get or build SchemeInfo for a callee, using the cache in MonoState.

buildSchemeInfo freshens the callee's MVarIds using the global MVarEnv,
so cached schemes never share MVarIds with callers and can be reused safely.

-}
getOrBuildSchemeInfo : Can.Type MVarId -> Maybe TOpt.Global -> MonoState -> ( SchemeInfo, MonoState )
getOrBuildSchemeInfo funcCanType maybeGlobal state =
    case maybeGlobal of
        Just global ->
            let
                accum =
                    state.accum
            in
            case Data.Map.get TOpt.toComparableGlobal global accum.schemeCache of
                Just cachedInfo ->
                    -- Cached scheme exists. Re-freshen its MVarIds to avoid stale
                    -- bindings from previous unifications leaking into this call.
                    -- Without this, e.g. Just(Float) from one call site would leak
                    -- into Just(Bool) inside Maybe.map.
                    let
                        ( info, mvarEnv1 ) =
                            TypeSubst.refreshSchemeInfo state.ctx.mvarEnv cachedInfo

                        ctx1 =
                            let
                                ctx =
                                    state.ctx
                            in
                            { ctx | mvarEnv = mvarEnv1 }
                    in
                    ( info, { state | ctx = ctx1 } )

                Nothing ->
                    -- Build SchemeInfo from the global's canonical annotation type if available.
                    let
                        canonicalCanTypeForScheme : Can.Type MVarId
                        canonicalCanTypeForScheme =
                            case Data.Map.get TOpt.toComparableGlobal global state.ctx.annotations of
                                Just (Can.Forall _ annType) ->
                                    annType

                                Nothing ->
                                    Utils.Crash.crash ("getOrBuildSchemeInfo: no annotation entry for global " ++ TOpt.toComparableGlobal global)

                        ( info, mvarEnv1 ) =
                            TypeSubst.buildSchemeInfo state.ctx.mvarEnv canonicalCanTypeForScheme

                        newCache =
                            Data.Map.insert TOpt.toComparableGlobal global info accum.schemeCache

                        ctx1 =
                            let
                                ctx =
                                    state.ctx
                            in
                            { ctx | mvarEnv = mvarEnv1 }
                    in
                    ( info, { state | accum = { accum | schemeCache = newCache }, ctx = ctx1 } )

        Nothing ->
            -- Local/anonymous callee: build on demand, don't cache
            let
                ( info, mvarEnv1 ) =
                    TypeSubst.buildSchemeInfo state.ctx.mvarEnv funcCanType

                ctx1 =
                    let
                        ctx =
                            state.ctx
                    in
                    { ctx | mvarEnv = mvarEnv1 }
            in
            ( info, { state | ctx = ctx1 } )



-- ========== FREEVARS HELPERS ==========


{-| Return True if a top-level global function has an explicit annotation with
no generalized type variables (i.e. freeVars = {} in Can.Forall freeVars annType).

Only returns True when we have a confirmed Can.Forall entry with empty freeVars.
Returns False for globals with no annotation entry (Nothing case) — those must
go through the SchemeInfo path since funcMeta.tipe may contain unresolved TVars.

-}
isMonomorphicGlobal : TOpt.Global -> MonoState -> Bool
isMonomorphicGlobal global state =
    case Data.Map.get TOpt.toComparableGlobal global state.ctx.annotations of
        Just (Can.Forall freeVars _) ->
            Dict.isEmpty freeVars

        Nothing ->
            False


{-| Apply substitution with FreeVars scoping from the current global's annotation.
Only substitutes MVarIds that actually appear in canType, preventing cross-scheme
contamination. Uses cached currentFreeVars from SpecContext (set in processOneWorkItem).

Returns an UPDATED state: the hash-consing table this traversal fills (K6 of
`plans/mono-comparable-key-optimization.md`) lives in `accum.intern`, so the
result state must be threaded onward. Dropping it is silently sound and silently
slower — it only loses sharing — so every call site below binds the new state.

-}
applySubstFV : MonoState -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MonoState )
applySubstFV state subst canType =
    applySubstFVWithEnv state.ctx.mvarEnv state subst canType


{-| `applySubstFV` reading an EXPLICIT `MVarEnv` rather than the threaded state's.

A handful of sites deliberately substitute under an env captured earlier (e.g. a
fold that resolves every instance against `stateAfterBody`'s env while threading
its accumulator forward). Those sites still want their `Intern` table threaded,
so they name the two independently here. Everywhere else, `applySubstFV` takes
both from the same state.

-}
applySubstFVWithEnv : MVarEnv -> MonoState -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MonoState )
applySubstFVWithEnv mvarEnv state subst canType =
    let
        accum =
            state.accum

        ( monoType, intern1 ) =
            TypeSubst.applySubstFiltered mvarEnv subst canType accum.intern
    in
    ( monoType, { state | accum = { accum | intern = intern1 } } )


{-| Returns `True` if `to` is strictly more concrete than `from`.

Mirrors the row-polymorphic narrowing scenarios that can arise from
`applySubst` dropping unresolved row-extension MVars:

  - `from = MVar _`, `to` = anything non-MVar → True
  - `from = Mono.mRecord narrow`, `to = Mono.mRecord wider` (strict superset) → True
  - Function/tuple shapes propagate componentwise.

Used both at the let-binding (compare `defMonoType0` vs rhs's expr type)
and at `MonoRecordAccess` (compare canonical access type vs the field
type from the record's mono shape).

-}
isMoreConcrete : Mono.MonoType -> Mono.MonoType -> Bool
isMoreConcrete from to =
    case ( from, to ) of
        ( Mono.MVar _ _, Mono.MVar _ _ ) ->
            False

        ( Mono.MVar _ _, _ ) ->
            True

        _ ->
            recordWidened from to


recordWidened : Mono.MonoType -> Mono.MonoType -> Bool
recordWidened from to =
    case ( from, to ) of
        ( Mono.MRecord _ fromFields, Mono.MRecord _ toFields ) ->
            let
                fromKeys =
                    Dict.keys fromFields

                toKeys =
                    Dict.keys toFields
            in
            List.length toKeys
                > List.length fromKeys
                && List.all (\k -> Dict.member k toFields) fromKeys

        ( Mono.MFunction _ _ fromArgs fromRet, Mono.MFunction _ _ toArgs toRet ) ->
            (List.length fromArgs == List.length toArgs)
                && (List.any identity (List.map2 recordWidened fromArgs toArgs)
                        || recordWidened fromRet toRet
                   )

        ( Mono.MTuple _ fromElems, Mono.MTuple _ toElems ) ->
            List.length fromElems
                == List.length toElems
                && List.any identity (List.map2 recordWidened fromElems toElems)

        _ ->
            False


{-| Enqueue a specialization onto the worklist, deduplicating via the scheduled BitSet.
-}
enqueueSpec :
    Mono.Global
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.SpecId, MonoState )
enqueueSpec global rawMonoType state =
    let
        monoType =
            -- Refresh embedded constraints from the shared side table before keying
            -- (J3): a boxed var that Join-R tainted Number is re-stamped CNumber, so
            -- toComparableMonoType (D4) keys it as Int — the same specialization as an
            -- explicit-Int instantiation — rather than the boxed-erased sentinel.
            TypeSubst.refreshConstraints state.ctx.mvarEnv rawMonoType

        accum =
            state.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType accum.registry
    in
    if BitSet.member specId accum.scheduled then
        ( specId, { state | accum = { accum | registry = newRegistry } } )

    else
        ( specId
        , { state
            | accum =
                { accum
                    | registry = newRegistry
                    , scheduled = BitSet.insertGrowing specId accum.scheduled
                    , worklist = SpecializeGlobal specId :: accum.worklist
                }
          }
        )


{-| Check if the given name matches any active localMulti context in the stack.
-}
isLocalMultiTarget : Name -> MonoState -> Bool
isLocalMultiTarget name state =
    List.any (\ls -> ls.defName == name) state.ctx.localMulti


{-| Allocate or reuse a local function instance for a let-bound function.

    Searches the localMulti stack for the entry matching `defName`, and
    either returns an existing instance or creates a new one.

-}
getOrCreateLocalInstance :
    Name
    -> Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateLocalInstance defName funcMonoType0 callSubst state =
    let
        funcMonoType =
            -- Refresh constraints from the side table before keying (J3), so a
            -- Join-R-tainted number var keys and re-specializes as Int.
            TypeSubst.refreshConstraints state.ctx.mvarEnv funcMonoType0

        ( updatedStack, freshName ) =
            updateLocalMultiStack defName funcMonoType callSubst state.ctx.localMulti
    in
    ( freshName
    , { state
        | ctx =
            let
                ctx =
                    state.ctx
            in
            { ctx | localMulti = updatedStack }
      }
    )


{-| Walk the localMulti stack, find the entry for defName, and update it.
-}
updateLocalMultiStack :
    Name
    -> Mono.MonoType
    -> Substitution
    -> List LocalMultiState
    -> ( List LocalMultiState, Name )
updateLocalMultiStack defName funcMonoType callSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateLocalMultiStack: defName not found in stack: " ++ defName)

        localState :: rest ->
            if localState.defName == defName then
                case Mono.specMapGet funcMonoType localState.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Mono.specMapSize localState.instances

                            freshName =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName
                                , monoType = funcMonoType
                                , subst = callSubst
                                }

                            newInstances =
                                Mono.specMapInsert funcMonoType newInfo localState.instances

                            newLocalState =
                                { localState | instances = newInstances }
                        in
                        ( newLocalState :: rest, freshName )

            else
                let
                    ( updatedRest, freshName ) =
                        updateLocalMultiStack defName funcMonoType callSubst rest
                in
                ( localState :: updatedRest, freshName )



-- ========== VALUE-MULTI SPECIALIZATION ==========


{-| Check if a Can.Type MVarId contains any TLambda anywhere in its structure.
-}
typeContainsLambda : Can.Type MVarId -> Bool
typeContainsLambda canType =
    case canType of
        Can.TLambda _ _ ->
            True

        Can.TType _ _ args ->
            List.any typeContainsLambda args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ t) acc -> acc || typeContainsLambda t) False fields

        Can.TTuple a b rest ->
            typeContainsLambda a || typeContainsLambda b || List.any typeContainsLambda rest

        Can.TAlias _ _ _ (Can.Filled inner) ->
            typeContainsLambda inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            typeContainsLambda inner

        Can.TVar _ ->
            False

        Can.TUnit ->
            False


{-| Does the type contain any free type variable that is NOT number-classed —
i.e. a boxed/CEcoValue-class var? (The old name `hasCEcoTVar` read as "has a
CEcoValue-stamped var"; it actually tests `not isNumberVar` per free var.)
-}
hasNonNumberVar : MVarEnv -> Can.Type MVarId -> Bool
hasNonNumberVar mvarEnv canType =
    let
        varIds =
            KernelAbi.freeVarIds canType []
    in
    List.any
        (\mvarId ->
            not (State.isNumberVar mvarId mvarEnv)
        )
        varIds


{-| Should this non-function let binding use value-multi specialization?
True when the type contains lambdas AND unconstrained CEco type variables.
-}
shouldUseValueMulti : MVarEnv -> Can.Type MVarId -> Bool
shouldUseValueMulti mvarEnv defCanType =
    typeContainsLambda defCanType
        && (hasNonNumberVar mvarEnv defCanType || hasUnresolvedNumberVar mvarEnv defCanType)


{-| Does this type contain an unresolved CNumber type variable (a bare `number`
or a `number` nested in a container/record/tuple)? Such non-function `let`
bindings are eagerly defaulted to `Int` by the standard path, which mis-types
them when a use site demands `Float`. Routing them through the demand-driven
value-multi machinery lets the consumer's resolved numeric type (carried in the
call-site `paramType`) flow back onto the binding before it is emitted.
-}
hasUnresolvedNumberVar : MVarEnv -> Can.Type MVarId -> Bool
hasUnresolvedNumberVar mvarEnv defCanType =
    List.any
        (\mvarId -> State.isNumberVar mvarId mvarEnv)
        (KernelAbi.freeVarIds defCanType [])


{-| Conservative gate on the eager MonoType of a number-carrying let: fire the
number specialization only for shapes where an unboxed Int-vs-Float slot is
actually at stake and the recording machinery handles it — a scalar number, or a
SHALLOW tuple/record/list/`Maybe`/`Result`/`Array` of numbers. Boxed user custom
types (`Box (Maybe number)`), deeply nested lists (`List (List …)`), and
aggregates carrying non-numeric components (`{ x : number, y : String }`) are
left on the eager path, where they were already correct — seeding the value-multi
machinery over them corrupts their boxed representation.
-}
isNumericFixableShape : Mono.MonoType -> Bool
isNumericFixableShape mt =
    case mt of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MTuple _ ts ->
            List.all isNumericFixableShape ts

        Mono.MRecord _ fields ->
            not (Dict.isEmpty fields) && List.all isNumericFixableShape (Dict.values fields)

        Mono.MList _ t ->
            isNumericFixableShape t

        Mono.MCustom _ _ _ args ->
            -- Any custom type (incl. user types like `NumBox number`, and partially-
            -- numeric ones like `Result e Int` where the error arg is a phantom
            -- non-numeric) with at least one numeric-fixable arg and no arg that is
            -- itself a non-numeric *aggregate the recording would have to re-type*
            -- (a function, or a number-bearing shape we can't fix). Under quiescence-
            -- before-defaulting (MONO_028) a boxed/phantom custom that flows here stays
            -- an OPEN number and closes to Int correctly, so admitting it is safe — the
            -- former `isNumericDataRhs` provenance gate that excluded case/poly-call RHS
            -- was a prediction the eager-Int-commit made necessary and is now removed.
            List.any isNumericFixableShape args
                && List.all (\a -> isNumericFixableShape a || not (monoTypeMentionsNumeric a)) args

        Mono.MVar _ Mono.CNumber ->
            -- Quiescence-before-defaulting: an open number var is a residual that
            -- closes to Int, so it is a numeric-fixable scalar here (it used to
            -- arrive already defaulted to MInt before applySubst stopped defaulting).
            True

        _ ->
            False


{-| Is `name` a deferred number-carrying value-multi target on the stack? Used
at call-argument and record-access sites to decide whether to record a numeric
use-site instance for the binding rather than resolving the reference eagerly.
-}
isNumberMultiTarget : Name -> MonoState -> Bool
isNumberMultiTarget name state =
    case findValueMultiEntry name state.ctx.valueMulti of
        Just ( _, defCanType ) ->
            hasUnresolvedNumberVar state.ctx.mvarEnv defCanType

        Nothing ->
            False


{-| Does this MonoType mention any numeric content (a concrete `Int`/`Float` or an
unresolved `CNumber` var) anywhere? Used by the shape gate to admit partially-
numeric customs (`Result e Int`) only when the non-numeric args are inert — i.e.
contain no numeric content the recording would have to re-type.
-}
monoTypeMentionsNumeric : Mono.MonoType -> Bool
monoTypeMentionsNumeric mt =
    case mt of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ t ->
            monoTypeMentionsNumeric t

        Mono.MTuple _ ts ->
            List.any monoTypeMentionsNumeric ts

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsNumeric t) False fields

        Mono.MCustom _ _ _ args ->
            List.any monoTypeMentionsNumeric args

        Mono.MFunction _ _ args r ->
            List.any monoTypeMentionsNumeric args || monoTypeMentionsNumeric r

        _ ->
            False


{-| Record a numeric use-site instance for the deferred binding `name`, given the
`resolvedShape` MonoType demanded by a consumer (a scalar `MFloat`/`MInt`, or a
container like `Mono.mTuple [MFloat, MInt]` / `Mono.mList MFloat`).

The shape is unified against the binding's own `defCanType` (looked up on the
value-multi stack), so the resulting `enrichedSubst` binds the binding's number
vars directly. Emission (`applySubstFV info.subst defCanType`) then yields the
concrete numeric type without depending on use-site/binding MVarId sharing.

Returns the instance's fresh name, its concrete MonoType, and the updated state;
`Nothing` if `name` is not a value-multi target (defensive — callers gate on
`isNumberMultiTarget`).

-}
recordNumberInstanceAgainstShape : Name -> Mono.MonoType -> Substitution -> MonoState -> Maybe ( Name, Mono.MonoType, MonoState )
recordNumberInstanceAgainstShape name resolvedShape subst state =
    case findValueMultiEntry name state.ctx.valueMulti of
        Just ( _, defCanType ) ->
            let
                ( enrichedSubst, mvarEnv1 ) =
                    TypeSubst.unifyExtend state.ctx.mvarEnv defCanType resolvedShape subst

                stateE0 =
                    setMVarEnv mvarEnv1 state

                ( instMonoType, stateE ) =
                    applySubstFV stateE0 enrichedSubst defCanType

                ( freshName, state1 ) =
                    getOrCreateValueInstance name instMonoType enrichedSubst stateE
            in
            Just ( freshName, instMonoType, state1 )

        Nothing ->
            Nothing


{-| Resolve a reference to a number-multi binding that appears in a non-call-arg,
non-projection position (an `if`/`case` branch result, a record-construction
field, a `let m = n` alias, …). The reference's own resolved `meta.tipe` is the
consumer's demand at this site (e.g. `Float` for the `then`-branch of an
`if … * 1.5`). Record an instance for that shape and point the reference at it.
Falls back to the prelim `varEnv` type if the binding is not (or no longer) on
the stack.
-}
resolveNumberMultiVarRef : Name -> Can.Type MVarId -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
resolveNumberMultiVarRef name canType subst state =
    let
        ( resolvedShape, stateI ) =
            applySubstFV state subst canType

        -- Record a fresh instance for every reference. (The earlier Float-only
        -- guard — record only when `monoTypeContainsFloat resolvedShape` — was
        -- retired: the J5 deletion loop proved recording Int-typed uses too is
        -- inert, since they dedup to the eager instance.)
        recorded =
            recordNumberInstanceAgainstShape name resolvedShape subst stateI
    in
    case recorded of
        Just ( freshName, instMonoType, state1 ) ->
            ( Mono.MonoVarLocal freshName instMonoType, state1 )

        Nothing ->
            case State.lookupVar name stateI.ctx.varEnv of
                Just envType ->
                    ( Mono.MonoVarLocal name envType, stateI )

                Nothing ->
                    ( Mono.MonoVarLocal name resolvedShape, stateI )


{-| Check if the given name matches any active valueMulti context in the stack.
-}
isValueMultiTarget : Name -> MonoState -> Bool
isValueMultiTarget name state =
    List.any (\entry -> entry.defName == name) state.ctx.valueMulti


{-| Check if an expression is a VarLocal/TrackedVarLocal that is a value-multi target.
Returns the variable name and its canonical type if so.
-}
getValueMultiVar : TOpt.Expr MVarId -> MonoState -> Maybe ( Name, Can.Type MVarId )
getValueMultiVar expr state =
    case expr of
        TOpt.VarLocal name meta ->
            if isValueMultiTarget name state then
                Just ( name, meta.tipe )

            else
                Nothing

        TOpt.TrackedVarLocal _ name meta ->
            if isValueMultiTarget name state then
                Just ( name, meta.tipe )

            else
                Nothing

        _ ->
            Nothing


{-| Walk a TOpt.Path to its Root, then check whether the Root name is a valueMulti
target. Returns the root name and its canonical type (as recorded on the
valueMulti stack) when it is; otherwise Nothing.
-}
getValueMultiRootFromPath : TOpt.Path -> MonoState -> Maybe ( Name, Can.Type MVarId )
getValueMultiRootFromPath path state =
    case path of
        TOpt.Root name ->
            findValueMultiEntry name state.ctx.valueMulti

        TOpt.Index _ _ subPath ->
            getValueMultiRootFromPath subPath state

        TOpt.ArrayIndex _ subPath ->
            getValueMultiRootFromPath subPath state

        TOpt.Field _ subPath ->
            getValueMultiRootFromPath subPath state

        TOpt.Unbox subPath ->
            getValueMultiRootFromPath subPath state


findValueMultiEntry : Name -> List ValueMultiState -> Maybe ( Name, Can.Type MVarId )
findValueMultiEntry name stack =
    case stack of
        [] ->
            Nothing

        entry :: rest ->
            if entry.defName == name then
                Just ( entry.defName, entry.defCanType )

            else
                findValueMultiEntry name rest


{-| Rewrite the Root name inside a TOpt.Path, preserving the surrounding
Index/ArrayIndex/Field/Unbox chain. Used when a destructor is re-targeted at a
fresh value-multi instance.
-}
rewriteRootInPath : Name -> Name -> TOpt.Path -> TOpt.Path
rewriteRootInPath oldName newName path =
    case path of
        TOpt.Root name ->
            if name == oldName then
                TOpt.Root newName

            else
                path

        TOpt.Index idx hint subPath ->
            TOpt.Index idx hint (rewriteRootInPath oldName newName subPath)

        TOpt.ArrayIndex idx subPath ->
            TOpt.ArrayIndex idx (rewriteRootInPath oldName newName subPath)

        TOpt.Field fieldName subPath ->
            TOpt.Field fieldName (rewriteRootInPath oldName newName subPath)

        TOpt.Unbox subPath ->
            TOpt.Unbox (rewriteRootInPath oldName newName subPath)


{-| For a custom-type field destructure (`Index idx (HintCustom ctorName)`),
synthesize the partial custom container `MCustom home name args` with the field's
type-arg set to `leafMono` and the rest fresh, by unifying the constructor
scheme's field arg with `leafMono` and reading off the (freshened) result type.
The scheme maps the field index to its type-arg position, so e.g. both fields of
`Pair number number` pin the single shared param. `rootCanType` supplies the
type's home; returns `Nothing` for non-`TType` roots (nested customs) or an
unknown ctor, and the caller falls back to the eager path.
-}
customContainerForField : Can.Type MVarId -> Name -> Int -> Mono.MonoType -> MonoState -> Maybe ( Mono.MonoType, MonoState )
customContainerForField rootCanType ctorName fieldIdx leafMono state =
    case rootCanType of
        Can.TType home _ _ ->
            let
                ctorGlobal =
                    TOpt.Global home ctorName

                -- @unbox single-field types are `TOpt.Box`; multi-field/multi-ctor
                -- are `TOpt.Ctor`. Both carry the constructor's canonical type.
                maybeCtorCanType =
                    case Data.Map.get TOpt.toComparableGlobal ctorGlobal state.ctx.toptNodes of
                        Just (TOpt.Ctor _ _ ct) ->
                            Just ct

                        Just (TOpt.Box ct) ->
                            Just ct

                        _ ->
                            Nothing
            in
            case maybeCtorCanType of
                Just ctorCanType ->
                    let
                        ( schemeInfo, state1 ) =
                            getOrBuildSchemeInfo ctorCanType (Just ctorGlobal) state
                    in
                    case List.drop fieldIdx schemeInfo.argTypes of
                        fieldCanType :: _ ->
                            let
                                ( subst1, mvarEnv1 ) =
                                    TypeSubst.unifyExtend state1.ctx.mvarEnv fieldCanType leafMono Dict.empty

                                state2a =
                                    setMVarEnv mvarEnv1 state1

                                ( customMono, state2 ) =
                                    applySubstFV state2a subst1 schemeInfo.resultType
                            in
                            Just ( customMono, state2 )

                        [] ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Build a partial MonoType container by walking a TOpt.Path outward from the
Root, placing `leafMonoType` at the Root position and fresh MVars for sibling
positions. Returns Nothing for shapes we don't yet know how to synthesize
(Index + HintList, ArrayIndex); callers should fall back
to the non-valueMulti code path.

Examples:
Index 0 HintTuple2 (Root n) -> Mono.mTuple [leaf, MVar fresh]
Index 1 HintTuple3 (Root n) -> Mono.mTuple [MVar, leaf, MVar]
Field "a" (Root n) -> Mono.mRecord (Dict.singleton "a" leaf)
Unbox (Root n) -> leaf (wrapper's payload is the leaf)

-}
buildPartialContainer : Can.Type MVarId -> TOpt.Path -> Mono.MonoType -> MonoState -> Maybe ( Mono.MonoType, MonoState )
buildPartialContainer rootCanType path leafMonoType state =
    case path of
        TOpt.Root _ ->
            Just ( leafMonoType, state )

        TOpt.Index idx hint subPath ->
            case hint of
                TOpt.HintTuple2 ->
                    let
                        ( fillerId, env1 ) =
                            State.freshMVar Mono.CEcoValue state.ctx.mvarEnv

                        state1 =
                            setMVarEnv env1 state

                        filler =
                            Mono.MVar fillerId Mono.CEcoValue

                        elems =
                            case Index.toMachine idx of
                                0 ->
                                    [ leafMonoType, filler ]

                                _ ->
                                    [ filler, leafMonoType ]
                    in
                    buildPartialContainer rootCanType subPath (Mono.mTuple elems) state1

                TOpt.HintTuple3 ->
                    let
                        ( fillerA, envA ) =
                            State.freshMVar Mono.CEcoValue state.ctx.mvarEnv

                        ( fillerB, envB ) =
                            State.freshMVar Mono.CEcoValue envA

                        state1 =
                            setMVarEnv envB state

                        mvA =
                            Mono.MVar fillerA Mono.CEcoValue

                        mvB =
                            Mono.MVar fillerB Mono.CEcoValue

                        elems =
                            case Index.toMachine idx of
                                0 ->
                                    [ leafMonoType, mvA, mvB ]

                                1 ->
                                    [ mvA, leafMonoType, mvB ]

                                _ ->
                                    [ mvA, mvB, leafMonoType ]
                    in
                    buildPartialContainer rootCanType subPath (Mono.mTuple elems) state1

                TOpt.HintCustom ctorName ->
                    -- Custom-type field (e.g. `case v of NumBox k -> k`). Synthesize
                    -- the custom container `MCustom home name [.. leaf ..]` by setting
                    -- the field's type-arg via the constructor scheme, then recurse.
                    case customContainerForField rootCanType ctorName (Index.toMachine idx) leafMonoType state of
                        Just ( customMono, stateC ) ->
                            buildPartialContainer rootCanType subPath customMono stateC

                        Nothing ->
                            Nothing

                TOpt.HintList ->
                    Nothing

        TOpt.Field fieldName subPath ->
            buildPartialContainer rootCanType
                subPath
                (Mono.mRecord (Dict.singleton fieldName leafMonoType))
                state

        TOpt.Unbox subPath ->
            -- A single-field `@unbox` wrapper. Look up the type's *actual* single
            -- constructor in the type environment (no assumption that the ctor is
            -- named like the type), then synthesize `MCustom home name [.. leaf ..]`
            -- via its scheme; the field is index 0. Otherwise pass the leaf through.
            let
                customAttempt =
                    case rootCanType of
                        Can.TType home typeName _ ->
                            case Analysis.lookupUnion state.ctx.globalTypeEnv home typeName of
                                Just (Can.Union unionData) ->
                                    case unionData.alts of
                                        [ Can.Ctor ctorData ] ->
                                            customContainerForField rootCanType ctorData.name 0 leafMonoType state

                                        _ ->
                                            Nothing

                                Nothing ->
                                    Nothing

                        _ ->
                            Nothing
            in
            case customAttempt of
                Just ( customMono, stateC ) ->
                    buildPartialContainer rootCanType subPath customMono stateC

                Nothing ->
                    buildPartialContainer rootCanType subPath leafMonoType state

        TOpt.ArrayIndex _ _ ->
            Nothing


{-| Body-first specialization of a `Destruct` whose root is a number-multi target
(quiescence-before-defaulting, MONO\_028). REPLACES the eager
`demandedNumericUseType` look-ahead (demand replay): instead of PREDICTING which
uses of the destructor-bound variable demand `Float`, seed `dname` as a
number-multi target and specialize the body FIRST, so its uses record one instance
per demanded numeric shape via `resolveNumberMultiVarRef` (the state-threaded
valueMulti channel). Then emit one `MonoDestruct` per recorded instance, each
projecting its slot from a root instance materialised (via
`buildPartialContainer`/`getOrCreateValueInstance`) at the demanded Int/Float type.
The eager Int instance's destructor is emitted only if `dname` is actually
referenced by a non-Float use (otherwise it would create a spurious dead root
instance). This inverts the historical "specialize destructor, then body" order.
-}
specializeNumberDestruct :
    Name
    -> TOpt.Path
    -> TOpt.Meta MVarId
    -> Name
    -> Can.Type MVarId
    -> TOpt.Expr MVarId
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeNumberDestruct dname destructorPath destructorMeta rootName rootCanType body subst state =
    let
        fieldCanType =
            destructorMeta.tipe

        ( eagerLeaf, stateI0 ) =
            applySubstFV state subst fieldCanType

        intKey =
            TypeSubst.refreshConstraints state.ctx.mvarEnv eagerLeaf

        -- The `dname` valueMulti entry only needs defName/defCanType/instances for
        -- use-site recording; its `def` is never specialized (this handler owns the
        -- pop and emits MonoDestructs, not MonoLets), so a self-referential stub def
        -- suffices as a placeholder.
        placeholderDef =
            TOpt.Def A.zero dname (TOpt.VarLocal dname destructorMeta) fieldCanType

        seededEntry =
            { defName = dname
            , defCanType = fieldCanType
            , def = placeholderDef
            , instances =
                Mono.specMapSingleton intKey
                    { freshName = dname
                    , monoType = eagerLeaf
                    , subst = subst
                    , derivedDestructorNames = Set.empty
                    }
            }

        stateForBody =
            { stateI0
                | ctx =
                    let
                        c =
                            stateI0.ctx
                    in
                    { c
                        | valueMulti = seededEntry :: c.valueMulti
                        , varEnv = State.insertVar dname eagerLeaf c.varEnv
                    }
            }

        ( monoBody, stateAfterBody ) =
            specializeExpr body subst stateForBody

        ( dnameEntry, restStack ) =
            case stateAfterBody.ctx.valueMulti of
                top :: rest ->
                    ( top, rest )

                [] ->
                    Utils.Crash.crash "Specialize.specializeNumberDestruct: valueMulti underflow"

        statePopped =
            { stateAfterBody
                | ctx =
                    let
                        c =
                            stateAfterBody.ctx
                    in
                    { c | valueMulti = restStack }
            }

        dnameUsed =
            exprReferencesLocal dname monoBody

        -- Drain the eager Int instance (freshName == dname) only if a non-Float use
        -- of `dname` actually referenced it in the body; drain all Float instances.
        instancesToEmit =
            Mono.specMapValues dnameEntry.instances
                |> List.filter (\info -> info.freshName /= dname || dnameUsed)

        ( destructorsRev, stateFinal ) =
            List.foldl
                (\info ( acc, st ) ->
                    case buildPartialContainer rootCanType destructorPath info.monoType st of
                        Just ( partialContainerMono, stateP ) ->
                            let
                                ( refinedSubst, mvarEnv1 ) =
                                    TypeSubst.unifyExtend stateP.ctx.mvarEnv rootCanType partialContainerMono info.subst

                                stateR0 =
                                    setMVarEnv mvarEnv1 stateP

                                ( rootInstanceMonoType, stateR ) =
                                    applySubstFV stateR0 refinedSubst rootCanType

                                ( freshRootName, stateI ) =
                                    getOrCreateValueInstance rootName rootInstanceMonoType refinedSubst stateR

                                -- Must match getOrCreateValueInstance's internal key
                                -- EXACTLY: it applies refreshConstraints before keying
                                -- (J3), so the tag lookup must too, or it misses the
                                -- instance and crashes.
                                instanceKey =
                                    TypeSubst.refreshConstraints stateR.ctx.mvarEnv rootInstanceMonoType

                                taggedStack =
                                    tagValueInstanceWithDestructor rootName instanceKey info.freshName stateI.ctx.valueMulti

                                stateT =
                                    { stateI
                                        | ctx =
                                            let
                                                c =
                                                    stateI.ctx
                                            in
                                            { c
                                                | valueMulti = taggedStack
                                                , varEnv = State.insertVar freshRootName rootInstanceMonoType c.varEnv
                                            }
                                    }

                                rewrittenDestructor =
                                    TOpt.Destructor info.freshName
                                        (rewriteRootInPath rootName freshRootName destructorPath)
                                        destructorMeta

                                monoDestructor =
                                    specializeDestructor rewrittenDestructor
                                        refinedSubst
                                        stateT.ctx.mvarEnv
                                        stateT.ctx.varEnv
                                        stateT.ctx.globalTypeEnv
                                        stateT.ctx.currentGlobal

                                (Mono.MonoDestructor destructorName _ destructorType) =
                                    monoDestructor

                                stateV =
                                    { stateT
                                        | ctx =
                                            let
                                                c =
                                                    stateT.ctx
                                            in
                                            { c | varEnv = State.insertVar destructorName destructorType c.varEnv }
                                    }
                            in
                            ( monoDestructor :: acc, stateV )

                        Nothing ->
                            ( acc, st )
                )
                ( [], statePopped )
                instancesToEmit

        finalExpr =
            List.foldl
                (\md accExpr -> Mono.MonoDestruct md accExpr (Mono.typeOf accExpr))
                monoBody
                destructorsRev
    in
    ( finalExpr, stateFinal )


{-| Does `expr` contain a `MonoVarLocal name` reference anywhere?
-}
exprReferencesLocal : Name -> Mono.MonoExpr -> Bool
exprReferencesLocal name expr =
    Traverse.foldExpr
        (\e acc ->
            acc
                || (case e of
                        Mono.MonoVarLocal n _ ->
                            n == name

                        _ ->
                            False
                   )
        )
        False
        expr


setMVarEnv : MVarEnv -> MonoState -> MonoState
setMVarEnv env state =
    { state
        | ctx =
            let
                c =
                    state.ctx
            in
            { c | mvarEnv = env }
    }


{-| Strip exactly `numArgs` parameter layers from a curried `MonoType`. Used at
kernel call sites to compute the call's result type from the kernel's ABI
function type (which, after `applySubstLambdaChain`, is a chain of single-param
`Mono.mFunction`s). `Mono.resultTypeOf` is unsafe here because it drills through all
layers, giving the wrong type for partial applications.
-}
peelCallResult : Int -> Mono.MonoType -> Mono.MonoType
peelCallResult numArgs monoType =
    if numArgs <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ anno params result ->
                let
                    pcount =
                        List.length params
                in
                if pcount > numArgs then
                    Mono.mFunction anno (List.drop numArgs params) result

                else if pcount == numArgs then
                    result

                else
                    peelCallResult (numArgs - pcount) result

            _ ->
                monoType


{-| Allocate or reuse a value instance for a let-bound value with lambdas.
-}
getOrCreateValueInstance :
    Name
    -> Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateValueInstance defName monoType0 currentSubst state =
    let
        monoType =
            -- Refresh constraints from the side table before keying (J3).
            TypeSubst.refreshConstraints state.ctx.mvarEnv monoType0

        ( updatedStack, freshName_ ) =
            updateValueMultiStack defName monoType currentSubst state.ctx.valueMulti
    in
    ( freshName_
    , { state
        | ctx =
            let
                ctx =
                    state.ctx
            in
            { ctx | valueMulti = updatedStack }
      }
    )


{-| Walk the valueMulti stack, find the entry for defName, and update it.
-}
updateValueMultiStack :
    Name
    -> Mono.MonoType
    -> Substitution
    -> List ValueMultiState
    -> ( List ValueMultiState, Name )
updateValueMultiStack defName monoType currentSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateValueMultiStack: defName not found in stack: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Mono.specMapGet monoType entry.instances of
                    Just info ->
                        -- Instance exists but this call supplies a new
                        -- `currentSubst` derived from a different destructor
                        -- path on the same root. That path may expose type
                        -- vars for slots the earlier destructor never touched
                        -- (e.g. the second destructor in `( getter, setter )`
                        -- binds the setter's own MVarIds which the getter's
                        -- partial container never mentioned).
                        --
                        -- Merge new-only bindings from `currentSubst` into
                        -- `info.subst` via Dict.union (left-biased): existing
                        -- entries — potentially strengthened by later call-
                        -- site refinement — are preserved, while fresh
                        -- destructor-path bindings get picked up. Both sides
                        -- derive from the same outer `subst`, so any key
                        -- common to both already agrees.
                        let
                            newInfo =
                                { info | subst = Dict.union info.subst currentSubst }

                            newInstances =
                                Mono.specMapInsert monoType newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Mono.specMapSize entry.instances

                            freshName_ =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$v" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName_
                                , monoType = monoType
                                , subst = currentSubst
                                , derivedDestructorNames = Set.empty
                                }

                            newInstances =
                                Mono.specMapInsert monoType newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, freshName_ )

            else
                let
                    ( updatedRest, freshName_ ) =
                        updateValueMultiStack defName monoType currentSubst rest
                in
                ( entry :: updatedRest, freshName_ )


{-| Record that a destructor-introduced local `destructorName` belongs to the
instance keyed by `instanceKey` on the `valueMulti` entry for `defName`.

Used at `TOpt.Destruct` creation time so later call sites of the destructor can
find which value-multi instance to refine. Crashes on missing keys per design
decision D7: silently skipping would reintroduce exactly the class of bugs this
tagging fixes.

-}
tagValueInstanceWithDestructor :
    Name
    -> Mono.MonoType
    -> Name
    -> List ValueMultiState
    -> List ValueMultiState
tagValueInstanceWithDestructor defName instanceKey destructorName stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.tagValueInstanceWithDestructor: defName not found: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Mono.specMapGet instanceKey entry.instances of
                    Just info ->
                        let
                            newInfo =
                                { info
                                    | derivedDestructorNames =
                                        Set.insert destructorName info.derivedDestructorNames
                                }

                            newInstances =
                                Mono.specMapInsert instanceKey newInfo entry.instances
                        in
                        { entry | instances = newInstances } :: rest

                    Nothing ->
                        Utils.Crash.crash
                            ("Specialize.tagValueInstanceWithDestructor: instance key not found for "
                                ++ defName
                                ++ " / "
                                ++ Mono.monoTypeToDebugString instanceKey
                            )

            else
                entry :: tagValueInstanceWithDestructor defName instanceKey destructorName rest


{-| If `funcName` is a destructor registered on some value-multi instance,
refine that instance's `subst` using `unifyArgsOnly` against the destructor's
canonical function type and the call-site argument MonoTypes, then return the
refined substitution, updated `MVarEnv`, and stack with the instance updated.

Walks the stack head-to-tail (innermost-first) and stops at the first match
(D3). Returns `Nothing` if no stack entry has an instance claiming `funcName`.

`unifyArgsOnly` is monotone: bindings only become more concrete, so repeatedly
extending `info.subst` this way cannot regress a `MInt` back into an alias.

-}
refineValueMultiForDestructorCall :
    Name
    -> Can.Type MVarId
    -> List Mono.MonoType
    -> MVarEnv
    -> List ValueMultiState
    -> Maybe ( Substitution, MVarEnv, List ValueMultiState )
refineValueMultiForDestructorCall funcName funcCanType argTypes mvarEnv stack =
    case stack of
        [] ->
            Nothing

        entry :: rest ->
            case findInstanceByDestructor funcName (Mono.specMapToList entry.instances) of
                Just ( instanceKey, info ) ->
                    let
                        ( newSubst, newEnv ) =
                            TypeSubst.unifyArgsOnly mvarEnv funcCanType argTypes info.subst

                        newInfo =
                            { info | subst = newSubst }

                        newInstances =
                            Mono.specMapInsert instanceKey newInfo entry.instances

                        newEntry =
                            { entry | instances = newInstances }
                    in
                    Just ( newSubst, newEnv, newEntry :: rest )

                Nothing ->
                    case refineValueMultiForDestructorCall funcName funcCanType argTypes mvarEnv rest of
                        Just ( newSubst, newEnv, newRest ) ->
                            Just ( newSubst, newEnv, entry :: newRest )

                        Nothing ->
                            Nothing


{-| Linear scan of a single valueMulti entry's instances for one whose
`derivedDestructorNames` contains `funcName`. Returns the (key, info) on the
first match; only one match can exist because a destructor local belongs to
exactly one instance.
-}
findInstanceByDestructor :
    Name
    -> List ( Mono.MonoType, State.ValueInstanceInfo )
    -> Maybe ( Mono.MonoType, State.ValueInstanceInfo )
findInstanceByDestructor funcName pairs =
    case pairs of
        [] ->
            Nothing

        ( key, info ) :: rest ->
            if Set.member funcName info.derivedDestructorNames then
                Just ( key, info )

            else
                findInstanceByDestructor funcName rest


{-| Specialize a lambda expression (Function or TrackedFunction).

This is a staging-agnostic specialization that:

1.  Specializes exactly one lambda node at a time (no peelFunctionChain)
2.  Preserves the syntactic structure: `\x y -> body` vs `\x -> \y -> body`
3.  Does NOT enforce staging invariants (that's GlobalOpt's job as GOPT\_016)

After this pass:

  - `\x y -> body` (one TOpt.Function [x,y] body) → one MonoClosure with 2 params
  - `\x -> \y -> body` (nested TOpt.Function) → outer closure with 1 param,
    body contains inner closure

IMPORTANT: The closure may have more params than the type's stage arity.
This is INTENTIONAL. Example:

    \x y -> body
    produces: params=[(x,Int),(y,Int)], type=Mono.mFunction [Int] (Mono.mFunction [Int] Int)

The flat param list comes from TOpt.Function syntax.
The curried type comes from TypeSubst.applySubst preserving TLambda structure.

GlobalOpt (GOPT\_016) will canonicalize by flattening the type:
Mono.mFunction [Int] (Mono.mFunction [Int] Int) → Mono.mFunction [Int, Int] Int

Invariant relied upon: TOPT\_005 - the Can.Type MVarId on the TOpt node is the
authoritative TLambda encoding of this function's params and result.

-}
specializeLambda :
    TOpt.Expr MVarId
    -> Can.Type MVarId
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        -- 1. Specialize the whole function type once (no flattening).
        -- Invariant: `canType` is the TLambda encoding of this function (TOPT_005).
        -- Monomorphize preserves the curried structure from TypeSubst.applySubst.
        -- The closure will have N params (from TOpt syntax) but type with stage arity < N.
        -- Example: \x y -> body has params=2, type=MFunction [a] (MFunction [b] c) (stage arity 1).
        -- GlobalOpt (GOPT_001) will flatten: MFunction [a, b] c.
        ( monoType0, stateI ) =
            applySubstFV state subst canType

        -- 1b. Feed the concrete function type back into the substitution.
        -- This propagates constraints from the enclosing specialization context
        -- (e.g. compose identity identity 1) into the lambda's internal type variables.
        -- unifyExtend only adds bindings already implied by monoType0, so this is safe.
        -- J5: keep the returned env (Join-R taints) and thread it via stateWithLambda.
        ( refinedSubst, refinedEnv ) =
            TypeSubst.unifyExtend state.ctx.mvarEnv canType monoType0 subst

        -- 2. Extract params and body directly (no peelFunctionChain).
        ( params, bodyExpr ) =
            case lambdaExpr of
                TOpt.Function _ ps body _ ->
                    ( ps, body )

                TOpt.TrackedFunction _ trackedPs body _ ->
                    ( List.map (\( locName, ty ) -> ( A.toValue locName, ty )) trackedPs, body )

                _ ->
                    Utils.Crash.crash
                        "specializeLambda: called with non-lambda expression"

        -- Guard: paramCount == 0 is a bug
        -- 3. Specialize each parameter's declared Can.Type MVarId under refinedSubst.
        -- Threaded fold rather than `List.map`: each application also grows the
        -- Intern table. Every `st` here has `state`'s `mvarEnv` (applySubstFV only
        -- touches `accum.intern`), so this reads the same env the map did.
        ( monoParams, stateP ) =
            List.foldr
                (\( name, paramCanType ) ( acc, st ) ->
                    let
                        ( paramMono, st1 ) =
                            applySubstFV st refinedSubst paramCanType
                    in
                    ( ( name, paramMono ) :: acc, st1 )
                )
                ( [], stateI )
                params

        ctx =
            stateP.ctx

        lambdaId =
            Mono.AnonymousLambda ctx.currentModule ctx.lambdaCounter

        newVarEnv =
            List.foldl
                (\( name, monoParamType ) ve ->
                    State.insertVar name monoParamType ve
                )
                (State.pushFrame ctx.varEnv)
                monoParams

        stateWithLambda =
            { stateP
                | ctx =
                    { ctx
                        | lambdaCounter = ctx.lambdaCounter + 1
                        , varEnv = newVarEnv
                        , mvarEnv = refinedEnv
                    }
            }

        -- 4. Specialize the body under refinedSubst.
        ( monoBody, stateAfter0 ) =
            specializeExpr bodyExpr refinedSubst stateWithLambda

        stateAfter =
            { stateAfter0
                | ctx =
                    let
                        ctx0 =
                            stateAfter0.ctx
                    in
                    { ctx0 | varEnv = State.popFrame ctx0.varEnv }
            }

        -- 5. Compute captures.
        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = captures
            , params = monoParams
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        -- 6. Use the monomorphic function type from TypeSubst.applySubst unchanged.
        -- Under staging-agnostic Monomorphize, we must NOT change the type's staging.
        -- GlobalOpt (GOPT_001) will canonicalize by flattening to match param count.
        monoTypeFixed : Mono.MonoType
        monoTypeFixed =
            monoType0
    in
    ( Mono.MonoClosure closureInfo monoBody monoTypeFixed, stateAfter )



-- ========== NODE SPECIALIZATION ==========


{-| Specialize a constructor via getOrBuildSchemeInfo so that MVarIds are freshened
per specialization, preventing stale bindings from leaking across call sites.
-}
specializeCtorViaScheme : Name.Name -> Int -> Int -> Can.Type MVarId -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeCtorViaScheme ctorName tag arity canType requestedMonoType state =
    let
        ctorGlobal =
            case state.ctx.currentGlobal of
                Just (Mono.Global canonical name) ->
                    TOpt.Global canonical name

                _ ->
                    Utils.Crash.crash "specializeCtorViaScheme: currentGlobal is not a Global — ctors must always have a currentGlobal"

        ( schemeInfo, state1 ) =
            getOrBuildSchemeInfo canType (Just ctorGlobal) state

        ( subst, mvarEnv1 ) =
            TypeSubst.unify state1.ctx.mvarEnv schemeInfo.schemeType requestedMonoType

        ctorMonoType =
            TypeSubst.applySubstPure mvarEnv1 subst schemeInfo.schemeType

        shape =
            buildCtorShapeFromArity ctorName tag arity ctorMonoType

        ctorResultType =
            extractCtorResultType arity requestedMonoType

        ctx2 =
            let
                ctx =
                    state1.ctx
            in
            { ctx | mvarEnv = mvarEnv1 }
    in
    ( Mono.MonoCtor shape ctorResultType, { state1 | ctx = ctx2 } )


{-| Specialize a typed optimized node to a monomorphized node at the requested concrete type.
The ctorName parameter is used to populate CtorLayout.name for constructor nodes.
-}
specializeNode : Name.Name -> TOpt.Node MVarId -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeNode ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ meta ->
            let
                canType =
                    meta.tipe

                ( subst0, env0 ) =
                    TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType

                -- Also unify the body expression's canonical type with requestedMonoType.
                -- The annotation canType may be fully resolved (no TVars) while internal
                -- expressions retain unresolved TVars. This enriches the substitution
                -- with bindings for those internal TVars.
                ( subst, env1 ) =
                    TypeSubst.unifyExtend env0 (TOpt.typeOf expr) requestedMonoType subst0

                -- J5: thread the (Join-R-tainted) env from both unifications into the
                -- state so `taintNumber` marks persist to the final superVars.
                ( monoExpr, state1 ) =
                    specializeExpr expr subst (setMVarEnv env1 state)

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TrackedDefine _ expr deps meta ->
            -- Tracking region is unused here; delegate to the untracked arm.
            specializeNode ctorName (TOpt.Define expr deps meta) requestedMonoType state

        TOpt.Ctor index arity canType ->
            let
                ctorHome =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global canonical _) ->
                            canonical

                        _ ->
                            Utils.Crash.crash "specializeNode TOpt.Ctor: currentGlobal must be a Global"
            in
            specializeCtorViaScheme ctorName (CtorTag.effective ctorHome ctorName index) arity canType requestedMonoType state

        TOpt.Enum tag canType ->
            let
                ( unifSubst, envU ) =
                    TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType

                monoType =
                    TypeSubst.applySubstPure envU unifSubst canType

                enumHome =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global canonical _) ->
                            canonical

                        _ ->
                            Utils.Crash.crash "specializeNode TOpt.Enum: currentGlobal must be a Global"
            in
            -- J5: thread the unify env into the returned state.
            ( Mono.MonoEnum (CtorTag.effective enumHome ctorName tag) monoType, setMVarEnv envU state )

        TOpt.Box canType ->
            -- @unbox types have a single constructor (tag=0) with one field (arity=1).
            -- Treat them as regular constructors so eco.construct.custom is emitted.
            specializeCtorViaScheme ctorName 0 1 canType requestedMonoType state

        TOpt.Link linkedGlobal ->
            -- Link to another global - follow the link
            case Data.Map.get TOpt.toComparableGlobal linkedGlobal state.ctx.toptNodes of
                Nothing ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just linkedNode ->
                    let
                        linkedName =
                            case linkedGlobal of
                                TOpt.Global _ name ->
                                    name
                    in
                    specializeNode linkedName linkedNode requestedMonoType state

        TOpt.Kernel _ _ ->
            -- Inline kernel code - treat as extern
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Manager _ ->
            -- Effect manager leaf: generate a function that calls Elm_Kernel_Platform_leaf
            let
                homeModuleName =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global (IO.Canonical _ modName) _) ->
                            Name.toElmString modName

                        _ ->
                            "Unknown"
            in
            ( Mono.MonoManagerLeaf homeModuleName requestedMonoType, state )

        TOpt.Cycle names valueDefs funcDefs _ ->
            specializeCycle names valueDefs funcDefs requestedMonoType state

        TOpt.PortIncoming expr _ meta ->
            case requestedMonoType of
                Mono.MFunction _ _ _ _ ->
                    -- The port itself, used as `(payload -> msg) -> Sub msg`:
                    -- lower to the Fx_Leaf wrapper closure and enqueue the
                    -- payload Decoder as a separate specialization.
                    specializePortNode True expr meta.tipe requestedMonoType state

                _ ->
                    -- Decoder-value specialization (enqueued by the wrapper
                    -- case via enqueueSpec at the Decoder type): compile the
                    -- payload Decoder as a plain value node. The generated
                    -- @__eco_register_ports preamble calls its thunk and
                    -- hands the decoder to the runtime port registry.
                    let
                        decoderCanType =
                            TOpt.typeOf expr

                        ( subst, envU ) =
                            TypeSubst.unify state.ctx.mvarEnv decoderCanType requestedMonoType

                        ( monoExpr, state1 ) =
                            specializeExpr expr subst (setMVarEnv envU state)
                    in
                    ( Mono.MonoDefine monoExpr requestedMonoType, state1 )

        TOpt.PortOutgoing expr _ meta ->
            specializePortNode False expr meta.tipe requestedMonoType state


{-| Lower a port node to its Fx\_Leaf wrapper closure (PORT\_002).

Incoming `port bar : (payload -> msg) -> Sub msg` becomes

    \tagger -> Elm_Kernel_Platform_leaf "bar" tagger

and the payload decoder is enqueued as a separate specialization of the
same Global at its (non-function) `Decoder payload` type — the worklist
driver routes that request back through the PortIncoming arm, which
compiles it as a plain `MonoDefine` value node. Prune keeps the decoder
spec alive via `MonoGraph.ports` and the MLIR backend registers it with
the runtime at startup (PORT\_003).

Outgoing `port foo : payload -> Cmd msg` becomes

    \p -> Elm_Kernel_Platform_leaf "foo" (encoder p)

The encoder runs eagerly at the call site, so an outgoing Fx\_Leaf value
is always an already-encoded Json value by the time the port's effect
manager sees it.

Both wrappers are proper zero-capture `MonoClosure`s, so every downstream
GlobalOpt invariant (arity tracking, staging canonicalization, GOPT\_001)
holds without port-specific handling.

-}
specializePortNode :
    Bool
    -> TOpt.Expr MVarId
    -> Can.Type MVarId
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializePortNode incoming expr canType requestedMonoType state =
    let
        ( portGlobal, portName ) =
            case state.ctx.currentGlobal of
                Just ((Mono.Global _ name) as g) ->
                    ( g, Name.toElmString name )

                _ ->
                    Utils.Crash.crash "specializePortNode: currentGlobal must be a Global"

        ( subst, portEnv ) =
            TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType

        ( paramType, resultType ) =
            case requestedMonoType of
                Mono.MFunction _ _ [ p ] r ->
                    ( p, r )

                _ ->
                    Utils.Crash.crash
                        ("specializePortNode: port '"
                            ++ portName
                            ++ "' must have a single-parameter function type"
                        )

        region =
            A.zero

        ctx =
            state.ctx

        lambdaId =
            Mono.AnonymousLambda ctx.currentModule ctx.lambdaCounter

        stateWithLambda =
            { state | ctx = { ctx | lambdaCounter = ctx.lambdaCounter + 1, mvarEnv = portEnv } }

        paramName =
            "_eco_port_arg"

        paramVar =
            Mono.MonoVarLocal paramName paramType

        nameLit =
            Mono.MonoLiteral (Mono.LStr portName) Mono.MString

        leafKernel valueType =
            Mono.MonoVarKernel region
                "Elm"
                "Platform"
                "leaf"
                (Mono.mFunction Mono.LTop [ Mono.MString, valueType ] resultType)

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( paramName, paramType ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
    in
    if incoming then
        let
            body =
                Mono.MonoCall region
                    (leafKernel paramType)
                    [ nameLit, paramVar ]
                    resultType
                    Mono.defaultCallInfo

            wrapper =
                Mono.MonoClosure closureInfo body requestedMonoType

            decoderMonoType =
                TypeSubst.applySubstPure stateWithLambda.ctx.mvarEnv subst (TOpt.typeOf expr)

            ( decoderSpecId, state1 ) =
                enqueueSpec portGlobal decoderMonoType stateWithLambda

            state2 =
                recordPortRegistration
                    { name = portName
                    , key = Mono.toComparableGlobal portGlobal
                    , incoming = True
                    , decoderSpecId = Just decoderSpecId
                    }
                    state1
        in
        ( Mono.MonoPortIncoming wrapper requestedMonoType, state2 )

    else
        let
            ( encoderMono, state1 ) =
                specializeExpr expr subst stateWithLambda

            encodedType =
                case Mono.typeOf encoderMono of
                    Mono.MFunction _ _ _ r ->
                        r

                    t ->
                        t

            encodedExpr =
                Mono.MonoCall region
                    encoderMono
                    [ paramVar ]
                    encodedType
                    Mono.defaultCallInfo

            body =
                Mono.MonoCall region
                    (leafKernel encodedType)
                    [ nameLit, encodedExpr ]
                    resultType
                    Mono.defaultCallInfo

            wrapper =
                Mono.MonoClosure closureInfo body requestedMonoType

            state2 =
                recordPortRegistration
                    { name = portName
                    , key = Mono.toComparableGlobal portGlobal
                    , incoming = False
                    , decoderSpecId = Nothing
                    }
                    state1
        in
        ( Mono.MonoPortOutgoing wrapper requestedMonoType, state2 )


{-| Record a port registration once per port Global (multiple monomorphic
instantiations of the same port share one registration). Two DIFFERENT
ports with the same bare name are both kept — the runtime's registration
preamble then crashes at startup with a duplicate-name message
(PORT\_001, JS \_Platform\_checkPortName parity).
-}
recordPortRegistration : Mono.PortRegistration -> MonoState -> MonoState
recordPortRegistration reg state =
    let
        accum =
            state.accum
    in
    if List.any (\p -> p.key == reg.key) accum.ports then
        state

    else
        { state | accum = { accum | ports = reg :: accum.ports } }


{-| Specialize a mutually recursive cycle, handling both value and function definitions.
-}
specializeCycle :
    List Name
    -> List ( Name, TOpt.Expr MVarId )
    -> List (TOpt.Def MVarId)
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeCycle _ valueDefs funcDefs requestedMonoType state =
    case ( List.isEmpty funcDefs, state.ctx.currentGlobal ) of
        ( True, Just (Mono.Global requestedCanonical requestedName) ) ->
            -- Pure-value SCC: specializeFunctionCycle with an empty funcDefs reduces
            -- exactly to the old specializeValueCycle (its extra unifyExtend on an empty
            -- func-subst is a no-op: `unify e t m` ≡ `unifyExtend e t m Dict.empty`).
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                []
                requestedMonoType
                state

        ( True, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                funcDefs
                requestedMonoType
                state

        ( _, Just (Mono.Accessor _) ) ->
            -- Accessors are virtual globals and don't participate in cycles
            Utils.Crash.crash "Specialize.specializeCycle: Accessor should not appear in cycles"


{-| Specialize a single (Name, Expr) pair inside a value-only cycle.
-}
specializeValueInCycle :
    IO.Canonical
    -> Name
    -> Mono.MonoType
    -> Substitution
    -> ( Name, TOpt.Expr MVarId )
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst ( name, expr ) ( accNodes, accState ) =
    let
        globalVal =
            Mono.Global requestedCanonical name

        canType =
            TOpt.typeOf expr

        monoTypeFromExpr =
            TypeSubst.applySubstPure accState.ctx.mvarEnv sharedSubst canType

        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromExpr

        accum =
            accState.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalVal monoTypeForSpecId accum.registry

        accState1 =
            { accState | accum = { accum | registry = newRegistry } }
    in
    if arrayHasNode specId accNodes then
        ( accNodes, accState1 )

    else
        let
            ( monoExpr, accState2 ) =
                specializeExpr expr sharedSubst accState1

            monoNode =
                Mono.MonoDefine monoExpr (Mono.typeOf monoExpr)

            nextNodes =
                arraySetGrowing specId (Just monoNode) accNodes
        in
        ( nextNodes, accState2 )


{-| Specialize a cycle that contains at least one function definition, by
creating separate nodes for each function in `funcDefs` AND each zero-arg value
in `valueDefs`.

This handles ALL SCCs — mixed value+function and (with `funcDefs = []`) pure-value —
so it is the sole cycle specializer (`specializeCycle` routes every case here).

  - `sharedSubst` is derived from the requested member, which may be either
    a function (in `funcDefs`) or a value (in `valueDefs`). The two sources
    are combined via `TypeSubst.unifyExtend` so neither overrides the other.
    In practice only one ever applies because a given top-level name is
    either a `Define` (value) or a `Def`/`TailDef` (function), never both
    (see specialize-cycle disjointness invariant).
  - All `funcDefs` are specialized via `specializeFunc`.
  - All `valueDefs` are specialized via `specializeValueInCycle`.

This guarantees that any requested global in the SCC (function or value) gets
a real MonoNode instead of falling back to MonoExtern.

-}
specializeFunctionCycle :
    IO.Canonical
    -> Name
    -> List ( Name, TOpt.Expr MVarId )
    -> List (TOpt.Def MVarId)
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFunctionCycle requestedCanonical requestedName valueDefs funcDefs requestedMonoType state =
    let
        maybeRequestedDef =
            List.filter (defHasName requestedName) funcDefs
                |> List.head

        maybeRequestedExpr =
            List.filter (\( n, _ ) -> n == requestedName) valueDefs
                |> List.head

        -- Seed with the function-derived subst if the requested name is a
        -- function. If not, this stays empty and unifyExtend below will build
        -- the subst from the value expression alone.
        -- J5: keep each unify's env, chain them, and thread into the fold's state.
        ( substFromFunc, envFromFunc ) =
            case maybeRequestedDef of
                Just def ->
                    TypeSubst.unify
                        state.ctx.mvarEnv
                        (getDefCanonicalType def)
                        requestedMonoType

                Nothing ->
                    ( Dict.empty, state.ctx.mvarEnv )

        -- Extend with value-derived bindings if the requested name is a value.
        -- Using unifyExtend mirrors how `specializeNode`'s TOpt.Define /
        -- TrackedDefine cases enrich substitutions.
        ( sharedSubst, sharedEnv ) =
            case maybeRequestedExpr of
                Just ( _, expr ) ->
                    TypeSubst.unifyExtend
                        envFromFunc
                        (TOpt.typeOf expr)
                        requestedMonoType
                        substFromFunc

                Nothing ->
                    ( substFromFunc, envFromFunc )

        -- Specialize all functions in the cycle under sharedSubst.
        ( nodesAfterFuncs, stateAfterFuncs ) =
            List.foldl
                (specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, setMVarEnv sharedEnv state )
                funcDefs

        -- Specialize all values in the cycle under the same sharedSubst.
        ( newNodes, stateAfter ) =
            List.foldl
                (specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst)
                ( nodesAfterFuncs, stateAfterFuncs )
                valueDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType stateAfter.accum.registry
    in
    case Array.get requestedSpecId newNodes |> Maybe.andThen identity of
        Just requestedNode ->
            ( requestedNode
            , { stateAfter
                | accum =
                    let
                        a =
                            stateAfter.accum
                    in
                    { a | nodes = newNodes }
              }
            )

        Nothing ->
            -- Should not occur once mixed cycles populate values: the
            -- requested name is guaranteed to be in `names` of the Cycle.
            -- Retain the MonoExtern fallback as a belt-and-braces guard.
            ( Mono.MonoExtern requestedMonoType
            , { stateAfter
                | accum =
                    let
                        a =
                            stateAfter.accum
                    in
                    { a | nodes = newNodes }
              }
            )


specializeFunc :
    IO.Canonical
    -> Name
    -> Mono.MonoType
    -> Substitution
    -> TOpt.Def MVarId
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst def ( accNodes, accState ) =
    let
        name =
            getDefName def

        globalFun =
            Mono.Global requestedCanonical name

        canType =
            getDefCanonicalType def

        monoTypeFromDef =
            TypeSubst.applySubstPure accState.ctx.mvarEnv sharedSubst canType

        -- For the requested function in this cycle, use the exact MonoType
        -- from the worklist (requestedMonoType) as the specialization key.
        -- This ensures the SpecId matches what call sites expect.
        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromDef

        accum =
            accState.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalFun monoTypeForSpecId accum.registry

        accState1 =
            { accState | accum = { accum | registry = newRegistry } }
    in
    if arrayHasNode specId accNodes then
        ( accNodes, accState1 )

    else
        let
            ( monoNode, accState2 ) =
                specializeFuncDefInCycle sharedSubst def accState1

            nextNodes =
                arraySetGrowing specId (Just monoNode) accNodes
        in
        ( nextNodes, accState2 )


specializeFuncDefInCycle :
    Substitution
    -> TOpt.Def MVarId
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFuncDefInCycle subst def state =
    case def of
        TOpt.Def _ _ expr _ ->
            let
                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TailDef _ _ args body returnType _ ->
            let
                monoArgs =
                    List.map (specializeArg state.ctx.mvarEnv subst) args

                ctx =
                    state.ctx

                newVarEnv =
                    List.foldl
                        (\( name, monoParamType ) ve -> State.insertVar name monoParamType ve)
                        (State.pushFrame ctx.varEnv)
                        monoArgs

                stateWithParams =
                    { state | ctx = { ctx | varEnv = newVarEnv, mvarEnv = augmentedEnv } }

                -- J5: fold both the subst AND the env so per-param taints survive.
                ( augmentedSubstRaw, augmentedEnv ) =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) ( s, e ) ->
                            TypeSubst.unifyExtend e canParamType monoParamType s
                        )
                        ( subst, state.ctx.mvarEnv )
                        (List.map2 Tuple.pair args monoArgs)

                ( monoBody, state1pre ) =
                    specializeExpr body augmentedSubstRaw stateWithParams

                state1 =
                    { state1pre
                        | ctx =
                            let
                                ctx1 =
                                    state1pre.ctx
                            in
                            { ctx1 | varEnv = State.popFrame ctx1.varEnv }
                    }

                -- Note: `returnType` is misleadingly named - it's actually the FULL function
                -- type of the definition (e.g., Int -> Int -> Int becomes MFunction [MInt] (MFunction [MInt] MInt)).
                -- Context.extractNodeSignature expects this full function type and extracts
                -- the actual return type from it.
                monoFuncType =
                    TypeSubst.applySubstPure state.ctx.mvarEnv augmentedSubstRaw returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoFuncType, state1 )



-- ========== VALUE DEFINITIONS ==========
-- ========== EXPRESSION SPECIALIZATION ==========


{-| Specialize a typed optimized expression to a monomorphized expression by applying type substitutions.
-}
specializeGeneralDestruct : TOpt.Destructor MVarId -> TOpt.Expr MVarId -> TOpt.Meta MVarId -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeGeneralDestruct destructor body meta subst state =
    let
        canType =
            meta.tipe

        ( monoType0, stateI0 ) =
            applySubstFV state subst canType

        (TOpt.Destructor dname destructorPath destructorMeta) =
            destructor

        maybeValueMultiRefinement =
            case getValueMultiRootFromPath destructorPath stateI0 of
                Just ( rootName, rootCanType ) ->
                    let
                        ( rootResolved, stateRR ) =
                            applySubstFV stateI0 subst rootCanType
                    in
                    if not (Mono.containsAnyMVar rootResolved) then
                        -- The root is already fully concrete (no remaining type
                        -- variables): there is nothing for the destructor to narrow, and
                        -- the existing value instance keyed by the resolved type already
                        -- matches. Fall through to the non-refining path (`Nothing`).
                        --
                        -- Running buildPartialContainer/unifyExtend on an
                        -- already-concrete root is not merely redundant but
                        -- actively wrong when the same canonical type variable
                        -- appears in multiple container slots (e.g. a tuple whose
                        -- elements share one solver var, `(v, v, v)`): the partial
                        -- container fills the non-leaf slots with fresh distinct
                        -- CEcoValue fillers, and unifying that against the repeated
                        -- var rebinds it once per slot, aliasing it to the last
                        -- (unbound) filler. The root instance would then collapse
                        -- to all-boxed and a spurious second instance (`_v0$v1`)
                        -- would be created, desyncing the projection layout from
                        -- the scrutinee's actual unboxed layout (CGEN_040
                        -- operand-type violation).
                        --
                        -- The number-multi-root-with-a-Float-demand case (formerly the
                        -- `floatDemand /= Nothing` carve-out here) no longer reaches this
                        -- path: it is diverted to `specializeNumberDestruct` (body-first,
                        -- MONO_028), which discovers the Float demand from the body's uses
                        -- instead of the deleted `demandedNumericUseType` look-ahead.
                        Nothing

                    else
                        let
                            ( eagerLeaf, stateRE ) =
                                applySubstFV stateRR subst destructorMeta.tipe

                            -- The slot's open (closes-to-Int) leaf. A number-multi root
                            -- whose slot genuinely demands Float is handled by the
                            -- body-first `specializeNumberDestruct` divert, so here the
                            -- leaf is materialised as-is.
                            destrMonoType0 =
                                eagerLeaf
                        in
                        case buildPartialContainer rootCanType destructorPath destrMonoType0 stateRE of
                            Just ( partialContainerMono, stateP ) ->
                                let
                                    ( refinedSubst, mvarEnv1 ) =
                                        TypeSubst.unifyExtend stateP.ctx.mvarEnv
                                            rootCanType
                                            partialContainerMono
                                            subst

                                    stateR0 =
                                        setMVarEnv mvarEnv1 stateP

                                    ( rootInstanceMonoType, stateR ) =
                                        applySubstFV stateR0 refinedSubst rootCanType

                                    ( freshRootName, stateI ) =
                                        getOrCreateValueInstance rootName
                                            rootInstanceMonoType
                                            refinedSubst
                                            stateR

                                    -- Record `dname` on the owning instance so later
                                    -- call sites of this destructor can refine `info.subst`
                                    -- via refineValueMultiForDestructorCall. Uses the same
                                    -- comparable-MonoType key as getOrCreateValueInstance.
                                    instanceKey =
                                        rootInstanceMonoType

                                    taggedStack =
                                        tagValueInstanceWithDestructor rootName
                                            instanceKey
                                            dname
                                            stateI.ctx.valueMulti

                                    stateT =
                                        { stateI
                                            | ctx =
                                                let
                                                    ct =
                                                        stateI.ctx
                                                in
                                                { ct | valueMulti = taggedStack }
                                        }

                                    rewrittenDestructor =
                                        TOpt.Destructor dname
                                            (rewriteRootInPath rootName
                                                freshRootName
                                                destructorPath
                                            )
                                            destructorMeta

                                    stateWithRoot =
                                        { stateT
                                            | ctx =
                                                let
                                                    c =
                                                        stateT.ctx
                                                in
                                                { c
                                                    | varEnv =
                                                        State.insertVar freshRootName
                                                            rootInstanceMonoType
                                                            c.varEnv
                                                }
                                        }
                                in
                                Just ( rewrittenDestructor, refinedSubst, stateWithRoot )

                            Nothing ->
                                Nothing

                Nothing ->
                    Nothing

        ( effectiveDestructor, effectiveSubst, stateForDestruct ) =
            case maybeValueMultiRefinement of
                Just triple ->
                    triple

                Nothing ->
                    ( destructor, subst, stateI0 )

        monoDestructor =
            specializeDestructor effectiveDestructor
                effectiveSubst
                stateForDestruct.ctx.mvarEnv
                stateForDestruct.ctx.varEnv
                stateForDestruct.ctx.globalTypeEnv
                stateForDestruct.ctx.currentGlobal

        (Mono.MonoDestructor destructorName _ destructorType) =
            monoDestructor

        stateWithVar =
            { stateForDestruct
                | ctx =
                    let
                        cd =
                            stateForDestruct.ctx
                    in
                    { cd | varEnv = State.insertVar destructorName destructorType cd.varEnv }
            }

        ( monoBody, stateAfter ) =
            specializeExpr body effectiveSubst stateWithVar

        monoType =
            if Mono.containsAnyMVar monoType0 then
                Mono.typeOf monoBody

            else
                monoType0
    in
    ( Mono.MonoDestruct monoDestructor monoBody monoType, stateAfter )


{-| Shared tail of the four eager-let fallbacks in the `TOpt.Let` arm (localMulti
empty/underflow, valueMulti empty, plain non-function let). Given the def already
specialized (`monoDef`/`state1`) and — for the multi paths — the body already
specialized under the multi-stack entry (`probeBody`), decide the binding's mono type
(preferring the RHS type when `applySubst` narrowed a row-poly record, per `recordWidened`),
enrich the subst if needed, and build the `MonoLet`.

`state` is the OUTER pre-def state used only for `applySubstFV defCanType`. When
`probeBody` is `Just` and no enrichment is needed the probe body is reused (no re-spec);
otherwise the body is specialized once under the (possibly enriched) subst and
`stateWithVar`. The plain-let path (D) passes `probeBody = Nothing`, so it always specializes
the body here — it had no earlier multi-stack probe.

-}
finishEagerLet :
    MonoState
    -> TOpt.Expr MVarId
    -> Maybe Mono.MonoExpr
    -> Name
    -> Can.Type MVarId
    -> Mono.MonoType
    -> Substitution
    -> Mono.MonoDef
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
finishEagerLet state body probeBody defName defCanType monoType0 subst monoDef state1 =
    let
        -- Reads the OUTER state's env (see the docstring) but threads the Intern
        -- table on `state1`, which is the state that continues from here.
        ( defMonoType0, state1I ) =
            applySubstFVWithEnv state.ctx.mvarEnv state1 subst defCanType

        exprMonoType =
            monoDefExprType monoDef

        useExprType =
            Mono.containsAnyMVar defMonoType0 || recordWidened defMonoType0 exprMonoType

        defMonoType =
            if useExprType then
                exprMonoType

            else
                defMonoType0

        -- J5: unify from state1's env (superset of state's; env is monotonic) and
        -- thread the result into stateWithVar.
        ( enrichedSubst, enrichedEnv ) =
            if useExprType then
                TypeSubst.unifyExtend state1I.ctx.mvarEnv defCanType defMonoType subst

            else
                ( subst, state1I.ctx.mvarEnv )

        stateWithVar =
            { state1I
                | ctx =
                    let
                        c =
                            state1I.ctx
                    in
                    { c
                        | varEnv = State.insertVar defName defMonoType c.varEnv
                        , mvarEnv = enrichedEnv
                    }
            }

        ( monoBody2, state2 ) =
            case ( probeBody, useExprType ) of
                ( Just pb, False ) ->
                    ( pb, stateWithVar )

                _ ->
                    specializeExpr body enrichedSubst stateWithVar
    in
    ( Mono.MonoLet monoDef
        monoBody2
        (if Mono.containsAnyMVar monoType0 then
            Mono.typeOf monoBody2

         else
            monoType0
        )
    , state2
    )


{-| Shared per-field body of the `Record`/`TrackedRecord` arms: refine the subst with
the field's expected mono type (so lambdas inside records get concrete types), specialize
the field expr, and cons it onto the accumulator. Each arm keeps its own fold so the
field-specialization ORDER (and thus enqueue/instance side effects) is preserved exactly:
`Record` folds a `Dict Name` (name order), `TrackedRecord` a located-key map
(`A.compareLocated` order).
-}
specializeRecordField :
    Substitution
    -> Dict.Dict Name Mono.MonoType
    -> Name
    -> TOpt.Expr MVarId
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeRecordField subst monoFieldTypes fieldName fieldExpr ( acc, st ) =
    let
        -- J5: unify from the fold state's env and thread it forward.
        ( refinedSubst, refinedEnv ) =
            case Dict.get fieldName monoFieldTypes of
                Just fieldMonoType ->
                    TypeSubst.unifyExtend st.ctx.mvarEnv (TOpt.typeOf fieldExpr) fieldMonoType subst

                Nothing ->
                    ( subst, st.ctx.mvarEnv )

        ( monoExpr, newSt ) =
            specializeExpr fieldExpr refinedSubst (setMVarEnv refinedEnv st)
    in
    ( ( fieldName, monoExpr ) :: acc, newSt )


{-| Build a record's MonoType (Fix A) from its already-specialized field exprs, rather
than from the substituted canonical type — avoids the unboxed-first / declaration-order
slot-index disagreement between construction and projection sites.
-}
recordMonoTypeFromFields : List ( Name, Mono.MonoExpr ) -> Mono.MonoType
recordMonoTypeFromFields monoFields =
    Mono.mRecord
        (List.foldl
            (\( fn, e ) acc -> Dict.insert fn (Mono.typeOf e) acc)
            Dict.empty
            monoFields
        )


specializeExpr : TOpt.Expr MVarId -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeExpr expr subst state =
    case expr of
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )

        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )

        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        TOpt.Int _ value meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType
            in
            case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, stateI )

                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, stateI )

        TOpt.Float _ value meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType
            in
            ( Mono.MonoLiteral (Mono.LFloat value) monoType, stateI )

        TOpt.VarLocal name meta ->
            if isLocalMultiTarget name state then
                let
                    ( monoTypeFromMeta, stateI ) =
                        applySubstFV state subst meta.tipe

                    ( freshName, state1 ) =
                        getOrCreateLocalInstance name monoTypeFromMeta subst stateI
                in
                ( Mono.MonoVarLocal freshName monoTypeFromMeta, state1 )

            else if isNumberMultiTarget name state then
                resolveNumberMultiVarRef name meta.tipe subst state

            else
                case State.lookupVar name state.ctx.varEnv of
                    Just envType ->
                        ( Mono.MonoVarLocal name envType, state )

                    Nothing ->
                        let
                            ( monoTypeFromMeta, stateI ) =
                                applySubstFV state subst meta.tipe
                        in
                        ( Mono.MonoVarLocal name monoTypeFromMeta, stateI )

        TOpt.TrackedVarLocal _ name meta ->
            -- Tracking region is unused here; delegate to the untracked arm.
            specializeExpr (TOpt.VarLocal name meta) subst state

        TOpt.VarGlobal region global meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoType, stateM ) =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global stateI.ctx.toptNodes of
                                Just (TOpt.Define _ _ defMeta) ->
                                    applySubstFV stateI subst defMeta.tipe

                                Just (TOpt.TrackedDefine _ _ _ defMeta) ->
                                    applySubstFV stateI subst defMeta.tipe

                                Just (TOpt.Enum _ enumCanType) ->
                                    applySubstFV stateI subst enumCanType

                                Just (TOpt.Ctor _ _ ctorCanType) ->
                                    applySubstFV stateI subst ctorCanType

                                _ ->
                                    ( monoType0, stateI )

                        _ ->
                            ( monoType0, stateI )

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType stateM
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarEnum region global _ meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoType, stateM ) =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global stateI.ctx.toptNodes of
                                Just (TOpt.Enum _ enumCanType) ->
                                    applySubstFV stateI subst enumCanType

                                _ ->
                                    ( monoType0, stateI )

                        _ ->
                            ( monoType0, stateI )

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType stateM
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarBox region global meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType stateI
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarCycle region canonical name meta ->
            let
                -- Prefer the canonical scheme type from the TypedOptimized graph
                -- so we do not depend on the potentially fragmented meta.tipe TVars.
                schemeType =
                    case Data.Map.get TOpt.toComparableGlobal (TOpt.Global canonical name) state.ctx.toptNodes of
                        Just (TOpt.Define _ _ defMeta) ->
                            defMeta.tipe

                        Just (TOpt.TrackedDefine _ _ _ defMeta) ->
                            defMeta.tipe

                        Just (TOpt.Cycle _ _ funcDefs _) ->
                            -- For functions in a recursive cycle, find the matching Def/TailDef
                            -- and use its canonical function type.
                            let
                                maybeDef =
                                    List.filter (\d -> getDefName d == name) funcDefs |> List.head
                            in
                            case maybeDef of
                                Just def ->
                                    getDefCanonicalType def

                                Nothing ->
                                    meta.tipe

                        _ ->
                            -- Fallback: use the VarCycle's own meta.tipe if we cannot
                            -- find a node or matching def. This should not normally happen.
                            meta.tipe

                monoType =
                    TypeSubst.applySubstPure state.ctx.mvarEnv subst schemeType

                monoGlobal =
                    Mono.Global canonical name

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarDebug region name _ _ meta ->
            let
                canType =
                    meta.tipe

                funcMonoType =
                    deriveKernelAbiType state.ctx.mvarEnv ( "Debug", name ) canType subst
            in
            ( Mono.MonoVarKernel region "Elm" "Debug" name funcMonoType, state )

        TOpt.VarKernel region kernelPrefix home name meta ->
            let
                canType =
                    meta.tipe

                funcMonoType =
                    deriveKernelAbiType state.ctx.mvarEnv ( home, name ) canType subst
            in
            ( Mono.MonoVarKernel region kernelPrefix home name funcMonoType, state )

        TOpt.List region exprs meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoExprs, stateAfter ) =
                    specializeExprs exprs subst stateI

                -- If the element type has unresolved TVars, infer from first element.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case monoExprs of
                            first :: _ ->
                                Mono.mList (Mono.typeOf first)

                            [] ->
                                -- Empty list: element type is unconstrained, leave as-is.
                                -- MVar _ CEcoValue compiles identically to eco.value.
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoList region monoExprs monoType, stateAfter )

        TOpt.Function srcLam params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.Function srcLam params body meta) canType subst state

        TOpt.TrackedFunction srcLam params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.TrackedFunction srcLam params body meta) canType subst state

        TOpt.Call region func args meta ->
            -- Two-phase argument processing: defer accessor specialization until after
            -- call-site type unification, so accessors receive fully-resolved record types.
            let
                canType =
                    meta.tipe

                ( processedArgs, argTypes, state1 ) =
                    processCallArgs args subst state

                -- Refine caller substitution with container element types from arg exprs.
                -- This pushes bindings like a=MInt from List Int args back into subst,
                -- so helpers like foldrHelper get distinct specializations per element type.
                -- Skipped for local multi-target calls (they share MVarIds, no freshening).
                ( substForCall, mvarEnv1 ) =
                    refineSubstFromArgExprs state1.ctx.mvarEnv args argTypes subst

                state1r =
                    let
                        ctx =
                            state1.ctx
                    in
                    { state1 | ctx = { ctx | mvarEnv = mvarEnv1 } }
            in
            case func of
                TOpt.VarGlobal funcRegion global funcMeta ->
                    let
                        isMonoGlobal =
                            isMonomorphicGlobal global state1r

                        funcCanType : Can.Type MVarId
                        funcCanType =
                            case Data.Map.get TOpt.toComparableGlobal global state1r.ctx.annotations of
                                Just (Can.Forall _ annType) ->
                                    annType

                                Nothing ->
                                    funcMeta.tipe
                    in
                    if isMonoGlobal then
                        -- MONOMORPHIC FAST PATH: no SchemeInfo, no unifyCallSiteDirect.
                        -- The annotation has zero generalized vars, so applySubstPure with
                        -- substForCall is sufficient to derive the single funcMonoType.
                        let
                            funcMonoType =
                                TypeSubst.applySubstPure state1r.ctx.mvarEnv substForCall funcCanType

                            -- applySubstPure is env-pure (J5), so no mvarEnv update.
                            state1m =
                                state1r

                            paramTypes =
                                TypeSubst.extractParamTypes funcMonoType

                            ( monoArgs, state2 ) =
                                resolveProcessedArgs processedArgs paramTypes substForCall state1m

                            ( resultMonoType, state2I ) =
                                callResultMonoType
                                    state2.ctx.mvarEnv
                                    state2
                                    substForCall
                                    canType

                            monoGlobal =
                                toptGlobalToMono global

                            ( specId, newState ) =
                                enqueueSpec monoGlobal funcMonoType state2I

                            monoFunc =
                                Mono.MonoVarGlobal funcRegion specId funcMonoType
                        in
                        ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                        , newState
                        )

                    else
                        -- EXISTING POLYMORPHIC PATH (unchanged)
                        let
                            ( schemeInfo, state1a ) =
                                getOrBuildSchemeInfo funcCanType (Just global) state1r

                            -- J5: keep the call-site unify env and thread it downstream.
                            ( callSubst, funcMonoTypeRaw, callEnv ) =
                                TypeSubst.unifyCallSiteDirectWithExpected
                                    state1a.ctx.mvarEnv
                                    schemeInfo.argTypes
                                    schemeInfo.resultType
                                    argTypes
                                    (Just canType)
                                    substForCall

                            state1e =
                                setMVarEnv callEnv state1a

                            funcMonoType =
                                funcMonoTypeRaw

                            paramTypes =
                                TypeSubst.extractParamTypes funcMonoType

                            ( monoArgs, state2 ) =
                                resolveProcessedArgs processedArgs paramTypes callSubst state1e

                            ( resultMonoType, state2I ) =
                                callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                            monoGlobal =
                                toptGlobalToMono global

                            ( specId, newState ) =
                                enqueueSpec monoGlobal funcMonoType state2I

                            monoFunc =
                                Mono.MonoVarGlobal funcRegion specId funcMonoType
                        in
                        ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, newState )

                TOpt.VarKernel funcRegion kernelPrefix home name funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1r

                        -- Direct unification: scheme MVarIds are freshened by buildSchemeInfo
                        -- J5: keep the call-site unify env and thread it downstream.
                        ( callSubst, _, callEnv ) =
                            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                        state1e =
                            setMVarEnv callEnv state1a

                        -- Kernel ABI derivation uses funcCanType directly (no renaming)
                        funcMonoType =
                            deriveKernelAbiType state.ctx.mvarEnv ( home, name ) funcCanType callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                        -- Prefer the kernel ABI's result type when it is already
                        -- fully concrete (no free MVars). The enclosing canType
                        -- may still carry MVars from a polymorphic wrapper, so
                        -- re-deriving from it would lose the ABI's concreteness
                        -- (root cause of heap-layout mismatches for kernels like
                        -- Parser.findSubString returning (Int, Int, Int)).
                        -- Peel exactly as many layers as arguments applied —
                        -- kernels may be partially applied, so Mono.resultTypeOf
                        -- (which drills to the leaf) is unsafe.
                        abiResultType =
                            peelCallResult (List.length argTypes) funcMonoType

                        ( resultMonoType, state2I ) =
                            if Mono.containsAnyMVar abiResultType then
                                callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                            else
                                ( abiResultType, state2 )

                        monoFunc =
                            Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2I )

                TOpt.VarDebug funcRegion name _ _ funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1r

                        -- Direct unification: scheme MVarIds are freshened by buildSchemeInfo
                        -- J5: keep the call-site unify env and thread it downstream.
                        ( callSubst, _, callEnv ) =
                            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                        state1e =
                            setMVarEnv callEnv state1a

                        -- Kernel ABI derivation uses funcCanType directly (no renaming)
                        funcMonoType =
                            deriveKernelAbiType state.ctx.mvarEnv ( "Debug", name ) funcCanType callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                        -- Same invariant as VarKernel: trust the ABI-derived result
                        -- type when it is fully concrete; otherwise fall back to
                        -- the enclosing canType so MVar IDs stay aligned with the
                        -- enclosing spec key. Peel exactly the applied-arg count
                        -- to handle partial applications correctly.
                        abiResultType =
                            peelCallResult (List.length argTypes) funcMonoType

                        ( resultMonoType, state2I ) =
                            if Mono.containsAnyMVar abiResultType then
                                callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                            else
                                ( abiResultType, state2 )

                        monoFunc =
                            Mono.MonoVarKernel funcRegion "Elm" "Debug" name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2I )

                _ ->
                    -- Fallback: locally-bound or non-global function.
                    -- Checked in order:
                    --   1. Destructor-call branch: `func` is a local whose name is
                    --      registered on some enclosing value-multi instance. Refine
                    --      that instance's `subst` with call-site unification so the
                    --      eventual emit sees concrete field/lambda types.
                    --   2. LocalMulti branch: `func` names a let-bound function being
                    --      multi-specialized.
                    --   3. Non-local scheme branch: everything else.
                    let
                        funcCanType =
                            TOpt.typeOf func

                        maybeFuncName =
                            case func of
                                TOpt.VarLocal name _ ->
                                    Just name

                                TOpt.TrackedVarLocal _ name _ ->
                                    Just name

                                _ ->
                                    Nothing

                        maybeDestructorRefinement =
                            case maybeFuncName of
                                Just fname ->
                                    refineValueMultiForDestructorCall fname
                                        funcCanType
                                        argTypes
                                        state1r.ctx.mvarEnv
                                        state1r.ctx.valueMulti

                                Nothing ->
                                    Nothing

                        localMultiName =
                            case maybeFuncName of
                                Just name ->
                                    if isLocalMultiTarget name state1 then
                                        Just name

                                    else
                                        Nothing

                                Nothing ->
                                    Nothing
                    in
                    case maybeDestructorRefinement of
                        Just ( callSubst, newEnv, newStack ) ->
                            -- Destructor call on a value-multi instance: the refined
                            -- `callSubst` has already been written back onto that
                            -- instance inside refineValueMultiForDestructorCall; here we
                            -- just use it for this call's own specialization.
                            let
                                state1d0 =
                                    let
                                        ctx =
                                            state1r.ctx
                                    in
                                    { state1r
                                        | ctx =
                                            { ctx
                                                | mvarEnv = newEnv
                                                , valueMulti = newStack
                                            }
                                    }

                                ( funcMonoType, state1d ) =
                                    applySubstFV state1d0 callSubst funcCanType

                                paramTypes =
                                    TypeSubst.extractParamTypes funcMonoType

                                ( monoArgs, state2 ) =
                                    resolveProcessedArgs processedArgs paramTypes callSubst state1d

                                ( resultMonoType, state2I ) =
                                    callResultMonoType state2.ctx.mvarEnv state2 callSubst canType

                                ( monoFunc, state3 ) =
                                    specializeExpr func callSubst state2I
                            in
                            ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                            , state3
                            )

                        Nothing ->
                            case localMultiName of
                                Just name ->
                                    -- Local multi target: type variables are shared with enclosing
                                    -- scope, so we must NOT rename them (no unifyFuncCall).
                                    -- Use unifyArgsOnly to extend the caller's subst with arg bindings.
                                    let
                                        -- J5: keep the args-only unify env and thread it downstream.
                                        ( callSubst, callEnv ) =
                                            TypeSubst.unifyArgsOnly state1.ctx.mvarEnv funcCanType argTypes subst

                                        state1e0 =
                                            setMVarEnv callEnv state1

                                        ( funcMonoType, state1e ) =
                                            applySubstFV state1e0 callSubst funcCanType

                                        paramTypes =
                                            TypeSubst.extractParamTypes funcMonoType

                                        ( monoArgs, state2 ) =
                                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                                        ( resultMonoType, state2I ) =
                                            callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                                        ( freshName, state3 ) =
                                            getOrCreateLocalInstance name funcMonoType callSubst state2I

                                        monoFunc =
                                            Mono.MonoVarLocal freshName funcMonoType
                                    in
                                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                                    , state3
                                    )

                                Nothing ->
                                    -- Non-local function: direct unification (no renaming needed with global MVarIds)
                                    let
                                        ( schemeInfo, state1a ) =
                                            getOrBuildSchemeInfo funcCanType Nothing state1r

                                        -- J5: keep the call-site unify env and thread it downstream.
                                        ( callSubst, funcMonoTypeRaw, callEnv ) =
                                            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                                        state1e =
                                            setMVarEnv callEnv state1a

                                        funcMonoType =
                                            funcMonoTypeRaw

                                        paramTypes =
                                            TypeSubst.extractParamTypes funcMonoType

                                        ( monoArgs, state2 ) =
                                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                                        ( resultMonoType, state2I ) =
                                            callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                                        ( monoFunc, state3 ) =
                                            specializeExpr func callSubst state2I
                                    in
                                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                                    , state3
                                    )

        TOpt.TailCall name args meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoArgs, stateAfter ) =
                    specializeNamedExprs args subst stateI

                -- If the canonical type had unresolved TVars (producing CEcoValue),
                -- look up the result type from the tail-called function's registered type.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case State.lookupVar name stateAfter.ctx.varEnv of
                            Just funcType ->
                                Mono.resultTypeOf funcType

                            Nothing ->
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoTailCall name monoArgs monoType, stateAfter )

        TOpt.If branches final meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                -- Fix 2: the resolved if-result type is the consumer demand on every
                -- branch. Push it onto each branch's own type so a generalized
                -- `number` branch (e.g. the `then`-branch reference `n` in
                -- `(if c then n else 0) * 1.5`, whose node still says `number`) is
                -- specialized at the result type rather than defaulting to Int.
                ( monoBranches, state1 ) =
                    specializeBranches monoType0 branches subst stateI

                ( monoFinal, state2 ) =
                    -- J5: thread the pushed-type unify env into the branch specialization.
                    let
                        ( pushedSubst, pushedEnv ) =
                            pushExpectedType state1.ctx.mvarEnv monoType0 (TOpt.typeOf final) subst
                    in
                    specializeExpr final pushedSubst (setMVarEnv pushedEnv state1)

                -- If the canonical type had unresolved TVars (producing CEcoValue),
                -- infer the concrete type from the specialized final branch instead.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.typeOf monoFinal

                    else
                        monoType0
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateL ) =
                    applySubstFV state subst canType

                defName =
                    getDefName def

                defCanType =
                    getDefCanonicalType def
            in
            case defCanType of
                Can.TLambda _ _ ->
                    -- Function def: demand-driven local multi-specialization.
                    -- Push a fresh entry onto the localMulti stack for this defName.
                    let
                        newEntry =
                            { defName = defName
                            , instances = Mono.specMapEmpty
                            }

                        stateForBody =
                            { stateL
                                | ctx =
                                    let
                                        c =
                                            stateL.ctx
                                    in
                                    { c | localMulti = newEntry :: c.localMulti }
                            }

                        -- Specialize the body under the outer substitution,
                        -- with the new localMulti stack entry for this defName.
                        ( monoBody, stateAfterBody ) =
                            specializeExpr body subst stateForBody
                    in
                    -- Pop our entry from the stack and extract discovered instances.
                    case stateAfterBody.ctx.localMulti of
                        topEntry :: restOfStack ->
                            if Mono.specMapIsEmpty topEntry.instances then
                                -- No calls to this def were recorded in the body:
                                -- fall back to single-instance behavior using the original name.
                                let
                                    -- Keep restOfStack so outer contexts are visible during specializeDef
                                    ( monoDef, state1 ) =
                                        specializeDef def
                                            subst
                                            { stateAfterBody
                                                | ctx =
                                                    let
                                                        cab =
                                                            stateAfterBody.ctx
                                                    in
                                                    { cab | localMulti = restOfStack }
                                            }
                                in
                                finishEagerLet stateL body (Just monoBody) defName defCanType monoType0 subst monoDef state1

                            else
                                -- We have one or more concrete instances discovered from call sites.
                                let
                                    instancesList =
                                        Mono.specMapValues topEntry.instances

                                    -- Build MonoDefs for each instance, bridging call-site types
                                    -- to the def's own type variables via unifyExtend.
                                    -- info.subst uses renamed call-site variable names which
                                    -- don't match the def's canonical type variables; unifyExtend
                                    -- properly maps the def's variables to the call-site mono types.
                                    ( instanceDefs, stateWithDefs ) =
                                        List.foldl
                                            (\info ( defsAcc, stAcc ) ->
                                                let
                                                    -- J5: unify from the accumulator's env and thread it forward.
                                                    ( mergedSubst, mergedEnv ) =
                                                        TypeSubst.unifyExtend stAcc.ctx.mvarEnv defCanType info.monoType subst

                                                    ( monoDef0, st1 ) =
                                                        specializeDef def mergedSubst (setMVarEnv mergedEnv stAcc)

                                                    monoDef =
                                                        renameMonoDef info.freshName monoDef0
                                                in
                                                ( monoDef :: defsAcc, st1 )
                                            )
                                            ( []
                                            , { stateAfterBody
                                                | ctx =
                                                    let
                                                        cab2 =
                                                            stateAfterBody.ctx
                                                    in
                                                    { cab2 | localMulti = restOfStack }
                                              }
                                            )
                                            instancesList

                                    -- Register varEnv for all instances
                                    stateWithVars =
                                        List.foldl
                                            (\info st ->
                                                { st
                                                    | ctx =
                                                        let
                                                            cst =
                                                                st.ctx
                                                        in
                                                        { cst
                                                            | varEnv =
                                                                State.insertVar info.freshName info.monoType cst.varEnv
                                                        }
                                                }
                                            )
                                            stateWithDefs
                                            instancesList

                                    -- Build nested MonoLet chain
                                    finalExpr =
                                        List.foldl
                                            (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                                            monoBody
                                            instanceDefs
                                in
                                ( finalExpr, stateWithVars )

                        [] ->
                            -- Should not happen: we pushed an entry above.
                            -- Fall back to single-instance behavior.
                            let
                                ( monoDef, state1 ) =
                                    specializeDef def subst stateAfterBody
                            in
                            finishEagerLet stateL body (Just monoBody) defName defCanType monoType0 subst monoDef state1

                _ ->
                    if shouldUseValueMulti stateL.ctx.mvarEnv defCanType then
                        -- Value-multi path: defer specialization until uses are known.
                        let
                            newEntry =
                                { defName = defName
                                , defCanType = defCanType
                                , def = def
                                , instances = Mono.specMapEmpty
                                }

                            -- Add defName to VarEnv with a preliminary type so that
                            -- Destruct nodes from LetDestruct can find their root variable.
                            -- (LetDestruct compiles to Let + Destruct chain where Destructs
                            -- reference Root defName.)
                            ( prelimDefMonoType, stateI ) =
                                applySubstFV stateL subst defCanType

                            stateForBody =
                                { stateI
                                    | ctx =
                                        let
                                            cvm =
                                                stateI.ctx
                                        in
                                        { cvm
                                            | valueMulti = newEntry :: cvm.valueMulti
                                            , varEnv = State.insertVar defName prelimDefMonoType cvm.varEnv
                                        }
                                }

                            ( monoBody, stateAfterBody ) =
                                specializeExpr body subst stateForBody
                        in
                        case stateAfterBody.ctx.valueMulti of
                            topEntry :: restOfStack ->
                                if Mono.specMapIsEmpty topEntry.instances then
                                    -- Value never used: fall back to eager single-instance behavior.
                                    let
                                        ( monoDef, state1 ) =
                                            specializeDef def
                                                subst
                                                { stateAfterBody
                                                    | ctx =
                                                        let
                                                            cvmf =
                                                                stateAfterBody.ctx
                                                        in
                                                        { cvmf | valueMulti = restOfStack }
                                                }
                                    in
                                    finishEagerLet stateL body (Just monoBody) defName defCanType monoType0 subst monoDef state1

                                else
                                    -- We have instances: specialize def once per requested type.
                                    --
                                    -- Per D6, `info.monoType` is only the coarse container shape
                                    -- used as the instance key; `info.subst` carries the fine-
                                    -- grained bindings accumulated from destructor-path refinement
                                    -- AND from call-site unification threaded back by the
                                    -- destructor-call branch (refineValueMultiForDestructorCall).
                                    -- Re-derive the instance MonoType from `info.subst` + defCanType
                                    -- so the varEnv and unifyExtend both see the refined type.
                                    let
                                        instancesList =
                                            Mono.specMapValues topEntry.instances

                                        ( instanceDefs, stateWithDefs ) =
                                            List.foldl
                                                (\info ( defsAcc, stAcc ) ->
                                                    let
                                                        ( instanceDefMonoType0, stAcc1 ) =
                                                            applySubstFVWithEnv stateAfterBody.ctx.mvarEnv stAcc info.subst defCanType

                                                        -- J5: unify from the accumulator's env and thread it forward.
                                                        ( mergedSubst, mergedEnv ) =
                                                            TypeSubst.unifyExtend
                                                                stAcc1.ctx.mvarEnv
                                                                defCanType
                                                                instanceDefMonoType0
                                                                info.subst

                                                        ( monoDef0, st1 ) =
                                                            specializeDef def mergedSubst (setMVarEnv mergedEnv stAcc1)

                                                        monoDef =
                                                            renameMonoDef info.freshName monoDef0
                                                    in
                                                    ( monoDef :: defsAcc, st1 )
                                                )
                                                ( []
                                                , { stateAfterBody
                                                    | ctx =
                                                        let
                                                            cvmi =
                                                                stateAfterBody.ctx
                                                        in
                                                        { cvmi | valueMulti = restOfStack }
                                                  }
                                                )
                                                instancesList

                                        stateWithVars =
                                            List.foldl
                                                (\info st ->
                                                    let
                                                        ( instanceDefMonoType0, st1 ) =
                                                            applySubstFVWithEnv stateAfterBody.ctx.mvarEnv st info.subst defCanType
                                                    in
                                                    { st1
                                                        | ctx =
                                                            let
                                                                cvmv =
                                                                    st1.ctx
                                                            in
                                                            { cvmv
                                                                | varEnv =
                                                                    State.insertVar info.freshName instanceDefMonoType0 cvmv.varEnv
                                                            }
                                                    }
                                                )
                                                stateWithDefs
                                                instancesList

                                        finalExpr =
                                            List.foldl
                                                (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                                                monoBody
                                                instanceDefs
                                    in
                                    ( finalExpr, stateWithVars )

                            [] ->
                                -- Stack underflow: should not happen.
                                Utils.Crash.crash "Specialize: valueMulti stack underflow in Let"

                    else if hasUnresolvedNumberVar stateL.ctx.mvarEnv defCanType && isNumericFixableShape (Tuple.first (applySubstFV stateL subst defCanType)) then
                        -- D7 uniform number-let gate (MONO_028). The former gate had a
                        -- third, provenance/prediction conjunct —
                        --   (isNumericDataRhs || (isScalarNumberShape && demandedNumericUseType /= Nothing))
                        -- — that decided, from RHS provenance and a demand-replay Float
                        -- prediction, whether deferral was WORTH THE RISK given that NOT
                        -- deferring meant a possibly-wrong eager Int commit. Under
                        -- quiescence-before-defaulting the eager seed emits OPEN types
                        -- (closed to Int only at the end, never Int-committed), so every
                        -- number-fixable binding can be admitted unconditionally and the
                        -- use-site machinery (resolveNumberMultiVarRef) detects any Float
                        -- use — no up-front prediction needed. The two remaining conjuncts
                        -- are STRUCTURAL guards, not predictions, and are kept:
                        -- `hasUnresolvedNumberVar` restricts to number-carrying bindings,
                        -- and `isNumericFixableShape` excludes shapes the seed-and-emit
                        -- machinery cannot re-type (e.g. a record with a boxed `List a`
                        -- field — RecordNarrow08 — which must NOT enter this branch).
                        --
                        -- Number-carrying non-function let. We cannot simply DEFER the
                        -- whole binding (as the value-multi path does): re-specializing
                        -- the RHS after the body scrambles the instance recording of any
                        -- `localMulti` function it calls. Instead: specialize the def
                        -- EAGERLY (preserving that order), seed the value-multi stack with
                        -- this eager (open, closes-to-Int) instance, then specialize the
                        -- body. Float-demanding uses record additional instances (extra
                        -- specialized copies of the RHS); Int/boxed uses resolve to the
                        -- eager instance via varEnv.
                        -- rhsUsesLocalMulti bailout retired (J5 deletion loop proved it
                        -- inert): the eager-seed number-multi path below handles all cases,
                        -- including when the RHS itself drives localMulti specialization.
                        let
                            -- The Intern table is threaded through first, then into
                            -- specializeDef. `applySubstFV` is the identity on stateL
                            -- apart from `accum.intern`, so this reorder is behaviour-
                            -- preserving; `stateI.ctx.mvarEnv == stateL.ctx.mvarEnv`.
                            ( eagerMonoType0, stateI ) =
                                applySubstFV stateL subst defCanType

                            ( eagerDef, stateEager ) =
                                specializeDef def subst stateI

                            eagerExprMonoType =
                                monoDefExprType eagerDef

                            eagerMonoType =
                                if Mono.containsAnyMVar eagerMonoType0 || recordWidened eagerMonoType0 eagerExprMonoType then
                                    eagerExprMonoType

                                else
                                    eagerMonoType0

                            intKey =
                                TypeSubst.refreshConstraints stateL.ctx.mvarEnv eagerMonoType

                            seededEntry =
                                { defName = defName
                                , defCanType = defCanType
                                , def = def
                                , instances =
                                    Mono.specMapSingleton intKey
                                        { freshName = defName
                                        , monoType = eagerMonoType
                                        , subst = subst
                                        , derivedDestructorNames = Set.empty
                                        }
                                }

                            stateForBody =
                                { stateEager
                                    | ctx =
                                        let
                                            cn =
                                                stateEager.ctx
                                        in
                                        { cn
                                            | valueMulti = seededEntry :: cn.valueMulti
                                            , varEnv = State.insertVar defName eagerMonoType cn.varEnv
                                        }
                                }

                            ( monoBody, stateAfterBody ) =
                                specializeExpr body subst stateForBody
                        in
                        case stateAfterBody.ctx.valueMulti of
                            topEntry :: restOfStack ->
                                let
                                    -- All instances except the seeded eager (Int) one are
                                    -- Float-demanding copies discovered in the body.
                                    floatInstances =
                                        Mono.specMapValues (Mono.specMapRemove intKey topEntry.instances)

                                    stateRest =
                                        { stateAfterBody
                                            | ctx =
                                                let
                                                    cr =
                                                        stateAfterBody.ctx
                                                in
                                                { cr | valueMulti = restOfStack }
                                        }

                                    ( floatDefs, stateWithDefs ) =
                                        List.foldl
                                            (\info ( defsAcc, stAcc ) ->
                                                let
                                                    -- Step A: re-derive the instance type from the
                                                    -- (possibly refined) info.subst, mirroring the
                                                    -- value-multi path (D6). Destructor- and use-site
                                                    -- refinements threaded into info.subst then flow
                                                    -- into emission, instead of the static
                                                    -- info.monoType recorded at instance creation.
                                                    ( instanceDefMonoType0, stAcc1 ) =
                                                        applySubstFVWithEnv stateAfterBody.ctx.mvarEnv stAcc info.subst defCanType

                                                    -- J5: unify from the accumulator's env and thread it forward.
                                                    ( mergedSubst, mergedEnv ) =
                                                        TypeSubst.unifyExtend stAcc1.ctx.mvarEnv defCanType instanceDefMonoType0 info.subst

                                                    ( md0, st1 ) =
                                                        specializeDef def mergedSubst (setMVarEnv mergedEnv stAcc1)

                                                    md =
                                                        renameMonoDef info.freshName md0
                                                in
                                                ( md :: defsAcc, st1 )
                                            )
                                            ( [], stateRest )
                                            floatInstances

                                    stateWithVars =
                                        List.foldl
                                            (\info st ->
                                                let
                                                    ( instanceDefMonoType0, st1 ) =
                                                        applySubstFVWithEnv stateAfterBody.ctx.mvarEnv st info.subst defCanType
                                                in
                                                { st1
                                                    | ctx =
                                                        let
                                                            cv =
                                                                st1.ctx
                                                        in
                                                        { cv | varEnv = State.insertVar info.freshName instanceDefMonoType0 cv.varEnv }
                                                }
                                            )
                                            stateWithDefs
                                            floatInstances

                                    bodyWithFloats =
                                        List.foldl
                                            (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc))
                                            monoBody
                                            floatDefs
                                in
                                ( Mono.MonoLet eagerDef
                                    bodyWithFloats
                                    (if Mono.containsAnyMVar monoType0 then
                                        Mono.typeOf bodyWithFloats

                                     else
                                        monoType0
                                    )
                                , stateWithVars
                                )

                            [] ->
                                Utils.Crash.crash "Specialize: number-multi stack underflow in Let"

                    else
                        -- Non-function let: original eager behavior
                        let
                            ( monoDef, state1 ) =
                                specializeDef def subst stateL
                        in
                        -- probeBody Nothing: the plain-let path has no multi-stack probe, so
                        -- finishEagerLet specializes the body once under the enriched subst.
                        finishEagerLet stateL body Nothing defName defCanType monoType0 subst monoDef state1

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor dname destructorPath destructorMeta) =
                    destructor
            in
            case getValueMultiRootFromPath destructorPath state of
                Just ( rootName, rootCanType ) ->
                    -- Body-first divert (MONO_028) applies ONLY to a SCALAR-number
                    -- destructor slot projected from a number-multi ROOT whose path
                    -- buildPartialContainer can refine. Checks are ordered
                    -- cheap→expensive and gated lazily: `isNumberMultiTarget` is a
                    -- cheap stack scan; only inside it do we pay the O(type)
                    -- `applySubstFV` (eagerLeaf), and only when the slot is a scalar
                    -- number do we run the `buildPartialContainer` probe. The common
                    -- (non-number-root) Destruct computes none of this. A
                    -- tuple/record/nested slot is not a scalar number and stays on the
                    -- general path; list-index (`ArrayIndex`) paths are rejected by the
                    -- probe (Nothing) — diverting them would drop the destructor and
                    -- leave the bound var unbound (`lookupVar: unbound`).
                    if isNumberMultiTarget rootName state then
                        let
                            ( eagerLeaf, stateI ) =
                                applySubstFV state subst destructorMeta.tipe

                            fieldIsScalarNumber =
                                case eagerLeaf of
                                    Mono.MInt ->
                                        True

                                    Mono.MFloat ->
                                        True

                                    Mono.MVar _ Mono.CNumber ->
                                        True

                                    _ ->
                                        False
                        in
                        if
                            fieldIsScalarNumber
                                && (case buildPartialContainer rootCanType destructorPath eagerLeaf stateI of
                                        Just _ ->
                                            True

                                        Nothing ->
                                            False
                                   )
                        then
                            specializeNumberDestruct dname destructorPath destructorMeta rootName rootCanType body subst stateI

                        else
                            specializeGeneralDestruct destructor body meta subst stateI

                    else
                        specializeGeneralDestruct destructor body meta subst state

                Nothing ->
                    specializeGeneralDestruct destructor body meta subst state

        TOpt.Case label root decider jumps meta ->
            -- ABI normalization for case expressions has been moved to MonoGlobalOptimize.
            -- Here we simply specialize the branches and use the type from the substitution.
            let
                canType =
                    meta.tipe

                ( monoTypeFromCan, stateI ) =
                    applySubstFV state subst canType

                savedVarEnv =
                    stateI.ctx.varEnv

                ( monoDecider0, state1 ) =
                    specializeDecider monoTypeFromCan root decider subst stateI

                state1WithResetVarEnv =
                    { state1
                        | ctx =
                            let
                                cc =
                                    state1.ctx
                            in
                            { cc | varEnv = savedVarEnv }
                    }

                ( monoJumps0, state2 ) =
                    specializeJumps monoTypeFromCan jumps subst state1WithResetVarEnv
            in
            ( Mono.MonoCase label
                root
                monoDecider0
                monoJumps0
                (if Mono.containsAnyMVar monoTypeFromCan then
                    -- Infer from first jump or decider leaf
                    inferCaseType monoDecider0 monoJumps0 monoTypeFromCan

                 else
                    monoTypeFromCan
                )
            , state2
            )

        TOpt.Accessor region fieldName meta ->
            -- Standalone accessor expression (not passed as argument to a call).
            -- If the MonoType still has MVars (incomplete record layout from unresolved
            -- row variables), defer to ResolveAccessorValues pass via MonoAccessorValue.
            -- Otherwise, create the virtual global immediately.
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType
            in
            if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                ( Mono.MonoAccessorValue region fieldName monoType, stateI )

            else
                let
                    accessorGlobal =
                        Mono.Accessor fieldName

                    ( specId, newState ) =
                        enqueueSpec accessorGlobal monoType stateI
                in
                ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.Access record _ fieldName meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateA ) =
                    applySubstFV state subst canType
            in
            case getValueMultiVar record stateA of
                Just ( varName, recordCanType ) ->
                    if isNumberMultiTarget varName stateA then
                        -- Number-multi target: record an instance against the binding's
                        -- own defCanType using this field's resolved type as the demanded
                        -- shape (`{ field : fieldMonoType }`).
                        case recordNumberInstanceAgainstShape varName (Mono.mRecord (Dict.singleton fieldName monoType)) subst stateA of
                            Just ( freshName, instMonoType, state1 ) ->
                                ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName instMonoType) fieldName monoType, state1 )

                            Nothing ->
                                ( Mono.MonoRecordAccess (Mono.MonoVarLocal varName monoType) fieldName monoType, stateA )

                    else
                        -- Value-multi target: derive the concrete record type from the
                        -- access field type. The field's monoType is concrete (type inference
                        -- resolved it), but the record's canonical type has free type vars.
                        -- Unify to learn the concrete bindings.
                        let
                            partialRecordMono =
                                Mono.mRecord (Dict.singleton fieldName monoType)

                            -- J5: keep the unify env and thread it via stateE.
                            ( enrichedSubst, enrichedEnv ) =
                                TypeSubst.unifyExtend stateA.ctx.mvarEnv recordCanType partialRecordMono subst

                            stateE0 =
                                setMVarEnv enrichedEnv stateA

                            ( recordMonoType, stateE ) =
                                applySubstFV stateE0 enrichedSubst recordCanType

                            ( freshName, state1 ) =
                                getOrCreateValueInstance varName recordMonoType enrichedSubst stateE
                        in
                        ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName recordMonoType) fieldName monoType, state1 )

                Nothing ->
                    let
                        ( monoRecord, stateAfter ) =
                            specializeExpr record subst stateA

                        -- If the specialized record's mono type carries a more concrete
                        -- type for this field than what applySubst produced from the
                        -- field's canonical type, prefer it. This handles nested
                        -- row-polymorphic records where the field's canonical type
                        -- references a row-extension MVar that is not in `subst` —
                        -- in that case applySubst yields a narrow MRecord (or an
                        -- MVar/MCustom-with-MVar-args) even though the actual heap
                        -- value carries the full record. The record's own mono type
                        -- has the authoritative concrete field type. (Companion fix
                        -- to `recordWidened`-based let-binding fix in this module.)
                        refinedMonoType =
                            case Mono.typeOf monoRecord of
                                Mono.MRecord _ fields ->
                                    case Dict.get fieldName fields of
                                        Just fieldMono ->
                                            if isMoreConcrete monoType fieldMono then
                                                fieldMono

                                            else
                                                monoType

                                        Nothing ->
                                            monoType

                                _ ->
                                    monoType
                    in
                    ( Mono.MonoRecordAccess monoRecord fieldName refinedMonoType, stateAfter )

        TOpt.Update _ record updates meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType

                ( monoRecord, state1 ) =
                    specializeExpr record subst stateI

                -- Use the already-specialized record's MonoType for field type lookup.
                -- This is more concrete than re-applying subst to the canonical type,
                -- because monoRecord already encodes constraints from its own specialization.
                recordMonoType =
                    Mono.typeOf monoRecord

                getFieldMonoType fieldName =
                    case recordMonoType of
                        Mono.MRecord _ fieldMap ->
                            Dict.get fieldName fieldMap

                        _ ->
                            Nothing

                ( monoUpdates, state2 ) =
                    Data.Map.foldl A.compareLocated
                        (\locName updateExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                -- J5: unify from the fold state's env and thread it forward.
                                ( refinedSubst, refinedEnv ) =
                                    case getFieldMonoType fieldName of
                                        Just fieldMonoType ->
                                            TypeSubst.unifyExtend st.ctx.mvarEnv (TOpt.typeOf updateExpr) fieldMonoType subst

                                        Nothing ->
                                            ( subst, st.ctx.mvarEnv )

                                ( monoExpr, newSt ) =
                                    specializeExpr updateExpr refinedSubst (setMVarEnv refinedEnv st)
                            in
                            ( ( fieldName, monoExpr ) :: acc, newSt )
                        )
                        ( [], state1 )
                        updates

                resultMonoType =
                    case ( recordMonoType, monoType ) of
                        ( Mono.MRecord _ recordFields, Mono.MRecord _ resultFields ) ->
                            Mono.mRecord (Dict.union resultFields recordFields)

                        ( Mono.MRecord _ _, _ ) ->
                            Utils.Crash.crash "Specialize.TOpt.Update: record with non-record result type"

                        _ ->
                            Utils.Crash.crash "Specialize.TOpt.Update: input expression is not a record"
            in
            ( Mono.MonoRecordUpdate monoRecord monoUpdates resultMonoType, state2 )

        TOpt.Record fields meta ->
            let
                canType =
                    meta.tipe

                -- Refinement hint only — may contain MVar _ CEcoValue for any
                -- field whose upstream constraint flow gapped. Used solely to
                -- guide per-field substitution refinement; NOT used as the
                -- record's final MonoType (see Fix A below).
                ( refinementMonoType, stateI ) =
                    applySubstFV state subst canType

                monoFieldTypes =
                    case refinementMonoType of
                        Mono.MRecord _ fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Dict.foldl
                        (specializeRecordField subst monoFieldTypes)
                        ( [], stateI )
                        fields
            in
            ( Mono.MonoRecordCreate monoFields (recordMonoTypeFromFields monoFields), stateAfter )

        TOpt.TrackedRecord _ fields meta ->
            let
                canType =
                    meta.tipe

                -- Refinement hint only — see Fix A note on TOpt.Record above.
                ( refinementMonoType, stateI ) =
                    applySubstFV state subst canType

                monoFieldTypes =
                    case refinementMonoType of
                        Mono.MRecord _ fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Data.Map.foldl A.compareLocated
                        (\locName fieldExpr accSt ->
                            specializeRecordField subst monoFieldTypes (A.toValue locName) fieldExpr accSt
                        )
                        ( [], stateI )
                        fields
            in
            ( Mono.MonoRecordCreate monoFields (recordMonoTypeFromFields monoFields), stateAfter )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        TOpt.Tuple region a b rest _ ->
            let
                ( monoA, state1 ) =
                    specializeExpr a subst state

                ( monoB, state2 ) =
                    specializeExpr b subst state1

                ( monoRest, state3 ) =
                    specializeExprs rest subst state2

                allExprs =
                    monoA :: monoB :: monoRest

                -- Fix A (wrong-unboxed-bitmap-upstream): build the tuple's
                -- MonoType from the already-specialised element expressions
                -- rather than from meta.tipe. This guarantees the container's
                -- declared element types match the actual SSA slot types,
                -- even when an upstream constraint-flow gap leaves a slot's
                -- canonical TVar unbound (which would otherwise fall through
                -- applySubst's Nothing/CEcoValue branch and produce a buggy
                -- MVar _ CEcoValue in the MonoType).
                monoType =
                    Mono.mTuple (List.map Mono.typeOf allExprs)
            in
            ( Mono.MonoTupleCreate region allExprs monoType, state3 )

        TOpt.Shader _ _ _ _ ->
            ( Mono.MonoUnit, state )


{-| Infer the result type of a case expression from its branches.
When the canonical type has unresolved TVars, we look at the first
concrete branch type instead.
-}
inferCaseType : Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> Mono.MonoType
inferCaseType decider jumps fallback =
    -- Try to extract type from first jump
    case jumps of
        ( _, expr ) :: _ ->
            Mono.typeOf expr

        [] ->
            -- No jumps, try decider leaf
            inferFromDecider decider fallback


inferFromDecider : Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferFromDecider decider fallback =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Mono.typeOf expr

        Mono.Leaf (Mono.Jump _) ->
            fallback

        Mono.Chain _ yes _ ->
            inferFromDecider yes fallback

        Mono.FanOut _ branches def ->
            case branches of
                ( _, d ) :: _ ->
                    inferFromDecider d fallback

                [] ->
                    inferFromDecider def fallback



-- ========== EXPRESSION LIST HELPERS ==========


{-| Specialize a list of expressions.
Uses foldl + reverse instead of foldr for stack safety (foldl is tail-call optimized).
-}
specializeExprs : List (TOpt.Expr MVarId) -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeExprs exprs subst state =
    let
        ( revAcc, finalState ) =
            List.foldl
                (\e ( acc, st ) ->
                    let
                        ( me, st1 ) =
                            specializeExpr e subst st
                    in
                    ( me :: acc, st1 )
                )
                ( [], state )
                exprs
    in
    ( List.reverse revAcc, finalState )


{-| Refine a substitution using the canonical types of call-site arguments.

For each arg expression, unify its canonical type (TOpt.typeOf) with its
computed MonoType via unifyExtend. This pushes container element bindings
(e.g. a = MInt from List Int) back into the substitution, even when the
callee's callback types are too generic to provide them.

-}
refineSubstFromArgExprs :
    MVarEnv
    -> List (TOpt.Expr MVarId)
    -> List Mono.MonoType
    -> Substitution
    -> ( Substitution, MVarEnv )
refineSubstFromArgExprs mvarEnv args argTypes subst =
    List.foldl
        (\( expr, argMono ) ( s, env ) ->
            TypeSubst.unifyExtend env (TOpt.typeOf expr) argMono s
        )
        ( subst, mvarEnv )
        (List.map2 Tuple.pair args argTypes)


{-| Process call arguments, deferring accessor specialization.

Returns:

  - processed args (some are PendingAccessor),
  - the monomorphic arg types for call-site unification,
  - updated MonoState.

-}
processCallArgs :
    List (TOpt.Expr MVarId)
    -> Substitution
    -> MonoState
    -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArgs args subst state =
    let
        ( revArgs, revTypes, finalState ) =
            List.foldl (processCallArg subst) ( [], [], state ) args
    in
    ( List.reverse revArgs, List.reverse revTypes, finalState )


processCallArg : Substitution -> TOpt.Expr MVarId -> ( List ProcessedArg, List Mono.MonoType, MonoState ) -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArg subst arg ( accArgs, accTypes, st ) =
    case arg of
        TOpt.Accessor region fieldName accessorMeta ->
            let
                accessorCanType =
                    accessorMeta.tipe

                monoType =
                    TypeSubst.applySubstPure st.ctx.mvarEnv subst accessorCanType
            in
            ( PendingAccessor region fieldName accessorCanType :: accArgs
            , monoType :: accTypes
            , st
            )

        TOpt.VarKernel _ _ _ _ _ ->
            let
                ( monoExpr, st1 ) =
                    specializeExpr arg subst st
            in
            ( ResolvedArg monoExpr :: accArgs
            , Mono.typeOf monoExpr :: accTypes
            , st1
            )

        TOpt.VarLocal name localMeta ->
            let
                localCanType =
                    localMeta.tipe
            in
            if isLocalMultiTarget name st then
                let
                    ( monoType, st1 ) =
                        applySubstFV st subst localCanType
                in
                ( LocalFunArg name localCanType :: accArgs
                , monoType :: accTypes
                , st1
                )

            else if isNumberMultiTarget name st then
                -- Deferred number binding used as a call argument. Keep its type as
                -- an unresolved CNumber var so a numeric operator resolves it via the
                -- concrete sibling arg / expected result; the Float instance is then
                -- recorded against the callee's paramType in resolveProcessedArg.
                ( PendingNumberValue name localCanType :: accArgs
                , TypeSubst.applySubstPure st.ctx.mvarEnv subst localCanType :: accTypes
                , st
                )

            else
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst st
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )

        TOpt.TrackedVarLocal _ name trackedLocalMeta ->
            -- Tracking region is unused here; delegate to the untracked arm. (The
            -- else-branch's `specializeExpr` on the untracked VarLocal is equivalent —
            -- specializeExpr's TrackedVarLocal arm itself delegates to VarLocal.)
            processCallArg subst (TOpt.VarLocal name trackedLocalMeta) ( accArgs, accTypes, st )

        TOpt.Call _ _ _ meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stI ) =
                    applySubstFV st subst canType
            in
            if Mono.containsAnyMVar monoType then
                -- Inner call result is still polymorphic (a CEcoValue var, or —
                -- since applySubst no longer eagerly defaults — an open number
                -- residual). Defer specialization until we know the outer callee's
                -- expected parameter type, which may bind the number to Float.
                ( PendingExpr arg subst canType :: accArgs
                , monoType :: accTypes
                , stI
                )

            else
                -- Fully monomorphic result — specialize immediately.
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst stI
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )

        _ ->
            case arg of
                TOpt.VarGlobal _ _ meta ->
                    let
                        canType =
                            meta.tipe

                        -- Preserve unresolved CNumber as MVar so that later call-site
                        -- unification (unifyCallSiteDirect) can transitively bind
                        -- `number = Float` via concrete-typed sibling args (e.g.
                        -- `Array Float` for `Array.foldl (+) 0.0 arr`). applySubst now
                        -- preserves CNumber by construction (quiescence-before-
                        -- defaulting, MONO_028), so the former applySubstKeepNumber
                        -- fork is redundant.
                        monoType =
                            TypeSubst.applySubstPure st.ctx.mvarEnv subst canType
                    in
                    if Mono.containsAnyMVar monoType then
                        ( PendingExpr arg subst canType :: accArgs
                        , monoType :: accTypes
                        , st
                        )

                    else
                        let
                            ( monoExpr, st1 ) =
                                specializeExpr arg subst st
                        in
                        ( ResolvedArg monoExpr :: accArgs
                        , Mono.typeOf monoExpr :: accTypes
                        , st1
                        )

                _ ->
                    let
                        ( monoExpr, st1 ) =
                            specializeExpr arg subst st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes
                    , st1
                    )


{-| Resolve a single processed argument.

For PendingAccessor, derives the accessor's MonoType from the expected
parameter type (which must be a record), NOT from the accessor's canonical type.

-}
resolveProcessedArg :
    ProcessedArg
    -> Maybe Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
resolveProcessedArg processedArg maybeParamType subst state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

        PendingAccessor region fieldName _ ->
            case maybeParamType of
                Just (Mono.MFunction _ _ [ Mono.MRecord _ fields ] _) ->
                    -- The parameter type is a function from record to something.
                    -- Derive accessor's MonoType from the full record layout.
                    let
                        fieldType =
                            case Dict.get fieldName fields of
                                Just ft ->
                                    ft

                                Nothing ->
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record. This is a compiler bug.")

                        recordType =
                            Mono.mRecord fields

                        accessorMonoType =
                            Mono.mFunction Mono.LTop [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                Just (Mono.MRecord _ fields) ->
                    -- The parameter type is directly a record (accessor applied to record).
                    -- This case handles when the accessor IS the function being called.
                    let
                        fieldType =
                            case Dict.get fieldName fields of
                                Just ft ->
                                    ft

                                Nothing ->
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record (direct). This is a compiler bug.")

                        recordType =
                            Mono.mRecord fields

                        accessorMonoType =
                            Mono.mFunction Mono.LTop [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash "Specialize.resolveProcessedArg: Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."

        PendingExpr savedExpr savedSubst canType ->
            -- Deferred polymorphic argument — a VarGlobal or a nested Call that
            -- needed the callee's parameter type. Refine the substitution with that
            -- paramType, then specialize.
            let
                -- J5: keep the refine env (Join-R taints) and thread it into specialize.
                ( refinedSubst, refinedEnv ) =
                    case maybeParamType of
                        Just paramType ->
                            TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType savedSubst

                        Nothing ->
                            ( savedSubst, state.ctx.mvarEnv )
            in
            specializeExpr savedExpr refinedSubst (setMVarEnv refinedEnv state)

        LocalFunArg name canType ->
            -- Let-bound function passed as argument. Use the callee's parameter type
            -- to refine the local's type and create a monomorphic instance.
            case maybeParamType of
                Just paramType ->
                    case paramType of
                        Mono.MFunction _ _ _ _ ->
                            let
                                -- J5: keep the refine env and thread it via stateU.
                                ( refinedSubst, refinedEnv ) =
                                    TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType subst

                                stateU0 =
                                    setMVarEnv refinedEnv state

                                ( funcMonoType, stateU ) =
                                    applySubstFV stateU0 refinedSubst canType
                            in
                            if isLocalMultiTarget name stateU then
                                let
                                    ( freshName, state1 ) =
                                        getOrCreateLocalInstance
                                            name
                                            funcMonoType
                                            refinedSubst
                                            stateU
                                in
                                ( Mono.MonoVarLocal freshName funcMonoType, state1 )

                            else
                                ( Mono.MonoVarLocal name funcMonoType, stateU )

                        _ ->
                            let
                                ( monoType, state1 ) =
                                    applySubstFV state subst canType
                            in
                            ( Mono.MonoVarLocal name monoType, state1 )

                Nothing ->
                    let
                        ( monoType, state1 ) =
                            applySubstFV state subst canType
                    in
                    ( Mono.MonoVarLocal name monoType, state1 )

        PendingNumberValue name canType ->
            -- Deferred number binding passed as an argument. The callee's resolved
            -- paramType is the consumer's demand (e.g. MFloat for `1.4 * n`, or
            -- MTuple [MFloat, MInt] for `Tuple.first p`). Record an instance keyed
            -- on that shape; the binding emits one specialized def per instance.
            case maybeParamType of
                Just paramType ->
                    case recordNumberInstanceAgainstShape name paramType subst state of
                        Just ( freshName, instMonoType, state1 ) ->
                            ( Mono.MonoVarLocal freshName instMonoType, state1 )

                        Nothing ->
                            let
                                ( monoType, state1 ) =
                                    applySubstFV state subst canType
                            in
                            ( Mono.MonoVarLocal name monoType, state1 )

                Nothing ->
                    let
                        ( monoType, state1 ) =
                            applySubstFV state subst canType
                    in
                    ( Mono.MonoVarLocal name monoType, state1 )


{-| Resolve a list of processed arguments using the callee's parameter types.
-}
resolveProcessedArgs :
    List ProcessedArg
    -> List Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( List Mono.MonoExpr, MonoState )
resolveProcessedArgs processedArgs paramTypes subst state =
    let
        step processedArg ( acc, st, remainingParams ) =
            let
                ( maybeParam, rest ) =
                    case remainingParams of
                        p :: ps ->
                            ( Just p, ps )

                        [] ->
                            ( Nothing, [] )

                ( monoExpr, st1 ) =
                    resolveProcessedArg processedArg maybeParam subst st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )


{-| Specialize a list of named expressions.
-}
specializeNamedExprs :
    List ( Name, TOpt.Expr MVarId )
    -> Substitution
    -> MonoState
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeNamedExprs namedExprs subst state =
    let
        ( revAcc, finalState ) =
            List.foldl
                (\( name, e ) ( acc, st ) ->
                    let
                        ( me, st1 ) =
                            specializeExpr e subst st
                    in
                    ( ( name, me ) :: acc, st1 )
                )
                ( [], state )
                namedExprs
    in
    ( List.reverse revAcc, finalState )


{-| If `expectedMono` is a concrete (MVar-free) type, push it onto `bodyCanType`
by unification, so an `if`/`case` branch (or other operand) whose own node type is
a generalized `number` is specialized at the demanded type (e.g. `Float`) instead
of defaulting to `Int`. The resolved branch-result type is the consumer demand on
each branch, but the branch's own reference node (a let-generalized `number`) may
still say `number` — this threads the result type onto it. (When the expected type
is still polymorphic we leave the branch untouched and infer post hoc, as before.)
-}
pushExpectedType : MVarEnv -> Mono.MonoType -> Can.Type MVarId -> Substitution -> ( Substitution, MVarEnv )
pushExpectedType mvarEnv expectedMono bodyCanType subst =
    if Mono.containsAnyMVar expectedMono then
        ( subst, mvarEnv )

    else
        TypeSubst.unifyExtend mvarEnv bodyCanType expectedMono subst


{-| Specialize if-expression branches (condition-body pairs).
-}
specializeBranches :
    Mono.MonoType
    -> List ( TOpt.Expr MVarId, TOpt.Expr MVarId )
    -> Substitution
    -> MonoState
    -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )
specializeBranches expectedMono branches subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( cond, body ) ( acc, st ) ->
                    let
                        ( mCond, st1 ) =
                            specializeExpr cond subst st

                        st1WithResetVarTypes =
                            { st1
                                | ctx =
                                    let
                                        c =
                                            st1.ctx
                                    in
                                    { c | varEnv = savedVarEnv }
                            }

                        ( mBody, st2 ) =
                            -- J5: thread the pushed-type unify env into the branch specialization.
                            let
                                ( pushedSubst, pushedEnv ) =
                                    pushExpectedType st1.ctx.mvarEnv expectedMono (TOpt.typeOf body) subst
                            in
                            specializeExpr body pushedSubst (setMVarEnv pushedEnv st1WithResetVarTypes)
                    in
                    ( ( mCond, mBody ) :: acc, st2 )
                )
                ( [], state )
                branches
    in
    ( List.reverse revAcc, finalState )



-- ========== CONSTRUCTOR HELPERS ==========


{-| Extract the result type of a constructor after peeling off function arguments.
-}
extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ args result ->
                extractCtorResultType (n - List.length args) result

            _ ->
                monoType



-- ========== CYCLE SPECIALIZATION HELPERS ==========


{-| Check if a definition has the given name.
-}
defHasName : Name -> TOpt.Def MVarId -> Bool
defHasName targetName def =
    case def of
        TOpt.Def _ name _ _ ->
            name == targetName

        TOpt.TailDef _ name _ _ _ _ ->
            name == targetName


{-| Get the name from a definition.
-}
getDefName : TOpt.Def MVarId -> Name
getDefName def =
    case def of
        TOpt.Def _ name _ _ ->
            name

        TOpt.TailDef _ name _ _ _ _ ->
            name


{-| Get the canonical type from a definition.
-}
getDefCanonicalType : TOpt.Def MVarId -> Can.Type MVarId
getDefCanonicalType def =
    case def of
        TOpt.Def _ _ _ canType ->
            canType

        TOpt.TailDef _ _ args _ returnType _ ->
            buildFuncType args returnType



-- ========== DEFINITION SPECIALIZATION HELPERS ==========


{-| Specialize a local definition.
-}
specializeDef : TOpt.Def MVarId -> Substitution -> MonoState -> ( Mono.MonoDef, MonoState )
specializeDef def subst state =
    case def of
        TOpt.Def _ name expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDef name monoExpr, stateAfter )

        TOpt.TailDef _ name args expr _ _ ->
            let
                monoArgs =
                    List.map (specializeArg state.ctx.mvarEnv subst) args

                ctx =
                    state.ctx

                newVarEnv =
                    List.foldl
                        (\( pname, monoParamType ) ve ->
                            State.insertVar pname monoParamType ve
                        )
                        (State.pushFrame ctx.varEnv)
                        monoArgs

                stateWithParams =
                    { state | ctx = { ctx | varEnv = newVarEnv, mvarEnv = augmentedEnv } }

                -- J5: fold both the subst AND the env so per-param taints survive.
                ( augmentedSubstRaw, augmentedEnv ) =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) ( s, e ) ->
                            TypeSubst.unifyExtend e canParamType monoParamType s
                        )
                        ( subst, state.ctx.mvarEnv )
                        (List.map2 Tuple.pair args monoArgs)

                ( monoExpr, stateAfterPre ) =
                    specializeExpr expr augmentedSubstRaw stateWithParams

                stateAfter =
                    { stateAfterPre
                        | ctx =
                            let
                                c =
                                    stateAfterPre.ctx
                            in
                            { c | varEnv = State.popFrame c.varEnv }
                    }
            in
            ( Mono.MonoTailDef name monoArgs monoExpr, stateAfter )


specializeDestructor : TOpt.Destructor MVarId -> Substitution -> MVarEnv -> VarEnv -> TypeEnv.GlobalTypeEnv -> Maybe Mono.Global -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path meta) subst mvarEnv varEnv globalTypeEnv currentGlobal =
    let
        monoPath =
            specializePath mvarEnv path varEnv globalTypeEnv currentGlobal name

        monoType =
            TypeSubst.applySubstPure mvarEnv subst meta.tipe
    in
    Mono.MonoDestructor name monoPath monoType


{-| Specialize a path, computing the result type at each step.

The path is structured from leaf (root variable) outward, so we:

1.  Find the root and look up its type in VarTypes
2.  Walk back out through the path, computing types at each step

-}
specializePath : MVarEnv -> TOpt.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Maybe Mono.Global -> Name -> Mono.MonoPath
specializePath mvarEnv path varEnv globalTypeEnv currentGlobal destructorName =
    case path of
        TOpt.Index index hint subPath ->
            let
                monoSubPath =
                    specializePath mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeIndexProjectionType mvarEnv globalTypeEnv hint (Index.toMachine index) containerType
            in
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

        TOpt.ArrayIndex idx subPath ->
            let
                monoSubPath =
                    specializePath mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                -- ArrayIndex is used for array access, element type comes from the array's element type
                resultType =
                    computeArrayElementType containerType
            in
            Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath

        TOpt.Field fieldName subPath ->
            let
                monoSubPath =
                    specializePath mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                recordType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    case recordType of
                        Mono.MRecord _ fields ->
                            case Dict.get fieldName fields of
                                Just fieldMonoType ->
                                    fieldMonoType

                                Nothing ->
                                    Utils.Crash.crash
                                        ("Specialize.specializePath: Field '"
                                            ++ fieldName
                                            ++ "' not found in record type. This is a compiler bug."
                                        )

                        _ ->
                            Utils.Crash.crash
                                ("Specialize.specializePath: Expected Mono.mRecord for field path but got: "
                                    ++ Mono.monoTypeToDebugString recordType
                                )
            in
            Mono.MonoField fieldName resultType monoSubPath

        TOpt.Unbox subPath ->
            let
                monoSubPath =
                    specializePath mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                -- Compute the result type by looking up the single field type of the container
                resultType =
                    computeUnboxResultType mvarEnv globalTypeEnv containerType
            in
            Mono.MonoUnbox resultType monoSubPath

        TOpt.Root name ->
            let
                rootType =
                    case State.lookupVar name varEnv of
                        Just ty ->
                            ty

                        Nothing ->
                            Utils.Crash.crash ("Specialize.specializePath: Root variable '" ++ name ++ "' not found in VarEnv. Destructor: '" ++ destructorName ++ "'. VarEnv keys: [" ++ String.join ", " (State.varEnvKeys varEnv) ++ "]. Global: " ++ debugGlobal currentGlobal)
            in
            Mono.MonoRoot name rootType


debugGlobal : Maybe Mono.Global -> String
debugGlobal mg =
    case mg of
        Nothing ->
            "Nothing"

        Just (Mono.Global (IO.Canonical _ modName) name) ->
            Name.toElmString modName ++ "." ++ name

        Just (Mono.Accessor name) ->
            "Accessor(" ++ name ++ ")"


{-| Compute the result type of projecting at an index from a container.
-}
computeIndexProjectionType : MVarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.ContainerHint -> Int -> Mono.MonoType -> Mono.MonoType
computeIndexProjectionType mvarEnv globalTypeEnv hint index containerType =
    case hint of
        TOpt.HintList ->
            case containerType of
                Mono.MList _ elemType ->
                    if index == 0 then
                        -- Index 0 is head: returns the element type
                        elemType

                    else
                        -- Index 1 is tail: returns the list type itself
                        containerType

                _ ->
                    Utils.Crash.crash ("Specialize.computeIndexProjectionType: HintList at index " ++ String.fromInt index ++ " - Expected Mono.mList but got: " ++ Mono.monoTypeToDebugString containerType)

        TOpt.HintTuple2 ->
            computeTupleElementType index containerType

        TOpt.HintTuple3 ->
            computeTupleElementType index containerType

        TOpt.HintCustom ctorName ->
            computeCustomFieldType mvarEnv globalTypeEnv ctorName index containerType


{-| Compute element type from a tuple at the given index.
-}
computeTupleElementType : Int -> Mono.MonoType -> Mono.MonoType
computeTupleElementType index containerType =
    case containerType of
        Mono.MTuple _ elementTypes ->
            case List.drop index elementTypes of
                elemType :: _ ->
                    elemType

                [] ->
                    Utils.Crash.crash ("Specialize.computeTupleElementType: Tuple index " ++ String.fromInt index ++ " out of bounds for tuple with " ++ String.fromInt (List.length elementTypes) ++ " elements")

        _ ->
            Utils.Crash.crash ("Specialize.computeTupleElementType: Expected Mono.mTuple but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute field type from a custom type constructor at the given index.

This looks up the union definition to find the constructor's argument types,
then applies the type variable substitution based on the monomorphized type arguments.

-}
computeCustomFieldType : MVarEnv -> TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType
computeCustomFieldType mvarEnv globalTypeEnv ctorName index containerType =
    case containerType of
        Mono.MCustom _ moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case findCtorByName ctorName unionData.alts of
                        Nothing ->
                            Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor '" ++ ctorName ++ "' not found in union " ++ typeName)

                        Just (Can.Ctor ctorData) ->
                            case List.drop index ctorData.args of
                                canArgType :: _ ->
                                    -- Build name-to-MVarId mapping and Int-keyed substitution
                                    let
                                        ( nameToId, mvarEnv1 ) =
                                            List.foldl
                                                (\vn ( acc, e ) ->
                                                    let
                                                        ( mid, e1 ) =
                                                            State.freshMVar Mono.CEcoValue e
                                                    in
                                                    ( Dict.insert vn mid acc, e1 )
                                                )
                                                ( Dict.empty, mvarEnv )
                                                unionData.vars

                                        typeVarSubst =
                                            List.foldl
                                                (\( vn, ta ) s ->
                                                    case Dict.get vn nameToId of
                                                        Just mid ->
                                                            Dict.insert (Id.toComparable mid) ta s

                                                        Nothing ->
                                                            s
                                                )
                                                Dict.empty
                                                (List.map2 Tuple.pair unionData.vars typeArgs)

                                        canArgTypeWithIds =
                                            Analysis.convertCanTypeNameToMVarId nameToId canArgType
                                    in
                                    TypeSubst.applySubstPure mvarEnv1 typeVarSubst canArgTypeWithIds

                                [] ->
                                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor arg index " ++ String.fromInt index ++ " out of bounds for " ++ ctorName)

        _ ->
            Utils.Crash.crash ("Specialize.computeCustomFieldType: Expected Mono.mCustom for ctor '" ++ ctorName ++ "' index " ++ String.fromInt index ++ " but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Find a constructor by name in a list of alternatives.
-}
findCtorByName : Name -> List Can.Ctor -> Maybe Can.Ctor
findCtorByName targetName alts =
    List.filter (\(Can.Ctor ctorData) -> ctorData.name == targetName) alts
        |> List.head


{-| Compute the result type of unwrapping a single-constructor type.

For Unbox paths, we need to find the single field type of the container.
The container must be a single-constructor type (Can.Unbox option).

-}
computeUnboxResultType : MVarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType
computeUnboxResultType mvarEnv globalTypeEnv containerType =
    case containerType of
        Mono.MCustom _ moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    -- Unbox is used for single-constructor types with a single field
                    case unionData.alts of
                        [ Can.Ctor ctorData ] ->
                            case ctorData.args of
                                [ canArgType ] ->
                                    -- Build name-to-MVarId mapping and Int-keyed substitution
                                    let
                                        ( nameToId, mvarEnv1 ) =
                                            List.foldl
                                                (\vn ( acc, e ) ->
                                                    let
                                                        ( mid, e1 ) =
                                                            State.freshMVar Mono.CEcoValue e
                                                    in
                                                    ( Dict.insert vn mid acc, e1 )
                                                )
                                                ( Dict.empty, mvarEnv )
                                                unionData.vars

                                        typeVarSubst =
                                            List.foldl
                                                (\( vn, ta ) s ->
                                                    case Dict.get vn nameToId of
                                                        Just mid ->
                                                            Dict.insert (Id.toComparable mid) ta s

                                                        Nothing ->
                                                            s
                                                )
                                                Dict.empty
                                                (List.map2 Tuple.pair unionData.vars typeArgs)

                                        canArgTypeWithIds =
                                            Analysis.convertCanTypeNameToMVarId nameToId canArgType
                                    in
                                    TypeSubst.applySubstPure mvarEnv1 typeVarSubst canArgTypeWithIds

                                _ ->
                                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-arg constructor but got " ++ String.fromInt (List.length ctorData.args) ++ " args for " ++ typeName)

                        _ ->
                            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-constructor type but got " ++ String.fromInt (List.length unionData.alts) ++ " constructors for " ++ typeName)

        _ ->
            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected Mono.mCustom but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute element type from an array access.
-}
computeArrayElementType : Mono.MonoType -> Mono.MonoType
computeArrayElementType containerType =
    case containerType of
        Mono.MCustom _ _ "Array" [ elemType ] ->
            elemType

        _ ->
            Utils.Crash.crash ("Specialize.computeArrayElementType: Expected Array type but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Convert ContainerHint to ContainerKind for monomorphized paths.
-}
hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom ctorName ->
            Mono.CustomContainer ctorName


{-| Convert a TypedPath.ContainerHint to a ContainerKind for MonoDtPath.
-}
dtHintToKind : TypedPath.ContainerHint -> Mono.ContainerKind
dtHintToKind hint =
    case hint of
        TypedPath.HintList ->
            Mono.ListContainer

        TypedPath.HintTuple2 ->
            Mono.Tuple2Container

        TypedPath.HintTuple3 ->
            Mono.Tuple3Container

        TypedPath.HintCustom ctorName ->
            Mono.CustomContainer ctorName

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


{-| Convert TypedPath.ContainerHint to TOpt.ContainerHint for reuse of computeIndexProjectionType.
-}
dtHintToTOptHint : TypedPath.ContainerHint -> TOpt.ContainerHint
dtHintToTOptHint hint =
    case hint of
        TypedPath.HintList ->
            TOpt.HintList

        TypedPath.HintTuple2 ->
            TOpt.HintTuple2

        TypedPath.HintTuple3 ->
            TOpt.HintTuple3

        TypedPath.HintCustom ctorName ->
            TOpt.HintCustom ctorName

        TypedPath.HintUnknown ->
            TOpt.HintCustom ""


{-| Convert a DT.Path (TypedPath) to a MonoDtPath by resolving types from VarEnv.
-}
specializeDtPath : MVarEnv -> Name -> TypedPath.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoDtPath
specializeDtPath mvarEnv rootName dtPath varEnv globalTypeEnv =
    let
        rootType =
            case State.lookupVar rootName varEnv of
                Just ty ->
                    ty

                Nothing ->
                    Utils.Crash.crash ("Specialize.specializeDtPath: Root '" ++ rootName ++ "' not in VarEnv")

        go : TypedPath.Path -> Mono.MonoDtPath
        go path =
            case path of
                TypedPath.Empty ->
                    Mono.DtRoot rootName rootType

                TypedPath.Index index hint subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeIndexProjectionType mvarEnv globalTypeEnv (dtHintToTOptHint hint) (Index.toMachine index) containerType
                    in
                    Mono.DtIndex (Index.toMachine index) (dtHintToKind hint) resultType monoSubPath

                TypedPath.Unbox subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeUnboxResultType mvarEnv globalTypeEnv containerType
                    in
                    Mono.DtUnbox resultType monoSubPath
    in
    go dtPath


{-| Specialize a pattern match decider tree.
-}
specializeDecider : Mono.MonoType -> Name -> TOpt.Decider (TOpt.Choice MVarId) -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider expectedMono rootName decider subst state =
    case decider of
        TOpt.Leaf choice ->
            let
                ( monoChoice, stateAfter ) =
                    specializeChoice expectedMono choice subst state
            in
            ( Mono.Leaf monoChoice, stateAfter )

        TOpt.Chain testChain success failure ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoTestChain =
                    List.map
                        (\( path, test ) ->
                            ( specializeDtPath state.ctx.mvarEnv rootName path state.ctx.varEnv state.ctx.globalTypeEnv, test )
                        )
                        testChain

                ( monoSuccess, state1 ) =
                    specializeDecider expectedMono rootName success subst state

                state1WithResetVarEnv =
                    { state1
                        | ctx =
                            let
                                c =
                                    state1.ctx
                            in
                            { c | varEnv = savedVarEnv }
                    }

                ( monoFailure, state2 ) =
                    specializeDecider expectedMono rootName failure subst state1WithResetVarEnv
            in
            ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path edges fallback ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoPath =
                    specializeDtPath state.ctx.mvarEnv rootName path state.ctx.varEnv state.ctx.globalTypeEnv

                ( monoEdges, state1 ) =
                    specializeEdges expectedMono rootName edges subst state

                state1WithResetVarEnv =
                    { state1
                        | ctx =
                            let
                                c =
                                    state1.ctx
                            in
                            { c | varEnv = savedVarEnv }
                    }

                ( monoFallback, state2 ) =
                    specializeDecider expectedMono rootName fallback subst state1WithResetVarEnv
            in
            ( Mono.FanOut monoPath monoEdges monoFallback, state2 )


specializeChoice : Mono.MonoType -> TOpt.Choice MVarId -> Substitution -> MonoState -> ( Mono.MonoChoice, MonoState )
specializeChoice expectedMono choice subst state =
    case choice of
        TOpt.Inline expr ->
            let
                -- J5: thread the pushed-type unify env into the choice specialization.
                ( pushedSubst, pushedEnv ) =
                    pushExpectedType state.ctx.mvarEnv expectedMono (TOpt.typeOf expr) subst

                ( monoExpr, stateAfter ) =
                    specializeExpr expr pushedSubst (setMVarEnv pushedEnv state)
            in
            ( Mono.Inline monoExpr, stateAfter )

        TOpt.Jump index ->
            ( Mono.Jump index, state )


specializeEdges : Mono.MonoType -> Name -> List ( DT.Test, TOpt.Decider (TOpt.Choice MVarId) ) -> Substitution -> MonoState -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )
specializeEdges expectedMono rootName edges subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( test, decider ) ( acc, st ) ->
                    let
                        stWithResetVarEnv =
                            { st
                                | ctx =
                                    let
                                        c =
                                            st.ctx
                                    in
                                    { c | varEnv = savedVarEnv }
                            }

                        ( monoDecider, newSt ) =
                            specializeDecider expectedMono rootName decider subst stWithResetVarEnv
                    in
                    ( ( test, monoDecider ) :: acc, newSt )
                )
                ( [], state )
                edges
    in
    ( List.reverse revAcc, finalState )


specializeJumps : Mono.MonoType -> List ( Int, TOpt.Expr MVarId ) -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeJumps expectedMono jumps subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( idx, expr ) ( acc, st ) ->
                    let
                        stWithResetVarEnv =
                            { st
                                | ctx =
                                    let
                                        c =
                                            st.ctx
                                    in
                                    { c | varEnv = savedVarEnv }
                            }

                        -- J5: thread the pushed-type unify env into the branch specialization.
                        ( pushedSubst, pushedEnv ) =
                            pushExpectedType st.ctx.mvarEnv expectedMono (TOpt.typeOf expr) subst

                        ( monoExpr, newSt ) =
                            specializeExpr expr pushedSubst (setMVarEnv pushedEnv stWithResetVarEnv)
                    in
                    ( ( idx, monoExpr ) :: acc, newSt )
                )
                ( [], state )
                jumps
    in
    ( List.reverse revAcc, finalState )


{-| Extract the expression type from a MonoDef.
-}
monoDefExprType : Mono.MonoDef -> Mono.MonoType
monoDefExprType monoDef =
    case monoDef of
        Mono.MonoDef _ monoExpr ->
            Mono.typeOf monoExpr

        Mono.MonoTailDef _ monoArgs monoExpr ->
            -- For TailDef, construct the function type from args and body return type.
            List.foldr
                (\( _, argType ) acc -> Mono.mFunction Mono.LTop [ argType ] acc)
                (Mono.typeOf monoExpr)
                monoArgs


{-| Compute the result MonoType for a Call expression.

Interpret the call expression's canonical result type using only the callee's
call-site substitution from unifyCallSiteDirect. The caller's substitution is
not applied here — with globally unique MVarIds per scheme, the old
caller-first heuristic is no longer needed and can produce wrong results.

-}
callResultMonoType : MVarEnv -> MonoState -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MonoState )
callResultMonoType mvarEnv state callSubst canType =
    applySubstFVWithEnv mvarEnv state callSubst canType


{-| Specialize a function argument by applying type substitution.
-}
specializeArg : MVarEnv -> Substitution -> ( A.Located Name, Can.Type MVarId ) -> ( Name, Mono.MonoType )
specializeArg mvarEnv subst ( locName, canType ) =
    let
        name =
            A.toValue locName

        monoType =
            TypeSubst.applySubstPure mvarEnv subst canType
    in
    ( name, monoType )


{-| Build a function type from a list of arguments and a return type.
-}
buildFuncType : List ( A.Located Name, Can.Type MVarId ) -> Can.Type MVarId -> Can.Type MVarId
buildFuncType args returnType =
    List.foldr
        (\( _, argType ) acc ->
            Can.TLambda argType acc
        )
        returnType
        args


{-| Build a constructor shape from name, tag, arity, and monomorphic type information.
-}
buildCtorShapeFromArity : Name.Name -> Int -> Int -> Mono.MonoType -> Mono.CtorShape
buildCtorShapeFromArity ctorName tag arity ctorMonoType =
    let
        fieldTypes =
            extractFieldTypes arity ctorMonoType
    in
    { name = ctorName
    , tag = tag
    , fieldTypes = fieldTypes
    }


{-| Extract a specific number of argument types from a function type.
-}
extractFieldTypes : Int -> Mono.MonoType -> List Mono.MonoType
extractFieldTypes n monoType =
    if n <= 0 then
        []

    else
        case monoType of
            Mono.MFunction _ _ args result ->
                args ++ extractFieldTypes (n - List.length args) result

            _ ->
                []


{-| Return True if a MonoType contains no remaining type variables.

Used to detect when a kernel use has been fully specialized at a call site
(e.g. Basics.add : number -> number -> number instantiated as
Int -> Int -> Int or Float -> Float -> Float).

-}
isFullyMonomorphicType : Mono.MonoType -> Bool
isFullyMonomorphicType monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            -- An open number var is a residual that closes to Int before codegen
            -- (the residual-number close in Prune), so for kernel-ABI suffix selection it is a
            -- monomorphic Int: keep the `_Int` fast path. The stored type is
            -- rewritten to MInt by the closing pass before the backend sees it.
            True

        Mono.MVar _ Mono.CEcoValue ->
            False

        Mono.MList _ inner ->
            isFullyMonomorphicType inner

        Mono.MFunction _ _ args result ->
            List.all isFullyMonomorphicType args
                && isFullyMonomorphicType result

        Mono.MTuple _ elems ->
            List.all isFullyMonomorphicType elems

        Mono.MRecord _ fields ->
            Dict.foldl
                (\_ fieldType acc -> acc && isFullyMonomorphicType fieldType)
                True
                fields

        Mono.MCustom _ _ _ args ->
            List.all isFullyMonomorphicType args

        -- Primitive / unit types are trivially monomorphic
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MBool ->
            True

        Mono.MChar ->
            True

        Mono.MString ->
            True

        Mono.MUnit ->
            True



-- ========== KERNEL ABI TYPE DERIVATION ==========


{-| Derive the MonoType for a kernel function's ABI.

This is _call-site aware_:

  - For monomorphic uses (no remaining MVar in the instantiated function type),
    we prefer the fully specialized MonoType obtained by applying the call-site
    substitution.

  - For genuinely polymorphic uses, we fall back to the KernelAbiMode-driven
    behavior:

        - UseSubstitution  -> applySubst
        - PreserveVars     -> all CEcoValue (boxed) vars (or concrete type
          when the kernel is in `suffixSelectingKernels` and the call site
          is fully monomorphic)

-}
deriveKernelAbiType : MVarEnv -> ( String, String ) -> Can.Type MVarId -> Substitution -> Mono.MonoType
deriveKernelAbiType mvarEnv kernelId canFuncType callSubst =
    let
        -- Monomorphic function type at this use-site, after substitution.
        monoAfterSubst : Mono.MonoType
        monoAfterSubst =
            TypeSubst.applySubstPure mvarEnv callSubst canFuncType

        mode : KernelAbi.KernelAbiMode
        mode =
            KernelAbi.deriveKernelAbiMode kernelId canFuncType mvarEnv
    in
    case mode of
        KernelAbi.UseSubstitution ->
            -- Monomorphic kernel type from the outset (no type variables).
            monoAfterSubst

        KernelAbi.PreserveVars ->
            -- Concrete-type-aware kernels keep the monomorphic call-site type
            -- so it can drive Elm-level wrapper specialization (e.g. List.cons
            -- per element type) and per-instance kernel symbol selection (e.g.
            -- Utils.compare → _Int / _Float / _Char). The C++ kernel ABI is
            -- determined separately by kernelBackendAbiPolicy in MLIR codegen,
            -- which may override this type with all-boxed !eco.value arguments.
            if
                EverySet.member KernelAbi.comparePair kernelId KernelAbi.suffixSelectingKernels
                    && isFullyMonomorphicType monoAfterSubst
            then
                -- e.g. List.cons : Int -> List Int -> List Int at this site
                monoAfterSubst

            else
                -- default: all vars become CEcoValue (fully boxed ABI)
                Tuple.first (KernelAbi.canTypeToMonoType_preserveVars mvarEnv canFuncType)



-- ========== GLOBAL CONVERSIONS ==========


{-| Convert a typed optimized global reference to a monomorphized global reference.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name



-- ========== LOCAL FUNCTION CLONE HELPERS ==========


{-| Rename a MonoDef to use a fresh name (for multi-specialization clones).
-}
renameMonoDef : Name -> Mono.MonoDef -> Mono.MonoDef
renameMonoDef newName def =
    case def of
        Mono.MonoDef _ expr ->
            Mono.MonoDef newName expr

        Mono.MonoTailDef oldName args expr ->
            Mono.MonoTailDef newName args (renameTailCalls oldName newName expr)


{-| Rename self tail-calls from oldName to newName in a MonoExpr.

Used when cloning MonoTailDef for local multi-specialization so that
each cloned definition's internal MonoTailCall refers to its own name.

-}
renameTailCalls : Name -> Name -> Mono.MonoExpr -> Mono.MonoExpr
renameTailCalls oldName newName expr =
    case expr of
        Mono.MonoTailCall name args resultType ->
            Mono.MonoTailCall
                (if name == oldName then
                    newName

                 else
                    name
                )
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) args)
                resultType

        Mono.MonoCall region func args resultType callInfo ->
            Mono.MonoCall region
                (renameTailCalls oldName newName func)
                (List.map (renameTailCalls oldName newName) args)
                resultType
                callInfo

        Mono.MonoIf branches final resultType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( renameTailCalls oldName newName c, renameTailCalls oldName newName t )) branches)
                (renameTailCalls oldName newName final)
                resultType

        Mono.MonoLet def_ body resultType ->
            let
                newDef =
                    case def_ of
                        Mono.MonoDef n bound ->
                            Mono.MonoDef n (renameTailCalls oldName newName bound)

                        Mono.MonoTailDef n params bound ->
                            Mono.MonoTailDef
                                (if n == oldName then
                                    newName

                                 else
                                    n
                                )
                                params
                                (renameTailCalls oldName newName bound)
            in
            Mono.MonoLet newDef (renameTailCalls oldName newName body) resultType

        Mono.MonoClosure info body closureType ->
            Mono.MonoClosure info (renameTailCalls oldName newName body) closureType

        Mono.MonoList region items t ->
            Mono.MonoList region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoTupleCreate region items t ->
            Mono.MonoTupleCreate region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) fields)
                t

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate
                (renameTailCalls oldName newName record)
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) updates)
                t

        Mono.MonoRecordAccess record fieldName t ->
            Mono.MonoRecordAccess (renameTailCalls oldName newName record) fieldName t

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct destructor (renameTailCalls oldName newName body) t

        Mono.MonoCase scrutName scrutVar decider jumps t ->
            Mono.MonoCase scrutName
                scrutVar
                (renameTailCallsDecider oldName newName decider)
                (List.map (\( i, e ) -> ( i, renameTailCalls oldName newName e )) jumps)
                t

        -- Leaf nodes: unchanged
        Mono.MonoLiteral _ _ ->
            expr

        Mono.MonoVarLocal _ _ ->
            expr

        Mono.MonoVarGlobal _ _ _ ->
            expr

        Mono.MonoVarKernel _ _ _ _ _ ->
            expr

        Mono.MonoUnit ->
            expr

        Mono.MonoAccessorValue _ _ _ ->
            expr


renameTailCallsDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameTailCallsDecider oldName newName decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (renameTailCallsChoice oldName newName choice)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (renameTailCallsDecider oldName newName success)
                (renameTailCallsDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, renameTailCallsDecider oldName newName d )) edges)
                (renameTailCallsDecider oldName newName fallback)


renameTailCallsChoice : Name -> Name -> Mono.MonoChoice -> Mono.MonoChoice
renameTailCallsChoice oldName newName choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (renameTailCalls oldName newName e)

        Mono.Jump i ->
            Mono.Jump i



-- ========== ARRAY HELPERS ==========


{-| Check if the array has a non-Nothing node at the given index.
-}
arrayHasNode : Int -> Array.Array (Maybe a) -> Bool
arrayHasNode index arr =
    case Array.get index arr of
        Just (Just _) ->
            True

        _ ->
            False


{-| Set an element in an array, growing it with Nothing values if necessary.
-}
arraySetGrowing : Int -> Maybe a -> Array.Array (Maybe a) -> Array.Array (Maybe a)
arraySetGrowing index value arr =
    let
        len =
            Array.length arr
    in
    if index < len then
        Array.set index value arr

    else
        Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))
