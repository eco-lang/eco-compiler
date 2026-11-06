module LetNumberTupleSecondTest exposing (main)

{-| The second integer-literal element of a let-bound pair, read with
`Tuple.second`, is used as a `Float` while the first is never used:
`round (Tuple.second p * 1.5)` with `p = ( 99, 30 )` logs 45.
-}

-- CHECK: tup2: 45

import Html exposing (text)


main =
    let
        p =
            ( 99, 30 )

        result =
            round (Tuple.second p * 1.5)

        _ =
            Debug.log "tup2" result
    in
    text "done"
