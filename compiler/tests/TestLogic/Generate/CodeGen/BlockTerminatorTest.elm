module TestLogic.Generate.CodeGen.BlockTerminatorTest exposing (suite)

{-| Test suite for CGEN_042: Block Terminator Presence invariant.

Every block in every region emitted by MLIR codegen must end with a
terminator operation (e.g. `eco.return`, `eco.jump`, `eco.yield`, `scf.yield`).

Note: `eco.case` is NOT a terminator - it is a value-producing expression.
`eco.yield` is used to terminate eco.case alternative regions.

-}

import TestLogic.Generate.CodeGen.BlockTerminator exposing (expectBlockTerminator)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_042: Block Terminator Presence"
        [ StandardTestSuites.expectSuite expectBlockTerminator "passes block terminator invariant"
        ]
