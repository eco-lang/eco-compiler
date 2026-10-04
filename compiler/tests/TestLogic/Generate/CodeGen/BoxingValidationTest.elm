module TestLogic.Generate.CodeGen.BoxingValidationTest exposing (suite)

{-| The code generator moves a value between its primitive and its boxed form
with two ops, `eco.box` and `eco.unbox`, and nothing in the MLIR types stops it
emitting one with the wrong type on either side. This suite runs the check for
that, `TestLogic.Generate.CodeGen.BoxingValidation.expectBoxingValidation`, on
every program of the standard catalogue rather than on a few chosen by hand.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites.expectSuite`
collects from the `SourceIR` case modules it includes. Most of its programs are
fixed; those of its fuzz tests vary from run to run.

What the tests establish:

  - `suite` applies the check to each catalogue program: a program passes when
    it compiles to MLIR through `TestLogic.TestPipeline.runToMlir` and, in the
    result, every `eco.box` op records an `i64`, `f64`, `i16` or `i1` operand
    type and has a `!eco.value` result, and every `eco.unbox` op records a
    `!eco.value` operand type and has a result of one of those four types. A
    program that fails to compile fails.

Among what is not tested:

  - the type of the value an op actually consumes: the operand type checked is
    the one the op records in its `_operand_types` attribute, as
    `BoxingValidation` describes;
  - an op that does not record exactly one operand type, or does not have
    exactly one result, which is skipped;
  - ops with other names, such as the `eco.box.i64` and `eco.box.f64` ops that
    bytes decoding emits.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.BoxingValidation exposing (expectBoxingValidation)


{-| The boxing check applied to every program of the standard catalogue,
grouped under `CGEN_001: Boxing Validation`.
-}
suite : Test
suite =
    Test.describe "CGEN_001: Boxing Validation"
        [ StandardTestSuites.expectSuite expectBoxingValidation "passes boxing validation invariant"
        ]
