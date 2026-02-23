module RegexNeverTest exposing (main)

-- CHECK: never_contains: False

import Html exposing (text)
import Regex

main =
    let
        _ = Debug.log "never_contains" (Regex.contains Regex.never "anything")
    in
    text "done"
