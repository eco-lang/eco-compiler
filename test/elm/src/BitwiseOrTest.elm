module BitwiseOrTest exposing (main)

{-| Test Bitwise.or.
-}

-- CHECK: or1: 15
-- CHECK: or2: 31
-- CHECK: or3: 15

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "or1" (Bitwise.or 15 8)
        _ = Debug.log "or2" (Bitwise.or 15 16)
        _ = Debug.log "or3" (Bitwise.or 15 15)
    in
    text "done"
