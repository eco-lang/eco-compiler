module Compiler.Elm.StringTest exposing (suite)

{-| Regression test for `Compiler.Elm.String.fromChunks` on the code point
U+FFFF. EXPECTED TO FAIL until the bug is fixed.

The surrogate-pair test is `code < 0xFFFF`, so `CodePoint 0xFFFF` (from the
source escape `\u{FFFF}`) takes the surrogate branch with `code - 0x10000 = -1`
and is written as `퟿\uDFFF` instead of `￿`.

-}

import Compiler.Elm.String as ES
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler.Elm.String.fromChunks"
        [ Test.test "CodePoint 0xFFFF is one BMP escape" <|
            \_ ->
                ES.fromChunks "" [ ES.CodePoint 0xFFFF ]
                    |> Expect.equal "\\uFFFF"
        , Test.test "CodePoint 0xFFFE stays one BMP escape (control)" <|
            \_ ->
                ES.fromChunks "" [ ES.CodePoint 0xFFFE ]
                    |> Expect.equal "\\uFFFE"
        ]
