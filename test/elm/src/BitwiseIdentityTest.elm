module BitwiseIdentityTest exposing (main)

{-| `Bitwise.and` and `Bitwise.or` of a number with itself return the number, and `Bitwise.xor` of a number with itself returns 0.
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
