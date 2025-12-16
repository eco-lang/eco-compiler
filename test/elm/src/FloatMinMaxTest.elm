module FloatMinMaxTest exposing (main)

{-| Test min and max on floats.
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
