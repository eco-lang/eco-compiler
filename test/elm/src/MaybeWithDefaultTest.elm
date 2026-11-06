module MaybeWithDefaultTest exposing (main)

{-| `Maybe.withDefault` returns the wrapped value of a `Just` and the default for `Nothing`.

With default `0`, `Just 42` gives `42` and `Nothing` gives `0`.
-}

-- CHECK: withDefault1: 42
-- CHECK: withDefault2: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "withDefault1" (Maybe.withDefault 0 (Just 42))
        _ = Debug.log "withDefault2" (Maybe.withDefault 0 Nothing)
    in
    text "done"
