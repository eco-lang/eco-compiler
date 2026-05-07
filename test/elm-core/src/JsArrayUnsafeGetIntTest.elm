module JsArrayUnsafeGetIntTest exposing (main)

{-| `Array.get` routes through `Elm_Kernel_JsArray_unsafeGet_Int`. Exercise
    on three primitive element types so the same Int-indexed kernel is
    invoked over arrays of differing kinds.
-}

-- CHECK: int_at_0: Just 10
-- CHECK: int_at_2: Just 30
-- CHECK: float_at_1: Just 2.5
-- CHECK: char_at_0: Just 'a'
-- CHECK: oob: Nothing


import Array
import Html exposing (text)


main =
    let
        ints =
            Array.fromList [ 10, 20, 30 ]

        floats =
            Array.fromList [ 1.5, 2.5, 3.5 ]

        chars =
            Array.fromList [ 'a', 'b', 'c' ]

        _ =
            Debug.log "int_at_0" (Array.get 0 ints)

        _ =
            Debug.log "int_at_2" (Array.get 2 ints)

        _ =
            Debug.log "float_at_1" (Array.get 1 floats)

        _ =
            Debug.log "char_at_0" (Array.get 0 chars)

        _ =
            Debug.log "oob" (Array.get 99 ints)
    in
    text "done"
