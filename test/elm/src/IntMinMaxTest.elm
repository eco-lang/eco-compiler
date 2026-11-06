module IntMinMaxTest exposing (main)

{-| Checks `min` and `max` on Int arguments, including a negative one.
-}

-- CHECK: min1: 3
-- CHECK: min2: -5
-- CHECK: max1: 10
-- CHECK: max2: 5

import Html exposing (text)


main =
    let
        _ = Debug.log "min1" (min 10 3)
        _ = Debug.log "min2" (min -5 5)
        _ = Debug.log "max1" (max 10 3)
        _ = Debug.log "max2" (max -5 5)
    in
    text "done"
