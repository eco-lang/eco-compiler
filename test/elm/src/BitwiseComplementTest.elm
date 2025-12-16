module BitwiseComplementTest exposing (main)

{-| Test Bitwise.complement.
-}

-- CHECK: comp1: -1
-- CHECK: comp2: -16

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "comp1" (Bitwise.complement 0)
        _ = Debug.log "comp2" (Bitwise.complement 15)
    in
    text "done"
