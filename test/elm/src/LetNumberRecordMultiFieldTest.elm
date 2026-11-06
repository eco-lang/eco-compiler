module LetNumberRecordMultiFieldTest exposing (main)

{-| Two integer-literal fields of one let-bound record, read as `r.lo` and `r.hi`,
are each used as a `Float`: `round (r.lo * 1.5) + round (r.hi * 1.5)` with
`r = { lo = 30, hi = 40 }` logs 105.
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
