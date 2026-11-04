module TestLogic.GlobalOpt.MonoInlineSimplifyTest exposing (suite)

{-| Tests for the post-monomorphization inliner,
`Compiler.MonoOpt.InlineSimplify.optimize`, run on its own, outside a
build: that over the standard catalogue its output keeps two structural
invariants.

The programs are those of the `SourceIR.Suite.StandardTestSuites` catalogue,
each turned into a monomorphized graph by `TestLogic.TestPipeline.runToMono`,
the production pipeline up to and including monomorphization. The inliner is
then called with `Config.default.inline`. The optimized graph is not pruned
afterwards, whereas a default build prunes it.

What the tests establish, over the standard catalogue ("optimizes without
errors"): `runToMono` succeeds; in the optimized graph no live node refers to
a SpecId that has no node; and no `MonoDefine` holds a `MonoTailCall` other
than one to a tail-recursive `let` definition in the same body, which is what
inlining a `MonoTailFunc` body would leave behind. A `runToMono` error fails
the program's test with its message.

That the inliner does the rewrite each of four small fixtures is built for
(an identity call inlined, a dead `let` dropped, a directly applied lambda
beta-reduced, two nested dead `let`s dropped) is pinned by its metrics in the
unit test `Compiler.MonoOpt.InlineSimplifyTest`.

Among what is not tested: that the optimized graph computes the same values,
and the inliner's metrics over the catalogue.

-}

import Array
import Compiler.Config as Config
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Compiler.MonoOpt.InlineSimplify as MonoInlineSimplify
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| All the tests of this module: the standard-catalogue group.
-}
suite : Test
suite =
    Test.describe "MonoInlineSimplify"
        [ standardTestSuite
        ]



-- ============================================================================
-- STANDARD TEST SUITE INTEGRATION
-- ============================================================================


{-| The test, over every program in the standard catalogue, that the inliner's
output keeps the invariants `graphIssues` checks.
-}
standardTestSuite : Test
standardTestSuite =
    StandardTestSuites.expectSuite expectOptimizationPreservesValidity "optimizes without errors"


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes when `graphIssues` finds nothing in the result. Fails with the
pipeline's message when `runToMono` returns an error.
-}
expectOptimizationPreservesValidity : Src.Module -> Expect.Expectation
expectOptimizationPreservesValidity srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                ( optimizedGraph, _ ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            case graphIssues optimizedGraph of
                [] ->
                    Expect.pass

                issues ->
                    Expect.fail (String.join "\n" issues)


{-| Returns a line for each problem in `graph`: a live node that refers (as
`MonoTraverse.collectSpecEdges` finds references) to a SpecId with no node,
and a `MonoDefine` whose body holds a `MonoTailCall` to a name that no
`MonoTailDef` in the same body defines.
-}
graphIssues : Mono.MonoGraph -> List String
graphIssues (Mono.MonoGraph record) =
    let
        edges =
            MonoTraverse.collectSpecEdges record.nodes

        isLive specId =
            case Array.get specId record.nodes of
                Just (Just _) ->
                    True

                _ ->
                    False
    in
    Array.foldl
        (\entry ( specId, acc ) ->
            case entry of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    let
                        dangling =
                            Array.get specId edges
                                |> Maybe.andThen identity
                                |> Maybe.withDefault []
                                |> List.filter (\t -> not (isLive t))
                                |> List.map
                                    (\t ->
                                        "SpecId " ++ String.fromInt specId ++ " refers to SpecId " ++ String.fromInt t ++ ", which has no node"
                                    )

                        orphans =
                            case node of
                                Mono.MonoDefine expr _ ->
                                    orphanTailCalls expr
                                        |> List.map
                                            (\n ->
                                                "SpecId " ++ String.fromInt specId ++ " (a MonoDefine) holds a MonoTailCall to '" ++ n ++ "' outside any tail-recursive definition of that name"
                                            )

                                _ ->
                                    []
                    in
                    ( specId + 1, acc ++ dangling ++ orphans )
        )
        ( 0, [] )
        record.nodes
        |> Tuple.second


{-| Returns the names of the `MonoTailCall`s in `expr` that no `MonoTailDef`
in `expr` defines.
-}
orphanTailCalls : Mono.MonoExpr -> List String
orphanTailCalls expr =
    let
        ( tailDefs, tailCalls ) =
            MonoTraverse.foldExpr
                (\e ( defs, calls ) ->
                    case e of
                        Mono.MonoLet (Mono.MonoTailDef name _ _) _ _ ->
                            ( name :: defs, calls )

                        Mono.MonoTailCall name _ _ ->
                            ( defs, name :: calls )

                        _ ->
                            ( defs, calls )
                )
                ( [], [] )
                expr
    in
    List.filter (\n -> not (List.member n tailDefs)) tailCalls
