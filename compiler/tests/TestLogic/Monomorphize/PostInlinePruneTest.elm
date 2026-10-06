module TestLogic.Monomorphize.PostInlinePruneTest exposing (suite)

{-| Tests for `Prune.pruneAfterInline`, the pass that removes the
specializations `MonoInlineSimplify` leaves unreferenced, and for
`Prune.restrictToSccEdges`, which that pass applies to the edges it keeps.

A _specialization_ (spec) is one instantiation of a definition at a concrete
type. It sits in the graph's `nodes` array at the index of its SpecId, and it is
_live_ while that slot holds a node; pruning empties a slot and renumbers
nothing. When the inliner copies a function into its only call site, the
function's spec stays in the graph with nothing referring to it. The prune keeps
only what is reachable from its roots (the spec of `main`, and any
incoming-port and flags-decoder specs), as `Compiler.Monomorphize.Prune`
describes, over references it re-collects from the rewritten bodies with
`MonoTraverse.collectSpecEdges`, which counts every `MonoVarGlobal` as a
reference to its spec.

The risk is removing a spec that a live node still names, so most of these
tests check what survives. A _dangling reference_ is a pair of a live spec and a
spec that is not live but appears among its collected references. `danglingRefs`
lists them, making the same check as `Builder.Generate.validatePruned`. It reads
references with a walk written out in this module (`nodeGlobalRefs`), not with
the `collectSpecEdges` the prune uses, so a reference that function misses
shows here as dangling.

Each graph test builds a module with `Compiler.AST.SourceBuilder` and runs it
through `withGraphs`: `TestPipeline.runToMono`, the production pipeline, which
adds a `main` that uses `testValue`, then
`MonoInlineSimplify.optimize` with the default inline configuration, then the
prune. The three modules are:

  - `inlineAwayModule`, where `testValue` makes the only call to a small
    `addOne`;
  - `valueRefModule`, where `testValue` passes `addOne` to `List.map` and
    nothing calls it directly;
  - `localPartialModule`, where a lambda partially applied to an argument of
    `localPartial` is passed to `List.map`.

What the tests establish:

  - The fuzz test builds a graph of 1 to 16 vertices, in which every vertex
    whose index is 4 more than a multiple of 5 has no edge entry, and picks a
    random subset of its vertices. It checks that `restrictToSccEdges` leaves
    unchanged the vertices that lie on a cycle of the subgraph induced on the
    subset, the vertices that lie on a cycle of the whole graph, and which
    vertices have an edge entry, and that it keeps exactly the edges whose
    two ends reach each other, in their order, dropping every edge between
    components. The cyclic sets are the use the edges are kept for:
    `MonoInlineSimplify.buildBodyLookup` decides from them whether a spec is
    recursive, over the nodes the graph holds when it runs.
  - T1, on `inlineAwayModule`: the prune does not increase the number of live
    specs, it does reduce it, and it leaves no dangling reference.
  - T2, on `valueRefModule`: the prune leaves no dangling reference and at
    least one live spec.
  - T3, on `inlineAwayModule`: the spec of `main` is live after the prune. A
    graph with no `main` would pass unchecked.
  - T4, on `inlineAwayModule`: after the prune, a spec has an entry in the
    registry's `reverseMapping` exactly when it is live.
  - T5: no dangling reference after the prune, on each of the three modules.
  - T6, on `inlineAwayModule`: the inliner alone, without the prune, leaves the
    number of live specs unchanged.

Among what is not tested: the solver engine, which a default build uses; the
port and flags-decoder roots; that the pruned graph's `callEdges` are
restricted; and that any particular spec, such as `addOne`, is the one removed
or kept.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Data.BitSet as BitSet
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.Graph as Graph
import Compiler.Monomorphize.Prune as Prune
import Expect
import Fuzz
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The post-inline prune tests: the `restrictToSccEdges` fuzz test, then T1 to
T6.
-}
suite : Test
suite =
    Test.describe "post-inline dead-spec prune"
        [ sccRestrictionTest
        , Test.describe "T1 — an orphaned spec is removed"
            [ Test.test "the inlined-away callee's spec is gone and nothing references it" <|
                \_ ->
                    withGraphs inlineAwayModule
                        (\before after ->
                            Expect.all
                                [ \_ ->
                                    if liveCount after <= liveCount before then
                                        Expect.pass

                                    else
                                        Expect.fail
                                            ("prune ADDED specs: "
                                                ++ String.fromInt (liveCount before)
                                                ++ " -> "
                                                ++ String.fromInt (liveCount after)
                                            )

                                -- And on this fixture it shrinks.
                                , \_ ->
                                    if liveCount after < liveCount before then
                                        Expect.pass

                                    else
                                        Expect.fail
                                            ("expected at least one pruned spec, still "
                                                ++ String.fromInt (liveCount after)
                                            )
                                , \_ -> Expect.equal [] (danglingRefs after)
                                ]
                                ()
                        )
            ]
        , Test.describe "T2 — a spec referenced as a VALUE survives"
            [ Test.test "a global passed to a HOF is kept even with no call to it" <|
                \_ ->
                    -- `addOne` is named only as an argument to `List.map`,
                    -- so a prune that followed only calls would remove it.
                    withGraphs valueRefModule
                        (\_ after ->
                            Expect.all
                                [ \_ -> Expect.equal [] (danglingRefs after)
                                , \_ ->
                                    if liveCount after > 0 then
                                        Expect.pass

                                    else
                                        Expect.fail "pruned the entire graph"
                                ]
                                ()
                        )
            ]
        , Test.describe "T3 — roots are kept"
            [ Test.test "main's own spec survives" <|
                \_ ->
                    withGraphs inlineAwayModule
                        (\_ ((Mono.MonoGraph record) as after) ->
                            case record.main of
                                Just (Mono.StaticMain mainSpecId) ->
                                    if isLive after mainSpecId then
                                        Expect.pass

                                    else
                                        Expect.fail "the main spec was pruned"

                                _ ->
                                    -- Not expected: the pipeline always
                                    -- adds a `main`.
                                    Expect.pass
                        )
            ]
        , Test.describe "T4 — the registry is pruned with the nodes"
            [ Test.test "a pruned spec's reverseMapping entry is nulled, a kept one is not" <|
                \_ ->
                    -- AbiCloning picks direct-call targets from the specs
                    -- `reverseMapping` lists for a global, so an entry left
                    -- for a removed spec offers a target with no node.
                    withGraphs inlineAwayModule
                        (\(Mono.MonoGraph before) ((Mono.MonoGraph after) as afterGraph) ->
                            let
                                mismatched =
                                    Array.foldl
                                        (\_ ( specId, acc ) ->
                                            let
                                                live =
                                                    isLive afterGraph specId

                                                registered =
                                                    case Array.get specId after.registry.reverseMapping of
                                                        Just (Just _) ->
                                                            True

                                                        _ ->
                                                            False
                                            in
                                            ( specId + 1
                                            , if registered /= live then
                                                specId :: acc

                                              else
                                                acc
                                            )
                                        )
                                        ( 0, [] )
                                        before.nodes
                                        |> Tuple.second
                            in
                            Expect.equal [] mismatched
                        )
            ]
        , Test.describe "T5 — the graph stays CLOSED (MONO_011)"
            [ Test.test "every MonoVarGlobal in a live node names a live node" <|
                \_ ->
                    Expect.all
                        (List.map
                            (\srcModule _ -> withGraphs srcModule (\_ after -> Expect.equal [] (danglingRefs after)))
                            [ inlineAwayModule, valueRefModule, localPartialModule ]
                        )
                        ()
            ]
        , Test.describe "T6 — the flag is off: nothing moves"
            [ Test.test "not calling the prune leaves every spec in place" <|
                \_ ->
                    -- With `inline.pruneDead` off a build does not call the
                    -- prune, so this compares the graphs either side of the
                    -- inliner alone.
                    case Pipeline.runToMono inlineAwayModule of
                        Err msg ->
                            Expect.fail msg

                        Ok artifacts ->
                            let
                                inlined =
                                    Tuple.first (MonoInlineSimplify.optimize pruneConfig artifacts.monoGraph)
                            in
                            Expect.equal (liveCount artifacts.monoGraph) (liveCount inlined)
            ]
        ]



