module LetNumberFoldrTest exposing (main)

{-| Probe: a list of `number` consumed by `List.foldr` with a `Float`
accumulator. Distinct from the existing `foldl (+)` seed case. Correct:
30*1.5 + 40*1.5 + 0 = 45 + 60 = 105.

-}

-- CHECK: foldr: 105

import Html exposing (text)


main =
    let
        xs =
            [ 30, 40 ]

        result =
            round (List.foldr (\x acc -> x * 1.5 + acc) 0.0 xs)

        _ =
            Debug.log "foldr" result
    in
    text "done"
