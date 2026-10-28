module Compiler.Elm.StringTest exposing (suite)

{-| Regression tests for `Compiler.Elm.String`.

`fromChunks` on the code point U+FFFF: the surrogate-pair test used to be
`code < 0xFFFF`, so `CodePoint 0xFFFF` (from the source escape `\u{FFFF}`)
took the surrogate branch with `code - 0x10000 = -1` and was written as
`\uD7FF\uDFFF` instead of `\uFFFF`.

`valueKey`, the key decision trees compare `Char` and `String` patterns by: two
spellings of one value share a key (`a` and `\u0061`, a raw astral character
and its surrogate-pair escapes), escapes decode to their code points, and the
key of `ab` differs from that of `a,b`.

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
        , Test.describe "valueKey"
            [ Test.test "a and \\u0061 share a key" <|
                \_ -> ES.valueKey "\\u0061" |> Expect.equal (ES.valueKey "a")
            , Test.test "a raw astral character and its surrogate pair share a key" <|
                \_ -> ES.valueKey "\\uD83D\\uDE00" |> Expect.equal (ES.valueKey "😀")
            , Test.test "a surrogate pair is one code point" <|
                \_ -> ES.valueKey "\\uD83D\\uDE00" |> Expect.equal "128512"
            , Test.test "escapes decode to code points" <|
                \_ -> ES.valueKey "\\n\\'\\\"\\\\x" |> Expect.equal "10,39,34,92,120"
            , Test.test "ab and a,b differ" <|
                \_ -> (ES.valueKey "ab" == ES.valueKey "a,b") |> Expect.equal False
            ]
        ]
