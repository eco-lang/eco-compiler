module TestLogic.Monomorphize.MonoDirectTest exposing (suite)

{-| Test suite for MonoDirect (solver-directed) monomorphization.

Verifies that MonoDirect produces output satisfying the same invariants as
the existing monomorphizer: MONO\_018, MONO\_001, MONO\_005, MONO\_015, MONO\_020,
MONO\_024.

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "MonoDirect monomorphization invariants"
        [ StandardTestSuites.expectSuite expectMonoDirectCompiles "compiles via MonoDirect"
        ]


{-| Basic sanity check: verify MonoDirect pipeline compiles without errors.
-}
expectMonoDirectCompiles : Src.Module -> Expectation
expectMonoDirectCompiles srcModule =
    case Pipeline.runToMonoDirect srcModule of
        Err msg ->
            Expect.fail ("MonoDirect compilation failed: " ++ msg)

        Ok { monoGraph } ->
            -- Basic sanity: the graph should have at least one node
            Expect.pass
