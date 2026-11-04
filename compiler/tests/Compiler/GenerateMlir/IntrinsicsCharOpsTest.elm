module Compiler.GenerateMlir.IntrinsicsCharOpsTest exposing (suite)

{-| Pins that `Compiler.GenerateMlir.Intrinsics` emits the `eco.char.*` op of
each `Char` kernel when its operand is not a constant. Elsewhere in the
catalogue the `Char` conversions are constant-folded away, so these programs,
whose `Char` ops take a lambda's argument, are the ones on which
`TestLogic.Generate.CodeGen.CharTypeMappingTest` (CGEN\_015) sees an op to
check. They are also catalogue cases of `SourceIR.KernelIntrinsicCases`.

Each program is built by `makeKernelModule` and compiled with
`TestLogic.TestPipeline.runToMlir`. Each test passes when the named op is
present and every `eco.char.*` op gives the `Char` side the type `i32`
(`TestLogic.Generate.CodeGen.CharTypeMapping.expectCharTypeMappingWithOps`):

  - `List.map (\c -> Elm.Kernel.Char.toCode c) [ 'a', 'b' ]` emits
    `eco.char.toInt`;
  - `List.map (\n -> Elm.Kernel.Char.fromCode n) [ 97, 98 ]` emits
    `eco.char.fromInt`;
  - `List.map (\c -> Elm.Kernel.Utils.compare c 'm') [ 'a', 'z' ]` emits
    `eco.char.cmp_order`;
  - `List.map (\c -> Elm.Kernel.Utils.lt c 'm') [ 'a', 'z' ]` emits
    `eco.char.lt`.

Among what is not tested: the other comparisons (`le`, `gt`, `ge`, `equal`),
and `Char` ops reached through elm/core's `Char` module rather than the kernel.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.IR.Source as Src
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMappingWithOps)


{-| The four pins of the module docstring.
-}
suite : Test
suite =
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


{-| A kernel module whose `testValue` is `List.map fn items`.
-}
mapOver : Src.Expr -> List Src.Expr -> Src.Module
mapOver fn items =
    SB.makeKernelModule "testValue"
        (SB.callExpr (SB.qualVarExpr "List" "map") [ fn, SB.listExpr items ])
