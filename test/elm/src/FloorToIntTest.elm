module FloorToIntTest exposing (main)

{-| Test floor for Float to Int conversion.
-}

-- CHECK: floor1: 2
-- CHECK: floor2: -3

import Html exposing (text)


main =
    let
        _ = Debug.log "floor1" (floor 2.7)
        _ = Debug.log "floor2" (floor -2.3)
    in
    text "done"
