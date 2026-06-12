module LetNumberMixedTupleSlotTest exposing (main)

{-| Probe: 3-tuple with a non-numeric (String) middle slot (`( 30, "x", 40 )`),
the numeric slots used at `Float`. Tests number-slot refinement interleaved with
an inert non-numeric slot. Correct: 30*1.5 + 40*1.5 = 45 + 60 = 105.
-}

-- CHECK: mixedslot: 105

import Html exposing (text)


main =
    let
        result =
            case ( 30, "x", 40 ) of
                ( a, _, c ) ->
                    round (a * 1.5) + round (c * 1.5)

        _ =
            Debug.log "mixedslot" result
    in
    text "done"
