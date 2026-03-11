module TestLogic.Monomorphize.FullyMonomorphicNoCEcoValueTest exposing (suite)

{-| Test suite for MONO\_024: Fully monomorphic specializations have no CEcoValue
in reachable MonoTypes.

For every specialization with a fully monomorphic key (no MVar, no MErased),
the entire expression tree must contain no CEcoValue MVar.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue)


suite : Test
suite =
    Test.describe "MONO_024: Fully monomorphic specs have no CEcoValue"
        [ StandardTestSuites.expectSuite expectFullyMonomorphicNoCEcoValue "has no CEcoValue in fully monomorphic specs"
        ]
