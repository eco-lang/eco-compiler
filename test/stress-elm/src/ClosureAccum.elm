module ClosureAccum exposing (main)

-- CHECK: result: 500500000

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildClosures : Int -> List (Int -> Int) -> List (Int -> Int)
buildClosures i acc =
    if i <= 0 then
        acc
    else
        buildClosures (i - 1) ((\k x -> x + k) i :: acc)


applyAll : List (Int -> Int) -> Int -> Int
applyAll fns acc =
    case fns of
        [] ->
            acc

        f :: rest ->
            applyAll rest (f acc)


loop : List (Int -> Int) -> Int -> Int -> Int
loop fns count acc =
    if count <= 0 then
        acc
    else
        loop fns (count - 1) (applyAll fns acc)


main =
    let
        closures =
            buildClosures m []

        -- Each applyAll adds sum(1..m) = m*(m+1)/2 = 500500
        -- After n iterations: n * 500500 = 500500000
        result =
            loop closures n 0

        _ =
            Debug.log "result" result
    in
    text "done"
