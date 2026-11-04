module TestLogic.Monomorphize.LambdaSetJoinHonestyTest exposing (suite)

{-| Runs the join-honesty check of `TestLogic.Monomorphize.LambdaSetJoinHonesty`
over the standard catalogue of test programs, so that an `if` or a `case` whose
function-typed result claims a complete lambda set its branches do not support
is looked for in many kinds of program, not only at the one join that
`Compiler.Monomorphize.Solver.LssHonestSourcesPipelineTest` pins.

A _lambda set_ is the annotation on an arrow of a monomorphized type naming the
function values that can reach it, and an `LSet` claims its list is complete. A
join that claims `LSet js` while a branch brings a member outside `js`, or
brings unknown members (`LTop`, `LVar`), is dishonest; LSS\_026 is the rule that
an unknown inflow makes a resolution ⊤, never a set. The checker's module
docstring defines the terms in full and says what it does not check.

The fixture is every program that `SourceIR.Suite.StandardTestSuites` passes to
its caller's expectation.

What the tests establish:

  - `"satisfies LSS_026 at joins"`: for each program, `expectHonestJoins`
    compiles it with `TestLogic.TestPipeline.runToGlobalOpt` and finds no
    dishonest join in the graph the solver engine produced or in the globally
    optimized one; a failure message names the graph.

Among what is not tested: any lambda-set configuration other than the one
`runToGlobalOpt` uses.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetJoinHonesty exposing (expectHonestJoins)


{-| The join check over every standard test program.
-}
suite : Test
suite =
    Test.describe "Lambda set join honesty (LSS_026)"
        [ StandardTestSuites.expectSuite expectHonestJoins "satisfies LSS_026 at joins"
        ]
