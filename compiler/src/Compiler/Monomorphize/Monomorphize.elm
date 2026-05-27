module Compiler.Monomorphize.Monomorphize exposing (monomorphize)

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

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.Specialize as Specialize
import Compiler.Monomorphize.State as State exposing (WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Data.Map as DMap
import Dict
import Set
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== STATE ==========


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
type alias MonoState =
    State.MonoState



-- ========== ENTRY POINT ==========


{-| Transform a typed optimized graph using a custom entry point name.

This is useful for testing when the entry point is not named "main".

-}
monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize entryPointName globalTypeEnv globalGraph =
    let
        -- Phase 0: Assign globally unique MVarIds to all type variables
        ( TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _, mvarState ) =
            AssignMVarIds.assignIds globalGraph

        mvarEnv =
            State.initMVarEnv mvarState.nextId mvarState.numberVars
    in
    case findEntryPointId entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntry mainGlobal mainType globalTypeEnv nodesWithIds annotationsWithIds mvarEnv


{-| Perform monomorphization from a given entry point.
-}
monomorphizeFromEntry : TOpt.Global -> Can.Type TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> State.MVarEnv -> Result String Mono.MonoGraph
monomorphizeFromEntry mainGlobal mainType globalTypeEnv nodes annotations mvarEnv =
    let
        ( finalState, mainSpecIdVal ) =
            runSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv

        rawGraph =
            assembleRawGraph finalState mainSpecIdVal

        prunedGraph =
            Prune.pruneUnreachableSpecs finalState.ctx.globalTypeEnv rawGraph
    in
    Ok prunedGraph


{-| Phase 1: Run the specialization worklist to completion (pure).
-}
runSpecialization : TOpt.Global -> Can.Type TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> State.MVarEnv -> ( MonoState, Mono.SpecId )
runSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv =
    let
        ( stateWithMain, mainSpecIdVal ) =
            initSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv

        finalState =
            processWorklistPure stateWithMain
    in
    ( finalState, mainSpecIdVal )


{-| Shared initialization for the specialization worklist.
-}
initSpecialization : TOpt.Global -> Can.Type TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> State.MVarEnv -> ( MonoState, Mono.SpecId )
initSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv =
    let
        mainMonoType : Mono.MonoType
        mainMonoType =
            canTypeToMonoType Dict.empty mainType

        currentModule : IO.Canonical
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
            Registry.getOrCreateSpecId (toptGlobalToMono mainGlobal) mainMonoType Nothing initialAccum.registry

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
assembleRawGraph : MonoState -> Mono.SpecId -> Mono.MonoGraph
assembleRawGraph finalState mainSpecIdVal =
    assembleRawGraphFrom finalState.accum finalState.ctx.lambdaCounter mainSpecIdVal


assembleRawGraphFrom : State.SpecAccum -> Int -> Mono.SpecId -> Mono.MonoGraph
assembleRawGraphFrom finalAccum lambdaCounter mainSpecIdVal =
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
        , registry = { nextId = finalAccum.registry.nextId, mapping = Dict.empty, reverseMapping = finalAccum.registry.reverseMapping }
        , main = mainInfo
        , ctorShapes = Dict.empty
        , nextLambdaIndex = lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = specHasEffects
        , specValueUsed = valueUsedWithMain
        }



-- ========== INITIALIZATION ==========


{-| Initialize the monomorphization state.
-}
initState : IO.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> State.MVarEnv -> MonoState
initState =
    State.initState


{-| Find an entry point by name in the ID-rewritten global graph.
-}
findEntryPointId : Name -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> Maybe ( TOpt.Global, Can.Type TypeIds.MVarId )
findEntryPointId entryPointName nodes =
    DMap.foldl TOpt.compareGlobal
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case ( global, node ) of
                        ( TOpt.Global _ name, TOpt.Define _ _ meta ) ->
                            if name == entryPointName then
                                Just ( global, meta.tipe )

                            else
                                Nothing

                        ( TOpt.Global _ name, TOpt.TrackedDefine _ _ _ meta ) ->
                            if name == entryPointName then
                                Just ( global, meta.tipe )

                            else
                                Nothing

                        _ ->
                            Nothing
        )
        Nothing
        nodes



-- ========== WORKLIST PROCESSING ==========


{-| Process all pending specializations until the worklist is empty (pure).
-}
processWorklistPure : MonoState -> MonoState
processWorklistPure state =
    case state.accum.worklist of
        [] ->
            state

        (SpecializeGlobal specId) :: rest ->
            processWorklistPure (processOneWorkItem specId rest state)


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

            Just ( global, monoType, _ ) ->
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
        Mono.MFunction [ Mono.MRecord fields ] fieldType ->
            let
                recordType =
                    Mono.MRecord fields

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
            Utils.Crash.crash "Monomorphize" "specializeAccessorGlobal" "Expected MFunction [MRecord ...] fieldType"


{-| Substitution mapping MVarIds to their concrete monomorphic types.
-}
type alias Substitution =
    State.Substitution


canTypeToMonoType : Substitution -> Can.Type TypeIds.MVarId -> Mono.MonoType
canTypeToMonoType subst canType =
    -- Use a dummy MVarEnv for the entry point type conversion (no fresh allocations needed)
    Tuple.first (TypeSubst.canTypeToMonoType (State.initMVarEnv TypeIds.firstMVarId Set.empty) subst canType)



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
