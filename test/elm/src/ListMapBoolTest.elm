module ListMapBoolTest exposing (main)

{-| Test List.map producing Bool results — exercises list head projection with Bool.
-}

-- CHECK: map_not: [False, True, False]
-- CHECK: map_id: [True, False, True]

import Html exposing (text)


main =
    let
        _ = Debug.log "map_not" (List.map not [True, False, True])
        _ = Debug.log "map_id" (List.map identity [True, False, True])
    in
    text "done"
