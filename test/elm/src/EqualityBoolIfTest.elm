module EqualityBoolIfTest exposing (main)

{-| `Bool == Bool` flowing through `if … then … else …`. The result of
the broken kernel call is re-boxed and then unboxed by the `if` to drive
control flow, so this is the form the user originally hit.
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
