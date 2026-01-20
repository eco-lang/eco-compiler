module CaseAsPatternTest exposing (main)

{-| Test case expression with as-patterns.
-}

-- CHECK: as1: 0
-- CHECK: as2: 3
-- CHECK: as3: 6

import Html exposing (text)


sumWithLength list =
    case list of
        [] -> 0
        ((x :: _) as whole) -> x + List.length whole


main =
    let
        _ = Debug.log "as1" (sumWithLength [])
        _ = Debug.log "as2" (sumWithLength [1, 2])
        _ = Debug.log "as3" (sumWithLength [3, 4, 5])
    in
    text "done"
