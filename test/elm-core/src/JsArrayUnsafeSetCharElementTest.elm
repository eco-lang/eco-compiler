module JsArrayUnsafeSetCharElementTest exposing (main)

{-| `Array.set` on an `Array Char` replaces the element at the given index and leaves the original array unchanged.

It sets index 0 and the last index, 3, each starting from the same four-element array.

-}

-- CHECK: original: ['a','b','c','d']
-- CHECK: set_0: ['z','b','c','d']
-- CHECK: set_3: ['a','b','c','x']


import Array
import Html exposing (text)


main =
    let
        arr : Array.Array Char
        arr =
            Array.fromList [ 'a', 'b', 'c', 'd' ]

        _ =
            Debug.log "original" (Array.toList arr)

        _ =
            Debug.log "set_0" (Array.toList (Array.set 0 'z' arr))

        _ =
            Debug.log "set_3" (Array.toList (Array.set 3 'x' arr))
    in
    text "done"
