module TupleMapFirstTest exposing (main)

{-| `Tuple.mapFirst` applies a function to the first component of a pair and leaves the second unchanged.
-}

-- CHECK: mapFirst1: (2,10)
-- CHECK: mapFirst2: (10,20)

import Html exposing (text)


main =
    let
        _ = Debug.log "mapFirst1" (Tuple.mapFirst (\x -> x * 2) (1, 10))
        _ = Debug.log "mapFirst2" (Tuple.mapFirst (\x -> x + 5) (5, 20))
    in
    text "done"
