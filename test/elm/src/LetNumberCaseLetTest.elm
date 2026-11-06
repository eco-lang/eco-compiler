module LetNumberCaseLetTest exposing (main)

{-| An unannotated number literal bound by a `let` inside a `case` branch, then used as
a Float: `round (30 * 1.5)` gives 45.
-}

-- CHECK: caselet: 45

import Html exposing (text)


main =
    let
        flag =
            True

        result =
            case flag of
                True ->
                    let
                        n =
                            30
                    in
                    round (n * 1.5)

                False ->
                    0

        _ =
            Debug.log "caselet" result
    in
    text "done"
