module ResultMapTypeMismatchTest exposing (main)

{-| Checks that `Result.map` can change the `Ok` type, here mapping `Ok 42` through `\x -> x > 0` from `Int` to `Bool` to get `Ok True`.
-}

-- CHECK: result: Ok True

import Html exposing (text)


main =
    let
        result =
            Result.map (\x -> x > 0) (Ok 42)

        _ = Debug.log "result" result
    in
    text "done"
