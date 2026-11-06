module CaseStringTest exposing (main)

{-| A case expression on a `String` with two literal patterns and a wildcard
returns the `Int` of the matching branch.
-}

-- CHECK: case1: 1
-- CHECK: case2: 2
-- CHECK: case3: 0

import Html exposing (text)


strToNum s =
    case s of
        "one" -> 1
        "two" -> 2
        _ -> 0


main =
    let
        _ = Debug.log "case1" (strToNum "one")
        _ = Debug.log "case2" (strToNum "two")
        _ = Debug.log "case3" (strToNum "other")
    in
    text "done"
