module RegexFindTest exposing (main)

{-| `Regex.find` returns one match for each non-overlapping run of the pattern.

The pattern `[0-9]+` over `"abc123def456"` finds the two digit runs, so the
list of matches has length 2. The contents of the matches are not checked.

-}

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
