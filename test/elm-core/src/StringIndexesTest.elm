module StringIndexesTest exposing (main)

{-| Checks that `String.indexes` returns every position where a substring occurs, and an empty list when it never does.

`"he"` occurs in `"he says hello"` at positions 0 and 8; `"xyz"` does not occur
in `"hello"`.

-}

-- CHECK: indexes1: [0,8]
-- CHECK: indexes_none: []

import Html exposing (text)

main =
    let
        _ = Debug.log "indexes1" (String.indexes "he" "he says hello")
        _ = Debug.log "indexes_none" (String.indexes "xyz" "hello")
    in
    text "done"
