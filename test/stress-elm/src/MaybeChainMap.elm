module MaybeChainMap exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildMaybes : Int -> List (Maybe Int) -> List (Maybe Int)
buildMaybes i acc =
    if i <= 0 then
        acc
    else
        buildMaybes (i - 1) (Just i :: acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildMaybes m []

        negate x =
            -x

        transformed =
            applyNTimes n (List.map (Maybe.map negate)) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
