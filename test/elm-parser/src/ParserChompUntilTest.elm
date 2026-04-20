module ParserChompUntilTest exposing (main)

-- CHECK: until: Ok "abc "

import Html exposing (text)
import Parser


main =
    let
        p = Parser.getChompedString (Parser.chompUntil "end")
        result = Parser.run p "abc end xyz"
        _ = Debug.log "until" result
    in
    text "done"
