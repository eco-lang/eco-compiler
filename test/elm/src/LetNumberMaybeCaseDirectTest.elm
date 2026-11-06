module LetNumberMaybeCaseDirectTest exposing (main)

{-| An integer literal inside `Just`, taken out by a `case` pattern and multiplied
by `1.5`, is used as a `Float`: `round (n * 1.5)` with `n` bound from `Just 30`
logs 45.

The payload is reached by matching `Just n` directly, not through `Maybe.map`.

-}

-- CHECK: maybedirect: 45

import Html exposing (text)


main =
    let
        result =
            case Just 30 of
                Just n ->
                    round (n * 1.5)

                Nothing ->
                    0

        _ =
            Debug.log "maybedirect" result
    in
    text "done"
