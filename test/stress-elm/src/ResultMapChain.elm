module ResultMapChain exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildResults : Int -> List (Result String Int) -> List (Result String Int)
buildResults i acc =
    if i <= 0 then
        acc
    else
        let
            val =
                if modBy 2 i == 0 then
                    Ok i

                else
                    Err (String.fromInt i)
        in
        buildResults (i - 1) (val :: acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildResults m []

        transformed =
            applyNTimes n (List.map (Result.map negate)) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
