module TestLogic.Monomorphize.LambdaSetWellFormedTest exposing (suite)

{-| Runs the lambda-set well-formedness check of
`TestLogic.Monomorphize.LambdaSetWellFormed` over the standard catalogue of
test programs, so that an empty `LSet`, or a member list out of order, is
looked for in many kinds of program rather than in the three fixtures of each
of the P tests it was taken from (`Compiler.Monomorphize.Solver.LssPapMembersTest`
and `Compiler.Monomorphize.Solver.LssHonestSourcesPipelineTest`).

A _lambda set_ is the annotation on an arrow of a monomorphized type naming the
function values that can reach it. LSS\_001 says an `LSet` is never empty in a
pruned graph (an unconstrained slot reads back as ⊤) and that `LSet` and
`LPartial` member lists are strictly ascending. The checker's module docstring
says where it looks and what it does not check.

The fixture is every program that `SourceIR.Suite.StandardTestSuites` passes to
its caller's expectation.

What the test establishes:

  - `"satisfies LSS_001"`: for each program, `expectLambdaSetsWellFormed`
    compiles it with `TestLogic.TestPipeline.runToGlobalOpt` and finds no empty
    `LSet` and no member list that is not strictly ascending, in the registry
    types, node types and expression types of both the solver engine's graph
    and the globally optimized one.

Among what is not tested: any lambda-set configuration other than the one
`runToGlobalOpt` uses, and the substitution engine.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetWellFormed exposing (expectLambdaSetsWellFormed)


{-| The well-formedness check over every standard test program.
-}
suite : Test
suite =
    Test.describe "Lambda sets well formed (LSS_001)"
        [ StandardTestSuites.expectSuite expectLambdaSetsWellFormed "satisfies LSS_001"
        ]
