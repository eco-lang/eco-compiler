module ParserOctalBinaryIntTest exposing (main)

{-| Checks that `Parser.number` reads octal and binary integer literals.

`"0o777"` gives `Ok 511` and `"0b1010"` gives `Ok 10`. Hexadecimal and float
forms are disabled in the configuration and not exercised.
-}

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
