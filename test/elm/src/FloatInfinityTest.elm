module FloatInfinityTest exposing (main)

{-| Test infinity behavior.
-}

-- CHECK: isInf1: True
-- CHECK: isInf2: True
-- CHECK: isInf3: False

import Html exposing (text)


main =
    let
        posInf = 1.0 / 0.0
        negInf = -1.0 / 0.0
        _ = Debug.log "isInf1" (isInfinite posInf)
        _ = Debug.log "isInf2" (isInfinite negInf)
        _ = Debug.log "isInf3" (isInfinite 3.14)
    in
    text "done"
