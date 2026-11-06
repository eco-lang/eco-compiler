module ParserIssue18IntLeadingZeroTest exposing (main)

{-| `Parser.int` succeeds on inputs its documentation says it rejects.

<https://github.com/elm/parser/issues/18>

The documentation of `int` says `run int "0123" == Err ...` and `run int "123a" == Err ...` (number
parsers "peek ahead, making sure they are not followed by anything unexpected"). Elm 0.19.1
(elm/parser 1.1.0) gives `Ok 0` and `Ok 123`; `Ok 0` for "0123" silently drops the digits.

-}

-- CHECK: {{(^|\n)0123: Err}}
-- CHECK: {{(^|\n)123a: Err}}

import Html exposing (text)
import Parser


main =
    let
        _ =
            Debug.log "0123" (Parser.run Parser.int "0123")

        _ =
            Debug.log "123a" (Parser.run Parser.int "123a")
    in
    text "done"
