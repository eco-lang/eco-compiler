module TestLogic.Generate.CodeGen.EcoUnboxSanityTest exposing (suite)

{-| Test suite for CGEN_0E2: eco.unbox Sanity invariant.

eco.unbox converts !eco.value (boxed) to a primitive type (i1, i16, i64, f64).
This test verifies:

1.  The operand is !eco.value
2.  The result is a primitive type (i1, i16, i64, or f64)

Note: i32 is NOT a primitive in eco.

-}

import TestLogic.Generate.CodeGen.EcoUnboxSanity exposing (expectEcoUnboxSanity)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0E2: eco.unbox Sanity"
        [ StandardTestSuites.expectSuite expectEcoUnboxSanity "passes eco.unbox sanity invariant"
        ]
