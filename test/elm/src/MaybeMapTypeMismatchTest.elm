module MaybeMapTypeMismatchTest exposing (main)

{-| `Maybe.map` with a function whose result type (Bool) differs from its argument type (Float), applied with `|>`, returns the mapped Bool.

Mapping `\x -> x > 0` over `Just 1.0` gives `Just True`, and over `Just -1.0`
gives `Just False`.
-}

-- CHECK: r1: Just True
-- CHECK: r2: Just False

import Html exposing (text)


main =
    let
        r1 =
            Just 1.0
                |> Maybe.map (\x -> x > 0)

        r2 =
            Just -1.0
                |> Maybe.map (\x -> x > 0)

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
