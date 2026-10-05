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
  - every `eco.char.toInt` op takes one operand defined as `i16` and gives one
    `i64` result;
  - every `eco.char.fromInt` op takes one operand defined as `i64` and gives
    one `i16` result;
  - every other `eco.char.` op (the comparisons) takes only `i16` operands.

Among what is not tested: a `Char` constant; a case on a `Char`; and the result
types of the comparisons. A program with no `eco.char.` op passes once it
compiles; the catalogue's char conversions are constant-folded away, so
`focusedTests` compiles four programs whose `Char` ops take a lambda's
argument and expects the ops to be present:

  - `List.map (\c -> Elm.Kernel.Char.toCode c) [ 'a', 'b' ]` must emit
    `eco.char.toInt`;
  - `List.map (\n -> Elm.Kernel.Char.fromCode n) [ 97, 98 ]` must emit
    `eco.char.fromInt`;
  - `List.map (\c -> Elm.Kernel.Utils.compare c 'm') [ 'a', 'z' ]` must emit
    `eco.char.cmp_order`;
  - `List.map (\c -> Elm.Kernel.Utils.lt c 'm') [ 'a', 'z' ]` must emit
    `eco.char.lt`.

-}

import Compiler.AST.SourceBuilder as SB
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping, expectCharTypeMappingWithOps)


{-| The standard catalogue of programs, each checked with
`expectCharTypeMapping`, gathered under one `describe`.
-}
suite : Test
suite =
    Test.describe "CGEN_015: Char Type Mapping"
        [ StandardTestSuites.expectSuite expectCharTypeMapping "passes char type mapping invariant"
        , focusedTests
        ]


{-| Programs whose `Char` ops survive to MLIR, each checked with
`expectCharTypeMappingWithOps` and the op it must emit.
-}
focusedTests : Test
focusedTests =
    let
        mapOver fn items =
            SB.makeKernelModule "testValue"
                (SB.callExpr (SB.qualVarExpr "List" "map") [ fn, SB.listExpr items ])
    in
    Test.describe "Char ops on non-constant operands"
        [ Test.test "Char.toCode in a lambda" <|
            \_ ->
                mapOver
                    (SB.lambdaExpr [ SB.pVar "c" ] (SB.callExpr (SB.qualVarExpr "Elm.Kernel.Char" "toCode") [ SB.varExpr "c" ]))
                    [ SB.chrExpr "a", SB.chrExpr "b" ]
                    |> expectCharTypeMappingWithOps [ "eco.char.toInt" ]
        , Test.test "Char.fromCode in a lambda" <|
            \_ ->
                mapOver
                    (SB.lambdaExpr [ SB.pVar "n" ] (SB.callExpr (SB.qualVarExpr "Elm.Kernel.Char" "fromCode") [ SB.varExpr "n" ]))
                    [ SB.intExpr 97, SB.intExpr 98 ]
                    |> expectCharTypeMappingWithOps [ "eco.char.fromInt" ]
        , Test.test "Utils.compare on Chars in a lambda" <|
            \_ ->
                mapOver
                    (SB.lambdaExpr [ SB.pVar "c" ] (SB.callExpr (SB.qualVarExpr "Elm.Kernel.Utils" "compare") [ SB.varExpr "c", SB.chrExpr "m" ]))
                    [ SB.chrExpr "a", SB.chrExpr "z" ]
                    |> expectCharTypeMappingWithOps [ "eco.char.cmp_order" ]
        , Test.test "Utils.lt on Chars in a lambda" <|
            \_ ->
                mapOver
                    (SB.lambdaExpr [ SB.pVar "c" ] (SB.callExpr (SB.qualVarExpr "Elm.Kernel.Utils" "lt") [ SB.varExpr "c", SB.chrExpr "m" ]))
                    [ SB.chrExpr "a", SB.chrExpr "z" ]
                    |> expectCharTypeMappingWithOps [ "eco.char.lt" ]
        ]
