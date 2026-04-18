module ListZipUnzip exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


zip : List a -> List b -> List ( a, b ) -> List ( a, b )
zip xs ys acc =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            zip xr yr (( x, y ) :: acc)

        _ ->
            List.reverse acc


unzip : List ( a, b ) -> ( List a, List b )
unzip pairs =
    unzipHelper pairs [] []


unzipHelper : List ( a, b ) -> List a -> List b -> ( List a, List b )
unzipHelper pairs accA accB =
    case pairs of
        [] ->
            ( List.reverse accA, List.reverse accB )

        ( a, b ) :: rest ->
            unzipHelper rest (a :: accA) (b :: accB)


loop : List Int -> List Int -> Int -> Bool -> Bool
loop as_ bs count ok =
    if count <= 0 then
        ok
    else
        let
            zipped =
                zip as_ bs []

            ( as2, bs2 ) =
                unzip zipped
        in
        loop as2 bs2 (count - 1) (ok && as_ == as2 && bs == bs2)


main =
    let
        as_ =
            List.range 1 m

        bs =
            List.range (m + 1) (m * 2)

        result =
            loop as_ bs n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
