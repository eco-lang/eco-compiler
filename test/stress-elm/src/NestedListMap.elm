module NestedListMap exposing (main)

-- CHECK: roundtrip: True

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


buildNested : Int -> List (List Int) -> List (List Int)
buildNested i acc =
    if i <= 0 then
        acc
    else
        buildNested (i - 1) (List.range ((i - 1) * innerSize + 1) (i * innerSize) :: acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        -- m/innerSize outer lists, each with innerSize elements = m total elements
        outerCount =
            m // innerSize

        original =
            buildNested outerCount []

        transformed =
            applyNTimes n (List.map (List.map negate)) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
