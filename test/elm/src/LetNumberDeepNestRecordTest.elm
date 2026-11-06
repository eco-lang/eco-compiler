module LetNumberDeepNestRecordTest exposing (main)

{-| A `number` literal in a record that is itself a field of a let-bound record
is read through two field accesses and used as a `Float`.

`outer = { inner = { v = 30 } }` and `round (outer.inner.v * 1.5)` logs 45.

-}

-- CHECK: deeprec: 45

import Html exposing (text)


main =
    let
        outer =
            { inner = { v = 30 } }

        result =
            round (outer.inner.v * 1.5)

        _ =
            Debug.log "deeprec" result
    in
    text "done"
