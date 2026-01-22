module Compiler.Canonicalize.IdAssignmentTest exposing (suite)

{-| Consolidated test suite for ID assignment verification.

This module gathers all individual test suites and runs them with the
appropriate expectation functions.

-}

import Compiler.Canonicalize.IdAssignment exposing (expectUniqueIds, expectUniqueIdsCanonical)
import Compiler.ForeignTests as ForeignTests
import Compiler.KernelTests as KernelTests
import Compiler.StandardTestSuites as StandardTestSuites
import Compiler.TypeCheckFails as TypeCheckFails
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Unique IDs for all nodes in Canonical form"
        [ StandardTestSuites.expectSuite expectUniqueIds "has unique IDs"
        , TypeCheckFails.expectSuite expectUniqueIds "has unique IDs"

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelTests.expectSuite expectUniqueIdsCanonical "has unique IDs"
        , ForeignTests.expectSuite expectUniqueIdsCanonical "has unique IDs"
        ]
