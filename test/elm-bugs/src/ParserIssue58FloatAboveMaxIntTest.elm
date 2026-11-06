module ParserIssue58FloatAboveMaxIntTest exposing (main)

{-| `Parser.float` loses precision on integral literals above 2^53.

<https://github.com/elm/parser/issues/58>

18014398509610716 is exactly representable as a Float, and `String.toFloat` reads it exactly.
Elm 0.19.1 (elm/parser 1.1.0) accumulates the digits as an Int and returns 18014398509610720.

-}

-- CHECK: toFloat: Just 18014398509610716
-- CHECK: parser: Ok 18014398509610716

import Html exposing (text)
import Parser


main =
    let
        _ =
            Debug.log "toFloat" (String.toFloat "18014398509610716")

        _ =
            Debug.log "parser" (Parser.run Parser.float "18014398509610716")
    in
    text "done"
