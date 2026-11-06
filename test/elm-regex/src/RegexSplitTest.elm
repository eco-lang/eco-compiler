module RegexSplitTest exposing (main)

{-| `Regex.split` cuts a string at every match and drops the matched text.

Splitting `"abc123def456ghi"` on `[0-9]+` gives the three letter runs between
the digit runs.

-}

-- CHECK: split1: ["abc","def","ghi"]

import Html exposing (text)
import Regex

main =
    let
        regex = Maybe.withDefault Regex.never (Regex.fromString "[0-9]+")
        _ = Debug.log "split1" (Regex.split regex "abc123def456ghi")
    in
    text "done"
