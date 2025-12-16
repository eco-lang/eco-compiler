module BitwiseShiftLeftTest exposing (main)

{-| Test Bitwise.shiftLeftBy.
-}

-- CHECK: shl1: 16
-- CHECK: shl2: 32
-- CHECK: shl3: 1024

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "shl1" (Bitwise.shiftLeftBy 4 1)
        _ = Debug.log "shl2" (Bitwise.shiftLeftBy 1 16)
        _ = Debug.log "shl3" (Bitwise.shiftLeftBy 10 1)
    in
    text "done"
