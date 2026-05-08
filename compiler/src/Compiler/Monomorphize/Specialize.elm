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
    | PendingGlobal (TOpt.Expr MVarId) Substitution (Can.Type MVarId)
    | PendingCall (TOpt.Expr MVarId) Substitution (Can.Type MVarId)
    | LocalFunArg Name (Can.Type MVarId)



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
-}
applySubstFV : MonoState -> Substitution -> Can.Type MVarId -> Mono.MonoType
applySubstFV state subst canType =
    TypeSubst.applySubstWithFreeVars state.ctx.mvarEnv state.ctx.currentFreeVars subst canType


{-| Enqueue a specialization onto the worklist, deduplicating via the scheduled BitSet.
-}
enqueueSpec :
    Mono.Global
    -> Mono.MonoType
    -> Maybe Mono.LambdaId
    -> MonoState
    -> ( Mono.SpecId, MonoState )
enqueueSpec global rawMonoType maybeLambda state =
    let
        monoType =
            Mono.forceCNumberToInt rawMonoType

        accum =
            state.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType maybeLambda accum.registry
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
getOrCreateLocalInstance defName funcMonoType callSubst state =
    let
        key =
            Mono.toComparableMonoType funcMonoType

        ( updatedStack, freshName ) =
            updateLocalMultiStack defName key funcMonoType callSubst state.ctx.localMulti
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
    -> String
    -> Mono.MonoType
    -> Substitution
    -> List LocalMultiState
    -> ( List LocalMultiState, Name )
updateLocalMultiStack defName key funcMonoType callSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateLocalMultiStack: defName not found in stack: " ++ defName)

        localState :: rest ->
            if localState.defName == defName then
                case Dict.get key localState.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Dict.size localState.instances

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
                                Dict.insert key newInfo localState.instances

                            newLocalState =
                                { localState | instances = newInstances }
                        in
                        ( newLocalState :: rest, freshName )

            else
                let
                    ( updatedRest, freshName ) =
                        updateLocalMultiStack defName key funcMonoType callSubst rest
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


{-| Check if a Can.Type MVarId contains any type variable with CEcoValue constraint.
-}
hasCEcoTVar : MVarEnv -> Can.Type MVarId -> Bool
hasCEcoTVar mvarEnv canType =
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
    typeContainsLambda defCanType && hasCEcoTVar mvarEnv defCanType


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


{-| Build a partial MonoType container by walking a TOpt.Path outward from the
Root, placing `leafMonoType` at the Root position and fresh MVars for sibling
positions. Returns Nothing for shapes we don't yet know how to synthesize
(Index + HintCustom, Index + HintList, ArrayIndex); callers should fall back
to the non-valueMulti code path.

Examples:
Index 0 HintTuple2 (Root n) -> MTuple [leaf, MVar fresh]
Index 1 HintTuple3 (Root n) -> MTuple [MVar, leaf, MVar]
Field "a" (Root n) -> MRecord (Dict.singleton "a" leaf)
Unbox (Root n) -> leaf (wrapper's payload is the leaf)

-}
buildPartialContainer : TOpt.Path -> Mono.MonoType -> MonoState -> Maybe ( Mono.MonoType, MonoState )
buildPartialContainer path leafMonoType state =
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
                    buildPartialContainer subPath (Mono.MTuple elems) state1

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
                    buildPartialContainer subPath (Mono.MTuple elems) state1

                _ ->
                    -- HintList, HintCustom: not synthesized here; fall back.
                    Nothing

        TOpt.Field fieldName subPath ->
            buildPartialContainer subPath
                (Mono.MRecord (Dict.singleton fieldName leafMonoType))
                state

        TOpt.Unbox subPath ->
            -- A single-field wrapper: the wrapper's payload is the leaf, so
            -- the container viewed at the next level out is the leaf itself.
            -- This is an approximation — once that outer level is a known
            -- MCustom/MRecord the existing layout logic takes over; for now
            -- we punt.
            buildPartialContainer subPath leafMonoType state

        TOpt.ArrayIndex _ _ ->
            Nothing


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
`MFunction`s). `Mono.resultTypeOf` is unsafe here because it drills through all
layers, giving the wrong type for partial applications.
-}
peelCallResult : Int -> Mono.MonoType -> Mono.MonoType
peelCallResult numArgs monoType =
    if numArgs <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction params result ->
                let
                    pcount =
                        List.length params
                in
                if pcount > numArgs then
                    Mono.MFunction (List.drop numArgs params) result

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
getOrCreateValueInstance defName monoType currentSubst state =
    let
        key =
            Mono.toComparableMonoType monoType

        ( updatedStack, freshName_ ) =
            updateValueMultiStack defName key monoType currentSubst state.ctx.valueMulti
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
    -> String
    -> Mono.MonoType
    -> Substitution
    -> List ValueMultiState
    -> ( List ValueMultiState, Name )
