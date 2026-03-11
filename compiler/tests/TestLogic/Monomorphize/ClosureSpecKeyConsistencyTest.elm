module TestLogic.Monomorphize.ClosureSpecKeyConsistencyTest exposing (suite)

{-| Test suite for MONO\_025: Closure MonoType matches specialization key.

For every closure/function specialization, the closure's parameter types and
result type must be consistent with what the specialization key MonoType implies.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.ClosureSpecKeyConsistency exposing (expectClosureSpecKeyConsistency)


suite : Test
suite =
    Test.describe "MONO_025: Closure MonoType matches specialization key"
        [ StandardTestSuites.expectSuite expectClosureSpecKeyConsistency "has closure types matching spec keys"
        ]
