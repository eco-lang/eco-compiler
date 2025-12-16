module CharToUpperTest exposing (main)

{-| Test Char.toUpper.
-}

-- CHECK: upper1: 'A'
-- CHECK: upper2: 'Z'
-- CHECK: upper3: '0'

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "upper1" (Char.toUpper 'a')
        _ = Debug.log "upper2" (Char.toUpper 'z')
        _ = Debug.log "upper3" (Char.toUpper '0')
    in
    text "done"
