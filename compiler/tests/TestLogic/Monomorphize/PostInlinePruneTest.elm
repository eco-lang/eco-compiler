module TestLogic.Monomorphize.PostInlinePruneTest exposing (suite)

{-| `Prune.pruneAfterInline` — the post-`MonoInlineSimplify` dead-spec prune
(`plans/post-inline-dead-spec-prune.md` §7.1).

The pass removes specializations the inliner orphaned: it inlines the only
reference to a callee and leaves the callee's spec in the graph, because
`Prune` runs at the END of monomorphization and the inliner returns
`callEdges = Array.empty`. On the self-compile that is 6,608 unreferenced
code-bearing functions, 4.86 % of the emitted text.

**The one real risk is pruning something LIVE**, so most of what is pinned here
is what must SURVIVE. A spec is kept alive by ANY `MonoVarGlobal` occurrence —
a direct call, a `papCreate` that names it, a bare reference stored into data —
never only by call-shaped ones. An adjacency that misses a shape is a
miscompile, not a missed optimization: `plans/prune-bitset-calledges-reachability.md`
failed exactly that way across 702 tests with MONO\_011 / CGEN\_044.

T5 is that risk as a direct assertion — the same closure check
`Generate.validatePruned` runs under `ECO_MONO_VALIDATE=1` — and it is the test
to extend when a new cross-spec reference shape is introduced.

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
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Prune as Prune
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "post-inline dead-spec prune"
        [ Test.describe "T1 — an orphaned spec is removed"
            [ Test.test "the inlined-away callee's spec is gone and nothing references it" <|
                \_ ->
                    withGraphs inlineAwayModule
                        (\before after ->
                            Expect.all
                                [ -- The prune only ever removes.
                                  \_ ->
                                    if liveCount after <= liveCount before then
                                        Expect.pass

                                    else
                                        Expect.fail
                                            ("prune ADDED specs: "
                                                ++ String.fromInt (liveCount before)
                                                ++ " -> "
                                                ++ String.fromInt (liveCount after)
                                            )

                                -- And on this fixture it removes something:
                                -- `addOne` is tiny, inlines at its only call
                                -- site, and its spec is then unreferenced.
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
                    -- `List.map addOne xs` references `addOne` through a
                    -- `MonoVarGlobal` in ARGUMENT position, which lowers to a
                    -- `papCreate function=@addOne`, not a call. A collector
                    -- that only followed call-shaped references would prune it
                    -- and the emitted module would name a missing symbol.
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
                                    -- No main: the prune keeps everything
                                    -- (library compile), which T1 already
                                    -- covers via the monotonicity assertion.
                                    Expect.pass
                        )
            ]
        , Test.describe "T4 — the registry is pruned with the nodes"
            [ Test.test "a pruned spec's reverseMapping entry is nulled, a kept one is not" <|
                \_ ->
                    -- Load-bearing, not cosmetic: E9.5 post-settle devirt picks
                    -- its direct-call target from the registry's specs of a
                    -- global (`specsByGlobal` folds `reverseMapping` and skips
                    -- `Nothing`). A dead spec left there is a candidate whose
                    -- node is gone — an `eco.call` to a missing symbol.
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
                                            , if registered && not live then
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
                    -- The pass is a function, so "flag off" in the pipeline is
                    -- "do not call it". What this pins is that the INLINER
                    -- alone never removes a spec — every difference in live
                    -- count between the two flag states is the prune's.
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


{-| Run the real pipeline position: monomorphize, inline, then prune. Hands the
check the graph BEFORE and AFTER the prune so a test can assert on the delta.
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


{-| Defaults, with the report off — the census builds strings the tests do not
read.
-}
pruneConfig : Config.InlineConfig
pruneConfig =
    let
        base =
            Config.default.inline
    in
    { base | report = False }


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


isLive : Mono.MonoGraph -> Int -> Bool
isLive (Mono.MonoGraph record) specId =
    case Array.get specId record.nodes of
        Just (Just _) ->
            True

        _ ->
            False


{-| `( from, to )` for every reference from a live node to a pruned one. The
MONO\_011 closure check, and empty is the only acceptable answer.
-}
danglingRefs : Mono.MonoGraph -> List ( Int, Int )
danglingRefs ((Mono.MonoGraph record) as graph) =
    let
        edges =
            MonoTraverse.collectSpecEdges record.nodes
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


tInt : Src.Type
tInt =
    tType "Int" []


tIntList : Src.Type
tIntList =
    tType "List" [ tInt ]


{-| `addOne` is under the inline threshold and is called once, so the inliner
copies it into `testValue` and orphans its spec.
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


{-| `addOne` reaches `List.map` as a VALUE. Nothing calls it directly, so a
call-shaped reachability would prune it and the `papCreate` naming it would
dangle.
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


{-| A partially applied local lambda escaping into a HOF — the shape that keeps
closures and PAPs alive across the pass.
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
