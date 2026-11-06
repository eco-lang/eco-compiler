module FloatMinMaxTest exposing (main)

{-| `min` and `max` on Floats pick the smaller and larger argument, including with a negative argument.

The pairs are 10.0 and 3.14, and -5.0 and 5.0. Whole-number results print without a decimal point.

-}

-- CHECK: min1: 3.14
-- CHECK: min2: -5
-- CHECK: max1: 10
-- CHECK: max2: 5

import Html exposing (text)


main =
    let
        _ = Debug.log "min1" (min 10.0 3.14)
        _ = Debug.log "min2" (min -5.0 5.0)
        _ = Debug.log "max1" (max 10.0 3.14)
        _ = Debug.log "max2" (max -5.0 5.0)
    in
    text "done"
