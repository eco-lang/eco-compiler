module LetNumberMaybeChainTest exposing (main)

{-| An integer literal inside `Just`, run through two `Maybe.map` calls, is used as
a `Float`: `Just 30` multiplied by `1.5`, divided by 3 and rounded logs 15.

The first `Maybe.map` multiplies by `1.5`, which fixes the payload to `Float`;
the second uses `(/)` and `round`.

-}

-- CHECK: chain: 15

import Html exposing (text)


main =
    let
        m =
            Just 30

        result =
            m
                |> Maybe.map (\x -> 1.5 * x)
                |> Maybe.map (\x -> round (x / 3))
                |> Maybe.withDefault 0

        _ =
            Debug.log "chain" result
    in
    text "done"
