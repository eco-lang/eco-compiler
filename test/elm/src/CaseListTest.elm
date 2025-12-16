module CaseListTest exposing (main)

{-| Test case expression on List.
-}

-- CHECK: case1: "empty"
-- CHECK: case2: "one"
-- CHECK: case3: "many"

import Html exposing (text)


describeList list =
    case list of
        [] -> "empty"
        [_] -> "one"
        _ -> "many"


main =
    let
        _ = Debug.log "case1" (describeList [])
        _ = Debug.log "case2" (describeList [1])
        _ = Debug.log "case3" (describeList [1, 2, 3])
    in
    text "done"
