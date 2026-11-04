module TestLogic.Generate.CodeGen.CharTypeMappingTest exposing (suite)

{-| Runs the check that MLIR conversions between `Char` and `Int` give the
`Char` side the type `i32`, over every program in the standard `SourceIR`
catalogue. Without it, a conversion emitted with another width for the `Char`
would go unnoticed in those programs.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` assembles.
Each program in it is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir`.

What `suite` establishes, for each program, through
`TestLogic.Generate.CodeGen.CharTypeMapping.expectCharTypeMapping`:

  - the program compiles to MLIR;
  - every `eco.char.toInt` op takes one operand defined as `i32` and gives one
    `i64` result;
  - every `eco.char.fromInt` op takes one operand defined as `i64` and gives
    one `i32` result;
  - every other `eco.char.` op (the comparisons) takes only `i32` operands.

Among what is not tested: a `Char` constant; a case on a `Char`; and the result
types of the comparisons. A program with no `eco.char.` op passes once it
compiles. Most of the catalogue's char conversions are constant-folded away;
the cases of `SourceIR.KernelIntrinsicCases` whose `Char` kernel takes a
lambda's argument keep an `eco.char.toInt`, `eco.char.fromInt`,
`eco.char.cmp_order` and `eco.char.lt` for the check to see, and the unit
test `Compiler.GenerateMlir.IntrinsicsCharOpsTest` pins that those ops are
emitted.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping)


{-| The standard catalogue of programs, each checked with
`expectCharTypeMapping`, gathered under one `describe`.
-}
suite : Test
suite =
    Test.describe "CGEN_015: Char Type Mapping"
        [ StandardTestSuites.expectSuite expectCharTypeMapping "passes char type mapping invariant"
        ]
