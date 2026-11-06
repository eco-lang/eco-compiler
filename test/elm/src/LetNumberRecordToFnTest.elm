module LetNumberRecordToFnTest exposing (main)

{-| An unannotated let-bound integer literal, placed in a record passed to a
function that takes `{ v : Float }`, is used as a `Float`:
`round (useFloat { v = base })` with `base = 30` logs 45.

`base` is fixed to `Float` only by the record parameter type of `useFloat`,
which multiplies the field by `1.5`.

-}

-- CHECK: rec2fn: 45

import Html exposing (text)


useFloat : { v : Float } -> Float
useFloat r =
    r.v * 1.5


main =
    let
        base =
            30

        result =
            round (useFloat { v = base })

        _ =
            Debug.log "rec2fn" result
    in
    text "done"
