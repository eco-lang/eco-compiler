module LetNumberAndThenTest exposing (main)

{-| Probe: a `number` boxed in `Maybe`, consumed via `Maybe.andThen` at `Float`.
Correct: 1.5*30 = 45.

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
