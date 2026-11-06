module NotEqualBoolIfTest exposing (main)

{-| The result of `/=` on two `Bool` literals is used as the condition of an
`if`, for all four combinations of operands; each logs `"yes"` exactly when
the operands differ.
-}

-- CHECK: ifTT: "no"
-- CHECK: ifTF: "yes"
-- CHECK: ifFT: "yes"
-- CHECK: ifFF: "no"

import Html exposing (text)


main =
    let
        _ = Debug.log "ifTT" (if True /= True then "yes" else "no")
        _ = Debug.log "ifTF" (if True /= False then "yes" else "no")
        _ = Debug.log "ifFT" (if False /= True then "yes" else "no")
        _ = Debug.log "ifFF" (if False /= False then "yes" else "no")
    in
    text "done"
