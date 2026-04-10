module MaybeMapToStringTest exposing (main)

{-| Test Maybe.map with Int -> String mapping function.
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
