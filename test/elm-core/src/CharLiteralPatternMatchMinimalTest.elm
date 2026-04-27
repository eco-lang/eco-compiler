module CharLiteralPatternMatchMinimalTest exposing (main)

{-| Minimal isolation of the bug exposed by the C/D/E regression tests.

Tests increasing pattern complexity:
- bare Char literal
- Char in tuple
- Char in Maybe
- Char in Maybe (Char, X) -- this is the shape from String.uncons
-}

-- CHECK: m1_bareChar: "y"
-- CHECK: m2_charInTuple: "y"
-- CHECK: m3_charInMaybe: "y"
-- CHECK: m4_charInMaybeTuple: "y"
-- CHECK: m5_uncons_pat: "y"
-- CHECK: m6_uncons_eq: "y"

import Html exposing (text)


main =
    let
        -- m1: bare Char
        m1 =
            case '"' of
                '"' ->
                    "y"

                _ ->
                    "n"

        -- m2: Char inside a tuple
        m2 =
            case ( '"', 0 ) of
                ( '"', _ ) ->
                    "y"

                _ ->
                    "n"

        -- m3: Char inside a Maybe
        m3 =
            case Just '"' of
                Just '"' ->
                    "y"

                _ ->
                    "n"

        -- m4: Char inside a Maybe (Char, X) — the shape from String.uncons
        m4 =
            case Just ( '"', "x" ) of
                Just ( '"', _ ) ->
                    "y"

                _ ->
                    "n"

        -- m5: actual String.uncons with literal pattern
        m5 =
            case String.uncons "\"x" of
                Just ( '"', _ ) ->
                    "y"

                _ ->
                    "n"

        -- m6: actual String.uncons with == comparison
        m6 =
            case String.uncons "\"x" of
                Just ( c, _ ) ->
                    if c == '"' then
                        "y"

                    else
                        "n"

                Nothing ->
                    "n"

        _ =
            Debug.log "m1_bareChar" m1

        _ =
            Debug.log "m2_charInTuple" m2

        _ =
            Debug.log "m3_charInMaybe" m3

        _ =
            Debug.log "m4_charInMaybeTuple" m4

        _ =
            Debug.log "m5_uncons_pat" m5

        _ =
            Debug.log "m6_uncons_eq" m6
    in
    text "done"
