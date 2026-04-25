module ArrayZipUnzip exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 2


zip : Array Int -> Array Int -> Array ( Int, Int )
zip xs ys =
    let
        len =
            min (Array.length xs) (Array.length ys)
    in
    Array.initialize len
        (\i ->
            ( Maybe.withDefault 0 (Array.get i xs)
            , Maybe.withDefault 0 (Array.get i ys)
            )
        )


unzip : Array ( Int, Int ) -> ( Array Int, Array Int )
unzip pairs =
    ( Array.map Tuple.first pairs
    , Array.map Tuple.second pairs
    )


loop : Array Int -> Array Int -> Int -> Bool -> Bool
loop as_ bs count ok =
    if count <= 0 then
        ok
    else
        let
            zipped =
                zip as_ bs

            ( as2, bs2 ) =
                unzip zipped
        in
        loop as2 bs2 (count - 1) (ok && as_ == as2 && bs == bs2)


main =
    let
        as_ =
            Array.initialize m (\i -> i + 1)

        bs =
            Array.initialize m (\i -> i + 1 + m)

        result =
            loop as_ bs loopCount True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
