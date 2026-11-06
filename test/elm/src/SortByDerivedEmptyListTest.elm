module SortByDerivedEmptyListTest exposing (main)

{-| `List.sortBy List.reverse` sorts a list of lists, two of them empty, by their reversed contents.

The keys are `[2,1]`, `[]`, `[3]` and `[]`. Lists compare element by element and
`[]` sorts first, so the result is the two empty lists in input order, then
`[1,2]` (key `[2,1]`), then `[3]`.

-}

-- CHECK: result: [[],[],[1,2],[3]]

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        result : List (List Int)
        result = List.sortBy List.reverse [ [ 1, 2 ], emptyL, [ 3 ], emptyL ]

        _ = Debug.log "result" result
    in
    text "done"
