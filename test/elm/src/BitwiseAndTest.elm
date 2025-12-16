module BitwiseAndTest exposing (main)

{-| Test Bitwise.and.
-}

-- CHECK: and1: 8
-- CHECK: and2: 0
-- CHECK: and3: 15

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "and1" (Bitwise.and 15 8)
        _ = Debug.log "and2" (Bitwise.and 15 16)
        _ = Debug.log "and3" (Bitwise.and 15 15)
    in
    text "done"
