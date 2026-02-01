module TestLogic.Type.Constrain.TypedErasedCheckingParityTest exposing (suite)

{-| Consolidated test suite for ID assignment verification.

This module gathers all individual test suites and runs them with the
appropriate expectation functions.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import TestLogic.Type.Constrain.TypedErasedCheckingParity
    exposing
        ( expectEquivalentTypeChecking
        , expectEquivalentTypeCheckingCanonical
        )
import SourceIR.ForeignCases as ForeignCases
import SourceIR.KernelCases as KernelCases
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Type solver constrain and constrinWithIds type check equivalently"
        [ StandardTestSuites.expectSuite expectEquivalentTypeChecking "check equivalently"
        , TypeCheckFailsCases.expectSuite expectEquivalentTypeChecking "check equivalently"

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelCases.expectSuite expectEquivalentTypeCheckingCanonical "check equivalently"
        , ForeignCases.expectSuite expectEquivalentTypeCheckingCanonical "check equivalently"
        ]
