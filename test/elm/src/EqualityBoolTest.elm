module EqualityBoolTest exposing (main)

{-| `==` and `/=` on `Bool` literals give the correct answer for all four
combinations of operands.

The test logs the full truth table of `==` and of `/=` over `True` and `False`.

-}

-- CHECK: tt: True
-- CHECK: tf: False
-- CHECK: ft: False
-- CHECK: ff: True
-- CHECK: ntt: False
-- CHECK: ntf: True
-- CHECK: nft: True
-- CHECK: nff: False

import Html exposing (text)


main =
    let
        _ = Debug.log "tt" (True == True)
        _ = Debug.log "tf" (True == False)
        _ = Debug.log "ft" (False == True)
        _ = Debug.log "ff" (False == False)
        _ = Debug.log "ntt" (True /= True)
        _ = Debug.log "ntf" (True /= False)
        _ = Debug.log "nft" (False /= True)
        _ = Debug.log "nff" (False /= False)
    in
    text "done"
