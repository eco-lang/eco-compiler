module BitwiseShiftRightTest exposing (main)

{-| `Bitwise.shiftRightBy` is an arithmetic shift: it divides a positive number by a power of two, and keeps the sign of a negative one, so `-1` shifted right stays `-1`.
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
