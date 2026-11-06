module ResultMapTest exposing (main)

{-| Checks that `Result.map` applies its function to an `Ok` value (`Ok 42` doubled gives `Ok 84`) and leaves an `Err` unchanged.
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
