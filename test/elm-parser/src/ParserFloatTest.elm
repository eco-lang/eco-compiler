module ParserFloatTest exposing (main)

-- CHECK: parsed_float: Ok 3.14
-- CHECK: parsed_exp: Ok 0.015

import Html exposing (text)
import Parser


main =
    let
        _ = Debug.log "parsed_float" (Parser.run Parser.float "3.14")
        _ = Debug.log "parsed_exp" (Parser.run Parser.float "1.5e-2")
    in
    text "done"
