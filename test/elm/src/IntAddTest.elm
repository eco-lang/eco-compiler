module IntAddTest exposing (main)

{-| Int addition gives the right sum for two positives, a positive and its negation, and two negatives.
-}

-- CHECK: add1: 13
-- CHECK: add2: 0
-- CHECK: add3: -5

import Html exposing (text)


main =
    let
        _ = Debug.log "add1" (10 + 3)
        _ = Debug.log "add2" (5 + -5)
        _ = Debug.log "add3" (-2 + -3)
    in
    text "done"
