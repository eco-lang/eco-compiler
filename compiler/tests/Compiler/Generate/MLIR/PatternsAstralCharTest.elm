module Compiler.Generate.MLIR.PatternsAstralCharTest exposing (suite)

{-| Regression test for `Compiler.Generate.MLIR.Patterns`: a Char pattern above
0xFFFF is matched against its full code point.

A Char pattern above 0xFFFF (a `\u{1F600}` escape, stored by the parser as
two `\uXXXX` escapes forming a surrogate pair) is decoded by
`decodeChrPatternCode`, which combines the pair into the code point, held by
the `i32` Char type. It used to fold every hex digit after the first `\u`
into one number (0xD83D00DE00).

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
    Test.test "astral Char pattern is its code point" <|
        \_ -> check source


source : String
source =
    """module Test exposing (..)

import Basics exposing (..)
import Char exposing (Char)

testValue : Char -> Int
testValue c =
    case c of
        '\\u{1F600}' ->
            1

        _ ->
            0
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
