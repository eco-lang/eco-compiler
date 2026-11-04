module TestLogic.MonoOpt.BorrowTailCallEscape exposing
    ( TailFuncAnalysis
    , expectTailCallArgsEscape
    , tailFuncAnalyses
    )

{-| A check that borrow inference never reports a tail-call argument dead
before the end of its function's body. The arguments of a tail call are values
the function's next iteration still uses; if one were reported dead earlier,
reification could place a release after the tail call, which would break the
tail-call loop and release a value still in use. The rule is that of
`design_docs/globalopt/borrow-inference-design.md` §8.5; no invariant row
states it.

The analysis tracks _resources_: one per heap position of a value's type,
numbered from 0 within each definition. A scalar such as an `Int` has none, and
a `List Int` has one. For each resource, `Compiler.MonoOpt.Borrow.Solve`
computes an approximate lifetime, `ltA`, the latest point at which the resource
is live, as `Compiler.MonoOpt.Borrow.Lifetime` describes. The point asked about
is the empty path, the end of the whole function body.
`Compiler.MonoOpt.Borrow.Constrain` seeds every resource of a `MonoTailCall`
argument at that point (it is _escape-seeded_), so its `ltA` should reach the
end of the body.

Borrow inference only reports; it never changes the graph, and it is off by
default (`borrow.enabled`). The check therefore does not need it turned on: it
runs the analysis itself, with `Compiler.MonoOpt.Borrow.analyzeDefForTest`, on
the graph a default build optimizes, the graph the analysis would read when
enabled.

`expectTailCallArgsEscape` compiles a program with
`TestLogic.TestPipeline.runToGlobalOpt`, analyses every `MonoTailFunc` of the
optimized graph, and fails on a tail-call argument resource whose `ltA` is
`LEmpty` or that `Lifetime.endsBefore` reports dead at the end of the body.
`tailFuncAnalyses` returns the analyses themselves, for tests that pin more
about one program.

Among what is not checked: the precise lifetimes `ltP`, access modes, and
whether any later stage places or omits a release after a tail call.

-}

import Array
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Compiler.MonoOpt.Borrow as Borrow
import Compiler.MonoOpt.Borrow.Lifetime as L exposing (Lifetime(..))
import Compiler.MonoOpt.Borrow.Rty exposing (ResVar)
import Compiler.MonoOpt.Borrow.Solve as Solve
import Expect
import TestLogic.TestPipeline as Pipeline


{-| The analysis of one `MonoTailFunc`: its `SpecId`, the solved constraints,
the resources of its tail-call arguments, and its number of resources.
-}
type alias TailFuncAnalysis =
    { specId : Int
    , solved : Solve.Solved
    , tailArgRes : List ResVar
    , resourceCount : Int
    }


{-| Passes when `srcModule` compiles through global optimization and, in every
`MonoTailFunc` of the optimized graph, every tail-call argument resource has
an `ltA` that is not `LEmpty` and that `Lifetime.endsBefore` does not report
dead at the end of the body. Fails with the pipeline's message, or with one
line per offending resource.
-}
expectTailCallArgsEscape : Src.Module -> Expect.Expectation
expectTailCallArgsEscape srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                -- At the empty path, endsBefore is False only for `LLocal Star`
                -- and `LParams`, so it already rules out `LEmpty`.
                deadTailArgs analysis =
                    List.filter
                        (\r ->
                            let
                                lt =
                                    Solve.ltAOf r analysis.solved
                            in
                            lt == LEmpty || L.endsBefore lt []
                        )
                        analysis.tailArgRes
                        |> List.map
                            (\r ->
                                "SpecId "
                                    ++ String.fromInt analysis.specId
                                    ++ ": tail-call argument resource "
                                    ++ Debug.toString r
                                    ++ " has ltA "
                                    ++ Debug.toString (Solve.ltAOf r analysis.solved)
                                    ++ ", dead before the end of the body"
                            )
            in
            case List.concatMap deadTailArgs (tailFuncAnalyses optimizedMonoGraph) of
                [] ->
                    Expect.pass

                issues ->
                    Expect.fail (String.join "\n" issues)


{-| Returns the analysis of each `MonoTailFunc` of `graph`, highest `SpecId`
first.
-}
tailFuncAnalyses : Mono.MonoGraph -> List TailFuncAnalysis
tailFuncAnalyses graph =
    let
        (Mono.MonoGraph { nodes }) =
            graph

        -- A node's SpecId is its index in `nodes`. Consing makes the list
        -- descending.
        tailFuncSpecIds =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just (Mono.MonoTailFunc _ _ _) ->
                            ( specId + 1, specId :: acc )

                        _ ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                nodes
                |> Tuple.second
    in
    List.filterMap
        (\sid ->
            Borrow.analyzeDefForTest graph sid
                |> Maybe.map (\( solved, tailArgRes, n ) -> { specId = sid, solved = solved, tailArgRes = tailArgRes, resourceCount = n })
        )
        tailFuncSpecIds
