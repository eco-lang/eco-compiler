module TestLogic.Generate.CodeGen.OperandTypeConsistencyTest exposing (suite)

{-| Test suite for CGEN\_040: Operand Type Consistency invariant.

For any operation with `_operand_types` attribute, the list length must equal
SSA operand count and each declared type must match the corresponding SSA
operand type.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.OperandTypeConsistency exposing (expectOperandTypeConsistency)


suite : Test
suite =
    Test.describe "CGEN_040: Operand Type Consistency"
        [ StandardTestSuites.expectSuite expectOperandTypeConsistency "passes operand type consistency invariant"
        ]
