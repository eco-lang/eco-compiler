module PartialAppArray exposing (main)

-- CHECK: result: 500500000

import Array exposing (Array)
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


buildPartials : Int -> Array (Int -> Int -> Int)
buildPartials count =
    Array.initialize count (\i -> add3 (i + 1))


applyAll : Array (Int -> Int -> Int) -> Int -> Int
applyAll paps acc =
    Array.foldl (\f a -> a + f 0 0) acc paps


loop : Array (Int -> Int -> Int) -> Int -> Int -> Int
loop paps count acc =
    if count <= 0 then
        acc
    else
        loop paps (count - 1) (applyAll paps acc)


main =
    let
        partials =
            buildPartials m

        -- Each applyAll adds sum(1..m) = 500500 (since add3 i 0 0 = i)
        -- After n iterations: n * 500500 = 500500000
        result =
            loop partials n 0

        _ =
            Debug.log "result" result
    in
    text "done"
