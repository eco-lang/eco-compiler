module RegexFindTest exposing (main)

-- CHECK: find_count: 2

import Html exposing (text)
import Regex

main =
    let
        regex = Maybe.withDefault Regex.never (Regex.fromString "[0-9]+")
        matches = Regex.find regex "abc123def456"
        _ = Debug.log "find_count" (List.length matches)
    in
    text "done"
