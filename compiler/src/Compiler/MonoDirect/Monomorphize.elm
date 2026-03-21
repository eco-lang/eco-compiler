module Compiler.MonoDirect.Monomorphize exposing (monomorphizeDirect)

{-| Solver-directed monomorphization entry point.

This module provides `monomorphizeDirect`, which uses the solver snapshot
for type resolution instead of TypeSubst string-based substitution.

This is a test-only module — not wired into the production pipeline.

@docs monomorphizeDirect

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Compiler.MonoDirect.JoinpointFlatten as JoinpointFlatten
import Compiler.MonoDirect.Specialize as Specialize
import Compiler.MonoDirect.State as State exposing (MonoDirectState, WorkItem(..))
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverSnapshot)
import Data.Map as DMap
import Dict
import System.TypeCheck.IO as IO
import Utils.Crash


{-| Monomorphize a global graph using solver-directed type resolution.
-}
monomorphizeDirect :
    Name
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot
    -> TOpt.GlobalGraph
    -> Result String Mono.MonoGraph
monomorphizeDirect entryPointName globalTypeEnv snapshot (TOpt.GlobalGraph nodes _ _) =
    case findEntryPoint entryPointName nodes of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainNode ) ->
            let
                mainMonoType =
                    resolveMainType snapshot mainNode

                ( finalState, mainSpecId ) =
                    runSpecialization mainGlobal mainMonoType globalTypeEnv snapshot nodes

                rawGraph =
                    assembleRawGraph finalState mainSpecId

                flattenedGraph =
                    JoinpointFlatten.flattenGraphJoinpoints rawGraph

                prunedGraph =
                    Prune.pruneUnreachableSpecs globalTypeEnv flattenedGraph
            in
            Ok prunedGraph



-- ========== ENTRY POINT FINDING ==========


findEntryPoint : Name -> DMap.Dict (List String) TOpt.Global TOpt.Node -> Maybe ( TOpt.Global, TOpt.Node )
findEntryPoint entryPointName nodes =
    DMap.foldl TOpt.compareGlobal
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case ( global, node ) of
                        ( TOpt.Global _ name, TOpt.Define _ _ _ ) ->
                            if name == entryPointName then
                                Just ( global, node )

                            else
                                Nothing

                        ( TOpt.Global _ name, TOpt.TrackedDefine _ _ _ _ ) ->
                            if name == entryPointName then
                                Just ( global, node )

                            else
                                Nothing

                        _ ->
                            Nothing
        )
        Nothing
        nodes


{-| Resolve the main function's MonoType from solver state.
-}
resolveMainType : SolverSnapshot -> TOpt.Node -> Mono.MonoType
resolveMainType snapshot node =
    case nodeMetaTvar node of
        Just tvar ->
            SolverSnapshot.withLocalUnification snapshot
                []
                []
                (\view -> Mono.forceCNumberToInt (view.monoTypeOf tvar))

        Nothing ->
            Utils.Crash.crash "MonoDirect.resolveMainType: main node has no tvar"


nodeMetaTvar : TOpt.Node -> Maybe IO.Variable
nodeMetaTvar node =
    case node of
        TOpt.Define _ _ meta ->
            meta.tvar

        TOpt.TrackedDefine _ _ _ meta ->
            meta.tvar

        TOpt.PortIncoming _ _ meta ->
            meta.tvar

        TOpt.PortOutgoing _ _ meta ->
            meta.tvar

        _ ->
            Nothing


nodeCanType : TOpt.Node -> Can.Type
nodeCanType node =
    case node of
        TOpt.Define _ _ meta ->
            meta.tipe

        TOpt.TrackedDefine _ _ _ meta ->
            meta.tipe

        TOpt.PortIncoming _ _ meta ->
            meta.tipe

        TOpt.PortOutgoing _ _ meta ->
            meta.tipe

        TOpt.Ctor _ _ tipe ->
            tipe

        TOpt.Enum _ tipe ->
            tipe

        TOpt.Box tipe ->
            tipe

        _ ->
            Can.TUnit



-- ========== SPECIALIZATION ==========


runSpecialization :
    TOpt.Global
    -> Mono.MonoType
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot
    -> DMap.Dict (List String) TOpt.Global TOpt.Node
    -> ( MonoDirectState, Mono.SpecId )
runSpecialization mainGlobal mainMonoType globalTypeEnv snapshot nodes =
    let
        currentModule =
            case mainGlobal of
                TOpt.Global canonical _ ->
                    canonical

        initialState =
            State.initState currentModule nodes globalTypeEnv snapshot

        ( mainSpecId, registryWithMain ) =
            Registry.getOrCreateSpecId (toptGlobalToMono mainGlobal) mainMonoType Nothing initialState.registry

        stateWithMain =
            { initialState
                | registry = registryWithMain
                , worklist = [ SpecializeGlobal mainSpecId ]
                , scheduled = BitSet.insertGrowing mainSpecId initialState.scheduled
            }
    in
    ( processWorklist snapshot stateWithMain, mainSpecId )


