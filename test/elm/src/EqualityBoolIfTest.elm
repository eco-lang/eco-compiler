module EqualityBoolIfTest exposing (main)

{-| The result of `==` and `/=` on `Bool` operands drives an `if` expression
correctly.

All four `==` comparisons of `True` and `False` choose `"yes"` exactly when the
operands are equal. The two `/=` cases choose `"yes"` only for `True /= False`.

-}

-- CHECK: ifTT: "yes"
-- CHECK: ifTF: "no"
-- CHECK: ifFT: "no"
-- CHECK: ifFF: "yes"
-- CHECK: nifTT: "no"
-- CHECK: nifTF: "yes"

import Html exposing (text)


main =
    let
        _ = Debug.log "ifTT" (if True == True then "yes" else "no")
        _ = Debug.log "ifTF" (if True == False then "yes" else "no")
        _ = Debug.log "ifFT" (if False == True then "yes" else "no")
        _ = Debug.log "ifFF" (if False == False then "yes" else "no")
        _ = Debug.log "nifTT" (if True /= True then "yes" else "no")
        _ = Debug.log "nifTF" (if True /= False then "yes" else "no")
    in
    text "done"
