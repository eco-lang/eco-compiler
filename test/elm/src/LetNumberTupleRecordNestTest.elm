module LetNumberTupleRecordNestTest exposing (main)

{-| Probe: a record nested inside a tuple (`( { lo = 30 }, 40 )`), both the record
field and the sibling tuple slot used at `Float`. Mixes record-field and
tuple-slot refinement in one destructure. Correct: 30*1.5 + 40*1.5 = 105.
-}

-- CHECK: tuprec: 105

import Html exposing (text)


main =
    let
        result =
            case ( { lo = 30 }, 40 ) of
                ( r, c ) ->
                    round (r.lo * 1.5) + round (c * 1.5)

        _ =
            Debug.log "tuprec" result
    in
    text "done"
