module Compiler.Monomorphize.Prune exposing (pruneUnreachableSpecs, pruneAfterInline, restrictToSccEdges)

{-| Monomorphization emits a specialization for everything it might need, and
inlining later absorbs some of them, so the graph holds specializations that no
code reaches. This module removes them.

A _specialization_ (spec) is one node of the `MonoGraph`, identified by its
`SpecId`. A spec is _live_ when it is reachable from a _root_ along spec
references: the roots are `main`'s spec, the decoder spec of every incoming
port, and the flags decoder's spec. The decoders are roots because the startup
preamble that refers to them is generated after pruning. When the graph has no
`main`, every existing node is kept.

A `SpecId` is an index into the graph's arrays, and other tables (the registry's
`reverseMapping`, LSS member keys, ids minted by later passes) hold those
indices. So a prune never renumbers: a dead spec's slot becomes `Nothing`, as
for a spec that was never emitted.

There are two entry points over one shared rebuild. `pruneUnreachableSpecs`
runs right after monomorphization over the graph's own `callEdges`, and while
copying the live nodes it also _closes_ them: every residual number variable
(see `Compiler.AST.Monomorphized.resolveNumberType`) becomes `MInt`, and
`ctorShapes` is recomputed from the closed nodes. `pruneAfterInline` runs after
inlining, re-collects the edges from the current bodies, does no closing, and
leaves the graph's `callEdges` holding only the edges inside a strongly
connected component (`restrictToSccEdges`).

@docs pruneUnreachableSpecs, pruneAfterInline, restrictToSccEdges

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Graph as Graph
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.State as State
import Dict
import Utils.Crash


{-| Returns the set of SpecIds reachable over `edges` from the roots: `main`'s
spec, every incoming port's decoder spec and the flags decoder's spec. With no
`main`, it returns every SpecId that has a node.

The edges must relate every spec to every spec its body refers to. A missing
edge does not merely keep a dead spec; it can drop a live one.

-}
reachableFromMain : Array (Maybe (List Int)) -> Mono.MonoGraph -> BitSet
reachableFromMain edges (Mono.MonoGraph record) =
    let
        size =
            record.registry.nextId
    in
    case record.main of
        Nothing ->
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
                -- Port and flags decoders are referenced only by the startup preamble, generated after pruning.
                portRoots =
                    List.filterMap .decoderSpecId record.ports

                flagsRoots =
                    case record.flagsDecoder of
                        Just specId ->
                            [ specId ]

                        Nothing ->
                            []
            in
            markReachable edges (mainSpecId :: portRoots ++ flagsRoots) (BitSet.fromSize size)


