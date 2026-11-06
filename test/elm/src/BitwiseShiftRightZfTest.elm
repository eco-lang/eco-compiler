module BitwiseShiftRightZfTest exposing (main)

{-| `Bitwise.shiftRightZfBy` shifts a positive Int right, filling with zeros: 16 shifted by 4 is 1 and by 1 is 8.
-}

-- CHECK: shrz1: 1
-- CHECK: shrz2: 8

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "shrz1" (Bitwise.shiftRightZfBy 4 16)
        _ = Debug.log "shrz2" (Bitwise.shiftRightZfBy 1 16)
    in
    text "done"
