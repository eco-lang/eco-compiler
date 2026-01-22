module Compiler.Generate.CodeGen.JoinpointUniqueIdTest exposing (suite)

{-| Test suite for CGEN_031: Joinpoint ID Uniqueness invariant.

Within a single `func.func`, each `eco.joinpoint` id must be unique.

-}

import Compiler.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_031: Joinpoint ID Uniqueness"
        [ StandardTestSuites.expectSuite expectJoinpointUniqueId "passes joinpoint unique id invariant"
        ]
