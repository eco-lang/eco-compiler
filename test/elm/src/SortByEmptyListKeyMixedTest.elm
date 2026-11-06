module SortByEmptyListKeyMixedTest exposing (main)

{-| `List.sortBy` with a key function that returns `[]` for some elements and a one-element list for others puts the `[]` keys first and keeps input order among equal keys.

`keyOf` returns `[]` for even numbers and `[ n ]` for odd ones. `[]` compares
less than any non-empty list, and `List.sortBy` is stable, so `[ 1, 2, 3, 4 ]`
sorts to `[2,4,1,3]`: the evens in input order, then the odds ordered by their
keys `[1]` and `[3]`.

-}

-- CHECK: result: [2,4,1,3]

import Html exposing (text)


keyOf : Int -> List Int
keyOf n =
    if modBy 2 n == 0 then
        []

    else
        [ n ]


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 1, 2, 3, 4 ]

        _ = Debug.log "result" result
    in
    text "done"
