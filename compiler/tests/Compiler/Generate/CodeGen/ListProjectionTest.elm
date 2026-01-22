module Compiler.Generate.CodeGen.ListProjectionTest exposing (suite)

{-| Test suite for CGEN_021: List Projection invariant.

List destructuring must use only `eco.project.list_head` and `eco.project.list_tail`.

-}

import Compiler.Generate.CodeGen.ListProjection exposing (expectListProjection)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_021: List Projection"
        [ StandardTestSuites.expectSuite expectListProjection "passes list projection invariant"
        ]
