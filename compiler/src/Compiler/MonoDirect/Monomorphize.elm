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

                prunedGraph =
                    Prune.pruneUnreachableSpecs globalTypeEnv rawGraph
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
            SolverSnapshot.withLocalUnification snapshot [] []
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

        patchedNodes =
            let
                base =
                    Array.repeat nextId Nothing
            in
            Dict.foldl
                (\specId node acc ->
                    let
                        isValueUsed =
                            BitSet.member specId valueUsedWithMain

                        keyHasCEcoMVar =
                            case Array.get specId state.registry.reverseMapping of
                                Just (Just ( _, keyType, _ )) ->
                                    Mono.containsCEcoMVar keyType

                                _ ->
                                    False

                        patched =
                            if isValueUsed then
                                if keyHasCEcoMVar then
                                    patchNodeTypesCEcoToErased node

                                else
                                    patchInternalExprCEcoToErased node

                            else
                                patchNodeTypesToErased node
                    in
                    Array.set specId (Just patched) acc
                )
                base
                state.nodes

        patchedRegistry =
            let
                oldReg =
                    state.registry

                newReverseMapping =
                    Array.indexedMap
                        (\specId entry ->
                            case entry of
                                Just ( global, _, maybeLambda ) ->
                                    case Array.get specId patchedNodes |> Maybe.andThen identity of
                                        Just patchedNode ->
                                            Just ( global, Mono.nodeType patchedNode, maybeLambda )

                                        Nothing ->
                                            entry

                                Nothing ->
                                    Nothing
                        )
                        oldReg.reverseMapping

                newMapping =
                    List.foldl
                        (\( specId, maybeEntry ) acc ->
                            case maybeEntry of
                                Just ( global, monoType, maybeLambda ) ->
                                    let
                                        key =
                                            Mono.toComparableSpecKey (Mono.SpecKey global monoType maybeLambda)
                                    in
                                    Dict.insert key specId acc

                                Nothing ->
                                    acc
                        )
                        Dict.empty
                        (Array.toIndexedList newReverseMapping)
            in
            { nextId = oldReg.nextId
            , mapping = newMapping
            , reverseMapping = newReverseMapping
            }

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
        { nodes = patchedNodes
        , registry = patchedRegistry
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



-- ========== TYPE ERASURE ==========


patchNodeTypesToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (mapExprTypes Mono.eraseTypeVarsToErased expr) (Mono.eraseTypeVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (List.map (\( n, pt ) -> ( n, Mono.eraseTypeVarsToErased pt )) params)
                (mapExprTypes Mono.eraseTypeVarsToErased expr)
                (Mono.eraseTypeVarsToErased t)

        _ ->
            node


patchNodeTypesCEcoToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesCEcoToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (mapExprTypes Mono.eraseCEcoVarsToErased expr) (Mono.eraseCEcoVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (List.map (\( n, pt ) -> ( n, Mono.eraseCEcoVarsToErased pt )) params)
                (mapExprTypes Mono.eraseCEcoVarsToErased expr)
                (Mono.eraseCEcoVarsToErased t)

        Mono.MonoCycle defs t ->
            Mono.MonoCycle
                (List.map (\( name, expr ) -> ( name, mapExprTypes Mono.eraseCEcoVarsToErased expr )) defs)
                (Mono.eraseCEcoVarsToErased t)

        _ ->
            node


patchInternalExprCEcoToErased : Mono.MonoNode -> Mono.MonoNode
patchInternalExprCEcoToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (mapExprTypes Mono.eraseCEcoVarsToErased expr) t

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc params (mapExprTypes Mono.eraseCEcoVarsToErased expr) t

        _ ->
            node


mapExprTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoExpr -> Mono.MonoExpr
mapExprTypes f =
    Traverse.mapExpr (mapOneExprType f)


mapOneExprType : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoExpr -> Mono.MonoExpr
mapOneExprType f expr =
    case expr of
        Mono.MonoLiteral lit t ->
            Mono.MonoLiteral lit (f t)

        Mono.MonoVarLocal name t ->
            Mono.MonoVarLocal name (f t)

        Mono.MonoVarGlobal region specId t ->
            Mono.MonoVarGlobal region specId (f t)

        Mono.MonoVarKernel region home name t ->
            Mono.MonoVarKernel region home name (f t)

        Mono.MonoList region items t ->
            Mono.MonoList region items (f t)

        Mono.MonoClosure info body t ->
            let
                newParams =
                    List.map (\( n, pt ) -> ( n, f pt )) info.params
            in
            Mono.MonoClosure { info | params = newParams } body (f t)

        Mono.MonoCall region func args t callInfo ->
            Mono.MonoCall region func args (f t) callInfo

        Mono.MonoTailCall name args t ->
            Mono.MonoTailCall name args (f t)

        Mono.MonoIf branches elseExpr t ->
            Mono.MonoIf branches elseExpr (f t)

        Mono.MonoLet def body t ->
            let
                newDef =
                    case def of
                        Mono.MonoDef n bound ->
                            Mono.MonoDef n bound

                        Mono.MonoTailDef n params bound ->
                            Mono.MonoTailDef n
                                (List.map (\( pn, pt ) -> ( pn, f pt )) params)
                                bound
            in
            Mono.MonoLet newDef body (f t)

        Mono.MonoDestruct destr inner t ->
            Mono.MonoDestruct (mapDestructorTypes f destr) inner (f t)

        Mono.MonoCase x y decider jumps t ->
            Mono.MonoCase x y decider jumps (f t)

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate fields (f t)

        Mono.MonoRecordAccess inner field t ->
            Mono.MonoRecordAccess inner field (f t)

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate record updates (f t)

        Mono.MonoTupleCreate region elems t ->
            Mono.MonoTupleCreate region elems (f t)

        Mono.MonoUnit ->
            Mono.MonoUnit


mapDestructorTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoDestructor -> Mono.MonoDestructor
mapDestructorTypes f (Mono.MonoDestructor name path pathType) =
    Mono.MonoDestructor name (mapPathTypes f path) (f pathType)


mapPathTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoPath -> Mono.MonoPath
mapPathTypes f path =
    case path of
        Mono.MonoIndex idx kind t inner ->
            Mono.MonoIndex idx kind (f t) (mapPathTypes f inner)

        Mono.MonoField name t inner ->
            Mono.MonoField name (f t) (mapPathTypes f inner)

        Mono.MonoUnbox t inner ->
            Mono.MonoUnbox (f t) (mapPathTypes f inner)

        Mono.MonoRoot name t ->
            Mono.MonoRoot name (f t)
