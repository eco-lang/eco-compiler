module StringRepeatTest exposing (main)

{-| Checks that `String.repeat` concatenates `n` copies of a string, giving the empty string when `n` is 0.
-}

-- CHECK: repeat1: "abcabcabc"
-- CHECK: repeat_zero: ""

import Html exposing (text)

main =
    let
        _ = Debug.log "repeat1" (String.repeat 3 "abc")
        _ = Debug.log "repeat_zero" (String.repeat 0 "abc")
    in
    text "done"
