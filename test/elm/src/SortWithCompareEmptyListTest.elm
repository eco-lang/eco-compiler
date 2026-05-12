module SortWithCompareEmptyListTest exposing (main)

{-| `List.sortWith compare` on Lists including `[]`. Regression guard
for the sortWith path. Values pass to the comparator via encoded
HPointer; the comparator calls top-level `compare` on Lists, which
takes the early-return path in `cmp` for nullptr-resolved constants.
-}

-- CHECK: result: [[], [], [1], [2]]

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
