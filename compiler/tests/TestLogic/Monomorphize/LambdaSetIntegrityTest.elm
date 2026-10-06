module TestLogic.Monomorphize.LambdaSetIntegrityTest exposing (suite)

{-| Runs the lambda-set check of `TestLogic.Monomorphize.LambdaSetIntegrity`
over the standard catalogue of test programs, so that a closure missing from
the lambda set its own type claims for it is looked for in many kinds of
program rather than a hand-picked few.

A _lambda set_ is the annotation on the arrow of a function type naming the
function values that can flow through it. A closure whose own member id is
missing from the `LSet` at the head of its type is a _lost member_, and a later
pass that trusts the set treats calls to it as calls to something else. The
checker's module docstring defines both terms in full and says what it does
not check.

The fixture is every program that `SourceIR.Suite.StandardTestSuites` passes
to its caller's expectation.

What the tests establish:

  - `"satisfies LSS_002"`: for each program, `expectLambdaSetIntegrity`
    compiles it with `TestLogic.TestPipeline.runToGlobalOpt` and finds no
    lost member among the closures of the optimized graph.
  - `"satisfies LSS_002 before the inliner"`: the same check through
    `expectLambdaSetIntegrityBeforeOpt`, on the graph the solver engine
    produced, before the inliner and global optimization have run, so that a
    lost member is told apart from one those passes lose.

Among what is not tested: any lambda-set configuration other than the one
`runToGlobalOpt` uses.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetIntegrity exposing (expectLambdaSetIntegrity, expectLambdaSetIntegrityBeforeOpt)


{-| The two groups of tests, each running a lambda-set check over every
standard test program.
-}
suite : Test
suite =
    Test.describe "Lambda set integrity (LSS_002)"
        [ StandardTestSuites.expectSuite expectLambdaSetIntegrity "satisfies LSS_002"
        , StandardTestSuites.expectSuite expectLambdaSetIntegrityBeforeOpt "satisfies LSS_002 before the inliner"
        ]
