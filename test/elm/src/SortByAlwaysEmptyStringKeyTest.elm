module SortByAlwaysEmptyStringKeyTest exposing (main)

{-| `List.sortBy` with a key function that returns `""` for every element leaves the list in its original order.

`emptyKey` is a named top-level function that ignores its argument and returns
`""`. All keys are equal, and `List.sortBy` is stable,
so `[ 3, 1, 2 ]` stays `[3,1,2]`.

-}

-- CHECK: result: [3,1,2]

import Html exposing (text)


emptyKey : Int -> String
emptyKey _ =
    ""


main =
    let
        result : List Int
        result = List.sortBy emptyKey [ 3, 1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"
