module SortByEmptyListKeyMixedTest exposing (main)

{-| `List.sortBy` whose key extractor returns `[]` for some inputs and
a heap List for others. Mixed-key F3.

Elm semantics: `[] < [_]`, so even-numbered inputs (key=`[]`) precede
odd-numbered inputs (key=`[n]`). Within each group, stable sort
preserves input order.
-}

-- CHECK: result: [2, 4, 1, 3]

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
