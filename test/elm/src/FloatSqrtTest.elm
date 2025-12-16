module FloatSqrtTest exposing (main)

{-| Test square root.
-}

-- CHECK: sqrt1: 2
-- CHECK: sqrt2: 3
-- CHECK: sqrt3: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "sqrt1" (sqrt 4.0)
        _ = Debug.log "sqrt2" (sqrt 9.0)
        _ = Debug.log "sqrt3" (sqrt 0.0)
    in
    text "done"
