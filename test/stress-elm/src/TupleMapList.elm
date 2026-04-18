module TupleMapList exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildTuples : Int -> List ( Int, Int ) -> List ( Int, Int )
buildTuples i acc =
    if i <= 0 then
        acc
    else
        buildTuples (i - 1) (( i, -i ) :: acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildTuples m []

        swap ( a, b ) =
            ( b, a )

        transformed =
            applyNTimes n (List.map swap) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
