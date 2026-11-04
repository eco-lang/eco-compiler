module TestLogic.MonoOpt.BorrowTailCallEscapeTest exposing (suite)

{-| Tests, on the standard catalogue of test programs, that borrow inference
never reports a tail-call argument dead before the end of its function's body
(`design_docs/globalopt/borrow-inference-design.md` §8.5; no invariant row
states the rule).

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.MonoOpt.BorrowTailCallEscape.expectTailCallArgsEscape`, which
compiles it through global optimization with
`TestLogic.TestPipeline.runToGlobalOpt`, runs the borrow analysis on every
`MonoTailFunc` of the optimized graph, and fails on a resource of a tail-call
argument whose approximate lifetime does not reach the end of the body. Borrow
inference is off by default and only reports, so the check runs the analysis
itself on the default build's graph rather than through `borrow.enabled`. A
program with no `MonoTailFunc`, or none with heap tail-call arguments, passes
once it compiles.

The catalogue includes `SourceIR.BorrowTailCallCases`, the program this check
was first written for; `Compiler.MonoOpt.Borrow.BorrowTailCallEscapeTest` pins
its negative control.

Among what is not tested: the precise lifetimes, access modes, and whether a
later stage places or omits a release after a tail call.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.MonoOpt.BorrowTailCallEscape exposing (expectTailCallArgsEscape)


{-| `expectTailCallArgsEscape` over every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "MonoTailCall heap args are escape-seeded (never dead at/before the tail call)"
        [ StandardTestSuites.expectSuite expectTailCallArgsEscape "keeps its tail-call arguments live to the end of the body"
        ]
