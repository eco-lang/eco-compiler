module CharLiteralPatternMatchVariousTest exposing (main)

-- CHECK: dquote: "y"
-- CHECK: lbrace: "y"
-- CHECK: lowerA: "y"
-- CHECK: backslash: "y"
-- CHECK: newline: "y"
-- CHECK: digit0: "y"
-- CHECK: space: "y"

import Html exposing (text)


main =
    let
        check c =
            case c of
                '"' ->
                    if c == '"' then
                        "y"

                    else
                        "n"

                _ ->
                    "fall"

        m1 =
            case '"' of
                '"' ->
                    "y"

                _ ->
                    "n"

        m2 =
            case '{' of
                '{' ->
                    "y"

                _ ->
                    "n"

        m3 =
            case 'a' of
                'a' ->
                    "y"

                _ ->
                    "n"

        m4 =
            case '\\' of
                '\\' ->
                    "y"

                _ ->
                    "n"

        m5 =
            case '\n' of
                '\n' ->
                    "y"

                _ ->
                    "n"

        m6 =
            case '0' of
                '0' ->
                    "y"

                _ ->
                    "n"

        m7 =
            case ' ' of
                ' ' ->
                    "y"

                _ ->
                    "n"

        _ = Debug.log "dquote" m1
        _ = Debug.log "lbrace" m2
        _ = Debug.log "lowerA" m3
        _ = Debug.log "backslash" m4
        _ = Debug.log "newline" m5
        _ = Debug.log "digit0" m6
        _ = Debug.log "space" m7
    in
    text "done"
