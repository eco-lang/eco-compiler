module StringEscapesTest exposing (main)

{-| String literals containing the escape sequences `\n`, `\t` and `\"` compile, and
`Debug.log` prints the string containing an escaped double quote as `"\""`.

The newline and tab strings are logged too, but only their labels are checked.
-}

-- CHECK: newline
-- CHECK: tab
-- CHECK: quote: "\""

import Html exposing (text)


main =
    let
        _ = Debug.log "newline" "line1\nline2"
        _ = Debug.log "tab" "col1\tcol2"
        _ = Debug.log "quote" "\""
    in
    text "done"
