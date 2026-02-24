module TestIndexedMap2 exposing (main)

-- CHECK: map1: [20, 40, 60]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [10, 20, 30]
        _ = Debug.log "map1" (Array.toList (Array.map (\x -> x * 2) arr))
    in
    text "done"
