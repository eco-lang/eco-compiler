module EqualityBoolCaseTest exposing (main)

{-| `case (a == b) of True -> … ; False -> …`.

The decision tree's `IsBool` test lowers to an i1 xor (Patterns.elm), so
the *case* itself is correct. The bug enters via the kernel call that
produces the scrutinee.
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
