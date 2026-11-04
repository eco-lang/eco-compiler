module Compiler.Monomorphize.Solver.LssLocalMultiEnrichTest exposing (suite)

{-| Pins that each program of `SourceIR.LocalMultiEnrichCases` has, after
monomorphization by the solver engine with lambda-set specialization on, a
use of a let-bound name whose definition has an `LSet` on its outermost arrow,
so that the E4a use-enrichment check those programs were written for cannot
pass on them only because every annotation is ⊤.

The check itself, that each such use carries its definition's lambda-set
annotations, runs over the whole standard catalogue, these programs included,
as `TestLogic.Monomorphize.LocalUseEnrichmentTest`;
`TestLogic.Monomorphize.LocalUseEnrichment` states it in full. Here each
program is monomorphized with `TestLogic.TestPipeline.runSolverMonoWithLimits`
under the default specialization limits and the default lambda-set
configuration with `enabled` set, and `LocalUseEnrichment.check` walks the
graph before global optimization. A program passes when the pipeline
succeeds, no checked use disagrees with its definition, and at least one
checked use refers to a definition whose type has an `LSet` on its outermost
arrow.

-}

import Compiler.Config as Config
import Compiler.IR.Source as Src
import Expect
import SourceIR.LocalMultiEnrichCases as LocalMultiEnrichCases
import Test exposing (Test)
import TestLogic.Monomorphize.LocalUseEnrichment as LocalUseEnrichment
import TestLogic.TestPipeline as Pipeline


{-| The one test: `expectEnrichedUse` over the programs of
`SourceIR.LocalMultiEnrichCases`.
-}
suite : Test
suite =
    Test.describe "E4a local-multi use enrichment survives the deferred single walk"
        [ LocalMultiEnrichCases.expectSuite expectEnrichedUse "have an enriched, set-annotated use"
        ]


{-| Fails with the pipeline's message if any stage fails, with every
disagreeing use if there are any, and as vacuous if no checked use refers to a
definition with an `LSet` on its outermost arrow. The vacuous message lists
each `MonoDef` the walk met, with its right-hand side's type, in the order met.
-}
expectEnrichedUse : Src.Module -> Expect.Expectation
expectEnrichedUse srcModule =
    let
        defaults =
            Config.defaultLss
    in
    case Pipeline.runSolverMonoWithLimits Config.defaultLimits { defaults | enabled = True } srcModule of
        Err e ->
            Expect.fail e

        Ok graph ->
            let
                found =
                    LocalUseEnrichment.check graph
            in
            if not (List.isEmpty found.violations) then
                Expect.fail (String.join "\n" found.violations)

            else if found.enriched == 0 then
                Expect.fail ("vacuous: no use bound to an instance with a set-annotated head; defs seen: " ++ String.join "; " (List.reverse found.defs))

            else
                Expect.pass
