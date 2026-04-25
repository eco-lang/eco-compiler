module DictFromListToList exposing (main)

-- CHECK: roundtrip: True

import Dict exposing (Dict)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 2


buildPairs : Int -> List ( Int, Int ) -> List ( Int, Int )
buildPairs i acc =
    if i <= 0 then
        acc
    else
        buildPairs (i - 1) (( i, i * 7 ) :: acc)


loop : List ( Int, Int ) -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            dict =
                Dict.fromList original

            back =
                Dict.toList dict
        in
        loop original (count - 1) (ok && back == original)


main =
    let
        -- buildPairs counts down, so pairs are (1,7),(2,14),...,(m,m*7) — already sorted by key
        original =
            buildPairs m []

        result =
            loop original loopCount True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
