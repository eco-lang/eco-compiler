module ParserMapTest exposing (main)

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
