module TestLogic.Generate.CodeGen.JoinpointUniqueIdTest exposing (suite)

{-| Test suite for CGEN\_031: Joinpoint ID Uniqueness invariant.

Within a single `func.func`, each `eco.joinpoint` id must be unique.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)


suite : Test
suite =
    Test.describe "CGEN_031: Joinpoint ID Uniqueness"
        [ StandardTestSuites.expectSuite expectJoinpointUniqueId "passes joinpoint unique id invariant"
        ]
