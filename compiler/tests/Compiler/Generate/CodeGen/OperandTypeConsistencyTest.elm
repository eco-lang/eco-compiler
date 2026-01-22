module Compiler.Generate.CodeGen.OperandTypeConsistencyTest exposing (suite)

{-| Test suite for CGEN_040: Operand Type Consistency invariant.

For any operation with `_operand_types` attribute, the list length must equal
SSA operand count and each declared type must match the corresponding SSA
operand type.

-}

import Compiler.Generate.CodeGen.OperandTypeConsistency exposing (expectOperandTypeConsistency)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_040: Operand Type Consistency"
        [ StandardTestSuites.expectSuite expectOperandTypeConsistency "passes operand type consistency invariant"
        ]