updateValueMultiStack defName key monoType currentSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateValueMultiStack: defName not found in stack: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Dict.get key entry.instances of
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
                                Dict.insert key newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Dict.size entry.instances

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
                                Dict.insert key newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, freshName_ )

            else
                let
                    ( updatedRest, freshName_ ) =
                        updateValueMultiStack defName key monoType currentSubst rest
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
    -> String
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
                case Dict.get instanceKey entry.instances of
                    Just info ->
                        let
                            newInfo =
                                { info
                                    | derivedDestructorNames =
                                        Set.insert destructorName info.derivedDestructorNames
                                }

                            newInstances =
                                Dict.insert instanceKey newInfo entry.instances
                        in
                        { entry | instances = newInstances } :: rest

                    Nothing ->
                        Utils.Crash.crash
                            ("Specialize.tagValueInstanceWithDestructor: instance key not found for "
                                ++ defName
                                ++ " / "
                                ++ instanceKey
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
            case findInstanceByDestructor funcName (Dict.toList entry.instances) of
                Just ( instanceKey, info ) ->
                    let
                        ( newSubst, newEnv ) =
                            TypeSubst.unifyArgsOnly mvarEnv funcCanType argTypes info.subst

                        newInfo =
                            { info | subst = newSubst }

                        newInstances =
                            Dict.insert instanceKey newInfo entry.instances

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
    -> List ( String, State.ValueInstanceInfo )
    -> Maybe ( String, State.ValueInstanceInfo )
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
    produces: params=[(x,Int),(y,Int)], type=MFunction [Int] (MFunction [Int] Int)

The flat param list comes from TOpt.Function syntax.
The curried type comes from TypeSubst.applySubst preserving TLambda structure.

GlobalOpt (GOPT\_016) will canonicalize by flattening the type:
MFunction [Int] (MFunction [Int] Int) → MFunction [Int, Int] Int

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
        monoType0 : Mono.MonoType
        monoType0 =
            Mono.forceCNumberToInt (applySubstFV state subst canType)

        -- 1b. Feed the concrete function type back into the substitution.
        -- This propagates constraints from the enclosing specialization context
        -- (e.g. compose identity identity 1) into the lambda's internal type variables.
        -- unifyExtend only adds bindings already implied by monoType0, so this is safe.
        refinedSubst : Substitution
        refinedSubst =
            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canType monoType0 subst)

        -- 2. Extract params and body directly (no peelFunctionChain).
        ( params, bodyExpr ) =
            case lambdaExpr of
                TOpt.Function ps body _ ->
                    ( ps, body )

                TOpt.TrackedFunction trackedPs body _ ->
                    ( List.map (\( locName, ty ) -> ( A.toValue locName, ty )) trackedPs, body )

                _ ->
                    Utils.Crash.crash
                        "specializeLambda: called with non-lambda expression"

        -- Guard: paramCount == 0 is a bug
        -- 3. Specialize each parameter's declared Can.Type MVarId under refinedSubst.
        monoParams : List ( Name, Mono.MonoType )
        monoParams =
            List.map
                (\( name, paramCanType ) ->
                    ( name, Mono.forceCNumberToInt (applySubstFV state refinedSubst paramCanType) )
                )
                params

        ctx =
            state.ctx

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
            { state
                | ctx =
                    { ctx
                        | lambdaCounter = ctx.lambdaCounter + 1
                        , varEnv = newVarEnv
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

        ( ctorMonoTypeRaw, mvarEnv2 ) =
            TypeSubst.applySubst mvarEnv1 subst schemeInfo.schemeType

        ctorMonoType =
            Mono.forceCNumberToInt ctorMonoTypeRaw

        shape =
            buildCtorShapeFromArity ctorName tag arity ctorMonoType

        ctorResultType =
            extractCtorResultType arity requestedMonoType

        ctx2 =
            let
                ctx =
                    state1.ctx
            in
            { ctx | mvarEnv = mvarEnv2 }
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

                subst0 =
                    Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)

                -- Also unify the body expression's canonical type with requestedMonoType.
                -- The annotation canType may be fully resolved (no TVars) while internal
                -- expressions retain unresolved TVars. This enriches the substitution
                -- with bindings for those internal TVars.
                subst =
                    Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv (TOpt.typeOf expr) requestedMonoType subst0)

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TrackedDefine _ expr _ meta ->
            let
                canType =
                    meta.tipe

                subst0 =
                    Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)

                subst =
                    Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv (TOpt.typeOf expr) requestedMonoType subst0)

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

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
                monoType =
                    Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst state.ctx.mvarEnv (Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)) canType))

                enumHome =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global canonical _) ->
                            canonical

                        _ ->
                            Utils.Crash.crash "specializeNode TOpt.Enum: currentGlobal must be a Global"
            in
            ( Mono.MonoEnum (CtorTag.effective enumHome ctorName tag) monoType, state )

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
            let
                canType =
                    meta.tipe

                subst =
                    Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state
            in
            -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
            ( Mono.MonoPortIncoming monoExpr requestedMonoType, state1 )

        TOpt.PortOutgoing expr _ meta ->
            let
                canType =
                    meta.tipe

                subst =
                    Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state
            in
            -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
            ( Mono.MonoPortOutgoing monoExpr requestedMonoType, state1 )


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
            specializeValueCycle
                requestedCanonical
                requestedName
                valueDefs
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


{-| Specialize a value-only recursive cycle by creating separate MonoDefine nodes
for each zero-arg binding, mirroring specializeFunctionCycle.
-}
specializeValueCycle :
    IO.Canonical
    -> Name
    -> List ( Name, TOpt.Expr MVarId )
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeValueCycle requestedCanonical requestedName valueDefs requestedMonoType state =
    let
        maybeRequestedExpr =
            List.filter (\( n, _ ) -> n == requestedName) valueDefs
                |> List.head

        sharedSubst : Substitution
        sharedSubst =
            case maybeRequestedExpr of
                Just ( _, expr ) ->
                    let
                        canType =
                            TOpt.typeOf expr
                    in
                    Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)

                Nothing ->
                    Dict.empty

        ( newNodes, stateAfter ) =
            List.foldl
                (specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, state )
                valueDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.accum.registry
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
            Mono.forceCNumberToInt
                (Tuple.first (TypeSubst.applySubst accState.ctx.mvarEnv sharedSubst canType))

        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromExpr

        accum =
            accState.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalVal monoTypeForSpecId Nothing accum.registry

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

