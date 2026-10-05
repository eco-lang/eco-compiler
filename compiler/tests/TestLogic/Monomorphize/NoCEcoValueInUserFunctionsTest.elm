module TestLogic.Monomorphize.NoCEcoValueInUserFunctionsTest exposing (suite)

{-| Runs the check that no `number` type variable, `MVar _ CNumber`, is left
anywhere in a monomorphized graph, over the standard test programs and the
programs with local tail-recursive functions.

The check is
`TestLogic.Monomorphize.NoCEcoValueInUserFunctions.expectNoResidualNumberVars`,
which compiles each program with `TestLogic.TestPipeline.runToMono` (the
substitution engine). Invariant MONO\_021 names this test: `CEcoValue`
variables may stay in user function and closure types by design, and the
forbidden residual, a `CNumber` variable, is MONO\_002.

The programs are those of `SourceIR.Suite.StandardTestSuites` and those of
`SourceIR.LocalTailRecCases`, which define tail-recursive functions inside a
`let`. The standard catalogue also includes `LocalTailRecCases`, so those
programs are given to the check twice.

The suite holds two parts:

  - the standard catalogue, in a group named `"has no residual number var"`;
  - the local tail-recursion programs, as one test that fails at the first
    program that fails.

Among what is not tested: `CEcoValue` variables, the graph the solver engine
produces, and the graph after global optimization.

-}

import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.NoCEcoValueInUserFunctions exposing (expectNoResidualNumberVars)


{-| The two parts described above, both checked with
`expectNoResidualNumberVars`.
-}
suite : Test
suite =
    Test.describe "MONO_021 / MONO_002: no residual CNumber MVar after monomorphization (CEcoValue allowed)"
        [ StandardTestSuites.expectSuite expectNoResidualNumberVars "has no residual number var"
        , LocalTailRecCases.expectSuite expectNoResidualNumberVars "has no residual number var"
        ]
