module ListRepeatTest exposing (main)

-- CHECK: repeat1: [0, 0, 0]
-- CHECK: repeat_str: ["hi", "hi"]
-- CHECK: repeat_zero: []

import Html exposing (text)

main =
    let
        _ = Debug.log "repeat1" (List.repeat 3 0)
        _ = Debug.log "repeat_str" (List.repeat 2 "hi")
        _ = Debug.log "repeat_zero" (List.repeat 0 "x")
    in
    text "done"