-- ============================================================================
-- ====== HELPERS ======
-- ============================================================================


{-| Returns the SpecId of every `MonoVarGlobal` in `node`'s body, or none for a
node kind that has no body.

It is written out here rather than taken from `MonoTraverse.collectSpecEdges`,
which the prune itself uses, so that a reference shape that function missed
would still be found here and show as dangling.

-}
nodeGlobalRefs : Mono.MonoNode -> List Int
nodeGlobalRefs node =
    case node of
        Mono.MonoDefine body _ ->
            exprGlobalRefs body

        Mono.MonoTailFunc _ body _ ->
            exprGlobalRefs body

        Mono.MonoPortIncoming body _ ->
            exprGlobalRefs body

        Mono.MonoPortOutgoing body _ ->
            exprGlobalRefs body

        _ ->
            []


{-| Returns the SpecId of every `MonoVarGlobal` in `expr`, at any depth,
including closure captures, `let` definitions and the case branches held in a
decision tree as well as in its jump list.
-}
exprGlobalRefs : Mono.MonoExpr -> List Int
exprGlobalRefs expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            [ specId ]

        Mono.MonoClosure info body _ ->
            List.concatMap (\( _, e, _ ) -> exprGlobalRefs e) info.captures ++ exprGlobalRefs body

        Mono.MonoLet def body _ ->
            (case def of
                Mono.MonoDef _ bound ->
                    exprGlobalRefs bound

                Mono.MonoTailDef _ _ bound ->
                    exprGlobalRefs bound
            )
                ++ exprGlobalRefs body

        Mono.MonoCase _ _ decider jumps _ ->
            deciderGlobalRefs decider ++ List.concatMap (\( _, e ) -> exprGlobalRefs e) jumps

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> exprGlobalRefs c ++ exprGlobalRefs t) branches ++ exprGlobalRefs final

        Mono.MonoCall _ fn args _ _ ->
            exprGlobalRefs fn ++ List.concatMap exprGlobalRefs args

        Mono.MonoTailCall _ namedArgs _ ->
            List.concatMap (\( _, a ) -> exprGlobalRefs a) namedArgs

        Mono.MonoDestruct _ inner _ ->
            exprGlobalRefs inner

        Mono.MonoList _ items _ ->
            List.concatMap exprGlobalRefs items

        Mono.MonoRecordCreate fields _ ->
            List.concatMap (\( _, e ) -> exprGlobalRefs e) fields

        Mono.MonoRecordAccess inner _ _ ->
            exprGlobalRefs inner

        Mono.MonoRecordUpdate inner updates _ ->
            exprGlobalRefs inner ++ List.concatMap (\( _, e ) -> exprGlobalRefs e) updates

        Mono.MonoTupleCreate _ items _ ->
            List.concatMap exprGlobalRefs items

        Mono.MonoLiteral _ _ ->
            []

        Mono.MonoVarLocal _ _ ->
            []

        Mono.MonoVarKernel _ _ _ _ _ ->
            []

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns the references of the case branches held inline at the leaves of
`decider`.
-}
deciderGlobalRefs : Mono.Decider Mono.MonoChoice -> List Int
deciderGlobalRefs decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            exprGlobalRefs e

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ yes no ->
            deciderGlobalRefs yes ++ deciderGlobalRefs no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> deciderGlobalRefs d) edges ++ deciderGlobalRefs fallback


