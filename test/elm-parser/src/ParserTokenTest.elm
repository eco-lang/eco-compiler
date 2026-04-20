module ParserTokenTest exposing (main)

-- CHECK: letter: True

import Html exposing (text)
import Parser


main =
    let
        result = Parser.run (Parser.token "let") "letter"
        _ = Debug.log "letter"
            (case result of
                Ok _ -> True
                Err _ -> False
            )
    in
    text "done"
