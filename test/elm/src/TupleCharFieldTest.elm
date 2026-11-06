module TupleCharFieldTest exposing (main)

{-| A tuple holding a `Char` and an `Int` (`( 'A', Char.toCode 'A' )`) is built and printed with both components intact.
-}

-- CHECK: pair: ('A',65)

import Html exposing (text)


main =
    let
        pair =
            ( 'A', Char.toCode 'A' )

        _ =
            Debug.log "pair" pair
    in
    text "done"
