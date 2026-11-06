module LetNumberApplyToTest exposing (main)

{-| An unannotated `let`-bound number literal reaches a Float multiplication only
through a generic higher-order function: `round (applyTo (\x -> x * 1.5) n)` with
`n = 30` gives 45.
-}

-- CHECK: applyTo: 45

import Html exposing (text)


applyTo : (a -> b) -> a -> b
applyTo f x =
    f x


main =
    let
        n =
            30

        result =
            round (applyTo (\x -> x * 1.5) n)

        _ =
            Debug.log "applyTo" result
    in
    text "done"
