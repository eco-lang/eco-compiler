module SortByEmptyStringKeyMixedTest exposing (main)

{-| `List.sortBy` whose key extractor returns `""` for some inputs and a
heap String for others. Mixed-key F3: comparator's `Allocator::resolve`
may hit the constant on either side.

Elm semantics: `"" < "x"`, so even-numbered inputs (key=`""`) precede
odd-numbered inputs (key=`"x"`).
-}

-- CHECK: result: [2, 4, 1, 3]

import Html exposing (text)


keyOf : Int -> String
keyOf n =
    if modBy 2 n == 0 then
        ""

    else
        "x"


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 1, 2, 3, 4 ]

        _ = Debug.log "result" result
    in
    text "done"
