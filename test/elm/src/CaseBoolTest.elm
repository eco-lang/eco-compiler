module CaseBoolTest exposing (main)

{-| Test case expression on Bool.
-}

-- CHECK: case1: "yes"
-- CHECK: case2: "no"

import Html exposing (text)


boolToStr b =
    case b of
        True -> "yes"
        False -> "no"


main =
    let
        _ = Debug.log "case1" (boolToStr True)
        _ = Debug.log "case2" (boolToStr False)
    in
    text "done"
