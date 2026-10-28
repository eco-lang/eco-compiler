module StringAstralUnconsTest exposing (main)

{-| G1/E6: uncons splits off one code point, as in Elm (Char is a Unicode code
point in i32). For "😀b" the head is the whole emoji (code 128512 = 0x1F600)
and the remainder is "b" (1 UTF-16 unit). cons writes an astral Char back as a
surrogate pair, so cons ∘ uncons round-trips.
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
