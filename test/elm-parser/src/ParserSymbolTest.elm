module ParserSymbolTest exposing (main)

-- CHECK: single: True
-- CHECK: double: True

import Html exposing (text)
import Parser


main =
    let
        single = Parser.run (Parser.symbol "=") "="
        _ = Debug.log "single"
            (case single of
                Ok _ -> True
                Err _ -> False
            )
        double = Parser.run (Parser.symbol "==") "=="
        _ = Debug.log "double"
            (case double of
                Ok _ -> True
                Err _ -> False
            )
    in
    text "done"
