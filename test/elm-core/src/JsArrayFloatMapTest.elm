module JsArrayFloatMapTest exposing (main)

{-| `Array.map` on `Array Float`. Uses `Elm_Kernel_JsArray_map` on the leaf
    `JsArray` blocks of the Array tree, which re-boxes each unboxed slot as
    an `Elm Int` before calling the user mapper. For `Array Float` the mapper
    must receive float values unchanged.
-}

-- CHECK: doubled: [2, 4, 6]
-- CHECK: incr: [2.5, 3.5, 4.5]
-- CHECK: negate: [-1, -2, -3]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [1.0, 2.0, 3.0]
        _ = Debug.log "doubled" (Array.toList (Array.map (\x -> x * 2.0) arr))
        _ = Debug.log "incr" (Array.toList (Array.map (\x -> x + 1.0) (Array.fromList [1.5, 2.5, 3.5])))
        _ = Debug.log "negate" (Array.toList (Array.map (\x -> -x) (Array.fromList [1.0, 2.0, 3.0])))
    in
    text "done"
