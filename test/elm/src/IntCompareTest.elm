module IntCompareTest exposing (main)

{-| Test integer comparisons.
-}

-- CHECK: lt: True
-- CHECK: gt: True
-- CHECK: le1: True
-- CHECK: le2: True
-- CHECK: ge1: True
-- CHECK: ge2: True
-- CHECK: eq: True
-- CHECK: ne: True

import Html exposing (text)


main =
    let
        _ = Debug.log "lt" (3 < 10)
        _ = Debug.log "gt" (10 > 3)
        _ = Debug.log "le1" (3 <= 10)
        _ = Debug.log "le2" (5 <= 5)
        _ = Debug.log "ge1" (10 >= 3)
        _ = Debug.log "ge2" (5 >= 5)
        _ = Debug.log "eq" (5 == 5)
        _ = Debug.log "ne" (5 /= 3)
    in
    text "done"
