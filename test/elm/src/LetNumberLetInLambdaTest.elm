module LetNumberLetInLambdaTest exposing (main)

{-| Probe: binding-site variation — the `number` `let` lives inside a lambda
body, used at `Float`. Correct: 1.5*30 = 45.

-}

-- CHECK: lamlet: 45

import Html exposing (text)


makeVal : () -> Int
makeVal _ =
    let
        n =
            30
    in
    round (n * 1.5)


main =
    let
        result =
            makeVal ()

        _ =
            Debug.log "lamlet" result
    in
    text "done"
