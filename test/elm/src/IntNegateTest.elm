module IntNegateTest exposing (main)

{-| Test integer negation.
-}

-- CHECK: neg1: -5
-- CHECK: neg2: 5
-- CHECK: neg3: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "neg1" (negate 5)
        _ = Debug.log "neg2" (negate -5)
        _ = Debug.log "neg3" (negate 0)
    in
    text "done"
