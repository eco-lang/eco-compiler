module TestLogic.Generate.CodeGen.BlockTerminatorTest exposing (suite)

{-| Nothing in `Mlir.Mlir` stops the code generator from ending a block with an
op that does not pass control elsewhere, because a block's `terminator` field
accepts any op. These tests make a block that ends that way fail a test instead
of going unnoticed.

The programs are the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` describes it. Each one is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir`.

What the tests establish:

  - `suite` passes `expectBlockTerminator` to the standard suite. For each
    program it checks that, for every op at any depth and every region of that
    op, each block's `terminator` is an op whose name is on the list that
    `isValidTerminator` in `TestLogic.Generate.CodeGen.Invariants` accepts. A
    block ending in `eco.case` fails, since `eco.case` is not on that list. A
    program that fails to compile fails its test too.

Among what is not tested: where each kind of terminator may appear, since only
the name is compared and `eco.yield`, for example, passes at the end of any
block; an op in a block's body that is itself a terminator; and programs outside
the standard catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.BlockTerminator exposing (expectBlockTerminator)


{-| The block-terminator check applied to every program in the standard
catalogue, as one group of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_042: Block Terminator Presence"
        [ StandardTestSuites.expectSuite expectBlockTerminator "passes block terminator invariant"
        ]
