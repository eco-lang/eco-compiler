module BasicsClampTest exposing (main)

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
