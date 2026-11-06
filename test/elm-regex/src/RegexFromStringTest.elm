module RegexFromStringTest exposing (main)

{-| `Regex.fromString` returns `Just` for a valid pattern and `Nothing` for an invalid one.

`[0-9]+` compiles. `[invalid` has an unclosed character class and is rejected.

-}

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
