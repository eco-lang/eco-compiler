module ListMapBoolTest exposing (main)

{-| Checks that `List.map` produces correct `List Bool` results, mapping `not` and
`identity` over `[True, False, True]`.
-}

-- CHECK: map_not: [False,True,False]
-- CHECK: map_id: [True,False,True]

import Html exposing (text)


main =
    let
        _ = Debug.log "map_not" (List.map not [True, False, True])
        _ = Debug.log "map_id" (List.map identity [True, False, True])
    in
    text "done"