processWorklist : SolverSnapshot -> MonoDirectState -> MonoDirectState
processWorklist snapshot state =
    case state.worklist of
        [] ->
            state

        (SpecializeGlobal specId) :: rest ->
            if BitSet.member specId state.inProgress then
                processWorklist snapshot { state | worklist = rest }

            else
                case Registry.lookupSpecKey specId state.registry of
                    Nothing ->
                        processWorklist snapshot { state | worklist = rest }

                    Just ( global, monoType, _ ) ->
                        let
                            state2 =
                                { state
                                    | worklist = rest
                                    , inProgress = BitSet.insertGrowing specId state.inProgress
                                    , currentGlobal = Just global
                                    , varEnv = State.emptyVarEnv
                                }
                        in
                        case global of
                            Mono.Accessor fieldName ->
                                let
                                    ( monoNode, stateAfter ) =
                                        specializeAccessorGlobal fieldName monoType state2
                                in
                                processWorklist snapshot (finalizeSpec specId monoNode stateAfter)

                            Mono.Global _ name ->
                                let
                                    toptGlobal =
                                        monoGlobalToTOpt global
                                in
                                case DMap.get TOpt.toComparableGlobal toptGlobal state2.toptNodes of
                                    Nothing ->
                                        processWorklist snapshot (finalizeExtern specId monoType state2)

                                    Just toptNode ->
                                        let
                                            ( monoNode, stateAfter ) =
                                                Specialize.specializeNode snapshot name toptNode monoType state2
                                        in
                                        processWorklist snapshot (finalizeSpec specId monoNode stateAfter)


finalizeSpec : Mono.SpecId -> Mono.MonoNode -> MonoDirectState -> MonoDirectState
finalizeSpec specId monoNode state =
    let
        actualType =
            Mono.nodeType monoNode

        updatedRegistry =
            Registry.updateRegistryType specId actualType state.registry

        neighbors =
            collectCallsFromNode monoNode

        specValueUsed1 =
            List.foldl
                (\calleeId acc -> BitSet.insertGrowing calleeId acc)
                state.specValueUsed
                neighbors

        effectsHere =
            nodeHasEffects monoNode
    in
    { state
        | registry = updatedRegistry
        , nodes = Dict.insert specId monoNode state.nodes
        , inProgress = BitSet.removeGrowing specId state.inProgress
        , callEdges = Dict.insert specId neighbors state.callEdges
        , specHasEffects =
            if effectsHere then
                BitSet.insertGrowing specId state.specHasEffects

            else
                state.specHasEffects
        , specValueUsed = specValueUsed1
        , currentGlobal = Nothing
    }


finalizeExtern : Mono.SpecId -> Mono.MonoType -> MonoDirectState -> MonoDirectState
finalizeExtern specId monoType state =
    { state
        | nodes = Dict.insert specId (Mono.MonoExtern monoType) state.nodes
        , inProgress = BitSet.removeGrowing specId state.inProgress
        , callEdges = Dict.insert specId [] state.callEdges
        , currentGlobal = Nothing
    }


specializeAccessorGlobal : Name -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
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
            Utils.Crash.crash "MonoDirect.specializeAccessorGlobal: expected MFunction [MRecord] fieldType"



-- ========== GRAPH ASSEMBLY ==========


assembleRawGraph : MonoDirectState -> Mono.SpecId -> Mono.MonoGraph
assembleRawGraph state mainSpecId =
    let
        mainInfo =
            Just (Mono.StaticMain mainSpecId)

        valueUsedWithMain =
            BitSet.insertGrowing mainSpecId state.specValueUsed

        nextId =
            state.registry.nextId

        -- Store nodes directly — no erasure pass needed.
        -- Remaining MVar _ CEcoValue compile identically to eco.value in codegen.
        nodesArray =
            let
                base =
                    Array.repeat nextId Nothing
            in
            Dict.foldl
                (\specId node acc -> Array.set specId (Just node) acc)
                base
                state.nodes

        callEdgesArray =
            let
                base =
                    Array.repeat nextId Nothing
            in
            Dict.foldl
                (\specId edges acc -> Array.set specId (Just edges) acc)
                base
                state.callEdges
    in
    Mono.MonoGraph
        { nodes = nodesArray
        , registry = { nextId = state.registry.nextId, mapping = Dict.empty, reverseMapping = state.registry.reverseMapping }
        , main = mainInfo
        , ctorShapes = Dict.empty
        , nextLambdaIndex = state.lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = state.specHasEffects
        , specValueUsed = valueUsedWithMain
        }



-- ========== GLOBAL CONVERSIONS ==========


toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


monoGlobalToTOpt : Mono.Global -> TOpt.Global
monoGlobalToTOpt global =
    case global of
        Mono.Global canonical name ->
            TOpt.Global canonical name

        Mono.Accessor _ ->
            Utils.Crash.crash "MonoDirect.monoGlobalToTOpt: Accessor"



-- ========== CALL EDGE COLLECTION ==========


extractSpecId : Mono.MonoExpr -> List Int -> List Int
extractSpecId expr acc =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            specId :: acc

        _ ->
            acc


collectCallsFromNode : Mono.MonoNode -> List Int
collectCallsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            Traverse.foldExpr extractSpecId [] expr

        Mono.MonoTailFunc _ expr _ ->
            Traverse.foldExpr extractSpecId [] expr

        Mono.MonoPortIncoming expr _ ->
            Traverse.foldExpr extractSpecId [] expr

        Mono.MonoPortOutgoing expr _ ->
            Traverse.foldExpr extractSpecId [] expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, expr ) -> Traverse.foldExpr extractSpecId [] expr) defs

        _ ->
            []



-- ========== EFFECT DETECTION ==========


nodeHasEffects : Mono.MonoNode -> Bool
nodeHasEffects node =
    let
        checkExpr expr acc =
            if acc then
                True

            else
                case expr of
                    Mono.MonoVarKernel _ "Debug" _ _ ->
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

        Mono.MonoCycle defs _ ->
            List.any (\( _, expr ) -> Traverse.foldExpr checkExpr False expr) defs

        _ ->
            False
