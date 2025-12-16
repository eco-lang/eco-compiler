module IntPowTest exposing (main)

{-| Test integer exponentiation.
-}

-- CHECK: pow1: 8
-- CHECK: pow2: 1
-- CHECK: pow3: 1024
-- CHECK: pow4: -8

import Html exposing (text)


main =
    let
        _ = Debug.log "pow1" (2 ^ 3)
        _ = Debug.log "pow2" (5 ^ 0)
        _ = Debug.log "pow3" (2 ^ 10)
        _ = Debug.log "pow4" ((-2) ^ 3)
    in
    text "done"
