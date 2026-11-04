module TestLogic.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| These tests exist so that a construct or closure op whose slot kinds
misdescribe its operands is caught in the MLIR the code generator produces.

An _unboxed bitmap_ is the integer attribute in which a tuple construct op
records how its stored operands are kept, as one 2-bit _slot kind_ per slot:
boxed, or an unboxed Int, Float or Char. A record or custom construct op
records the same kinds in a `slot_kinds` array, one entry per field, and so
does an `eco.papCreate` or `eco.papExtend`, one entry per captured operand or
new argument. A list cons records only whether its head is
unboxed, in the boolean `head_unboxed`. No other op carries an integer bitmap
(wide-object Phase 3D). The rules that the check applies, and the operands each
op's kinds cover, are set out in the module docstring of
`TestLogic.Generate.CodeGen.UnboxedBitmap`.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` collects them. Each program is compiled to
MLIR by the test pipeline. The catalogue includes `SourceIR.WideObjectCases`:
records and constructors of up to 30 fields, a record whose boxed fields sit
past slot 15, and closures capturing or extending by 26 and 27 `Int`s, past
the slots the old fixed bitmaps described.

What the tests establish, for each program in the catalogue:

  - `expectUnboxedBitmap`: it compiles to MLIR, and in each checked op the
    bitmap slot or `slot_kinds` entry of every compared operand holds the kind
    of that operand's recorded type, each list cons's `head_unboxed` is true
    exactly when its head is `i64`, `f64` or `i32`, no compared operand is an
    `i1`, and no record or custom construct op carries a stale
    `unboxed_bitmap`.

  - `expectClosureKindLimits`: it compiles to MLIR, and its closure ops' kind
    attributes have the post-Phase-2 form, as `checkClosureKindLimits` sets it
    out: `slot_kinds` arrays of at most 2047 entries and no u64 closure bitmap
    (bug B4 of `plans/wide-object-tail-kind-words.md`: before Phase 2 the
    generator emitted a `newargs_unboxed_bitmap` of 26 Int kinds, 52 bits,
    where the backend's u64 bitmap held 25 slots).

The exact `slot_kinds` of particular wide programs are pinned by the unit
tests `Compiler.GenerateMlir.OpsSlotKindsTest` (construct ops) and
`Compiler.GenerateMlir.ExprPapSlotKindsTest` (closure ops).

Among what is not tested: the `head_kind` attribute of `eco.construct.list`,
the kinds of `eco.papCreateGroup` ops (only their limits), whether a recorded
operand type matches the SSA value actually passed, and any program outside the
catalogue.

-}

import Compiler.IR.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (violationsToExpectation)
import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (checkClosureKindLimits, expectUnboxedBitmap)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The standard catalogue of `SourceIR` programs, checked with
`expectUnboxedBitmap` and with `expectClosureKindLimits`, gathered under one
group.
-}
suite : Test
suite =
    Test.describe "CGEN_026/027/003/049: Unboxed Bitmap Consistency"
        [ StandardTestSuites.expectSuite expectUnboxedBitmap "passes unboxed bitmap invariant"
        , StandardTestSuites.expectSuite expectClosureKindLimits "keeps closure kind attributes within the backend's slot limits"
        ]


{-| Compiles `srcModule` with `TestLogic.TestPipeline.runToMlir` and passes
when its closure ops respect `checkClosureKindLimits`.
-}
expectClosureKindLimits : Src.Module -> Expect.Expectation
expectClosureKindLimits srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkClosureKindLimits mlirModule)
