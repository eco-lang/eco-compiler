module SortByDerivedEmptyListTest exposing (main)

{-| `List.sortBy List.reverse` over a list of Lists where some are `[]`.
`List.reverse [] = []` so the key extractor produces `[]` for empty
inputs. Confirms F3 fires even when the constant is derived.
-}

-- CHECK: result: [[], [], [1, 2], [3]]

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
