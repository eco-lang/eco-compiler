module MaybeMapTest exposing (main)

{-| `Maybe.map` applies a function inside `Just` and leaves `Nothing` unchanged.

Doubling `Just 42` gives `Just 84`; doubling `Nothing` gives `Nothing`.
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
