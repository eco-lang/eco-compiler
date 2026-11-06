module JsArrayFloatFoldlTest exposing (main)

{-| `Array.foldl` and `Array.foldr` over an `Array Float` pass the element values to the folding function.

`foldl` is checked with `(+)` (sum 7), `(*)` (product 24) and `max` (3.5). `foldr (::) []` rebuilds `[1.5, 2.5, 3.0]` in its original order.
-}

-- CHECK: sum: 7
-- CHECK: product: 24
-- CHECK: maxViaFold: 3.5
-- CHECK: foldrList: [1.5,2.5,3]

import Array
import Html exposing (text)

main =
    let
        _ = Debug.log "sum" (Array.foldl (+) 0.0 (Array.fromList [1.5, 2.5, 3.0]))
        _ = Debug.log "product" (Array.foldl (*) 1.0 (Array.fromList [2.0, 3.0, 4.0]))
        _ = Debug.log "maxViaFold" (Array.foldl max 0.0 (Array.fromList [1.5, 3.5, 2.5]))
        _ = Debug.log "foldrList" (Array.foldr (::) [] (Array.fromList [1.5, 2.5, 3.0]))
    in
    text "done"
