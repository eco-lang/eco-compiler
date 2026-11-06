module CaseIntTest exposing (main)

{-| Checks that a `case` on an `Int` matches integer literal patterns and falls
through to the wildcard for any other value.

`describeNum` matches 1 and 2; the third call passes 99, which only the `_`
branch matches.

-}

-- CHECK: case1: "one"
-- CHECK: case2: "two"
-- CHECK: case3: "other"

import Html exposing (text)


describeNum n =
    case n of
        1 -> "one"
        2 -> "two"
        _ -> "other"


main =
    let
        _ = Debug.log "case1" (describeNum 1)
        _ = Debug.log "case2" (describeNum 2)
        _ = Debug.log "case3" (describeNum 99)
    in
    text "done"
