module TestLogic.Generate.CodeGen.CaseTagsCountTest exposing (suite)

{-| Test suite for CGEN_029: Case Tags Count invariant.

The `eco.case` `tags` array length must equal the number of alternative regions.

-}

import TestLogic.Generate.CodeGen.CaseTagsCount exposing (expectCaseTagsCount)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_029: Case Tags Count"
        [ StandardTestSuites.expectSuite expectCaseTagsCount "passes case tags count invariant"
        ]
