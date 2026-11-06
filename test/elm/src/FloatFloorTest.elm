module FloatFloorTest exposing (main)

{-| `floor` rounds a `Float` down towards negative infinity, for positive, whole and negative values.

`floor -2.3` and `floor -2.7` are both -3.
-}

-- CHECK: floor1: 2
-- CHECK: floor2: 2
-- CHECK: floor3: -3
-- CHECK: floor4: -3

import Html exposing (text)


main =
    let
        _ = Debug.log "floor1" (floor 2.7)
        _ = Debug.log "floor2" (floor 2.0)
        _ = Debug.log "floor3" (floor -2.3)
        _ = Debug.log "floor4" (floor -2.7)
    in
    text "done"
