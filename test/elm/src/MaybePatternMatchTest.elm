module MaybePatternMatchTest exposing (main)

{-| A `case` on a `Maybe` takes the `Just` branch to extract the value and the `Nothing` branch otherwise.

`unwrap` returns the wrapped Int or `0`: `unwrap (Just 42)` is `42` and
`unwrap Nothing` is `0`.
-}

-- CHECK: match1: 42
-- CHECK: match2: 0

import Html exposing (text)


unwrap maybe =
    case maybe of
        Just x -> x
        Nothing -> 0


main =
    let
        _ = Debug.log "match1" (unwrap (Just 42))
        _ = Debug.log "match2" (unwrap Nothing)
    in
    text "done"
