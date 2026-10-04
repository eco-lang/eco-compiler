module TestLogic.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| These tests exist so that a construct or closure op whose unboxed bitmap
misdescribes its operands is caught in the MLIR the code generator produces.

An _unboxed bitmap_ is the integer attribute in which a tuple, record or custom
construct op, an `eco.papCreate` or an `eco.papExtend` records how its stored
operands are kept, as one 2-bit _slot kind_ per slot: boxed, or an unboxed Int,
Float or Char. A list cons records only whether its head is
unboxed, in the boolean `head_unboxed`. The rules that the check applies, and
the operands each op's bitmap covers, are set out in the module docstring of
`TestLogic.Generate.CodeGen.UnboxedBitmap`.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` collects them. Each program is compiled to
MLIR by the test pipeline.

What the tests establish:

  - For each program in the catalogue, `expectUnboxedBitmap` checks that it
    compiles to MLIR, that in each checked op the bitmap slot of every compared
    operand holds the kind of that operand's recorded type, that each list
    cons's `head_unboxed` is true exactly when its head is `i64`, `f64` or
    `i16`, and that no compared operand is an `i1`.

Among what is not tested: the `head_kind` attribute of `eco.construct.list`,
`eco.papCreateGroup` ops, any slot past the sixteenth (which the checker, run
on JavaScript's 32-bit `Bitwise`, does not read correctly), whether a recorded
operand type matches the SSA value actually passed, and any program outside the
catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (expectUnboxedBitmap)


{-| The standard catalogue of `SourceIR` programs, each checked with
`expectUnboxedBitmap`, gathered under one group.
-}
suite : Test
suite =
    Test.describe "CGEN_026/027/003/049: Unboxed Bitmap Consistency"
        [ StandardTestSuites.expectSuite expectUnboxedBitmap "passes unboxed bitmap invariant"
        ]
