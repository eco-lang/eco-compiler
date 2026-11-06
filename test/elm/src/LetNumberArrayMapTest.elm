module LetNumberArrayMapTest exposing (main)

{-| An unannotated `let`-bound `Array` of number literals is mapped with a function
that uses each element as a Float: `x * 1.5` then `round` turns `[30, 40]` into
`[45,60]`.
-}

-- CHECK: array: [45,60]

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 30, 40 ]

        result =
            Array.toList (Array.map (\x -> round (x * 1.5)) arr)

        _ =
            Debug.log "array" result
    in
    text "done"
