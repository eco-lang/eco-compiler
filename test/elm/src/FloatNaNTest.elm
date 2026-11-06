module FloatNaNTest exposing (main)

{-| `isNaN` is True for `0.0 / 0.0` and False for 3.14, and adding 1.0 to NaN can be logged.

The last CHECK line matches only the `nanProp` label, so the value printed for `nan + 1.0` is not checked.

-}

-- CHECK: isNaN1: True
-- CHECK: isNaN2: False
-- CHECK: nanProp

import Html exposing (text)


main =
    let
        nan = 0.0 / 0.0
        _ = Debug.log "isNaN1" (isNaN nan)
        _ = Debug.log "isNaN2" (isNaN 3.14)
        _ = Debug.log "nanProp" (nan + 1.0)
    in
    text "done"
