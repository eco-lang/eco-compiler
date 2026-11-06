module DebugLogNoDropTest exposing (main)

{-| A `Debug.log` call inside an unused `let` binding still prints.

`deadLogged` is never read; its value is `String.length` applied to
`Debug.log "kept" "logged"`, and the test checks that the line
`kept: "logged"` is printed. The second unused binding, `deadPure`, contains no
`Debug` call and has no observable effect.

The relative order of the logged lines is not checked.

-}

-- CHECK: kept: "logged"

import Html exposing (text)


main : Html.Html msg
main =
    let
        deadLogged =
            String.length (Debug.log "kept" "logged")

        deadPure =
            String.length "xyz"
    in
    text "done"
