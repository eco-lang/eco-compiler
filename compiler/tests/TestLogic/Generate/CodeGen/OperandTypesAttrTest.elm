module TestLogic.Generate.CodeGen.OperandTypesAttrTest exposing (suite)

{-| These tests make it a failure when the code generator leaves out, or
miscounts, the operand types it records on certain eco ops. Several other MLIR
checkers read operand types only from an op's `_operand_types` attribute and
skip an op that lacks it, so a missing attribute would otherwise pass them. The
check itself, and the ops it covers, are described in
`TestLogic.Generate.CodeGen.OperandTypesAttr`.

The programs are the standard catalogue of `SourceIR` test programs, gathered
by `SourceIR.Suite.StandardTestSuites`. Most are fixed; some, from its fuzzing
case modules, can vary from run to run.

What the tests establish:

  - `suite` compiles each program to MLIR and checks, with
    `expectOperandTypesAttr`, that compilation succeeds and that every op on
    that module's list which has at least one operand carries an
    `_operand_types` array with one entry per operand.

Among what is not tested: ops not on that list; whether each entry is the
right type for its operand; and programs from the `SourceIR` case modules that
`StandardTestSuites` leaves out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.OperandTypesAttr exposing (expectOperandTypesAttr)


{-| The operand-types check, applied to every program of the standard
catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_032: Operand Types Attribute"
        [ StandardTestSuites.expectSuite expectOperandTypesAttr "passes operand types attr invariant"
        ]
