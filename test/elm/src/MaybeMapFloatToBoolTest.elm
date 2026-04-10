module MaybeMapFloatToBoolTest exposing (main)

{-| Test Maybe.map with Float -> Bool mapping function.
Triggers monomorphization bug where output type (Bool) is treated as input type (Float).
-}

-- CHECK: result: Just True

import Html exposing (text)


main =
    let
        result =
            Maybe.map (\x -> x > 0) (Just 42.0)

        _ = Debug.log "result" result
    in
    text "done"
