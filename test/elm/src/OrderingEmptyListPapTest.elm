module OrderingEmptyListPapTest exposing (main)

{-| The operators `<`, `<=`, `>` and `>=` and the function `compare`,
partially applied to the empty list, work as function values passed to
`List.map` over `[ [], [ 1 ], [ 1, 2 ] ]`.

The empty list is equal to itself and less than any non-empty list.

-}

-- CHECK: ltEmpty: [False,True,True]
-- CHECK: leEmpty: [True,True,True]
-- CHECK: gtEmpty: [False,False,False]
-- CHECK: geEmpty: [True,False,False]
-- CHECK: cmpEmpty: [EQ,LT,LT]

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        xs : List (List Int)
        xs = [ emptyL, [ 1 ], [ 1, 2 ] ]

        _ = Debug.log "ltEmpty" (List.map ((<) emptyL) xs)
        _ = Debug.log "leEmpty" (List.map ((<=) emptyL) xs)
        _ = Debug.log "gtEmpty" (List.map ((>) emptyL) xs)
        _ = Debug.log "geEmpty" (List.map ((>=) emptyL) xs)
        _ = Debug.log "cmpEmpty" (List.map (compare emptyL) xs)
    in
    text "done"
