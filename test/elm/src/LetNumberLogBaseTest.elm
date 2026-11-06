module LetNumberLogBaseTest exposing (main)

{-| An unannotated let-bound integer literal, passed to `logBase`, is used as a
`Float`: `round (logBase 10 n)` with `n = 100` logs 2.

The literal `100` has the type `number`, and the only thing that fixes it to
`Float` is the parameter type of `logBase`; no arithmetic operator touches it.

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
