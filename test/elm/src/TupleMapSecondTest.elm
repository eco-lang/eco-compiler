module TupleMapSecondTest exposing (main)

{-| `Tuple.mapSecond` applies a function to the second component of a pair and leaves the first unchanged.
-}

-- CHECK: mapSecond1: (1,20)
-- CHECK: mapSecond2: (5,25)

import Html exposing (text)


main =
    let
        _ = Debug.log "mapSecond1" (Tuple.mapSecond (\x -> x * 2) (1, 10))
        _ = Debug.log "mapSecond2" (Tuple.mapSecond (\x -> x + 5) (5, 20))
    in
    text "done"
