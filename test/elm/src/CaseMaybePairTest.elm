module CaseMaybePairTest exposing (main)

{-| Test overlapping Maybe pair patterns in decision tree. -}

-- CHECK: both: 7
-- CHECK: first: 3
-- CHECK: second: 4
-- CHECK: neither: 0

import Html exposing (text)


match t =
    case t of
        (Just a, Just b) -> a + b
        (Just a, Nothing) -> a
        (Nothing, Just b) -> b
        (Nothing, Nothing) -> 0


main =
    let
        _ = Debug.log "both" (match (Just 3, Just 4))
        _ = Debug.log "first" (match (Just 3, Nothing))
        _ = Debug.log "second" (match (Nothing, Just 4))
        _ = Debug.log "neither" (match (Nothing, Nothing))
    in
    text "done"
