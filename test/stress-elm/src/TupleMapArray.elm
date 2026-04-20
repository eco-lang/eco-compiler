module TupleMapArray exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildTuples : Int -> Array ( Int, Int )
buildTuples count =
    Array.initialize count (\i -> ( i + 1, -(i + 1) ))


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildTuples m

        swap ( a, b ) =
            ( b, a )

        transformed =
            applyNTimes n (Array.map swap) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