This generalizes the previous function-only behavior to cover mixed
value+function SCCs. `specializeValueCycle` still handles pure-value SCCs.

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
        substFromFunc : Substitution
        substFromFunc =
            case maybeRequestedDef of
                Just def ->
                    Tuple.first
                        (TypeSubst.unify
                            state.ctx.mvarEnv
                            (getDefCanonicalType def)
                            requestedMonoType
                        )

                Nothing ->
                    Dict.empty

        -- Extend with value-derived bindings if the requested name is a value.
        -- Using unifyExtend mirrors how `specializeNode`'s TOpt.Define /
        -- TrackedDefine cases enrich substitutions.
        sharedSubst : Substitution
        sharedSubst =
            case maybeRequestedExpr of
                Just ( _, expr ) ->
                    Tuple.first
                        (TypeSubst.unifyExtend
                            state.ctx.mvarEnv
                            (TOpt.typeOf expr)
                            requestedMonoType
                            substFromFunc
                        )

                Nothing ->
                    substFromFunc

        -- Specialize all functions in the cycle under sharedSubst.
        ( nodesAfterFuncs, stateAfterFuncs ) =
            List.foldl
                (specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, state )
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
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.accum.registry
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
            Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst accState.ctx.mvarEnv sharedSubst canType))

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
            Registry.getOrCreateSpecId globalFun monoTypeForSpecId Nothing accum.registry

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
                    { state | ctx = { ctx | varEnv = newVarEnv } }

                augmentedSubstRaw =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canParamType monoParamType s)
                        )
                        subst
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
                    Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst state.ctx.mvarEnv augmentedSubstRaw returnType))
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoFuncType, state1 )



-- ========== VALUE DEFINITIONS ==========
-- ========== EXPRESSION SPECIALIZATION ==========


