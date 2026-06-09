module LetNumberListOfRecordsTest exposing (main)

{-| Probe: nested container — a list of records each holding a `number`, mapped
at `Float`. Exercises numeric specialization through two boxing layers.
Correct: [45, 60].

-}

-- CHECK: listrec: [45, 60]

import Html exposing (text)


main =
    let
        rs =
            [ { n = 30 }, { n = 40 } ]

        result =
            List.map (\r -> round (r.n * 1.5)) rs

        _ =
            Debug.log "listrec" result
    in
    text "done"
