module EmbeddedNothingAndThenTest exposing (main)

{-| Test Nothing propagation through a chain of Maybe.andThen calls.
-}

-- CHECK: chain1: Nothing
-- CHECK: chain2: Nothing

import Html exposing (text)


main =
    let
        chain1 =
            Just 5
                |> Maybe.andThen (\_ -> Nothing)
                |> Maybe.andThen (\x -> Just (x + 1))

        chain2 =
            Nothing
                |> Maybe.andThen (\x -> Just (x + 1))
                |> Maybe.andThen (\x -> Just (x * 2))

        _ = Debug.log "chain1" chain1
        _ = Debug.log "chain2" chain2
    in
    text "done"
