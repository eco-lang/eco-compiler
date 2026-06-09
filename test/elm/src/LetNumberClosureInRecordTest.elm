module LetNumberClosureInRecordTest exposing (main)

{-| Probe: a `number` captured by a closure that is STORED in a record field,
then applied at `Float`. Combines capture + boxing of the closure. Correct:
1.5*30 = 45.

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
