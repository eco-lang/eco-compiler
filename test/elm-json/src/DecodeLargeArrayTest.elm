module DecodeLargeArrayTest exposing (main)

{-| Decoding long JSON arrays of integers gives the same elements, in order, through
`Json.Decode.list`, `array`, `index`, `oneOf` and `value`, for arrays of 1,020 to 100,000
elements.

`check n` encodes `List.range 0 (n - 1)` and logs `True` only if all of these hold: `list`
decodes it to the original list; `array` decodes it to an `Array` with length `n`, the same
elements as the list, equal under `==` to `Array.fromList` of the list, and the right value from
`Array.get` at several indices below `n` (including 32767 and 32768 once `n` is large enough);
`index i` decodes element `i` at several indices, including the last; `index n` fails;
a `oneOf` whose first branch (a list of strings) fails falls through to its second and reports
`n` elements; and decoding to a `Value` and re-encoding gives back the original JSON text.
The sizes are 1020, 1021, 1022, 3070 and 100000.
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
