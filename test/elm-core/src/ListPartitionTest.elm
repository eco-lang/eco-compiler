module ListPartitionTest exposing (main)

{-| `List.partition` splits a list into the elements that satisfy a predicate and those that do not, each in its original order.

Partitioning 1 to 5 by `isEven` gives `([2,4],[1,3,5])`.

-}

-- CHECK: partition1: ([2,4],[1,3,5])

import Html exposing (text)

isEven n = modBy 2 n == 0

main =
    let
        _ = Debug.log "partition1" (List.partition isEven [1, 2, 3, 4, 5])
    in
    text "done"
