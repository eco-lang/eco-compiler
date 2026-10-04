module Compiler.Monomorphize.Monomorphize exposing
    ( monomorphize
    , monomorphizeWithLimits, monomorphizeWithLimitsAssigned
    )

{-| This module transforms a TypedOptimized.GlobalGraph into a Monomorphized.MonoGraph
by specializing all polymorphic functions to their concrete type instantiations.

The monomorphization algorithm works as follows:

1.  Find the entry point (main function).
2.  Use a worklist to process each (Global, MonoType, Maybe LambdaId) specialization.
3.  For each work item, specialize the TOpt.Node Name into a MonoNode by:
    a. Unifying the polymorphic type with the concrete type to get a substitution.
    b. Applying the substitution to all types in the expression.
    c. Discovering new specializations needed and adding them to the worklist.
4.  Continue until the worklist is empty.


# Monomorphization

@docs monomorphize
@docs monomorphizeWithLimits, monomorphizeWithLimitsAssigned

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.Specialize as Specialize
import Compiler.Monomorphize.State as State exposing (WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Data.Map as DMap
import Dict
import Utils.Crash



-- ========== STATE ==========


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
type alias MonoState =
    State.MonoState



-- ========== ENTRY POINT ==========


{-| Transform a typed optimized graph using a custom entry point name.

This is useful for testing when the entry point is not named "main".

MONO\_030: this wrapper runs with the default spec watchdogs; the Builder
calls `monomorphizeWithLimits` with the env-overridable config limits.

-}
monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize =
    monomorphizeWithLimits Config.defaultLimits


{-| `monomorphize` with explicit MONO\_030 spec watchdogs. Enforcement is
drain-level (per work item — `processWorklistPure`): the guarded pathology is
growth ACROSS items (each spec enqueueing a bigger-typed successor —
polymorphic recursion through annotated mutual cycles is legal Elm, see
`plans/monomorphization-plan.md` §3's correction note), so catching it one
item late changes nothing, and the existing `Result String` driver channel
carries the error with no threading through `Specialize`'s internals.
-}
monomorphizeWithLimits : Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphizeWithLimits limits entryPointName globalTypeEnv globalGraph =
    -- Phase 5 (flags) + Phase 0 (MVarId assignment) both live in
    -- `EntryPrep.assign`: the flags decoder is synthesized BEFORE assignment so
    -- it is rewritten along with everything else. The decoder spec is
    -- registered at startup by the generated preamble via
    -- Elm_Kernel_Platform_registerFlagsDecoder; initWorker runs it against the
    -- host-supplied flags JSON. This engine assigns with `( False, False )` —
    -- changing those flags would move its output.
    monomorphizeWithLimitsAssigned limits
        entryPointName
        globalTypeEnv
        (EntryPrep.assign ( False, False ) entryPointName globalGraph)


{-| `monomorphizeWithLimits` on a graph that has ALREADY been through
`AssignMVarIds` — the entry the Builder uses, because the pre-mono passes
(`plans/pre-mono-lss-transforms.md`) run on the assigned graph. The Name-typed
entry above is a wrapper, so every existing caller and test is unchanged.
-}
monomorphizeWithLimitsAssigned : Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String Mono.MonoGraph
monomorphizeWithLimitsAssigned limits entryPointName globalTypeEnv assigned =
    let
        (TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _ _) =
            assigned.graph

        mvarEnv =
            State.initMVarEnv assigned.mvarState.nextId assigned.mvarState.superVars
    in
    case EntryPrep.findEntryPointId entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntryWith limits assigned.flagsGlobal mainGlobal mainType globalTypeEnv nodesWithIds annotationsWithIds mvarEnv


monomorphizeFromEntryWith : Config.SpecLimits -> Maybe TOpt.Global -> TOpt.Global -> Can.Type TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> State.MVarEnv -> Result String Mono.MonoGraph
monomorphizeFromEntryWith limits maybeFlagsGlobal mainGlobal mainType globalTypeEnv nodes annotations mvarEnv =
    let
        ( stateWithMain, mainSpecIdVal ) =
            initSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv

        -- Phase 5: enqueue the flags-decoder spec alongside main. Its
        -- MonoType comes from the synthetic node's own (concrete)
        -- annotation; the worklist driver specializes it like any global.
        ( stateInit, flagsDecoderSpecId ) =
            case maybeFlagsGlobal of
                Nothing ->
                    ( stateWithMain, Nothing )

                Just flagsGlobal ->
                    case EntryPrep.findNodeAnnotationType flagsGlobal nodes of
                        Nothing ->
                            ( stateWithMain, Nothing )

                        Just decoderTipe ->
                            let
                                decoderMonoType =
                                    entryPointMonoType Dict.empty decoderTipe

                                accum =
                                    stateWithMain.accum

                                ( specId, registry2 ) =
                                    Registry.getOrCreateSpecId (toptGlobalToMono flagsGlobal) decoderMonoType accum.registry
                            in
                            ( { stateWithMain
                                | accum =
                                    { accum
                                        | registry = registry2
                                        , worklist = SpecializeGlobal specId :: accum.worklist
                                        , scheduled = BitSet.insertGrowing specId accum.scheduled
                                    }
                              }
                            , Just specId
                            )

        result =
            processWorklistPure limits stateInit
    in
    case result of
        Err msg ->
            Err msg

        Ok finalState ->
            let
                rawGraph =
                    assembleRawGraphFrom finalState.accum finalState.ctx.lambdaCounter mainSpecIdVal flagsDecoderSpecId

                -- Prune AND close residual number vars in one fused pass (Q3, perf): Prune
                -- discharges `MVar _ CNumber` → MInt (consulting the FINAL superVars so
                -- Join-R-tainted vars heal) as it copies live nodes and recomputes
                -- ctorShapes, so no separate whole-graph closing pass is needed.
                prunedGraph =
                    Prune.pruneUnreachableSpecs finalState.ctx.mvarEnv finalState.ctx.globalTypeEnv rawGraph
            in
            Ok prunedGraph


{-| Shared initialization for the specialization worklist.
-}
initSpecialization : TOpt.Global -> Can.Type TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> State.MVarEnv -> ( MonoState, Mono.SpecId )
initSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv =
    let
        mainMonoType : Mono.MonoType
        mainMonoType =
            entryPointMonoType Dict.empty mainType

        currentModule : ModuleName.Canonical
        currentModule =
            case mainGlobal of
                TOpt.Global canonical _ ->
                    canonical

        initialState : MonoState
        initialState =
            initState currentModule nodes annotations globalTypeEnv mvarEnv

        initialAccum =
            initialState.accum

        ( mainSpecIdVal, registryWithMain ) =
            Registry.getOrCreateSpecId (toptGlobalToMono mainGlobal) mainMonoType initialAccum.registry

        stateWithMain : MonoState
        stateWithMain =
            { initialState
                | accum =
                    { initialAccum
                        | registry = registryWithMain
                        , worklist = [ SpecializeGlobal mainSpecIdVal ]
                        , scheduled = BitSet.insertGrowing mainSpecIdVal initialAccum.scheduled
                    }
            }
    in
    ( stateWithMain, mainSpecIdVal )


{-| Phase 2: Assemble the raw MonoGraph from the final specialization state.

Performs MVar erasure, registry patching, and graph construction.

-}
assembleRawGraphFrom : State.SpecAccum -> Int -> Mono.SpecId -> Maybe Mono.SpecId -> Mono.MonoGraph
assembleRawGraphFrom finalAccum lambdaCounter mainSpecIdVal flagsDecoderSpecId =
    let
        mainInfo : Maybe Mono.MainInfo
        mainInfo =
            Just (Mono.StaticMain mainSpecIdVal)

        nextId : Int
        nextId =
            finalAccum.registry.nextId

        -- Store nodes directly — already an Array (Maybe MonoNode).
        -- Pad to nextId length if needed so downstream consumers see a full-size array.
        nodesArray : Array.Array (Maybe Mono.MonoNode)
        nodesArray =
            let
                currentLen =
                    Array.length finalAccum.nodes
            in
            if currentLen >= nextId then
                finalAccum.nodes

            else
                Array.append finalAccum.nodes (Array.repeat (nextId - currentLen) Nothing)

        -- Compute callEdges, specHasEffects, specValueUsed from the nodes dict.
        -- These were previously accumulated during the worklist but are deferred
        -- here to reduce per-iteration allocation pressure.
        ( callEdgesArray, specHasEffects, specValueUsed ) =
            let
                baseEdges =
                    Array.repeat nextId Nothing
            in
            Array.foldl
                (\maybeNode ( specId, ( edgesAcc, effectsAcc, valueUsedAcc ) ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, ( edgesAcc, effectsAcc, valueUsedAcc ) )

                        Just node ->
                            let
                                neighbors =
                                    collectCallsFromNode node

                                newEdges =
                                    Array.set specId (Just neighbors) edgesAcc

                                newEffects =
                                    if nodeHasEffects node then
                                        BitSet.insertGrowing specId effectsAcc

                                    else
                                        effectsAcc

                                newValueUsed =
                                    List.foldl
                                        (\calleeId acc -> BitSet.insertGrowing calleeId acc)
                                        valueUsedAcc
                                        neighbors
                            in
                            ( specId + 1, ( newEdges, newEffects, newValueUsed ) )
                )
                ( 0, ( baseEdges, BitSet.empty, BitSet.empty ) )
                nodesArray
                |> Tuple.second

        -- Mark the main entry point as value-used
        valueUsedWithMain : BitSet.BitSet
        valueUsedWithMain =
            BitSet.insertGrowing mainSpecIdVal specValueUsed
    in
    Mono.MonoGraph
        { nodes = nodesArray
        , registry = { nextId = finalAccum.registry.nextId, mapping = Mono.specKeyMapEmpty, reverseMapping = finalAccum.registry.reverseMapping, countByGlobal = Dict.empty }
        , main = mainInfo
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = specHasEffects
        , specValueUsed = valueUsedWithMain
        , ports = finalAccum.ports
        , flagsDecoder = flagsDecoderSpecId
        , lssMemberOrigins = Dict.empty -- subst engine: all-LTop, no LSS members
        , lssMemberKinds = Dict.empty -- subst engine: no LSS members
        , lssBlockedMembers = Dict.empty -- subst engine: no μ-tie (LSS_018 is solver-only)
        }



-- ========== INITIALIZATION ==========


{-| Initialize the monomorphization state.
-}
initState : ModuleName.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> State.MVarEnv -> MonoState
initState =
    State.initState



-- ========== WORKLIST PROCESSING ==========


{-| Process all pending specializations until the worklist is empty (pure).

MONO\_030 (subst arm): after each item, validate the specs CREATED during it —
fold `reverseMapping[prevNextId .. nextId)` against the breadth and key-size
limits. Per-item granularity is sufficient (the pathology is growth across
items) and keeps the checks out of `Specialize`'s pure tuple plumbing. The
error text is `Registry`'s shared formatter — identical to the solver's
`LimitExceeded` presentation.

-}
processWorklistPure : Config.SpecLimits -> MonoState -> Result String MonoState
processWorklistPure limits state =
    case state.accum.worklist of
        [] ->
            Ok state

        (SpecializeGlobal specId) :: rest ->
            let
                prevNextId =
                    state.accum.registry.nextId

                state1 =
                    processOneWorkItem specId rest state
            in
            case checkNewSpecs limits prevNextId state1.accum.registry of
                Just err ->
                    Err err

                Nothing ->
                    processWorklistPure limits state1


{-| Validate registry entries `[from .. registry.nextId)` against the
MONO\_030 limits. `Nothing` = all fine. A limit of 0 disables its check.
-}
checkNewSpecs : Config.SpecLimits -> Int -> Mono.SpecializationRegistry -> Maybe String
checkNewSpecs limits from registry =
    if limits.specBreadth <= 0 && limits.specTypeNodes <= 0 then
        Nothing

    else if from >= registry.nextId then
        Nothing

    else
        case Array.get from registry.reverseMapping |> Maybe.andThen identity of
            Nothing ->
                checkNewSpecs limits (from + 1) registry

            Just ( global, monoType ) ->
                let
                    count =
                        Registry.createdCount global registry
                in
                if limits.specBreadth > 0 && count > limits.specBreadth then
                    Just (Registry.breadthLimitMessage global count limits.specBreadth)

                else if limits.specTypeNodes > 0 && not (Mono.typeNodesWithin limits.specTypeNodes monoType) then
                    Just (Registry.typeNodesLimitMessage global limits.specTypeNodes)

                else
                    checkNewSpecs limits (from + 1) registry


{-| Process a single work item from the worklist.
-}
processOneWorkItem : Mono.SpecId -> List WorkItem -> MonoState -> MonoState
processOneWorkItem specId rest state =
    let
        accum =
            state.accum
    in
    if BitSet.member specId accum.inProgress then
        -- Skip to avoid infinite recursion when specializing recursive functions.
        { state | accum = { accum | worklist = rest } }

    else
        case Registry.lookupSpecKey specId accum.registry of
            Nothing ->
                -- Should not happen if registry/worklist invariants hold
                { state | accum = { accum | worklist = rest } }

            Just ( global, monoType ) ->
                let
                    ctx =
                        state.ctx

                    freeVars =
                        case global of
                            Mono.Global canonical name ->
                                case DMap.get TOpt.toComparableGlobal (TOpt.Global canonical name) ctx.annotations of
                                    Just (Can.Forall fv _) ->
                                        fv

                                    Nothing ->
                                        Dict.empty

                            Mono.Accessor _ ->
                                Dict.empty

                    -- Clear varEnv when starting a new function specialization
                    -- because we're entering a new scope with different local variables
                    state2 =
                        { accum =
                            { accum
                                | worklist = rest
                                , inProgress = BitSet.insertGrowing specId accum.inProgress
                            }
                        , ctx =
                            { ctx
                                | currentGlobal = Just global
                                , currentFreeVars = freeVars
                                , varEnv = State.emptyVarEnv
                            }
                        }
                in
                case global of
                    Mono.Accessor fieldName ->
                        -- Handle accessor specialization
                        let
                            ( monoNode, stateAfter ) =
                                specializeAccessorGlobal fieldName monoType state2

                            stateAfterAccum =
                                stateAfter.accum
                        in
                        { stateAfter
                            | accum =
                                { stateAfterAccum
                                    | nodes = arraySetGrowing specId (Just monoNode) stateAfterAccum.nodes
                                    , inProgress = BitSet.removeGrowing specId stateAfterAccum.inProgress
                                }
                            , ctx =
                                let
                                    ca =
                                        stateAfter.ctx
                                in
                                { ca | currentGlobal = Nothing }
                        }

                    Mono.Global _ name ->
                        -- Existing logic with monoGlobalToTOpt and toptNodes lookup
                        let
                            toptGlobal =
                                monoGlobalToTOpt global
                        in
                        case DMap.get TOpt.toComparableGlobal toptGlobal state2.ctx.toptNodes of
                            Nothing ->
                                -- External or missing definition; treat as extern.
                                let
                                    s2accum =
                                        state2.accum
                                in
                                { state2
                                    | accum =
                                        { s2accum
                                            | nodes = arraySetGrowing specId (Just (Mono.MonoExtern monoType)) s2accum.nodes
                                            , inProgress = BitSet.removeGrowing specId s2accum.inProgress
                                        }
                                    , ctx =
                                        let
                                            c2 =
                                                state2.ctx
                                        in
                                        { c2 | currentGlobal = Nothing }
                                }

                            Just toptNode ->
                                -- Specialize this node to concrete types.
                                let
                                    ( monoNode0, stateAfter ) =
                                        Specialize.specializeNode name toptNode monoType state2

                                    ( monoNode, newLambdaCounter ) =
                                        ResolveAccessorValues.rewriteNode
                                            stateAfter.ctx.currentModule
                                            stateAfter.ctx.lambdaCounter
                                            monoNode0

                                    stateAfterCtx =
                                        stateAfter.ctx

                                    saAccum =
                                        stateAfter.accum

                                    actualType =
                                        Mono.nodeType monoNode

                                    updatedRegistry =
                                        Registry.updateRegistryType specId actualType saAccum.registry
                                in
                                { stateAfter
                                    | accum =
                                        { saAccum
                                            | registry = updatedRegistry
                                            , nodes = arraySetGrowing specId (Just monoNode) saAccum.nodes
                                            , inProgress = BitSet.removeGrowing specId saAccum.inProgress
                                        }
                                    , ctx =
                                        { stateAfterCtx
                                            | lambdaCounter = newLambdaCounter
                                            , currentGlobal = Nothing
                                        }
                                }


specializeAccessorGlobal : Name -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeAccessorGlobal fieldName monoType state =
    case monoType of
        Mono.MFunction _ _ [ Mono.MRecord _ fields ] fieldType ->
            let
                recordType =
                    Mono.mRecord fields

                paramName =
                    "record"

                bodyExpr =
                    Mono.MonoRecordAccess
                        (Mono.MonoVarLocal paramName recordType)
                        fieldName
                        fieldType
            in
            ( Mono.MonoTailFunc [ ( paramName, recordType ) ] bodyExpr monoType, state )

        _ ->
            Utils.Crash.crash "Monomorphize" "specializeAccessorGlobal" "Expected Mono.mFunction [Mono.mRecord ...] fieldType"


{-| Substitution mapping MVarIds to their concrete monomorphic types.
-}
type alias Substitution =
    State.Substitution


entryPointMonoType : Substitution -> Can.Type TypeIds.MVarId -> Mono.MonoType
entryPointMonoType subst canType =
    -- Use a dummy MVarEnv for the entry point type conversion (no fresh allocations needed)
    TypeSubst.applySubstPure (State.initMVarEnv TypeIds.firstMVarId Dict.empty) subst canType



-- ========== ARRAY HELPERS ==========


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
        -- Grow array to accommodate index, then set
        Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))



-- ========== LAYOUT HELPERS ==========
-- ========== KERNEL ABI TYPE DERIVATION ==========
-- ========== GLOBAL CONVERSIONS ==========


{-| Convert a typed optimized global reference to a monomorphized global reference.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


{-| Convert a monomorphized global reference to a typed optimized global reference.
-}
monoGlobalToTOpt : Mono.Global -> TOpt.Global
monoGlobalToTOpt global =
    case global of
        Mono.Global canonical name ->
            TOpt.Global canonical name

        Mono.Accessor _ ->
            Utils.Crash.crash "Monomorphize" "monoGlobalToTOpt" "Accessor should be handled before calling monoGlobalToTOpt"



-- ========== CTOR LAYOUT COMPUTATION ==========
-- Moved to Compiler.Monomorphize.Analysis (computeCtorShapesForGraph, buildCompleteCtorShapes, buildCtorShapeFromUnion)
-- ========== CALL EDGE COLLECTION ==========


extractSpecId : Mono.MonoExpr -> List Int -> List Int
extractSpecId expr acc =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            specId :: acc

        _ ->
            acc


collectCalls : Mono.MonoExpr -> List Int
collectCalls =
    Traverse.foldExpr extractSpecId []


collectCallsFromNode : Mono.MonoNode -> List Int
collectCallsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            collectCalls expr

        Mono.MonoTailFunc _ expr _ ->
            collectCalls expr

        Mono.MonoPortIncoming expr _ ->
            collectCalls expr

        Mono.MonoPortOutgoing expr _ ->
            collectCalls expr

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []



-- ========== EFFECT DETECTION ==========


{-| Determine if a MonoNode's body references Debug.\* kernels (binding-time effects).
-}
nodeHasEffects : Mono.MonoNode -> Bool
nodeHasEffects node =
    let
        checkExpr expr acc =
            if acc then
                True

            else
                case expr of
                    Mono.MonoVarKernel _ _ "Debug" _ _ ->
                        True

                    _ ->
                        False
    in
    case node of
        Mono.MonoDefine expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoTailFunc _ expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoPortIncoming expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoPortOutgoing expr _ ->
            Traverse.foldExpr checkExpr False expr

        _ ->
            False
