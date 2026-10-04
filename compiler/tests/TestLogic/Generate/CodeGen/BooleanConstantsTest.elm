module TestLogic.Generate.CodeGen.BooleanConstantsTest exposing (suite)

{-| A Bool in generated MLIR is a raw `i1` only in SSA operand context; in a heap
object, in a closure capture and at a function boundary it is boxed as
`!eco.value`, as `Compiler.Generate.MLIR.Types` describes. These tests make an
`i1` recorded among the operand types of an op that builds a heap object or a
closure fail a test instead of going unnoticed.

The programs are the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` describes it. Each one is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir`.

What the tests establish:

  - `suite` passes `expectBooleanConstants` to the standard suite. For each
    program it checks that no `eco.construct.*` or `eco.papCreate` op has `i1`
    among the types in its `_operand_types` attribute. It also checks that an
    `eco.constant` whose `value` attribute is `"True"` or `"False"` has a
    `!eco.value` result, but, as `TestLogic.Generate.CodeGen.BooleanConstants`
    describes, the `eco.constant` ops the code generator emits carry no `value`
    attribute, so that half examines none of them. A program that fails to
    compile fails its test too.

Among what is not tested: an op with no `_operand_types` attribute; the operands
of `eco.papExtend`, `eco.call` and every other op; the result type of a Bool
`eco.constant` the code generator emits; and programs outside the standard
catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.BooleanConstants exposing (expectBooleanConstants)


{-| The Bool-representation check applied to every program in the standard
catalogue, as one group of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_009: Boolean Constants"
        [ StandardTestSuites.expectSuite expectBooleanConstants "passes boolean constants invariant"
        ]
