module FloatRoundTest exposing (main)

{-| `round` rounds a Float to the nearest Int, with halves rounded up: 2.5 gives 3 and 3.5 gives 4.

Rounding to even would give 2 for 2.5, so this is not banker's rounding. The other
cases are 2.7, 2.3 and -2.7; a negative half is not tested.

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
