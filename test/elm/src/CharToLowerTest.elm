module CharToLowerTest exposing (main)

{-| `Char.toLower` maps `'A'` to `'a'` and `'Z'` to `'z'`, and leaves `'0'` unchanged.
-}

-- CHECK: lower1: 'a'
-- CHECK: lower2: 'z'
-- CHECK: lower3: '0'

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "lower1" (Char.toLower 'A')
        _ = Debug.log "lower2" (Char.toLower 'Z')
        _ = Debug.log "lower3" (Char.toLower '0')
    in
    text "done"
