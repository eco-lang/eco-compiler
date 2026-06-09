module LetNumberLogBaseTest exposing (main)

{-| Probe: a non-arithmetic Float consumer — `logBase : Float -> Float -> Float`
forces the let-bound `number` to `Float` via its argument type, with no `(*)` at
the use site. Correct: logBase 10 100 = 2.

-}

-- CHECK: logbase: 2

import Html exposing (text)


main =
    let
        n =
            100

        result =
            round (logBase 10 n)

        _ =
            Debug.log "logbase" result
    in
    text "done"
