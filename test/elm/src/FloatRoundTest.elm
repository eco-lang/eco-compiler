module FloatRoundTest exposing (main)

{-| Test round function (banker's rounding - ties to even).
-}

-- CHECK: round1: 3
-- CHECK: round2: 2
-- CHECK: round3: -3
-- CHECK: round4: 3
-- CHECK: round5: 4

import Html exposing (text)


main =
    let
        _ = Debug.log "round1" (round 2.7)
        _ = Debug.log "round2" (round 2.3)
        _ = Debug.log "round3" (round -2.7)
        _ = Debug.log "round4" (round 2.5)
        _ = Debug.log "round5" (round 3.5)
    in
    text "done"
