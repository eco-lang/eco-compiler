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

  - `"case branch types match"` (invariant MONO\_018): for each program,
    `expectMonoCaseBranchResultTypes` compiles it with
    `TestLogic.TestPipeline.runToMono` and finds that every body in each
    `MonoCase`'s jump list, and every `Inline` leaf of its decision tree, has
    a type `==` to the case's stored result type.

  - `"case branch types match after GlobalOpt"` (GOPT\_003, BUG PIN): the
    same check on the graph `TestLogic.TestPipeline.runToGlobalOpt` produces.
    It FAILS today on two programs, JoinpointABI "2.1 majority2Flat" and
    HigherOrder "Case returns differently staged lambdas": a `case` whose
    branches return differently staged lambdas keeps its monomorphized
    (curried) result type while the flat branches are retyped
    `[Int, Int] -> Int` and the curried branch is not wrapped. The cause is
    that `Compiler.GlobalOpt.Staging.Rewriter`'s `MonoCase` arm never
    retypes the case and the GOPT\_003 enforcer named in invariants.csv
    (`rewriteCaseForAbi` / `buildAbiWrapperGO` in
    `Compiler.GlobalOpt.MonoGlobalOptimize`) is unreachable;
    `Staging.validateClosureStaging` is a no-op. Codegen copes by calling such
    values `segmentation_unknown`, so no wrong output is known. Full notes:
    /work/gopt003-issue.md.

Among what is not tested: the branches of an `if`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes, expectMonoCaseBranchResultTypesAfterGlobalOpt)


{-| The group of tests checking case branch types over every standard test
program.
-}
suite : Test
suite =
    Test.describe "MONO_018 / GOPT_003: MonoCase branches match case result type"
        [ Test.describe "MONO_018: after monomorphization"
            [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypes "case branch types match" ]
        , Test.describe "GOPT_003 BUG PIN: after global optimization (staging leaves differently staged case branches unnormalized)"
            [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypesAfterGlobalOpt "case branch types match after GlobalOpt" ]
        ]
