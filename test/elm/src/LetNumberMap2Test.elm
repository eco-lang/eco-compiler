module LetNumberMap2Test exposing (main)

{-| Probe: a list of `number` consumed by `List.map2` at `Float`. Distinct
combinator from the existing `List.map`/`foldl` cases. Correct: [45, 60].

-}

-- CHECK: map2: [45, 60]

import Html exposing (text)


main =
    let
        xs =
            [ 30, 40 ]

        result =
            List.map2 (\x y -> round (x * 1.5 + y)) xs [ 0.0, 0.0 ]

        _ =
            Debug.log "map2" result
    in
    text "done"
