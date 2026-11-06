module JsArrayPushSliceTest exposing (main)

{-| `Array.push`, `Array.slice` and `Array.append` give the expected elements, including a negative slice start.

The test pushes onto a three-element array and onto `Array.empty`, and appends `[1,2]` and `[3,4,5]`. `Array.slice 1 3` of 1 to 5 gives `[2,3]`. `Array.slice -2 5` counts the start from the end of the array and gives `[4,5]`.

-}

-- CHECK: push1: [1,2,3,4]
-- CHECK: push_empty: [42]
-- CHECK: slice_mid: [2,3]
-- CHECK: slice_neg: [4,5]
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
