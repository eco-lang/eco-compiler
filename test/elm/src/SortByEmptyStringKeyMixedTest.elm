module SortByEmptyStringKeyMixedTest exposing (main)

{-| `List.sortBy` orders by a String key that is `""` for some elements and `"x"` for others.

`keyOf` returns `""` for even numbers and `"x"` for odd ones. Since `""` sorts
before `"x"` and `List.sortBy` is stable, sorting `[ 1, 2, 3, 4 ]` gives the even
numbers first, each group in its original order: `[2,4,1,3]`.
-}

-- CHECK: result: [2,4,1,3]

import Html exposing (text)


keyOf : Int -> String
keyOf n =
    if modBy 2 n == 0 then
        ""

    else
        "x"


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 1, 2, 3, 4 ]

        _ = Debug.log "result" result
    in
    text "done"
