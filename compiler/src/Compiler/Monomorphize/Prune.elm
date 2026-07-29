module Compiler.Monomorphize.Prune exposing (pruneUnreachableSpecs)

{-| Prune unreachable specializations from MonoGraph.

After monomorphization, this pass removes all specializations that are not
reachable from the main entry point via callEdges. This ensures the graph
handed to GlobalOpt and MLIR contains only concrete specializations that
matter for code generation.

@docs pruneUnreachableSpecs

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.State as State
import Dict exposing (Dict)
import Utils.Crash


{-| Compute the BitSet of SpecIds reachable from the main specialization
by DFS over the precomputed callEdges adjacency.
-}
reachableFromMain : Mono.MonoGraph -> BitSet
reachableFromMain (Mono.MonoGraph record) =
    let
        size =
            record.registry.nextId
    in
    case record.main of
        Nothing ->
            -- Library / non-executable: conservatively keep everything.
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( specId + 1, BitSet.insert specId acc )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, BitSet.fromSize size )
                record.nodes
                |> Tuple.second

        Just (Mono.StaticMain mainSpecId) ->
            let
                -- Incoming-port decoder specs are referenced only by the
                -- generated @__eco_register_ports preamble (emitted after
                -- pruning), so they must be explicit roots (PORT_003).
                portRoots =
                    List.filterMap .decoderSpecId record.ports

                -- The flags decoder is likewise referenced only by the
                -- generated preamble (Phase 5).
                flagsRoots =
                    case record.flagsDecoder of
                        Just specId ->
                            [ specId ]

                        Nothing ->
                            []
            in
            markReachable record.callEdges (mainSpecId :: portRoots ++ flagsRoots) (BitSet.fromSize size)


{-| DFS over callEdges using an explicit stack. Returns BitSet of all reachable specIds.
-}
markReachable : Array (Maybe (List Int)) -> List Int -> BitSet -> BitSet
markReachable callEdges stack visited =
    case stack of
        [] ->
            visited

        specId :: rest ->
            if BitSet.member specId visited then
                markReachable callEdges rest visited

            else
                let
                    visited1 =
                        BitSet.insert specId visited

                    neighbors =
                        case Array.get specId callEdges |> Maybe.andThen identity of
                            Nothing ->
                                []

                            Just edges ->
                                edges
                in
                markReachable callEdges (neighbors ++ rest) visited1


{-| Prune MonoGraph and SpecializationRegistry to keep only
specializations reachable from mainSpecId via callEdges.
Also recomputes ctorShapes from the pruned nodes.
-}
pruneUnreachableSpecs : State.MVarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
pruneUnreachableSpecs mvarEnv globalTypeEnv (Mono.MonoGraph record) =
    let
        live : BitSet
        live =
            reachableFromMain (Mono.MonoGraph record)

        -- Quiescence closing (MONO_028) FUSED into the prune rebuild (Q3, perf,
        -- plans/monomorphization-perf-analysis.md): discharge residual number vars
        -- (MVar CNumber → MInt) as live nodes are copied here, rather than in a
        -- separate whole-graph pass afterward. Gated on an allocation-free pre-scan
        -- so residual-free nodes/types are returned by reference. Because nodes1 is
        -- closed BEFORE ctorShapes are recomputed from it, the ctorShapes Dict keys
        -- (derived from the closed MCustom types) stay consistent with the closed
        -- node types by construction — fixing the pre-close-key desync hazard.
        isNum mvarId =
            State.isNumberVar mvarId mvarEnv

        closeType : Mono.MonoType -> Mono.MonoType
        closeType =
            Mono.resolveNumberType isNum

        hasResidualType : Mono.MonoType -> Bool
        hasResidualType =
            Mono.typeHasResidualNumber isNum

        closeNode : Mono.MonoNode -> Mono.MonoNode
        closeNode node =
            if Traverse.anyNodeType hasResidualType node then
                let
                    closed =
                        Traverse.mapNodeTypes closeType node
                in
                -- 2.2a (MONO_002 enforcement): a residual number var must not
                -- survive the close. This runs every compile, unconditionally —
                -- a stronger, shape-independent replacement for the old syntactic
                -- fail-fast (a stamped `MVar _ CNumber` crashing codegen only if
                -- its shape happened to be exercised). Catches a closeType
                -- resolution failure; the detection shares `anyNodeType` coverage
                -- with the close itself, so it does not guard an anyNodeType gap.
                if Traverse.anyNodeType hasResidualType closed then
                    Utils.Crash.crash "MONO_002: residual number var survived the closing pass (Prune)"

                else
                    closed

            else
                node

        -- 1. Filter nodes (leave Nothing gaps for dead entries) + close residuals
        nodes1 : Array (Maybe Mono.MonoNode)
        nodes1 =
            Array.indexedMap
                (\specId entry ->
                    if BitSet.member specId live then
                        Maybe.map closeNode entry

                    else
                        Nothing
                )
                record.nodes

        -- 2. Filter callEdges (leave Nothing gaps for dead entries)
        callEdges1 : Array (Maybe (List Int))
        callEdges1 =
            Array.indexedMap
                (\specId entry ->
                    if BitSet.member specId live then
                        entry

                    else
                        Nothing
                )
                record.callEdges

        -- 3. Rebuild registry
        oldReg =
            record.registry

        -- Null out dead entries in reverseMapping + close residual types
        reverseMapping1 : Array (Maybe ( Mono.Global, Mono.MonoType ))
        reverseMapping1 =
            Array.indexedMap
                (\i entry ->
                    if BitSet.member i live then
                        Maybe.map
                            (\pair ->
                                let
                                    ( g, mt ) =
                                        pair
                                in
                                if hasResidualType mt then
                                    ( g, closeType mt )

                                else
                                    pair
                            )
                            entry

                    else
                        Nothing
                )
                oldReg.reverseMapping

        -- mapping is not needed after monomorphization (only reverseMapping is used
        -- downstream by InlineSimplify, GlobalOpt, and MLIR gen), so skip rebuilding it.
        registry1 : Mono.SpecializationRegistry
        registry1 =
            { nextId = oldReg.nextId
            , mapping = Dict.empty
            , reverseMapping = reverseMapping1
            }

        -- 4. Recompute ctorShapes from the pruned+closed nodes. Since nodes1 is
        -- already closed, the derived keys and fieldTypes are closed and consistent.
        -- The gated pass over fieldTypes is defensive (a no-op when already closed).
        ctorShapes1 : Dict String (List Mono.CtorShape)
        ctorShapes1 =
            Dict.map
                (\_ shapes ->
                    List.map
                        (\shape ->
                            if List.any hasResidualType shape.fieldTypes then
                                { shape | fieldTypes = List.map closeType shape.fieldTypes }

                            else
                                shape
                        )
                        shapes
                )
                (Analysis.computeCtorShapesForGraph globalTypeEnv nodes1)
    in
    Mono.MonoGraph
        { nodes = nodes1
        , main = record.main
        , registry = registry1
        , ctorShapes = ctorShapes1
        , nextLambdaIndex = record.nextLambdaIndex
        , callEdges = callEdges1

        -- Stale bits for pruned specIds are harmless — no node exists to reference them.
        , specHasEffects = record.specHasEffects
        , specValueUsed = record.specValueUsed
        , ports = record.ports
        , flagsDecoder = record.flagsDecoder
        , lssMemberOrigins = record.lssMemberOrigins
        }
