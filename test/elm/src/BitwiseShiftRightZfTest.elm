module BitwiseShiftRightZfTest exposing (main)

{-| Test Bitwise.shiftRightZfBy (logical shift).
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
