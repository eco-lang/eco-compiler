module CaseListTest exposing (main)

{-| Checks that a `case` on a `List` distinguishes the empty list, a list of
exactly one element (`[_]`) and any longer list (`_`).
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
