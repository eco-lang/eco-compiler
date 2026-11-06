module SortWithCompareEmptyListTest exposing (main)

{-| `List.sortWith compare` on a `List (List Int)` that contains `[]` twice puts the empty lists first.

`[ [ 1 ], [], [ 2 ], [] ]` sorts to `[[],[],[1],[2]]`, the same result `List.sort`
gives in `SortEmptyListInListTest`.
-}

-- CHECK: result: [[],[],[1],[2]]

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        result : List (List Int)
        result = List.sortWith compare [ [ 1 ], emptyL, [ 2 ], emptyL ]

        _ = Debug.log "result" result
    in
    text "done"
