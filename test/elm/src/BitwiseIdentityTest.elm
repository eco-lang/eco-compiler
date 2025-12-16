module BitwiseIdentityTest exposing (main)

{-| Test bitwise identity properties.
-}

-- CHECK: identity1: 42
-- CHECK: identity2: 42
-- CHECK: identity3: 0

import Bitwise
import Html exposing (text)


main =
    let
        x = 42
        _ = Debug.log "identity1" (Bitwise.and x x)
        _ = Debug.log "identity2" (Bitwise.or x x)
        _ = Debug.log "identity3" (Bitwise.xor x x)
    in
    text "done"
