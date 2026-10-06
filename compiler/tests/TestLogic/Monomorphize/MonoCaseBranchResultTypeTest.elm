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
    the case's stored result type (`Mono.eqLayout`).

  - `"join staging is honest after GlobalOpt"` (invariant GOPT\_003, as
    rewritten by plans/staging-honesty-and-production-test-pipeline.md P2.3):
    `expectHonestJoinStaging` compiles each program with
    `TestLogic.TestPipeline.runToGlobalOpt` and finds that no call claims
    known stages past the first through a callee whose join has differently
    staged branches. JoinpointABI category 6 holds joins a build's η-expansion
    cannot dissolve, so the check is not vacuous on the production pipeline.

Among what is not tested: the branches of an `if`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectHonestJoinStaging, expectMonoCaseBranchResultTypes)


{-| The group of tests checking case branch types over every standard test
program.
-}
suite : Test
suite =
    Test.describe "MONO_018 / GOPT_003: MonoCase branches match case result type"
        [ Test.describe "MONO_018: after monomorphization"
            [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypes "case branch types match" ]
        , Test.describe "GOPT_003: after global optimization no call claims a staging its callee's join does not have"
            [ StandardTestSuites.expectSuite expectHonestJoinStaging "join staging is honest after GlobalOpt" ]
        ]
