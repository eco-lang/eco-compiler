module ToFloatTest exposing (main)

{-| Test toFloat conversion.
-}

-- CHECK: toFloat1: 42
-- CHECK: toFloat2: -10
-- CHECK: toFloat3: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "toFloat1" (toFloat 42)
        _ = Debug.log "toFloat2" (toFloat -10)
        _ = Debug.log "toFloat3" (toFloat 0)
    in
    text "done"
