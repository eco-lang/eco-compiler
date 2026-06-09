module LetNumberArrayMapTest exposing (main)

{-| Probe: a `number` boxed in an `Array`, mapped at `Float`. Extends the boxed
silent-miscompile family to `Array`. Correct: [45, 60].

-}

-- CHECK: array: [45, 60]

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
