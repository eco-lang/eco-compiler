module RecordUpdateList exposing (main)

-- CHECK: roundtrip: True

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


buildRecs : Int -> List Rec -> List Rec
buildRecs i acc =
    if i <= 0 then
        acc
    else
        buildRecs (i - 1) ({ a = i, b = i * 2, c = i * 3 } :: acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildRecs m []

        -- Negate field a each iteration; n is even so it round-trips
        transform =
            List.map (\r -> { r | a = -r.a })

        transformed =
            applyNTimes n transform original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
