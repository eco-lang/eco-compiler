module RoundToIntTest exposing (main)

{-| Test round for Float to Int conversion.
-}

-- CHECK: round1: 3
-- CHECK: round2: 2
-- CHECK: round3: -3

import Html exposing (text)


main =
    let
        _ = Debug.log "round1" (round 2.7)
        _ = Debug.log "round2" (round 2.3)
        _ = Debug.log "round3" (round -2.7)
    in
    text "done"
