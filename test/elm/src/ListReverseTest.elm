module ListReverseTest exposing (main)

{-| Checks `List.reverse` on an empty list and on lists of three and five
integers.
-}

-- CHECK: rev1: []
-- CHECK: rev2: [3,2,1]
-- CHECK: rev3: [5,4,3,2,1]

import Html exposing (text)


main =
    let
        _ = Debug.log "rev1" (List.reverse [])
        _ = Debug.log "rev2" (List.reverse [1, 2, 3])
        _ = Debug.log "rev3" (List.reverse [1, 2, 3, 4, 5])
    in
    text "done"
