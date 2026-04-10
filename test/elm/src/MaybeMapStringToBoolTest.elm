module MaybeMapStringToBoolTest exposing (main)

{-| Test Maybe.map with String -> Bool mapping function.
-}

-- CHECK: result: Just True

import Html exposing (text)


main =
    let
        result =
            Maybe.map String.isEmpty (Just "")

        _ = Debug.log "result" result
    in
    text "done"
