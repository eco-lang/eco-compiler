module TestLogic.Generate.CodeGen.PapExtendResultTest exposing (suite)

{-| Test suite for CGEN_034: PapExtend Result Type invariant.

`eco.papExtend` must produce `!eco.value` result.

-}

import TestLogic.Generate.CodeGen.PapExtendResult exposing (expectPapExtendResult)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_034: PapExtend Result Type"
        [ StandardTestSuites.expectSuite expectPapExtendResult "passes papExtend result invariant"
        ]
