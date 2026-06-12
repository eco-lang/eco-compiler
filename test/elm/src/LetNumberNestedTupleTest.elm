module LetNumberNestedTupleTest exposing (main)

{-| Probe: nested tuple pattern (`( ( a, b ), c )`) with the inner slots used at
`Float`. Exercises the depth-2 projection path and sibling fillers at depth.
Correct: 30*1.5 + 40*1.5 + 50 = 45 + 60 + 50 = 155.
-}

-- CHECK: nesttup: 155

import Html exposing (text)


main =
    let
        result =
            case ( ( 30, 40 ), 50 ) of
                ( ( a, b ), c ) ->
                    round (a * 1.5) + round (b * 1.5) + c

        _ =
            Debug.log "nesttup" result
    in
    text "done"
