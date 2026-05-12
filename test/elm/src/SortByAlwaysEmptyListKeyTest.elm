module SortByAlwaysEmptyListKeyTest exposing (main)

{-| `List.sortBy` whose key extractor returns the embedded constant `[]`
for every input. F3 with the Nil-family constant — same assert in
`Allocator::resolve`.
-}

-- CHECK: result: [3, 1, 2]

import Html exposing (text)


emptyKey : Int -> List Int
emptyKey _ =
    []


main =
    let
        result : List Int
        result = List.sortBy emptyKey [ 3, 1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"
