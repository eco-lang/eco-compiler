module BitwiseLargeShiftTest exposing (main)

{-| Test large shift amounts.
-}

-- DIVERGENCE: Int is 64-bit in eco; Elm on JavaScript shifts in 32 bits (shiftLeftBy 32 1 is 1 in Elm)
-- CHECK: shift32: 4294967296
-- CHECK: shift63: -9223372036854775808

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "shift32" (Bitwise.shiftLeftBy 32 1)
        _ = Debug.log "shift63" (Bitwise.shiftLeftBy 63 1)
    in
    text "done"