{-| Returns what `check` makes of the graph before and after the prune, where
before is `srcModule` monomorphized by `TestPipeline.runToMono` and then
inlined with `pruneConfig`. Fails with the pipeline's message if
`TestPipeline.runToMono` fails.
-}
withGraphs : Src.Module -> (Mono.MonoGraph -> Mono.MonoGraph -> Expect.Expectation) -> Expect.Expectation
withGraphs srcModule check =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                inlined =
                    Tuple.first (MonoInlineSimplify.optimize pruneConfig artifacts.monoGraph)
            in
            check inlined (Prune.pruneAfterInline inlined)


{-| The inline configuration the tests run the inliner with: the default, with
`report` set off, which it already is by default.
-}
pruneConfig : Config.InlineConfig
pruneConfig =
    let
        base =
            Config.default.inline
    in
    { base | report = False }


{-| Returns the number of live specs in the graph, the slots of `nodes` that
hold a node.
-}
liveCount : Mono.MonoGraph -> Int
liveCount (Mono.MonoGraph record) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just _ ->
                    acc + 1

                Nothing ->
                    acc
        )
        0
        record.nodes


{-| Returns whether the spec numbered `specId` is live, which is false for an
index outside `nodes` too.
-}
isLive : Mono.MonoGraph -> Int -> Bool
isLive (Mono.MonoGraph record) specId =
    case Array.get specId record.nodes of
        Just (Just _) ->
            True

        _ ->
            False


