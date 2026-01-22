module Compiler.Generate.CEcoValueLayoutTest exposing (suite)

{-| Test suite for invariant MONO\_003: CEcoValue layout is consistent.
-}

import Compiler.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CEcoValue layout is consistent (MONO_003)"
        [ StandardTestSuites.expectSuite expectValidCEcoValueLayout "has valid CEcoValue layout"
        ]
