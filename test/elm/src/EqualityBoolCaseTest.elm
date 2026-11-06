module EqualityBoolCaseTest exposing (main)

{-| The result of `==` on `Bool` operands drives a `case` on `True` and `False`
correctly.

`classify` returns `"yes"` for `True` and `"no"` for `False`. It is applied to
all four comparisons of `True` and `False`, so equal operands log `"yes"` and
unequal ones log `"no"`.

-}

-- CHECK: cTT: "yes"
-- CHECK: cTF: "no"
-- CHECK: cFT: "no"
-- CHECK: cFF: "yes"

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
        _ = Debug.log "cTT" (classify (True == True))
        _ = Debug.log "cTF" (classify (True == False))
        _ = Debug.log "cFT" (classify (False == True))
        _ = Debug.log "cFF" (classify (False == False))
    in
    text "done"
