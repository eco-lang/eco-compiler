module CaseDeeplyNestedTest exposing (main)

{-| Test deeply nested case expressions (3+ levels).
-}

-- CHECK: deep1: "all"
-- CHECK: deep2: "two"

import Html exposing (text)


describeThree a b c =
    case a of
        Just _ ->
            case b of
                Just _ ->
                    case c of
                        Just _ -> "all"
                        Nothing -> "two"
                Nothing -> "one"
        Nothing -> "none"


main =
    let
        _ = Debug.log "deep1" (describeThree (Just 1) (Just 2) (Just 3))
        _ = Debug.log "deep2" (describeThree (Just 1) (Just 2) Nothing)
    in
    text "done"