{-| Specialize a typed optimized expression to a monomorphized expression by applying type substitutions.
-}
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

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)
            in
            case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, state )

                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, state )

        TOpt.Float _ value meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)
            in
            ( Mono.MonoLiteral (Mono.LFloat value) monoType, state )

        TOpt.VarLocal name meta ->
            if isLocalMultiTarget name state then
                let
                    monoTypeFromMeta =
                        Mono.forceCNumberToInt (applySubstFV state subst meta.tipe)

                    ( freshName, state1 ) =
                        getOrCreateLocalInstance name monoTypeFromMeta subst state
                in
                ( Mono.MonoVarLocal freshName monoTypeFromMeta, state1 )

            else
                case State.lookupVar name state.ctx.varEnv of
                    Just envType ->
                        ( Mono.MonoVarLocal name envType, state )

                    Nothing ->
                        let
                            monoTypeFromMeta =
                                Mono.forceCNumberToInt (applySubstFV state subst meta.tipe)
                        in
                        ( Mono.MonoVarLocal name monoTypeFromMeta, state )

        TOpt.TrackedVarLocal _ name meta ->
            if isLocalMultiTarget name state then
                let
                    monoTypeFromMeta =
                        Mono.forceCNumberToInt (applySubstFV state subst meta.tipe)

                    ( freshName, state1 ) =
                        getOrCreateLocalInstance name monoTypeFromMeta subst state
                in
                ( Mono.MonoVarLocal freshName monoTypeFromMeta, state1 )

            else
                case State.lookupVar name state.ctx.varEnv of
                    Just envType ->
                        ( Mono.MonoVarLocal name envType, state )

                    Nothing ->
                        let
                            monoTypeFromMeta =
                                Mono.forceCNumberToInt (applySubstFV state subst meta.tipe)
                        in
                        ( Mono.MonoVarLocal name monoTypeFromMeta, state )

        TOpt.VarGlobal region global meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global state.ctx.toptNodes of
                                Just (TOpt.Define _ _ defMeta) ->
                                    Mono.forceCNumberToInt (applySubstFV state subst defMeta.tipe)

                                Just (TOpt.TrackedDefine _ _ _ defMeta) ->
                                    Mono.forceCNumberToInt (applySubstFV state subst defMeta.tipe)

                                Just (TOpt.Enum _ enumCanType) ->
                                    Mono.forceCNumberToInt (applySubstFV state subst enumCanType)

                                Just (TOpt.Ctor _ _ ctorCanType) ->
                                    Mono.forceCNumberToInt (applySubstFV state subst ctorCanType)

                                _ ->
                                    monoType0

                        _ ->
                            monoType0

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarEnum region global _ meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global state.ctx.toptNodes of
                                Just (TOpt.Enum _ enumCanType) ->
                                    Mono.forceCNumberToInt (applySubstFV state subst enumCanType)

                                _ ->
                                    monoType0

                        _ ->
                            monoType0

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarBox region global meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
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
                    Mono.forceCNumberToInt
                        (Tuple.first (TypeSubst.applySubst state.ctx.mvarEnv subst schemeType))

                monoGlobal =
                    Mono.Global canonical name

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
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

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                ( monoExprs, stateAfter ) =
                    specializeExprs exprs subst state

                -- If the element type has unresolved TVars, infer from first element.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case monoExprs of
                            first :: _ ->
                                Mono.MList (Mono.typeOf first)

                            [] ->
                                -- Empty list: element type is unconstrained, leave as-is.
                                -- MVar _ CEcoValue compiles identically to eco.value.
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoList region monoExprs monoType, stateAfter )

        TOpt.Function params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.Function params body meta) canType subst state

        TOpt.TrackedFunction params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.TrackedFunction params body meta) canType subst state

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
                        -- The annotation has zero generalized vars, so canTypeToMonoType with
                        -- substForCall is sufficient to derive the single funcMonoType.
                        let
                            ( funcMonoTypeRaw, mvarEnv2 ) =
                                TypeSubst.canTypeToMonoType state1r.ctx.mvarEnv substForCall funcCanType

                            funcMonoType =
                                Mono.forceCNumberToInt funcMonoTypeRaw

                            state1m =
                                let
                                    ctx =
                                        state1r.ctx
                                in
                                { state1r | ctx = { ctx | mvarEnv = mvarEnv2 } }

                            paramTypes =
                                TypeSubst.extractParamTypes funcMonoType

                            ( monoArgs, state2 ) =
                                resolveProcessedArgs processedArgs paramTypes substForCall state1m

                            resultMonoType =
                                callResultMonoType
                                    state2.ctx.mvarEnv
                                    state2.ctx.currentFreeVars
                                    substForCall
                                    canType

                            monoGlobal =
                                toptGlobalToMono global

                            ( specId, newState ) =
                                enqueueSpec monoGlobal funcMonoType Nothing state2

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

                            ( callSubst, funcMonoTypeRaw, _ ) =
                                TypeSubst.unifyCallSiteDirectWithExpected
                                    state1a.ctx.mvarEnv
                                    schemeInfo.argTypes
                                    schemeInfo.resultType
                                    argTypes
                                    (Just canType)
                                    substForCall

                            funcMonoType =
                                Mono.forceCNumberToInt funcMonoTypeRaw

                            paramTypes =
                                TypeSubst.extractParamTypes funcMonoType

                            ( monoArgs, state2 ) =
                                resolveProcessedArgs processedArgs paramTypes callSubst state1a

                            resultMonoType =
                                callResultMonoType state1a.ctx.mvarEnv state1a.ctx.currentFreeVars callSubst canType

                            monoGlobal =
                                toptGlobalToMono global

                            ( specId, newState ) =
                                enqueueSpec monoGlobal funcMonoType Nothing state2

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
                        ( callSubst, _, _ ) =
                            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                        -- Kernel ABI derivation uses funcCanType directly (no renaming)
                        funcMonoType =
                            deriveKernelAbiType state.ctx.mvarEnv ( home, name ) funcCanType callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1a

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

                        resultMonoType =
                            if Mono.containsAnyMVar abiResultType then
                                callResultMonoType state1a.ctx.mvarEnv state1a.ctx.currentFreeVars callSubst canType

                            else
                                abiResultType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2 )

                TOpt.VarDebug funcRegion name _ _ funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1r

                        -- Direct unification: scheme MVarIds are freshened by buildSchemeInfo
                        ( callSubst, _, _ ) =
                            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                        -- Kernel ABI derivation uses funcCanType directly (no renaming)
                        funcMonoType =
                            deriveKernelAbiType state.ctx.mvarEnv ( "Debug", name ) funcCanType callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1a

                        -- Same invariant as VarKernel: trust the ABI-derived result
                        -- type when it is fully concrete; otherwise fall back to
                        -- the enclosing canType so MVar IDs stay aligned with the
                        -- enclosing spec key. Peel exactly the applied-arg count
                        -- to handle partial applications correctly.
                        abiResultType =
                            peelCallResult (List.length argTypes) funcMonoType

                        resultMonoType =
                            if Mono.containsAnyMVar abiResultType then
                                callResultMonoType state1a.ctx.mvarEnv state1a.ctx.currentFreeVars callSubst canType

                            else
                                abiResultType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion "Elm" "Debug" name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2 )

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
                                state1d =
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

                                funcMonoType =
                                    Mono.forceCNumberToInt (applySubstFV state1d callSubst funcCanType)

                                paramTypes =
                                    TypeSubst.extractParamTypes funcMonoType

                                ( monoArgs, state2 ) =
                                    resolveProcessedArgs processedArgs paramTypes callSubst state1d

                                resultMonoType =
                                    callResultMonoType state2.ctx.mvarEnv state2.ctx.currentFreeVars callSubst canType

                                ( monoFunc, state3 ) =
                                    specializeExpr func callSubst state2
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
                                        callSubst =
                                            Tuple.first (TypeSubst.unifyArgsOnly state1.ctx.mvarEnv funcCanType argTypes subst)

                                        funcMonoType =
                                            Mono.forceCNumberToInt (applySubstFV state1 callSubst funcCanType)

                                        paramTypes =
                                            TypeSubst.extractParamTypes funcMonoType

                                        ( monoArgs, state2 ) =
                                            resolveProcessedArgs processedArgs paramTypes callSubst state1

                                        resultMonoType =
                                            callResultMonoType state1.ctx.mvarEnv state1.ctx.currentFreeVars callSubst canType

                                        ( freshName, state3 ) =
                                            getOrCreateLocalInstance name funcMonoType callSubst state2

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

                                        ( callSubst, funcMonoTypeRaw, _ ) =
                                            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                                        funcMonoType =
                                            Mono.forceCNumberToInt funcMonoTypeRaw

                                        paramTypes =
                                            TypeSubst.extractParamTypes funcMonoType

                                        ( monoArgs, state2 ) =
                                            resolveProcessedArgs processedArgs paramTypes callSubst state1a

                                        resultMonoType =
                                            callResultMonoType state1a.ctx.mvarEnv state1a.ctx.currentFreeVars callSubst canType

                                        ( monoFunc, state3 ) =
                                            specializeExpr func callSubst state2
                                    in
                                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                                    , state3
                                    )

        TOpt.TailCall name args meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                ( monoArgs, stateAfter ) =
                    specializeNamedExprs args subst state

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

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                ( monoBranches, state1 ) =
                    specializeBranches branches subst state

                ( monoFinal, state2 ) =
                    specializeExpr final subst state1

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

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

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
                            , instances = Dict.empty
                            }

                        stateForBody =
                            { state
                                | ctx =
                                    let
                                        c =
                                            state.ctx
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
                            if Dict.isEmpty topEntry.instances then
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

                                    defMonoType0 =
                                        Mono.forceCNumberToInt (applySubstFV state subst defCanType)

                                    defMonoType =
                                        if Mono.containsAnyMVar defMonoType0 then
                                            monoDefExprType monoDef

                                        else
                                            defMonoType0

                                    -- Enrich substitution with bindings discovered from
                                    -- the concrete def type, so the body sees them.
                                    -- This mirrors the non-function let branch below.
                                    enrichedSubst =
                                        if Mono.containsAnyMVar defMonoType0 then
                                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv defCanType defMonoType subst)

                                        else
                                            subst

                                    stateWithVar =
                                        { state1
                                            | ctx =
                                                let
                                                    c1 =
                                                        state1.ctx
                                                in
                                                { c1 | varEnv = State.insertVar defName defMonoType c1.varEnv }
                                        }

                                    -- Re-specialize body with enriched substitution
                                    -- so downstream expressions see the concrete def type.
                                    ( monoBody2, state2 ) =
                                        if Mono.containsAnyMVar defMonoType0 then
                                            specializeExpr body enrichedSubst stateWithVar

                                        else
                                            ( monoBody, stateWithVar )
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

                            else
                                -- We have one or more concrete instances discovered from call sites.
                                let
                                    instancesList =
                                        Dict.values topEntry.instances

                                    -- Build MonoDefs for each instance, bridging call-site types
                                    -- to the def's own type variables via unifyExtend.
                                    -- info.subst uses renamed call-site variable names which
                                    -- don't match the def's canonical type variables; unifyExtend
                                    -- properly maps the def's variables to the call-site mono types.
                                    ( instanceDefs, stateWithDefs ) =
                                        List.foldl
                                            (\info ( defsAcc, stAcc ) ->
                                                let
                                                    mergedSubst =
                                                        Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv defCanType info.monoType subst)

                                                    ( monoDef0, st1 ) =
                                                        specializeDef def mergedSubst stAcc

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

                                defMonoType0 =
                                    Mono.forceCNumberToInt (applySubstFV state subst defCanType)

                                defMonoType =
                                    if Mono.containsAnyMVar defMonoType0 then
                                        monoDefExprType monoDef

                                    else
                                        defMonoType0

                                enrichedSubst =
                                    if Mono.containsAnyMVar defMonoType0 then
                                        Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv defCanType defMonoType subst)

                                    else
                                        subst

                                stateWithVar =
                                    { state1
                                        | ctx =
                                            let
                                                c1f =
                                                    state1.ctx
                                            in
                                            { c1f | varEnv = State.insertVar defName defMonoType c1f.varEnv }
                                    }

                                ( monoBody2, state2 ) =
                                    if Mono.containsAnyMVar defMonoType0 then
                                        specializeExpr body enrichedSubst stateWithVar

                                    else
                                        ( monoBody, stateWithVar )
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

                _ ->
                    if shouldUseValueMulti state.ctx.mvarEnv defCanType then
                        -- Value-multi path: defer specialization until uses are known.
                        let
                            newEntry =
                                { defName = defName
                                , defCanType = defCanType
                                , def = def
                                , instances = Dict.empty
                                }

                            -- Add defName to VarEnv with a preliminary type so that
                            -- Destruct nodes from LetDestruct can find their root variable.
                            -- (LetDestruct compiles to Let + Destruct chain where Destructs
                            -- reference Root defName.)
                            prelimDefMonoType =
                                Mono.forceCNumberToInt (applySubstFV state subst defCanType)

                            stateForBody =
                                { state
                                    | ctx =
                                        let
                                            cvm =
                                                state.ctx
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
                                if Dict.isEmpty topEntry.instances then
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

                                        defMonoType0 =
                                            Mono.forceCNumberToInt (applySubstFV state subst defCanType)

                                        defMonoType =
                                            if Mono.containsAnyMVar defMonoType0 then
                                                monoDefExprType monoDef

                                            else
                                                defMonoType0

                                        enrichedSubst =
                                            if Mono.containsAnyMVar defMonoType0 then
                                                Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv defCanType defMonoType subst)

                                            else
                                                subst

                                        stateWithVar =
                                            { state1
                                                | ctx =
                                                    let
                                                        cvme =
                                                            state1.ctx
                                                    in
                                                    { cvme | varEnv = State.insertVar defName defMonoType cvme.varEnv }
                                            }

                                        ( monoBody2, state2 ) =
                                            if Mono.containsAnyMVar defMonoType0 then
                                                specializeExpr body enrichedSubst stateWithVar

                                            else
                                                ( monoBody, stateWithVar )
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
                                            Dict.values topEntry.instances

                                        ( instanceDefs, stateWithDefs ) =
                                            List.foldl
                                                (\info ( defsAcc, stAcc ) ->
                                                    let
                                                        instanceDefMonoType0 =
                                                            Mono.forceCNumberToInt
                                                                (applySubstFV stateAfterBody info.subst defCanType)

                                                        mergedSubst =
                                                            Tuple.first
                                                                (TypeSubst.unifyExtend
                                                                    state.ctx.mvarEnv
                                                                    defCanType
                                                                    instanceDefMonoType0
                                                                    info.subst
                                                                )

                                                        ( monoDef0, st1 ) =
                                                            specializeDef def mergedSubst stAcc

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
                                                        instanceDefMonoType0 =
                                                            Mono.forceCNumberToInt
                                                                (applySubstFV stateAfterBody info.subst defCanType)
                                                    in
                                                    { st
                                                        | ctx =
                                                            let
                                                                cvmv =
                                                                    st.ctx
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

                    else
                        -- Non-function let: original eager behavior
                        let
                            ( monoDef, state1 ) =
                                specializeDef def subst state

                            defMonoType0 =
                                Mono.forceCNumberToInt (applySubstFV state subst defCanType)

                            -- If defCanType has unresolved TVars, infer from the specialized expr.
                            defMonoType =
                                if Mono.containsAnyMVar defMonoType0 then
                                    monoDefExprType monoDef

                                else
                                    defMonoType0

                            -- Also enrich the substitution with any bindings discovered
                            -- from the concrete def type, so the body sees them.
                            enrichedSubst =
                                if Mono.containsAnyMVar defMonoType0 then
                                    Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv defCanType defMonoType subst)

                                else
                                    subst

                            stateWithVar =
                                { state1
                                    | ctx =
                                        let
                                            c1n =
                                                state1.ctx
                                        in
                                        { c1n | varEnv = State.insertVar defName defMonoType c1n.varEnv }
                                }

                            ( monoBody, state2 ) =
                                specializeExpr body enrichedSubst stateWithVar
                        in
                        ( Mono.MonoLet monoDef
                            monoBody
                            (if Mono.containsAnyMVar monoType0 then
                                Mono.typeOf monoBody

                             else
                                monoType0
                            )
                        , state2
                        )

        TOpt.Destruct destructor body meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                (TOpt.Destructor dname destructorPath destructorMeta) =
                    destructor

                maybeValueMultiRefinement =
                    case getValueMultiRootFromPath destructorPath state of
                        Just ( rootName, rootCanType ) ->
                            let
                                destrMonoType0 =
                                    Mono.forceCNumberToInt
                                        (applySubstFV state subst destructorMeta.tipe)
                            in
                            case buildPartialContainer destructorPath destrMonoType0 state of
                                Just ( partialContainerMono, stateP ) ->
                                    let
                                        ( refinedSubst, mvarEnv1 ) =
                                            TypeSubst.unifyExtend stateP.ctx.mvarEnv
                                                rootCanType
                                                partialContainerMono
                                                subst

                                        stateR =
                                            setMVarEnv mvarEnv1 stateP

                                        rootInstanceMonoType =
                                            Mono.forceCNumberToInt
                                                (applySubstFV stateR refinedSubst rootCanType)

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
                                            Mono.toComparableMonoType rootInstanceMonoType

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
                            ( destructor, subst, state )

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

        TOpt.Case label root decider jumps meta ->
            -- ABI normalization for case expressions has been moved to MonoGlobalOptimize.
            -- Here we simply specialize the branches and use the type from the substitution.
            let
                canType =
                    meta.tipe

                monoTypeFromCan =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                savedVarEnv =
                    state.ctx.varEnv

                ( monoDecider0, state1 ) =
                    specializeDecider root decider subst state

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
                    specializeJumps jumps subst state1WithResetVarEnv
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

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)
            in
            if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                ( Mono.MonoAccessorValue region fieldName monoType, state )

            else
                let
                    accessorGlobal =
                        Mono.Accessor fieldName

                    ( specId, newState ) =
                        enqueueSpec accessorGlobal monoType Nothing state
                in
                ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.Access record _ fieldName meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)
            in
            case getValueMultiVar record state of
                Just ( varName, recordCanType ) ->
                    -- Value-multi target: derive the concrete record type from the
                    -- access field type. The field's monoType is concrete (type inference
                    -- resolved it), but the record's canonical type has free type vars.
                    -- Unify to learn the concrete bindings.
                    let
                        partialRecordMono =
                            Mono.MRecord (Dict.singleton fieldName monoType)

                        enrichedSubst =
                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv recordCanType partialRecordMono subst)

                        recordMonoType =
                            Mono.forceCNumberToInt (applySubstFV state enrichedSubst recordCanType)

                        ( freshName, state1 ) =
                            getOrCreateValueInstance varName recordMonoType enrichedSubst state
                    in
                    ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName recordMonoType) fieldName monoType, state1 )

                Nothing ->
                    let
                        ( monoRecord, stateAfter ) =
                            specializeExpr record subst state
                    in
                    ( Mono.MonoRecordAccess monoRecord fieldName monoType, stateAfter )

        TOpt.Update _ record updates meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                ( monoRecord, state1 ) =
                    specializeExpr record subst state

                -- Use the already-specialized record's MonoType for field type lookup.
                -- This is more concrete than re-applying subst to the canonical type,
                -- because monoRecord already encodes constraints from its own specialization.
                recordMonoType =
                    Mono.typeOf monoRecord

                getFieldMonoType fieldName =
                    case recordMonoType of
                        Mono.MRecord fieldMap ->
                            Dict.get fieldName fieldMap

                        _ ->
                            Nothing

                ( monoUpdates, state2 ) =
                    Data.Map.foldl A.compareLocated
                        (\locName updateExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                refinedSubst =
                                    case getFieldMonoType fieldName of
                                        Just fieldMonoType ->
                                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv (TOpt.typeOf updateExpr) fieldMonoType subst)

                                        Nothing ->
                                            subst

                                ( monoExpr, newSt ) =
                                    specializeExpr updateExpr refinedSubst st
                            in
                            ( ( fieldName, monoExpr ) :: acc, newSt )
                        )
                        ( [], state1 )
                        updates

                resultMonoType =
                    case ( recordMonoType, monoType ) of
                        ( Mono.MRecord recordFields, Mono.MRecord resultFields ) ->
                            Mono.forceCNumberToInt (Mono.MRecord (Dict.union resultFields recordFields))

                        ( Mono.MRecord _, _ ) ->
                            Utils.Crash.crash "Specialize.TOpt.Update: record with non-record result type"

                        _ ->
                            Utils.Crash.crash "Specialize.TOpt.Update: input expression is not a record"
            in
            ( Mono.MonoRecordUpdate monoRecord monoUpdates resultMonoType, state2 )

        TOpt.Record fields meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                -- Extract mono field types from the record MonoType for substitution refinement.
                monoFieldTypes =
                    case monoType of
                        Mono.MRecord fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Dict.foldl
                        (\fieldName fieldExpr ( acc, st ) ->
                            let
                                -- Refine substitution per field: unify field's canonical type with
                                -- the expected mono type, so lambdas inside records get concrete types.
                                refinedSubst =
                                    case Dict.get fieldName monoFieldTypes of
                                        Just fieldMonoType ->
                                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv (TOpt.typeOf fieldExpr) fieldMonoType subst)

                                        Nothing ->
                                            subst

                                ( monoExpr, newSt ) =
                                    specializeExpr fieldExpr refinedSubst st
                            in
                            ( ( fieldName, monoExpr ) :: acc, newSt )
                        )
                        ( [], state )
                        fields
            in
            ( Mono.MonoRecordCreate monoFields monoType, stateAfter )

        TOpt.TrackedRecord _ fields meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                -- Extract mono field types for substitution refinement.
                monoFieldTypes =
                    case monoType of
                        Mono.MRecord fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Data.Map.foldl A.compareLocated
                        (\locName fieldExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                -- Refine substitution per field for lambdas in records.
                                refinedSubst =
                                    case Dict.get fieldName monoFieldTypes of
                                        Just fieldMonoType ->
                                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv (TOpt.typeOf fieldExpr) fieldMonoType subst)

                                        Nothing ->
                                            subst

                                ( monoExpr, newSt ) =
                                    specializeExpr fieldExpr refinedSubst st
                            in
                            ( ( fieldName, monoExpr ) :: acc, newSt )
                        )
                        ( [], state )
                        fields
            in
            ( Mono.MonoRecordCreate monoFields monoType, stateAfter )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        TOpt.Tuple region a b rest meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV state subst canType)

                ( monoA, state1 ) =
                    specializeExpr a subst state

                ( monoB, state2 ) =
                    specializeExpr b subst state1

                ( monoRest, state3 ) =
                    specializeExprs rest subst state2

                allExprs =
                    monoA :: monoB :: monoRest
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
                    Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst st.ctx.mvarEnv subst accessorCanType))
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
                    monoType =
                        Mono.forceCNumberToInt (applySubstFV st subst localCanType)
                in
                ( LocalFunArg name localCanType :: accArgs
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

        TOpt.TrackedVarLocal _ name trackedLocalMeta ->
            let
                trackedLocalCanType =
                    trackedLocalMeta.tipe
            in
            if isLocalMultiTarget name st then
                let
                    monoType =
                        Mono.forceCNumberToInt (applySubstFV st subst trackedLocalCanType)
                in
                ( LocalFunArg name trackedLocalCanType :: accArgs
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

        TOpt.Call _ _ _ meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (applySubstFV st subst canType)
            in
            if Mono.containsCEcoMVar monoType then
                -- Inner call result is still polymorphic. Defer specialization
                -- until we know the outer callee's expected parameter type.
                ( PendingCall arg subst canType :: accArgs
                , monoType :: accTypes
                , st
                )

            else
                -- Fully monomorphic result — specialize immediately.
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst st
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
                        -- `Array Float` for `Array.foldl (+) 0.0 arr`). Without
                        -- preservation, CNumber defaults to MInt and `Basics.add`
                        -- gets specialised as `Int -> Int -> Int`.
                        monoType =
                            TypeSubst.applySubstKeepNumber st.ctx.mvarEnv subst canType
                    in
                    if Mono.containsAnyMVar monoType then
                        ( PendingGlobal arg subst canType :: accArgs
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
                Just (Mono.MFunction [ Mono.MRecord fields ] _) ->
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
                            Mono.MRecord fields

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType Nothing state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                Just (Mono.MRecord fields) ->
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
                            Mono.MRecord fields

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType Nothing state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash "Specialize.resolveProcessedArg: Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."

        PendingGlobal savedExpr savedSubst canType ->
            -- Deferred VarGlobal: polymorphic global that needed call-site context.
            -- Refine the substitution with the callee's parameter type, then specialize.
            let
                refinedSubst =
                    case maybeParamType of
                        Just paramType ->
                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType savedSubst)

                        Nothing ->
                            savedSubst
            in
            specializeExpr savedExpr refinedSubst state

        PendingCall savedExpr savedSubst canType ->
            -- Nested call used as argument. Now that we know the callee's
            -- expected parameter type, refine the substitution and specialize.
            let
                refinedSubst =
                    case maybeParamType of
                        Just paramType ->
                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType savedSubst)

                        Nothing ->
                            savedSubst
            in
            specializeExpr savedExpr refinedSubst state

        LocalFunArg name canType ->
            -- Let-bound function passed as argument. Use the callee's parameter type
            -- to refine the local's type and create a monomorphic instance.
            case maybeParamType of
                Just paramType ->
                    case paramType of
                        Mono.MFunction _ _ ->
                            let
                                refinedSubst =
                                    Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType subst)

                                funcMonoType =
                                    Mono.forceCNumberToInt
                                        (applySubstFV state refinedSubst canType)
                            in
                            if isLocalMultiTarget name state then
                                let
                                    ( freshName, state1 ) =
                                        getOrCreateLocalInstance
                                            name
                                            funcMonoType
                                            refinedSubst
                                            state
                                in
                                ( Mono.MonoVarLocal freshName funcMonoType, state1 )

                            else
                                ( Mono.MonoVarLocal name funcMonoType, state )

                        _ ->
                            let
                                monoType =
                                    Mono.forceCNumberToInt
                                        (applySubstFV state subst canType)
                            in
                            ( Mono.MonoVarLocal name monoType, state )

                Nothing ->
                    let
                        monoType =
                            Mono.forceCNumberToInt
                                (applySubstFV state subst canType)
                    in
                    ( Mono.MonoVarLocal name monoType, state )


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


