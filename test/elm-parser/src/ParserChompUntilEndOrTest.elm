module ParserChompUntilEndOrTest exposing (main)

-- CHECK: chomped: Ok "abc"

import Html exposing (text)
import Parser


main =
    let
        p = Parser.getChompedString (Parser.chompUntilEndOr "}")
        result = Parser.run p "abc"
        _ = Debug.log "chomped" result
    in
    text "done"
