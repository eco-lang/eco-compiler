module TestLogic.Monomorphize.NoCEcoValueInUserFunctionsTest exposing (suite)

{-| Runs the check that no user-defined function or closure is left with a
`CEcoValue` type variable after monomorphization, over the standard test
programs and the programs with local tail-recursive functions. The whole suite
is wrapped in `Test.skip`, so none of it runs.

A `CEcoValue` variable is an `MVar` left in a `MonoType` for a value that is
always boxed; `Compiler.AST.Monomorphized` describes it. The check is
`TestLogic.Monomorphize.NoCEcoValueInUserFunctions.expectNoCEcoValueInUserFunctions`,
which compiles each program with `TestLogic.TestPipeline.runToMono` (the
substitution engine). As that module describes, it reports no variable of either
kind, so if the suite were run, a test would pass exactly when `runToMono`
succeeds on its programs.

The programs are those of `SourceIR.Suite.StandardTestSuites` and those of
`SourceIR.LocalTailRecCases`, which define tail-recursive functions inside a
`let`. The standard catalogue also includes `LocalTailRecCases`, so those
programs are given to the check twice.

The suite holds two parts:

  - the standard catalogue, in a group named
    `"has no CEcoValue in user functions"`;
  - the local tail-recursion programs, as one test that fails at the first
    program that fails.

Among what is not tested: anything at all while the suite is skipped; and, if
it were run, the presence of a `CEcoValue` variable in any type, the graph the
solver engine produces, and the graph after global optimization.

-}

import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.NoCEcoValueInUserFunctions exposing (expectNoCEcoValueInUserFunctions)


{-| The two parts described above, both checked with
`expectNoCEcoValueInUserFunctions` and skipped as a whole.
-}
suite : Test
suite =
    Test.describe "MONO_021: No CEcoValue MVar in user-defined function types"
        [ StandardTestSuites.expectSuite expectNoCEcoValueInUserFunctions "has no CEcoValue in user functions"
        , LocalTailRecCases.expectSuite expectNoCEcoValueInUserFunctions "has no CEcoValue in user functions"
        ]
        |> Test.skip
