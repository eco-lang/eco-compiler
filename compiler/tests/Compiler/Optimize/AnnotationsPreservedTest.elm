module Compiler.Optimize.AnnotationsPreservedTest exposing (suite)

{-| Test suite for invariant TOPT_003: Top-level annotations preserved in local graph.

-}

import Compiler.Optimize.AnnotationsPreserved exposing (expectAnnotationsPreserved)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Top-level annotations preserved in local graph (TOPT_003)"
        [ StandardTestSuites.expectSuite expectAnnotationsPreserved "has preserved annotations"
        ]
