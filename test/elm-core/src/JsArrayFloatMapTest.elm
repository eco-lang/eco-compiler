module JsArrayFloatMapTest exposing (main)

{-| `Array.map` over an `Array Float` passes the element values to the mapping function.

Three arrays are mapped, doubling, adding 1.0 and negating each element, and the results are read back with `Array.toList`.
-}

-- CHECK: doubled: [2,4,6]
-- CHECK: incr: [2.5,3.5,4.5]
-- CHECK: negate: [-1,-2,-3]

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
