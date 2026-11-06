module ParserMapTest exposing (main)

{-| Checks that `Parser.map` transforms a parser's result: `map negate int` on `"42"` gives `Ok -42`.
-}

-- CHECK: neg: Ok -42

import Html exposing (text)
import Parser


main =
    let
        negInt = Parser.map negate Parser.int
        result = Parser.run negInt "42"
        _ = Debug.log "neg" result
    in
    text "done"
