module SortByTupleWithEmptyListTest exposing (main)

{-| `List.sortBy` with a tuple key whose second component is sometimes `[]` orders by the first component, then by the list.

`keyOf n` is `( modBy 2 n, suffix )`, where `suffix` is `[]` when `n > 2` and
`[ n ]` otherwise. For `[ 4, 1, 2, 3 ]` the keys are `(0, [])`, `(1, [1])`,
`(0, [2])` and `(1, [])`. Tuples compare component by component and `[]` is less
than any non-empty list, so the sorted keys are `(0, [])`, `(0, [2])`, `(1, [])`,
`(1, [1])`, giving `[4,2,3,1]`.
-}

-- CHECK: result: [4,2,3,1]

import Html exposing (text)


keyOf : Int -> ( Int, List Int )
keyOf n =
    let
        suffix =
            if n > 2 then
                []

            else
                [ n ]
    in
    ( modBy 2 n, suffix )


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 4, 1, 2, 3 ]

        _ = Debug.log "result" result
    in
    text "done"
