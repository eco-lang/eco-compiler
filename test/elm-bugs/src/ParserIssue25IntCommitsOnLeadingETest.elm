module ParserIssue25IntCommitsOnLeadingETest exposing (main)

{-| `Parser.int` consumes input that starts with the letter `e`, so `oneOf` cannot try the next
alternative.

<https://github.com/elm/parser/issues/25>

`oneOf [ int, letters ]` on "else" fails with ExpectingInt in Elm 0.19.1 (elm/parser 1.1.0): `int`
treats the `e` as the start of an exponent and fails after chomping. Input without a digit is not
a number, so `int` must fail without consuming and `oneOf` must use the second parser.

-}

-- CHECK: result: Ok "else"

import Html exposing (text)
import Parser


main =
    let
        intOrWord =
            Parser.oneOf
                [ Parser.map String.fromInt Parser.int
                , Parser.getChompedString (Parser.chompWhile Char.isAlpha)
                ]

        _ =
            Debug.log "result" (Parser.run intOrWord "else")
    in
    text "done"