{-| Specialize if-expression branches (condition-body pairs).
-}
specializeBranches :
    List ( TOpt.Expr MVarId, TOpt.Expr MVarId )
    -> Substitution
    -> MonoState
    -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )
specializeBranches branches subst state =
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
                            specializeExpr body subst st1WithResetVarTypes
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
            Mono.MFunction args result ->
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
                    { state | ctx = { ctx | varEnv = newVarEnv } }

                augmentedSubstRaw =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            Tuple.first (TypeSubst.unifyExtend state.ctx.mvarEnv canParamType monoParamType s)
                        )
                        subst
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
            Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv subst meta.tipe))
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
                        Mono.MRecord fields ->
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
                                ("Specialize.specializePath: Expected MRecord for field path but got: "
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
                Mono.MList elemType ->
                    if index == 0 then
                        -- Index 0 is head: returns the element type
                        elemType

                    else
                        -- Index 1 is tail: returns the list type itself
                        containerType

                _ ->
                    Utils.Crash.crash ("Specialize.computeIndexProjectionType: HintList at index " ++ String.fromInt index ++ " - Expected MList but got: " ++ Mono.monoTypeToDebugString containerType)

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
        Mono.MTuple elementTypes ->
            case List.drop index elementTypes of
                elemType :: _ ->
                    elemType

                [] ->
                    Utils.Crash.crash ("Specialize.computeTupleElementType: Tuple index " ++ String.fromInt index ++ " out of bounds for tuple with " ++ String.fromInt (List.length elementTypes) ++ " elements")

        _ ->
            Utils.Crash.crash ("Specialize.computeTupleElementType: Expected MTuple but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute field type from a custom type constructor at the given index.

This looks up the union definition to find the constructor's argument types,
then applies the type variable substitution based on the monomorphized type arguments.

-}
computeCustomFieldType : MVarEnv -> TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType
computeCustomFieldType mvarEnv globalTypeEnv ctorName index containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
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
                                    Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv1 typeVarSubst canArgTypeWithIds))

                                [] ->
                                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor arg index " ++ String.fromInt index ++ " out of bounds for " ++ ctorName)

        _ ->
            Utils.Crash.crash ("Specialize.computeCustomFieldType: Expected MCustom for ctor '" ++ ctorName ++ "' index " ++ String.fromInt index ++ " but got: " ++ Mono.monoTypeToDebugString containerType)


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
        Mono.MCustom moduleName typeName typeArgs ->
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
                                    Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv1 typeVarSubst canArgTypeWithIds))

                                _ ->
                                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-arg constructor but got " ++ String.fromInt (List.length ctorData.args) ++ " args for " ++ typeName)

                        _ ->
                            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-constructor type but got " ++ String.fromInt (List.length unionData.alts) ++ " constructors for " ++ typeName)

        _ ->
            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected MCustom but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute element type from an array access.
