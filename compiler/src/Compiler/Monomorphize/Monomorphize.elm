module Compiler.Monomorphize.Monomorphize exposing (monomorphize, monomorphizeWithLog)

{-| This module transforms a TypedOptimized.GlobalGraph into a Monomorphized.MonoGraph
by specializing all polymorphic functions to their concrete type instantiations.

The monomorphization algorithm works as follows:

1.  Find the entry point (main function).
2.  Use a worklist to process each (Global, MonoType, Maybe LambdaId) specialization.
3.  For each work item, specialize the TOpt.Node into a MonoNode by:
    a. Unifying the polymorphic type with the concrete type to get a substitution.
    b. Applying the substitution to all types in the expression.
    c. Discovering new specializations needed and adding them to the worklist.
4.  Continue until the worklist is empty.


# Monomorphization

@docs monomorphize, monomorphizeWithLog

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.Specialize as Specialize
import Compiler.Monomorphize.State as State exposing (WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Data.Map as DMap
import Dict
import System.TypeCheck.IO as IO
import Task exposing (Task)
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
monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphize entryPointName globalTypeEnv (TOpt.GlobalGraph nodes _ _) =
    case findEntryPoint entryPointName nodes of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntry mainGlobal mainType globalTypeEnv nodes


{-| Perform monomorphization from a given entry point.
-}
monomorphizeFromEntry : TOpt.Global -> Can.Type -> TypeEnv.GlobalTypeEnv -> DMap.Dict (List String) TOpt.Global TOpt.Node -> Result String Mono.MonoGraph
monomorphizeFromEntry mainGlobal mainType globalTypeEnv nodes =
    let
        ( finalState, mainSpecIdVal ) =
            runSpecialization mainGlobal mainType globalTypeEnv nodes

        rawGraph =
            assembleRawGraph finalState mainSpecIdVal

        prunedGraph =
            Prune.pruneUnreachableSpecs finalState.ctx.globalTypeEnv rawGraph
    in
    Ok prunedGraph


{-| Like monomorphize, but logs each sub-pass via the provided logger.
-}
monomorphizeWithLog : (String -> Task x ()) -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph -> Task x (Result String Mono.MonoGraph)
monomorphizeWithLog log entryPointName globalTypeEnv (TOpt.GlobalGraph nodes _ _) =
    case findEntryPoint entryPointName nodes of
        Nothing ->
            Task.succeed (Err ("No " ++ entryPointName ++ " function found"))

        Just ( mainGlobal, mainType ) ->
            log "  Specialization (worklist)..."
                |> Task.andThen
                    (\_ ->
                        let
                            ( finalState, mainSpecIdVal ) =
                                runSpecialization mainGlobal mainType globalTypeEnv nodes
                        in
                        log "  Type patching + graph assembly..."
                            |> Task.andThen
                                (\_ ->
                                    let
                                        rawGraph =
                                            assembleRawGraph finalState mainSpecIdVal
                                    in
                                    log "  Pruning unreachable specs..."
                                        |> Task.map
                                            (\_ ->
                                                Ok (Prune.pruneUnreachableSpecs finalState.ctx.globalTypeEnv rawGraph)
                                            )
                                )
                    )


{-| Phase 1: Run the specialization worklist to completion.
-}
runSpecialization : TOpt.Global -> Can.Type -> TypeEnv.GlobalTypeEnv -> DMap.Dict (List String) TOpt.Global TOpt.Node -> ( MonoState, Mono.SpecId )
runSpecialization mainGlobal mainType globalTypeEnv nodes =
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
            initState currentModule nodes globalTypeEnv

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

        finalState : MonoState
        finalState =
            processWorklist stateWithMain
    in
    ( finalState, mainSpecIdVal )


{-| Phase 2: Assemble the raw MonoGraph from the final specialization state.

Performs MVar erasure, registry patching, and graph construction.

-}
assembleRawGraph : MonoState -> Mono.SpecId -> Mono.MonoGraph
assembleRawGraph finalState mainSpecIdVal =
    let
        finalAccum =
            finalState.accum

        -- Note: The callable top-level invariant is enforced by GlobalOpt via ensureCallableForNode.
        mainInfo : Maybe Mono.MainInfo
        mainInfo =
            Just (Mono.StaticMain mainSpecIdVal)

        -- Mark the main entry point as value-used
        valueUsedWithMain : BitSet.BitSet
        valueUsedWithMain =
            BitSet.insertGrowing mainSpecIdVal finalAccum.specValueUsed

        nextId : Int
        nextId =
            finalAccum.registry.nextId

        -- Store nodes directly — no erasure pass needed.
        -- Remaining MVar _ CEcoValue compile identically to eco.value in codegen.
        nodesArray : Array.Array (Maybe Mono.MonoNode)
        nodesArray =
            let
                base =
                    Array.repeat nextId Nothing
            in
            Dict.foldl
                (\specId node acc -> Array.set specId (Just node) acc)
                base
                finalAccum.nodes

        callEdgesArray : Array.Array (Maybe (List Int))
        callEdgesArray =
            let
                base =
                    Array.repeat nextId Nothing
            in
            Dict.foldl
                (\specId edges acc -> Array.set specId (Just edges) acc)
                base
                finalAccum.callEdges
    in
    Mono.MonoGraph
        { nodes = nodesArray
        , registry = finalAccum.registry
        , main = mainInfo
        , ctorShapes = Dict.empty
        , nextLambdaIndex = finalState.ctx.lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = finalAccum.specHasEffects
        , specValueUsed = valueUsedWithMain
        }



-- ========== INITIALIZATION ==========


{-| Initialize the monomorphization state with empty worklist and registry.
-}
initState : IO.Canonical -> DMap.Dict (List String) TOpt.Global TOpt.Node -> TypeEnv.GlobalTypeEnv -> MonoState
initState =
    State.initState


{-| Find an entry point by name in the global graph.
-}
findEntryPoint : Name -> DMap.Dict (List String) TOpt.Global TOpt.Node -> Maybe ( TOpt.Global, Can.Type )
findEntryPoint entryPointName nodes =
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


{-| Process all pending specializations until the worklist is empty.
-}
processWorklist : MonoState -> MonoState
processWorklist state =
    case state.accum.worklist of
        [] ->
            state

        (SpecializeGlobal specId) :: rest ->
            let
                accum =
                    state.accum
            in
            if BitSet.member specId accum.inProgress then
                -- Skip to avoid infinite recursion when specializing recursive functions.
                processWorklist { state | accum = { accum | worklist = rest } }

            else
                case Registry.lookupSpecKey specId accum.registry of
                    Nothing ->
                        -- Should not happen if registry/worklist invariants hold
                        processWorklist { state | accum = { accum | worklist = rest } }

                    Just ( global, monoType, _ ) ->
                        let
                            ctx =
                                state.ctx

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

                                    neighbors =
                                        collectCallsFromNode monoNode

                                    specValueUsed1 =
                                        List.foldl
                                            (\calleeId acc -> BitSet.insertGrowing calleeId acc)
                                            stateAfterAccum.specValueUsed
                                            neighbors

                                    -- Accessors are always pure, no specHasEffects update needed
                                    newState =
                                        { stateAfter
                                            | accum =
                                                { stateAfterAccum
                                                    | nodes = Dict.insert specId monoNode stateAfterAccum.nodes
                                                    , inProgress = BitSet.removeGrowing specId stateAfterAccum.inProgress
                                                    , callEdges = Dict.insert specId neighbors stateAfterAccum.callEdges
                                                    , specValueUsed = specValueUsed1
                                                }
                                            , ctx = let ca = stateAfter.ctx in { ca | currentGlobal = Nothing }
                                        }
                                in
                                processWorklist newState

                            Mono.Global _ name ->
                                -- Existing logic with monoGlobalToTOpt and toptNodes lookup
                                let
                                    toptGlobal =
                                        monoGlobalToTOpt global
                                in
                                case DMap.get TOpt.toComparableGlobal toptGlobal state2.ctx.toptNodes of
                                    Nothing ->
                                        -- External or missing definition; treat as extern.
                                        -- Externs are effect-free and have no callees.
                                        let
                                            s2accum =
                                                state2.accum

                                            newState =
                                                { state2
                                                    | accum =
                                                        { s2accum
                                                            | nodes = Dict.insert specId (Mono.MonoExtern monoType) s2accum.nodes
                                                            , inProgress = BitSet.removeGrowing specId s2accum.inProgress
                                                            , callEdges = Dict.insert specId [] s2accum.callEdges
                                                        }
                                                    , ctx = let c2 = state2.ctx in { c2 | currentGlobal = Nothing }
                                                }
                                        in
                                        processWorklist newState

                                    Just toptNode ->
                                        -- Specialize this node to concrete types.
                                        -- Pass the global's name for constructor name population.
                                        let
                                            ( monoNode, stateAfter ) =
                                                Specialize.specializeNode name toptNode monoType state2

                                            saAccum =
                                                stateAfter.accum

                                            -- Update registry with actual node type (may differ from requested type
                                            -- due to closure flattening, e.g., Int -> Int -> Int vs (Int, Int) -> Int)
                                            actualType =
                                                Mono.nodeType monoNode

                                            updatedRegistry =
                                                Registry.updateRegistryType specId actualType saAccum.registry

                                            neighbors =
                                                collectCallsFromNode monoNode

                                            effectsHere =
                                                nodeHasEffects monoNode

                                            specValueUsed1 =
                                                List.foldl
                                                    (\calleeId acc -> BitSet.insertGrowing calleeId acc)
                                                    saAccum.specValueUsed
                                                    neighbors

                                            newState =
                                                { stateAfter
                                                    | accum =
                                                        { saAccum
                                                            | registry = updatedRegistry
                                                            , nodes = Dict.insert specId monoNode saAccum.nodes
                                                            , inProgress = BitSet.removeGrowing specId saAccum.inProgress
                                                            , callEdges = Dict.insert specId neighbors saAccum.callEdges
                                                            , specHasEffects =
                                                                if effectsHere then
                                                                    BitSet.insertGrowing specId saAccum.specHasEffects

                                                                else
                                                                    saAccum.specHasEffects
                                                            , specValueUsed = specValueUsed1
                                                        }
                                                    , ctx = let ca2 = stateAfter.ctx in { ca2 | currentGlobal = Nothing }
                                                }
                                        in
                                        processWorklist newState


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


{-| Substitution mapping type variable names to their concrete monomorphic types.
-}
type alias Substitution =
    State.Substitution


canTypeToMonoType : Substitution -> Can.Type -> Mono.MonoType
canTypeToMonoType =
    TypeSubst.canTypeToMonoType



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

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, expr ) -> collectCalls expr) defs

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






