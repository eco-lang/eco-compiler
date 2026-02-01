module TestLogic.Canonicalize.GlobalNamesTest exposing (suite)

{-| Test suite for invariant CANON_001: Global names are fully qualified.

This module gathers test cases and runs them with the GlobalNames test logic.

-}

import TestLogic.Canonicalize.GlobalNames exposing (expectGlobalNamesQualified, expectGlobalNamesQualifiedCanonical)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import SourceIR.ForeignCases as ForeignCases
import SourceIR.KernelCases as KernelCases
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Global names are fully qualified (CANON_001)"
        [ StandardTestSuites.expectSuite expectGlobalNamesQualified "has qualified global names"
        , TypeCheckFailsCases.expectSuite expectGlobalNamesQualified "has qualified global names"

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelCases.expectSuite expectGlobalNamesQualifiedCanonical "has qualified global names"
        , ForeignCases.expectSuite expectGlobalNamesQualifiedCanonical "has qualified global names"
        ]
