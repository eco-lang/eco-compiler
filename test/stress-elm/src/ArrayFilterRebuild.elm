module ArrayFilterRebuild exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loop : Array Int -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            odds =
                Array.filter (\x -> modBy 2 x == 1) original

            evens =
                Array.filter (\x -> modBy 2 x == 0) original

            rebuilt =
                Array.append odds evens
                    |> Array.toList
                    |> List.sort
                    |> Array.fromList
        in
        loop original (count - 1) (ok && rebuilt == original)


main =
    let
        original =
            Array.initialize m (\i -> i + 1)

        result =
            loop original n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
