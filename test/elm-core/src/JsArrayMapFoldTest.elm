module JsArrayMapFoldTest exposing (main)

{-| `Array.map`, `Array.foldl` and `Array.foldr` visit an array's elements in the right order.

`Array.map` doubles each of `[1,2,3]`. `Array.foldl (+) 0` sums 1 to 5 to 15. `Array.foldr (::) []` over 1 to 5 rebuilds the list in its original order, which shows that `foldr` starts from the last element.

-}

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
