module FloatSqrtTest exposing (main)

{-| `sqrt` of 4.0, 9.0 and 0.0 is 2, 3 and 0.
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
