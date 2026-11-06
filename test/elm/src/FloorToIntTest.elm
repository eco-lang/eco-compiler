module FloorToIntTest exposing (main)

{-| `floor` rounds a Float down to an Int: 2.7 gives 2 and -2.3 gives -3.
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
