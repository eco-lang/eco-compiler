module CharUnicodeTest exposing (main)

{-| Test Unicode characters.
-}

-- CHECK: code1: 955
-- CHECK: code2: 8364

import Char
import Html exposing (text)


main =
    let
        -- Greek lambda
        _ = Debug.log "code1" (Char.toCode '\u{03BB}')
        -- Euro sign
        _ = Debug.log "code2" (Char.toCode '\u{20AC}')
    in
    text "done"
