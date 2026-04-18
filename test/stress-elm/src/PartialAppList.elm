module PartialAppList exposing (main)

-- CHECK: result: 500500000

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


buildPartials : Int -> List (Int -> Int -> Int) -> List (Int -> Int -> Int)
buildPartials i acc =
    if i <= 0 then
        acc
    else
        buildPartials (i - 1) (add3 i :: acc)


applyAll : List (Int -> Int -> Int) -> Int -> Int
applyAll paps acc =
    case paps of
        [] ->
            acc

        f :: rest ->
            applyAll rest (acc + f 0 0)


loop : List (Int -> Int -> Int) -> Int -> Int -> Int
loop paps count acc =
    if count <= 0 then
        acc
    else
        loop paps (count - 1) (applyAll paps acc)


main =
    let
        partials =
            buildPartials m []

        -- Each applyAll adds sum(1..m) = 500500 (since add3 i 0 0 = i)
        -- After n iterations: n * 500500 = 500500000
        result =
            loop partials n 0

        _ =
            Debug.log "result" result
    in
    text "done"
