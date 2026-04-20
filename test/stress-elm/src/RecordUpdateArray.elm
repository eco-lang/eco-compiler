module RecordUpdateArray exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    }


buildRecs : Int -> Array Rec
buildRecs count =
    Array.initialize count
        (\i ->
            let
                k =
                    i + 1
            in
            { a = k, b = k * 2, c = k * 3 }
        )


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildRecs m

        -- Negate field a each iteration; n is even so it round-trips
        transform =
            Array.map (\r -> { r | a = -r.a })

        transformed =
            applyNTimes n transform original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
