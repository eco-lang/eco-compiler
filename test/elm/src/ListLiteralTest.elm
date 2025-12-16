module ListLiteralTest exposing (main)

{-| Test list literal syntax.
-}

-- CHECK: list1: [1]
-- CHECK: list2: [1,2,3]
-- CHECK: list3: [10,20,30,40,50]

import Html exposing (text)


main =
    let
        _ = Debug.log "list1" [1]
        _ = Debug.log "list2" [1, 2, 3]
        _ = Debug.log "list3" [10, 20, 30, 40, 50]
    in
    text "done"
