module TestLogic.Generate.CodeGen.PartialApplicationRoutingTest exposing (suite)

{-| Test suite for CGEN\_002: Partial Applications Through Closure Generation.

Partial applications must go through eco.papCreate/papExtend, not eco.call.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PartialApplicationRouting exposing (expectPartialApplicationRouting)


suite : Test
suite =
    Test.describe "CGEN_002: Partial Application Routing"
        [ StandardTestSuites.expectSuite expectPartialApplicationRouting "passes partial application routing invariant"
        ]
