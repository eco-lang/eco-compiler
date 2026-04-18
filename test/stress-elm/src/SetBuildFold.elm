module SetBuildFold exposing (main)

-- CHECK: result: 500500000

import Html exposing (text)
import Set exposing (Set)


n : Int
n =
    1000


m : Int
m =
    1000


buildSet : Int -> Set Int -> Set Int
buildSet i acc =
    if i <= 0 then
        acc
    else
        buildSet (i - 1) (Set.insert i acc)


loop : Int -> Int -> Int
loop count acc =
    if count <= 0 then
        acc
    else
        let
            s =
                buildSet m Set.empty

            sum =
                Set.foldl (+) 0 s
        in
        loop (count - 1) (acc + sum)


main =
    let
        -- Each set fold sums 1..m = m*(m+1)/2 = 500500
        -- After n iterations: n * 500500 = 500500000
        result =
            loop n 0

        _ =
            Debug.log "result" result
    in
    text "done"
