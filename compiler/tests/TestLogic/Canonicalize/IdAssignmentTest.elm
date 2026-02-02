module TestLogic.Canonicalize.IdAssignmentTest exposing (suite)

{-| Consolidated test suite for ID assignment verification.

This module gathers all individual test suites and runs them with the
appropriate expectation functions.

-}

import SourceIR.ForeignCases as ForeignCases
import SourceIR.KernelCases as KernelCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)
import TestLogic.Canonicalize.IdAssignment exposing (expectUniqueIds, expectUniqueIdsCanonical)


suite : Test
suite =
    Test.describe "Unique IDs for all nodes in Canonical form"
        [ StandardTestSuites.expectSuite expectUniqueIds "has unique IDs"
        , TypeCheckFailsCases.expectSuite expectUniqueIds "has unique IDs"

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelCases.expectSuite expectUniqueIdsCanonical "has unique IDs"
        , ForeignCases.expectSuite expectUniqueIdsCanonical "has unique IDs"
        ]
