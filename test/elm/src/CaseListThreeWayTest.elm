module CaseListThreeWayTest exposing (main)

{-| Test case expression on List with [], [x], and x::xs patterns.
-}

-- CHECK: desc1: "empty"
-- CHECK: desc2: "single: 42"
-- CHECK: desc3: "multiple: 1"

import Html exposing (text)


describeList list =
    case list of
        [] -> "empty"
        [x] -> "single: " ++ String.fromInt x
        x :: xs -> "multiple: " ++ String.fromInt x


main =
    let
        _ = Debug.log "desc1" (describeList [])
        _ = Debug.log "desc2" (describeList [42])
        _ = Debug.log "desc3" (describeList [1, 2, 3])
    in
    text "done"
