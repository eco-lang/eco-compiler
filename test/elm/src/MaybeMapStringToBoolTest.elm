module MaybeMapStringToBoolTest exposing (main)

{-| `Maybe.map` with a String -> Bool function produces a `Maybe Bool`: mapping `String.isEmpty` over `Just ""` gives `Just True`.
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
