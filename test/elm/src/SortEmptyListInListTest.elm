module SortEmptyListInListTest exposing (main)

{-| `List.sort` on `List (List Int)` that includes `[]` twice.
Same F3 surface as `SortEmptyStringInListTest` with the Nil-family
constant.
-}

-- CHECK: result: [[], [], [1], [2]]

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
