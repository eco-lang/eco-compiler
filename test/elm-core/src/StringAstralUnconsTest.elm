module StringAstralUnconsTest exposing (main)

{-| `String.uncons` splits a whole character outside the Basic Multilingual
Plane, such as an emoji, off the front of a string, and `String.cons` puts it
back.

For `"😀b"` the head has code 128512 (`0x1F600`) and the rest is `"b"`, of
length 1. `String.cons` of the head and the rest gives `"😀b"` again, and
`String.cons '😀' "b"` has `String.length` 3, since `String.length` counts
UTF-16 units and the emoji takes two.

-}

-- CHECK: uncons_code: 128512
-- CHECK: uncons_rest_len: 1
-- CHECK: uncons_rest_ok: True
-- CHECK: cons_roundtrip: True
-- CHECK: cons_len: 3

import Html exposing (text)


main =
    let
        result =
            String.uncons "😀b"

        code =
            case result of
                Just ( c, _ ) ->
                    Char.toCode c

                Nothing ->
                    -1

        restLen =
            case result of
                Just ( _, r ) ->
                    String.length r

                Nothing ->
                    -1

        roundTrip =
            case result of
                Just ( c, r ) ->
                    String.cons c r == "😀b"

                Nothing ->
                    False

        _ =
            Debug.log "uncons_code" code

        _ =
            Debug.log "uncons_rest_len" restLen

        _ =
            Debug.log "uncons_rest_ok" (Maybe.map Tuple.second result == Just "b")

        _ =
            Debug.log "cons_roundtrip" roundTrip

        _ =
            Debug.log "cons_len" (String.length (String.cons '😀' "b"))
    in
    text "done"