{-| Returns the dangling references of a graph as `( from, to )` SpecId pairs:
`from` is live, and `to` is among the references `nodeGlobalRefs` finds in its
node but is not live.
-}
danglingRefs : Mono.MonoGraph -> List ( Int, Int )
danglingRefs ((Mono.MonoGraph record) as graph) =
    let
        edges =
            Array.map (Maybe.map nodeGlobalRefs) record.nodes
    in
    Array.foldl
        (\entry ( specId, acc ) ->
            case entry of
                Nothing ->
                    ( specId + 1, acc )

                Just _ ->
                    ( specId + 1
                    , case Array.get specId edges |> Maybe.andThen identity of
                        Just targets ->
                            List.foldl
                                (\t a ->
                                    if isLive graph t then
                                        a

                                    else
                                        ( specId, t ) :: a
                                )
                                acc
                                targets

                        Nothing ->
                            acc
                    )
        )
        ( 0, [] )
        record.nodes
        |> Tuple.second



-- ============================================================================
-- ====== FIXTURES ======
-- ============================================================================


{-| The source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The source type `List Int`.
-}
tIntList : Src.Type
tIntList =
    tType "List" [ tInt ]


{-| A module in which `testValue` is `addOne 41`, the only call to
`addOne n = n + 1`. T1 relies on the inliner leaving at least one spec of it
unreferenced.
-}
inlineAwayModule : Src.Module
inlineAwayModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "addOne"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt tInt
          , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
          }
        , { name = "testValue"
          , args = []
          , tipe = tInt
          , body = callExpr (varExpr "addOne") [ intExpr 41 ]
          }
        ]
        []
        []


{-| A module in which `testValue` is `List.map addOne [ 1, 2, 3 ]`, so
`addOne` is referred to as a value and nothing calls it directly.
-}
valueRefModule : Src.Module
valueRefModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "addOne"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt tInt
          , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
          }
        , { name = "testValue"
          , args = []
          , tipe = tIntList
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ varExpr "addOne", listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
          }
        ]
        []
        []


{-| A module in which `localPartial k xs` maps `(\a b -> a + b) k` over `xs`,
passing a lambda partially applied to `k` to `List.map`, and `testValue` calls
`localPartial 7 [ 1, 2 ]`.
-}
localPartialModule : Src.Module
localPartialModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "localPartial"
          , args = [ pVar "k", pVar "xs" ]
          , tipe = tLambda tInt (tLambda tIntList tIntList)
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ callExpr
                        (lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                        )
                        [ varExpr "k" ]
                    , varExpr "xs"
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tIntList
          , body = callExpr (varExpr "localPartial") [ intExpr 7, listExpr [ intExpr 1, intExpr 2 ] ]
          }
        ]
        []
        []


