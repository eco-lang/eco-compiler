module NestedArrayMap exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


innerSize : Int
innerSize =
    10


buildNested : Int -> Array (Array Int)
buildNested outerCount =
    Array.initialize outerCount
        (\i -> Array.initialize innerSize (\k -> i * innerSize + k + 1))


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        -- m/innerSize outer arrays, each with innerSize elements = m total elements
        outerCount =
            m // innerSize

        original =
            buildNested outerCount

        transformed =
            applyNTimes n (Array.map (Array.map negate)) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
