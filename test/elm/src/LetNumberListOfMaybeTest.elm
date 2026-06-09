module LetNumberListOfMaybeTest exposing (main)

{-| Probe: nested container — a list of `Maybe number`, each mapped at `Float`.
Two boxing layers (list of Maybe). Correct: [45, 60].

-}

-- CHECK: listmaybe: [45, 60]

import Html exposing (text)


main =
    let
        xs =
            [ Just 30, Just 40 ]

        result =
            List.map (\m -> Maybe.withDefault 0 (Maybe.map (\x -> round (x * 1.5)) m)) xs

        _ =
            Debug.log "listmaybe" result
    in
    text "done"
