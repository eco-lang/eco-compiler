module LetNumberDeepNestRecordTest exposing (main)

{-| Probe: deeper boxing nesting — a record inside a record holding a `number`,
projected at `Float`. Correct: 1.5*30 = 45.

-}

-- CHECK: deeprec: 45

import Html exposing (text)


main =
    let
        outer =
            { inner = { v = 30 } }

        result =
            round (outer.inner.v * 1.5)

        _ =
            Debug.log "deeprec" result
    in
    text "done"
