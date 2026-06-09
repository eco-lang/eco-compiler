module LetNumberCaseLetTest exposing (main)

{-| Probe: binding-site variation — the `number` `let` lives inside a `case`
branch, used at `Float`. Correct: 1.5*30 = 45.

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
