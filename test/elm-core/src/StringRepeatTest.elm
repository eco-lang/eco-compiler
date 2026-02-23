module StringRepeatTest exposing (main)

-- CHECK: repeat1: "abcabcabc"
-- CHECK: repeat_zero: ""

import Html exposing (text)

main =
    let
        _ = Debug.log "repeat1" (String.repeat 3 "abc")
        _ = Debug.log "repeat_zero" (String.repeat 0 "abc")
    in
    text "done"
