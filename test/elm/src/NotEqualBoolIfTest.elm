module NotEqualBoolIfTest exposing (main)

{-| `Bool /= Bool` flowing through `if … then … else …`. Exercises the
`Elm_Kernel_Utils_notEqual` symbol on a control-flow scrutinee.
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
