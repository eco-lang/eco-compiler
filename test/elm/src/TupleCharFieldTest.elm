module TupleCharFieldTest exposing (main)

{-| Test that (Int, Char) tuples round-trip correctly through
heap allocation and projection.

-}

-- CHECK: pair: ('A', 65)

import Html exposing (text)


main =
    let
        pair =
            ( 'A', Char.toCode 'A' )

        _ =
            Debug.log "pair" pair
    in
    text "done"
