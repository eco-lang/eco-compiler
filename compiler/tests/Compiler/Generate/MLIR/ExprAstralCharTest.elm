module Compiler.Generate.MLIR.ExprAstralCharTest exposing (suite)

{-| Regression test for a suspected bug in `Compiler.Generate.MLIR.Expr`.

EXPECTED TO FAIL until the bug is fixed.

A Char literal above 0xFFFF (a `\u{1F600}` escape, stored by the parser as a
surrogate pair and combined by `decodeSurrogatePair`, Expr.elm ~8155) is
emitted by `generateLiteral` (Expr.elm ~705) through `Ops.arithConstantChar`
as an `i16` constant (`Types.ecoChar` = I16), which cannot hold it.

The fixture is compiled with `TestPipeline.runToMlir`; the test requires that
every `arith.constant` typed `i16` (the Char type) holds a value in 0..0xFFFF.

-}

import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.test "astral Char literal fits its i16 constant" <|
        \_ -> check source


source : String
source =
    """module Test exposing (..)

import Basics exposing (..)
import Char exposing (Char)

testValue : Char
testValue =
    '\\u{1F600}'
"""


check : String -> Expectation
check src =
    case Parse.fromByteString (Parse.Package Pkg.core) src of
        Err _ ->
            Expect.fail "fixture does not parse"

        Ok srcModule ->
            case Pipeline.runToMlir srcModule of
                Err e ->
                    Expect.fail ("fixture does not compile: " ++ e)

                Ok { mlirOutput } ->
                    Expect.equal [] (outOfRangeI16Constants mlirOutput)


{-| Returns every `value = N : i16` in `text` whose N is outside 0..0xFFFF.
-}
outOfRangeI16Constants : String -> List String
outOfRangeI16Constants text =
    String.split "value = " text
        |> List.drop 1
        |> List.filterMap
            (\chunk ->
                case String.split " : i16" chunk of
                    numText :: _ :: _ ->
                        case String.toInt numText of
                            Just n ->
                                if n < 0 || n > 0xFFFF then
                                    Just ("value = " ++ numText ++ " : i16")

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                    _ ->
                        Nothing
            )

