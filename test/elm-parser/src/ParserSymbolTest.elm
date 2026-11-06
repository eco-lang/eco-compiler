module ParserSymbolTest exposing (main)

{-| Checks that `Parser.symbol` matches one-character and two-character symbols.

`symbol "="` succeeds on `"="` and `symbol "=="` succeeds on `"=="`.
-}

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
