module FloatNegativeZeroTest exposing (main)

{-| Test negative zero behavior.
-}

-- CHECK: eq: True
-- CHECK: div1: Infinity
-- CHECK: div2: -Infinity

import Html exposing (text)


main =
    let
        negZero = -0.0
        _ = Debug.log "eq" (negZero == 0.0)
        _ = Debug.log "div1" (1.0 / 0.0)
        _ = Debug.log "div2" (1.0 / negZero)
    in
    text "done"
