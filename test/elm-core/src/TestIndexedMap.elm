module TestIndexedMap exposing (main)

-- CHECK: indexedMap1: [(0, 10), (1, 20), (2, 30)]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [10, 20, 30]
        _ = Debug.log "indexedMap1" (Array.toList (Array.indexedMap (\i v -> (i, v)) arr))
    in
    text "done"
