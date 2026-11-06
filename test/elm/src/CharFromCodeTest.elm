module CharFromCodeTest exposing (main)

{-| `Char.fromCode` turns the code points 65, 97 and 48 into `'A'`, `'a'` and `'0'`.
-}

-- CHECK: char1: 'A'
-- CHECK: char2: 'a'
-- CHECK: char3: '0'

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "char1" (Char.fromCode 65)
        _ = Debug.log "char2" (Char.fromCode 97)
        _ = Debug.log "char3" (Char.fromCode 48)
    in
    text "done"
