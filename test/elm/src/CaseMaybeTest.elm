module CaseMaybeTest exposing (main)

{-| Checks that a `case` on a `Maybe Int` returns the wrapped value for `Just`
and a default of -1 for `Nothing`.
-}

-- CHECK: case1: 42
-- CHECK: case2: -1

import Html exposing (text)


maybeToInt maybe =
    case maybe of
        Just x -> x
        Nothing -> -1


main =
    let
        _ = Debug.log "case1" (maybeToInt (Just 42))
        _ = Debug.log "case2" (maybeToInt Nothing)
    in
    text "done"
