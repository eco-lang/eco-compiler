module JsArrayUnsafeSetIntElementTest exposing (main)

{-| `Array.set` on `Array Int` routes through
    `Elm_Kernel_JsArray_unsafeSet_Int`.
-}

-- CHECK: original: [1, 2, 3, 4]
-- CHECK: set_0: [99, 2, 3, 4]
-- CHECK: set_3: [1, 2, 3, 42]
-- CHECK: set_oob: [1, 2, 3, 4]


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
