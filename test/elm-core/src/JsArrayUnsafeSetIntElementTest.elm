module JsArrayUnsafeSetIntElementTest exposing (main)

{-| `Array.set` on an `Array Int` replaces the element at a valid index, and returns the array unchanged for an index out of range.

It sets index 0 and the last index, 3, each starting from the same four-element array, and then sets index 100, which leaves `[1,2,3,4]`.

-}

-- CHECK: original: [1,2,3,4]
-- CHECK: set_0: [99,2,3,4]
-- CHECK: set_3: [1,2,3,42]
-- CHECK: set_oob: [1,2,3,4]


import Array
import Html exposing (text)


main =
    let
        arr : Array.Array Int
        arr =
            Array.fromList [ 1, 2, 3, 4 ]

        _ =
            Debug.log "original" (Array.toList arr)

        _ =
            Debug.log "set_0" (Array.toList (Array.set 0 99 arr))

        _ =
            Debug.log "set_3" (Array.toList (Array.set 3 42 arr))

        _ =
            Debug.log "set_oob" (Array.toList (Array.set 100 0 arr))
    in
    text "done"
