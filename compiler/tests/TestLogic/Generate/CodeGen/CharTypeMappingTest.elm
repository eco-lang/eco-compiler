module TestLogic.Generate.CodeGen.CharTypeMappingTest exposing (suite)

{-| Runs the check that MLIR conversions between `Char` and `Int` give the
`Char` side the type `i16`, over every program in the standard `SourceIR`
catalogue. Without it, a conversion emitted with another width for the `Char`
would go unnoticed in those programs.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` assembles.
Each program in it is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir`.

What `suite` establishes, for each program, through
`TestLogic.Generate.CodeGen.CharTypeMapping.expectCharTypeMapping`:

  - the program compiles to MLIR;
  - every `eco.char.toInt` op whose `_operand_types` attribute records at
    least one type has `i16` as the first type recorded there;
  - every `eco.char.fromInt` op that has a result has `i16` as its first result
    type.

Among what is not tested: the other `eco.char.` ops, including the
comparisons; a `Char` constant; a case on a `Char`; and the `Int` side of either
conversion. A program with no char conversion passes once it compiles.

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
