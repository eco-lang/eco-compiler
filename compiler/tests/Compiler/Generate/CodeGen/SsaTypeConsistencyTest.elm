module Compiler.Generate.CodeGen.SsaTypeConsistencyTest exposing (suite)

{-| Test suite for CGEN_0B1: SSA Type Consistency invariant.

Within each function, an SSA name must never be assigned different types.
This catches the "use of value '%X' expects different type than prior uses"
runtime error.

Note: SSA names like %0 are routinely reused across functions, so checking
must be per-function, not module-wide.

-}

import Compiler.Generate.CodeGen.SsaTypeConsistency exposing (expectSsaTypeConsistency)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0B1: SSA Type Consistency"
        [ StandardTestSuites.expectSuite expectSsaTypeConsistency "passes SSA type consistency invariant"
        ]
