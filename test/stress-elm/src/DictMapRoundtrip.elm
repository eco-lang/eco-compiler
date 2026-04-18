module DictMapRoundtrip exposing (main)

-- CHECK: roundtrip: True

import Dict exposing (Dict)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildDict : Int -> Dict Int String -> Dict Int String
buildDict i acc =
    if i <= 0 then
        acc
    else
        buildDict (i - 1) (Dict.insert i (String.fromInt i) acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildDict m Dict.empty

        transformed =
            applyNTimes n (Dict.map (\_ v -> String.reverse v)) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
