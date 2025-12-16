module MaybeMapTest exposing (main)

{-| Test Maybe.map.
-}

-- CHECK: map1: Just 84
-- CHECK: map2: Nothing

import Html exposing (text)


main =
    let
        _ = Debug.log "map1" (Maybe.map (\x -> x * 2) (Just 42))
        _ = Debug.log "map2" (Maybe.map (\x -> x * 2) Nothing)
    in
    text "done"
