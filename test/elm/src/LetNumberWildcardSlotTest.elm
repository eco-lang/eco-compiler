module LetNumberWildcardSlotTest exposing (main)

{-| Probe: 3-tuple destructure with the middle slot wildcarded (`( a, _, c )`),
the bound slots used at `Float`. Tests filler handling for a genuinely-unused
slot. Correct: 30*1.5 + 50*1.5 = 45 + 75 = 120.
-}

-- CHECK: wildslot: 120

import Html exposing (text)


main =
    let
        result =
            case ( 30, 40, 50 ) of
                ( a, _, c ) ->
                    round (a * 1.5) + round (c * 1.5)

        _ =
            Debug.log "wildslot" result
    in
    text "done"
