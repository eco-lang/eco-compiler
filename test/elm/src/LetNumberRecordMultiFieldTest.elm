module LetNumberRecordMultiFieldTest exposing (main)

{-| Probe: a record with TWO `number` fields, both projected at `Float`. The
existing boxed test uses a single-field record; this checks per-field numeric
specialization. Correct: 30*1.5 + 40*1.5 = 45 + 60 = 105.

-}

-- CHECK: multi: 105

import Html exposing (text)


main =
    let
        r =
            { lo = 30, hi = 40 }

        result =
            round (r.lo * 1.5) + round (r.hi * 1.5)

        _ =
            Debug.log "multi" result
    in
    text "done"
