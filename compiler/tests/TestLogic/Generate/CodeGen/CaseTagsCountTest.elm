module TestLogic.Generate.CodeGen.CaseTagsCountTest exposing (suite)

{-| Test suite for CGEN\_029: Case Tags Count invariant.

The `eco.case` `tags` array length must equal the number of alternative regions.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseTagsCount exposing (expectCaseTagsCount)


suite : Test
suite =
    Test.describe "CGEN_029: Case Tags Count"
        [ StandardTestSuites.expectSuite expectCaseTagsCount "passes case tags count invariant"
        ]
