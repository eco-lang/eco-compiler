module StringEscapesTest exposing (main)

{-| Test string escape sequences.
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
