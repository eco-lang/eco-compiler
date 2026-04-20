module ParserHexIntTest exposing (main)

-- CHECK: hex_ff: Ok 255
-- CHECK: hex_deadbeef: Ok 3735928559

import Html exposing (text)
import Parser


main =
    let
        _ = Debug.log "hex_ff" (Parser.run Parser.int "0xFF")
        _ = Debug.log "hex_deadbeef" (Parser.run Parser.int "0xdeadbeef")
    in
    text "done"
