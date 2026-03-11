module TestLogic.Monomorphize.NoCEcoValueInUserFunctionsTest exposing (suite)

{-| Test suite for MONO\_021: No CEcoValue MVar in user-defined function types.

After monomorphization, no user-defined function or closure MonoType may contain
MVar with CEcoValue constraint. This test runs the standard test suite plus
targeted cases for local tail-recursive functions that previously failed to
specialize.

-}

import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.NoCEcoValueInUserFunctions exposing (expectNoCEcoValueInUserFunctions)


suite : Test
suite =
    Test.describe "MONO_021: No CEcoValue MVar in user-defined function types"
        [ StandardTestSuites.expectSuite expectNoCEcoValueInUserFunctions "has no CEcoValue in user functions"
        , LocalTailRecCases.expectSuite expectNoCEcoValueInUserFunctions "has no CEcoValue in user functions"
        ]
