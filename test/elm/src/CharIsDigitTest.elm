module CharIsDigitTest exposing (main)

{-| Test Char.isDigit.
-}

-- CHECK: digit1: True
-- CHECK: digit2: True
-- CHECK: digit3: False
-- CHECK: digit4: False

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "digit1" (Char.isDigit '0')
        _ = Debug.log "digit2" (Char.isDigit '9')
        _ = Debug.log "digit3" (Char.isDigit 'a')
        _ = Debug.log "digit4" (Char.isDigit 'A')
    in
    text "done"
