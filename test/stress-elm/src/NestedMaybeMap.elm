module NestedMaybeMap exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildTripleMaybes : Int -> List (Maybe (Maybe (Maybe Int))) -> List (Maybe (Maybe (Maybe Int)))
buildTripleMaybes i acc =
    if i <= 0 then
        acc
    else
        buildTripleMaybes (i - 1) (Just (Just (Just i)) :: acc)


tripleNestedNegate : Maybe (Maybe (Maybe Int)) -> Maybe (Maybe (Maybe Int))
tripleNestedNegate =
    Maybe.map (Maybe.map (Maybe.map negate))


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildTripleMaybes m []

        transformed =
            applyNTimes n (List.map tripleNestedNegate) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
