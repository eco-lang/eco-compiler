module TestLogic.Generate.CEcoValueLayoutTest exposing (suite)

{-| Test suite for invariant MONO\_003: CEcoValue layout is consistent.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)


suite : Test
suite =
    Test.describe "CEcoValue layout is consistent (MONO_003)"
        [ StandardTestSuites.expectSuite expectValidCEcoValueLayout "has valid CEcoValue layout"
        ]
