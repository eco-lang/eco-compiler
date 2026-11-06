module CaseMaybePairTest exposing (main)

{-| Checks that a `case` on a tuple of two `Maybe Int` values, with one branch for
each of the four `Just`/`Nothing` combinations, picks the right branch and binds
the right values in each.

The four calls cover all four combinations; `(Just 3, Just 4)` gives their sum.

-}

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