{-| Returns `visited` extended by every SpecId reachable over `callEdges` from
the ids on `stack`, by depth-first search with an explicit stack. An id with no
entry in `callEdges` has no successors.
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


{-| What a prune does to the entries it keeps: `node` and `tipe` transform a
kept node and a kept `reverseMapping` type, `hasResidual` says whether a type
needs `tipe` at all, and `ctorShapes` produces the new constructor-shape map
from the old one and the kept nodes. The mono-time prune closes residual number
variables through it; the post-inline prune passes identities.
-}
type alias Closer =
    { node : Mono.MonoNode -> Mono.MonoNode
    , tipe : Mono.MonoType -> Mono.MonoType
    , hasResidual : Mono.MonoType -> Bool
    , ctorShapes : Mono.LayoutMap (List Mono.CtorShape) -> Array (Maybe Mono.MonoNode) -> Mono.LayoutMap (List Mono.CtorShape)
    }


{-| Returns the graph with every spec unreachable over `edges` from the roots
removed, and the kept entries transformed by `closer`. SpecIds are not
renumbered.
-}
pruneUnreachableWith : Array (Maybe (List Int)) -> Closer -> Mono.MonoGraph -> Mono.MonoGraph
pruneUnreachableWith edges closer (Mono.MonoGraph record) =
    let
        live : BitSet
        live =
            reachableFromMain edges (Mono.MonoGraph record)
    in
    rebuild live edges closer (Mono.MonoGraph record)


{-| Returns the graph with every spec unreachable from the roots removed, for
use after inlining, which can leave a spec with no remaining reference.

The edges are collected afresh from the current bodies
(`Compiler.Monomorphize.MonoTraverse.collectSpecEdges`), not taken from
`callEdges`, which may be empty or stale once bodies have been rewritten. No
type is closed, and `ctorShapes` is kept as it is: removing nodes only leaves
the map with entries no live node looks up. The result's `callEdges` holds only
the edges that `restrictToSccEdges` keeps.

-}
pruneAfterInline : Mono.MonoGraph -> Mono.MonoGraph
pruneAfterInline ((Mono.MonoGraph record) as graph) =
    case
        pruneUnreachableWith
            (Traverse.collectSpecEdges record.nodes)
            { node = identity
            , tipe = identity
            , hasResidual = always False
            , ctorShapes = \shapes _ -> shapes
            }
            graph
    of
        Mono.MonoGraph pruned ->
            Mono.MonoGraph { pruned | callEdges = restrictToSccEdges pruned.callEdges }


{-| Returns `edges` with only the edges whose two ends lie in the same strongly
connected component, self-loops included. Each row keeps its order and its
`Nothing` or `Just`, and a target outside the array's range is dropped.

Every edge of a cycle lies inside one component, so the restricted edges have
the same cycles as the full ones, and so does any subgraph induced from them on
a subset of the specs. What is lost is the edges between components.

-}
restrictToSccEdges : Array (Maybe (List Int)) -> Array (Maybe (List Int))
restrictToSccEdges edges =
    let
        n =
            Array.length edges

        inRange t =
            t >= 0 && t < n

        fwd : Array (List Int)
        fwd =
            Array.map (\entry -> List.filter inRange (Maybe.withDefault [] entry)) edges

        trans : Array (List Int)
        trans =
            Array.foldl
                (\targets ( src, acc ) ->
                    ( src + 1
                    , List.foldl
                        (\t a ->
                            case Array.get t a of
                                Just preds ->
                                    Array.set t (src :: preds) a

                                Nothing ->
                                    a
                        )
                        acc
                        targets
                    )
                )
                ( 0, Array.repeat n [] )
                fwd
                |> Tuple.second

        selfLoops : BitSet
        selfLoops =
            Array.foldl
                (\targets ( src, acc ) ->
                    ( src + 1
                    , if List.member src targets then
                        BitSet.insert src acc

                      else
                        acc
                    )
                )
                ( 0, BitSet.emptyWithSize n )
                fwd
                |> Tuple.second

        component : Array Int
        component =
            List.foldl
                (\scc ( nextComp, acc ) ->
                    case scc of
                        Graph.AcyclicSCC v ->
                            ( nextComp + 1, Array.set v nextComp acc )

                        Graph.CyclicSCC vs ->
                            ( nextComp + 1, List.foldl (\v a -> Array.set v nextComp a) acc vs )
                )
                ( 0, Array.repeat n -1 )
                (Graph.stronglyConnCompInt { fwd = fwd, trans = trans, selfLoops = selfLoops, size = n })
                |> Tuple.second

        compOf v =
            Maybe.withDefault -1 (Array.get v component)
    in
    Array.indexedMap
        (\src entry ->
            case entry of
                Just targets ->
                    let
                        c =
                            compOf src
                    in
                    Just (List.filter (\t -> inRange t && compOf t == c) targets)

                Nothing ->
                    Nothing
        )
        edges


{-| Returns the graph with every spec unreachable from the roots over its
`callEdges` removed, and the kept entries closed.

Closing replaces every `MVar _ CNumber`, and every variable `mvarEnv` marks as
a number, with `MInt`, in each kept node and each kept `reverseMapping` type. A kept node
that still has a residual number variable after closing crashes the compiler
(MONO\_002). `ctorShapes` is recomputed from the closed nodes, so its layout
keys agree with the closed types, and any shape field still holding a residual
is closed too.

-}
pruneUnreachableSpecs : State.MVarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
pruneUnreachableSpecs mvarEnv globalTypeEnv ((Mono.MonoGraph record) as graph) =
    let
        isNum mvarId =
            State.isNumberVar mvarId mvarEnv

        -- Written with their parameter so that they are not partial applications called indirectly per type.
        closeType : Mono.MonoType -> Mono.MonoType
        closeType t =
            Mono.resolveNumberType isNum t

        hasResidualType : Mono.MonoType -> Bool
        hasResidualType t =
            Mono.typeHasResidualNumber isNum t

        closeNode : Mono.MonoNode -> Mono.MonoNode
        closeNode node =
            if Traverse.anyNodeType hasResidualType node then
                let
                    closed =
                        Traverse.mapNodeTypes closeType node
                in
                -- The check walks the same positions as the close, so it cannot see a type anyNodeType misses.
                if Traverse.anyNodeType hasResidualType closed then
                    Utils.Crash.crash "MONO_002: residual number var survived the closing pass (Prune)"

                else
                    closed

            else
                node
    in
    pruneUnreachableWith record.callEdges
        { node = closeNode
        , tipe = closeType
        , hasResidual = hasResidualType
        , ctorShapes =
            -- The nodes are already closed, so the per-shape close is defensive.
            \_ nodes1 ->
                Mono.layoutMapMap
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
        }
        graph


{-| Returns the graph keeping only the specs in `live`, with kept entries
transformed by `closer`.

Dead slots of `nodes`, `edges` (which becomes `callEdges`) and the registry's
`reverseMapping` become `Nothing`. The registry's `mapping` and `countByGlobal`
are emptied, not filtered. `nextId`, `main`, the ports, the flags decoder, the
LSS tables, `specHasEffects` and `specValueUsed` are carried unchanged.

-}
rebuild : BitSet -> Array (Maybe (List Int)) -> Closer -> Mono.MonoGraph -> Mono.MonoGraph
rebuild live edges closer (Mono.MonoGraph record) =
    let
        closeNode =
            closer.node

        closeType =
            closer.tipe

        hasResidualType =
            closer.hasResidual

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

        callEdges1 : Array (Maybe (List Int))
        callEdges1 =
            Array.indexedMap
                (\specId entry ->
                    if BitSet.member specId live then
                        entry

                    else
                        Nothing
                )
                edges

        oldReg =
            record.registry

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

        -- The forward mapping is not rebuilt; later stages look specs up through reverseMapping.
        registry1 : Mono.SpecializationRegistry
        registry1 =
            { nextId = oldReg.nextId
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping = reverseMapping1
            , countByGlobal = Dict.empty
            }

        ctorShapes1 : Mono.LayoutMap (List Mono.CtorShape)
        ctorShapes1 =
            closer.ctorShapes record.ctorShapes nodes1
    in
    Mono.MonoGraph
        { nodes = nodes1
        , main = record.main
        , registry = registry1
        , ctorShapes = ctorShapes1
        , nextLambdaIndex = record.nextLambdaIndex
        , callEdges = callEdges1

        -- Bits of pruned specs are left set; no node remains to read them.
        , specHasEffects = record.specHasEffects
        , specValueUsed = record.specValueUsed
        , ports = record.ports
        , flagsDecoder = record.flagsDecoder
        , lssMemberOrigins = record.lssMemberOrigins
        , lssMemberKinds = record.lssMemberKinds
        , lssBlockedMembers = record.lssBlockedMembers
        }
