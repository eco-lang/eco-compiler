module SortByTupleWithMixedConstantsTest exposing (main)

{-| `List.sortBy` with a `( Int, List Int )` key whose list is `[]` for positive inputs and `[ -n ]` otherwise orders by the distinct first components.

For `[ -2, -1, 0, 1, 2 ]` the keys are `(-2, [2])`, `(-1, [1])`, `(0, [0])`,
`(1, [])` and `(2, [])`. Every first component is different, so the second
components never decide the order and the input comes back unchanged:
`[-2,-1,0,1,2]`.
-}

-- CHECK: result: [-2,-1,0,1,2]

import Html exposing (text)


keyOf : Int -> ( Int, List Int )
keyOf n =
    if n > 0 then
        ( n, [] )

    else
        ( n, [ -n ] )


main =
    let
        result : List Int
        result = List.sortBy keyOf [ -2, -1, 0, 1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"
