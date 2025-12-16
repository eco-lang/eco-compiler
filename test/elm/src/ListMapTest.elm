module ListMapTest exposing (main)

{-| Test List.map.
-}

-- CHECK: map1: [2,4,6]
-- CHECK: map2: []
-- CHECK: map3: [1,4,9]

import Html exposing (text)


double x = x * 2
square x = x * x


main =
    let
        _ = Debug.log "map1" (List.map double [1, 2, 3])
        _ = Debug.log "map2" (List.map double [])
        _ = Debug.log "map3" (List.map square [1, 2, 3])
    in
    text "done"
