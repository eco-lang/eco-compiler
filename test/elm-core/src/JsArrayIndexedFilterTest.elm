module JsArrayIndexedFilterTest exposing (main)

-- CHECK: indexedMap1: [(0,10),(1,20),(2,30)]
-- CHECK: filter1: [2,4,6]
-- CHECK: toIndexedList1: [(0,10),(1,20),(2,30)]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [10, 20, 30]
        _ = Debug.log "indexedMap1" (Array.toList (Array.indexedMap (\i v -> (i, v)) arr))
        _ = Debug.log "filter1" (Array.toList (Array.filter (\x -> modBy 2 x == 0) (Array.fromList [1, 2, 3, 4, 5, 6])))
        _ = Debug.log "toIndexedList1" (Array.toIndexedList arr)
    in
    text "done"
