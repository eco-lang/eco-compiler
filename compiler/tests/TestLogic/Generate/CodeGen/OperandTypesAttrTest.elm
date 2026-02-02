module TestLogic.Generate.CodeGen.OperandTypesAttrTest exposing (suite)

{-| Test suite for CGEN\_032: Operand Types Attribute invariant.

`_operand_types` is required when an op has operands and must have correct length.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.OperandTypesAttr exposing (expectOperandTypesAttr)


suite : Test
suite =
    Test.describe "CGEN_032: Operand Types Attribute"
        [ StandardTestSuites.expectSuite expectOperandTypesAttr "passes operand types attr invariant"
        ]
