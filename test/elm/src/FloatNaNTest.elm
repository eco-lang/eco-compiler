module FloatNaNTest exposing (main)

{-| Test NaN behavior.
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
