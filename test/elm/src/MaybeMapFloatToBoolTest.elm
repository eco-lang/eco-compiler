module MaybeMapFloatToBoolTest exposing (main)

{-| `Maybe.map` with a Float -> Bool function produces a `Maybe Bool`: mapping `\x -> x > 0` over `Just 42.0` gives `Just True`.
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
