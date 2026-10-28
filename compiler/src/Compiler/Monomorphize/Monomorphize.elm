module Compiler.Monomorphize.Monomorphize exposing
    ( monomorphize
    , monomorphizeWithLimits, monomorphizeWithLimitsAssigned
    )

{-| Code generation needs every function at one concrete type, and Elm code is
polymorphic, so this module turns a typed optimized graph into a monomorphized
graph in which each polymorphic definition appears once per type it is used at.
It is the driver of the substitution engine, one of the compiler's two
monomorphizers.

A _specialization_ (spec) is one global at one `MonoType`. The registry gives
each spec a `SpecId`, and the graph's nodes are indexed by it. The _worklist_
is the stack of `SpecializeGlobal` items still to build, each naming a `SpecId`.
It starts with the entry point and, when the entry is a `Program`, the
synthetic flags-decoder global. One item is taken from the front at a time and
handed to `Compiler.Monomorphize.Specialize`, which builds its node and pushes
an item for every spec the body refers to that has not been scheduled before.
Draining stops when the worklist is empty.

Because annotated mutually recursive functions may recurse at ever larger types,
which is legal Elm, the number and size of specs can grow without bound. After
each item the specs it created are checked against `Config.SpecLimits`, and the
first one over a limit ends the run with an `Err`. One item may create several
specs past a limit before the check runs; the `Err` names the first of them.

When the worklist is empty the nodes are assembled into a `MonoGraph`, with its
call edges, effect set and value-used set computed from the bodies, and
`Compiler.Monomorphize.Prune` then removes unreachable specs and closes
residual number type variables.


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
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
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


{-| The substitution engine's state while the worklist drains, as
`Compiler.Monomorphize.State` defines it.
-}
type alias MonoState =
    State.MonoState


{-| Monomorphizes `globalGraph` from the definition named by the first argument,
using `Config.defaultLimits` as the spec limits.

Returns `Err` when no `Define` or `TrackedDefine` of that name exists or a
spec limit is exceeded.

-}
monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize =
    monomorphizeWithLimits Config.defaultLimits


{-| Monomorphizes as `monomorphize` does, under the given spec limits.

It first assigns type-variable ids with `EntryPrep.assign ( False, False )`,
which also synthesizes the flags decoder.

-}
monomorphizeWithLimits : Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphizeWithLimits limits entryPointName globalTypeEnv globalGraph =
    monomorphizeWithLimitsAssigned limits
        entryPointName
        globalTypeEnv
        (EntryPrep.assign ( False, False ) entryPointName globalGraph)


{-| Monomorphizes as `monomorphizeWithLimits` does, on a graph that has
already been through `EntryPrep.assign`.

Returns `Err ("No " ++ name ++ " function found")` when the graph has no
`Define` or `TrackedDefine` of that name.

-}
monomorphizeWithLimitsAssigned : Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String Mono.MonoGraph
monomorphizeWithLimitsAssigned limits entryPointName globalTypeEnv assigned =
    let
        (TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _ _) =
            assigned.graph

        mvarEnv =
            State.initMVarEnv assigned.mvarState.nextId assigned.mvarState.superVars
    in
    case EntryPrep.findEntryPointId assigned.entryHome entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntryWith limits assigned.flagsGlobal mainGlobal mainType globalTypeEnv nodesWithIds annotationsWithIds mvarEnv


{-| Seeds the worklist with `mainGlobal` and, when given and annotated, the
flags-decoder global, drains it, and returns the assembled and pruned graph.

Both seeded specs get their `MonoType` from their annotation with no
substitution, so a type variable left in either stays a variable. They are
created before draining starts and are never checked against the limits.

-}
monomorphizeFromEntryWith : Config.SpecLimits -> Maybe TOpt.Global -> TOpt.Global -> Can.Type TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> State.MVarEnv -> Result String Mono.MonoGraph
monomorphizeFromEntryWith limits maybeFlagsGlobal mainGlobal mainType globalTypeEnv nodes annotations mvarEnv =
    let
        ( stateWithMain, mainSpecIdVal ) =
            initSpecialization mainGlobal mainType globalTypeEnv nodes annotations mvarEnv

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

                -- Prune also closes residual number variables, using the final MVarEnv.
                prunedGraph =
                    Prune.pruneUnreachableSpecs finalState.ctx.mvarEnv finalState.ctx.globalTypeEnv rawGraph
            in
            Ok prunedGraph


{-| Creates the initial state with the spec for `mainGlobal` at its annotated
type registered, scheduled and alone on the worklist, and returns that spec's id.
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


{-| Builds the unpruned `MonoGraph` from the drained state.

The node array is padded with `Nothing` up to the registry's `nextId`. A spec's
call edges are every `SpecId` its body refers to through `MonoVarGlobal`, and
the value-used set is all of those plus `mainSpecIdVal`. A spec is in the
effect set only when its body refers to a `Debug` kernel. The registry keeps
only `reverseMapping`: the forward `mapping` and `countByGlobal` are emptied.
`ctorShapes` and the LSS fields are left empty, since this engine computes no
LSS members.

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
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        }


{-| Creates the empty state for a run whose entry is in the given module.
-}
initState : ModuleName.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> State.MVarEnv -> MonoState
initState =
    State.initState


{-| Processes work items until the worklist is empty, returning the final state.

After each item the specs it created are checked against `limits`, and the
first violation is returned as `Err` with `Registry`'s limit message.

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


{-| Returns the message for the first spec with id from `from` up to the
registry's `nextId` that breaks a limit, or `Nothing` if none does.

The breadth limit bounds how many specs have been created for one global, and
the type-node limit bounds the size of a spec's type. A limit of zero or less
disables its check.

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


{-| Removes the item for `specId` from the worklist (`rest` is what remains)
and stores the spec's node.

A record accessor gets a one-parameter function projecting the field, a global
with no definition in the graph becomes `MonoExtern`, and any other global is
specialized by `Specialize.specializeNode` with accessor values then resolved.
For a node other than a constructor, the registry's type for the spec is
replaced with the node's own type. An id with no registry entry is dropped
without a node.

-}
processOneWorkItem : Mono.SpecId -> List WorkItem -> MonoState -> MonoState
processOneWorkItem specId rest state =
    let
        accum =
            state.accum
    in
    if BitSet.member specId accum.inProgress then
        -- Never taken in practice: inProgress is cleared before this function
        -- returns, and Specialize schedules an id at most once.
        { state | accum = { accum | worklist = rest } }

    else
        case Registry.lookupSpecKey specId accum.registry of
            Nothing ->
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
                        let
                            toptGlobal =
                                monoGlobalToTOpt global
                        in
                        case DMap.get TOpt.toComparableGlobal toptGlobal state2.ctx.toptNodes of
                            Nothing ->
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

                                    -- A constructor keeps the function type it was
                                    -- requested at; its node holds the constructed type.
                                    updatedRegistry =
                                        case monoNode of
                                            Mono.MonoCtor _ _ ->
                                                saAccum.registry

                                            _ ->
                                                Registry.updateRegistryType specId (Mono.nodeType monoNode) saAccum.registry
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


{-| Builds the node for the accessor `.fieldName` at `monoType`: a
`MonoTailFunc` taking a parameter `record` and returning its field. The state
is returned unchanged.

Crashes unless `monoType` is a function of one record argument.

-}
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


{-| A substitution from type-variable ids to `MonoType`s, as
`Compiler.Monomorphize.State` defines it.
-}
type alias Substitution =
    State.Substitution


{-| Returns the `MonoType` of a seeded spec's annotation under `subst`.

The conversion uses a fresh `MVarEnv` with no constraint information, so a
variable not bound by `subst` stays a variable.

-}
entryPointMonoType : Substitution -> Can.Type TypeIds.MVarId -> Mono.MonoType
entryPointMonoType subst canType =
    TypeSubst.applySubstPure (State.initMVarEnv TypeIds.firstMVarId Dict.empty) subst canType


{-| Returns `arr` with `value` at `index`, first padding it with `Nothing` when
it is too short.
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


{-| Returns the monomorphized reference to the same global.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


{-| Returns the typed optimized reference to the same global. Crashes on a
record accessor, which has no typed optimized counterpart.
-}
monoGlobalToTOpt : Mono.Global -> TOpt.Global
monoGlobalToTOpt global =
    case global of
        Mono.Global canonical name ->
            TOpt.Global canonical name

        Mono.Accessor _ ->
            Utils.Crash.crash "Monomorphize" "monoGlobalToTOpt" "Accessor should be handled before calling monoGlobalToTOpt"


{-| Adds the `SpecId` to `acc` when `expr` is a `MonoVarGlobal`.
-}
extractSpecId : Mono.MonoExpr -> List Int -> List Int
extractSpecId expr acc =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            specId :: acc

        _ ->
            acc


{-| Returns the `SpecId` of every `MonoVarGlobal` in `expr`, with repeats.
-}
collectCalls : Mono.MonoExpr -> List Int
collectCalls =
    Traverse.foldExpr extractSpecId []


{-| Returns the `SpecId`s a node's body refers to; a node with no body refers to none.
-}
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


{-| Tells whether the node's body refers to a kernel of the `Debug` module.
Other kernels are not considered.
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
