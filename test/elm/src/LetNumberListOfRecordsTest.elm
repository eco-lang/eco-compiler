module LetNumberListOfRecordsTest exposing (main)

{-| `number` fields of records in a let-bound list, mapped with a `Float`
multiplication, are `Float`s.

`rs = [ { n = 30 }, { n = 40 } ]`, and `List.map (\r -> round (r.n * 1.5))` logs
`[45,60]`.

-}

-- CHECK: listrec: [45,60]

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
