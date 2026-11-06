module CaseBoolTest exposing (main)

{-| A case expression on a Bool with `True` and `False` branches selects the matching branch.
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
