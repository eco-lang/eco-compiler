module ParserOctalBinaryIntTest exposing (main)

-- CHECK: octal: Ok 511
-- CHECK: binary: Ok 10

import Html exposing (text)
import Parser


myNum : Parser.Parser Int
myNum =
    Parser.number
        { int = Just identity
        , hex = Nothing
        , octal = Just identity
        , binary = Just identity
        , float = Nothing
        }


main =
    let
        _ = Debug.log "octal" (Parser.run myNum "0o777")
        _ = Debug.log "binary" (Parser.run myNum "0b1010")
    in
    text "done"
