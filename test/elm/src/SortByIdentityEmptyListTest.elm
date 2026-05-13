module SortByIdentityEmptyListTest exposing (main)

{-| `List.sortBy identity` on a list of Lists where some are `[]`.
Same F3 surface — `[]` values appear as embedded constants when the
comparator dereferences them.
-}

-- CHECK: result: [[], [], [1], [2]]

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
