module StringIndexesTest exposing (main)

-- CHECK: indexes1: [0, 8]
-- CHECK: indexes_none: []

import Html exposing (text)

main =
    let
        _ = Debug.log "indexes1" (String.indexes "he" "he says hello")
        _ = Debug.log "indexes_none" (String.indexes "xyz" "hello")
    in
    text "done"
