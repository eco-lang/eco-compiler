module ResultMapTest exposing (main)

{-| Test Result.map.
-}

-- CHECK: map1: Ok 84
-- CHECK: map2: Err "error"

import Html exposing (text)


main =
    let
        _ = Debug.log "map1" (Result.map (\x -> x * 2) (Ok 42))
        _ = Debug.log "map2" (Result.map (\x -> x * 2) (Err "error"))
    in
    text "done"
