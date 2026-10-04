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
    compiles it with `TestLogic.TestPipeline.runToGlobalOptLssOn` and finds no
    lost member among the closures of the optimized graph.
  - `"satisfies LSS_002 under lss.arrowIdentity"`: the same check through
    `expectLambdaSetIntegrityArrowId`, which compiles with
    `runToGlobalOptLssArrowIdOn`. `TestLogic.TestPipeline` defines that as the
    same function as `runToGlobalOptLssOn`, so this group repeats the first and
    no `lss.arrowIdentity` setting is applied.

Among what is not tested: any lambda-set configuration other than the one
`runToGlobalOptLssOn` uses, and the graph before the inliner and global
optimization have run.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetIntegrity exposing (expectLambdaSetIntegrity, expectLambdaSetIntegrityArrowId)


{-| The two groups of tests, each running a lambda-set check over every
standard test program.
-}
suite : Test
suite =
    Test.describe "Lambda set integrity (LSS_002)"
        [ StandardTestSuites.expectSuite expectLambdaSetIntegrity "satisfies LSS_002"

        -- Repeats the group above: runToGlobalOptLssArrowIdOn is runToGlobalOptLssOn.
        , StandardTestSuites.expectSuite expectLambdaSetIntegrityArrowId "satisfies LSS_002 under lss.arrowIdentity"
        ]