{-| A fuzz test that `Prune.restrictToSccEdges`, which keeps only the edges
inside a strongly connected component, leaves unchanged the vertices on a cycle
of a randomly chosen induced subgraph, the vertices on a cycle of the whole
graph, and which vertices have an edge entry.

The graph has `n` vertices, from 1 to 16; a vertex whose index is 4 more than a
multiple of 5 has no edge entry, and a generated edge from such a vertex is
dropped. A vertex is in the subgraph when its position in `mask` holds `True`
or lies beyond the end of `mask`.

-}
sccRestrictionTest : Test
sccRestrictionTest =
    Test.fuzz3
        (Fuzz.intRange 1 16)
        (Fuzz.list (Fuzz.pair (Fuzz.intRange 0 15) (Fuzz.intRange 0 15)))
        (Fuzz.list Fuzz.bool)
        "restrictToSccEdges preserves the cyclic set of every induced subgraph"
    <|
        \n pairs mask ->
            let
                edges =
                    List.foldl
                        (\( s, t ) acc ->
                            let
                                src =
                                    modBy n s
                            in
                            case Array.get src acc of
                                Just (Just ts) ->
                                    Array.set src (Just (modBy n t :: ts)) acc

                                _ ->
                                    acc
                        )
                        (Array.initialize n
                            (\i ->
                                if modBy 5 i == 4 then
                                    Nothing

                                else
                                    Just []
                            )
                        )
                        pairs

                keep v =
                    case List.drop v mask of
                        k :: _ ->
                            k

                        [] ->
                            True

                restricted =
                    Prune.restrictToSccEdges edges
            in
            Expect.all
                [ \_ -> Expect.equal (cyclicSet n keep edges) (cyclicSet n keep restricted)
                , \_ -> Expect.equal (cyclicSet n (always True) edges) (cyclicSet n (always True) restricted)
                , \_ -> Expect.equal (Array.map (Maybe.map (always ())) edges) (Array.map (Maybe.map (always ())) restricted)
                , \_ ->
                    -- Exactly the edges whose two ends reach each other (one
                    -- strongly connected component) are kept, in their order:
                    -- an edge between components is dropped.
                    Expect.equal
                        (Array.indexedMap
                            (\src entry -> Maybe.map (List.filter (\t -> reaches n edges t src)) entry)
                            edges
                        )
                        restricted
                ]
                ()


{-| Tells whether vertex `to` can be reached from vertex `from` in `edges`, a
graph of `n` vertices, by a path of zero or more edges. A missing edge entry
counts as no edges.
-}
reaches : Int -> Array.Array (Maybe (List Int)) -> Int -> Int -> Bool
reaches n edges from to =
    let
        visit pending seen =
            case pending of
                [] ->
                    List.member to seen

                v :: rest ->
                    if List.member v seen then
                        visit rest seen

                    else
                        visit (Maybe.withDefault [] (Maybe.andThen identity (Array.get v edges)) ++ rest) (v :: seen)
    in
    from < n && visit [ from ] []


{-| Returns, in ascending order, the vertices that lie on a cycle of the
subgraph of `edges` induced on the vertices `keep` accepts. `n` is the number
of vertices, and a missing edge entry counts as no edges.
-}
cyclicSet : Int -> (Int -> Bool) -> Array.Array (Maybe (List Int)) -> List Int
cyclicSet n keep edges =
    let
        fwd =
            Array.indexedMap
                (\s entry ->
                    if keep s then
                        List.filter keep (Maybe.withDefault [] entry)

                    else
                        []
                )
                edges

        trans =
            Array.foldl
                (\ts ( s, acc ) ->
                    ( s + 1
                    , List.foldl (\t a -> Array.set t (s :: Maybe.withDefault [] (Array.get t a)) a) acc ts
                    )
                )
                ( 0, Array.repeat n [] )
                fwd
                |> Tuple.second

        selfLoops =
            Array.foldl
                (\ts ( s, acc ) ->
                    ( s + 1
                    , if List.member s ts then
                        BitSet.insert s acc

                      else
                        acc
                    )
                )
                ( 0, BitSet.emptyWithSize n )
                fwd
                |> Tuple.second
    in
    Graph.stronglyConnCompInt { fwd = fwd, trans = trans, selfLoops = selfLoops, size = n }
        |> List.concatMap
            (\scc ->
                case scc of
                    Graph.CyclicSCC vs ->
                        vs

                    Graph.AcyclicSCC _ ->
                        []
            )
        |> List.sort
