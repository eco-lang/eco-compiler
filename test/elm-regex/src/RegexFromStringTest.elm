module RegexFromStringTest exposing (main)

-- CHECK: from_string: True
-- CHECK: invalid: False

import Html exposing (text)
import Regex

main =
    let
        maybeRegex = Regex.fromString "[0-9]+"
        _ = Debug.log "from_string" (maybeRegex /= Nothing)
        invalid = Regex.fromString "[invalid"
        _ = Debug.log "invalid" (invalid /= Nothing)
    in
    text "done"
