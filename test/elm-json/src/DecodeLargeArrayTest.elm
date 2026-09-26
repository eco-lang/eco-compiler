module DecodeLargeArrayTest exposing (main)

{-| threaded-gc-04b D5: JSON arrays longer than the chunk width
    F = 1,021 elements (8 KiB large-object threshold) are stored chunked.
    Every decoder must see the same elements at F-1, F, F+1, 3F+7 and a
    large size, and `Json.Decode.array` must build a well-formed Array (a
    multi-level tree above 32 leaves) there.
-}

-- CHECK: n1020: True
-- CHECK: n1021: True
-- CHECK: n1022: True
-- CHECK: n3070: True
-- CHECK: n100000: True

import Array
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


check : Int -> Bool
check n =
    let
        xs =
            List.range 0 (n - 1)

        text_ =
            E.encode 0 (E.list E.int xs)

        listOk =
            D.decodeString (D.list D.int) text_ == Ok xs

        arrayOk =
            case D.decodeString (D.array D.int) text_ of
                Ok arr ->
                    Array.length arr
                        == n
                        && Array.toList arr
                        == xs
                        && arr
                        == Array.fromList xs
                        && List.all (\i -> Array.get i arr == Just i)
                            (List.filter (\i -> i < n) [ 0, 1020, 1021, 1022, 32767, 32768, n - 1 ])

                Err _ ->
                    False

        indexOk =
            List.all (\i -> D.decodeString (D.index i D.int) text_ == Ok i)
                (List.filter (\i -> i < n) [ 0, 1020, 1021, 2042, 2043, n - 1 ])

        outOfRangeOk =
            case D.decodeString (D.index n D.int) text_ of
                Ok _ ->
                    False

                Err _ ->
                    True

        oneOfOk =
            D.decodeString (D.oneOf [ D.map List.length (D.list D.string), D.map List.length (D.list D.int) ]) text_
                == Ok n

        roundTripOk =
            case D.decodeString D.value text_ of
                Ok v ->
                    E.encode 0 v == text_

                Err _ ->
                    False
    in
    listOk && arrayOk && indexOk && outOfRangeOk && oneOfOk && roundTripOk


main =
    let
        _ =
            Debug.log "n1020" (check 1020)

        _ =
            Debug.log "n1021" (check 1021)

        _ =
            Debug.log "n1022" (check 1022)

        _ =
            Debug.log "n3070" (check 3070)

        _ =
            Debug.log "n100000" (check 100000)
    in
    text "done"
