module Compiler.Canonicalize.GlobalNamesTest exposing (suite)

{-| Test suite for invariant CANON_001: Global names are fully qualified.

This module gathers test cases and runs them with the GlobalNames test logic.

-}

import Compiler.Canonicalize.GlobalNames exposing (expectGlobalNamesQualified, expectGlobalNamesQualifiedCanonical)
import Compiler.ForeignTests as ForeignTests
import Compiler.KernelTests as KernelTests
import Compiler.StandardTestSuites as StandardTestSuites
import Compiler.TypeCheckFails as TypeCheckFails
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Global names are fully qualified (CANON_001)"
        [ StandardTestSuites.expectSuite expectGlobalNamesQualified "has qualified global names"
        , TypeCheckFails.expectSuite expectGlobalNamesQualified "has qualified global names"

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelTests.expectSuite expectGlobalNamesQualifiedCanonical "has qualified global names"
        , ForeignTests.expectSuite expectGlobalNamesQualifiedCanonical "has qualified global names"
        ]
