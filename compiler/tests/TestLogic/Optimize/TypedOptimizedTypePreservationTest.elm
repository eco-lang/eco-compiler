module TestLogic.Optimize.TypedOptimizedTypePreservationTest exposing (suite)

{-| Test suite for invariant TOPT_004: Typed optimization is type preserving.

TOPT_004: The Can.Type attached to each TOpt.Expr must match the expected type
derived via local typing rules.

Key checks:

  - Literals have expected primitive types (Bool, Int, Float, Char, String, Unit)
  - VarLocal matches type from binding site
  - VarKernel matches type from KernelTypeEnv
  - VarGlobal is an instance of the annotation scheme
  - Function type is curried chain of param types → body type
  - Call/TailCall type is result of applying args to function type
  - Let type matches body type
  - If branches and else all match If type
  - Destruct type matches body type
  - Case has all Inline expressions and Jump targets matching result type

-}

import TestLogic.Optimize.TypePreservation exposing (expectTypePreservation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "TypedOptimized type preservation (TOPT_004)"
        [ StandardTestSuites.expectSuite expectTypePreservation "preserves types"
        ]
