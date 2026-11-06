module BitwiseShiftLeftTest exposing (main)

{-| `Bitwise.shiftLeftBy n x` shifts the bits of `x` left by `n` places, multiplying it by 2 to the power `n`.
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
