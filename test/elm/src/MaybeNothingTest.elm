module MaybeNothingTest exposing (main)

{-| Test Nothing.
-}

-- CHECK: nothing: Nothing

import Html exposing (text)


main =
    let
        _ = Debug.log "nothing" Nothing
    in
    text "done"
