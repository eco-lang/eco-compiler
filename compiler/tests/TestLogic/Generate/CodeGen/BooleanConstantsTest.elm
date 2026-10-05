module TestLogic.Generate.CodeGen.BooleanConstantsTest exposing (suite)

{-| A Bool in generated MLIR is a raw `i1` only in SSA operand context; in a heap
object, in a closure capture and at a function boundary it is boxed as
`!eco.value`, as `Compiler.Generate.MLIR.Types` describes. These tests make an
`i1` passed into an op that builds a heap object or a closure, or that crosses a
call boundary, fail a test instead of going unnoticed.

The programs are the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` describes it. Each one is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir`.

What the tests establish:

  - `suite` passes `expectBooleanConstants` to the standard suite. For each
    program it checks that every True/False `eco.constant` (integer `kind` 1
    or 0) produces one `!eco.value`, and that no operand of
    `eco.construct.*`, `eco.papCreate`, `eco.papCreateGroup`, `eco.papExtend`,
    `eco.call` or `eco.return` is defined with type `i1`.
    `TestLogic.Generate.CodeGen.BooleanConstants` gives the details. A program
    that fails to compile fails its test too.

Among what is not tested: an `i1` inside an SSA aggregate moved to the heap by
`eco.to_heap`, and programs outside the standard catalogue.

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
