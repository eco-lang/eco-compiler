module LetNumberTupleSecondTest exposing (main)

{-| Probe: boxed `number` in a tuple, projected via `Tuple.second` (the existing
boxed test uses `Tuple.first`). The second slot must specialize to `Float`.
Correct: 1.5*30 = 45.

-}

-- CHECK: tup2: 45

import Html exposing (text)


main =
    let
        p =
            ( 99, 30 )

        result =
            round (Tuple.second p * 1.5)

        _ =
            Debug.log "tup2" result
    in
    text "done"
