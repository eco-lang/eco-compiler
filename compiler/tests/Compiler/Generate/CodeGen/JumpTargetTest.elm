module Compiler.Generate.CodeGen.JumpTargetTest exposing (suite)

{-| Test suite for CGEN_030: Jump Target Validity invariant.

`eco.jump` target must refer to a lexically enclosing `eco.joinpoint` with
matching id, and argument types must match.

-}

import Compiler.Generate.CodeGen.JumpTarget exposing (expectJumpTarget)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_030: Jump Target Validity"
        [ StandardTestSuites.expectSuite expectJumpTarget "passes jump target invariant"
        ]
