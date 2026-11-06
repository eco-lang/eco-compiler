module LetNumberLetInLambdaTest exposing (main)

{-| A `number` bound in a `let` inside a top-level function's body and
multiplied by a `Float` is a `Float`.

`makeVal ()` binds `n = 30` and returns `round (n * 1.5)`, so the test logs 45.

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
