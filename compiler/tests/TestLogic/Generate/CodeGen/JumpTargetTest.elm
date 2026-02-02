module TestLogic.Generate.CodeGen.JumpTargetTest exposing (suite)

{-| Test suite for CGEN\_030: Jump Target Validity invariant.

`eco.jump` target must refer to a lexically enclosing `eco.joinpoint` with
matching id, and argument types must match.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JumpTarget exposing (expectJumpTarget)


suite : Test
suite =
    Test.describe "CGEN_030: Jump Target Validity"
        [ StandardTestSuites.expectSuite expectJumpTarget "passes jump target invariant"
        ]
