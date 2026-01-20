module CaseResultTest exposing (main)

{-| Test case expression on Result type.
-}

-- CHECK: res1: 42
-- CHECK: res2: -1
-- CHECK: res3: 100

import Html exposing (text)


resultToInt result =
    case result of
        Ok value -> value
        Err _ -> -1


main =
    let
        _ = Debug.log "res1" (resultToInt (Ok 42))
        _ = Debug.log "res2" (resultToInt (Err "error"))
        _ = Debug.log "res3" (resultToInt (Ok 100))
    in
    text "done"
