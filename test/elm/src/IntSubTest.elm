module IntSubTest exposing (main)

{-| Test integer subtraction.
-}

-- CHECK: sub1: 7
-- CHECK: sub2: 10
-- CHECK: sub3: 1

import Html exposing (text)


main =
    let
        _ = Debug.log "sub1" (10 - 3)
        _ = Debug.log "sub2" (5 - -5)
        _ = Debug.log "sub3" (-2 - -3)
    in
    text "done"
