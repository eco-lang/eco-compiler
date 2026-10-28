module Compiler.Generate.MLIR.ExprAstralCharTest exposing (suite)

{-| Regression test for `Compiler.Generate.MLIR.Expr`: a Char literal above
0xFFFF is emitted as its full code point.

A Char literal above 0xFFFF (a `\u{1F600}` escape, stored by the parser as a
surrogate pair and combined by `decodeSurrogatePair`) is emitted by
`generateLiteral` through `Ops.arithConstantChar` as a constant of the Char
type, `i32` (`Types.ecoChar`), which holds any code point.

The fixture is compiled with `TestPipeline.runToMlir`; the test requires that
the MLIR holds the constant `value = 128512 : i32` (U+1F600) and that every
`i32` constant is in 0..0x10FFFF.

-}

import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.test "astral Char literal is its code point" <|
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
                    Expect.all
                        [ \out -> Expect.equal [] (outOfRangeCharConstants out)
                        , \out ->
                            if String.contains "value = 128512 : i32" out then
                                Expect.pass

                            else
                                Expect.fail ("no i32 code point constant 128512 (U+1F600) in:\n" ++ out)
                        ]
                        mlirOutput


{-| Returns every `value = N : i32` in `text` whose N is not a Unicode code
point, outside 0..0x10FFFF.
-}
outOfRangeCharConstants : String -> List String
outOfRangeCharConstants text =
    String.split "value = " text
        |> List.drop 1
        |> List.filterMap
            (\chunk ->
                case String.split " : i32" chunk of
                    numText :: _ :: _ ->
                        case String.toInt numText of
                            Just n ->
                                if n < 0 || n > 0x0010FFFF then
                                    Just ("value = " ++ numText ++ " : i32")

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                    _ ->
                        Nothing
            )
