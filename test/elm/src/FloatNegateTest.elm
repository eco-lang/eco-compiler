module FloatNegateTest exposing (main)

{-| Test float negation.
-}

-- CHECK: neg1: -3.14
-- CHECK: neg2: 3.14
-- CHECK: neg3: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "neg1" (negate 3.14)
        _ = Debug.log "neg2" (negate -3.14)
        _ = Debug.log "neg3" (negate 0.0)
    in
    text "done"
