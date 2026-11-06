module NotEqualBoolCaseTest exposing (main)

{-| The result of `/=` on two `Bool` literals is matched by a `case` with
`True` and `False` branches, for all four combinations of operands.

`classify` returns `"yes"` for `True`, so the expected output is `"yes"`
exactly when the operands differ.
-}

-- CHECK: cTT: "no"
-- CHECK: cTF: "yes"
-- CHECK: cFT: "yes"
-- CHECK: cFF: "no"

import Html exposing (text)


classify : Bool -> String
classify b =
    case b of
        True ->
            "yes"

        False ->
            "no"


main =
    let
        _ = Debug.log "cTT" (classify (True /= True))
        _ = Debug.log "cTF" (classify (True /= False))
        _ = Debug.log "cFT" (classify (False /= True))
        _ = Debug.log "cFF" (classify (False /= False))
    in
    text "done"
