module TestLogic.Generate.CodeGen.BoxingValidationTest exposing (suite)

{-| Test suite for CGEN\_001: Boxing Validation invariant.

Boxing operations must only convert between primitive MLIR types (i64, f64, i16)
and `!eco.value`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.BoxingValidation exposing (expectBoxingValidation)


suite : Test
suite =
    Test.describe "CGEN_001: Boxing Validation"
        [ StandardTestSuites.expectSuite expectBoxingValidation "passes boxing validation invariant"
        ]
