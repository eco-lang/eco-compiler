module Compiler.Monomorphize.Prune exposing (pruneUnreachableSpecs, pruneAfterInline, restrictToSccEdges)

{-| Prune unreachable specializations from MonoGraph.

After monomorphization, this pass removes all specializations that are not
reachable from the main entry point via callEdges. This ensures the graph
handed to GlobalOpt and MLIR contains only concrete specializations that
matter for code generation.

**Two entry points, one reachability.** `pruneUnreachableSpecs` is the
mono-time call: it prunes over the `callEdges` monomorphization computed and
FUSES quiescence closing (MONO\_028) into the rebuild. `pruneAfterInline` is
the post-`MonoInlineSimplify` call
(`plans/post-inline-dead-spec-prune.md`): the inliner orphans a specialization
whenever it inlines the only reference to it, and nothing removed those until
this existed — 6,608 unreferenced code-bearing functions, 4.86 % of the
self-compile's emitted text. It re-collects edges from the REWRITTEN bodies
(`callEdges` is `Array.empty` after the inliner) and does no closing: residual
number vars were already discharged and crash-checked at mono time.

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
import Dict exposing (Dict)
import Utils.Crash


{-| Compute the BitSet of SpecIds reachable from the main specialization by DFS
over the given adjacency.

The adjacency is a PARAMETER, not `record.callEdges`, because the two callers
have different ones: mono time passes the array monomorphization built,
post-inline passes a fresh `MonoTraverse.collectSpecEdges` over the rewritten
bodies. Both must relate every `MonoVarGlobal` occurrence to its spec — see
that function's doc for why a partial adjacency is a miscompile and not a
missed optimization.

-}
reachableFromMain : Array (Maybe (List Int)) -> Mono.MonoGraph -> BitSet
reachableFromMain edges (Mono.MonoGraph record) =
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
            markReachable edges (mainSpecId :: portRoots ++ flagsRoots) (BitSet.fromSize size)


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


{-| What a prune does to the entries it KEEPS. Mono time closes residual number
vars as it copies (Q3 perf: one walk, not two) and recomputes `ctorShapes` from
the closed nodes so the layout keys stay consistent with them; post-inline does
neither, so its closer is the identity one below.
-}
type alias Closer =
    { node : Mono.MonoNode -> Mono.MonoNode
    , tipe : Mono.MonoType -> Mono.MonoType
    , hasResidual : Mono.MonoType -> Bool
    , ctorShapes : Mono.LayoutMap (List Mono.CtorShape) -> Array (Maybe Mono.MonoNode) -> Mono.LayoutMap (List Mono.CtorShape)
    }


{-| Prune every specialization unreachable from the roots, over the edges given.

Spec ids are array INDICES and are never renumbered: a dead slot becomes
`Nothing`, exactly as it does for a spec monomorphization never emitted.
Renumbering would invalidate `reverseMapping`, `callEdges`, LSS member keys
(`l|<raw>|<specId>`), AbiCloning's `hostSpecId` and CafHoist's mints.

-}
pruneUnreachableWith : Array (Maybe (List Int)) -> Closer -> Mono.MonoGraph -> Mono.MonoGraph
pruneUnreachableWith edges closer (Mono.MonoGraph record) =
    let
        live : BitSet
        live =
            reachableFromMain edges (Mono.MonoGraph record)
    in
    rebuild live edges closer (Mono.MonoGraph record)


{-| The post-`MonoInlineSimplify` prune
(`plans/post-inline-dead-spec-prune.md`).

Edges are re-collected from the rewritten bodies: the inliner returns
`callEdges = Array.empty`, and the mono-time array would be stale anyway
because the bodies changed under it.

No closing. Residual number vars were discharged at mono time and a survivor
crashes there (MONO\_002), so there is nothing left to close; `ctorShapes` is
carried through unchanged because pruning only ever REMOVES nodes, so the map
can only become a superset of what the live nodes look up — and every consumer
reads it by `layoutMapGet`, never by iteration.

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
            -- Row 8 (plans/frontend-heap-release.md §7.4, CGEN_069/MONO_022):
            -- the graph carries ONLY the intra-SCC edges from here on.
            Mono.MonoGraph { pruned | callEdges = restrictToSccEdges pruned.callEdges }


{-| Keep only the edges whose two ends lie in the same strongly connected
component (self-loops included), preserving each row's order and its
`Nothing`/`Just` shape.

The one downstream reader of `callEdges` is `MonoInlineSimplify.buildBodyLookup`
at codegen, which needs only `isRecursive` — membership of a cycle in the graph
INDUCED on the codegen-time nodes (GlobalOpt/CafHoist add and remove specs, so
that set differs from this one). Every edge of a cycle lies inside one SCC, so
a subgraph induced from the restricted edges has exactly the cycles the one
induced from the full edges has: `isRecursive` is unchanged for every spec,
and the cross-SCC edges (the bulk of the array) are not carried to codegen.

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

        -- Component id per vertex (acyclic singletons get their own id too).
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


{-| Prune MonoGraph and SpecializationRegistry to keep only
specializations reachable from mainSpecId via callEdges.
Also recomputes ctorShapes from the pruned nodes.
-}
pruneUnreachableSpecs : State.MVarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
pruneUnreachableSpecs mvarEnv globalTypeEnv ((Mono.MonoGraph record) as graph) =
    let
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

        -- Spelled with their parameter: point-free these are declared arity 1
        -- and defined with none, so each is a PAP that the whole-graph walks
        -- below apply indirectly once per type they visit.
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
    in
    pruneUnreachableWith record.callEdges
        { node = closeNode
        , tipe = closeType
        , hasResidual = hasResidualType
        , ctorShapes =
            -- Recompute from the pruned+closed nodes. Since they are already
            -- closed the derived keys and fieldTypes are closed and
            -- consistent; the gated pass below is defensive (a no-op then).
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


{-| The shared rebuild: filter, close, re-register, recompute shapes.
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
                edges

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
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping = reverseMapping1
            , countByGlobal = Dict.empty -- MONO_030: during-run counts; not carried into the output graph
            }

        -- 4. ctorShapes, via the closer: recomputed and closed at mono time,
        -- carried through unchanged post-inline (§3.1 — pruning only removes
        -- nodes, so the existing map is a superset and every consumer reads it
        -- by key).
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

        -- Stale bits for pruned specIds are harmless — no node exists to reference them.
        , specHasEffects = record.specHasEffects
        , specValueUsed = record.specValueUsed
        , ports = record.ports
        , flagsDecoder = record.flagsDecoder
        , lssMemberOrigins = record.lssMemberOrigins
        , lssMemberKinds = record.lssMemberKinds
        , lssBlockedMembers = record.lssBlockedMembers
        }
