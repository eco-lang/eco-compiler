module ParserHexIntTest exposing (main)

-- CHECK: hex_ff: Ok 255
-- CHECK: hex_deadbeef: Ok 3735928559

import Html exposing (text)
import Parser


hexInt : Parser.Parser Int
hexInt =
    Parser.number
        { int = Nothing
        , hex = Just identity
        , octal = Nothing
        , binary = Nothing
        , float = Nothing
        }


main =
    let
        _ = Debug.log "hex_ff" (Parser.run hexInt "0xFF")
        _ = Debug.log "hex_deadbeef" (Parser.run hexInt "0xdeadbeef")
    in
    text "done"
