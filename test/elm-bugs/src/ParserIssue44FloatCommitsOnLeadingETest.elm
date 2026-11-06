module ParserIssue44FloatCommitsOnLeadingETest exposing (main)

{-| `Parser.float` commits on input that starts with `e`, so `oneOf` cannot fall back.

<https://github.com/elm/parser/issues/44>

`oneOf [ float |> map ..., chompUntilEndOr "\n" |> getChompedString ]` on "e should be text" fails
with ExpectingFloat in Elm 0.19.1 (elm/parser 1.1.0), while "not starting with e" works. Text
without a digit is not a float: `float` must fail without consuming.

-}

-- CHECK: e: Ok "e should be text"
-- CHECK: n: Ok "not starting with e"

import Html exposing (text)
import Parser


floatOrText : Parser.Parser String
floatOrText =
    Parser.oneOf
        [ Parser.float |> Parser.map (\n -> "Number: " ++ String.fromFloat n)
        , Parser.chompUntilEndOr "\n" |> Parser.getChompedString
        ]


main =
    let
        _ =
            Debug.log "e" (Parser.run floatOrText "e should be text")

        _ =
            Debug.log "n" (Parser.run floatOrText "not starting with e")
    in
    text "done"
