module SortByTupleWithEmptyStringTest exposing (main)

{-| `List.sortBy` with a tuple key whose second component is sometimes `""` orders by the first component, then by the string.

`keyOf n` is `( modBy 2 n, suffix )`, where `suffix` is `""` when `n > 2` and
`"x"` otherwise. For `[ 4, 1, 2, 3 ]` the keys are `(0, "")`, `(1, "x")`,
`(0, "x")` and `(1, "")`. Tuples compare component by component and `""` is less
than `"x"`, so the sorted keys are `(0, "")`, `(0, "x")`, `(1, "")`, `(1, "x")`,
giving `[4,2,3,1]`.
-}

-- CHECK: result: [4,2,3,1]

import Html exposing (text)


keyOf : Int -> ( Int, String )
keyOf n =
    let
        suffix =
            if n > 2 then
                ""

            else
                "x"
    in
    ( modBy 2 n, suffix )


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 4, 1, 2, 3 ]

        _ = Debug.log "result" result
    in
    text "done"
