module RegexContainsTest exposing (main)

-- CHECK: contains_yes: True
-- CHECK: contains_no: False

import Html exposing (text)
import Regex

main =
    let
        regex = Maybe.withDefault Regex.never (Regex.fromString "[0-9]+")
        _ = Debug.log "contains_yes" (Regex.contains regex "abc123")
        _ = Debug.log "contains_no" (Regex.contains regex "abcdef")
    in
    text "done"
