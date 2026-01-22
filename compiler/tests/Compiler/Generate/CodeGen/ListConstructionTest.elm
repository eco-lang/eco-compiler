module Compiler.Generate.CodeGen.ListConstructionTest exposing (suite)

{-| Test suite for CGEN_016: List Construction invariant.

List values must use `eco.construct.list` for cons cells and `eco.constant Nil`
for empty lists; never `eco.construct.custom`.

-}

import Compiler.Generate.CodeGen.ListConstruction exposing (expectListConstruction)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_016: List Construction"
        [ StandardTestSuites.expectSuite expectListConstruction "passes list construction invariant"
        ]
