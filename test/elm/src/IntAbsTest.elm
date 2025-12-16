module IntAbsTest exposing (main)

{-| Test integer absolute value.
-}

-- CHECK: abs1: 5
-- CHECK: abs2: 5
-- CHECK: abs3: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "abs1" (abs 5)
        _ = Debug.log "abs2" (abs -5)
        _ = Debug.log "abs3" (abs 0)
    in
    text "done"
