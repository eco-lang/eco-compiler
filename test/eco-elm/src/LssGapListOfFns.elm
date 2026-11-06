module LssGapListOfFns exposing (main)

{-| Top-level functions held in a list are applied in order by `List.foldl`.

`runAll handlers 10` applies `double` and then `addFive`, printing
(10 * 2) + 5 = 25.

## eco

A lambda-set specialization (LSS) probe: function values held in a list and
applied through a fold. The element position of the container must carry the
lambda set for the fold's application to be resolvable at all.

-}

-- CHECK: listOfFns: 25

import Html exposing (text)


double : Int -> Int
double n =
    n * 2


addFive : Int -> Int
addFive n =
    n + 5


handlers : List (Int -> Int)
handlers =
    [ double, addFive ]


runAll : List (Int -> Int) -> Int -> Int
runAll fs x =
    List.foldl (\f acc -> f acc) x fs


main =
    let
        _ =
            Debug.log "listOfFns" (runAll handlers 10)
    in
    text "hello"
