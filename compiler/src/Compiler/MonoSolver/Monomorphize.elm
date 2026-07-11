module Compiler.MonoSolver.Monomorphize exposing (monomorphize, monomorphizeWithReport)

{-| The solver-based monomorphizer (Architecture C) — a drop-in replacement for
`Compiler.Monomorphize.Monomorphize`, using the type checker's real HM
unification engine (`Compiler.Type.Unify` / `UnionFind`) instead of the
Dict-substitution engine.

**No fallback.** This engine never consults the original one. A construct it
cannot yet handle returns `Err "MonoSolver.unsupported: <what>"` through the
normal `Result String MonoGraph` channel, which the pipeline surfaces as a loud
build failure. It must NOT import `Compiler.Monomorphize.TypeSubst` or
`.Specialize`, and works only from the total `meta.tipe` (never `meta.tvar`).

The driver mirrors the original phase-for-phase: shared input prep (flags
decoder, MVarId assignment), seed main + flags decoder, LIFO worklist drain, then
assemble and hand off to the shared `Prune.pruneUnreachableSpecs` (which closes
residual number vars and recomputes ctor shapes). Only the per-node
specialization is the new solver engine.

@docs monomorphize

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), S, WorkItem(..))
import Compiler.MonoSolver.Translate as Translate
import Compiler.MonoSolver.Zonk as Zonk
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO


{-| Transform a typed optimized graph into a monomorphized graph, entering from
the named entry point. Same as the original engine plus the LSS knobs (the
original engine never computes sets; `lss.enabled = False` here is
byte-identical to it).
-}
monomorphize : Config.LssConfig -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize lssConfig entryPointName globalTypeEnv globalGraph =
    Result.map Tuple.first (monomorphizeWithReport lssConfig entryPointName globalTypeEnv globalGraph)


