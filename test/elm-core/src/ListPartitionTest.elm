module ListPartitionTest exposing (main)

-- CHECK: partition1: ([2, 4], [1, 3, 5])

import Html exposing (text)

isEven n = modBy 2 n == 0

main =
    let
        _ = Debug.log "partition1" (List.partition isEven [1, 2, 3, 4, 5])
    in
    text "done"
