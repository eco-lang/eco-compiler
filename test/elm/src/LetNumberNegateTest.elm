module LetNumberNegateTest exposing (main)

{-| Probe: a `number` routed through `negate` (number-polymorphic) before a
`Float` consumer. The `Float` demand still flows from `sqrt`. Correct:
sqrt (negate (negate 144)) = 12.

-}

-- CHECK: neg: 12

import Html exposing (text)


main =
    let
        n =
            144

        result =
            round (sqrt (negate (negate n)))

        _ =
            Debug.log "neg" result
    in
    text "done"
