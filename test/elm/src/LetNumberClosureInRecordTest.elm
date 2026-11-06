module LetNumberClosureInRecordTest exposing (main)

{-| An anonymous function that uses an unannotated `let`-bound number is stored in a
record field and then called with a Float: `rec.f 1.5` computes `1.5 * 30`, logged
rounded as 45.
-}

-- CHECK: closrec: 45

import Html exposing (text)


main =
    let
        n =
            30

        rec =
            { f = \x -> x * n }

        result =
            round (rec.f 1.5)

        _ =
            Debug.log "closrec" result
    in
    text "done"
