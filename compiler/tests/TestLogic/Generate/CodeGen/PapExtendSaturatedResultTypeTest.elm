module TestLogic.Generate.CodeGen.PapExtendSaturatedResultTypeTest exposing (suite)

{-| Test suite for CGEN\_056: Saturated PapExtend Result Type invariant.

For every `eco.papExtend` that represents a fully saturated closure application
of some `func.func @f`, the result MLIR type must equal @f's return type.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendSaturatedResultType exposing (expectPapExtendSaturatedResultType)


suite : Test
suite =
    Test.describe "CGEN_056: Saturated PapExtend Result Type"
        [ StandardTestSuites.expectSuite expectPapExtendSaturatedResultType "passes saturated papExtend result type invariant"
        ]
