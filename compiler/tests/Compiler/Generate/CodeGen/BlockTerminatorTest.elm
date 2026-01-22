module Compiler.Generate.CodeGen.BlockTerminatorTest exposing (suite)

{-| Test suite for CGEN_042: Block Terminator Presence invariant.

Every block in every region emitted by MLIR codegen must end with a
terminator operation (e.g. `eco.return`, `eco.jump`, `scf.yield`).

-}

import Compiler.Generate.CodeGen.BlockTerminator exposing (expectBlockTerminator)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_042: Block Terminator Presence"
        [ StandardTestSuites.expectSuite expectBlockTerminator "passes block terminator invariant"
        ]
