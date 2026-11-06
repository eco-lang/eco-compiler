module JsArrayUnsafeSetFloatElementTest exposing (main)

{-| `Array.set` on an `Array Float` replaces the element at the given index and leaves the original array unchanged.

It sets indexes 0 and 2, each starting from the same four-element array. `Debug.log` prints the whole-number floats such as `1.0` without a fractional part, as `1`.

-}

-- CHECK: original: [1,2,3,4]
-- CHECK: set_0: [9.5,2,3,4]
-- CHECK: set_2: [1,2,1.25,4]


import Array
import Html exposing (text)


main =
    let
        arr : Array.Array Float
        arr =
            Array.fromList [ 1.0, 2.0, 3.0, 4.0 ]

        _ =
            Debug.log "original" (Array.toList arr)

        _ =
            Debug.log "set_0" (Array.toList (Array.set 0 9.5 arr))

        _ =
            Debug.log "set_2" (Array.toList (Array.set 2 1.25 arr))
    in
    text "done"
