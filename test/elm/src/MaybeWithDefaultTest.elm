module MaybeWithDefaultTest exposing (main)

{-| Test Maybe.withDefault.
-}

-- CHECK: withDefault1: 42
-- CHECK: withDefault2: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "withDefault1" (Maybe.withDefault 0 (Just 42))
        _ = Debug.log "withDefault2" (Maybe.withDefault 0 Nothing)
    in
    text "done"
