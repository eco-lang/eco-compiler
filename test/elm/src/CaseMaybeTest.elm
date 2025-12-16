module CaseMaybeTest exposing (main)

{-| Test case expression on Maybe.
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
