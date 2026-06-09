module LetNumberTupleBothTest exposing (main)

{-| Probe: BOTH slots of a tuple of `number`s forced to `Float` (existing boxed
test forces only the first). Correct: 1.5*30 + 1.5*40 = 45 + 60 = 105.

-}

-- CHECK: tupboth: 105

import Html exposing (text)


main =
    let
        p =
            ( 30, 40 )

        result =
            round (Tuple.first p * 1.5) + round (Tuple.second p * 1.5)

        _ =
            Debug.log "tupboth" result
    in
    text "done"
