module LetNumberTupleToFnTest exposing (main)

{-| A let-bound pair of integer literals passed to a function that takes
`( Float, Float )` is used at `Float`: `round (useTuple p)` with `p = ( 30, 40 )`
logs 105.

`useTuple` destructures its argument and returns `a * 1.5 + b * 1.5`; only its
parameter type fixes the pair's elements to `Float`.

-}

-- CHECK: tup2fn: 105

import Html exposing (text)


useTuple : ( Float, Float ) -> Float
useTuple ( a, b ) =
    a * 1.5 + b * 1.5


main =
    let
        p =
            ( 30, 40 )

        result =
            round (useTuple p)

        _ =
            Debug.log "tup2fn" result
    in
    text "done"
