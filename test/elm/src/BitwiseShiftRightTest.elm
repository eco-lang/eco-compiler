module BitwiseShiftRightTest exposing (main)

{-| Test Bitwise.shiftRightBy (arithmetic shift).
-}

-- CHECK: shr1: 1
-- CHECK: shr2: 8
-- CHECK: shr3: -1

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "shr1" (Bitwise.shiftRightBy 4 16)
        _ = Debug.log "shr2" (Bitwise.shiftRightBy 1 16)
        _ = Debug.log "shr3" (Bitwise.shiftRightBy 4 -1)
    in
    text "done"
