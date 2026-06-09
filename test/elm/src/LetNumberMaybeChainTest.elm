module LetNumberMaybeChainTest exposing (main)

{-| Probe: a `number` boxed in `Maybe`, then run through a CHAIN of `Maybe.map`s
where the first stage forces `Float`. Correct: (1.5*30)/3 = 45/3 = 15.

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
