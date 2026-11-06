module StringEscapeSingleQuoteTest exposing (main)

{-| String literals containing single quotes (apostrophes) keep them unchanged.

An apostrophe needs no escape inside a double-quoted Elm string. Three literals
containing one or two apostrophes are logged and must print as written.

## eco

Exercises the MLIR string literal emitter: it must not write a backslash
escape before an apostrophe, since MLIR only accepts backslash, double quote,
n, t and hex escapes inside double-quoted strings. The TEXT-MLIR directive
routes the program through the MLIR text printer (compiler/src/Mlir/Pretty.elm),
where such an escape would make the output unparseable.

-}

-- TEXT-MLIR: also keeps the MLIR text printer (Mlir.Pretty) covered and checked end to end
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
