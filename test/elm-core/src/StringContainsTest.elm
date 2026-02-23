module StringContainsTest exposing (main)

-- CHECK: contains_yes: True
-- CHECK: contains_no: False
-- CHECK: contains_empty: True

import Html exposing (text)

main =
    let
        _ = Debug.log "contains_yes" (String.contains "ell" "Hello")
        _ = Debug.log "contains_no" (String.contains "xyz" "Hello")
        _ = Debug.log "contains_empty" (String.contains "" "Hello")
    in
    text "done"
