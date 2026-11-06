module SortEmptyListInListTest exposing (main)

{-| `List.sort` on a `List (List Int)` that contains `[]` twice puts the empty lists first.

Lists compare element by element, and `[]` is less than any non-empty list, so
`[ [ 1 ], [], [ 2 ], [] ]` sorts to `[[],[],[1],[2]]`.
-}

-- CHECK: result: [[],[],[1],[2]]

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        result : List (List Int)
        result = List.sort [ [ 1 ], emptyL, [ 2 ], emptyL ]

        _ = Debug.log "result" result
    in
    text "done"
