module StringContainsTest exposing (main)

{-| `String.contains` finds a substring that is present, rejects one that is
not, and reports that the empty string is contained in any string.

The haystack is `"Hello"`; the needles are `"ell"`, `"xyz"` and `""`.

-}

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
