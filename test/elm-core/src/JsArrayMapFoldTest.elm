module JsArrayMapFoldTest exposing (main)

-- CHECK: map1: [2,4,6]
-- CHECK: foldl_sum: 15
-- CHECK: foldr_build: [1,2,3,4,5]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [1, 2, 3]
        _ = Debug.log "map1" (Array.toList (Array.map (\x -> x * 2) arr))
        _ = Debug.log "foldl_sum" (Array.foldl (+) 0 (Array.fromList [1, 2, 3, 4, 5]))
        _ = Debug.log "foldr_build" (Array.foldr (::) [] (Array.fromList [1, 2, 3, 4, 5]))
    in
    text "done"
