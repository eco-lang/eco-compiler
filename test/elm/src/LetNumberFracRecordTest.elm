module LetNumberFracRecordTest exposing (main)

{-| Probe: a record whose two `number` fields are independently specialized —
one used at `Int` (via `toFloat`), the other at `Float` (via `* 0.1`). The
record type is `{ intPart : number, fracPart : number1 }` (two independent
number vars). The Float-demanded field must NOT default to Int.

Correct: toFloat 30 + 0.1 * 40 = 30 + 4 = 34.

-}

-- CHECK: frac: 34

import Html exposing (text)


main =
    let
        r =
            { intPart = 30, fracPart = 40 }

        result =
            round (toFloat r.intPart + 0.1 * r.fracPart)

        _ =
            Debug.log "frac" result
    in
    text "done"
