module JsArraySingletonAndPushPrimitivesTest exposing (main)

{-| `Array.repeat 1` and `Array.push` work on arrays of `Int`, `Float` and `Char`.

For each element type, `Array.repeat 1` makes a one-element array and `Array.push` adds an element to the end of a small array built with `Array.fromList`. Each result is printed through `Array.toList`.

-}

-- CHECK: int_singleton: [42]
-- CHECK: float_singleton: [3.14]
-- CHECK: char_singleton: ['z']
-- CHECK: int_push: [1,2,3,99]
-- CHECK: float_push: [1.5,2.5,9.5]
-- CHECK: char_push: ['a','b','q']


import Array
import Html exposing (text)


main =
    let
        _ =
            Debug.log "int_singleton" (Array.toList (Array.repeat 1 42))

        _ =
            Debug.log "float_singleton" (Array.toList (Array.repeat 1 3.14))

        _ =
            Debug.log "char_singleton" (Array.toList (Array.repeat 1 'z'))

        intArr : Array.Array Int
        intArr =
            Array.fromList [ 1, 2, 3 ]

        floatArr : Array.Array Float
        floatArr =
            Array.fromList [ 1.5, 2.5 ]

        charArr : Array.Array Char
        charArr =
            Array.fromList [ 'a', 'b' ]

        _ =
            Debug.log "int_push" (Array.toList (Array.push 99 intArr))

        _ =
            Debug.log "float_push" (Array.toList (Array.push 9.5 floatArr))

        _ =
            Debug.log "char_push" (Array.toList (Array.push 'q' charArr))
    in
    text "done"
