module ParserChompWhileTest exposing (main)

-- CHECK: chomped: Ok "abc"

import Char
import Html exposing (text)
import Parser


alphaP : Parser.Parser String
alphaP =
    Parser.getChompedString (Parser.chompWhile Char.isAlpha)


main =
    let
        result = Parser.run alphaP "abc123"
        _ = Debug.log "chomped" result
    in
    text "done"
