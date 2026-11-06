module MaybeNothingTest exposing (main)

{-| `Debug.log` prints a bare `Nothing` as `Nothing`.
-}

-- CHECK: nothing: Nothing

import Html exposing (text)


main =
    let
        _ = Debug.log "nothing" Nothing
    in
    text "done"
