module JsArrayPushSliceTest exposing (main)

-- CHECK: push1: [1,2,3,4]
-- CHECK: push_empty: [42]
-- CHECK: slice_mid: [2,3]
-- CHECK: slice_neg: [3,4]
-- CHECK: append1: [1,2,3,4,5]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [1, 2, 3]
        _ = Debug.log "push1" (Array.toList (Array.push 4 arr))
        _ = Debug.log "push_empty" (Array.toList (Array.push 42 Array.empty))
        _ = Debug.log "slice_mid" (Array.toList (Array.slice 1 3 (Array.fromList [1, 2, 3, 4, 5])))
        _ = Debug.log "slice_neg" (Array.toList (Array.slice -2 5 (Array.fromList [1, 2, 3, 4, 5])))
        _ = Debug.log "append1" (Array.toList (Array.append (Array.fromList [1, 2]) (Array.fromList [3, 4, 5])))
    in
    text "done"
