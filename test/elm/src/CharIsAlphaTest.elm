module CharIsAlphaTest exposing (main)

{-| Test Char.isAlpha.
-}

-- CHECK: alpha1: True
-- CHECK: alpha2: True
-- CHECK: alpha3: False
-- CHECK: alpha4: False

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "alpha1" (Char.isAlpha 'a')
        _ = Debug.log "alpha2" (Char.isAlpha 'Z')
        _ = Debug.log "alpha3" (Char.isAlpha '0')
        _ = Debug.log "alpha4" (Char.isAlpha ' ')
    in
    text "done"
