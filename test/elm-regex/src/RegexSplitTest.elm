module RegexSplitTest exposing (main)

-- CHECK: split1: ["abc", "def", "ghi"]

import Html exposing (text)
import Regex

main =
    let
        regex = Maybe.withDefault Regex.never (Regex.fromString "[0-9]+")
        _ = Debug.log "split1" (Regex.split regex "abc123def456ghi")
    in
    text "done"
