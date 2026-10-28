module Compiler.Json.DecodeTest exposing (suite)

{-| Regression tests for the parse errors of `Compiler.Json.Decode`.

`pValue`'s `P.oneOf Start` replaces every empty failure with `Start`, and
`P.andThen` once kept `Eerr` after a consuming parser, so `ObjectColon`,
`ObjectField` and `ArrayEnd` were never produced: `{"a" 1}`, `{"a":1, x}` and
`[1, 2 x` were all reported as `Start 1 1`. Now that `andThen` promotes such a
failure to `Cerr`, each is reported at the mistake.

-}

import Compiler.Json.Decode as D
import Expect
import Test exposing (Test)


parseError : String -> Maybe D.ParseError
parseError src =
    case D.fromByteString D.int src of
        Err (D.ParseProblem _ e) ->
            Just e

        _ ->
            Nothing


suite : Test
suite =
    Test.describe "Compiler.Json.Decode parse errors"
        [ Test.test "missing colon is ObjectColon at the 1" <|
            \_ ->
                parseError "{\"a\" 1}"
                    |> Expect.equal (Just (D.ObjectColon 1 6))
        , Test.test "bad field after a comma is ObjectField" <|
            \_ ->
                parseError "{\"a\":1, x}"
                    |> Expect.equal (Just (D.ObjectField 1 9))
        , Test.test "missing ] is ArrayEnd" <|
            \_ ->
                parseError "[1, 2 x"
                    |> Expect.equal (Just (D.ArrayEnd 1 7))
        ]
