module SortByIdentityEmptyListTest exposing (main)

{-| `List.sortBy identity` on a list of `List Int` values, two of which are `[]`, puts the empty lists first.

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
        result = List.sortBy identity [ [ 1 ], emptyL, [ 2 ], emptyL ]

        _ = Debug.log "result" result
    in
    text "done"
