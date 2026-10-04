module TestLogic.Monomorphize.MonoCaseBranchResultTypeTest exposing (suite)

{-| Runs the case-branch type check of
`TestLogic.Monomorphize.MonoCaseBranchResultType` over the standard catalogue
of test programs. A `MonoCase` records its own result type, and `Mono.typeOf`
of the case returns that record without looking at the branches, so a branch
of a different type would make the type reported for the case wrong for that
branch.

The fixture is every program that `SourceIR.Suite.StandardTestSuites` passes
to its caller's expectation.

What the tests establish:

  - `"case branch types match"`: for each program,
    `expectMonoCaseBranchResultTypes` compiles it with
    `TestLogic.TestPipeline.runToMono` and finds that every body in each
    `MonoCase`'s jump list, and every `Inline` leaf of its decision tree, has
    a type `==` to the case's stored result type.

Among what is not tested: the graph after the inliner and global optimization
have run, since `runToMono` stops before them, and the branches of an `if`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes)


{-| The group of tests checking case branch types over every standard test
program.
-}
suite : Test
suite =
    Test.describe "GOPT_003: MonoCase branches match case result type"
        [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypes "case branch types match"
        ]
