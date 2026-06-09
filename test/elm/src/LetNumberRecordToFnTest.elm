module LetNumberRecordToFnTest exposing (main)

{-| Probe: a `number` bound separately, then placed into a record that is passed
to a function demanding a `Float` field. The constraint is doubly indirect
(record construction + function parameter type). Correct: 1.5*30 = 45.

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
