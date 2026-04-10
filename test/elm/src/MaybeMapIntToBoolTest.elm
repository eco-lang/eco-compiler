module MaybeMapIntToBoolTest exposing (main)

{-| Test Maybe.map with Int -> Bool mapping function.
-}

-- CHECK: result: Just True

import Html exposing (text)


main =
    let
        result =
            Maybe.map (\x -> x > 0) (Just 42)

        _ = Debug.log "result" result
    in
    text "done"
