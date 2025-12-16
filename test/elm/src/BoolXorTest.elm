module BoolXorTest exposing (main)

{-| Test xor function.
-}

-- CHECK: xor1: False
-- CHECK: xor2: True
-- CHECK: xor3: True
-- CHECK: xor4: False

import Html exposing (text)


main =
    let
        _ = Debug.log "xor1" (xor True True)
        _ = Debug.log "xor2" (xor True False)
        _ = Debug.log "xor3" (xor False True)
        _ = Debug.log "xor4" (xor False False)
    in
    text "done"
