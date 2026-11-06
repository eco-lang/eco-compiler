module BasicsClampTest exposing (main)

{-| `clamp 5 10` returns the lower bound for 3, the value itself for 7 and the upper bound for
15, and `clamp 1.0 5.0` leaves 3.5 unchanged.
-}

-- CHECK: clamp_low: 5
-- CHECK: clamp_mid: 7
-- CHECK: clamp_high: 10
-- CHECK: clamp_float: 3.5

import Html exposing (text)

main =
    let
        _ = Debug.log "clamp_low" (clamp 5 10 3)
        _ = Debug.log "clamp_mid" (clamp 5 10 7)
        _ = Debug.log "clamp_high" (clamp 5 10 15)
        _ = Debug.log "clamp_float" (clamp 1.0 5.0 3.5)
    in
    text "done"
