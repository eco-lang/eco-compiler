module LetNumberDestructureTest exposing (main)

{-| Probe: binding-site variation — `number`s bound by a DESTRUCTURING let
pattern (`( a, b ) = ( 30, 40 )`) rather than a plain `n = …` binding, both used
at `Float`. The two slots are independent `number` vars; neither must default to
`Int`. Correct: 30*1.5 + 40*1.5 = 45 + 60 = 105.

-}

-- CHECK: destructure: 105

import Html exposing (text)


main =
    let
        ( a, b ) =
            ( 30, 40 )

        result =
            round (a * 1.5) + round (b * 1.5)

        _ =
            Debug.log "destructure" result
    in
    text "done"
