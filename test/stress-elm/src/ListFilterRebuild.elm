module ListFilterRebuild exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loop : List Int -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            odds =
                List.filter (\x -> modBy 2 x == 1) original

            evens =
                List.filter (\x -> modBy 2 x == 0) original

            rebuilt =
                List.sort (odds ++ evens)
        in
        loop original (count - 1) (ok && rebuilt == original)


main =
    let
        original =
            List.range 1 m

        result =
            loop original n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
