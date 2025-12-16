module FloatCompareTest exposing (main)

{-| Test float comparisons.
-}

-- CHECK: lt: True
-- CHECK: gt: True
-- CHECK: le: True
-- CHECK: ge: True
-- CHECK: eq: True
-- CHECK: ne: True

import Html exposing (text)


main =
    let
        _ = Debug.log "lt" (3.14 < 10.0)
        _ = Debug.log "gt" (10.0 > 3.14)
        _ = Debug.log "le" (3.14 <= 3.14)
        _ = Debug.log "ge" (3.14 >= 3.14)
        _ = Debug.log "eq" (3.14 == 3.14)
        _ = Debug.log "ne" (3.14 /= 2.71)
    in
    text "done"
