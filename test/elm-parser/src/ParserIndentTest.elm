module ParserIndentTest exposing (main)

-- CHECK: indent: Ok 4

import Html exposing (text)
import Parser


p : Parser.Parser Int
p =
    Parser.withIndent 4 Parser.getIndent


main =
    let
        result = Parser.run p ""
        _ = Debug.log "indent" result
    in
    text "done"
