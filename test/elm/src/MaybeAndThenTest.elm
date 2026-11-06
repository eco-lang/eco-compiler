module MaybeAndThenTest exposing (main)

{-| `Maybe.andThen` applies a `Maybe`-returning function to a `Just` value and passes `Nothing` through.

`half` returns `Just (x // 2)` for an even `x` and `Nothing` for an odd one. The
test logs `andThen half` on `Just 42` (giving `Just 21`), on `Just 41` (the
function returns `Nothing`) and on `Nothing` (the function is never applied).
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
