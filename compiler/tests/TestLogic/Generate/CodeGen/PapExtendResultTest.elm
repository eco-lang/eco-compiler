module TestLogic.Generate.CodeGen.PapExtendResultTest exposing (suite)

{-| Test suite for CGEN\_034: PapExtend Result Type invariant.

`eco.papExtend` must produce `!eco.value` result.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendResult exposing (expectPapExtendResult)


suite : Test
suite =
    Test.describe "CGEN_034: PapExtend Result Type"
        [ StandardTestSuites.expectSuite expectPapExtendResult "passes papExtend result invariant"
        ]
