module MaybePatternMatchTest exposing (main)

{-| Test pattern matching on Maybe.
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
