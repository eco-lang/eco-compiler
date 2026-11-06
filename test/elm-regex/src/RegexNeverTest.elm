module RegexNeverTest exposing (main)

{-| `Regex.never` matches nothing, so `Regex.contains Regex.never` is `False` on a non-empty string.
-}

-- CHECK: never_contains: False

import Html exposing (text)
import Regex

main =
    let
        _ = Debug.log "never_contains" (Regex.contains Regex.never "anything")
    in
    text "done"
