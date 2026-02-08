module TestLogic.Monomorphize.MonoCtorLayoutIntegrityTest exposing (suite)

{-| Test suite for invariant MONO\_013: Constructor layouts define consistent custom types.

For each custom type and each constructor:

  - Verify CtorShape field count and ordering match the constructor definition.
  - Assert unboxedBitmap matches which fields are unboxed primitives.
  - Check all construction and pattern matching nodes adhere to the same layout.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoCtorLayoutIntegrity exposing (expectMonoCtorLayoutIntegrity)


suite : Test
suite =
    Test.describe "MONO_013: Constructor layouts consistent"
        [ StandardTestSuites.expectSuite expectMonoCtorLayoutIntegrity "has consistent constructor layouts"
        ]
