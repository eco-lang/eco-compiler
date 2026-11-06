module JsArrayInitializeRepeatTest exposing (main)

{-| `Array.initialize` and `Array.repeat` build arrays of the requested length, including length zero.

`Array.initialize 5` with `\i -> i * i` gives the squares of 0 to 4, and `Array.repeat 3 7` gives three 7s. With a length of 0, each function gives an empty array.

-}

-- CHECK: init1: [0,1,4,9,16]
-- CHECK: repeat1: [7,7,7]
-- CHECK: repeat_zero: []
-- CHECK: init_zero: []

import Array
import Html exposing (text)

main =
    let
        _ = Debug.log "init1" (Array.toList (Array.initialize 5 (\i -> i * i)))
        _ = Debug.log "repeat1" (Array.toList (Array.repeat 3 7))
        _ = Debug.log "repeat_zero" (Array.toList (Array.repeat 0 7))
        _ = Debug.log "init_zero" (Array.toList (Array.initialize 0 (\i -> i)))
    in
    text "done"
