module FloatAbsTest exposing (main)

{-| Test float absolute value.
-}

-- CHECK: abs1: 3.14
-- CHECK: abs2: 3.14
-- CHECK: abs3: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "abs1" (abs 3.14)
        _ = Debug.log "abs2" (abs -3.14)
        _ = Debug.log "abs3" (abs 0.0)
    in
    text "done"
