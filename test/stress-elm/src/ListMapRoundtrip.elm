module ListMapRoundtrip exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            List.range 1 m

        negate x =
            -x

        transformed =
            applyNTimes n (List.map negate) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
