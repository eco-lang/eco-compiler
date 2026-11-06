module MaybeMapToStringTest exposing (main)

{-| `Maybe.map` with an Int -> String function produces a `Maybe String`: mapping `String.fromInt` over `Just 42` gives `Just "42"`.
-}

-- CHECK: result: Just "42"

import Html exposing (text)


main =
    let
        result =
            Maybe.map String.fromInt (Just 42)

        _ = Debug.log "result" result
    in
    text "done"
