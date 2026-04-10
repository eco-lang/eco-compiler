module ResultMapTypeMismatchTest exposing (main)

{-| Test Result.map with Int -> Bool mapping function.
Same monomorphization issue as Maybe.map but for Result.
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
