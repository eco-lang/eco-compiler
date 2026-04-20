module ParserNumberTest exposing (main)

-- CHECK: int_value: Ok 42
-- CHECK: hex_value: Ok 255

import Html exposing (text)
import Parser


myNum : Parser.Parser Int
myNum =
    Parser.number
        { int = Just identity
        , hex = Just identity
        , octal = Just identity
        , binary = Just identity
        , float = Nothing
        }


main =
    let
        _ = Debug.log "int_value" (Parser.run myNum "42")
        _ = Debug.log "hex_value" (Parser.run myNum "0xff")
    in
    text "done"
