module LetNumberTupleToFnTest exposing (main)

{-| Probe: a `number` pair passed to a function demanding a `Float` tuple. The
`Float` constraint lives in the parameter type of `useTuple`, reached after a
boxed tuple projection inside the callee. Correct: 1.5*30 + 1.5*40 = 105.

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