-}
computeArrayElementType : Mono.MonoType -> Mono.MonoType
computeArrayElementType containerType =
    case containerType of
        Mono.MCustom _ "Array" [ elemType ] ->
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
specializeDecider : Name -> TOpt.Decider (TOpt.Choice MVarId) -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider rootName decider subst state =
    case decider of
        TOpt.Leaf choice ->
            let
                ( monoChoice, stateAfter ) =
                    specializeChoice choice subst state
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
                    specializeDecider rootName success subst state

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
                    specializeDecider rootName failure subst state1WithResetVarEnv
            in
            ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path edges fallback ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoPath =
                    specializeDtPath state.ctx.mvarEnv rootName path state.ctx.varEnv state.ctx.globalTypeEnv

                ( monoEdges, state1 ) =
                    specializeEdges rootName edges subst state

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
                    specializeDecider rootName fallback subst state1WithResetVarEnv
            in
            ( Mono.FanOut monoPath monoEdges monoFallback, state2 )


specializeChoice : TOpt.Choice MVarId -> Substitution -> MonoState -> ( Mono.MonoChoice, MonoState )
specializeChoice choice subst state =
    case choice of
        TOpt.Inline expr ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.Inline monoExpr, stateAfter )

        TOpt.Jump index ->
            ( Mono.Jump index, state )


