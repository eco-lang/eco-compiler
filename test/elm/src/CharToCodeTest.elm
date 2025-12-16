module CharToCodeTest exposing (main)

{-| Test Char.toCode.
-}

-- CHECK: code1: 65
-- CHECK: code2: 97
-- CHECK: code3: 48

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "code1" (Char.toCode 'A')
        _ = Debug.log "code2" (Char.toCode 'a')
        _ = Debug.log "code3" (Char.toCode '0')
    in
    text "done"
