module DictFromArrayToArray exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Dict exposing (Dict)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildPairs : Int -> Array ( Int, Int )
buildPairs count =
    Array.initialize count
        (\i ->
            let
                k =
                    i + 1
            in
            ( k, k * 7 )
        )


loop : Array ( Int, Int ) -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            dict =
                original |> Array.toList |> Dict.fromList

            back =
                dict |> Dict.toList |> Array.fromList
        in
        loop original (count - 1) (ok && back == original)


main =
    let
        -- Array.initialize counts 0..m-1 → (1,7),(2,14),...,(m,m*7) in key-sorted order
        original =
            buildPairs m

        result =
            loop original n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
