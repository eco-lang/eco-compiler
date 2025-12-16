module MaybeAndThenTest exposing (main)

{-| Test Maybe.andThen.
-}

-- CHECK: andThen1: Just 21
-- CHECK: andThen2: Nothing
-- CHECK: andThen3: Nothing

import Html exposing (text)


half x =
    if modBy 2 x == 0 then
        Just (x // 2)
    else
        Nothing


main =
    let
        _ = Debug.log "andThen1" (Maybe.andThen half (Just 42))
        _ = Debug.log "andThen2" (Maybe.andThen half (Just 41))
        _ = Debug.log "andThen3" (Maybe.andThen half Nothing)
    in
    text "done"
