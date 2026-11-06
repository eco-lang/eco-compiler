module JsArrayUnsafeGetIntTest exposing (main)

{-| `Array.get` returns `Just` the element at a valid index and `Nothing` for an index past the end.

It reads from arrays of `Int`, `Float` and `Char`. The out-of-range case is index 99 of a three-element `Int` array.

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
