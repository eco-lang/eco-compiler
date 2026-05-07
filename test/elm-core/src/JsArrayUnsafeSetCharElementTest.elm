module JsArrayUnsafeSetCharElementTest exposing (main)

{-| `Array.set` on `Array Char` routes through
    `Elm_Kernel_JsArray_unsafeSet_Char`.
-}

-- CHECK: original: ['a', 'b', 'c', 'd']
-- CHECK: set_0: ['z', 'b', 'c', 'd']
-- CHECK: set_3: ['a', 'b', 'c', 'x']


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