{-| `monomorphize` additionally returning the rendered LSS census
(`Just` iff `lss.report`). The report rides the result because this function
is pure and `compiler/src` cannot use `Debug.toString` — the census is plain
string concatenation, printed to stderr by the Builder.
-}
monomorphizeWithReport : Config.LssConfig -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeWithReport lssConfig entryPointName globalTypeEnv globalGraph =
    let
        ( graphWithFlags, maybeFlagsGlobal ) =
            EntryPrep.insertFlagsDecoderNode entryPointName globalGraph

        ( TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _ _, mvarState ) =
            AssignMVarIds.assignIds graphWithFlags
    in
    case EntryPrep.findEntryPointId entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            let
                mainHome : IO.Canonical
                mainHome =
                    case mainGlobal of
                        TOpt.Global home _ ->
                            home

                s0 : S
                s0 =
                    initState lssConfig mainHome nodesWithIds annotationsWithIds globalTypeEnv mvarState

                -- Entry seeding uses an EMPTY super table (matching the original
                -- engine's `entryPointMonoType Dict.empty`).
                mainMonoType : Mono.MonoType
                mainMonoType =
                    Zonk.canTypeToMono Dict.empty mainType

                ( mainSpecId, s1 ) =
                    seedSpec (toptToMonoGlobal mainGlobal) mainMonoType s0

                ( maybeFlagsSpecId, s2 ) =
                    seedFlagsDecoder maybeFlagsGlobal nodesWithIds s1
            in
            case drain s2 of
                Err failure ->
                    Err (renderFailure failure)

                Ok sFinal ->
                    let
                        graph =
                            pruneGraph sFinal (assembleRawGraph sFinal mainSpecId maybeFlagsSpecId)

                        report =
                            if lssConfig.report then
                                Just (renderLssReport sFinal graph)

                            else
                                Nothing
                    in
                    Ok ( graph, report )


{-| The LSS census (design §8.6): member counts, set-size histogram, widening
events by cause, signature memo stats, and the top per-global spec counts.
Rendered post-prune; plain string concatenation only.
-}
renderLssReport : S -> Mono.MonoGraph -> String
renderLssReport sFinal (Mono.MonoGraph g) =
    let
        stats =
            sFinal.lssStats

        lambdaCount =
            Dict.size sFinal.env.lamLabels

        internedCount =
            Dict.size sFinal.lssMembers

        sigCount =
            Dict.size sFinal.lssSignatures

        trivialCount =
            Dict.foldl
                (\_ sig n ->
                    if sig.trivial then
                        n + 1

                    else
                        n
                )
                0
                sFinal.lssSignatures

        histLine =
            if Dict.isEmpty stats.sizeHist then
                "(none)"

            else
                String.join " "
                    (Dict.foldr (\size count acc -> (String.fromInt size ++ "->" ++ String.fromInt count) :: acc) [] stats.sizeHist)

        specCounts =
            Array.foldl
                (\maybeEntry acc ->
                    case maybeEntry of
                        Just ( global, _ ) ->
                            let
                                k =
                                    Mono.toComparableGlobal global
                            in
                            Dict.insert k (1 + Maybe.withDefault 0 (Dict.get k acc)) acc

                        Nothing ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        topSpecs =
            Dict.toList specCounts
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 5
                |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                |> String.join " "
    in
    String.join "\n"
        [ "=== LSS census ==="
        , "members: " ++ String.fromInt sFinal.nextMemberId ++ " total (" ++ String.fromInt lambdaCount ++ " source lambdas, " ++ String.fromInt internedCount ++ " interned)"
        , "signatures: " ++ String.fromInt sigCount ++ " memoized (" ++ String.fromInt trivialCount ++ " trivial)"
        , "sets zonked: " ++ String.fromInt stats.setsZonked ++ "; size histogram: " ++ histLine
        , "widened: bySize=" ++ String.fromInt stats.widenedBySize ++ " byKernel=" ++ String.fromInt stats.widenedByKernel ++ " byBudget=" ++ String.fromInt stats.widenedByBudget
        , "top specs/global: " ++ topSpecs
        , "=================="
        ]



-- ====== INITIAL STATE ======


initState : Config.LssConfig -> IO.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> AssignMVarIds.GlobalMVarState -> S
initState lssConfig currentModule nodes annotations globalTypeEnv mvarState =
    { worklist = []
    , nodes = Array.empty
    , inProgress = BitSet.empty
    , scheduled = BitSet.empty
    , registry = Registry.emptyRegistry
    , ports = []
    , lambdaCounter = 0
    , superTable = mvarState.superVars
    , nextMVarId = mvarState.nextId
    , lssSignatures = Dict.empty
    , lssInProgress = Dict.empty
    , lssMembers = Dict.empty
    , nextMemberId = Id.toComparable mvarState.nextLam
    , lssStats = Engine.emptyLssStats
    , schemeMono = Dict.empty
    , kernelAbiMono = Dict.empty
    , callMemo = Dict.empty
    , nodeResolution = Dict.empty
    , env =
        { toptNodes = nodes
        , annotations = annotations
        , globalTypeEnv = globalTypeEnv
        , currentModule = currentModule
        , superStatic = mvarState.superVars
        , lss = lssConfig
        , lamLabels = mvarState.lamLabels
        }
    , currentGlobal = Nothing
    , store = Engine.freshStore
    , memo = Dict.empty
    , revMemo = Array.empty
    , varEnv = Dict.empty
    , numberMulti = []
    , localMulti = []
    , derivedDestructors = Dict.empty
    , localCanTypes = Dict.empty
    , lssRootAnn = Nothing
    , dirtySpecs = BitSet.empty
    , specCountByGlobal = Dict.empty
    }


seedSpec : Mono.Global -> Mono.MonoType -> S -> ( Mono.SpecId, S )
seedSpec global monoType s =
    let
        ( specId, reg1 ) =
            Registry.getOrCreateSpecId global monoType s.registry
    in
    ( specId
    , { s
        | registry = reg1
        , worklist = SpecializeGlobal specId :: s.worklist
        , scheduled = BitSet.insertGrowing specId s.scheduled
      }
    )


seedFlagsDecoder : Maybe TOpt.Global -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> S -> ( Maybe Mono.SpecId, S )
seedFlagsDecoder maybeFlagsGlobal nodes s =
    case maybeFlagsGlobal of
        Nothing ->
            ( Nothing, s )

        Just flagsGlobal ->
            case EntryPrep.findNodeAnnotationType flagsGlobal nodes of
                Nothing ->
                    ( Nothing, s )

                Just decoderTipe ->
                    let
                        decoderMonoType =
                            Zonk.canTypeToMono Dict.empty decoderTipe

                        ( specId, s1 ) =
                            seedSpec (toptToMonoGlobal flagsGlobal) decoderMonoType s
                    in
                    ( Just specId, s1 )



-- ====== WORKLIST DRAIN ======


drain : S -> Result Failure S
drain s =
    case s.worklist of
        [] ->
            Ok s

        (SpecializeGlobal specId) :: rest ->
            case processItem specId { s | worklist = rest } of
                Err e ->
                    Err e

                Ok s1 ->
                    drain s1


processItem : Mono.SpecId -> S -> Result Failure S
processItem specId s =
    if BitSet.member specId s.inProgress then
        -- Recursive self-reference: already being specialized; drop.
        Ok s

    else if nodeAlreadyDone specId s && not (BitSet.member specId s.dirtySpecs) then
        -- Stale duplicate work item: a LSS_010 re-push already satisfied by a
        -- later (re-)translation, or a duplicate re-push. Flag-off never
        -- reaches this (each spec is pushed exactly once).
        Ok s

    else
        case Registry.lookupSpecKey specId s.registry of
            Nothing ->
                Ok s

            Just ( global, monoType ) ->
                let
                    sItem =
                        Engine.resetItem
                            { s
                                | inProgress = BitSet.insertGrowing specId s.inProgress
                                , currentGlobal = Just global

                                -- LSS_010: consume the dirty mark before
                                -- translating with the (joined) stored type; a
                                -- join arriving DURING this translation re-marks
                                -- it and finishNode re-pushes.
                                , dirtySpecs = BitSet.removeGrowing specId s.dirtySpecs
                            }
                in
                case global of
                    Mono.Accessor fieldName ->
                        case monoType of
                            Mono.MFunction _ [ Mono.MRecord fields ] fieldType ->
                                Ok
                                    (finishNode specId
                                        (Mono.MonoTailFunc
                                            [ ( "record", Mono.MRecord fields ) ]
                                            (Mono.MonoRecordAccess (Mono.MonoVarLocal "record" (Mono.MRecord fields)) fieldName fieldType)
                                            monoType
                                        )
                                        sItem
                                    )

                            _ ->
                                Err (EngineBug ("accessor global " ++ fieldName ++ ": expected MFunction [MRecord] fieldType"))

                    Mono.Global home name ->
                        let
                            -- D13: resolve the node + its annotation-id set ONCE per
                            -- global (both depend only on the immutable node map), then
                            -- reuse across every spec of the same global. `sItem2`
                            -- carries the memo insert on the first resolve.
                            ( resolution, sItem2 ) =
                                resolveGlobalNode home name sItem
                        in
                        case resolution.node of
                            Nothing ->
                                Ok (finishNode specId (Mono.MonoExtern monoType) sItem2)

                            Just node ->
                                case specializeNode name home node monoType sItem2 of
                                    Err e ->
                                        Err e

                                    Ok ( monoNode0, s1raw ) ->
                                        let
                                            -- Harvest Join-R number taints from this item's store into
                                            -- the global super table before the store is discarded —
                                            -- EXCLUDING the node's own annotation vars (per-spec, memoized).
                                            s1 =
                                                Engine.harvestSuperTableExcept resolution.annIds s1raw

                                            ( monoNode, newLambdaCounter ) =
                                                ResolveAccessorValues.rewriteNode home s1.lambdaCounter monoNode0

                                            actualType =
                                                Mono.nodeType monoNode

                                            s2 =
                                                { s1
                                                    | registry = Registry.updateRegistryType specId actualType s1.registry
                                                    , lambdaCounter = newLambdaCounter
                                                }
                                        in
                                        Ok (finishNode specId monoNode s2)


{-| Specialize one top-level node. `name`/`home` identify the definition (used
for ctor tags and to follow links to their target's name/home).
-}
specializeNode : Name -> IO.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
specializeNode name home node monoType s =
    case node of
        TOpt.Define expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.TrackedDefine _ expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.Kernel _ _ ->
            Ok ( Mono.MonoExtern monoType, s )

        TOpt.Ctor index arity canType ->
            Engine.runStep (Translate.specializeCtorViaScheme name (CtorTag.effective home name index) arity canType monoType) s

        TOpt.Enum index canType ->
            Engine.runStep (Translate.enumNode (CtorTag.effective home name index) canType monoType) s

        TOpt.Box canType ->
            -- @unbox single-field type: a 1-field ctor with literal tag 0.
            Engine.runStep (Translate.specializeCtorViaScheme name 0 1 canType monoType) s

        TOpt.Link linkedGlobal ->
            case DMap.get TOpt.toComparableGlobal linkedGlobal s.env.toptNodes of
                Nothing ->
                    Ok ( Mono.MonoExtern monoType, s )

                Just linkedNode ->
                    case linkedGlobal of
                        TOpt.Global linkedHome linkedName ->
                            specializeNode linkedName linkedHome linkedNode monoType s

        TOpt.Manager _ ->
            case home of
                IO.Canonical _ modName ->
                    Ok ( Mono.MonoManagerLeaf (Name.toElmString modName) monoType, s )

        TOpt.Cycle _ valueDefs funcDefs _ ->
            -- The demand reaches the cycle node through a `_M$<first>` Link, so
            -- `name` here is the group name; the REQUESTED member is the original
            -- demand preserved in `currentGlobal`. Each member's cross-references
            -- enqueue its siblings, so members materialize as separate work items.
            let
                reqName =
                    case s.currentGlobal of
                        Just (Mono.Global _ n) ->
                            n

                        _ ->
                            name
            in
            Engine.runStep (Translate.specializeCycle reqName valueDefs funcDefs monoType) s

        TOpt.PortIncoming expr _ meta ->
            case monoType of
                Mono.MFunction _ _ _ ->
                    Engine.runStep (Translate.specializePort True expr meta.tipe monoType) s

                _ ->
                    -- The same port Global demanded at its DECODER (non-function)
                    -- type: compile the payload decoder as a plain value node
                    -- (mirrors the original engine's split).
                    defineFrom (TOpt.typeOf expr) expr monoType s

        TOpt.PortOutgoing expr _ meta ->
            Engine.runStep (Translate.specializePort False expr meta.tipe monoType) s


{-| D13: resolve a `Mono.Global` to its `TOpt.Node` and annotation-id set, memoized
by the comparable global. The node map and `nodeAnnotationIds` are both functions
of the immutable `toptNodes`, so a global with N specializations resolves once and
the DMap descent + `freeVarIds` walk are skipped for the other N-1. The memo lives
in `S.nodeResolution` (survives `resetItem`); byte-identical to recomputing.
-}
resolveGlobalNode : IO.Canonical -> Name -> S -> ( Engine.NodeResolution, S )
resolveGlobalNode home name s =
    let
        gkey =
            TOpt.toComparableGlobal (TOpt.Global home name)
    in
    case Dict.get gkey s.nodeResolution of
        Just resolution ->
            ( resolution, s )

        Nothing ->
            let
                node =
                    DMap.get TOpt.toComparableGlobal (TOpt.Global home name) s.env.toptNodes

                annIds =
                    case node of
                        Just n ->
                            nodeAnnotationIds n

                        Nothing ->
                            EverySet.empty

                resolution =
                    { node = node, annIds = annIds }
            in
            ( resolution, { s | nodeResolution = Dict.insert gkey resolution s.nodeResolution } )


{-| The item node's annotation free-var ids (excluded from taint harvest).
-}
nodeAnnotationIds : TOpt.Node TypeIds.MVarId -> EverySet.EverySet Int Int
nodeAnnotationIds node =
    let
        fromCan t =
            EverySet.fromList identity (List.map Id.toComparable (KernelAbi.freeVarIds t []))
    in
    case node of
        TOpt.Define _ _ meta ->
            fromCan meta.tipe

        TOpt.TrackedDefine _ _ _ meta ->
            fromCan meta.tipe

        _ ->
            EverySet.empty


{-| Specialize a value definition: assert the demanded type against the def's
annotation in the store (so a polymorphic body concretizes via the shared memo),
then translate the body. For a monomorphic global the demand equals the
annotation and the unification is a no-op.
-}
defineFrom : Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
defineFrom annCanType expr demand s =
    case Engine.runStep (Translate.demandUnifyRoot annCanType demand expr) s of
        Err e ->
            Err e

        Ok ( (), s1 ) ->
            case Engine.runStep (Translate.translate expr) s1 of
                Err e ->
                    Err e

                Ok ( monoExpr, s2 ) ->
                    Ok ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s2 )


finishNode : Mono.SpecId -> Mono.MonoNode -> S -> S
finishNode specId monoNode s =
    { s
        | nodes = arraySetGrowing specId (Just monoNode) s.nodes
        , inProgress = BitSet.removeGrowing specId s.inProgress
        , currentGlobal = Nothing

        -- LSS_010: a demand join landed while this spec was mid-translation
        -- (enqueueSpec cannot re-push an inProgress item) — re-translate with
        -- the joined stored type. The dirty mark is consumed at the re-pop.
        , worklist =
            if BitSet.member specId s.dirtySpecs then
                SpecializeGlobal specId :: s.worklist

            else
                s.worklist
    }


nodeAlreadyDone : Mono.SpecId -> S -> Bool
nodeAlreadyDone specId s =
    case Array.get specId s.nodes of
        Just (Just _) ->
            True

        _ ->
            False



-- ====== ASSEMBLY (mirror of assembleRawGraphFrom) ======


assembleRawGraph : S -> Mono.SpecId -> Maybe Mono.SpecId -> Mono.MonoGraph
assembleRawGraph s mainSpecId flagsDecoderSpecId =
    let
        nextId : Int
        nextId =
            s.registry.nextId

        nodesArray : Array (Maybe Mono.MonoNode)
        nodesArray =
            let
                currentLen =
                    Array.length s.nodes
            in
            if currentLen >= nextId then
                s.nodes

            else
                Array.append s.nodes (Array.repeat (nextId - currentLen) Nothing)

        ( callEdgesArray, specHasEffects, specValueUsed ) =
            Array.foldl
                (\maybeNode ( specId, ( edgesAcc, effectsAcc, valueUsedAcc ) ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, ( edgesAcc, effectsAcc, valueUsedAcc ) )

                        Just node ->
                            let
                                -- D14: one fused walk yields both the call-edges and
                                -- the effects flag (was two full `foldExpr` passes over
                                -- the same expr). Byte-identical: same traversal order,
                                -- same cons order for edges, same Debug-kernel effect.
                                ( neighbors, hasEffects ) =
                                    collectEdgesAndEffectsFromNode node

                                newEdges =
                                    Array.set specId (Just neighbors) edgesAcc

                                newEffects =
                                    if hasEffects then
                                        BitSet.insertGrowing specId effectsAcc

                                    else
                                        effectsAcc

                                newValueUsed =
                                    List.foldl (\calleeId acc -> BitSet.insertGrowing calleeId acc) valueUsedAcc neighbors
                            in
                            ( specId + 1, ( newEdges, newEffects, newValueUsed ) )
                )
                ( 0, ( Array.repeat nextId Nothing, BitSet.empty, BitSet.empty ) )
                nodesArray
                |> Tuple.second

        valueUsedWithMain : BitSet.BitSet
        valueUsedWithMain =
            BitSet.insertGrowing mainSpecId specValueUsed
    in
    Mono.MonoGraph
        { nodes = nodesArray
        , registry = { nextId = nextId, mapping = Dict.empty, reverseMapping = s.registry.reverseMapping }
        , main = Just (Mono.StaticMain mainSpecId)
        , ctorShapes = Dict.empty
        , nextLambdaIndex = s.lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = specHasEffects
        , specValueUsed = valueUsedWithMain
        , ports = s.ports
        , flagsDecoder = flagsDecoderSpecId
        }


pruneGraph : S -> Mono.MonoGraph -> Mono.MonoGraph
pruneGraph s rawGraph =
    Prune.pruneUnreachableSpecs
        (State.initMVarEnv s.nextMVarId s.superTable)
        s.env.globalTypeEnv
        rawGraph



-- ====== CALL-EDGE / EFFECT COLLECTION (mirror of the original private helpers) ======


{-| D14: fused edge-and-effect step. One `foldExpr` pass accumulates both the
call-edge spec ids (a `MonoVarGlobal`, cons order preserved) and the effects flag
(a `Debug` kernel reference). Replaces the former `extractSpecId` + `checkExpr`
double walk over the same expr; each expr node contributes to at most one field,
so the union is exact and byte-identical.
-}
collectEdgesAndEffects : Mono.MonoExpr -> ( List Int, Bool ) -> ( List Int, Bool )
collectEdgesAndEffects expr (( edges, effects ) as acc) =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            ( specId :: edges, effects )

        Mono.MonoVarKernel _ _ "Debug" _ _ ->
            ( edges, True )

        _ ->
            acc


collectEdgesAndEffectsFromNode : Mono.MonoNode -> ( List Int, Bool )
collectEdgesAndEffectsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoTailFunc _ expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoPortIncoming expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoPortOutgoing expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        _ ->
            ( [], False )



-- ====== HELPERS ======


toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)
arraySetGrowing index value arr =
    let
        len =
            Array.length arr
    in
    if index < len then
        Array.set index value arr

    else
        Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))


renderFailure : Failure -> String
renderFailure failure =
    case failure of
        Unsupported msg ->
            "MonoSolver.unsupported: " ++ msg

        UnifyMismatch msg ->
            "MonoSolver.unify-mismatch: " ++ msg

        EngineBug msg ->
            "MonoSolver.bug: " ++ msg
