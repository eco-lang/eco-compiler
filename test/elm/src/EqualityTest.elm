module EqualityTest exposing (main)

{-| Test equality operators.
-}

-- CHECK: eq1: True
-- CHECK: eq2: False
-- CHECK: ne1: True
-- CHECK: ne2: False
-- CHECK: listEq: True

import Html exposing (text)


main =
    let
        _ = Debug.log "eq1" (5 == 5)
        _ = Debug.log "eq2" (5 == 6)
        _ = Debug.log "ne1" (5 /= 6)
        _ = Debug.log "ne2" (5 /= 5)
        _ = Debug.log "listEq" ([1, 2, 3] == [1, 2, 3])
    in
    text "done"
