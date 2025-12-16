module BitwiseLargeShiftTest exposing (main)

{-| Test large shift amounts.
-}

-- CHECK: shift32: 0
-- CHECK: shift63

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "shift32" (Bitwise.shiftLeftBy 32 1)
        _ = Debug.log "shift63" (Bitwise.shiftLeftBy 63 1)
    in
    text "done"
