module LetNumberTupleRecordNestTest exposing (main)

{-| An integer-literal record field and an integer-literal tuple element, from a
record nested in a pair, are both used as `Float`s: matching
`( { lo = 30 }, 40 )` against `( r, c )` and computing
`round (r.lo * 1.5) + round (c * 1.5)` logs 105.
-}

-- CHECK: tuprec: 105

import Html exposing (text)


main =
    let
        result =
            case ( { lo = 30 }, 40 ) of
                ( r, c ) ->
                    round (r.lo * 1.5) + round (c * 1.5)

        _ =
            Debug.log "tuprec" result
    in
    text "done"
