module StringEscapeSingleQuoteTest exposing (main)

{-| Test that strings containing single quotes (apostrophes) compile correctly.
The MLIR string literal emitter must not produce \' escapes, since MLIR
only recognizes \\, \", \n, \t, and hex escapes inside double-quoted strings.
-}

-- CHECK: q1: "it's working"
-- CHECK: q2: "don't panic"
-- CHECK: q3: "quotes: ' and '"

import Html exposing (text)


main =
    let
        _ = Debug.log "q1" "it's working"
        _ = Debug.log "q2" "don't panic"
        _ = Debug.log "q3" ("quotes: ' and '")
    in
    text "done"
