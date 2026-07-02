module StringAstralUnconsTest exposing (main)

{-| G1/E6: uncons splits off one UTF-16 code unit in Eco (Char is i16). For "😀b"
the head is the lone high surrogate (code 55357 = 0xD83D) and the remainder is
the low surrogate + "b" (2 code units) — a deliberate divergence from Elm's
code-point uncons.
-}

-- CHECK: uncons_code: 55357
-- CHECK: uncons_rest_len: 2

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

        _ =
            Debug.log "uncons_code" code

        _ =
            Debug.log "uncons_rest_len" restLen
    in
    text "done"
