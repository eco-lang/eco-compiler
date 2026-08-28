module LssGapListOfFns exposing (main)

{-| LSS gap probe — function values held in a LIST, applied through a fold.

The container is the obstacle: the element position must carry the set for the
fold's application to be resolvable at all.
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
