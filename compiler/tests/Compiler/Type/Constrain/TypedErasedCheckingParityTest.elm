module Compiler.Type.Constrain.TypedErasedCheckingParityTest exposing (suite)

{-| Consolidated test suite for ID assignment verification.

This module gathers all individual test suites and runs them with the
appropriate expectation functions.

-}

import Compiler.ForeignTests as ForeignTests
import Compiler.KernelTests as KernelTests
import Compiler.StandardTestSuites as StandardTestSuites
import Compiler.Type.Constrain.TypedErasedCheckingParity
    exposing
        ( expectEquivalentTypeChecking
        , expectEquivalentTypeCheckingCanonical
        )
import Compiler.TypeCheckFails as TypeCheckFails
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Type solver constrain and constrinWithIds type check equivalently"
        [ StandardTestSuites.expectSuite expectEquivalentTypeChecking "check equivalently"
        , TypeCheckFails.expectSuite expectEquivalentTypeChecking "check equivalently"

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelTests.expectSuite expectEquivalentTypeCheckingCanonical "check equivalently"
        , ForeignTests.expectSuite expectEquivalentTypeCheckingCanonical "check equivalently"
        ]
