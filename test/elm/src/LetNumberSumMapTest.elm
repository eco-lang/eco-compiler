module LetNumberSumMapTest exposing (main)

{-| Probe: a list of `number` mapped at `Float` and reduced with `List.sum` (a
Float-typed reduction). Correct: 30*1.5 + 40*1.5 = 45 + 60 = 105.

-}

-- CHECK: summap: 105

import Html exposing (text)


main =
    let
        xs =
            [ 30, 40 ]

        result =
            round (List.sum (List.map (\x -> x * 1.5) xs))

        _ =
            Debug.log "summap" result
    in
    text "done"