specializeEdges : Name -> List ( DT.Test, TOpt.Decider (TOpt.Choice MVarId) ) -> Substitution -> MonoState -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )
specializeEdges rootName edges subst state =
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
                            specializeDecider rootName decider subst stWithResetVarEnv
                    in
                    ( ( test, monoDecider ) :: acc, newSt )
                )
                ( [], state )
                edges
    in
    ( List.reverse revAcc, finalState )


specializeJumps : List ( Int, TOpt.Expr MVarId ) -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeJumps jumps subst state =
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

                        ( monoExpr, newSt ) =
                            specializeExpr expr subst stWithResetVarEnv
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
                (\( _, argType ) acc -> Mono.MFunction [ argType ] acc)
                (Mono.typeOf monoExpr)
                monoArgs


{-| Compute the result MonoType for a Call expression.

Interpret the call expression's canonical result type using only the callee's
call-site substitution from unifyCallSiteDirect. The caller's substitution is
not applied here — with globally unique MVarIds per scheme, the old
caller-first heuristic is no longer needed and can produce wrong results.

-}
callResultMonoType : MVarEnv -> Can.FreeVars -> Substitution -> Can.Type MVarId -> Mono.MonoType
callResultMonoType mvarEnv freeVars callSubst canType =
    Mono.forceCNumberToInt (TypeSubst.applySubstWithFreeVars mvarEnv freeVars callSubst canType)


{-| Specialize a function argument by applying type substitution.
-}
specializeArg : MVarEnv -> Substitution -> ( A.Located Name, Can.Type MVarId ) -> ( Name, Mono.MonoType )
specializeArg mvarEnv subst ( locName, canType ) =
    let
        name =
            A.toValue locName

        monoType =
            Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv subst canType))
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
            Mono.MFunction args result ->
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
        Mono.MVar _ _ ->
            False

        Mono.MList inner ->
            isFullyMonomorphicType inner

        Mono.MFunction args result ->
            List.all isFullyMonomorphicType args
                && isFullyMonomorphicType result

        Mono.MTuple elems ->
            List.all isFullyMonomorphicType elems

        Mono.MRecord fields ->
            Dict.foldl
                (\_ fieldType acc -> acc && isFullyMonomorphicType fieldType)
                True
                fields

        Mono.MCustom _ _ args ->
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
            Tuple.first (TypeSubst.applySubst mvarEnv callSubst canFuncType)

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
