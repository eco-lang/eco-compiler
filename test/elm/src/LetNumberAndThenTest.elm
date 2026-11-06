module LetNumberAndThenTest exposing (main)

{-| An unannotated `let` binding `Just 30`, whose literal has the constrained type
`number`, is used at `Float` inside `Maybe.andThen`: `round (30 * 1.5)` gives 45.
-}

-- CHECK: andthen: 45

import Html exposing (text)


main =
    let
        m =
            Just 30

        result =
            m
                |> Maybe.andThen (\x -> Just (round (x * 1.5)))
                |> Maybe.withDefault 0

        _ =
            Debug.log "andthen" result
    in
    text "done"
