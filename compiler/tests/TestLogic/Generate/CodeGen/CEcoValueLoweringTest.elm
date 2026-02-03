module TestLogic.Generate.CodeGen.CEcoValueLoweringTest exposing (suite)

{-| Test suite for CGEN\_013: CEcoValue MVars Always Lower to eco.value.

CEcoValue type variables must always lower to !eco.value in MLIR.

Note: This test is currently conservative and does not report violations
because distinguishing legitimate concrete types from incorrectly lowered
polymorphic types requires MonoType information that is not preserved in MLIR.
The test infrastructure is in place for future enhancement.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CEcoValueLowering exposing (expectCEcoValueLowering)


suite : Test
suite =
    Test.describe "CGEN_013: CEcoValue Lowering"
        [ StandardTestSuites.expectSuite expectCEcoValueLowering "passes CEcoValue lowering invariant"
        ]
