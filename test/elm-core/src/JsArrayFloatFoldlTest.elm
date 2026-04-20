module JsArrayFloatFoldlTest exposing (main)

{-| `Array.foldl` / `Array.foldr` on `Array Float`. Uses `Elm_Kernel_JsArray_foldl`
    and `foldr`, which re-box each unboxed slot as an `Elm Int` before calling
    the user fold function. For `Array Float` the accumulator arithmetic must
    work on the actual float values, not on their raw bit patterns reinterpreted
    as integers.
-}

-- CHECK: sum: 7
-- CHECK: product: 24
-- CHECK: maxViaFold: 3.5
-- CHECK: foldrList: [1.5, 2.5, 3]

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
