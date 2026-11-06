module CaseNestedTest exposing (main)

{-| Checks that a `case` on one `Maybe` with a further `case` on a second `Maybe`
inside each branch reaches all four combinations correctly.
-}

-- CHECK: nested1: "both"
-- CHECK: nested2: "first"
-- CHECK: nested3: "second"
-- CHECK: nested4: "neither"

import Html exposing (text)


describe a b =
    case a of
        Just _ ->
            case b of
                Just _ -> "both"
                Nothing -> "first"
        Nothing ->
            case b of
                Just _ -> "second"
                Nothing -> "neither"


main =
    let
        _ = Debug.log "nested1" (describe (Just 1) (Just 2))
        _ = Debug.log "nested2" (describe (Just 1) Nothing)
        _ = Debug.log "nested3" (describe Nothing (Just 2))
        _ = Debug.log "nested4" (describe Nothing Nothing)
    in
    text "done"
