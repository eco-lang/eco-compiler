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

        -- Key-type-aware erasure of remaining MVars:
        -- 1. Dead-value specs (not value-used): erase ALL MVars to MErased
        -- 2. Value-used specs with polymorphic key type: erase only CEcoValue MVars
        --    (phantom type variables never constrained by any call site)
        -- 3. Value-used specs with monomorphic key type: leave unchanged
        --    (any remaining MVars are real specialization bugs caught by MONO_021)
        nextId : Int
        nextId =
            finalAccum.registry.nextId

        patchedNodes : Array.Array (Maybe Mono.MonoNode)
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
                            case Array.get specId finalAccum.registry.reverseMapping of
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
                finalAccum.nodes

        -- Patch registry reverseMapping + rebuild mapping to maintain MONO_017
        patchedRegistry : Mono.SpecializationRegistry
        patchedRegistry =
            let
                oldReg =
                    finalAccum.registry

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
        { nodes = patchedNodes
        , registry = patchedRegistry
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



-- ========== DEAD-VALUE SPEC TYPE ERASURE ==========


{-| Erase type variables in dead-value specialization nodes.

For specs whose value is never used (not referenced via MonoVarGlobal),
replace MVar with MErased in both node-level types and expression-level
type annotations. Only patches MonoDefine and MonoTailFunc; cycles, ports,
externs, and managers are left unchanged.

-}
patchNodeTypesToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine
                (eraseExprTypeVars expr)
                (Mono.eraseTypeVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (eraseParamTypes Mono.eraseTypeVarsToErasedHelp params)
                (eraseExprTypeVars expr)
                (Mono.eraseTypeVarsToErased t)

        -- Do NOT patch: cycles (preserve MONO_021 visibility), ports (ABI obligations),
        -- externs/managers (kernel ABI), ctors/enums (no MVars in practice)
        _ ->
            node


{-| Erase only CEcoValue MVar type variables in value-used specialization nodes
whose key type is still polymorphic.

These are phantom type variables that were never constrained by any call site.
CNumber MVars are preserved to avoid hiding numeric specialization bugs.
Patches MonoDefine, MonoTailFunc, and MonoCycle nodes.

-}
patchNodeTypesCEcoToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesCEcoToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine
                (eraseExprCEcoVars expr)
                (Mono.eraseCEcoVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (eraseParamTypes Mono.eraseCEcoVarsToErasedHelp params)
                (eraseExprCEcoVars expr)
                (Mono.eraseCEcoVarsToErased t)

        Mono.MonoCycle defs t ->
            Mono.MonoCycle
                (List.map (\( name, expr ) -> ( name, eraseExprCEcoVars expr )) defs)
                (Mono.eraseCEcoVarsToErased t)

        -- Do NOT patch: ports (ABI obligations), externs/managers (kernel ABI),
        -- ctors/enums (no MVars in practice). Cycles are only patched when their
        -- key type still contains CEcoValue MVars (see key-type-aware gating in
        -- monomorphizeFromEntry).
        _ ->
            node


patchInternalExprCEcoToErased : Mono.MonoNode -> Mono.MonoNode
patchInternalExprCEcoToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (eraseExprCEcoVars expr) t

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc params (eraseExprCEcoVars expr) t

        _ ->
            node


{-| Erase types in a parameter list using a changed-flag erasure function.
Returns the original list when no types changed.
-}
eraseParamTypes : (Mono.MonoType -> ( Bool, Mono.MonoType )) -> List ( Name, Mono.MonoType ) -> List ( Name, Mono.MonoType )
eraseParamTypes eraseHelp params =
    let
        ( changed, newParams ) =
            Mono.listMapChanged
                (\( n, ty ) ->
                    let
                        ( c, newTy ) =
                            eraseHelp ty
                    in
                    if c then
                        ( True, ( n, newTy ) )

                    else
                        ( False, ( n, ty ) )
                )
                params
    in
    if changed then
        newParams

    else
        params


{-| Apply a type transformation to all type annotations in an expression tree.

Uses MonoTraverse.mapExpr to bottom-up rewrite every expression node,
applying the given type transformation to each type annotation.

-}
mapExprTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoExpr -> Mono.MonoExpr
mapExprTypes f =
    Traverse.mapExpr (mapOneExprType f)


{-| Apply a type transformation to a single expression node (children already processed).
-}
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


{-| Erase all MVar type annotations inside an expression tree.

Uses mapExprTypes with Mono.eraseTypeVarsToErased to replace all MVars with MErased.

-}
eraseExprTypeVars : Mono.MonoExpr -> Mono.MonoExpr
eraseExprTypeVars =
    mapExprTypes Mono.eraseTypeVarsToErased


{-| Erase only CEcoValue MVar type annotations inside an expression tree.

Uses mapExprTypes with Mono.eraseCEcoVarsToErased to replace only CEcoValue MVars
with MErased, leaving CNumber MVars intact.

-}
eraseExprCEcoVars : Mono.MonoExpr -> Mono.MonoExpr
eraseExprCEcoVars =
    mapExprTypes Mono.eraseCEcoVarsToErased


{-| Apply a type transformation to types inside a MonoDestructor.
-}
mapDestructorTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoDestructor -> Mono.MonoDestructor
mapDestructorTypes f (Mono.MonoDestructor name path pathType) =
    Mono.MonoDestructor name (mapPathTypes f path) (f pathType)


{-| Apply a type transformation to types inside a MonoPath.
-}
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
