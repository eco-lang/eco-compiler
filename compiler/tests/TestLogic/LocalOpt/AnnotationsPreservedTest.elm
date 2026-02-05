module TestLogic.LocalOpt.AnnotationsPreservedTest exposing (suite)

{-| Test suite for invariant TOPT\_003: Top-level annotations preserved in local graph.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.AnnotationsPreserved exposing (expectAnnotationsPreserved)


suite : Test
suite =
    Test.describe "Top-level annotations preserved in local graph (TOPT_003)"
        [ StandardTestSuites.expectSuite expectAnnotationsPreserved "has preserved annotations"
        ]
