module BitwiseXorTest exposing (main)

{-| Test Bitwise.xor.
-}

-- CHECK: xor1: 7
-- CHECK: xor2: 31
-- CHECK: xor3: 0

import Bitwise
import Html exposing (text)


main =
    let
        _ = Debug.log "xor1" (Bitwise.xor 15 8)
        _ = Debug.log "xor2" (Bitwise.xor 15 16)
        _ = Debug.log "xor3" (Bitwise.xor 15 15)
    in
    text "done"
